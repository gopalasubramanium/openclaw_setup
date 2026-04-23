# Hermes Agent Personal & Family AI Assistant — Deployment Guide (v4)

Switches from OpenClaw to **Hermes Agent** by Nous Research. Simpler install, designed-in security (Tirith scanner, not patched CVEs), and first-class multi-profile support — which maps cleanly onto the four-family-member setup.

**What's the same as v3:**
- LAN-first, Tailscale deferred
- GX10 runs `qwen3.6:latest` for inference
- ZimaOS NAS mounted (read-only + one writable scratch)
- Four users: Gopala (main), Meenakshi, Daanya, Lohith
- Telegram + Discord channels
- SSH passwords on LAN (no keys)
- No Docker for the gateway (Hermes uses `local` terminal backend by default)

**What's different:**
- **Install:** one-line curl, Python + uv — no npm, no build errors
- **Profiles instead of agents:** each family member gets a fully isolated Hermes profile (`hermes profile create meenakshi` becomes a `meenakshi` command). Each profile has its own config, memory, sessions, gateway process, bot token — cleaner isolation than OpenClaw's multi-account hack
- **Gateway service is first-class:** `hermes gateway install` creates the systemd user service properly. No init.d scripts
- **Jetson role changes:** Hermes uses FTS5 text search + LLM summarization for cross-session memory by default, not vector embeddings. The Jetson's role shifts to an **optional fallback model host** rather than an embeddings host. If you want vector recall, it's possible but optional
- **Memory works out-of-the-box** with no extra config
- **Tirith security module** blocks dangerous commands pre-execution automatically
- **OpenAI-compatible Ollama:** Hermes talks to Ollama via `http://<host>:11434/v1`, treating it as a custom endpoint

---

## Target setup

| Role | Host | IP | Notes |
|---|---|---|---|
| Gateway | ZimaBoard Gen1, Ubuntu 24.04 LTS Minimal | `192.168.0.13` | Hermes Agent (Python) |
| Inference LLM | Asus Ascent GX10 | `192.168.0.12` | Ollama, `qwen3.6:latest` (35B, 256K context) |
| Fallback/embeddings (optional) | Jetson Orin Nano | `192.168.0.6` | Ollama, `qwen2.5:1.5b` or `nomic-embed-text` |
| NAS | ZimaOS | `192.168.0.10` | NFS exports |

**Four profiles, one per family member:**
- `main` → Gopala (default profile, full tools, Gmail/Calendar/Drive access)
- `meenakshi` → his wife
- `daanya` → his daughter (child-safe SOUL.md)
- `lohith` → his son (child-safe SOUL.md)

Each profile is a separate Hermes instance with its own:
- `HERMES_HOME` directory (`~/.hermes` for main, `~/.hermes/profiles/<name>` for others)
- Config, API keys, SOUL.md, memory, sessions, skills, cron jobs
- Telegram/Discord bot token (separate bot per profile)
- Gateway process (separate port, managed by systemd)

**Conventions**

| Prefix | Runs on |
|---|---|
| `[zima]$` | ZimaBoard as your admin user (sudo allowed) |
| `[zima-oc]$` | ZimaBoard as the `hermes` user (we create it in Phase 1) |
| `[gx10]$` | Asus GX10 |
| `[jetson]$` | Jetson Orin Nano |
| plain command | Your laptop or phone |

Replace `<angle-brackets>` with real values.

---

## Phase 1 — Harden ZimaBoard, create dedicated user (15 min)

```
ssh <your-user>@192.168.0.13
```

### 1.1 Update and install essentials

```
[zima]$ sudo apt update && sudo apt upgrade -y
[zima]$ sudo apt install -y curl git ufw unattended-upgrades nfs-common ca-certificates jq htop nano
```

### 1.2 Firewall — deny incoming except LAN SSH

```
[zima]$ sudo ufw default deny incoming
[zima]$ sudo ufw default allow outgoing
[zima]$ sudo ufw allow from 192.168.0.0/24 to any port 22 proto tcp comment 'SSH LAN'
[zima]$ sudo ufw enable
[zima]$ sudo ufw status verbose
```

**Outbound is allowed by default** — so Telegram/Discord polling, Google APIs, Ollama web search, Hermes updates all work without opening any inbound ports.

### 1.3 Unattended security updates

```
[zima]$ sudo dpkg-reconfigure -plow unattended-upgrades
[zima]$ sudo nano /etc/apt/apt.conf.d/50unattended-upgrades
```

Uncomment:

```
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
```

### 1.4 Create the `hermes` system user

```
[zima]$ sudo adduser hermes
```

