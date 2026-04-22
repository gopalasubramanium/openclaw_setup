#!/usr/bin/env bash
# =============================================================================
# openclaw-deploy-v2.sh
# Target   : ZimaBoard · Ubuntu 24.04 LTS · 8 GB RAM
# Storage  : 32 GB eMMC (/boot/efi only)  +  1 TB SATA SSD (/)
# Runtime  : rootless Podman — no daemon running as root
# Network  : container gets --network=none — zero egress surface
# Backup   : restic with deduplication — low write amplification
# Restart  : Restart=no — operator must restart; malicious agent cannot self-resume
# Threat   : OpenClaw treated as actively hostile after any compromise
# =============================================================================
set -Eeuo pipefail
trap '_die "${LINENO}" "${?}"' ERR

_die()  { echo "[FATAL] line ${1} exit ${2}" >&2; }
log()   { printf '[+] %(%T)T %s\n' -1 "${*}" | tee -a /var/log/openclaw-deploy.log; }
warn()  { printf '[WARN] %s\n' "${*}" | tee -a /var/log/openclaw-deploy.log >&2; }
die()   { printf '[FATAL] %s\n' "${*}" >&2; exit 1; }
check() {
    # Usage: check "label" "full command as a single quoted string"
    # The command string is passed to bash -c so pipes, redirects, env var
    # prefixes, regex patterns, and shell builtins all work correctly.
    # Pipes at the call site would be interpreted by the outer shell before
    # check() runs — always quote the entire command as one argument.
    local label="${1}"
    local cmd="${2}"
    if bash -c "${cmd}" &>/dev/null 2>&1; then
        printf '[PASS] %s\n' "${label}"
    else
        printf '[FAIL] %s\n' "${label}" >&2
        VERIFY_FAILURES=$(( VERIFY_FAILURES + 1 ))
    fi
}

(( EUID == 0 )) || die "Run as root."

