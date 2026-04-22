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
15. [Using OpenClaw in This Environment](#using-openclaw-in-this-environment)

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

---

## Using OpenClaw in This Environment

This section covers practical use of OpenClaw inside this hardened deployment — from first interaction to advanced operational patterns, including how to temporarily adjust the security posture for specific tasks and how to restore it afterwards.

---

### What OpenClaw Can and Cannot Do Here

Before working with the agent, understand the hard boundaries the deployment enforces. These are not soft defaults — they are enforced at multiple independent layers (Podman, systemd cgroup, AppArmor) and cannot be circumvented from inside the container.

| Capability | Status | Enforced by |
|------------|--------|-------------|
| Read files from `/app/data` | ✅ Allowed | Volume mount |
| Write files to `/app/data` | ✅ Allowed | Volume mount, AppArmor |
| Read skills from `/app/skills` | ✅ Allowed | Volume mount (ro) |
| Read config from `/app/config` | ✅ Allowed | Volume mount (ro) |
| Execute shell commands | ✅ Allowed (inside container only) | — |
| Write to `/app/skills` or `/app/config` | ❌ Blocked | ro mount + AppArmor |
| Make any network connection | ❌ Blocked | `--network=none` + AppArmor |
| Access the internet | ❌ Blocked | `--network=none` |
| Call external APIs | ❌ Blocked | `--network=none` |
| Restart itself after a crash | ❌ Blocked | `Restart=no` in systemd |
| Use more than 4 GB RAM | ❌ Blocked | Podman + systemd cgroup |
| Spawn more than 50 processes | ❌ Blocked | Podman + systemd cgroup |
| Use more than 1.5 CPU cores | ❌ Blocked | Podman + systemd cgroup |
| Modify its own container image | ❌ Blocked | `--read-only` |
| Access host filesystem | ❌ Blocked | Namespace isolation + AppArmor |
| Access Docker/Podman socket | ❌ Blocked | AppArmor hard-deny |

Understanding this table before designing tasks for the agent will save significant debugging time. Tasks that assume outbound connectivity, large memory, or writable config will silently fail or produce confusing errors inside the container.

---

### Basic Usage

#### Giving the Agent Input

OpenClaw reads its operating context from the mounted directories. The primary input mechanisms are:

**Placing files in `/opt/openclaw/data/`** — this is the agent's writable working directory. Files placed here before starting the agent are immediately readable.

```bash
# Place a document for the agent to process
sudo cp ~/my-document.txt /opt/openclaw/data/input.txt
sudo chown openclaw:openclaw /opt/openclaw/data/input.txt

# Start the agent
sudo systemctl start openclaw-agent

# Watch it work
sudo journalctl -u openclaw-agent -f
```

**Placing skills in `/opt/openclaw/skills/`** — skills define what the agent can do. These must be placed as root before starting; the agent cannot modify them.

```bash
# Install a new skill
sudo cp ~/my-skill.json /opt/openclaw/skills/
sudo chmod 644 /opt/openclaw/skills/my-skill.json
# Restart required for new skills to be loaded
sudo systemctl restart openclaw-agent
```

**Placing config in `/opt/openclaw/config/`** — configuration controls the agent's operating parameters: model settings, system prompts, safety filters.

```bash
# Update agent configuration
sudo cp ~/agent-config.yaml /opt/openclaw/config/config.yaml
sudo chmod 644 /opt/openclaw/config/config.yaml
sudo systemctl restart openclaw-agent
```

#### Reading Agent Output

```bash
# Read files the agent wrote
ls -la /opt/openclaw/data/
cat /opt/openclaw/data/output.txt

# Read agent logs
sudo journalctl -u openclaw-agent -n 200 --no-pager

# Live log stream during a task
sudo journalctl -u openclaw-agent -f

# All logs since last start
sudo journalctl -u openclaw-agent -b
```

#### Starting and Stopping a Task

```bash
# Start a task run
sudo systemctl start openclaw-agent

# Stop when task is complete
sudo systemctl stop openclaw-agent

# Check exit code — 0 = clean exit, non-zero = crash or error
systemctl show openclaw-agent --property ExecMainStatus
```

#### Cleaning Up Between Runs

Because the container is `--read-only`, nothing persists inside the container across runs. Only `/opt/openclaw/data/` accumulates state. Clean it selectively:

```bash
# Remove only output files, keep inputs
sudo find /opt/openclaw/data -name 'output*' -delete

# Full clean of data directory
sudo rm -rf /opt/openclaw/data/*
sudo chown openclaw:openclaw /opt/openclaw/data
```

---

### Intermediate Usage

#### Running the Agent Against a Batch of Files

```bash
# Stage a batch of input files
sudo mkdir -p /opt/openclaw/data/batch-$(date +%Y%m%d)
sudo cp ~/documents/*.pdf /opt/openclaw/data/batch-$(date +%Y%m%d)/
sudo chown -R openclaw:openclaw /opt/openclaw/data/batch-$(date +%Y%m%d)

# Write a task manifest the agent will read
cat << 'EOF' | sudo tee /opt/openclaw/data/task.json
{
  "task": "summarise",
  "input_dir": "/app/data/batch-20260421",
  "output_dir": "/app/data/results",
  "format": "markdown"
}
EOF
sudo chown openclaw:openclaw /opt/openclaw/data/task.json

# Run
sudo systemctl start openclaw-agent

# Wait for completion
while systemctl is-active --quiet openclaw-agent; do sleep 5; done
echo "Agent finished. Exit: $(systemctl show openclaw-agent --property ExecMainStatus)"

# Collect results
ls /opt/openclaw/data/results/
```

#### Monitoring Resource Usage During a Task

```bash
# Watch CPU and memory usage of the agent cgroup in real time
systemd-cgtop /system.slice/openclaw-agent.service

# One-shot resource snapshot
systemctl show openclaw-agent \
  --property MemoryCurrent,CPUUsageNSec,TasksCurrent

# Container-level view (run as openclaw user context)
sudo runuser -u openclaw -- \
  env XDG_RUNTIME_DIR=/run/user/$(id -u openclaw) \
  podman stats openclaw_agent --no-stream
```

#### Inspecting the Agent's Filesystem View

Useful for debugging why a task cannot find a file, or verifying mounts are correct before a run.

```bash
# List what the agent can see at /app
sudo runuser -u openclaw -- \
  env XDG_RUNTIME_DIR=/run/user/$(id -u openclaw) \
  podman exec openclaw_agent ls -la /app/

# Verify the agent's identity inside the container
sudo runuser -u openclaw -- \
  env XDG_RUNTIME_DIR=/run/user/$(id -u openclaw) \
  podman exec openclaw_agent id

# Verify network is truly absent
sudo runuser -u openclaw -- \
  env XDG_RUNTIME_DIR=/run/user/$(id -u openclaw) \
  podman exec openclaw_agent ip addr
# Expected: only 'lo' if --network=none is not fully applied,
# or 'RTNETLINK answers: Operation not permitted' — both are correct
```

#### Preserving a Task Run for Audit

```bash
# Before starting: record current state of data dir
sudo find /opt/openclaw/data -type f | sort > /tmp/pre-run-manifest.txt

# After the run: record what changed
sudo find /opt/openclaw/data -type f | sort > /tmp/post-run-manifest.txt
diff /tmp/pre-run-manifest.txt /tmp/post-run-manifest.txt

# Archive the run
sudo tar -czf /opt/backups/run-$(date +%Y%m%d-%H%M).tar.gz \
  /opt/openclaw/data \
  /var/log/openclaw-deploy.log
sudo journalctl -u openclaw-agent -b --no-pager > \
  /opt/backups/agent-log-$(date +%Y%m%d-%H%M).txt
```

---

### Advanced Usage

#### Running Multiple Sequential Tasks Without Full Restart

The container is ephemeral — each `systemctl start` launches a fresh container with the same immutable image. This is a feature, not a limitation: you get a clean execution environment every time without rebuilding anything.

```bash
# Pattern: stage → start → wait → collect → clean → repeat
for task in task1.json task2.json task3.json; do
  echo "--- Running ${task} ---"

  # Stage this task's input
  sudo cp ~/tasks/"${task}" /opt/openclaw/data/task.json
  sudo chown openclaw:openclaw /opt/openclaw/data/task.json

  # Run
  sudo systemctl start openclaw-agent

  # Wait for container to exit (Restart=no means it will not linger)
  while systemctl is-active --quiet openclaw-agent; do sleep 3; done

  # Collect output
  sudo cp /opt/openclaw/data/output.json \
    ~/results/"${task%.json}-output.json" 2>/dev/null || true

  # Log the exit status
  STATUS=$(systemctl show openclaw-agent --property ExecMainStatus | cut -d= -f2)
  echo "Exit status: ${STATUS}"

  # Clean up data for next run (preserves skills and config)
  sudo rm -f /opt/openclaw/data/task.json /opt/openclaw/data/output.json
done
```

#### Passing Secrets to the Agent Safely

The agent has no network access and cannot call a secrets manager. The correct pattern is to write secrets into `/opt/openclaw/data/` immediately before a run and remove them immediately after. Never write secrets into `skills/` or `config/` — those are backed up by restic.

```bash
# Write secret just before the run
echo "sk-..." | sudo tee /opt/openclaw/data/.api-key > /dev/null
sudo chmod 600 /opt/openclaw/data/.api-key
sudo chown openclaw:openclaw /opt/openclaw/data/.api-key

# Start the agent
sudo systemctl start openclaw-agent

# Wait for completion
while systemctl is-active --quiet openclaw-agent; do sleep 3; done

# Remove the secret immediately — do not leave it in the data dir
sudo rm -f /opt/openclaw/data/.api-key

# Verify it is gone
ls -la /opt/openclaw/data/.api-key 2>&1
```

**Important:** `/opt/openclaw/data/` is excluded from restic backups by default, so secrets written here are not leaked into the backup repository. If you change the exclude list, re-check this.

#### Versioning Skills and Config with Git

Skills and config are root-owned and read-only in the container. Tracking them with git gives you rollback, audit history, and a clear deployment process.

```bash
# Initialise git tracking for skills and config
sudo git -C /opt/openclaw init
sudo git -C /opt/openclaw add skills/ config/
sudo git -C /opt/openclaw commit -m "Initial skills and config"

# Deploy a new skill version
sudo cp ~/new-skill.json /opt/openclaw/skills/
sudo git -C /opt/openclaw add skills/new-skill.json
sudo git -C /opt/openclaw commit -m "Add new-skill v1.0"
sudo systemctl restart openclaw-agent

# Roll back to the previous version if the new skill misbehaves
sudo systemctl stop openclaw-agent
sudo git -C /opt/openclaw revert HEAD --no-edit
sudo systemctl start openclaw-agent
```

#### Limiting the Agent to Specific Input Files Only

By default the agent can read anything placed in `/opt/openclaw/data/`. For sensitive tasks where you want to restrict what the agent can see, create a subdirectory with restrictive permissions and only mount that.

Modify the service's volume mount to a subdirectory:

```bash
sudo systemctl stop openclaw-agent

# Edit the service file
sudo nano /etc/systemd/system/openclaw-agent.service
# Change:
#   --volume /opt/openclaw/data:/app/data:rw,Z
# To:
#   --volume /opt/openclaw/data/task-20260421:/app/data:rw,Z

sudo systemctl daemon-reload

# Create the restricted task directory
sudo mkdir -p /opt/openclaw/data/task-20260421
sudo chown openclaw:openclaw /opt/openclaw/data/task-20260421
sudo cp ~/specific-files/* /opt/openclaw/data/task-20260421/

sudo systemctl start openclaw-agent
```

Restore the general mount after the task is complete.

---

### Benefits in This Environment

**Repeatable execution.** The container image is immutable and the container filesystem is read-only. Every run starts from an identical state. Behaviour differences between runs are caused by inputs, not by accumulated container state.

**Bounded blast radius.** Even if the agent produces catastrophic output — filling `/opt/openclaw/data/`, exhausting CPU, generating malicious files — the damage is contained to that directory and that cgroup. The host, other services, and the network are unaffected.

**Forensic clarity.** Because the agent cannot modify its own skills, config, or container layer, any unexpected behaviour can be traced to: the input it received, the skill it executed, or the image it ran. There are no hidden state changes accumulating silently.

**Clean separation of concerns.** The operator controls what the agent can do (skills), how it operates (config), and what it can read/write (data mounts). The agent controls nothing about its own deployment.

**No credential leakage via network.** With `--network=none`, the agent cannot exfiltrate API keys, data, or findings regardless of what it is prompted to do. This is architecturally enforced, not policy-enforced.

**Zero-cost rollback.** If a skill or config change causes bad behaviour, `git revert` and `systemctl restart` restore the previous state in seconds.

---

### Challenges and Limitations

#### No Outbound Network Access by Default

This is the most significant operational constraint. Any OpenClaw capability that requires calling an external API — LLM inference endpoints, web search, tool APIs — is blocked. The agent is effectively air-gapped.

**Mitigation patterns:**

- Pre-fetch data and place it in `/opt/openclaw/data/` before the run
- Run the agent as a pure local processor (document analysis, code generation, file transformation) that does not require live API calls
- For tasks requiring API access, see [Temporarily Enabling Network Access](#temporarily-enabling-outbound-network-access)

#### Read-Only Skills and Config

The agent cannot improve or modify its own skills at runtime. This blocks self-improvement loops and any workflow where the agent is expected to write back to its own knowledge base.

**Mitigation:** Implement a human-in-the-loop update process — the agent writes proposed skill updates to `/opt/openclaw/data/proposed-skills/`, an operator reviews and approves them, then copies approved updates to `/opt/openclaw/skills/` as root.

#### No Persistent Container State

Each start launches a clean container. Any files the agent writes to the container's own filesystem (not the mounted volumes) are lost when the container exits. This catches developers who are used to Docker workflows where containers accumulate state.

**Mitigation:** Everything that must persist must be written to `/app/data` (maps to `/opt/openclaw/data/`). Structure the agent's output to always write results to `/app/data/` explicitly.

#### Memory Cap at 4 GB

For large document processing, embedding generation, or local model inference, 4 GB may be insufficient. The cap is enforced at both Podman and systemd cgroup layers.

**Mitigation options:**

```bash
# Temporarily raise the limit for a specific large task
# (restore afterwards — see safe procedures below)
sudo systemctl stop openclaw-agent
sudo systemctl set-property openclaw-agent MemoryMax=6G
sudo systemctl start openclaw-agent
# After the task:
sudo systemctl stop openclaw-agent
sudo systemctl set-property openclaw-agent MemoryMax=4G
```

Note: `systemctl set-property` writes a drop-in override file. The service file itself is unchanged. Remove the override with:

```bash
sudo rm -rf /etc/systemd/system/openclaw-agent.service.d/
sudo systemctl daemon-reload
```

#### CPU Quota at 1.5 Cores

On the 2-core Celeron N3350 variant of the ZimaBoard, 1.5 cores is 75% of total CPU. The host remains responsive but the agent cannot burst. Long-running inference tasks will be noticeably slower than on a higher-core count host.

**On the 4-core J3455:** 1.5 cores is 37.5% of available CPU — conservative and appropriate for a background agent.

#### PID Limit of 50

Some agent workloads spawn many short-lived subprocesses (e.g. running shell commands in parallel). 50 PIDs including threads is tight. If the agent fails with `fork: retry: Resource temporarily unavailable`, this is the cause.

**Temporary increase:**

```bash
sudo systemctl stop openclaw-agent
sudo systemctl set-property openclaw-agent TasksMax=200
# Also update the Podman flag in the service file:
sudo sed -i 's/--pids-limit=50/--pids-limit=150/' \
    /etc/systemd/system/openclaw-agent.service
sudo systemctl daemon-reload
sudo systemctl start openclaw-agent
# Restore after task:
sudo systemctl stop openclaw-agent
sudo rm -rf /etc/systemd/system/openclaw-agent.service.d/
sudo sed -i 's/--pids-limit=150/--pids-limit=50/' \
    /etc/systemd/system/openclaw-agent.service
sudo systemctl daemon-reload
```

---

### Temporarily Adjusting the Security Posture

This section covers common scenarios where a security control needs to be relaxed temporarily for a specific task, with exact commands to relax it and exact commands to restore it. Every relaxation should be treated as a maintenance window: stop the agent first, make the change, run the task, restore, verify.

**The fundamental rule:** document every change before making it, restore it before starting the next unrelated task, and verify the restore with the verification suite.

---

#### Temporarily Enabling Outbound Network Access

**When:** The agent needs to call an external API (LLM endpoint, web search, tool API) for a specific task.

**Risk:** The agent gains the ability to exfiltrate data from `/opt/openclaw/data/`, call C2 infrastructure if compromised, and make arbitrary outbound connections. Limit this window to the minimum time needed.

**Procedure:**

```bash
# 1. Stop the agent
sudo systemctl stop openclaw-agent

# 2. Create a restricted bridge network for the agent
#    --internal=false allows external routing
#    --subnet defines the agent's IP range
sudo podman network create \
  --driver bridge \
  --subnet 172.30.0.0/29 \
  openclaw-restricted

# 3. Add iptables rules to restrict what the bridge can reach.
#    Allow ONLY the specific API endpoints the agent needs.
#    Replace 1.2.3.4 with the actual IP of the API endpoint.
#    Use 'host api.example.com' or 'dig +short api.example.com' to resolve first.
API_IP="1.2.3.4"
sudo iptables -I FORWARD -s 172.30.0.0/29 -d "${API_IP}" -p tcp --dport 443 -j ACCEPT
sudo iptables -I FORWARD -s 172.30.0.0/29 ! -d "${API_IP}" -j DROP
sudo iptables -I FORWARD -s 172.30.0.0/29 -p udp --dport 53 -j ACCEPT

# 4. Edit the service to use the restricted network instead of none
sudo sed -i 's/--network=none/--network=openclaw-restricted/' \
    /etc/systemd/system/openclaw-agent.service
sudo systemctl daemon-reload

# 5. Run the task
sudo systemctl start openclaw-agent

# 6. When done: RESTORE IMMEDIATELY
sudo systemctl stop openclaw-agent

sudo sed -i 's/--network=openclaw-restricted/--network=none/' \
    /etc/systemd/system/openclaw-agent.service
sudo systemctl daemon-reload

# Remove iptables rules
sudo iptables -D FORWARD -s 172.30.0.0/29 -d "${API_IP}" -p tcp --dport 443 -j ACCEPT
sudo iptables -D FORWARD -s 172.30.0.0/29 ! -d "${API_IP}" -j DROP
sudo iptables -D FORWARD -s 172.30.0.0/29 -p udp --dport 53 -j ACCEPT

# Remove the network
sudo podman network rm openclaw-restricted

# 7. Verify network=none is restored
grep 'network=' /etc/systemd/system/openclaw-agent.service
# Expected: --network=none
```

**After restoring network isolation, check for unexpected data in `/opt/openclaw/data/`:**

```bash
sudo find /opt/openclaw/data -newer /tmp/pre-network-task-marker -type f
# Create the marker before the task: sudo touch /tmp/pre-network-task-marker
```

---

#### Temporarily Allowing the Agent to Write Config

**When:** The agent is being used in a supervised self-improvement workflow where an operator reviews and approves proposed config changes.

**Risk:** The agent can modify its own operating parameters — system prompts, safety filters, model settings — on next restart. Changes persist until manually reverted. This is a high-risk relaxation and should only be done in a session where the operator watches every write.

**Safer alternative:** Instead of making config writable, configure the agent to write proposed changes to `/app/data/proposed-config/` and have the operator review and manually promote them.

```bash
# ── SAFER PATTERN (recommended) ──────────────────────────────────────────
# Agent writes proposals to data dir; operator reviews and promotes.

sudo mkdir -p /opt/openclaw/data/proposed-config
sudo chown openclaw:openclaw /opt/openclaw/data/proposed-config

# Instruct the agent (via its task input) to write proposed config updates
# to /app/data/proposed-config/ rather than /app/config/

# After the run, review proposals:
ls /opt/openclaw/data/proposed-config/
cat /opt/openclaw/data/proposed-config/proposed-config.yaml

# If approved, promote manually as root:
sudo cp /opt/openclaw/data/proposed-config/proposed-config.yaml \
    /opt/openclaw/config/config.yaml
sudo systemctl restart openclaw-agent

# ── DIRECT WRITE (use only if absolutely necessary) ───────────────────────
# Stop agent
sudo systemctl stop openclaw-agent

# Temporarily make config writable in the service
sudo sed -i 's|config:/app/config:ro|config:/app/config:rw|' \
    /etc/systemd/system/openclaw-agent.service
sudo systemctl daemon-reload

# Run the supervised session
sudo systemctl start openclaw-agent

# RESTORE IMMEDIATELY after session
sudo systemctl stop openclaw-agent
sudo sed -i 's|config:/app/config:rw|config:/app/config:ro|' \
    /etc/systemd/system/openclaw-agent.service
sudo systemctl daemon-reload

# Verify the change was restored
grep 'config.*:r' /etc/systemd/system/openclaw-agent.service
# Expected: config:/app/config:ro

# Review exactly what the agent wrote to config
sudo git -C /opt/openclaw diff config/
```

---

#### Temporarily Allowing the Agent to Write Skills

**When:** Evaluating a proposed skill from the agent in a sandboxed test run before promoting it to production.

**Recommended pattern:** Never make skills writable in the production service. Instead, create a second test service with a separate skills directory.

```bash
# Create a test skills directory with the current skills as a baseline
sudo cp -r /opt/openclaw/skills /opt/openclaw/skills-test
sudo chown -R openclaw:openclaw /opt/openclaw/skills-test

# Create a test data directory
sudo mkdir -p /opt/openclaw/data-test
sudo chown openclaw:openclaw /opt/openclaw/data-test

# Write a test service (do not modify the production service)
sudo cat > /etc/systemd/system/openclaw-agent-test.service << 'EOF'
# TEST SERVICE — for skill development only. DO NOT enable in production.
# Differences from production: skills mount is rw, separate data dir.
[Unit]
Description=OpenClaw Agent TEST (skill development)
After=network-online.target

[Service]
Type=simple
User=openclaw
Group=openclaw
Environment=HOME=/var/lib/openclaw
Environment=XDG_RUNTIME_DIR=/run/user/999
MemoryMax=4G
MemorySwapMax=0
CPUQuota=150%
TasksMax=100
Restart=no
StandardOutput=journal
StandardError=journal
SyslogIdentifier=openclaw-agent-test

ExecStart=/usr/bin/podman run \
    --name openclaw_agent_test \
    --rm \
    --replace \
    --network=none \
    --user 999:999 \
    --userns=keep-id \
    --read-only \
    --cap-drop=all \
    --security-opt no-new-privileges=true \
    --memory=4g \
    --memory-swap=4g \
    --pids-limit=50 \
    --init \
    --tmpfs /tmp:noexec,nosuid,nodev,size=128m \
    --tmpfs /run:noexec,nosuid,nodev,size=64m \
    --volume /opt/openclaw/data-test:/app/data:rw,Z \
    --volume /opt/openclaw/skills-test:/app/skills:rw,Z \
    --volume /opt/openclaw/config:/app/config:ro,Z \
    ghcr.io/openclaw/openclaw:latest

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload

# Run the test
sudo systemctl start openclaw-agent-test
sudo journalctl -u openclaw-agent-test -f

# Review what the agent wrote to skills-test
sudo diff -r /opt/openclaw/skills /opt/openclaw/skills-test

# If you approve a proposed skill, promote it to production:
sudo systemctl stop openclaw-agent
sudo cp /opt/openclaw/skills-test/new-skill.json /opt/openclaw/skills/
sudo git -C /opt/openclaw add skills/new-skill.json
sudo git -C /opt/openclaw commit -m "Promote new-skill from test"
sudo systemctl start openclaw-agent

# Clean up the test service when done
sudo systemctl disable --now openclaw-agent-test 2>/dev/null || true
sudo rm /etc/systemd/system/openclaw-agent-test.service
sudo systemctl daemon-reload
```

---

#### Temporarily Raising Memory for a Large Task

**When:** Processing a large document corpus, generating embeddings, or running local inference that exceeds 4 GB.

```bash
# Before: take a snapshot of current limits
systemctl show openclaw-agent --property MemoryMax,MemorySwapMax

# Stop the agent
sudo systemctl stop openclaw-agent

# Raise limit for this task only (writes a drop-in, does not touch the service file)
# On an 8 GB host, 6 GB leaves 2 GB for the OS — do not go higher.
sudo systemctl set-property openclaw-agent MemoryMax=6G MemorySwapMax=0

# Verify the drop-in was written
cat /etc/systemd/system/openclaw-agent.service.d/50-property-MemoryMax.conf

# Run the task
sudo systemctl start openclaw-agent
while systemctl is-active --quiet openclaw-agent; do sleep 5; done

# RESTORE: remove the drop-in
sudo rm -rf /etc/systemd/system/openclaw-agent.service.d/
sudo systemctl daemon-reload

# Verify restored
systemctl show openclaw-agent --property MemoryMax
# Expected: MemoryMax=4294967296 (4 GB in bytes)
```

---

#### Temporarily Disabling AppArmor for Debugging

**When:** Diagnosing whether AppArmor is blocking a legitimate operation. This should be used only in a debugging session, never in production.

```bash
# Check if AppArmor is currently blocking something
sudo journalctl -k | grep -i 'apparmor.*DENIED' | tail -20

# Put the profile into complain mode (logs denials but does not block)
sudo aa-complain /etc/apparmor.d/openclaw-agent
sudo systemctl restart openclaw-agent

# After debugging, review what would have been blocked:
sudo journalctl -k | grep -i 'apparmor.*ALLOW\|apparmor.*audit' | grep openclaw | tail -30

# RESTORE: put the profile back into enforce mode immediately
sudo aa-enforce /etc/apparmor.d/openclaw-agent
sudo systemctl restart openclaw-agent

# Verify enforcement is active
sudo aa-status | grep openclaw-agent
# Expected: 'openclaw-agent' under 'profiles in enforce mode'
```

If complain mode reveals a legitimate path the agent needs, add it to the AppArmor profile rather than leaving the profile in complain mode:

```bash
# Edit the profile to allow the new path
sudo nano /etc/apparmor.d/openclaw-agent
# Add the required allow rule

# Reload the profile
sudo apparmor_parser -r /etc/apparmor.d/openclaw-agent

# Confirm enforce mode
sudo aa-status | grep openclaw-agent
```

---

#### Full Security Posture Verification After Any Temporary Change

After any temporary adjustment, run this before starting the next unrelated task:

```bash
# Verify all critical security controls are in their hardened state
echo "=== Security posture verification ==="

grep -q 'network=none' /etc/systemd/system/openclaw-agent.service \
  && echo "[PASS] network=none" \
  || echo "[FAIL] network not none — RESTORE REQUIRED"

grep -q 'skills.*:ro' /etc/systemd/system/openclaw-agent.service \
  && echo "[PASS] skills read-only" \
  || echo "[FAIL] skills writable — RESTORE REQUIRED"

grep -q 'config.*:ro' /etc/systemd/system/openclaw-agent.service \
  && echo "[PASS] config read-only" \
  || echo "[FAIL] config writable — RESTORE REQUIRED"

grep -q 'cap-drop=all' /etc/systemd/system/openclaw-agent.service \
  && echo "[PASS] cap-drop=all" \
  || echo "[FAIL] capabilities not dropped"

grep -q 'read-only' /etc/systemd/system/openclaw-agent.service \
  && echo "[PASS] read-only filesystem" \
  || echo "[FAIL] container filesystem writable"

[[ ! -d /etc/systemd/system/openclaw-agent.service.d ]] \
  && echo "[PASS] no systemd overrides" \
  || echo "[WARN] systemd overrides present: $(ls /etc/systemd/system/openclaw-agent.service.d/)"

sudo aa-status 2>/dev/null | grep -q 'openclaw-agent' \
  && sudo aa-status | grep -A1 'enforce' | grep -q 'openclaw-agent' \
  && echo "[PASS] AppArmor enforce mode" \
  || echo "[FAIL] AppArmor not enforcing openclaw-agent"

echo "=== End verification ==="
```

---

### Practical Scenarios

#### Scenario 1: One-Shot Document Analysis (No Network Required)

Typical use. The agent reads documents, produces a report, exits.

```bash
sudo cp ~/quarterly-report.pdf /opt/openclaw/data/
sudo chown openclaw:openclaw /opt/openclaw/data/quarterly-report.pdf
sudo systemctl start openclaw-agent
while systemctl is-active --quiet openclaw-agent; do sleep 5; done
cat /opt/openclaw/data/analysis.md
sudo systemctl stop openclaw-agent  # no-op if already exited, but safe to call
```

#### Scenario 2: Supervised Code Generation

The agent generates code. The operator reviews it before it is ever executed.

```bash
# Stage the specification
echo "Write a Python script to parse CSV files in /app/data/input/" \
  | sudo tee /opt/openclaw/data/task.txt > /dev/null
sudo chown openclaw:openclaw /opt/openclaw/data/task.txt

sudo systemctl start openclaw-agent
while systemctl is-active --quiet openclaw-agent; do sleep 5; done

# Review the generated code before running it anywhere
cat /opt/openclaw/data/generated_script.py

# If safe to run, execute it manually (not by the agent)
python3 /opt/openclaw/data/generated_script.py
```

#### Scenario 3: Nightly Batch Processing

Set up a systemd timer to run the agent nightly on new input files.

```bash
cat << 'EOF' | sudo tee /etc/systemd/system/openclaw-nightly.timer
[Unit]
Description=Nightly OpenClaw batch run

[Timer]
OnCalendar=*-*-* 02:00:00
RandomizedDelaySec=600
Persistent=false

[Install]
WantedBy=timers.target
EOF

# The timer starts the agent service directly
# This works because openclaw-agent is already defined as a systemd service
sudo systemctl daemon-reload
sudo systemctl enable --now openclaw-nightly.timer

# Verify the timer is scheduled
systemctl list-timers openclaw-nightly.timer
```

#### Scenario 4: Interactive Debugging Session

When a task is failing and you need to inspect the container environment interactively.

```bash
# Start the container with a shell instead of the default entrypoint
# This overrides the normal agent startup
sudo runuser -u openclaw -- \
  env XDG_RUNTIME_DIR=/run/user/$(id -u openclaw) \
  podman run \
    --rm \
    --interactive \
    --tty \
    --name openclaw_debug \
    --network=none \
    --user $(id -u openclaw):$(id -g openclaw) \
    --userns=keep-id \
    --read-only \
    --cap-drop=all \
    --security-opt no-new-privileges=true \
    --tmpfs /tmp:noexec,nosuid,nodev,size=128m \
    --tmpfs /run:noexec,nosuid,nodev,size=64m \
    --volume /opt/openclaw/data:/app/data:rw,Z \
    --volume /opt/openclaw/skills:/app/skills:ro,Z \
    --volume /opt/openclaw/config:/app/config:ro,Z \
    --entrypoint /bin/sh \
    ghcr.io/openclaw/openclaw:latest

# Inside the container you can inspect:
# ls /app/data /app/skills /app/config
# cat /app/config/config.yaml
# id
# ip addr   (should show no interfaces)
# exit to leave
```

#### Scenario 5: Emergency Stop During a Suspected Compromise

```bash
# Immediate hard kill — SIGKILL bypasses graceful shutdown
sudo systemctl kill --signal=SIGKILL openclaw-agent

# Confirm it is dead
systemctl is-active openclaw-agent
# Expected: inactive

# Lock it from starting again until investigation is complete
sudo systemctl mask openclaw-agent
# This creates a symlink to /dev/null — even manual 'systemctl start' will fail

# Investigate
sudo journalctl -u openclaw-agent -b --no-pager > /tmp/incident-logs.txt
sudo find /opt/openclaw/data -type f -newer /tmp/incident-start-marker -ls

# When ready to restore normal operation
sudo systemctl unmask openclaw-agent
```