**Give it a password when prompted** — it needs one so it can log in and manage its own systemd user services. Doesn't need sudo.

```
[zima]$ sudo loginctl enable-linger hermes
```

`enable-linger` lets this user's systemd services run without them being logged in — critical for the gateway to stay up.

---

## Phase 2 — GX10 Ascent inference host (15 min)

### 2.1 Confirm/pull model

```
ssh <gx10-user>@192.168.0.12
[gx10]$ ollama list
[gx10]$ ollama pull qwen3.6:latest          # 24 GB, grab a coffee
```

### 2.2 Sign in (for web search)

```
[gx10]$ ollama signin
```

### 2.3 Listen on LAN + tune for Hermes's 64K context requirement

```
[gx10]$ sudo systemctl edit ollama
```

Add:

```
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_KEEP_ALIVE=30m"
Environment="OLLAMA_NUM_PARALLEL=4"
Environment="OLLAMA_CONTEXT_LENGTH=65536"
```

`OLLAMA_CONTEXT_LENGTH=65536` sets the default context window to 64K. Hermes requires a minimum of 64K tokens — this ensures Ollama allocates that much. `NUM_PARALLEL=4` allows four profiles to query concurrently (one per family member).

```
[gx10]$ sudo systemctl daemon-reload
[gx10]$ sudo systemctl restart ollama
```

### 2.4 Firewall GX10

```
[gx10]$ sudo ufw allow from 192.168.0.0/24 to any port 22 proto tcp comment 'SSH LAN'
[gx10]$ sudo ufw allow from 192.168.0.13 to any port 11434 proto tcp comment 'ollama from zimaboard'
[gx10]$ sudo ufw default deny incoming
[gx10]$ sudo ufw enable
```

### 2.5 Test the OpenAI-compatible endpoint (this is what Hermes uses)

```
[zima]$ curl http://192.168.0.12:11434/v1/models
[zima]$ curl http://192.168.0.12:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3.6:latest",
    "messages": [{"role": "user", "content": "Say hello in one word."}]
  }'
```

If both work, Ollama is ready for Hermes. First call may take ~30s (model load).

**Phase 2 complete.**

---

## Phase 3 — Jetson Orin Nano (optional, 10 min)

Since Hermes's default memory system is FTS5 + LLM summarization (not vector embeddings), the Jetson's role is reduced. Three honest options:

1. **Skip it entirely for now.** Hermes works fully without it. Keep the Jetson for future use.
2. **Use as a fallback model host.** `qwen2.5:1.5b` isn't capable enough for tool chains, but it can handle "is GX10 down, please confirm you exist" health pings and simple Q&A.
3. **Use as an embeddings host** if you later enable vector-based memory (optional Hermes feature, not default).

**Recommended: go with option 1 for this deployment.** Revisit later if you want to add fallback or vector memory. This section is skippable; if you want to set it up anyway, do 3.1–3.3.

### 3.1 LAN listener + firewall

```
ssh <jetson-user>@192.168.0.6
[jetson]$ sudo systemctl edit ollama
```

```
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_KEEP_ALIVE=60m"
```

```
[jetson]$ sudo systemctl daemon-reload
[jetson]$ sudo systemctl restart ollama
[jetson]$ sudo ufw allow from 192.168.0.0/24 to any port 22 proto tcp comment 'SSH LAN'
[jetson]$ sudo ufw allow from 192.168.0.13 to any port 11434 proto tcp comment 'ollama from zimaboard'
[jetson]$ sudo ufw default deny incoming
[jetson]$ sudo ufw enable
```

### 3.2 Test from ZimaBoard

```
[zima]$ curl http://192.168.0.6:11434/v1/models
```

### 3.3 Defer the config

We'll plug it into Hermes as a `fallback_model` only if you want it later. Phase 9.3 covers this.

**Phase 3 complete (or skipped).**

---

## Phase 4 — Install Hermes Agent (10 min)

This is where it gets dramatically simpler than OpenClaw.

### 4.1 Log in as the `hermes` user

```
[zima]$ su - hermes
```

Enter the password you set in Phase 1.4. You're now running as `hermes`.

### 4.2 One-line installer

```
[zima-oc]$ curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash
```

The installer does everything: installs `uv`, Python 3.11, Node.js v22 (for browser/WhatsApp), `ripgrep`, `ffmpeg`, clones the repo, creates the virtualenv, installs all extras, symlinks `hermes` into `~/.local/bin/`.

Takes 3-5 minutes. No errors should appear.

### 4.3 Reload shell

```
[zima-oc]$ source ~/.bashrc
[zima-oc]$ hermes --version
```

