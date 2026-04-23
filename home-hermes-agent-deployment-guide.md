# Hermes Agent Home Deployment Guide (v1)

Replaces the earlier OpenClaw home setup guide.

This version keeps the same home-lab philosophy:
- LAN-first
- GX10 for inference
- ZimaBoard as the always-on gateway host
- NAS mounted into a controlled workspace
- Telegram and Discord as the first messaging channels

It also makes one deliberate architectural change:

**Docker is back.**  
With Hermes, profiles give you separate config, memory, sessions, skills, logs, and gateway state, but they **do not** sandbox filesystem access by themselves. On the default `local` terminal backend, the agent still has the same access as the Unix user running Hermes. For a home setup that may later involve messaging access, Docker isolation is the safer default.

---

## What changed versus the OpenClaw v3 guide

1. **OpenClaw is replaced with Hermes Agent**
   - Hermes installs with the official one-line installer.
   - Node/npm is no longer your primary install path.

2. **Profiles replace OpenClaw’s multi-agent pattern**
   - Hermes profiles are separate homes with their own `config.yaml`, `.env`, `SOUL.md`, memory, sessions, skills, cron jobs, and gateway state.
   - They are excellent for separation of identity and memory.
   - They are **not** a security boundary on their own.

3. **Docker terminal backend is recommended**
   - Commands run in a hardened container instead of directly on the ZimaBoard host.
   - Only the folders you mount are exposed to the agent.

4. **Jetson embeddings host is no longer required on day 1**
   - Keep the Jetson optional for future memory / indexing experiments.
   - The core Hermes deployment below does not depend on it.

---

## Target setup

| Role | Host | IP | Notes |
|---|---|---:|---|
| Hermes gateway host | ZimaBoard Gen1, Ubuntu 24.04 LTS Minimal | `192.168.0.13` | Hermes runs here as a dedicated user |
| Inference LLM | Asus Ascent GX10 | `192.168.0.12` | Ollama serving the main chat model |
| NAS | ZimaOS | `192.168.0.10` | NFS exports mounted read-only and read-write |
| Optional future node | Jetson Orin Nano | `192.168.0.6` | Not required for this guide |

**Networking:** LAN only.  
**Channels (phase 1):** Telegram and Discord.  
**Timezone:** `Asia/Singapore`.

---

## Conventions

| Prefix | Runs on |
|---|---|
| `[zima]$` | ZimaBoard as your admin user |
| `[zima-h]$` | ZimaBoard as the dedicated `hermes` user |
| `[gx10]$` | Asus GX10 |
| plain command | laptop / phone |

Replace placeholders like `<YOUR_USER>`, `<TELEGRAM_USER_ID>`, `<DISCORD_USER_ID>`, and bot tokens with your real values.

---

## Phase 0 — Before you touch anything

If OpenClaw is still running on the same host and using the same Telegram or Discord bot token, **stop it first**. Do not let OpenClaw and Hermes compete for the same bot token.

On the ZimaBoard:
```bash
[zima]$ systemctl --user stop openclaw 2>/dev/null || true
[zima]$ pkill -f openclaw || true
```

Take a simple backup:
```bash
[zima]$ tar czf ~/openclaw-backup-$(date +%F).tgz ~/.openclaw 2>/dev/null || true
```

---

## Phase 1 — Prepare the ZimaBoard

### 1.1 Update and install essentials
```bash
[zima]$ sudo apt update && sudo apt upgrade -y
[zima]$ sudo apt install -y curl git ufw unattended-upgrades nfs-common ca-certificates jq htop nano docker.io
```

### 1.2 Firewall — deny by default, allow LAN SSH
```bash
[zima]$ sudo ufw default deny incoming
[zima]$ sudo ufw default allow outgoing
[zima]$ sudo ufw allow from 192.168.0.0/24 to any port 22 proto tcp comment 'SSH LAN'
[zima]$ sudo ufw enable
[zima]$ sudo ufw status verbose
```

### 1.3 Automatic security updates
```bash
[zima]$ sudo dpkg-reconfigure -plow unattended-upgrades
```

Select **Yes**.

Then:
```bash
[zima]$ sudo nano /etc/apt/apt.conf.d/50unattended-upgrades
```

Uncomment:
```text
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
```

### 1.4 Create the dedicated Hermes user
```bash
[zima]$ sudo adduser --disabled-password --gecos "" hermes
[zima]$ sudo usermod -aG docker hermes
[zima]$ sudo loginctl enable-linger hermes
```

`enable-linger` keeps the user service alive after logout.

