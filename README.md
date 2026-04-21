# openclaw-deploy-v2.sh

Hardened deployment script for **OpenClaw** — an autonomous AI agent capable of writing files and executing shell commands — on a ZimaBoard running Ubuntu 24.04 LTS.

The script treats OpenClaw as a semi-hostile workload from first principles. Every design decision assumes the agent may become actively malicious after compromise.

---

## Table of Contents

1. [Hardware Target](#hardware-target)
2. [Threat Model](#threat-model)
3. [What the Script Does](#what-the-script-does)
4. [Security Architecture](#security-architecture)
5. [Prerequisites](#prerequisites)
6. [Installation](#installation)
7. [First Run](#first-run)
8. [Managing the Agent](#managing-the-agent)
9. [Backup and Recovery](#backup-and-recovery)
10. [Verification](#verification)
11. [Known Issues and Fixes](#known-issues-and-fixes)
12. [Operational Runbooks](#operational-runbooks)
13. [Design Decisions and Trade-offs](#design-decisions-and-trade-offs)
14. [Residual Risk](#residual-risk)

---

## Hardware Target

| Component | Spec |
|-----------|------|
| Board | ZimaBoard (Intel Celeron J3455 or N3350) |
| RAM | 8 GB |
| Boot device | 32 GB eMMC — hosts `/boot/efi` only |
| Root device | 1 TB SATA SSD — hosts `/` as ext4 |
| OS | Ubuntu 24.04 LTS Server (minimal install) |

The script is written specifically for this layout. Running it on different hardware requires reviewing the `harden_host()` fstab section and the `SMART_UNIT` detection logic.

---

## Threat Model

The agent is assumed to be capable of and potentially willing to:

- Write arbitrary files to its mounted directories
- Execute shell commands inside the container
- Attempt to fill disk storage to exhaust host capacity
- Modify its own skills or config to persist malicious behaviour across restarts
- Attempt lateral movement to other hosts on the LAN if given network access
- Attempt exfiltration of data from its writable mount
- Fork-bomb the host if process limits are absent
- Exploit kernel namespace vulnerabilities if capability restrictions are absent

The script is **not** designed to stop a determined attacker who has already achieved a kernel-level exploit. It is designed to:

1. Prevent a compromised container from reaching host root
2. Ensure a killed agent cannot self-resume
3. Eliminate all network exfiltration paths
4. Contain resource exhaustion to the agent's cgroup
5. Prevent skill/config poisoning from persisting silently
6. Give the operator a reliable restore point before anything goes wrong

---

## What the Script Does

The script runs eight sequential modules. Each is idempotent — re-running the script is safe and will reconcile state without destroying existing configuration.

### Preflight
Audits the system before making any changes. Detects:
- A running agent (stops it with a 10-second abort window)
- Partial deploys from a previously aborted run
- Existing UFW rules (logs them before reset)
- Existing restic repository (skips reinitialisation)
- Root filesystem above 85% (aborts — a failing deploy that fills the disk is worse than no deploy)

### Module 1 — Host Hardening (`harden_host`)
- Detects the correct SSH unit name (`ssh.service` on Ubuntu 22.04+, `sshd.service` on older)
- Writes an sshd drop-in at `/etc/ssh/sshd_config.d/99-hardening.conf`: no root login, keys only, 3 auth attempts, no TCP forwarding
- Validates sshd config before reloading — a broken config before UFW is enabled is recoverable; after UFW is enabled it is not
- Configures journald with a drop-in at `/etc/systemd/journald.conf.d/50-limits.conf`: 200 MB max, 14-day retention, 5-minute sync interval (reduces SSD write amplification)
- Adds `noatime,commit=60` to the root ext4 mount via fstab and remounts live — `noatime` eliminates atime writes on every file read; `commit=60` flushes the ext4 journal every 60 seconds instead of 5
- Disables services with no purpose: `avahi-daemon`, `cups`, `ModemManager`, `bluetooth`, `multipathd`
- Detects the correct smartmontools unit name and enables it; initiates an immediate SMART short self-test on the root SSD

### Module 2 — Unattended Upgrades (`config_updates`)
- Configures `unattended-upgrades` to apply security updates only
- Sets `Remove-Unused-Kernel-Packages: false` — on remote bare-metal with no IPMI, auto-removing the previous kernel before validating the new one boots is an unrecoverable lockout
- Sets `Automatic-Reboot: false` — kernel updates accumulate until a manual maintenance window
- Suppresses `needrestart` interactive prompts during automated upgrades via apt hook

### Module 3 — Firewall (`config_firewall`)
- Detects the active SSH port from live socket state (`ss -tlnp`)
- Resets UFW to a clean state
- Default deny **inbound and outbound** — then adds explicit allows only
- Outbound allows: DNS (53/udp+tcp), HTTP (80/tcp), HTTPS (443/tcp), NTP (123/udp)
- Inbound: SSH only, rate-limited (`ufw limit`)
- Hard gate: refuses to enable UFW if the SSH rule is not confirmed in the ruleset
- Configures Fail2Ban with a custom `jail.local`: 3 attempts, 5-minute window, 1-hour ban

### Module 4 — Backups (`config_backups`)
- Generates a random restic repository key at `/etc/openclaw/restic.key` (root-only, mode 400)
- Initialises a restic repository at `/opt/backups/restic`
- Writes an exclude file at `/etc/openclaw/restic-excludes.txt` — excludes all container storage, volatile paths, and agent runtime data
- Creates a backup script at `/usr/local/sbin/openclaw-backup`: daily backup, 7-daily/4-weekly retention with immediate prune, 5% integrity check
- Creates a systemd timer (`openclaw-backup.timer`) firing at 03:00 with a 30-minute random delay
- Runs an immediate backup to validate configuration

### Module 5 — Rootless Podman (`install_agent_runtime`)
- Installs `podman` and `uidmap` from Ubuntu repos
- Creates the `openclaw` system user with home at `/var/lib/openclaw` and `nologin` shell
- Writes subuid/subgid ranges (`100000:65536`) for rootless namespace mapping
- Enables linger for the agent user so Podman services survive user logout
- Configures Podman storage at `/var/lib/openclaw/.config/containers/storage.conf` with `metacopy=on` to reduce copy-on-write write amplification

### Module 6 — AppArmor (`config_apparmor`)
- Writes a deny-first AppArmor profile to `/etc/apparmor.d/openclaw-agent`
- Denies all network access (belt-and-suspenders over `--network=none`)
- Denies all capabilities independently of Podman's `--cap-drop=all`
- Denies all filesystem access, then allows only: standard libraries, timezone/locale files, tmpfs mounts, `/app/data` (writable), `/app/skills` and `/app/config` (read-only)
- Hard-denies writes to: `/etc/systemd`, `/etc/sudoers`, `/etc/cron*`, `/etc/passwd`, `/var/run/docker.sock`, `/var/run/podman`

### Module 7 — Agent Deployment (`config_agent`)
- Creates directories: `/opt/openclaw/{data,skills,config}`
  - `/opt/openclaw/` — owned by root (agent cannot modify its own deployment)
  - `/opt/openclaw/data/` — owned by `openclaw` (writable runtime output)
  - `/opt/openclaw/skills/` — owned by root (read-only in container)
  - `/opt/openclaw/config/` — owned by root (read-only in container)
- Pulls the agent image as the `openclaw` user into local Podman storage
- Writes a systemd service at `/etc/systemd/system/openclaw-agent.service`
- Enables the service but **does not start it** — the operator must start manually after reviewing verification output

### Module 8 — Verification (`verify`)
Runs 30 post-deploy checks and prints `[PASS]` or `[FAIL]` for each. The agent should not be started until all checks pass. See [Verification](#verification) for the full list.

---

## Security Architecture

### Why Rootless Podman Instead of Docker

With a rootful Docker daemon, a kernel namespace escape gives the attacker host root. With rootless Podman, the daemon does not exist — the container runs as the `openclaw` user. A kernel escape gives the attacker `openclaw`'s UID (999), which has no sudo, no cron, no write access outside `/opt/openclaw/data` and `/var/lib/openclaw`.

### Why `--network=none`

The container has no network interface at all — not even loopback. There is no bridge to restrict, no iptables rule to forget, no DNS to leak through. Exfiltration and C2 are architecturally impossible while this flag is set.

If OpenClaw requires outbound API access, a restricted bridge must be created with explicit `DOCKER-USER` iptables rules before enabling network access. Do not use `--network=bridge` without egress controls.

### Why `Restart=no`

A compromised agent that is killed — by the operator, by OOM, or by a crash triggered by its own malicious behaviour — does not resume automatically. The operator must run `systemctl start openclaw-agent` explicitly. This breaks the assumption that a persistent threat can simply wait out a kill and continue.

### Why `--read-only`

The container root filesystem is immutable. The agent cannot install tools, write cron entries, or create persistence files in the container layer. The only writable persistent path is `/app/data`, which maps to `/opt/openclaw/data` on the host — owned by `openclaw`, no execute bit.

### Why Skills and Config Are Mounted Read-Only

If skills or config are writable and the agent is compromised, it can modify its own behaviour across restarts — new skills that execute on the next invocation, config changes that disable safety filters. Mounting both read-only means the operator controls what the agent can do, not the agent.

### Layered Resource Limits

Resource limits are applied at two independent levels:

| Limit | Podman flag | systemd unit |
|-------|------------|--------------|
| Memory | `--memory=4g` | `MemoryMax=4G` |
| Swap | `--memory-swap=4g` | `MemorySwapMax=0` |
| CPU | `--cpus=1.5` | `CPUQuota=150%` |
| PIDs | `--pids-limit=50` | `TasksMax=100` |

Both layers must be independently bypassed for a resource exhaustion attack to succeed.

---

## Prerequisites

Before running the script:

1. **Ubuntu 24.04 LTS Server** — minimal install. No desktop environment.
2. **SSH key authentication must already be configured.** The script sets `PasswordAuthentication no`. If you do not have a key in `~/.ssh/authorized_keys` before running, you will be locked out when `sshd` reloads.
3. **Root or sudo access** — the script must run as root.
4. **Outbound internet access** — required for `apt-get` and the initial image pull. UFW is configured to allow this; the container is not.
5. **The OpenClaw image must be accessible** at `ghcr.io/openclaw/openclaw:latest` or the `AGENT_IMAGE` constant must be updated before running.

---

## Installation

```bash
# Copy the script to the ZimaBoard
scp openclaw-deploy-v2.sh user@zimaboard:~/

# SSH in
ssh user@zimaboard

# Make executable
chmod +x openclaw-deploy-v2.sh

# Run as root
sudo ./openclaw-deploy-v2.sh
```

The script is non-interactive. It runs all modules in order and exits. Do not pipe it from `curl` — download and inspect first.

---

## First Run

Expected runtime: 3–8 minutes depending on image size and network speed.

Expected output sequence:
```
=== PREFLIGHT: Auditing existing system state ===
...
=== POST-DEPLOY VERIFICATION ===
[PASS] sshd config is valid
[PASS] UFW active
...
All verification checks passed.

To start the agent:  systemctl start openclaw-agent
To watch logs:       journalctl -u openclaw-agent -f
To stop the agent:   systemctl stop openclaw-agent
  (agent will NOT restart automatically — this is intentional)
```

**Do not start the agent until all verification checks pass.**

### Before Starting the Agent

1. Back up the restic key offline:
   ```bash
   sudo cat /etc/openclaw/restic.key
   # Print this or store it in a password manager.
   # Without it, your backups are unreadable.
   ```

2. Populate skills and config:
   ```bash
   # Skills and config are mounted read-only in the container.
   # Populate them as root before starting the agent.
   sudo cp your-skills/* /opt/openclaw/skills/
   sudo cp your-config/* /opt/openclaw/config/
   ```

3. Start the agent:
   ```bash
   sudo systemctl start openclaw-agent
   sudo journalctl -u openclaw-agent -f
   ```

---

## Managing the Agent

### Start
```bash
sudo systemctl start openclaw-agent
```

### Stop
```bash
sudo systemctl stop openclaw-agent
# The agent will NOT restart automatically.
# This is intentional — Restart=no.
```

### Force kill (if stop hangs)
```bash
sudo systemctl kill --signal=SIGKILL openclaw-agent
```

### View logs
```bash
# Live
sudo journalctl -u openclaw-agent -f

# Last 100 lines
sudo journalctl -u openclaw-agent -n 100

# Since last boot
sudo journalctl -u openclaw-agent -b
```

### Check status
```bash
sudo systemctl status openclaw-agent
```

### Update the image
```bash
# Stop the agent
sudo systemctl stop openclaw-agent

# Pull the new image as the openclaw user
cd /
sudo runuser -u openclaw -- env \
    XDG_RUNTIME_DIR="/run/user/$(id -u openclaw)" \
    podman pull ghcr.io/openclaw/openclaw:latest

# Start the agent — it will use the new image
sudo systemctl start openclaw-agent
```

### Update skills or config
Skills and config are read-only inside the container. To update them, stop the agent, modify the files as root, then restart:

```bash
sudo systemctl stop openclaw-agent
sudo cp new-skill.json /opt/openclaw/skills/
sudo systemctl start openclaw-agent
```

### Disable the agent permanently
```bash
sudo systemctl disable --now openclaw-agent
```

---

## Backup and Recovery

### Backup Strategy

| What | Tool | Where | Frequency |
|------|------|--------|-----------|
| OS + config (`/etc`, `/opt/openclaw/skills`, `/opt/openclaw/config`) | restic | `/opt/backups/restic` | Daily at 03:00 |
| Agent runtime data (`/opt/openclaw/data`) | **Not backed up by default** — see note | — | — |
| Container image | Podman local storage | `/var/lib/openclaw` | On pull |

**Agent data note:** `/opt/openclaw/data` is excluded from the restic backup by default. It contains agent runtime output which may be large, fast-changing, and potentially hostile. If this data is operationally important, add a separate restic job or rsync target for it.

### Check backup status
```bash
sudo RESTIC_PASSWORD_FILE=/etc/openclaw/restic.key \
     RESTIC_REPOSITORY=/opt/backups/restic \
     restic snapshots
```

### Run a manual backup
```bash
sudo /usr/local/sbin/openclaw-backup
```

### Restore a snapshot

> Restic does not restore a bootable system. It restores filesystem content. For full bare-metal recovery, reinstall Ubuntu 24.04 first, then restore from restic.

```bash
# List snapshots
sudo RESTIC_PASSWORD_FILE=/etc/openclaw/restic.key \
     RESTIC_REPOSITORY=/opt/backups/restic \
     restic snapshots

# Restore latest snapshot to /
# WARNING: this overwrites live files. Stop all services first.
sudo systemctl stop openclaw-agent
sudo RESTIC_PASSWORD_FILE=/etc/openclaw/restic.key \
     RESTIC_REPOSITORY=/opt/backups/restic \
     restic restore latest --target / \
     --exclude /var/lib/containers \
     --exclude /tmp \
     --exclude /run \
     --exclude /proc \
     --exclude /sys \
     --exclude /dev

# Reload systemd after restoring unit files
sudo systemctl daemon-reload
```

### Backup key loss

If `/etc/openclaw/restic.key` is lost, the restic repository is permanently unreadable. There is no recovery path. This is why the key must be backed up offline at first-run.

---

## Verification

Run the full verification suite at any time:

```bash
# Re-run just the verify module
sudo bash -c '
source ./openclaw-deploy-v2.sh
VERIFY_FAILURES=0
verify
'
```

Or run individual checks manually:

```bash
# SSH hardening
sshd -t && echo "sshd config valid"
grep 'PermitRootLogin no' /etc/ssh/sshd_config.d/99-hardening.conf
grep 'PasswordAuthentication no' /etc/ssh/sshd_config.d/99-hardening.conf

# Firewall
sudo ufw status verbose

# Fail2Ban
sudo fail2ban-client status sshd

# Container security — run after starting the agent
sudo -u openclaw XDG_RUNTIME_DIR=/run/user/$(id -u openclaw) \
    podman inspect openclaw_agent --format \
    'User={{.Config.User}} ReadOnly={{.HostConfig.ReadonlyRootfs}} PidsLimit={{.HostConfig.PidsLimit}}'

# Memory limits
sudo systemctl show openclaw-agent --property MemoryMax,MemorySwapMax

# AppArmor
sudo aa-status | grep openclaw

# Disk usage
df -h /
sudo du -sh /opt/backups/restic /var/lib/openclaw

# Restic integrity
sudo RESTIC_PASSWORD_FILE=/etc/openclaw/restic.key \
     RESTIC_REPOSITORY=/opt/backups/restic \
     restic check

# SSD health
sudo smartctl -H /dev/sda
```

### Reboot validation

After any kernel update or reboot:

```bash
# All critical services should be active
for svc in ssh fail2ban smartmontools openclaw-backup.timer; do
    systemctl is-active "$svc" && echo "OK: $svc" || echo "FAIL: $svc"
done

# UFW should be active
sudo ufw status | grep -q 'Status: active' && echo "UFW: OK" || echo "UFW: FAIL"

# Agent should be enabled but stopped (Restart=no)
systemctl is-enabled openclaw-agent && echo "Agent: enabled" || echo "Agent: not enabled"
systemctl is-active openclaw-agent || echo "Agent: stopped (expected — start manually)"
```

---

## Known Issues and Fixes

### [FAIL] sshd PermitRootLogin=no

The `verify()` check for sshd uses an over-escaped regex that fails inside `bash -c`. The config file is correctly written — only the check is wrong.

Fix the check:

```bash
cat > /tmp/fix_sshd_check.py << 'PYEOF'
with open('openclaw-deploy-v2.sh', 'r') as f:
    src = f.read()

old = """    check "sshd PermitRootLogin=no"           "grep -qE '^\\\\\\\\s*PermitRootLogin\\\\\\\\s+no' /etc/ssh/sshd_config.d/99-hardening.conf\""""
new = '    check "sshd PermitRootLogin=no"           "grep -q \'PermitRootLogin no\' /etc/ssh/sshd_config.d/99-hardening.conf"'

old2 = """    check "sshd PasswordAuthentication=no"    "grep -qE '^\\\\\\\\s*PasswordAuthentication\\\\\\\\s+no' /etc/ssh/sshd_config.d/99-hardening.conf\""""
new2 = '    check "sshd PasswordAuthentication=no"    "grep -q \'PasswordAuthentication no\' /etc/ssh/sshd_config.d/99-hardening.conf"'

changed = 0
for o, n in [(old, new), (old2, new2)]:
    if o in src:
        src = src.replace(o, n)
        changed += 1

# Fallback: find by simpler pattern and show what is actually there
if changed == 0:
    for label in ['PermitRootLogin', 'PasswordAuthentication']:
        idx = src.find(f'check "sshd {label}')
        if idx >= 0:
            print(f"Actual line for {label}:")
            end = src.find('\n', idx)
            print(repr(src[idx:end]))
    print("Manual fix needed — see repr output above.")
else:
    with open('openclaw-deploy-v2.sh', 'w') as f:
        f.write(src)
    print(f"Fixed {changed} check(s).")
PYEOF
python3 /tmp/fix_sshd_check.py
```

Manually verify the config is correct regardless of the check result:

```bash
grep 'PermitRootLogin no' /etc/ssh/sshd_config.d/99-hardening.conf && echo "Config: OK"
```

### `mount: systemd still uses the old version` warning

Cosmetic. The `remount` command succeeds; the warning is from systemd detecting the fstab change. It disappears after the next reboot. No action required.

### `Synchronizing state of smartmontools.service` message

Cosmetic output from `systemd-sysv-install`. The service enables correctly. No action required.

---

## Operational Runbooks

### SSH lockout recovery

If you lose SSH access (e.g. UFW misconfiguration, broken sshd config):

1. Connect a monitor and keyboard to the ZimaBoard directly
2. Log in at the console
3. Fix the issue:
   ```bash
   # Broken sshd config
   sudo sshd -t              # find the error
   sudo nano /etc/ssh/sshd_config.d/99-hardening.conf
   sudo systemctl reload ssh

   # UFW locked out SSH
   sudo ufw allow in 22/tcp
   sudo ufw reload
   ```

### Agent fills disk

```bash
# Check usage
df -h /
du -sh /opt/openclaw/data /var/lib/openclaw /opt/backups/restic

# Stop the agent
sudo systemctl stop openclaw-agent

# Clear agent data if safe to do so
sudo rm -rf /opt/openclaw/data/*

# Prune restic if backup repo is large
sudo RESTIC_PASSWORD_FILE=/etc/openclaw/restic.key \
     RESTIC_REPOSITORY=/opt/backups/restic \
     restic forget --keep-daily 3 --keep-weekly 2 --prune

# Restart
sudo systemctl start openclaw-agent
```

### Suspected agent compromise

```bash
# 1. Kill immediately — Restart=no means it stays dead
sudo systemctl stop openclaw-agent

# 2. Capture state for forensics before touching anything
sudo journalctl -u openclaw-agent -b > /tmp/agent-logs-$(date +%Y%m%d).txt
sudo find /opt/openclaw/data -newer /opt/openclaw/.last-deploy -ls > /tmp/agent-writes-$(date +%Y%m%d).txt 2>/dev/null

# 3. Check for unexpected files in skills or config
# (these are root-owned and not writable by the agent, but verify)
sudo find /opt/openclaw/skills /opt/openclaw/config -newer /etc/systemd/system/openclaw-agent.service

# 4. Review AppArmor denials
sudo journalctl -k | grep apparmor | grep openclaw

# 5. Do NOT restart the agent until the incident is understood
# 6. Restore from a known-good restic snapshot if needed
```

### SSD failure

The SATA SSD is a single point of failure. If it fails:

1. Replace the SSD
2. Boot from a Ubuntu 24.04 live USB
3. Install Ubuntu 24.04 minimal
4. Copy `/etc/openclaw/restic.key` from your offline backup
5. Install restic: `apt-get install -y restic`
6. Restore: `restic -r /path/to/backup restore latest --target /`
7. Re-run `openclaw-deploy-v2.sh` to reconcile any missing state
8. Start the agent

### Kernel update procedure

Automatic reboots are disabled. After `unattended-upgrades` applies a kernel update:

```bash
# Check if a reboot is pending
cat /run/reboot-required 2>/dev/null && echo "Reboot required"

# Verify the new kernel is in the boot menu
grep menuentry /boot/grub/grub.cfg | head -5

# Schedule a maintenance window, then reboot
sudo reboot

# After reboot, verify boot is clean
uname -r                          # confirm new kernel
sudo systemctl status openclaw-agent  # confirm services

# Only after confirming new kernel boots correctly, remove the old one
sudo apt-get autoremove --purge
```

---

## Design Decisions and Trade-offs

| Decision | Chosen | Alternative | Reason for choice |
|----------|--------|-------------|-------------------|
| Container runtime | Rootless Podman | Rootful Docker | Kernel escape → openclaw UID, not host root |
| Network | `--network=none` | Restricted bridge | Zero exfiltration surface; no iptables complexity |
| Restart policy | `Restart=no` | `unless-stopped` | Malicious agent cannot self-resume after kill |
| Backup | restic | Timeshift rsync | Deduplication = lower write amplification; rsync is not crash-consistent on live Docker storage |
| Deployment unit | systemd service | docker-compose.yml | Native cgroup limits; `Restart=no` enforced at kernel level; no compose file the agent might reach |
| Config mount | read-only | read-write | Agent cannot modify its own operating parameters |
| Skills mount | read-only | read-write | Agent cannot poison future runs by writing malicious skills |
| Auto-reboot | disabled | enabled | Remote bare-metal with no IPMI; boot regression = permanent lockout |
| Kernel auto-remove | disabled | enabled | Same reason — previous kernel is the fallback; remove manually after validation |
| SSD write options | `noatime,commit=60` | defaults | Measurable reduction in unnecessary writes on a system managing an AI agent workload |

### `commit=60` trade-off

The ext4 journal flushes every 60 seconds instead of 5. In a hard power loss, up to 60 seconds of filesystem metadata changes may be lost. On a server with restic daily backups and no financial transaction workloads, this is acceptable. If the ZimaBoard is on a UPS, the risk is negligible.

### restic vs Timeshift

Timeshift rsync mode is not crash-consistent. On a system running Podman with active overlay2 writes, a Timeshift snapshot captures a point-in-time where different files are from different moments. Restoring such a snapshot routinely leaves container storage in an inconsistent state. restic is excluded from container storage paths entirely and backs up only what can be consistently restored.

The trade-off is that restic does not restore a bootable system. Recovery requires reinstalling Ubuntu first. This is documented and accepted.

---

## Residual Risk

After full deployment, the following risks remain and cannot be fully eliminated by host-level controls:

**Kernel namespace vulnerabilities.** User namespace remapping (via rootless Podman) raises the bar substantially — a kernel escape gives the attacker `openclaw`'s UID, not root. But kernel exploits exist. The only complete mitigation is VM-level isolation (KVM, gVisor), which is beyond the scope of this hardware.

**Prompt injection.** All host-level hardening limits what the agent can do. It does not prevent the agent from being instructed to do harmful things within its allowed capabilities. The read-only skills and config mounts partially address persistent injection, but the attack surface is intrinsic to an agent that accepts external input and executes commands.

**Image trust.** The script pulls `ghcr.io/openclaw/openclaw:latest` without digest pinning. A compromised upstream image is a full agent-level compromise. In production, pin to a digest and verify signatures:
```bash
# Find the current digest
podman image inspect ghcr.io/openclaw/openclaw:latest \
    --format '{{.Digest}}'

# Update AGENT_IMAGE in the script to pin it:
# ghcr.io/openclaw/openclaw@sha256:abc123...
```

**Physical access.** The ZimaBoard has no Secure Boot, no TPM attestation, and no disk encryption configured by this script. Physical access to the board is full access to all data.

**Single SSD.** There is no RAID, no redundant storage, no automated failover. SSD failure = service outage until manual recovery. Monitor SMART data and replace proactively.