### 4.4 Run setup wizard

```
[zima-oc]$ hermes setup
```

Walk through:

| Prompt | Answer |
|---|---|
| Model provider | **Custom endpoint (self-hosted / vLLM / etc.)** |
| API base URL | `http://192.168.0.12:11434/v1` |
| API key | `ollama` (any non-empty string — Ollama ignores it) |
| Model name | `qwen3.6:latest` |
| Context length | `65536` |
| Gateway setup | **Skip** — we configure per-profile in Phase 7 |
| Terminal backend | **Local** (Docker is optional; local is fine for trusted home use) |
| SOUL.md | Generate default, we'll overwrite in Phase 6 |

### 4.5 Prove it works

```
[zima-oc]$ hermes chat -q "Say hello in one word and confirm you are qwen3.6."
```

You should see a response. If anything is off:

```
[zima-oc]$ hermes doctor
```

`hermes doctor` is actually useful — it tells you exactly what's missing and how to fix it.

### 4.6 Install the gateway as a systemd user service

```
[zima-oc]$ hermes gateway install
```

This creates a proper systemd user service for the default `main` profile. It'll auto-start on boot (because of `enable-linger` from Phase 1.4) and restart on failure.

Verify:

```
[zima-oc]$ systemctl --user status hermes-gateway
[zima-oc]$ curl http://127.0.0.1:<port>/health     # hermes gateway install prints the port
```

**Phase 4 complete.**

---

## Phase 5 — Mount the NAS (15 min)

Unchanged from v3. Hermes reads from the same paths.

### 5.1 Create NFS exports on ZimaOS

1. **`openclaw-ro`** → points at `/Documents`, `/Reports`, etc. Allow `192.168.0.13` only. Read-only.
2. **`openclaw-rw`** → new folder `/openclaw-workspace`. Allow `192.168.0.13`. Read-write.

(Keep the export names as-is or rename to `hermes-ro`/`hermes-rw` — cosmetic.)

### 5.2 Mount on ZimaBoard

```
[zima]$ sudo mkdir -p /mnt/nas/readonly /mnt/nas/workspace
[zima]$ sudo chown -R hermes:hermes /mnt/nas
[zima]$ sudo nano /etc/fstab
```

Append:

```
192.168.0.10:/openclaw-ro         /mnt/nas/readonly   nfs4  ro,nofail,x-systemd.automount,x-systemd.idle-timeout=600  0 0
192.168.0.10:/openclaw-workspace  /mnt/nas/workspace  nfs4  rw,nofail,x-systemd.automount,x-systemd.idle-timeout=600  0 0
```

```
[zima]$ sudo systemctl daemon-reload
[zima]$ sudo mount -a
[zima]$ ls /mnt/nas/readonly                                            # lists files
[zima]$ touch /mnt/nas/workspace/test && rm /mnt/nas/workspace/test     # succeeds
[zima]$ touch /mnt/nas/readonly/test                                    # MUST fail
```

**Phase 5 complete.**

---

## Phase 6 — Create the four profiles (20 min)

This is where Hermes's profile system shines — each family member gets a fully isolated Hermes instance with one command.

### 6.1 Create three profiles (main already exists from Phase 4)

```
[zima-oc]$ hermes profile create meenakshi
[zima-oc]$ hermes profile create daanya
[zima-oc]$ hermes profile create lohith
[zima-oc]$ hermes profile list
```

Each profile creation:
- Makes `~/.hermes/profiles/<name>/` with its own config.yaml
- Creates a wrapper script at `~/.local/bin/<name>` — so `meenakshi chat` is a real command
- Gives it its own memory database, skills directory, sessions, gateway PID

### 6.2 Configure each profile's model

Each profile starts with no model configured. Point them at the same GX10 Ollama:

```
[zima-oc]$ meenakshi setup model
[zima-oc]$ daanya setup model
[zima-oc]$ lohith setup model
```

For each, answer as you did in Phase 4.4 (custom endpoint, `http://192.168.0.12:11434/v1`, model `qwen3.6:latest`, context `65536`).

All four profiles now use the same GX10 backend. Ollama's `NUM_PARALLEL=4` setting from Phase 2.3 lets them all talk at once.

### 6.3 Write SOUL.md per profile

SOUL.md defines persona and boundaries. Each profile has its own.

**Your profile (`main`):**

```
[zima-oc]$ nano ~/.hermes/SOUL.md
```