### 1.5 Confirm Docker works for the Hermes user
```bash
[zima]$ sudo -iu hermes
[zima-h]$ docker version
```

If this fails, log out and back in once, or reboot the ZimaBoard.

---

## Phase 2 — Prepare the GX10 inference host

### 2.1 Confirm Ollama and your model
```bash
ssh <YOUR_GX10_USER>@192.168.0.12
[gx10]$ ollama list
```

If your intended model is not present, pull it:
```bash
[gx10]$ ollama pull qwen3.6:latest
```

### 2.2 Bind Ollama to the LAN
```bash
[gx10]$ sudo systemctl edit ollama
```

Add:
```ini
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_KEEP_ALIVE=30m"
Environment="OLLAMA_NUM_PARALLEL=2"
```

Then:
```bash
[gx10]$ sudo systemctl daemon-reload
[gx10]$ sudo systemctl restart ollama
```

### 2.3 Firewall the GX10
```bash
[gx10]$ sudo ufw allow from 192.168.0.13 to any port 11434 proto tcp comment 'Ollama from ZimaBoard'
[gx10]$ sudo ufw default deny incoming
[gx10]$ sudo ufw enable
```

### 2.4 Verify from the ZimaBoard
```bash
[zima]$ curl http://192.168.0.12:11434/api/tags
```

If you want to test the OpenAI-compatible endpoint shape that Hermes can use via the custom provider path:
```bash
[zima]$ curl http://192.168.0.12:11434/v1/models
```

If `/v1/models` does not respond on your Ollama build, do not panic. Hermes can still be configured interactively with `hermes model`. The important thing is that Ollama is reachable and serving the model you want.

---

## Phase 3 — Mount the NAS

### 3.1 Create two NFS exports on ZimaOS
Create:

1. **`hermes-ro`**  
   Directories the agent may read.  
   Allow IP `192.168.0.13` only.  
   Access: **read-only**.

2. **`hermes-workspace`**  
   A clean working directory for generated files and outputs.  
   Allow IP `192.168.0.13` only.  
   Access: **read-write**.

### 3.2 Mount them on the ZimaBoard
```bash
[zima]$ sudo mkdir -p /mnt/nas/readonly /mnt/nas/workspace
[zima]$ sudo chown -R hermes:hermes /mnt/nas
[zima]$ sudo nano /etc/fstab
```

Append:
```fstab
192.168.0.10:/hermes-ro        /mnt/nas/readonly   nfs4 ro,nofail,x-systemd.automount,x-systemd.idle-timeout=600 0 0
192.168.0.10:/hermes-workspace /mnt/nas/workspace  nfs4 rw,nofail,x-systemd.automount,x-systemd.idle-timeout=600 0 0
```

Apply:
```bash
[zima]$ sudo systemctl daemon-reload
[zima]$ sudo mount -a
[zima]$ ls /mnt/nas/readonly
[zima]$ touch /mnt/nas/workspace/test && rm /mnt/nas/workspace/test
[zima]$ touch /mnt/nas/readonly/test
```

The final command **must fail**.

---

## Phase 4 — Install Hermes Agent

Switch to the Hermes user:
```bash
[zima]$ sudo -iu hermes
[zima-h]$ whoami
```

Expected:
```text
hermes
```

Install Hermes:
```bash
[zima-h]$ curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash
[zima-h]$ source ~/.bashrc
[zima-h]$ hermes --version
```

Run a quick health check:
```bash
[zima-h]$ hermes doctor
```

---

## Phase 5 — Configure Hermes for the home setup

### 5.1 Choose the model
Run the guided selector:
```bash
[zima-h]$ hermes model
```

Recommended path for this topology:

- choose **custom endpoint** if you want the clearest remote-GX10 setup
- point it at `http://192.168.0.12:11434/v1`
- use `qwen3.6:latest` as the model name, or whatever you actually loaded on the GX10

If the built-in Ollama path works cleanly in your environment, that is also fine. The important point is that Hermes is talking to the GX10, not inferencing on the ZimaBoard.

### 5.2 Set Docker as the terminal backend
```bash
[zima-h]$ hermes config set terminal.backend docker
```

### 5.3 Review and then pin your main config
Open:
```bash
[zima-h]$ nano ~/.hermes/config.yaml
```

Use this as the baseline:

```yaml
model:
  provider: custom
  default: "qwen3.6:latest"
  base_url: "http://192.168.0.12:11434/v1"

terminal:
  backend: docker
  timeout: 180
  docker_image: "nikolaik/python-nodejs:python3.11-nodejs20"
  docker_mount_cwd_to_workspace: false
  docker_volumes:
    - "/mnt/nas/readonly:/data/readonly:ro"
    - "/mnt/nas/workspace:/data/workspace"
    - "/home/hermes/.hermes/cache/documents:/output"

session_reset:
  mode: both
  idle_minutes: 720
  at_hour: 4

group_sessions_per_user: true

platform_toolsets:
  cli: [hermes-cli]
  telegram: [hermes-telegram]
  discord: [hermes-discord]
```

Notes:
- `/data/readonly` is the agent’s read-only document area.
- `/data/workspace` is the agent’s writable working area.
- `/output` is a host-visible export path for files you may later want Hermes to send through messaging.

### 5.4 Create your primary `SOUL.md`
```bash
[zima-h]$ nano ~/.hermes/SOUL.md
```

Suggested starting point:

```md
# Identity
You are Molty, Gopala's home and personal AI assistant.

# Purpose
Be direct, practical, precise, and calm.
Help with household organization, family planning, travel research, reminders, summaries, writing drafts, and personal technology administration.

# Operating rules
- Before sending any email, show a draft and wait for explicit confirmation.
- Before creating or modifying any calendar event, show the exact proposed event first.
- Treat `/data/readonly` as read-only.
- Write only to `/data/workspace` or `/output`.
- Cite URLs when using web information.
- Do not claim to have completed an action unless it has actually completed.

# Defaults
- Timezone: Asia/Singapore
- Currency: SGD unless told otherwise
- Date format: DD-MMM-YYYY

# Tone
Professional, warm, concise, respectful.
```

### 5.5 First real chat test
```bash
[zima-h]$ hermes --tui
```

Test prompts:
- `Tell me who you are and where you are allowed to write files.`
- `List the files you can see in /data/readonly.`
- `Create /data/workspace/hello.txt with one line saying Hermes is working.`

If anything breaks:
```bash
[zima-h]$ hermes doctor
```

---

## Phase 6 — Configure Telegram

### 6.1 Create the Telegram bot
Using `@BotFather`:
- run `/newbot`
- copy the bot token
- optionally set description, avatar, commands

If you want the bot to work in a group, **disable privacy mode** and then remove/re-add the bot to the group.

### 6.2 Find your numeric Telegram user ID
Message `@userinfobot` or `@get_id_bot` and copy the numeric ID.

### 6.3 Configure Hermes
Recommended:
```bash
[zima-h]$ hermes gateway setup
```

Choose **Telegram** and supply:
- bot token
- allowed user ID

Or configure manually:
```bash
[zima-h]$ nano ~/.hermes/.env
```

Add:
```env
TELEGRAM_BOT_TOKEN=<YOUR_TELEGRAM_BOT_TOKEN>
TELEGRAM_ALLOWED_USERS=<YOUR_TELEGRAM_USER_ID>
```

### 6.4 Optional Telegram behavior
If you will use Telegram groups and want the bot to react only when addressed, keep mention-based behavior. If you want a more chatty group assistant later, tune Telegram settings after the base deployment is stable.

---

## Phase 7 — Configure Discord

### 7.1 Create the Discord application and bot
In the Discord Developer Portal:
- create a new application
- add a bot
- copy the bot token
- invite it to your server with the required permissions

### 7.2 Find your Discord user ID
Enable Developer Mode in Discord, then right-click your username and copy the numeric user ID.

### 7.3 Configure Hermes
Recommended:
```bash
[zima-h]$ hermes gateway setup
```

Choose **Discord** and supply:
- bot token
- allowed user ID

Or configure manually in `~/.hermes/.env`:
```env
DISCORD_BOT_TOKEN=<YOUR_DISCORD_BOT_TOKEN>
DISCORD_ALLOWED_USERS=<YOUR_DISCORD_USER_ID>
```

If you want proactive notifications in a specific channel later, also set:
```env
DISCORD_HOME_CHANNEL=<CHANNEL_ID>
```

---

## Phase 8 — Install the persistent gateway service

Because this is a headless home box, use the **user service** under the `hermes` account with lingering enabled.

Install and start:
```bash
[zima-h]$ hermes gateway install
[zima-h]$ hermes gateway start
[zima-h]$ hermes gateway status
```

Logs:
```bash
[zima-h]$ journalctl --user -u hermes-gateway -f
```

You can now message the bot on Telegram and Discord.

---

## Phase 9 — Conservative validation checklist

From your phone or laptop:

1. **Telegram DM test**
   - Send: `Who are you?`
   - Confirm the bot replies.

