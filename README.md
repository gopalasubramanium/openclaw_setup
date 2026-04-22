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
8. [First-Use Setup — Making OpenClaw Operational](#first-use-setup--making-openclaw-operational)
9. [Managing the Agent](#managing-the-agent)
10. [Backup and Recovery](#backup-and-recovery)
11. [Verification](#verification)
12. [Known Issues and Fixes](#known-issues-and-fixes)
13. [Operational Runbooks](#operational-runbooks)
14. [Design Decisions and Trade-offs](#design-decisions-and-trade-offs)
15. [Residual Risk](#residual-risk)
16. [Using OpenClaw in This Environment](#using-openclaw-in-this-environment)
17. [Appendix A — OpenClaw CLI Quick Reference](#appendix-a--openclaw-cli-quick-reference)
18. [Appendix B — Daily Operations Cheatsheet](#appendix-b--daily-operations-cheatsheet)
19. [Appendix C — Environment Variables](#appendix-c--environment-variables)
20. [Appendix D — File and Directory Reference](#appendix-d--file-and-directory-reference)

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

### Why `slirp4netns` with restricted egress

The container uses `--network=slirp4netns:allow_host_loopback=false` which gives it a full isolated network stack for port mapping (Gateway WebSocket on 18789, Ollama API on 11434) while preventing it from reaching the host loopback or making arbitrary outbound connections. UFW restricts host-level egress to the Ollama host only.

This replaced the original `--network=none` design because `--network=none` and `-p` port mappings are mutually exclusive in Podman — `--network=none` creates an empty namespace with no interfaces, so the port forwarding layer has nothing to bind to.

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

**Do not start the agent until all verification checks pass. Then continue to the next section before starting anything.**

---

## First-Use Setup — Making OpenClaw Operational

> **Read this before running `systemctl start openclaw-agent`.**

The deploy script builds the security cage. It does **not** install OpenClaw itself. The two layers are deliberately separate:

```
openclaw-deploy-v2.sh   →  host hardening, Podman runtime,
                            systemd service, firewall, backups
                            (the cage)

You do this section     →  Node.js CLI, onboarding, API key,
                            channel config, exec approvals
                            (OpenClaw inside the cage)
```

The container image pulled by the deploy script is the OpenClaw Gateway process. Before it is useful, the **OpenClaw CLI** must be installed and onboarding must run — this is what configures your API key, workspace, and channels. The CLI talks to the Gateway over WebSocket on port 18789.

---

### Step 1 — Install Node.js on the ZimaBoard

The deploy script does not install Node.js. It is required for the OpenClaw CLI.

```bash
# Install Node.js 24 via NodeSource — not Ubuntu's repo (too old)
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
sudo apt-get install -y nodejs

# Verify — must be v24.x
node --version
npm --version
```

---

### Step 2 — Install the OpenClaw CLI

Install as your normal operator user — **not root**, and do not use `sudo`. The system
Node.js installed via NodeSource puts the global prefix at `/usr/lib/node_modules` which
is root-owned. Using `sudo npm install -g` works once but causes permission errors later.
The correct fix is to redirect the global prefix to a directory you own before installing.

```bash
# 1. Create a user-owned directory for npm global packages
mkdir -p ~/.npm-global

# 2. Tell npm to use it as the global prefix
npm config set prefix ~/.npm-global

# 3. Add it to PATH permanently
echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

# 4. Confirm the prefix changed — must show your home directory, not /usr/lib
npm config get prefix
# Expected: /home/gopalasubramanium/.npm-global

# 5. Install OpenClaw (no sudo needed)
npm install -g openclaw@latest

# 6. Also update npm itself if flagged during install
npm install -g npm@latest

# 7. Verify
openclaw --version
```

If `openclaw: command not found` appears after install even with the PATH set, the current
shell did not pick up the `.bashrc` change. Force it:

```bash
export PATH="$HOME/.npm-global/bin:$PATH"
openclaw --version
```

> **Why not `sudo npm install -g`?** It installs the package as root, meaning config
> files, caches, and sockets created during operation are root-owned. When you later run
> `openclaw` as your normal user it hits permission errors on its own files. The user-owned
> prefix approach avoids this entirely.

---

### Step 3 — Start the Gateway container

```bash
sudo systemctl start openclaw-agent

# Confirm it is running
sudo systemctl status openclaw-agent

# Watch until you see the Gateway listening on port 18789
sudo journalctl -u openclaw-agent -f
# Look for a line like: Gateway listening on ws://127.0.0.1:18789
# Ctrl-C to stop following once confirmed
```

---

### Step 4 — Run onboarding

Onboarding is the one-time wizard that configures your model provider API key, workspace, and first channel. Run it pointing at the Gateway that is now running in the container.

```bash
# Connect to the local Gateway running in the container
openclaw onboard --mode remote --remote-url ws://127.0.0.1:18789
```

If running from your **laptop instead of the ZimaBoard**:

```bash
# Replace with your ZimaBoard's actual IP address
openclaw onboard --mode remote --remote-url ws://192.168.1.100:18789
```

The wizard will walk you through:

1. **Security warning** — read it, then confirm to continue
2. **Model provider** — choose Anthropic (Claude), OpenAI, Ollama (local), or another provider
3. **API key** — paste your key for the chosen provider
4. **Channel** — optionally add Telegram (fastest: just a bot token), Slack, Discord, or others. You can skip this and add channels later
5. **Skills** — skip for now; add after confirming basic operation
6. **Hooks** — skip for now
7. **Apply and restart** — select Restart to apply all config

At the end of onboarding, note the **gateway token** shown on screen. You will need it to connect the dashboard from a browser.

---

### Step 5 — Verify the Gateway is live

```bash
# Overall health
openclaw doctor

# Gateway status
openclaw gateway status

# Model provider auth status
openclaw models status

# Everything in one view
openclaw status
```

All checks should be green. If `models status` shows an auth error, re-run:

```bash
openclaw models auth add
```

---

### Step 6 — Send a first message

```bash
# Quickest test — CLI direct
openclaw agent --message "Hello, are you online?"

# With extended thinking
openclaw agent --message "What can you do?" --thinking medium
```

If you set up Telegram during onboarding, open your bot in the Telegram app and send it a message directly — you do not need the CLI for day-to-day use once a channel is configured.

---

### Step 7 — Open the dashboard (optional)

```bash
# On the ZimaBoard itself (requires a browser)
openclaw dashboard
# Opens http://127.0.0.1:18789

# Or from your laptop's browser — navigate to:
# http://192.168.1.100:18789
# Paste the gateway token when prompted
```

---

### Step 8 — Configure exec approvals

By default the agent cannot run any shell commands. Define exactly what it is allowed to execute. Start with the minimum needed for your intended tasks.

```bash
# View current approvals (empty on first run)
openclaw approvals get

# Add safe read-only commands appropriate for document processing tasks
openclaw approvals allowlist add "/usr/bin/ls"
openclaw approvals allowlist add "/usr/bin/cat"
openclaw approvals allowlist add "/usr/bin/find"
openclaw approvals allowlist add "/usr/bin/grep"
openclaw approvals allowlist add "/usr/bin/wc"
openclaw approvals allowlist add "/usr/bin/python3"

# Set security mode to allowlist-only (never use 'full' — allows everything)
openclaw approvals set --file <(echo '{"security":"allowlist"}')

# Verify
openclaw approvals get
```

---

### Step 9 — Back up the restic key

```bash
sudo cat /etc/openclaw/restic.key
```

Print this value or store it in a password manager **before doing anything else**. If this key is lost, the restic backup repository is permanently unreadable. There is no recovery path.

---

### Step 10 — Populate skills and config (if you have them)

Skills and config are mounted read-only in the container. They must be placed as root before or between restarts — the agent cannot write to them.

```bash
# Place skill files
sudo cp your-skill.json /opt/openclaw/skills/
sudo chmod 644 /opt/openclaw/skills/your-skill.json

# Place config
sudo cp your-config.yaml /opt/openclaw/config/config.yaml
sudo chmod 644 /opt/openclaw/config/config.yaml

# Restart to pick up the new files
sudo systemctl restart openclaw-agent
```

---

### The network constraint — critical for API access

The container runs with `--network=none`. The Gateway inside the container **cannot reach your model provider's API** in the default configuration. This means the agent will accept messages but cannot call Claude/GPT/etc to generate responses unless one of these two approaches is used.

**Option A — Enable scoped outbound HTTPS (recommended for cloud API use):**

Follow the [Temporarily Enabling Outbound Network Access](#temporarily-enabling-outbound-network-access) procedure in the Using OpenClaw section, using your API provider's IP. To make it permanent rather than temporary, skip the restore step and leave the restricted bridge in place.

Find your provider's IP:

```bash
# Anthropic
dig +short api.anthropic.com

# OpenAI
dig +short api.openai.com
```

**Option B — Use a local model via Ollama (fully air-gapped, no API cost):**

```bash
# Install Ollama on the ZimaBoard host (outside the container)
curl -fsSL https://ollama.ai/install.sh | sh

# Pull a model (runs on the host, not in the container)
ollama pull llama3.2       # 2 GB — fast, capable
# or
ollama pull mistral        # 4 GB — more capable

# Ollama listens on localhost:11434
# Podman maps the host loopback to a reachable address inside the container
# so --network=none containers can reach host services via host-gateway

# During onboarding, choose 'ollama' as your provider
# The Gateway will call http://host-gateway:11434 automatically
```

Option B is the only fully air-gapped path. Option A requires a deliberate, scoped relaxation of network isolation for the specific API endpoint IP.

---

### First-use completion checklist

```
□  All 30 deploy script verification checks PASS
□  node --version shows v24.x
□  openclaw --version works
□  sudo systemctl start openclaw-agent
□  journalctl confirms Gateway listening on 18789
□  openclaw onboard --mode remote --remote-url ws://127.0.0.1:18789
     □  model provider chosen
     □  API key entered and accepted
     □  optional: Telegram/Slack channel added
□  openclaw doctor — all green
□  openclaw models status — provider authenticated
□  openclaw agent --message "Hello" — receives a reply
□  openclaw approvals allowlist add [commands your tasks need]
□  sudo cat /etc/openclaw/restic.key — KEY BACKED UP OFFLINE
□  Network decision made: cloud API bridge OR local Ollama
```


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

### Gateway takes 90–120 seconds to start on first run

Normal behaviour on the ZimaBoard's Celeron hardware. Node.js JIT compilation of the Gateway bundle takes time on first start. Subsequent starts are faster. Do not attempt to connect the CLI or run onboarding until `curl -s http://127.0.0.1:18789` returns HTTP 200.

### `Error: Cannot find module 'grammy'` when adding Telegram channel

The Telegram extension ships without its `grammy` npm dependency bundled. Fix:

```bash
cd ~/.npm-global/lib/node_modules/openclaw
npm install grammy
# Verify
node -e "require('grammy')" && echo "OK"
# Then retry:
openclaw channels add --channel telegram --token YOUR_BOT_TOKEN
```

### `ENOENT: no such file or directory, mkdir '/app/.openclaw'` on first start

The Gateway needs a writable persistent state directory at `/app/.openclaw` inside the container. This was not mounted in the original service file. The deploy script now creates `/opt/openclaw/state/` and mounts it at `/app/.openclaw:rw,Z`. If you see this error on an existing deploy, create and mount the directory manually:

```bash
sudo systemctl stop openclaw-agent
sudo mkdir -p /opt/openclaw/state
sudo chown 999:989 /opt/openclaw/state
sudo chmod 700 /opt/openclaw/state
# Add to service file ExecStart:
#   --volume /opt/openclaw/state:/app/.openclaw:rw,Z
sudo systemctl daemon-reload
sudo systemctl start openclaw-agent
```

### `--network=none` and `-p` port mapping are mutually exclusive in Podman

`--network=none` creates an empty network namespace with no interfaces — the port forwarding layer has nothing to bind to. The deploy script now uses `--network=slirp4netns:allow_host_loopback=false` which provides an isolated network stack that supports port mapping while preventing arbitrary outbound connections.

### `openclaw onboard` QuickStart switches to Manual for remote gateways

QuickStart mode only supports local gateways. When connecting to a remote Gateway (the container), the wizard automatically switches to Manual mode and only configures the gateway connection. Configure the model provider separately after onboarding:

```bash
# After onboarding completes:
openclaw models auth login --provider ollama
# URL: http://192.168.0.12:11434  (your Ollama host)
openclaw models set ollama/YOUR_MODEL_NAME
openclaw models status
```

### `Error: Pass --to <E.164>, --session-id, or --agent` from `openclaw agent`

The CLI requires an explicit agent target. Always specify `--agent main`:

```bash
openclaw agent --agent main --message "Hello"
```

### Gateway WebSocket 1006 abnormal closure on `openclaw agent`

The Gateway takes 90–120 seconds to start. If you run `openclaw agent` immediately after `systemctl start`, the CLI connects before the Gateway is ready and gets an abnormal closure. Wait for `curl -s http://127.0.0.1:18789` to return HTTP 200, then retry.

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
| Network | `slirp4netns` + UFW | `--network=none` | `--network=none` incompatible with `-p` in Podman; slirp4netns provides isolated stack with port mapping |
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
| Make arbitrary network connections | ⚠ Restricted | `slirp4netns` + UFW — only port 11434 to Ollama host allowed |
| Access the internet | ❌ Blocked | `slirp4netns allow_host_loopback=false` + UFW deny outgoing |
| Call Ollama API (192.168.0.12:11434) | ✅ Allowed | UFW rule + slirp4netns outbound_addr |
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

**Restricted egress network.** The container uses `slirp4netns` with `allow_host_loopback=false` and UFW restricting outbound to port 11434 on the Ollama host only. The agent cannot exfiltrate data to arbitrary destinations. The allowed path (Ollama API) is intentional and scoped.

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
    --network=slirp4netns:allow_host_loopback=false,cidr=10.41.0.0/24 \
    --user 999:989 \
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

---

## Appendix A — OpenClaw CLI Quick Reference

> **Context:** All `openclaw` commands below run **on the host** or from a machine that can reach the Gateway over SSH or WebSocket. They are not run inside the container. The container runs the OpenClaw process; the CLI manages it from outside. On this ZimaBoard deployment, run CLI commands either directly on the board (via SSH) or remotely by pointing `--url` at the Gateway's WebSocket address.
>
> **Installation:** `npm install -g openclaw@latest` (requires Node 22.16+ or Node 24). This is separate from the container image. The CLI is the operator's control plane; the container image is the agent's runtime.

---

### A.1 — Initial Setup and Onboarding

Onboarding is the one-time wizard that configures the Gateway, workspace, auth provider, and first channel. On this ZimaBoard deployment the Gateway runs as a systemd service inside the container; onboarding configures what it connects to and how it authenticates.

```bash
# Guided interactive onboarding — recommended for first-time setup
openclaw onboard

# Quick path — minimal prompts, auto-generates a gateway token
openclaw onboard --flow quickstart

# Full prompts — explicit port, bind address, and auth configuration
openclaw onboard --flow manual

# Connect to a remote Gateway that is already running (e.g. this ZimaBoard)
# Replace the URL with your board's IP or hostname
openclaw onboard --mode remote --remote-url ws://192.168.1.100:18789

# Open the dashboard UI immediately after onboarding (no channel setup needed)
openclaw dashboard
```

**What onboarding does:**
- Creates `~/.openclaw/openclaw.json` — the main config file
- Creates `~/.openclaw/workspace/` — the agent's workspace directory
- Configures the Gateway mode (local or remote)
- Sets up your first auth provider (Anthropic, OpenAI, Ollama, etc.)
- Optionally walks through channel setup (Telegram, Slack, WhatsApp, etc.)

---

### A.2 — Gateway Management

The Gateway is the WebSocket server that routes messages between channels, agents, and nodes. On this ZimaBoard deployment it runs as a systemd service (`openclaw-agent`) rather than as a user-level daemon.

```bash
# Check Gateway service and connection status
openclaw gateway status

# Check Gateway status and probe the live WebSocket connection
openclaw gateway status --probe

# Detailed health probe — checks localhost even if remote is configured
openclaw gateway probe

# Probe a remote Gateway over SSH (board's IP)
openclaw gateway probe --ssh user@192.168.1.100

# Start / stop / restart the Gateway user service
# (On this ZimaBoard, use systemctl instead — see Managing the Agent)
openclaw gateway start
openclaw gateway stop
openclaw gateway restart

# Install the Gateway as a persistent user service (launchd on macOS, systemd on Linux)
openclaw gateway install

# View live Gateway logs
openclaw logs --tail

# Low-level: call a Gateway RPC method directly
openclaw gateway call status
openclaw gateway call logs.tail --params '{"sinceMs": 60000}'

# Discover gateways on the local network via mDNS
openclaw gateway discover
openclaw gateway discover --timeout 4000
```

---

### A.3 — Models and Auth Providers

OpenClaw supports multiple LLM providers simultaneously. The model commands manage which provider and model the agent uses, and handle authentication tokens.

```bash
# Show current default model, fallbacks, and auth status
openclaw models status

# Show model status with live auth probes (makes real requests, may consume tokens)
openclaw models status --probe

# List all available models from configured providers
openclaw models list

# Scan for available models from all configured providers
openclaw models scan

# Set the default model
openclaw models set claude-sonnet-4-5                          # Anthropic (default provider)
openclaw models set anthropic/claude-opus-4-5                  # Explicit provider prefix
openclaw models set openai/gpt-4o                              # OpenAI
openclaw models set openrouter/moonshotai/kimi-k2              # OpenRouter (include provider prefix)
openclaw models set ollama/llama3.2                            # Local Ollama model

# Add a new auth provider interactively
openclaw models auth add

# Log in to a specific provider (OAuth or API key flow)
openclaw models auth login --provider anthropic
openclaw models auth login --provider openai
openclaw models auth login --provider ollama

# Add an API key via setup token (generate with 'claude setup-token' on another machine)
openclaw models auth setup-token

# Paste a token string directly (for automation)
openclaw models auth paste-token

# List configured model aliases
openclaw models aliases list

# Add a shorthand alias for a model
openclaw models aliases add fast openai/gpt-4o-mini
openclaw models aliases add smart anthropic/claude-opus-4-5

# List and manage fallback models (used when primary is unavailable)
openclaw models fallbacks list
openclaw models fallbacks add openai/gpt-4o-mini
openclaw models fallbacks clear
```

---

### A.4 — Agents

An agent is an isolated workspace with its own identity, auth credentials, and channel routing. The default agent is called `main`. Additional agents allow you to run separate personas or task-scoped assistants on the same Gateway.

```bash
# List all configured agents
openclaw agents list

# List agents with their channel bindings
openclaw agents list --bindings

# Add a new agent with its own workspace
openclaw agents add work --workspace ~/.openclaw/workspace-work

# Add a non-interactively (requires --workspace)
openclaw agents add ops \
  --workspace ~/.openclaw/workspace-ops \
  --non-interactive

# Show channel bindings for a specific agent
openclaw agents bindings
openclaw agents bindings --agent work

# Bind an agent to receive messages from a specific channel account
openclaw agents bind --agent work --bind telegram:my-bot-account
openclaw agents bind --agent ops  --bind slack:workspace-name

# Bind multiple channels at once
openclaw agents bind --agent ops \
  --bind telegram:ops-bot \
  --bind discord:guild-a

# Remove a channel binding
openclaw agents unbind --agent work --bind telegram:my-bot-account

# Set agent identity from an IDENTITY.md file in the workspace root
openclaw agents set-identity --workspace ~/.openclaw/workspace --from-identity

# Set agent identity fields explicitly
openclaw agents set-identity --agent main \
  --name "ZimaBot" \
  --emoji "🦞" \
  --avatar avatars/openclaw.png

# Delete an agent and its workspace (moves to Trash, not hard-deleted)
# Interactive confirmation required unless --force is passed
openclaw agents delete work
openclaw agents delete work --force
```

---

### A.5 — Channels

Channels are the messaging platforms OpenClaw connects to — Telegram, Slack, WhatsApp, Discord, Signal, iMessage, and many others. Each channel account is configured separately.

```bash
# List all configured channel accounts and their status
openclaw channels list

# Show runtime status of all channels on the Gateway
openclaw channels status

# Add a Telegram bot
openclaw channels add --channel telegram --token YOUR_BOT_TOKEN

# Add a Slack workspace
openclaw channels add --channel slack

# Add a Discord bot
openclaw channels add --channel discord --token YOUR_BOT_TOKEN

# Add WhatsApp (interactive QR code login)
openclaw channels login --channel whatsapp

# Remove a channel account
openclaw channels remove --channel telegram --delete

# Log out of a channel (keeps config, disconnects session)
openclaw channels logout --channel whatsapp

# View live logs for a specific channel
openclaw channels logs --channel telegram

# View logs for all channels
openclaw channels logs --channel all

# Check what capabilities a channel supports (intents, scopes, features)
openclaw channels capabilities
openclaw channels capabilities --channel discord --target channel:123456789

# Resolve human-readable names to channel IDs
openclaw channels resolve --channel slack "#general" "@jane"
openclaw channels resolve --channel discord "My Server/#support" "@someone"
```

**Channel-specific notes for this ZimaBoard deployment:** Because the container runs with `--network=none`, channel connections are made by the Gateway running on the host (or in a network-enabled configuration), not by the container process itself. If you need live channel connectivity, the Gateway must have network access. See [Temporarily Enabling Outbound Network Access](#temporarily-enabling-outbound-network-access).

---

### A.6 — Device Pairing

Pairing connects external apps or devices — iOS app, Android app, browser companion, other CLI instances — to your Gateway as nodes.

```bash
# List pending pairing requests
openclaw pairing list whatsapp
openclaw pairing list telegram

# Approve a pairing request
# <code> is the pairing code shown in the app or device requesting pairing
openclaw pairing approve whatsapp ABC123

# Approve and send a notification to the paired device when done
openclaw pairing approve telegram ABC123 --notify

# List all paired nodes (devices)
openclaw nodes list

# List only currently-connected nodes
openclaw nodes list --connected

# List nodes that connected within the last 24 hours
openclaw nodes list --last-connected 24h

# Show pending node pairing requests
openclaw nodes pending

# Approve a node pairing request by requestId
openclaw nodes approve <requestId>

# Show node connection status
openclaw nodes status
openclaw nodes status --connected
```

---

### A.7 — Skills

Skills extend what the agent can do — they define tools, workflows, and capabilities the agent can invoke. Skills live in the workspace and can be installed from ClawHub (the community skill registry) or written locally.

```bash
# List all skills (bundled + workspace + managed)
openclaw skills list

# List only eligible skills (requirements met on this system)
openclaw skills list --eligible

# Show detailed info about a specific skill
openclaw skills info <skill-name>
openclaw skills info file-manager
openclaw skills info web-search

# Check skill requirements and flag any that are missing dependencies
openclaw skills check

# Install a skill from ClawHub
# Skills installed this way are placed in the workspace skills directory
openclaw plugins install clawhub:<skill-name>

# Update a specific plugin/skill
openclaw plugins update <skill-id>

# Update all installed plugins
openclaw plugins update --all
```

**In this deployment:** Because skills are mounted read-only into the container (`/app/skills:ro`), the agent cannot self-install skills at runtime. To install a new skill:

```bash
# 1. Install the skill on the host as root
sudo openclaw skills install clawhub:web-search   # if CLI is installed on the host
# OR copy skill files manually:
sudo cp -r ~/my-skill/ /opt/openclaw/skills/my-skill/
sudo chmod -R 644 /opt/openclaw/skills/my-skill/

# 2. Restart the agent to pick up the new skill
sudo systemctl restart openclaw-agent
```

---

### A.8 — Plugins

Plugins extend the Gateway itself — they add new providers, channels, memory engines, and tool integrations. Unlike skills (which extend the agent), plugins run in-process with the Gateway.

```bash
# List all plugins (bundled + installed)
openclaw plugins list

# Show detailed info about a plugin
openclaw plugins info <plugin-id>

# Enable a bundled plugin (bundled plugins ship disabled)
openclaw plugins enable memory-core
openclaw plugins enable voice-elevenlabs
openclaw plugins enable browser-puppeteer

# Disable a plugin
openclaw plugins disable voice-elevenlabs

# Install a plugin from a path or npm spec
openclaw plugins install ./my-local-plugin
openclaw plugins install clawhub:my-plugin
openclaw plugins install my-plugin@1.2.3

# Install and link a local plugin without copying (for development)
openclaw plugins install --link ./my-plugin

# Check for plugin load errors
openclaw plugins doctor

# Update a specific plugin
openclaw plugins update <plugin-id>

# Update all plugins
openclaw plugins update --all

# Dry-run update (show what would change)
openclaw plugins update <plugin-id> --dry-run
```

---

### A.9 — Approvals

Approvals control which shell commands and programs the agent is allowed to execute. This is the primary safety gate for exec-capable operation. The allowlist defines pre-approved commands that do not require interactive confirmation; everything else is denied or prompted.

```bash
# View the current approvals config (local disk)
openclaw approvals get

# View approvals for a specific node
openclaw approvals get --node zimaboard

# View approvals on the Gateway
openclaw approvals get --gateway

# Replace the full approvals config from a file
openclaw approvals set --file ./exec-approvals.json
openclaw approvals set --gateway --file ./exec-approvals.json
openclaw approvals set --node zimaboard --file ./exec-approvals.json

# Add a specific command to the allowlist
openclaw approvals allowlist add "/usr/bin/git"
openclaw approvals allowlist add "/usr/bin/python3"
openclaw approvals allowlist add "~/Projects/**/bin/rg"

# Add a command to the allowlist for all agents on a specific node
openclaw approvals allowlist add \
  --agent "*" \
  --node zimaboard \
  "/usr/bin/uptime"

# Add a command scoped to a single agent
openclaw approvals allowlist add \
  --agent main \
  "/usr/local/bin/my-tool"

# Remove a command from the allowlist
openclaw approvals allowlist remove "/usr/bin/git"
```

**Example `exec-approvals.json` structure for a document-processing workflow:**

```json
{
  "allowlist": [
    "/usr/bin/python3",
    "/usr/bin/grep",
    "/usr/bin/find",
    "/usr/bin/wc",
    "/usr/bin/sort",
    "/usr/bin/head",
    "/usr/bin/tail",
    "/usr/bin/cat",
    "/usr/bin/sed",
    "/usr/bin/awk"
  ],
  "security": "allowlist"
}
```

**Security modes:**

| Mode | Behaviour |
|------|-----------|
| `deny` | All exec blocked regardless of allowlist |
| `allowlist` | Only allowlisted commands execute; all others denied |
| `full` | All commands allowed (never use this in production) |

---

### A.10 — Memory

OpenClaw's memory system indexes conversation history, workspace files, and notes into a searchable vector store. The agent uses this to recall past context.

```bash
# Show memory status
openclaw memory status

# Deep probe — checks vector store and embedding model availability
openclaw memory status --deep

# Deep probe with index recheck
openclaw memory status --deep --index

# Trigger a manual re-index
openclaw memory index

# Re-index with verbose output (shows per-phase detail)
openclaw memory index --verbose

# Search memory for a specific topic
openclaw memory search "release checklist"
openclaw memory search "project deadlines Q3"
openclaw memory search "API key configuration"

# Scope memory operations to a specific agent
openclaw memory status --agent main
openclaw memory index --agent ops --verbose
```

---

### A.11 — Scheduled Tasks (Cron)

The Gateway includes a cron scheduler for running recurring agent tasks without operator intervention.

```bash
# List all scheduled cron jobs
openclaw cron list

# Check cron job status and next run times
openclaw cron status

# Add a recurring job (standard cron syntax)
# The message is sent to the agent as a task
openclaw cron add "0 8 * * 1-5" "Summarise overnight email and send digest"
openclaw cron add "0 9 * * 1" "Generate weekly status report"
openclaw cron add "*/30 * * * *" "Check for new tasks in inbox"

# Add a one-shot job at a specific time (auto-deletes after success)
openclaw cron add --at "2026-05-01T09:00:00" "Remind: quarterly review today"

# Add a job and deliver output to a specific channel
openclaw cron add "0 7 * * *" "Morning briefing" \
  --announce \
  --channel telegram \
  --to "123456789"

# Edit an existing job — change delivery target without changing the message
openclaw cron edit <job-id> --announce --channel slack --to "channel:C1234567890"

# Disable delivery for a job (keeps it running, suppresses output)
openclaw cron edit <job-id> --no-deliver

# Enable a disabled job
openclaw cron enable <job-id>

# Disable a job without deleting it
openclaw cron disable <job-id>

# Remove a job
openclaw cron rm <job-id>

# View recent cron run history
openclaw cron runs
```

---

### A.12 — Sessions

Sessions are conversation threads. Each channel message starts or continues a session. Managing sessions lets you review history, resume conversations, or clean up stale threads.

```bash
# List all stored sessions
openclaw sessions

# List sessions active within the last 2 hours
openclaw sessions --active 120

# Output in JSON for scripting
openclaw sessions --json

# Send a message to an existing session (continue a conversation)
openclaw agent --session-id <id> --message "Continue where we left off"

# Start a new session with a specific agent
openclaw agent --agent ops --message "Start a new task"

# Send a message and deliver the reply to a channel
openclaw agent --agent ops \
  --message "Generate weekly report" \
  --deliver \
  --reply-channel slack \
  --reply-to "#reports"

# Send a message with extended thinking enabled
openclaw agent --agent main \
  --message "Analyse this problem thoroughly" \
  --thinking medium

# Force local execution (skip Gateway, run embedded)
openclaw agent --agent main --message "Run this locally" --local
```

---

### A.13 — Diagnostics and Health

```bash
# Run all health checks
openclaw doctor

# Run health checks and attempt automatic repairs
openclaw doctor --repair

# Deep health check including channel probes
openclaw doctor --deep

# Show overall system status
openclaw status

# Deep status probe across all subsystems
openclaw status --deep

# View live gateway logs
openclaw logs --tail

# View logs for the last N minutes
openclaw logs --since 30m

# View logs in JSON format (for log aggregation)
openclaw logs --json

# Check for available OpenClaw updates
openclaw update --check

# Update OpenClaw to the latest version
openclaw update
```

---

### A.14 — Config Management

```bash
# View the full config
openclaw config get

# Get a specific config key
openclaw config get gateway.port
openclaw config get agents.list

# Set a config value
openclaw config set gateway.port 18789
openclaw config set gateway.bind lan

# Unset a config key (revert to default)
openclaw config unset gateway.bind

# Run the interactive configuration wizard
openclaw configure
```

---

## Appendix B — Daily Operations Cheatsheet

A condensed reference for the most common daily operations on this ZimaBoard deployment.

### Morning Check

```bash
# Is the agent running?
sudo systemctl status openclaw-agent

# Any errors in the last 12 hours?
sudo journalctl -u openclaw-agent --since "12 hours ago" | grep -i 'error\|fatal\|warn'

# Disk usage OK?
df -h /
du -sh /opt/openclaw/data /opt/backups/restic

# Is the backup current?
sudo RESTIC_PASSWORD_FILE=/etc/openclaw/restic.key \
     RESTIC_REPOSITORY=/opt/backups/restic \
     restic snapshots | tail -3

# Gateway reachable?
openclaw gateway health --url ws://localhost:18789
```

### Starting a Task

```bash
# Place input
sudo cp ~/my-input.txt /opt/openclaw/data/
sudo chown openclaw:openclaw /opt/openclaw/data/my-input.txt

# Start
sudo systemctl start openclaw-agent

# Watch
sudo journalctl -u openclaw-agent -f
```

### After a Task

```bash
# Collect output
ls /opt/openclaw/data/
cp /opt/openclaw/data/output.md ~/results/

# Stop the agent (Restart=no means it may already be stopped)
sudo systemctl stop openclaw-agent

# Clean data dir for next run
sudo rm -f /opt/openclaw/data/input.txt /opt/openclaw/data/output.md
```

### Updating Skills or Config

```bash
# Stop agent
sudo systemctl stop openclaw-agent

# Update as root (skills and config are root-owned)
sudo cp ~/new-skill.json /opt/openclaw/skills/
sudo cp ~/updated-config.yaml /opt/openclaw/config/config.yaml

# Commit to git for audit trail
sudo git -C /opt/openclaw add skills/ config/
sudo git -C /opt/openclaw commit -m "Update skills and config $(date +%Y%m%d)"

# Start
sudo systemctl start openclaw-agent
```

### Security Posture Check

```bash
grep -q 'network=none'   /etc/systemd/system/openclaw-agent.service && echo "OK: network=none"     || echo "WARN: check network"
grep -q 'skills.*:ro'    /etc/systemd/system/openclaw-agent.service && echo "OK: skills read-only" || echo "WARN: skills writable"
grep -q 'config.*:ro'    /etc/systemd/system/openclaw-agent.service && echo "OK: config read-only" || echo "WARN: config writable"
grep -q 'cap-drop=all'   /etc/systemd/system/openclaw-agent.service && echo "OK: caps dropped"     || echo "WARN: check caps"
[[ ! -d /etc/systemd/system/openclaw-agent.service.d ]] && echo "OK: no overrides" || echo "WARN: overrides active"
sudo aa-status 2>/dev/null | grep -q 'openclaw-agent'                && echo "OK: AppArmor active"  || echo "WARN: check AppArmor"
```

---

## Appendix C — Environment Variables

Key environment variables that affect OpenClaw CLI and Gateway behaviour on this deployment.

| Variable | Purpose | Example |
|----------|---------|---------|
| `OPENCLAW_GATEWAY_TOKEN` | Authenticate CLI commands to the Gateway | Set in `~/.openclaw/openclaw.json` |
| `OPENCLAW_AGENT_DIR` | Override the agent workspace directory | `/var/lib/openclaw/workspace` |
| `OPENCLAW_LOCAL_CHECK` | Enable host-aware checks in dev shells | `1` |
| `OPENCLAW_LIVE_TEST` | Enable live API tests (consumes tokens) | `1` |
| `XDG_RUNTIME_DIR` | Required for rootless Podman | `/run/user/999` |
| `HOME` | Required for rootless Podman user context | `/var/lib/openclaw` |
| `NO_COLOR` | Disable ANSI colour in CLI output | `1` |

These variables are set by the systemd service unit for the container. For CLI invocations on the host, `XDG_RUNTIME_DIR` and `HOME` must be set when calling Podman as the `openclaw` user — this is handled by the `runuser` calls in the deploy script.

---

## Appendix D — File and Directory Reference

| Path | Purpose | Owner | Writable by agent |
|------|---------|-------|------------------|
| `/opt/openclaw/` | Deployment root | root | No |
| `/opt/openclaw/data/` | Agent runtime I/O | openclaw | Yes |
| `/opt/openclaw/state/` | Gateway config, workspace, sessions (`/app/.openclaw`) | openclaw | Yes |
| `/opt/openclaw/skills/` | Skill definitions | root | No (ro mount) |
| `/opt/openclaw/config/` | Agent configuration | root | No (ro mount) |
| `/var/lib/openclaw/` | Agent user home, Podman storage | openclaw | Yes |
| `/var/lib/openclaw/.config/containers/` | Podman storage config | openclaw | Yes |
| `/var/lib/openclaw/.local/share/containers/` | Container image layers | openclaw | Yes |
| `/etc/openclaw/` | Deploy-time config (key, excludes) | root | No |
| `/etc/openclaw/restic.key` | Backup encryption key | root | No |
| `/etc/openclaw/restic-excludes.txt` | Restic exclude list | root | No |
| `/etc/systemd/system/openclaw-agent.service` | Agent systemd unit | root | No |
| `/etc/apparmor.d/openclaw-agent` | AppArmor profile | root | No |
| `/opt/backups/restic/` | Restic backup repository | root | No |
| `/var/log/openclaw-deploy.log` | Deploy script log | root | No |
| `/run/user/999/` | Podman runtime dir (ephemeral) | openclaw | Yes |
| `~/.openclaw/openclaw.json` | CLI/Gateway config (on operator machine) | user | n/a |
| `~/.openclaw/workspace/` | Agent workspace (on operator machine) | user | n/a |
| `~/.openclaw/exec-approvals.json` | Exec approvals (on operator machine) | user | n/a |