```
# Identity
You are a personal assistant for Gopala — direct, practical, no filler.

# Boundaries
- Before sending any email, show a preview and wait for explicit confirmation.
- Before creating or modifying calendar events, show the event and wait for confirmation.
- Read from /mnt/nas/readonly. Write only to /mnt/nas/workspace or ~/.
- Cite sources when referencing web content.

# Tone
Professional but warm. Singlish is fine when Gopala uses it first. No emojis unless he does.

# People in Gopala's life
- Meenakshi — wife
- Daanya — daughter
- Lohith — son
(Build this list as you meet colleagues, clients, and contacts.)

# Defaults
- Timezone: Asia/Singapore
- Currency: SGD unless told otherwise
- Date format: DD-MMM-YYYY
```

**Meenakshi:**

```
[zima-oc]$ nano ~/.hermes/profiles/meenakshi/SOUL.md
```

```
# Identity
You are a personal helper for Meenakshi. Friendly, patient, helpful.

# Boundaries
- You do not have access to Gopala's email, calendar, or Drive.
- You do not run commands that modify the computer.
- You can only read from the household shared folders.
- Do not discuss Gopala's professional matters.

# Tone
Warm, conversational, respectful.

# Timezone
Asia/Singapore.
```

**Daanya (child-safe):**

```
[zima-oc]$ nano ~/.hermes/profiles/daanya/SOUL.md
```

```
# Identity
You are Daanya's friendly helper. You help with schoolwork, curiosity questions,
fun facts, and simple explanations.

# Absolute rules
- Never discuss violence, weapons, drugs, alcohol, adult topics, dating, or politics.
- Never run commands, send emails, modify files, or access files beyond what's in memory.
- Keep language simple, kind, and age-appropriate.
- If Daanya asks something you shouldn't help with, say: "That's a good question for
  your parents. Want to ask them together?"
- If Daanya seems upset or describes something unsafe happening, gently suggest she
  talks to a parent or teacher.

# Tone
Playful, warm, encouraging. Simple words. Explain with examples.
```

**Lohith:**

```
[zima-oc]$ cp ~/.hermes/profiles/daanya/SOUL.md ~/.hermes/profiles/lohith/SOUL.md
[zima-oc]$ sed -i 's/Daanya/Lohith/g' ~/.hermes/profiles/lohith/SOUL.md
```

### 6.4 Restrict tools for non-main profiles

Family profiles should not have filesystem-modify, shell-exec, or browser tools.

```
[zima-oc]$ meenakshi tools
```

Interactive menu — **disable**: `terminal`, `write_file`, `edit_file`, `apply_patch`, `browser`.
Keep enabled: `read_file`, `web_search`, `web_fetch`, `memory`, `todo`, `skills`.

Do the same for `daanya` and `lohith`:

```
[zima-oc]$ daanya tools
[zima-oc]$ lohith tools
```

Same set of disabled tools.

**Note on isolation:** Hermes doesn't claim tools-deny is a hostile sandbox — the docs are explicit that profiles are isolation for state (memory/sessions/config), not a jailbreak-proof boundary. For home family use this is appropriate. If you want a stronger boundary, switch those profiles to the `docker` terminal backend later (one-line config change). I'd suggest living with tool-deny for a month first and see if anyone ever has a reason to want more.

### 6.5 Test each profile responds with its own persona

```
[zima-oc]$ hermes chat -q "Who are you?"
[zima-oc]$ meenakshi chat -q "Who are you?"
[zima-oc]$ daanya chat -q "Who are you?"
[zima-oc]$ lohith chat -q "Who are you?"
```

Four different personas. If any two sound the same, SOUL.md is in the wrong directory.

**Phase 6 complete.**

---

## Phase 7 — Gateway services: Telegram + Discord per profile (40 min)

Each profile gets its own Telegram bot and its own gateway process.

### 7.1 Create four Telegram bots

DM `@BotFather` → `/newbot` → follow prompts. Repeat four times.

| Profile | Suggested username | Save token as |
|---|---|---|
| main | `molty_gopala_bot` | `TG_TOKEN_MAIN` |
| meenakshi | `molty_meena_bot` | `TG_TOKEN_MEENA` |
| daanya | `molty_daanya_bot` | `TG_TOKEN_DAANYA` |
| lohith | `molty_lohith_bot` | `TG_TOKEN_LOHITH` |

For each bot: `/setprivacy` → **Disable**.

### 7.2 Find each user's Telegram numeric ID

Each user DMs their own bot. Then:

```
[zima-oc]$ hermes gateway logs --follow
```

Log shows `from.id` for each user. Record:

- `TG_ID_GOPALA`
- `TG_ID_MEENA`
- `TG_ID_DAANYA`
- `TG_ID_LOHITH`