2. **Discord DM test**
   - Send: `Create a 3-line summary of what you can do.`
   - Confirm the bot replies.

3. **Filesystem boundary test**
   - Ask Hermes to write a file to `/data/workspace/test.txt`
   - Confirm the file appears in the NAS workspace.
   - Ask Hermes to write to `/data/readonly/test.txt`
   - Confirm it refuses or fails.

4. **Host isolation test**
   - Ask Hermes what the current filesystem looks like.
   - Confirm it sees only the Docker sandbox plus mounted paths, not the whole ZimaBoard host.

5. **Restart persistence**
   ```bash
   [zima-h]$ hermes gateway restart
   [zima-h]$ hermes gateway status
   ```

6. **Reboot persistence**
   ```bash
   [zima]$ sudo reboot
   ```
   After the reboot, confirm the gateway comes back and both bots respond.

---

## Phase 10 — Optional OpenClaw migration

If you want Hermes to import the old OpenClaw state, do it **only after** the fresh Hermes deployment above is working.

### 10.1 Dry run first
```bash
[zima-h]$ hermes claw migrate --dry-run
```

### 10.2 Then migrate
```bash
[zima-h]$ hermes claw migrate --preset full
```

### 10.3 Important cautions
- Stop OpenClaw before starting Hermes on the same Telegram / Discord bot token.
- Do **not** archive or clean up the old OpenClaw directory until Hermes is verified end-to-end.
- Validate:
  - `~/.hermes/config.yaml`
  - `~/.hermes/.env`
  - `~/.hermes/SOUL.md`
  - messaging access
  - gateway startup
  - writing to `/data/workspace`

If in doubt, keep the old `~/.openclaw` intact until you have at least a few days of stable Hermes operation.

---

## Phase 11 — Optional family profiles later

Do this only after the single primary home agent is stable.

Hermes profiles are excellent for separate identity and memory:
```bash
[zima-h]$ hermes profile create meenakshi
[zima-h]$ hermes profile create daanya
[zima-h]$ hermes profile create lohith
```

Each profile gets:
- its own `config.yaml`
- its own `.env`
- its own `SOUL.md`
- its own memory, sessions, skills, logs, and gateway state

Examples:
```bash
[zima-h]$ meenakshi setup
[zima-h]$ daanya setup
[zima-h]$ lohith setup
```

Important limitation for messaging: if you want each profile to run as its own Telegram or Discord assistant, each profile should use its **own bot token** and its **own gateway service**.

Examples:
```bash
[zima-h]$ meenakshi gateway install
[zima-h]$ meenakshi gateway start

[zima-h]$ daanya gateway install
[zima-h]$ daanya gateway start
```

### Suggested profile approach
- **Primary profile (`~/.hermes`)**: your own full-power assistant
- **Optional family profiles**:
  - no terminal access at first
  - different `SOUL.md`
  - separate bot identities if you actually want family-facing messaging assistants

### Example child-safe `SOUL.md`
For `daanya` or `lohith`:
```md
# Identity
You are a kind, age-appropriate family helper.

# Absolute rules
- Never discuss violence, weapons, drugs, alcohol, dating, explicit content, or politics.
- Never run commands.
- Never modify files.
- Keep language simple, kind, and age-appropriate.
- If something sounds unsafe or upsetting, gently tell the child to speak to a parent or teacher.

# Tone
Warm, simple, encouraging.
```

For these family profiles, also reduce tool access later with:
```bash
[zima-h]$ daanya tools
[zima-h]$ lohith tools
```

---

## Routine operations

### Check status
```bash
[zima-h]$ hermes status
[zima-h]$ hermes gateway status
[zima-h]$ hermes doctor
```

### Update Hermes
```bash
[zima-h]$ hermes update
```

### Restart gateway
```bash
[zima-h]$ hermes gateway restart
```

### View logs
```bash
[zima-h]$ journalctl --user -u hermes-gateway -f
```

### Review profiles
```bash
[zima-h]$ hermes profile list
```

### Review sessions
```bash
[zima-h]$ hermes sessions list
```

---

## Final recommendation

Start with **one primary Hermes home agent**.

Do not recreate the earlier multi-agent family layout immediately. Hermes can absolutely support multiple profiles, but the clean Hermes way is:
- first get one profile working well
- then add profiles only when you truly need separate identity or memory
- then give those profiles separate bot tokens if they must be messaging-facing

That gives you a simpler, safer, and more maintainable home deployment than trying to replicate the entire OpenClaw layout on day 1.