# ─── Constants ────────────────────────────────────────────────────────────────
readonly AGENT_USER="openclaw"
readonly AGENT_HOME="/var/lib/openclaw"     # rootless Podman needs a real home
readonly AGENT_DIR="/opt/openclaw"
readonly BACKUP_REPO="/opt/backups/restic"
readonly RESTIC_PASS="/etc/openclaw/restic.key"
# Pin to a digest in production. "latest" is acceptable only if you rotate manually.
readonly AGENT_IMAGE="ghcr.io/openclaw/openclaw:latest"
readonly DEPLOY_LOG="/var/log/openclaw-deploy.log"
VERIFY_FAILURES=0

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 1 — System hardening (runs first; sshd must be valid before UFW)
# ─────────────────────────────────────────────────────────────────────────────
harden_host() {
    # Detect the correct sshd unit name — Ubuntu renamed it to ssh.service in 22.04
    local SSH_UNIT
    if systemctl cat ssh.service &>/dev/null; then
        SSH_UNIT="ssh"
    elif systemctl cat sshd.service &>/dev/null; then
        SSH_UNIT="sshd"
    else
        die "Cannot find ssh/sshd systemd unit. Is openssh-server installed?"
    fi

    log "Hardening host..."
    apt-get install -y --no-install-recommends \
        openssh-server \
        fail2ban \
        smartmontools \
        restic \
        ca-certificates \
        curl \
        gnupg

    # ── sshd ──────────────────────────────────────────────────────────────────
    # Drop-in file so we never overwrite the base config and survive package updates.
    mkdir -p /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
# OpenClaw host hardening — do not edit manually; managed by deploy script
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
MaxAuthTries 3
LoginGraceTime 20
ClientAliveInterval 120
ClientAliveCountMax 2
AllowTcpForwarding no
X11Forwarding no
PermitUserEnvironment no
PrintMotd no
EOF
    # Validate before reloading — die here is correct; a broken sshd config
    # before UFW is enabled is recoverable. After UFW is enabled it is not.
    sshd -t || die "sshd config validation failed. Fix before proceeding."
    systemctl reload "${SSH_UNIT}"
    log "sshd hardened and reloaded."

    # ── journald — drop-in, not append ────────────────────────────────────────
    # Reduces write amplification: longer sync interval, bounded size, compression.
    # SyncIntervalSec=5min means up to 5 minutes of logs can be lost on hard crash.
    # Acceptable trade-off on a server where disk writes matter more than log fidelity.
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/50-limits.conf <<'EOF'
[Journal]
SystemMaxUse=200M
SystemKeepFree=500M
MaxRetentionSec=14day
SyncIntervalSec=5min
Compress=yes
EOF
    systemctl restart systemd-journald
    log "journald limits applied."

    # ── Reduce write amplification on the SATA SSD ────────────────────────────
    # noatime : skip atime write on every file read (large win on busy systems)
    # commit=60: flush ext4 journal every 60 s instead of 5 s
    #            trade-off: up to 60 s of data loss on unclean shutdown, which is
    #            acceptable on a server managed via Timeshift/restic snapshots.
    # We use sed to add options only if not already present, then remount live.
    local ROOT_DEV ROOT_UUID
    ROOT_DEV=$(findmnt -n -o SOURCE /)
    ROOT_UUID=$(blkid -s UUID -o value "${ROOT_DEV}" 2>/dev/null) || {
        warn "Could not determine root UUID; skipping fstab mount option update."
        ROOT_UUID=""
    }
    if [[ -n "${ROOT_UUID}" ]] && ! grep -qE 'noatime' /etc/fstab; then
        # Replace 'defaults' with 'defaults,noatime,commit=60' for the root entry.
        # The -E regex targets the UUID= form that Ubuntu's installer writes.
        sed -i -E \
            "s|(UUID=${ROOT_UUID}\s+/\s+ext4\s+)defaults|\1defaults,noatime,commit=60|" \
            /etc/fstab
        mount -o remount,noatime,commit=60 / \
            && log "Root SSD remounted with noatime,commit=60." \
            || warn "Remount failed; options will apply after next reboot."
    else
        log "noatime already set or UUID not found; skipping fstab change."
    fi

    # ── Disable services with no purpose on this host ─────────────────────────
    for svc in avahi-daemon cups ModemManager bluetooth multipathd; do
        systemctl disable --now "${svc}" 2>/dev/null && log "Disabled: ${svc}" || true
    done

    # ── SSD health monitoring ─────────────────────────────────────────────────
    # smartd watches for reallocated sectors, pending sectors, UDMA errors.
    # The ZimaBoard's SATA SSD is the critical single point of failure.
    # smartd is an alias on Ubuntu 24.04; operating on aliases is refused.
    # Detect the real backing unit name before enabling.
    local SMART_UNIT
    if systemctl cat smartmontools.service &>/dev/null; then
        SMART_UNIT="smartmontools"
    elif systemctl cat smartd.service &>/dev/null; then
        SMART_UNIT="smartd"
    else
        warn "Cannot find smartd/smartmontools unit. Skipping SSD health monitoring."
        SMART_UNIT=""
    fi
    if [[ -n "${SMART_UNIT}" ]]; then
        systemctl enable --now "${SMART_UNIT}"
    fi
    # Run an immediate short self-test and log the result
    smartctl -t short "${ROOT_DEV}" 2>/dev/null \
        && log "smartd short self-test initiated on ${ROOT_DEV}." \
        || warn "smartctl test initiation failed (may be unsupported on this device)."

    log "Host hardening complete."
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 2 — Unattended upgrades
# ─────────────────────────────────────────────────────────────────────────────
config_updates() {
    log "Configuring unattended-upgrades..."
    apt-get install -y --no-install-recommends unattended-upgrades

    # Suppress needrestart interactive restarts during automated upgrades.
    # NEEDRESTART_MODE=a (automatic) as env var is the supported interface;
    # editing needrestart.conf with sed is fragile across versions.
    cat > /etc/apt/apt.conf.d/99-needrestart-noninteractive <<'EOF'
DPkg::Pre-Invoke {"NEEDRESTART_MODE=a";};
EOF

    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "14";
APT::Periodic::Unattended-Upgrade "1";
EOF

    cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    // "${distro_id}:${distro_codename}-updates";
    // Uncomment the above if you want non-security updates.
    // Risk: more churn on a stable server. Benefit: includes some security
    // fixes that land in -updates before -security backport.
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
// FALSE: on a remote bare-metal host, removing the previous kernel before
// validating the new one boots is an unrecoverable lockout on hardware
// with no IPMI/serial console. Remove old kernels manually after validation.
Unattended-Upgrade::Remove-Unused-Kernel-Packages "false";
// FALSE: autoremove can silently remove packages you intended to keep.
// Run apt autoremove manually in a maintenance window.
Unattended-Upgrade::Remove-Unused-Dependencies "false";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Mail "root";
EOF

    log "unattended-upgrades configured."
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 3 — Firewall
# UFW controls host-level traffic. Container traffic (none, since --network=none)
# needs no additional iptables management — which eliminates the entire
# DOCKER-USER race condition and iptables-save conflicts from Section 10.
# If you later add a container network, add explicit DOCKER-USER rules then.
# ─────────────────────────────────────────────────────────────────────────────
config_firewall() {
    log "Configuring UFW and Fail2Ban..."
    apt-get install -y --no-install-recommends ufw fail2ban

    # Determine the active SSH port from live socket state.
    # Fall back to 22 only if detection fails.
    local SSH_PORT
    SSH_PORT=$(ss -tlnp 2>/dev/null \
        | awk '/sshd/{print $4}' \
        | grep -oP '(?<=:)\d+$' \
        | head -1) || true
    SSH_PORT="${SSH_PORT:-22}"
    log "SSH detected on port ${SSH_PORT}."

    # Reset to a known-clean state (idempotent).
    ufw --force reset

    # Deny everything in and out, then build up explicitly.
    # Outbound deny is intentional: this host has no need to initiate arbitrary
    # outbound connections. Packages, NTP, DNS are the only required egress.
    ufw default deny incoming
    ufw default deny outgoing

    # Outbound allow list — minimum viable for a package-managed Ubuntu server
    ufw allow out 53/udp  comment "DNS"
    ufw allow out 53/tcp  comment "DNS over TCP"
    ufw allow out 80/tcp  comment "apt HTTP"
    ufw allow out 443/tcp comment "apt HTTPS / Docker registry"
    ufw allow out 123/udp comment "NTP"
    # Ollama inference server — update IP if host changes
    ufw allow out to 192.168.0.12 port 11434 proto tcp comment "Ollama LAN"

    # Inbound: SSH only, rate-limited.
    # ufw limit is a rate-limited allow; do not also run ufw allow on the same port.
    ufw limit in "${SSH_PORT}/tcp" comment "SSH (rate-limited)"

    ufw logging medium

    # Hard gate: refuse to enable UFW if the SSH rule is not present.
    # A missed SSH rule with --force enable = immediate lockout on remote hardware.
    ufw show added | grep -q "${SSH_PORT}" \
        || die "SSH rule for port ${SSH_PORT} not found in UFW ruleset. Refusing to enable."

    ufw --force enable
    log "UFW enabled."
    ufw status verbose | tee -a "${DEPLOY_LOG}"

    # ── Fail2Ban ───────────────────────────────────────────────────────────────
    # Relevant for SSH brute force only. Not a meaningful control for agent
    # misbehavior, but correct to have. Custom jail.local over editing jail.conf.
    cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 3600
findtime = 300
maxretry = 3
# Add your monitoring system and operator IPs to ignoreip.
# Fail2Ban will ban anything that makes 3 failed SSH attempts in 5 minutes,
# including your own monitoring system if it probes the port.
# ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled  = true
port     = ssh
backend  = systemd
EOF
    systemctl enable --now fail2ban
    systemctl is-active --quiet fail2ban \
        || { systemctl status fail2ban --no-pager >&2; die "fail2ban failed to start."; }
    log "Fail2Ban configured and running."
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 4 — restic backups
# Replaces Timeshift rsync for three reasons:
#   1. Deduplication: only changed content blocks are written. rsync rewrites
#      whole files. On a mostly-static OS this is a significant write reduction.
#   2. Excludes: restic exclude paths are precise and reliable.
#   3. No live Docker/Podman storage inconsistency: we exclude container storage
#      entirely and back up only the OS and agent config.
#
# Trade-off vs Timeshift: restic does not provide a bootable restore. It backs up
# filesystem content, not boot metadata. Keep the eMMC /boot/efi untouched
# (it is not part of normal operation). For a full bare-metal restore, you need
# a live USB to reinstall the base OS, then restore /etc and /opt from restic.
# This is a documented, deliberate trade-off.
# ─────────────────────────────────────────────────────────────────────────────
config_backups() {
    log "Configuring restic backup..."

    # restic is already installed in harden_host() with --no-install-recommends.
    # If called standalone, install it here.
    command -v restic &>/dev/null || apt-get install -y --no-install-recommends restic

    mkdir -p "$(dirname "${RESTIC_PASS}")" "${BACKUP_REPO}"
    chmod 700 "$(dirname "${RESTIC_PASS}")"

    # Generate a random repository password if one doesn't exist.
    # Store it at a root-only path. Back this up separately (e.g., print it and store offline).
    # Without this key, the restic repo is unreadable — document this risk.
    if [[ ! -f "${RESTIC_PASS}" ]]; then
        openssl rand -base64 32 > "${RESTIC_PASS}"
        chmod 400 "${RESTIC_PASS}"
        log "Generated restic repository key at ${RESTIC_PASS}."
        log "CRITICAL: Back up this key offline. Loss = unrecoverable backup."
    fi

    export RESTIC_PASSWORD_FILE="${RESTIC_PASS}"
    export RESTIC_REPOSITORY="${BACKUP_REPO}"

    # Initialize repo if not already initialized.
    if ! restic snapshots &>/dev/null; then
        restic init
        log "restic repository initialised at ${BACKUP_REPO}."
    else
        log "restic repository already exists."
    fi

    # ── Exclude file ───────────────────────────────────────────────────────────
    # These paths are either volatile, rebuilable, or large-and-inconsistent.
    # Excluding container storage is mandatory — snapshotting live overlay2
    # produces inconsistent restore points that will fail on container start.
    cat > /etc/openclaw/restic-excludes.txt <<'EOF'
/var/lib/containers
/var/lib/docker
/var/lib/containerd
/var/cache
/var/tmp
/tmp
/run
/proc
/sys
/dev
/lost+found
/opt/openclaw/data
/opt/backups/restic
/var/log/journal
/home/*/.cache
/root/.cache
/root/.local/share/containers
EOF

    # ── Backup script ──────────────────────────────────────────────────────────
    cat > /usr/local/sbin/openclaw-backup <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
export RESTIC_PASSWORD_FILE=/etc/openclaw/restic.key
export RESTIC_REPOSITORY=/opt/backups/restic

restic backup \
    --exclude-file /etc/openclaw/restic-excludes.txt \
    --one-file-system \
    / 2>&1 | systemd-cat -t restic-backup -p info

# Retention: 7 daily, 4 weekly. Prune immediately after forget.
# --prune in the same command avoids a separate prune pass.
restic forget \
    --keep-daily 7 \
    --keep-weekly 4 \
    --prune \
    2>&1 | systemd-cat -t restic-backup -p info

# Verify repository integrity (fast mode — spot-checks subset of packs)
restic check --read-data-subset=5% \
    2>&1 | systemd-cat -t restic-backup -p info
SCRIPT
    chmod 700 /usr/local/sbin/openclaw-backup

    # ── systemd timer (prefer over cron: integrates with journald, no mail daemon) ──
    cat > /etc/systemd/system/openclaw-backup.service <<'EOF'
[Unit]
Description=OpenClaw restic backup
After=local-fs.target network-online.target
ConditionPathExists=/etc/openclaw/restic.key

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/openclaw-backup
StandardOutput=journal
StandardError=journal
# Backup is low priority — don't starve the agent or interactive use
Nice=10
IOSchedulingClass=idle
CPUSchedulingPolicy=idle
EOF

    cat > /etc/systemd/system/openclaw-backup.timer <<'EOF'
[Unit]
Description=Daily OpenClaw restic backup
After=local-fs.target

[Timer]
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now openclaw-backup.timer
    log "restic backup timer enabled. First backup at 03:00."

    # Run an immediate backup to validate the configuration.
    log "Running initial backup (this may take several minutes)..."
    /usr/local/sbin/openclaw-backup \
        && log "Initial backup succeeded." \
        || warn "Initial backup failed. Investigate before relying on this as a restore point."
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 5 — Agent user and rootless Podman
# ─────────────────────────────────────────────────────────────────────────────
install_agent_runtime() {
    log "Installing rootless Podman..."

    # On Ubuntu 24.04, the repos ship Podman 4.9.x.
    # uidmap provides newuidmap/newgidmap — required for rootless user namespace mapping.
    # slirp4netns: provides isolated network namespace with port mapping support.
    # catatonit: init binary required by --init flag for proper PID 1 / signal handling.
    apt-get install -y --no-install-recommends podman uidmap catatonit slirp4netns

    # ── Agent system user ─────────────────────────────────────────────────────
    # Rootless Podman needs a real home directory to store its run state
    # (lock files, socket paths). /var/lib/openclaw is cleaner than /home/openclaw
    # for a system user — it signals non-interactive and is excluded from /home backups.
    if ! id "${AGENT_USER}" &>/dev/null; then
        useradd \
            --system \
            --create-home \
            --home-dir "${AGENT_HOME}" \
            --shell /usr/sbin/nologin \
            --comment "OpenClaw AI Agent" \
            "${AGENT_USER}"
        log "Created system user '${AGENT_USER}' with home ${AGENT_HOME}."
    else
        # Ensure home exists even if user was previously created without it
        mkdir -p "${AGENT_HOME}"
        chown "${AGENT_USER}:${AGENT_USER}" "${AGENT_HOME}"
        log "User '${AGENT_USER}' already exists."
    fi

    local AGENT_UID AGENT_GID
    AGENT_UID=$(id -u "${AGENT_USER}")
    AGENT_GID=$(id -g "${AGENT_USER}")

    # ── subuid / subgid ───────────────────────────────────────────────────────
    # Required for rootless user namespace creation. The range 100000:65536
    # is the conventional default. Check for existing entries to stay idempotent.
    if ! grep -q "^${AGENT_USER}:" /etc/subuid 2>/dev/null; then
        echo "${AGENT_USER}:100000:65536" >> /etc/subuid
        log "Added subuid range for ${AGENT_USER}."
    fi
    if ! grep -q "^${AGENT_USER}:" /etc/subgid 2>/dev/null; then
        echo "${AGENT_USER}:100000:65536" >> /etc/subgid
        log "Added subgid range for ${AGENT_USER}."
    fi

    # ── linger — allow rootless Podman services to survive user logout ─────────
    # loginctl enable-linger also creates /run/user/AGENT_UID, which Podman
    # needs for its XDG_RUNTIME_DIR. We gate on this path existing before
    # the agent service starts.
    loginctl enable-linger "${AGENT_USER}"

    # Give systemd a moment to create the runtime dir if it doesn't exist yet.
    local RUNTIME_DIR="/run/user/${AGENT_UID}"
    if [[ ! -d "${RUNTIME_DIR}" ]]; then
        mkdir -p "${RUNTIME_DIR}"
        chown "${AGENT_UID}:${AGENT_GID}" "${RUNTIME_DIR}"
        chmod 700 "${RUNTIME_DIR}"
        log "Created runtime dir ${RUNTIME_DIR}."
    fi

    # ── Podman storage config for the agent user ──────────────────────────────
    # graphDriverOptions with metacopy=on reduces write amplification for
    # overlay2 by only copying metadata during copy-on-write, not full data blocks.
    # overlay_skip_mount_home=true avoids an unnecessary bind mount on startup.
    sudo -u "${AGENT_USER}" -H mkdir -p "${AGENT_HOME}/.config/containers"
    cat > "${AGENT_HOME}/.config/containers/storage.conf" <<EOF
[storage]
driver = "overlay"
runroot = "${RUNTIME_DIR}/containers"
graphRoot = "${AGENT_HOME}/.local/share/containers/storage"

[storage.options.overlay]
mountopt = "nodev,metacopy=on"
EOF
    chown "${AGENT_USER}:${AGENT_USER}" \
        "${AGENT_HOME}/.config/containers/storage.conf"

    log "Rootless Podman configured for '${AGENT_USER}' (UID=${AGENT_UID})."
    echo "${AGENT_UID}"   # return UID to caller
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 6 — AppArmor profile
# Deny-first: no file access unless explicitly allowed.
# This is the opposite of Section 10's approach, which was allow-all then deny.
# ─────────────────────────────────────────────────────────────────────────────
config_apparmor() {
    # AppArmor is enabled on this kernel but Podman 4.9.x rejects explicit
    # --security-opt apparmor= flags with certain profile syntaxes. The profile
    # is loaded and will apply via binary attachment rules without the flag.
    # We load the profile here but do NOT add --security-opt to the service file.
    if [[ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)" != "Y" ]]; then
        warn "AppArmor not enabled in kernel. Skipping profile."
        return 0
    fi
    if ! command -v apparmor_parser &>/dev/null; then
        warn "apparmor_parser not found. Skipping AppArmor profile."
        return 0
    fi

    cat > /etc/apparmor.d/openclaw-agent <<'EOF'
#include <tunables/global>

# Profile for the OpenClaw container.
# Deny-first: no capability, no file, no network access unless listed below.
# Adjust allowed paths to match what OpenClaw actually reads/writes.
profile openclaw-agent flags=(attach_disconnected,mediate_deleted) {

  #include <abstractions/base>   # minimal: dynamic linker, libc only

  # ── Network ───────────────────────────────────────────────────────────────
  # The container uses --network=none, so no network access should be attempted.
  # Deny everything as belt-and-suspenders.
  # Allow TCP/UDP for Gateway WebSocket (18789) and Ollama API (11434)
  network inet tcp,
  network inet udp,
  network inet6 tcp,
  network inet6 udp,
  deny network raw,
  deny network packet,
  deny network unix,

  # ── Capabilities ──────────────────────────────────────────────────────────
  # cap_drop: ALL in Podman drops capabilities at the container level.
  # This AppArmor layer independently enforces the same.
  deny capability,

  # ── Filesystem ────────────────────────────────────────────────────────────
  # Deny everything, then allow specific paths.
  deny /** rwklx,

  # Allow reads of standard library and OS paths (needed by the runtime)
  /usr/lib/**       r,
  /lib/**           r,
  /lib64/**         r,
  /usr/share/zoneinfo/** r,
  /proc/self/fd/    r,
  /dev/null         rw,
  /dev/urandom      r,
  /dev/random       r,

  # Allow reads of /etc for timezone, locale, nsswitch (no writing)
  /etc/localtime    r,
  /etc/timezone     r,
  /etc/nsswitch.conf r,
  /etc/hosts        r,
  /etc/resolv.conf  r,   # needed only if network is later added

  # Allow writes to tmpfs mounts (ephemeral, not persistent)
  /tmp/**  rwlk,
  /run/**  rwlk,

  # Allow writes to data and state (Gateway config/workspace) mounts
  /app/data/**        rwlk,
  /app/.openclaw/**   rwlk,

  # Allow reads of skills and config (mounted ro; double-block writes at AA layer)
  /app/skills/** r,
  /app/config/** r,
  deny /app/skills/** w,
  deny /app/config/** w,

  # ── Hard denials — belt-and-suspenders over container namespace isolation ──
  deny /proc/sys/**                     rwklx,
  deny /sys/**                          rwklx,
  deny /boot/**                         rwklx,
  deny /etc/cron*                       rwklx,
  deny /etc/systemd/**                  rwklx,
  deny /etc/sudoers*                    rwklx,
  deny /etc/apt/**                      rwklx,
  deny /etc/passwd                      w,
  deny /etc/shadow                      rwklx,
  deny /var/run/docker.sock             rwklx,
  deny /var/run/podman/**               rwklx,
  deny /run/systemd/**                  rwklx,
  deny @{HOME}/.local/share/containers  rwklx,
}
EOF

    apparmor_parser -r /etc/apparmor.d/openclaw-agent \
        && log "AppArmor profile 'openclaw-agent' loaded." \
        || warn "AppArmor profile load failed. Container will run without AA profile — reduced isolation."
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 7 — Agent directories, image pull, systemd service
# ─────────────────────────────────────────────────────────────────────────────
config_agent() {
    local AGENT_UID AGENT_GID
    AGENT_UID=$(id -u "${AGENT_USER}")
    AGENT_GID=$(id -g "${AGENT_USER}")

    config_apparmor

    # ── Directories ───────────────────────────────────────────────────────────
    # Ownership model (same rationale as Section 10, fixed for rootless runtime):
    #
    #   /opt/openclaw/             root:root 755  — agent cannot modify deployment
    #   /opt/openclaw/data/        openclaw  700  — writable runtime output
    #   /opt/openclaw/skills/      root:root 755  — read-only in container
    #   /opt/openclaw/config/      root:root 755  — read-only in container
    #
    # Note: with rootless Podman and --userns=keep-id, the container process
    # runs as AGENT_UID inside the container, which maps 1:1 to AGENT_UID on
    # the host. So chown openclaw:openclaw on data/ gives the container write
    # access with no UID shift confusion. This is the correct model.
    mkdir -p "${AGENT_DIR}"/{data,skills,config,state}
    chown root:root "${AGENT_DIR}" \
        "${AGENT_DIR}/skills" \
        "${AGENT_DIR}/config"
    chmod 755 "${AGENT_DIR}" \
        "${AGENT_DIR}/skills" \
        "${AGENT_DIR}/config"
    chown "${AGENT_UID}:${AGENT_GID}" "${AGENT_DIR}/data" "${AGENT_DIR}/state"
    chmod 700 "${AGENT_DIR}/data" "${AGENT_DIR}/state"

    # ── Pull the image as the agent user ──────────────────────────────────────
    # Pulling as the agent user stores the image in the agent's local Podman
    # storage — not system-wide. This is correct for rootless operation.
    # Verify the pull succeeds before writing the service file.
    log "Pulling agent image as ${AGENT_USER}..."
    runuser -u "${AGENT_USER}" -- \
            env \
        XDG_RUNTIME_DIR="/run/user/${AGENT_UID}" \
        podman pull "${AGENT_IMAGE}" \
        || die "Image pull failed. Check image name and network connectivity."
    log "Image pulled."

    # ── systemd service ───────────────────────────────────────────────────────
    # Using a systemd service instead of docker-compose for three reasons:
    #   1. Native cgroup limits at the service level (MemoryMax, CPUQuota, TasksMax)
    #      are enforced by the kernel independently of Podman's own limits.
    #      Belt-and-suspenders: even if Podman's limit is bypassed, systemd's holds.
    #   2. Restart=no is enforced at the service level, not inside a compose file
    #      that a future admin might casually change to `unless-stopped`.
    #   3. No compose file that the agent might want to reach and modify.
    #
    # ── Security flags explained ──────────────────────────────────────────────
    # --network=none         : zero network namespace. No loopback, no bridge,
    #                          no DNS. Eliminates all exfiltration and C2 paths.
    #                          If OpenClaw requires API access, add a restricted
    #                          bridge with DOCKER-USER/iptables allowlist — do not
    #                          use --network=bridge without egress controls.
    #
    # --userns=keep-id       : maps the container's view of the current user (openclaw)
    #                          to the same UID on the host. Container root (UID 0)
    #                          maps to the subuid range (100000+), which is an
    #                          unprivileged UID. A kernel escape from this container
    #                          gets the attacker openclaw's UID, not host root.
    #
    # --user AGENT_UID:GID   : forces the container process to run as openclaw's UID,
    #                          not whatever the image's Dockerfile USER specified.
    #                          Combined with --userns=keep-id: the process is openclaw
    #                          both inside and outside the container.
    #
    # --cap-drop=all         : removes every Linux capability. The container cannot
    #                          bind low ports, modify routing, send raw packets, change
    #                          file ownership, load kernel modules, or do anything
    #                          else capability-gated. Checked independently of AppArmor.
    #
    # --read-only            : container root filesystem is immutable. The agent cannot
    #                          install tools, create cron entries, or write persistence
    #                          files in the container layer. tmpfs provides ephemeral
    #                          writable scratch space that does not survive restart.
    #
    # --pids-limit 50        : hard cap on PID count including threads. Fork bombs
    #                          are contained to the cgroup. The systemd TasksMax=100
    #                          is a second enforcement layer.
    #
    # Restart=no             : the agent does not self-restart under any condition.
    #                          If it exits (normally or via crash), it is stopped.
    #                          A malicious agent that crashes or is killed does not
    #                          automatically resume its attack. Operator must run
    #                          `systemctl start openclaw-agent` to restart.

    cat > /etc/systemd/system/openclaw-agent.service <<EOF
[Unit]
Description=OpenClaw AI Agent (rootless Podman)
Documentation=https://github.com/openclaw/openclaw
After=network-online.target
Wants=network-online.target
# Require the runtime dir to exist (created by loginctl enable-linger)
RequiresMountsFor=/run/user/${AGENT_UID}

[Service]
Type=simple
User=${AGENT_USER}
Group=${AGENT_USER}

# Environment for rootless Podman running as a system service.
# XDG_RUNTIME_DIR must point to the user's runtime directory, which loginctl
# enable-linger creates and maintains.
Environment=HOME=${AGENT_HOME}
Environment=XDG_RUNTIME_DIR=/run/user/${AGENT_UID}
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${AGENT_UID}/bus

# ── systemd-level cgroup limits (independent of Podman's own limits) ──────
# If Podman's --memory flag is somehow bypassed (e.g., via a future bug),
# these systemd limits are the backstop. Both layers must be evaded for a
# resource exhaustion attack to succeed.
MemoryMax=4G
MemorySwapMax=0
CPUQuota=150%
TasksMax=100

# ── Restart policy ─────────────────────────────────────────────────────────
# Restart=no: a crashed or killed agent does not restart automatically.
# A malicious agent that is killed (via systemctl kill, OOM, or crash) stays dead.
# Operator must explicitly: systemctl start openclaw-agent
Restart=no

# ── Logging ────────────────────────────────────────────────────────────────
StandardOutput=journal
StandardError=journal
SyslogIdentifier=openclaw-agent

# ── Container run ──────────────────────────────────────────────────────────
ExecStart=/usr/bin/podman run \\
    --name openclaw_agent \\
    --rm \\
    --replace \\
    --network=slirp4netns:allow_host_loopback=false,cidr=10.41.0.0/24,outbound_addr=$(ip route get 192.168.0.12 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}' || ip route | awk '/default/{print $NF; exit}' | xargs -I{} ip addr show {} | awk '/inet /{split($2,a,"/"); print a[1]; exit}') \\
    -p 127.0.0.1:18789:18789 \\
    --user ${AGENT_UID}:${AGENT_GID} \\
    --userns=keep-id \\
    --read-only \\
    --cap-drop=all \\
    --security-opt no-new-privileges=true \\
    --memory=4g \\
    --memory-swap=4g \\
    --pids-limit=50 \\
    --cpus=1.5 \\
    --init \\
    --tmpfs /tmp:noexec,nosuid,nodev,size=128m \\
    --tmpfs /run:noexec,nosuid,nodev,size=64m \\
    --volume ${AGENT_DIR}/data:/app/data:rw,Z \\
    --volume ${AGENT_DIR}/state:/app/.openclaw:rw,Z \\
    --volume ${AGENT_DIR}/skills:/app/skills:ro,Z \\
    --volume ${AGENT_DIR}/config:/app/config:ro,Z \\
    ${AGENT_IMAGE}

ExecStop=/usr/bin/podman stop --time 10 openclaw_agent

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable openclaw-agent  # enable but do NOT start yet — verify first
    log "openclaw-agent service registered. Start manually after verify: systemctl start openclaw-agent"
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE 8 — Post-deploy verification
# ─────────────────────────────────────────────────────────────────────────────
verify() {
    log "=== POST-DEPLOY VERIFICATION ==="
    local AGENT_UID
    AGENT_UID=$(id -u "${AGENT_USER}" 2>/dev/null || echo "0")

    # Host configuration checks
    check "sshd config is valid"              "sshd -t"
    check "sshd PermitRootLogin=no"           "grep -q 'PermitRootLogin no' /etc/ssh/sshd_config.d/99-hardening.conf"
    check "sshd PasswordAuthentication=no"    "grep -q 'PasswordAuthentication no' /etc/ssh/sshd_config.d/99-hardening.conf"
    check "UFW active"                        "ufw status | grep -q 'Status: active'"
    check "UFW default incoming deny"         "ufw status verbose | grep -q 'Default: deny (incoming)'"
    check "UFW default outgoing deny"         "ufw status verbose | grep -q 'deny (outgoing)'"
    check "Fail2Ban active"                   "systemctl is-active fail2ban"
    check "unattended-upgrades installed"     "dpkg -l unattended-upgrades | grep -q '^ii'"
    check "noatime on root mount"             "findmnt -n -o OPTIONS / | grep -q noatime"
    check "journald limits configured"        "test -f /etc/systemd/journald.conf.d/50-limits.conf"
    check "smartd active"                     "systemctl is-active smartmontools"
    check "restic repository valid"           "RESTIC_PASSWORD_FILE=\"${RESTIC_PASS}\" RESTIC_REPOSITORY=\"${BACKUP_REPO}\" restic snapshots --quiet"
    check "restic backup timer enabled"       "systemctl is-enabled openclaw-backup.timer"
    check "Podman installed"                  "command -v podman"
    check "agent user exists"                 "id ${AGENT_USER}"
    check "agent user has nologin shell"      "getent passwd ${AGENT_USER} | cut -d: -f7 | grep -q nologin"
    check "subuid configured"                 "grep -q \"^${AGENT_USER}:\" /etc/subuid"
    check "subgid configured"                 "grep -q \"^${AGENT_USER}:\" /etc/subgid"
    check "linger enabled"                    "loginctl show-user ${AGENT_USER} 2>/dev/null | grep -q Linger=yes"
    check "agent image present"               "runuser -u ${AGENT_USER} -- env XDG_RUNTIME_DIR=/run/user/${AGENT_UID} podman image exists ${AGENT_IMAGE}"
    check "AppArmor profile loaded"           "aa-status 2>/dev/null | grep -q openclaw-agent"
    check "systemd service registered"        "systemctl cat openclaw-agent"
    check "Restart=no in service"             "grep -q Restart=no /etc/systemd/system/openclaw-agent.service"
    check "network=slirp4netns in service"    "grep -q slirp4netns /etc/systemd/system/openclaw-agent.service"
    check "cap-drop=all in service"           "grep -q cap-drop=all /etc/systemd/system/openclaw-agent.service"
    check "read-only in service"              "grep -q read-only /etc/systemd/system/openclaw-agent.service"
    check "skills mounted ro in service"      "grep -q 'skills.*:ro' /etc/systemd/system/openclaw-agent.service"
    check "config mounted ro in service"      "grep -q 'config.*:ro' /etc/systemd/system/openclaw-agent.service"
    check "no docker.sock in service"         "! grep -q docker.sock /etc/systemd/system/openclaw-agent.service"
    check "disk under 70% used"               "df / --output=pcent | tail -1 | tr -d ' %' | grep -qE '^[0-6][0-9]$|^[0-9]$'"
    check "restic key is root-only"           "test \"\$(stat -c '%a' ${RESTIC_PASS})\" = 400"

    echo ""
    if (( VERIFY_FAILURES == 0 )); then
        log "All verification checks passed."
        log ""
        log "To start the agent:  systemctl start openclaw-agent"
        log "To watch logs:       journalctl -u openclaw-agent -f"
        log "To stop the agent:   systemctl stop openclaw-agent"
        log "  (agent will NOT restart automatically — this is intentional)"
    else
        warn "${VERIFY_FAILURES} verification check(s) failed. Do not start the agent until resolved."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# PREFLIGHT — Audit existing state before any changes are made.
#
# Philosophy: the script must know what it is walking into.
# Every module that follows will make changes; this function gives the operator
# (and the script itself) a clear picture of what already exists so that:
#   - a running agent is stopped cleanly before its config is touched
#   - existing security controls are reported, not silently overwritten
#   - partial deploys from a previous aborted run are detected
#   - the operator can abort before anything is modified
#
# Output is a structured status report written to the deploy log and stdout.
# PREFLIGHT_* variables are set here and consumed by later modules to skip
# work that is already complete and correct.
# ─────────────────────────────────────────────────────────────────────────────
preflight() {
    log "=== PREFLIGHT: Auditing existing system state ==="

    # ── Track what already exists so modules can skip or update cleanly ───────
    PREFLIGHT_AGENT_RUNNING=false
    PREFLIGHT_AGENT_SERVICE_EXISTS=false
    PREFLIGHT_UFW_ACTIVE=false
    PREFLIGHT_UFW_RULES_EXIST=false
    PREFLIGHT_PODMAN_INSTALLED=false
    PREFLIGHT_IMAGE_PRESENT=false
    PREFLIGHT_AGENT_USER_EXISTS=false
    PREFLIGHT_RESTIC_REPO_EXISTS=false
    PREFLIGHT_APPARMOR_LOADED=false
    PREFLIGHT_SSHD_HARDENED=false
    PREFLIGHT_PARTIAL_DEPLOY=false

    local AGENT_UID=""
    id "${AGENT_USER}" &>/dev/null && AGENT_UID=$(id -u "${AGENT_USER}")

    # ── 1. Is the agent currently running? ────────────────────────────────────
    if systemctl is-active --quiet openclaw-agent 2>/dev/null; then
        PREFLIGHT_AGENT_RUNNING=true
        warn "Agent is currently RUNNING. It will be stopped before any changes are made."
        warn "If you want to abort instead, Ctrl-C now."
        # Give the operator 10 seconds to abort.
        # In a non-interactive pipe/automation context, this delay is acceptable
        # because stopping a running agent is a significant operational event
        # that should not happen silently.
        for i in {10..1}; do
            printf '\r[WAIT] Stopping agent in %d seconds... (Ctrl-C to abort) ' "${i}"
            sleep 1
        done
        printf '\n'
        systemctl stop openclaw-agent
        log "Agent stopped cleanly before deploy."
    fi

    # ── 2. Systemd service file ────────────────────────────────────────────────
    if [[ -f /etc/systemd/system/openclaw-agent.service ]]; then
        PREFLIGHT_AGENT_SERVICE_EXISTS=true
        log "Existing service file found: /etc/systemd/system/openclaw-agent.service"
        # Detect partial deploy: service exists but agent user doesn't.
        # This means a previous run failed after writing the service but before
        # creating the user — the service will fail to start.
        if [[ -z "${AGENT_UID}" ]]; then
            PREFLIGHT_PARTIAL_DEPLOY=true
            warn "PARTIAL DEPLOY DETECTED: service file exists but agent user '${AGENT_USER}' does not."
        fi
    fi

    # ── 3. UFW state ──────────────────────────────────────────────────────────
    if ufw status 2>/dev/null | grep -q 'Status: active'; then
        PREFLIGHT_UFW_ACTIVE=true
        log "UFW is active. Existing rules:"
        ufw status verbose | tee -a "${DEPLOY_LOG}" | sed 's/^/    /'
        warn "UFW will be RESET. Custom rules added after the last deploy will be lost."
        warn "Current rules are logged above and in ${DEPLOY_LOG}."
    fi
    # Detect if rules file exists even if UFW is inactive (partial previous run)
    if [[ -f /etc/ufw/user.rules ]] && grep -q 'ACCEPT' /etc/ufw/user.rules 2>/dev/null; then
        PREFLIGHT_UFW_RULES_EXIST=true
    fi

    # ── 4. Podman and image ───────────────────────────────────────────────────
    if command -v podman &>/dev/null; then
        PREFLIGHT_PODMAN_INSTALLED=true
        log "Podman found: $(podman --version)"
        if [[ -n "${AGENT_UID}" ]]; then
            if runuser -u "${AGENT_USER}" -- \
                        env \
                    XDG_RUNTIME_DIR="/run/user/${AGENT_UID}" \
                    podman image exists "${AGENT_IMAGE}" 2>/dev/null; then
                PREFLIGHT_IMAGE_PRESENT=true
                local IMAGE_CREATED
                IMAGE_CREATED=$(runuser -u "${AGENT_USER}" -- \
                        env \
                    XDG_RUNTIME_DIR="/run/user/${AGENT_UID}" \
                    podman image inspect "${AGENT_IMAGE}" \
                    --format '{{.Created}}' 2>/dev/null || echo "unknown")
                log "Agent image already present (created: ${IMAGE_CREATED})."
                log "Image will be re-pulled to check for updates."
                # We do not skip the pull — the image tagged :latest may have changed.
                # If you pin to a digest, you can skip the pull when digest matches.
            fi
        fi
    else
        log "Podman not installed — will be installed."
    fi

    # ── 5. Agent user ─────────────────────────────────────────────────────────
    if [[ -n "${AGENT_UID}" ]]; then
        PREFLIGHT_AGENT_USER_EXISTS=true
        local EXISTING_SHELL
        EXISTING_SHELL=$(getent passwd "${AGENT_USER}" | cut -d: -f7)
        log "Agent user '${AGENT_USER}' exists (UID=${AGENT_UID}, shell=${EXISTING_SHELL})."
        # Validate the shell is nologin — a previous partial run might have
        # created the user with a login shell.
        if [[ "${EXISTING_SHELL}" != "/usr/sbin/nologin" && \
              "${EXISTING_SHELL}" != "/bin/false" ]]; then
            warn "Agent user has a login shell '${EXISTING_SHELL}'. Will be corrected to nologin."
        fi
    else
        log "Agent user '${AGENT_USER}' does not exist — will be created."
    fi

    # ── 6. restic repository ──────────────────────────────────────────────────
    if [[ -f "${RESTIC_PASS}" ]] && \
       RESTIC_PASSWORD_FILE="${RESTIC_PASS}" \
       RESTIC_REPOSITORY="${BACKUP_REPO}" \
       restic snapshots --quiet &>/dev/null; then
        PREFLIGHT_RESTIC_REPO_EXISTS=true
        local SNAP_COUNT
        SNAP_COUNT=$(RESTIC_PASSWORD_FILE="${RESTIC_PASS}" \
            RESTIC_REPOSITORY="${BACKUP_REPO}" \
            restic snapshots --quiet 2>/dev/null | grep -c '^[a-f0-9]\{8\}' || echo "0")
        log "restic repository exists with ${SNAP_COUNT} snapshot(s). Will not reinitialise."
    elif [[ -f "${RESTIC_PASS}" ]] && [[ ! -d "${BACKUP_REPO}" ]]; then
        warn "PARTIAL DEPLOY DETECTED: restic key exists but repository directory is missing."
        PREFLIGHT_PARTIAL_DEPLOY=true
    fi

    # ── 7. AppArmor profile ───────────────────────────────────────────────────
    if aa-status 2>/dev/null | grep -q 'openclaw-agent' || \
       apparmor_parser -L 2>/dev/null | grep -q 'openclaw-agent'; then
        PREFLIGHT_APPARMOR_LOADED=true
        log "AppArmor profile 'openclaw-agent' is already loaded."
    fi

    # ── 8. sshd hardening ────────────────────────────────────────────────────
    if [[ -f /etc/ssh/sshd_config.d/99-hardening.conf ]]; then
        PREFLIGHT_SSHD_HARDENED=true
        log "sshd hardening drop-in already exists."
        # Validate it is syntactically sound — if a previous run wrote a
        # broken config, catch it here before we touch sshd again.
        sshd -t 2>/dev/null \
            || { warn "EXISTING sshd config is INVALID. Will overwrite."; \
                 PREFLIGHT_SSHD_HARDENED=false; }
    fi

    # ── 9. Detect leftover containers from a previous deploy ─────────────────
    # A stopped-but-not-removed container named openclaw_agent means the previous
    # run completed but the service was stopped. The --replace flag in the service
    # handles this, but we log it explicitly so it's not a surprise.
    if [[ -n "${AGENT_UID}" ]]; then
        local DEAD_CONTAINER
        DEAD_CONTAINER=$(runuser -u "${AGENT_USER}" -- \
                env \
            XDG_RUNTIME_DIR="/run/user/${AGENT_UID}" \
            podman ps -a --filter name=openclaw_agent --format '{{.Status}}' 2>/dev/null || true)
        if [[ -n "${DEAD_CONTAINER}" ]]; then
            log "Leftover container found (status: ${DEAD_CONTAINER}). Will be replaced on next start."
        fi
    fi

    # ── 10. Disk space gate ───────────────────────────────────────────────────
    # Refuse to proceed if the root filesystem is already above 85%.
    # A deploy that fills the disk is worse than no deploy.
    local DISK_PCT
    DISK_PCT=$(df / --output=pcent | tail -1 | tr -d ' %')
    if (( DISK_PCT > 85 )); then
        die "Root filesystem is at ${DISK_PCT}% capacity. Free space before deploying. Aborting."
    fi
    log "Root filesystem at ${DISK_PCT}% — OK."

    # ── Summary ───────────────────────────────────────────────────────────────
    log "--- Preflight summary ---"
    log "  Agent running:         ${PREFLIGHT_AGENT_RUNNING}"
    log "  Service exists:        ${PREFLIGHT_AGENT_SERVICE_EXISTS}"
    log "  UFW active:            ${PREFLIGHT_UFW_ACTIVE}"
    log "  Podman installed:      ${PREFLIGHT_PODMAN_INSTALLED}"
    log "  Image present:         ${PREFLIGHT_IMAGE_PRESENT}"
    log "  Agent user exists:     ${PREFLIGHT_AGENT_USER_EXISTS}"
    log "  restic repo exists:    ${PREFLIGHT_RESTIC_REPO_EXISTS}"
    log "  AppArmor loaded:       ${PREFLIGHT_APPARMOR_LOADED}"
    log "  sshd hardened:         ${PREFLIGHT_SSHD_HARDENED}"
    log "  Partial deploy:        ${PREFLIGHT_PARTIAL_DEPLOY}"
    log "--- End preflight ---"

    if [[ "${PREFLIGHT_PARTIAL_DEPLOY}" == "true" ]]; then
        warn "Partial deploy state detected. The script will attempt to reconcile."
        warn "If this is unexpected, investigate before proceeding."
    fi

    log "Preflight complete. Proceeding with deploy in 3 seconds..."
    sleep 3
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
#main() {
#    log "=== OpenClaw v2 Deployment ==="
#    log "Host: $(hostname) | $(. /etc/os-release && echo "${PRETTY_NAME}") | $(uname -r)"
#    log "Operator UID: ${EUID} | Deploy log: ${DEPLOY_LOG}"
#
#    # Order matters:
#    # 1. Harden first (sshd validated before UFW is enabled)
#    # 2. Updates second (idempotent, no service dependency)
#    # 3. Firewall third (SSH validated, then UFW enabled)
#    # 4. Backups fourth (restic install, initial snapshot before agent is running)
#    # 5. Agent last (Podman, AppArmor, service — depends on all of the above)
#    # 6. Verify always
#
#    harden_host
#    config_updates
#    config_firewall
#    config_backups
#    install_agent_runtime
#    config_agent
#    verify
#
#    log "=== Deployment complete: $(date -u) ==="
#}

main() {
    # Podman inherits the script CWD. If run from /home/operator (mode 700),
    # runuser spawns Podman as openclaw which cannot chdir there -> EPERM.
    # All paths in this script are absolute so cd / is safe here.
    cd /

    log "=== OpenClaw v2 Deployment ==="
    log "Host: $(hostname) | $(. /etc/os-release && echo "${PRETTY_NAME}") | $(uname -r)"

    preflight          # read — know what exists

    harden_host        # write
    config_updates
    config_firewall
    config_backups
    install_agent_runtime
    config_agent

    verify             # read — confirm what was written

    log "=== Deployment complete: $(date -u) ==="
}

main "$@"