### 7.3 Configure Telegram in each profile

```
[zima-oc]$ hermes gateway setup
```

Select Telegram → paste `TG_TOKEN_MAIN` → set allowlist → enter `TG_ID_GOPALA` when prompted.

Repeat for each profile:

```
[zima-oc]$ meenakshi gateway setup           # paste TG_TOKEN_MEENA, allow TG_ID_MEENA
[zima-oc]$ daanya gateway setup              # paste TG_TOKEN_DAANYA, allow TG_ID_DAANYA
[zima-oc]$ lohith gateway setup              # paste TG_TOKEN_LOHITH, allow TG_ID_LOHITH
```

Each gateway_setup writes tokens into its profile's `.env` file. Tokens are scoped per-profile — Daanya's bot token is not visible to Meenakshi's agent.

### 7.4 Install gateway services (systemd, auto-start on boot)

```
[zima-oc]$ hermes gateway install                   # main
[zima-oc]$ meenakshi gateway install                # own systemd unit
[zima-oc]$ daanya gateway install
[zima-oc]$ lohith gateway install
```

Each creates a separate systemd user service (`hermes-gateway`, `hermes-gateway-meenakshi`, etc.) on a separate port.

### 7.5 Verify

```
[zima-oc]$ systemctl --user status hermes-gateway                hermes-gateway-meenakshi \
           hermes-gateway-daanya hermes-gateway-lohith
```

All four should be `active (running)`.

### 7.6 Test from each user's phone

Each family member DMs their bot "Who are you?" — each gets the right persona. If any bot doesn't respond:

```
[zima-oc]$ <profile> gateway logs --follow
[zima-oc]$ <profile> doctor
```

### 7.7 Discord for you (main only)

Skip for family.

1. `https://discord.com/developers/applications` → **New Application** → `Molty`
2. **Bot** → add bot → copy token
3. Enable **Message Content Intent**
4. **OAuth2 → URL Generator** → `bot` + `applications.commands`; perms: Send Messages, Read Message History, Attach Files, Embed Links. Open URL → add to your personal server.
5. Settings → Developer Mode → right-click your name → Copy User ID → save as `DC_ID_GOPALA`

```
[zima-oc]$ hermes gateway setup
```

Select Discord → paste token → set allowlist → `DC_ID_GOPALA`.

```
[zima-oc]$ systemctl --user restart hermes-gateway
```

**Phase 7 complete.** Each family member has their own bot routing to their own agent.

---

## Phase 8 — Google OAuth: Gmail + Calendar + Drive (30 min)

Only for `main`. Family profiles don't get Google access.

### 8.1 Google Cloud project

On your laptop, signed in as `sgopala.ai@gmail.com`:

1. `https://console.cloud.google.com`
2. **Create project** → `hermes-personal` → select it

### 8.2 Enable APIs

**APIs & Services → Library**, enable:
- Gmail API
- Google Calendar API
- Google Drive API
- Google People API

### 8.3 OAuth consent

**APIs & Services → OAuth consent screen**:
- User type: **External**
- App name: `hermes-personal`
- Support email + Developer contact: `sgopala.ai@gmail.com`
- Scopes:
  - `https://www.googleapis.com/auth/gmail.modify`
  - `https://www.googleapis.com/auth/calendar`
  - `https://www.googleapis.com/auth/drive.readonly`
  - `https://www.googleapis.com/auth/contacts.readonly`
- Test users: add `sgopala.ai@gmail.com`

Keep in **Testing** mode.

### 8.4 OAuth client

**Credentials → Create Credentials → OAuth client ID** → Desktop app → `hermes-cli` → Download JSON.

Copy to the ZimaBoard:

```
scp client_secret.json <your-user>@192.168.0.13:/tmp/
ssh <your-user>@192.168.0.13
[zima]$ sudo mv /tmp/client_secret.json /home/hermes/.hermes/google-creds.json
[zima]$ sudo chown hermes:hermes /home/hermes/.hermes/google-creds.json
[zima]$ sudo chmod 600 /home/hermes/.hermes/google-creds.json
```

### 8.5 Install Gmail/Calendar/Drive skills

Hermes has a skills system compatible with `agentskills.io`. Browse and install:

```
[zima]$ su - hermes
[zima-oc]$ hermes skills browse
[zima-oc]$ hermes skills install gmail calendar drive
```

If the exact skill names differ (community names shift), use:

```
[zima-oc]$ hermes skills browse google
```

After install, each skill will prompt for OAuth on first use — run:

```
[zima-oc]$ hermes chat -q "List my 3 most recent emails."
```

First call opens a browser URL. Authenticate as `sgopala.ai@gmail.com`, paste the code back.

### 8.6 Safety guardrails

Add to `~/.hermes/config.yaml`:

```yaml
skills:
  config:
    gmail:
      confirm_send: true
      max_recipients: 5
      audit_log: "/mnt/nas/workspace/audit/gmail.log"
    calendar:
      confirm_modify: true
```

Restart:

```
[zima-oc]$ hermes gateway restart
```

### 8.7 Restrict Google skills to main

Hermes skills are already per-profile — family profiles don't see skills they haven't installed. No extra config needed. Confirm:

```
[zima-oc]$ meenakshi skills list
```

Should NOT show gmail/calendar/drive.

### 8.8 (Optional) Real-time Gmail push

For automatic reaction to new email, see `https://hermes-agent.nousresearch.com/docs/integrations/` — Gmail integration supports Pub/Sub push. Skip for now; pull-based works.

**Phase 8 complete.**

---

## Phase 9 — Memory, web search, automations (20 min)

### 9.1 Memory is already working

Hermes's default memory uses SQLite with FTS5 full-text search and LLM summarization for cross-session recall. No configuration needed — it just works. Verify:

```
[zima-oc]$ hermes chat -q "Remember that I prefer dates formatted as DD-MMM-YYYY."
[zima-oc]$ hermes chat -q "What date format do I prefer?"
```

Second call should recall it.

Each profile has its own memory database at `~/.hermes/profiles/<name>/memory.db`. Zero cross-contamination.

### 9.2 Web search

Hermes ships with `web_search` and `web_fetch` tools by default. If you want a specific provider (Brave, Tavily, Ollama Web Search), run:

```
[zima-oc]$ hermes config set model.web_search.provider ollama
[zima-oc]$ hermes config set model.web_search.base_url http://192.168.0.12:11434
```

Test:

```
[zima-oc]$ hermes chat -q "Search for today's weather in Singapore, 2-sentence summary."
```

### 9.3 (Optional) Jetson as fallback model

If you kept Phase 3 active and want failover to the Jetson when GX10 is unreachable:

```
[zima-oc]$ nano ~/.hermes/config.yaml
```

Add:

```yaml
fallback_model:
  provider: custom
  model: qwen2.5:1.5b
  base_url: http://192.168.0.6:11434/v1
  key_env: OLLAMA_API_KEY
```

Set a dummy API key env:

```
[zima-oc]$ hermes config set OLLAMA_API_KEY ollama
```

Honest caveat: 1.5B is too small for tool chains, so on failover the agent will degrade — it'll talk, but complex tasks will fail. Think of this as a "say sorry I'm degraded" fallback, not a real second-tier.

### 9.4 Cron automations

Hermes has first-class natural-language cron:

```
[zima-oc]$ hermes chat -q "Create a cron job named daily-briefing. Every day at 07:00 Asia/Singapore, summarise unread emails from the last 24 hours, list today's calendar events, and search the web for 3 headlines each on AI, semiconductors, and Singapore business news. Send the result to me on Telegram."
```

List:

```
[zima-oc]$ hermes cron list
```

### 9.5 Document ingestion from NAS

```
[zima-oc]$ hermes chat -q "Read all PDFs and .docx files under /mnt/nas/readonly/Documents. Remember the key points from each so I can ask questions later. Skip any file over 50 MB."
```

Hermes will walk the directory, summarise each file into memory. Re-run monthly as you add docs, or cron it.

### 9.6 ClawHub → Skills Hub

Hermes's community skill registry is `agentskills.io`:

```
[zima-oc]$ hermes skills browse
```

Useful skills to consider: `rss`, `weather`, `github`, `obsidian`. Install with `hermes skills install <name>`.

**Phase 9 complete.**

---

## Phase 10 — Backup, monitoring, maintenance (15 min)

### 10.1 Nightly backup of all profiles

```
[zima]$ sudo nano /etc/cron.d/hermes-backup
```

```
0 3 * * * hermes tar czf /mnt/nas/workspace/backups/hermes-$(date +\%F).tgz -C /home/hermes .hermes 2>/dev/null
0 4 * * 0 hermes find /mnt/nas/workspace/backups -name 'hermes-*.tgz' -mtime +30 -delete
```

Daily, 30-day retention. The tarball includes all four profiles' state (configs, memories, sessions, skills, OAuth tokens). **Keep the backup folder private.**

### 10.2 Health checks

```
[zima-oc]$ hermes doctor                    # main profile
[zima-oc]$ meenakshi doctor                 # per-profile
[zima-oc]$ daanya doctor
[zima-oc]$ lohith doctor
```

Run when something feels off. Hermes's doctor is thorough and actionable.

### 10.3 Logs

```
[zima-oc]$ journalctl --user -u hermes-gateway -f
[zima-oc]$ journalctl --user -u hermes-gateway-meenakshi -f
```

Or via Hermes:

```
[zima-oc]$ hermes gateway logs --follow
[zima-oc]$ meenakshi gateway logs --follow
```

### 10.4 Updates

```
[zima-oc]$ hermes update
```

Applies to all profiles in one go. Run monthly. Follow up with `hermes doctor`.

### 10.5 Kill switch

```
[zima-oc]$ systemctl --user stop hermes-gateway{,-meenakshi,-daanya,-lohith}
```

Revoke access:
- **Telegram:** BotFather → `/revoke` → new token → update `.env` in each profile
- **Discord:** Dev portal → Reset Token → update main profile's `.env`
- **Google:** `https://myaccount.google.com/permissions` → remove `hermes-personal` → redo Phase 8

---

## Phase 11 — Tailscale (dormant install, activate when needed)

Unchanged from v3. Install but don't `up`:

```
[zima]$ curl -fsSL https://tailscale.com/install.sh | sh
[gx10]$ curl -fsSL https://tailscale.com/install.sh | sh
[jetson]$ curl -fsSL https://tailscale.com/install.sh | sh
```

When you travel and need remote access:

```
[zima]$ sudo tailscale up --ssh
[gx10]$ sudo tailscale up --ssh
[jetson]$ sudo tailscale up
```

When home:

```
[zima]$ sudo tailscale down
```

When Tailscale is up, switch SSH to keys:

```
ssh-copy-id <your-user>@<zima-tailscale-ip>
[zima]$ sudo nano /etc/ssh/sshd_config.d/99-tailscale.conf
```

```
PasswordAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
```

```
[zima]$ sudo systemctl reload ssh
```

---

## Phase 12 — Things worth knowing

### 12.1 Tirith security scanner

Hermes ships with Tirith, a pre-execution command scanner, enabled by default. It blocks `curl | bash`, `rm -rf /`, and similar dangerous patterns before they run.

If it ever blocks a legitimate command, you'll see a clear message. Review the rules at `~/.hermes/tirith.yaml`. The Discord recommends running blocked commands manually in a split terminal rather than disabling Tirith.

### 12.2 Cloud failover for hard tasks

If local ever struggles on complex research, add Claude or OpenAI as a premium fallback:

```yaml
# ~/.hermes/config.yaml
fallback_model:
  provider: anthropic
  model: claude-opus-4-6
```

Set `ANTHROPIC_API_KEY` and cap spend at console.anthropic.com.

### 12.3 Profiles = process isolation

Four gateway processes run simultaneously. On the ZimaBoard (Celeron N3450, 8 GB RAM), each gateway is ~150-250 MB idle, spiking to ~500 MB during a response. Four active + system = ~3-4 GB peak. You're fine, but don't also run a browser tool.

### 12.4 Docker backend (if you change your mind on family sandboxing later)

```yaml
# ~/.hermes/profiles/daanya/config.yaml
terminal:
  backend: docker
  docker_image: "nikolaik/python-nodejs:python3.11-nodejs20"
  container_cpu: 1
  container_memory: 2048
```

Add Docker later with `sudo apt install docker.io`. Switching a profile is one config line.

### 12.5 Git-backup each profile

```
[zima-oc]$ cd ~/.hermes
[zima-oc]$ git init && git add . && git commit -m "initial"
[zima-oc]$ git remote add origin git@github.com:<you>/hermes-main.git
[zima-oc]$ git push -u origin main
```

Repeat for `~/.hermes/profiles/<name>/`. Use **private** repos.

### 12.6 Monthly review

- `hermes doctor` on each profile
- `df -h` and backup folder size
- Google OAuth status at `myaccount.google.com/permissions`
- Gmail audit log at `/mnt/nas/workspace/audit/gmail.log`

### 12.7 Family onboarding

For each of Meenakshi / Daanya / Lohith:

1. Send the direct link to their Telegram bot
2. Have them DM it once
3. Hand over the one-pager (Appendix C)

### 12.8 What NOT to do

- Don't give the `hermes` user sudo.
- Don't share `.env` files — they contain all bot tokens and API keys.
- Don't expose gateway ports (18789+) publicly.
- Don't skip `hermes doctor` warnings.
- Don't disable Tirith without a specific reason.

---

## Troubleshooting

| Symptom | First check |
|---|---|
| Bot doesn't respond on Telegram | `<profile> gateway logs --follow`, `<profile> doctor` |
| "Connection refused" to GX10 | `curl http://192.168.0.12:11434/v1/models` — if fails, Phase 2 firewall/systemd |
| Context length error on startup | `OLLAMA_CONTEXT_LENGTH=65536` not set on GX10; check Phase 2.3 |
| Wrong persona in a bot | SOUL.md in wrong directory, or gateway pointing at wrong profile |
| Memory not persisting | Profile's `~/.hermes/profiles/<name>/memory.db` readable? |
| Tirith blocked a command I want | Review `~/.hermes/tirith.yaml` or run the command manually outside Hermes |
| Can't switch to a profile | `hermes profile list` — confirm it exists; `source ~/.bashrc` |
| Gateway service didn't start on boot | `loginctl show-user hermes` — confirm `Linger=yes` from Phase 1.4 |

Universal first command: **`hermes doctor`**.

---

## Appendix A — Architecture

```
                       Internet (outbound only)
                              ^
                              |
  [4 phones] -- Telegram/Discord -- (cloud) -- Hermes gateways
                                                   |
                                                   v
  HOME LAN (192.168.0.0/24):

  +-----------------+                +-------------------------------+
  | ZimaOS NAS      |<-- NFS ------->|   ZimaBoard Gen1              |
  | 192.168.0.10    |                |   192.168.0.13                |
  |                 |                |   Hermes Agent                |
  +-----------------+                |   - main profile              |
                                     |   - meenakshi profile         |
                                     |   - daanya profile            |
                                     |   - lohith profile            |
                                     |   (4 gateway processes)       |
                                     +-------------+-----------------+
                                                   |
                                          Ollama OpenAI-compat API
                                          (http://...:11434/v1)
                                                   v
                                     +-------------------------------+
                                     | GX10 Ascent (192.168.0.12)    |
                                     | qwen3.6:latest, 64K context   |
                                     +-------------------------------+

  Optional: Jetson Orin Nano (192.168.0.6) — dormant, available as fallback_model
  Tailscale: installed dormant on all servers; activate only when remote.
```

---

## Appendix B — File map

```
/home/hermes/
├── .hermes/                            # main profile
│   ├── config.yaml
│   ├── .env                            # tokens, API keys
│   ├── SOUL.md
│   ├── memory.db                       # SQLite + FTS5
│   ├── sessions/
│   ├── skills/
│   ├── tirith.yaml
│   ├── google-creds.json               # OAuth (BACK UP)
│   └── profiles/
│       ├── meenakshi/
│       │   ├── config.yaml
│       │   ├── .env
│       │   ├── SOUL.md
│       │   ├── memory.db
│       │   └── sessions/
│       ├── daanya/
│       │   └── (same structure)
│       └── lohith/
│           └── (same structure)
│
├── .local/bin/
│   ├── hermes                          # symlink to main binary
│   ├── meenakshi                       # wrapper: HERMES_HOME=~/.hermes/profiles/meenakshi hermes ...
│   ├── daanya
│   └── lohith
│
└── .config/systemd/user/
    ├── hermes-gateway.service
    ├── hermes-gateway-meenakshi.service
    ├── hermes-gateway-daanya.service
    └── hermes-gateway-lohith.service

/mnt/nas/
├── readonly/                           # main reads from here
└── workspace/
    ├── audit/gmail.log
    └── backups/
        └── hermes-YYYY-MM-DD.tgz       # all 4 profiles
```

---

## Appendix C — One-pager for family

Same as v3 — print one per person.

> **Meet your personal AI helper**
>
> Your helper lives on our home server. You talk to your own helper on Telegram.
> Your helper is yours — it doesn't know what the others are saying.
>
> **What it can do**
> - Answer questions
> - Help with writing, schoolwork, curiosity
> - Remember stuff you tell it ("my piano recital is in March")
> - Search the web for facts
>
> **What it can't do**
> - Send messages to other people for you
> - Delete or change files on the computer
> - See or talk about anyone else's helper
>
> **If it says something odd** — tell Gopala.
> **If it stops replying** — tell Gopala.
>
> **Fun prompts to try**
> - "Tell me a weird fact about octopuses"
> - "Help me plan a birthday party for 10 kids"
> - "Explain photosynthesis like I'm 8"

---

## Done

Phase 1 tonight, stop there. Every phase is a checkpoint. First command when anything's off: **`hermes doctor`**.

Compared to OpenClaw: fewer moving parts, no npm/TypeScript/build-script drama, designed-in security, first-class multi-profile — this should feel significantly less painful than what you just went through.
