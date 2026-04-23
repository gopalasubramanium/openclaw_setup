# OpenClaw Personal & Family AI Assistant — Deployment Guide (v3)

Supersedes v1 and v2. Rebalanced toward "keep it genuinely simple, LAN-first, defer the heavy stuff until you need it".

**What changed from v2:**
- **No Tailscale by default** — installed dormant in Phase 11, activated only when you actually travel. On LAN everything talks directly.
- **No Docker at all** — neither for the gateway nor for family sandboxing. Family agents are restricted via tool deny-lists instead.
- **No SSH key hardening, no fail2ban** — LAN-only box with a strong password + unattended security updates is appropriate. Upgrade to keys only if/when you expose SSH via Tailscale.
- **Jetson Orin Nano (192.168.0.6) added as dedicated embeddings host** — GX10 does inference only, Jetson does embeddings only. Clean split.

---

## Target setup

| Role | Host | IP | Notes |
|---|---|---|---|
| Gateway | ZimaBoard Gen1, Ubuntu 24.04 LTS Minimal | `192.168.0.13` | OpenClaw daemon (Node.js) |
| Inference LLM | Asus Ascent GX10 | `192.168.0.12` | Ollama, `qwen3.6:latest` (35B, 24GB) |
| Embeddings | Jetson Orin Nano | `192.168.0.6` | Ollama, `nomic-embed-text` |
| NAS | ZimaOS | `192.168.0.10` | NFS exports to ZimaBoard |

**Networking:** LAN only. Tailscale installed dormant in Phase 11 for future remote access.
**Channels (phase 1):** Telegram + Discord.
**Google account:** `sgopala.ai@gmail.com` — Gmail R/W, Calendar R/W, Drive R-only.

**Four agents, one per user:**
- `main` → Gopala (no restrictions)
- `meenakshi` → tool deny: exec/write/edit
- `daanya` → tool deny: exec/write/edit/browser; child-safe SOUL.md
- `lohith` → same as Daanya

---

## Conventions

| Prefix | Runs on |
|---|---|
| `[zima]$` | ZimaBoard as your admin user (sudo allowed) |
| `[zima-oc]$` | ZimaBoard as the `openclaw` user |
| `[gx10]$` | Asus GX10 (inference host) |
| `[jetson]$` | Jetson Orin Nano (embeddings host) |
| plain command | Your laptop or phone |

Replace `<angle-brackets>` with your actual values.

---

## Phase 1 — Harden the ZimaBoard (15 min)

Trimmed down since we're LAN-only.

```
ssh <your-user>@192.168.0.13
```

### 1.1 Update and install essentials

```
[zima]$ sudo apt update && sudo apt upgrade -y
[zima]$ sudo apt install -y curl git ufw unattended-upgrades nfs-common ca-certificates jq htop nano
```

### 1.2 Firewall — deny by default, allow LAN only

```
[zima]$ sudo ufw default deny incoming
[zima]$ sudo ufw default allow outgoing
[zima]$ sudo ufw allow from 192.168.0.0/24 to any port 22 proto tcp comment 'SSH LAN'
[zima]$ sudo ufw enable
[zima]$ sudo ufw status verbose
```

### 1.3 Automatic security updates

```
[zima]$ sudo dpkg-reconfigure -plow unattended-upgrades
```

Select **Yes**. Then:

```
[zima]$ sudo nano /etc/apt/apt.conf.d/50unattended-upgrades
```

Uncomment (remove leading `//`):

```
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
```

Save: `Ctrl+O`, `Enter`, `Ctrl+X`.

### 1.4 SSH stays on password auth

Make sure your admin user has a **strong, unique password** — something like a 4-word passphrase (correct-horse-battery-staple style) is better than a complex short one.

```
[zima]$ passwd    # change if yours is weak
```

Skipping SSH key setup. LAN-only with strong password + UFW deny-by-default is adequate. Revisit in Phase 11 if you enable Tailscale.

### 1.5 Create the `openclaw` system user

```
[zima]$ sudo adduser --disabled-password --gecos "" openclaw
[zima]$ sudo loginctl enable-linger openclaw
```

`enable-linger` lets the user's systemd services run without being logged in.

**Phase 1 complete.**

---

## Phase 2 — Jetson Orin Nano as embeddings host (15 min)

### 2.1 Confirm Ollama is running

```
ssh <jetson-user>@192.168.0.6
[jetson]$ ollama list
```

You likely see `qwen2.5:1.5b`. Keep it — it's tiny and may be useful later.

### 2.2 Pull the embedding model

```
[jetson]$ ollama pull nomic-embed-text
```

About 270 MB. The Jetson Orin Nano (8GB shared memory) has no trouble hosting this plus `qwen2.5:1.5b`.

### 2.3 Let Ollama listen on the LAN interface

By default Ollama binds to `127.0.0.1`. Open it to the LAN:

```
[jetson]$ sudo systemctl edit ollama
```

Add:

```
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_KEEP_ALIVE=60m"
```

Longer keep-alive for embeddings because NAS ingestion fires in bursts.

```
[jetson]$ sudo systemctl daemon-reload
[jetson]$ sudo systemctl restart ollama
```

### 2.4 Firewall the Jetson

```
[jetson]$ sudo ufw allow from 192.168.0.13 to any port 11434 proto tcp comment 'ollama from zimaboard'
[jetson]$ sudo ufw default deny incoming
[jetson]$ sudo ufw enable
```

Only the ZimaBoard can hit Ollama. Your LAN clients and phones can't.

### 2.5 Test from the ZimaBoard

```
[zima]$ curl http://192.168.0.6:11434/api/tags
[zima]$ curl http://192.168.0.6:11434/api/embed -d '{
  "model": "nomic-embed-text",
  "input": "The sky is blue."
}'
```

Second call returns a vector (long JSON array). If it works, embeddings are ready.

**Phase 2 complete.**

---

## Phase 3 — GX10 Ascent as inference host (15 min)

### 3.1 Confirm the model

```
ssh <gx10-user>@192.168.0.12
[gx10]$ ollama list
```

If `qwen3.6:latest` isn't there:

```
[gx10]$ ollama pull qwen3.6:latest
```

24 GB download. Grab a coffee.

### 3.2 Sign in to Ollama (needed for Web Search)

```
[gx10]$ ollama signin
```

Follow prompts. Without this, Ollama Web Search won't work from OpenClaw.

### 3.3 Let Ollama listen on LAN

```
[gx10]$ sudo systemctl edit ollama
```

Add:

```
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_KEEP_ALIVE=30m"
Environment="OLLAMA_NUM_PARALLEL=2"
```

`NUM_PARALLEL=2` lets two agents query at once (you and a family member).

```
[gx10]$ sudo systemctl daemon-reload
[gx10]$ sudo systemctl restart ollama
```

### 3.4 Firewall GX10

```
[gx10]$ sudo ufw allow from 192.168.0.13 to any port 11434 proto tcp comment 'ollama from zimaboard'
[gx10]$ sudo ufw default deny incoming
[gx10]$ sudo ufw enable
```

### 3.5 Test from the ZimaBoard

```
[zima]$ curl http://192.168.0.12:11434/api/tags
[zima]$ curl http://192.168.0.12:11434/api/generate -d '{
  "model": "qwen3.6:latest",
  "prompt": "Say hello in one word.",
  "stream": false
}'
```

First call may take ~30s (model loading into VRAM). Subsequent calls are fast.

**Phase 3 complete.** Both LLM hosts reachable from the ZimaBoard, nothing else can touch them.

---

## Phase 4 — Install OpenClaw (15 min)

### 4.1 Install Node 24

```
[zima]$ curl -fsSL https://deb.nodesource.com/setup_24.x | sudo bash -
[zima]$ sudo apt install -y nodejs
[zima]$ node --version   # expect v24.x
```

### 4.2 Install OpenClaw globally

```
[zima]$ sudo npm install -g openclaw@latest
[zima]$ openclaw --version
```

### 4.3 Switch to the `openclaw` user

```
[zima]$ sudo -iu openclaw
[zima-oc]$ whoami   # openclaw
```

From here on, OpenClaw commands run as this user.

### 4.4 Onboarding

```
[zima-oc]$ openclaw onboard --install-daemon
```

Answers:

| Prompt | Answer |
|---|---|
| Model provider | **Ollama** |
| Base URL | `http://192.168.0.12:11434` |
| Model | `qwen3.6:latest` |
| API key | leave blank (or type `ollama`) |
| Install systemd daemon | **Yes** |
| Channels | **Skip** — we configure them per-channel in Phase 7 |

Verify:

```
[zima-oc]$ systemctl --user status openclaw
[zima-oc]$ openclaw agent --message "Hello, confirm you are Qwen 3.6 running via Ollama."
```

If either fails:

```
[zima-oc]$ openclaw doctor
[zima-oc]$ openclaw logs --follow
```

**Phase 4 complete.**

---

## Phase 5 — Mount the NAS (15 min)

### 5.1 On ZimaOS (web UI)

Create two NFS exports:

1. **`openclaw-ro`** — points at directories the agent should read (e.g., `/Documents`, `/Reports`). Allow IP `192.168.0.13` only. Access: **read-only**.
2. **`openclaw-rw`** — a new empty folder `/openclaw-workspace`. Allow `192.168.0.13`. Access: **read-write**.

### 5.2 On the ZimaBoard

```
[zima]$ sudo mkdir -p /mnt/nas/readonly /mnt/nas/workspace
[zima]$ sudo chown -R openclaw:openclaw /mnt/nas
[zima]$ sudo nano /etc/fstab
```

Append:

```
192.168.0.10:/openclaw-ro         /mnt/nas/readonly   nfs4  ro,nofail,x-systemd.automount,x-systemd.idle-timeout=600  0 0
192.168.0.10:/openclaw-workspace  /mnt/nas/workspace  nfs4  rw,nofail,x-systemd.automount,x-systemd.idle-timeout=600  0 0
```

`x-systemd.automount` mounts on first access, unmounts when idle 10 min — saves NAS wakeups.

```
[zima]$ sudo systemctl daemon-reload
[zima]$ sudo mount -a
[zima]$ ls /mnt/nas/readonly                                            # lists files
[zima]$ touch /mnt/nas/workspace/test && rm /mnt/nas/workspace/test     # succeeds
[zima]$ touch /mnt/nas/readonly/test                                    # MUST fail
```

If the third command succeeds, your NAS export isn't actually read-only. Fix it on ZimaOS.

**Phase 5 complete.**

---

## Phase 6 — Four isolated agents (25 min)

### 6.1 Create the three family agents

`main` already exists (Phase 4). Add the rest:

```
[zima-oc]$ openclaw agents add meenakshi --workspace ~/.openclaw/workspace-meenakshi --non-interactive
[zima-oc]$ openclaw agents add daanya --workspace ~/.openclaw/workspace-daanya --non-interactive
[zima-oc]$ openclaw agents add lohith --workspace ~/.openclaw/workspace-lohith --non-interactive
[zima-oc]$ openclaw agents list
```

Should show four: `main`, `meenakshi`, `daanya`, `lohith`.

### 6.2 Identities

```
[zima-oc]$ openclaw agents set-identity --agent main --name "Molty" --emoji "🦞"
[zima-oc]$ openclaw agents set-identity --agent meenakshi --name "Molty (Meenakshi)" --emoji "🌸"
[zima-oc]$ openclaw agents set-identity --agent daanya --name "Molty (Daanya)" --emoji "⭐"
[zima-oc]$ openclaw agents set-identity --agent lohith --name "Molty (Lohith)" --emoji "🚀"
```

### 6.3 SOUL.md per agent

**Your agent:**

```
[zima-oc]$ nano ~/.openclaw/workspace/SOUL.md
```

```
# Identity
You are Molty, Gopala's personal and professional assistant. Direct, practical, no filler.

# Boundaries
- Before sending any email, show a preview and wait for explicit confirmation.
- Before creating or modifying calendar events, show the event and wait for confirmation.
- Read from /mnt/nas/readonly. Write only to /mnt/nas/workspace or ~/.openclaw/workspace.
- Never reference or touch other family members' workspaces.
- Cite URLs when referencing web content.

# Tone
Professional but warm. Singlish is fine if Gopala uses it first. No emojis unless he does.

# People
- Meenakshi — wife
- Daanya — daughter
- Lohith — son
(Add colleagues, clients, recurring contacts here as they come up.)

# Defaults
- Timezone: Asia/Singapore
- Currency: SGD unless told otherwise
- Date format: DD-MMM-YYYY
```

**Meenakshi's agent:**

```
[zima-oc]$ nano ~/.openclaw/workspace-meenakshi/SOUL.md
```

```
# Identity
You are Molty, Meenakshi's personal helper. Friendly, patient, helpful.

# Boundaries
- No access to Gopala's email, calendar, or Drive.
- Cannot run commands or modify files.
- Read-only access to the NAS shared folders.
- Do not discuss Gopala's professional matters.

# Tone
Warm, conversational, respectful.

# Timezone
Asia/Singapore.
```

**Daanya (child-safe):**

```
[zima-oc]$ nano ~/.openclaw/workspace-daanya/SOUL.md
```

```
# Identity
You are Molty, Daanya's friendly helper. You help with schoolwork, curiosity questions,
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
[zima-oc]$ cp ~/.openclaw/workspace-daanya/SOUL.md ~/.openclaw/workspace-lohith/SOUL.md
[zima-oc]$ sed -i 's/Daanya/Lohith/g' ~/.openclaw/workspace-lohith/SOUL.md
```

### 6.4 AGENTS.md per workspace

**`main`:**

```
[zima-oc]$ nano ~/.openclaw/workspace/AGENTS.md
```

```
# Operating rules
- Use memory aggressively: remember names, deadlines, preferences, recurring projects.
- When summarising emails or news, always include the source URL or sender.
- For research, prefer 2-3 sources; flag contradictions.
- Draft email/reports in plain prose first; ask if formatting is needed.
- When ambiguous, ask ONE clarifying question rather than guessing.

# Paths
- Read-only NAS: /mnt/nas/readonly
- Writable NAS:  /mnt/nas/workspace

# Memory guidance
- Store: names, preferences, recurring deadlines, project context, decisions, contacts.
- Do not store: transient small talk, passwords, credit card numbers.
- When uncertain, err on saving.
```

**Family:**

```
[zima-oc]$ nano ~/.openclaw/workspace-meenakshi/AGENTS.md
```

```
# Operating rules
- Be brief and clear.
- Remember what this user tells you (recipes, appointments, kids' schedules).
- If asked for something you can't do, explain simply what you can help with instead.
```

Copy for the kids:

```
[zima-oc]$ cp ~/.openclaw/workspace-meenakshi/AGENTS.md ~/.openclaw/workspace-daanya/AGENTS.md
[zima-oc]$ cp ~/.openclaw/workspace-meenakshi/AGENTS.md ~/.openclaw/workspace-lohith/AGENTS.md
```

### 6.5 Per-agent tool restrictions (no sandbox — just deny-lists)

Edit the master config:

```
[zima-oc]$ nano ~/.openclaw/openclaw.json
```

Merge this `agents` block (preserve existing fields):

```json
{
  "agents": {
    "defaults": {
      "model": "ollama/qwen3.6:latest",
      "maxConcurrent": 2,
      "maxToolCallsPerTurn": 15
    },
    "list": [
      {
        "id": "main",
        "workspace": "~/.openclaw/workspace",
        "model": "ollama/qwen3.6:latest"
      },
      {
        "id": "meenakshi",
        "workspace": "~/.openclaw/workspace-meenakshi",
        "model": "ollama/qwen3.6:latest",
        "tools": {
          "deny": ["exec", "write", "edit", "apply_patch", "browser"]
        },
        "skills": ["memory", "web"]
      },
      {
        "id": "daanya",
        "workspace": "~/.openclaw/workspace-daanya",
        "model": "ollama/qwen3.6:latest",
        "tools": {
          "deny": ["exec", "write", "edit", "apply_patch", "browser"]
        },
        "skills": ["memory", "web"]
      },
      {
        "id": "lohith",
        "workspace": "~/.openclaw/workspace-lohith",
        "model": "ollama/qwen3.6:latest",
        "tools": {
          "deny": ["exec", "write", "edit", "apply_patch", "browser"]
        },
        "skills": ["memory", "web"]
      }
    ]
  }
}
```

**Note on "no sandbox":** `main` has full tool access (that's you). Family agents are prevented from running shell commands, editing files, or spawning a browser by tool-deny alone. Per-agent workspace isolation still means Meenakshi can't accidentally read Daanya's memory or vice versa — workspaces are cleanly separated. What's gone vs v2 is the Docker-backed process sandbox. Honest trade: if the agent itself were ever jailbroken into ignoring its deny-list (unlikely on a local model you control), there's no second line of defence. For home family use, this is an acceptable trade for zero Docker overhead.

Restart:

```
[zima-oc]$ systemctl --user restart openclaw
[zima-oc]$ openclaw agents list --bindings
```

**Phase 6 complete.**

---

## Phase 7 — Telegram + Discord with per-user routing (40 min)

### 7.1 Create four Telegram bots

One bot per agent. On your phone, message `@BotFather` → `/newbot` → follow prompts. Repeat four times.

| Agent | Suggested username | Save token as |
|---|---|---|
| main | `molty_gopala_bot` | `TG_TOKEN_MAIN` |
| meenakshi | `molty_meena_bot` | `TG_TOKEN_MEENA` |
| daanya | `molty_daanya_bot` | `TG_TOKEN_DAANYA` |
| lohith | `molty_lohith_bot` | `TG_TOKEN_LOHITH` |

For each bot: BotFather → `/setprivacy` → select the bot → **Disable** (so the bot can see group messages if you add it to a family group later).

### 7.2 Find each user's Telegram numeric ID

The safe method: each user DMs their respective bot once, then:

```
[zima-oc]$ openclaw logs --follow
```

When they message, the log shows `from.id`. Record numeric IDs:

- `TG_ID_GOPALA`
- `TG_ID_MEENA`
- `TG_ID_DAANYA`
- `TG_ID_LOHITH`

### 7.3 Configure Telegram (multi-account)

```
[zima-oc]$ nano ~/.openclaw/openclaw.json
```

Merge this `channels` block:

```json
{
  "channels": {
    "telegram": {
      "enabled": true,
      "dmPolicy": "allowlist",
      "groupPolicy": "allowlist",
      "defaultAccount": "main",
      "accounts": {
        "main": {
          "botToken": "<TG_TOKEN_MAIN>",
          "allowFrom": ["<TG_ID_GOPALA>"]
        },
        "meenakshi": {
          "botToken": "<TG_TOKEN_MEENA>",
          "allowFrom": ["<TG_ID_MEENA>"]
        },
        "daanya": {
          "botToken": "<TG_TOKEN_DAANYA>",
          "allowFrom": ["<TG_ID_DAANYA>"]
        },
        "lohith": {
          "botToken": "<TG_TOKEN_LOHITH>",
          "allowFrom": ["<TG_ID_LOHITH>"]
        }
      }
    }
  }
}
```

`dmPolicy: "allowlist"` is the docs' recommended pattern for one-owner bots — it's durable in config and survives restarts (unlike pairing, which has to be re-approved).

### 7.4 Bind each Telegram account to its agent

```
[zima-oc]$ openclaw agents bind --agent main      --bind telegram:main
[zima-oc]$ openclaw agents bind --agent meenakshi --bind telegram:meenakshi
[zima-oc]$ openclaw agents bind --agent daanya    --bind telegram:daanya
[zima-oc]$ openclaw agents bind --agent lohith    --bind telegram:lohith
[zima-oc]$ openclaw agents list --bindings
```

### 7.5 Restart and test

```
[zima-oc]$ systemctl --user restart openclaw
[zima-oc]$ openclaw channels status --probe
```

Each user DMs their bot. Test by asking each "who are you?" — Daanya's bot should sound like a kid helper, yours like a professional. If the persona's wrong, the binding is wrong.

### 7.6 Discord (you only)

1. `https://discord.com/developers/applications` → **New Application** → `Molty`.
2. **Bot** tab → **Add Bot** → copy token.
3. Enable **Message Content Intent**.
4. **OAuth2 → URL Generator** → scopes `bot` + `applications.commands`; permissions `Send Messages`, `Read Message History`, `Attach Files`, `Embed Links`. Open the URL → add to a personal server.
5. Discord settings → enable **Developer Mode** → right-click your name → **Copy User ID** → save as `DC_ID_GOPALA`.

Add to `openclaw.json`:

```json
{
  "channels": {
    "discord": {
      "enabled": true,
      "botToken": "<DISCORD_TOKEN>",
      "dmPolicy": "allowlist",
      "allowFrom": ["<DC_ID_GOPALA>"]
    }
  }
}
```

Bind:

```
[zima-oc]$ openclaw agents bind --agent main --bind discord:default
[zima-oc]$ systemctl --user restart openclaw
```

Test by DMing your Discord bot.

**Phase 7 complete.**

---

## Phase 8 — Google OAuth: Gmail + Calendar + Drive (30 min)

Only for the `main` agent. Family agents don't get Google access.

### 8.1 Google Cloud project

On your laptop, signed in as `sgopala.ai@gmail.com`:

1. `https://console.cloud.google.com`
2. **Create project** → `openclaw-personal` → select it

### 8.2 Enable APIs

**APIs & Services → Library**, enable:
- Gmail API
- Google Calendar API
- Google Drive API
- Google People API
- Pub/Sub API (only if you want Phase 8.7 real-time push)

### 8.3 OAuth consent

**APIs & Services → OAuth consent screen**:
- User type: **External**
- App name: `openclaw-personal`
- Support email + Developer contact: `sgopala.ai@gmail.com`
- Scopes:
  - `https://www.googleapis.com/auth/gmail.modify`
  - `https://www.googleapis.com/auth/calendar`
  - `https://www.googleapis.com/auth/drive.readonly`
  - `https://www.googleapis.com/auth/contacts.readonly`
- Test users: add `sgopala.ai@gmail.com`

Keep in **Testing** mode.

### 8.4 OAuth client

**Credentials → Create Credentials → OAuth client ID**:
- Type: **Desktop app**
- Name: `openclaw-cli`
- Download JSON → save as `client_secret.json`

Copy to the ZimaBoard:

```
scp client_secret.json <your-user>@192.168.0.13:/tmp/
ssh <your-user>@192.168.0.13
[zima]$ sudo mv /tmp/client_secret.json /home/openclaw/.openclaw/google-creds.json
[zima]$ sudo chown openclaw:openclaw /home/openclaw/.openclaw/google-creds.json
[zima]$ sudo chmod 600 /home/openclaw/.openclaw/google-creds.json
```

### 8.5 Install and authorise skills

```
[zima-oc]$ openclaw skills list
[zima-oc]$ openclaw skills install gmail calendar drive
[zima-oc]$ openclaw configure --section skills
```

The wizard walks you through each skill, opening an auth URL per service. Authenticate on your laptop browser as `sgopala.ai@gmail.com`, paste each returned code back.

**If `openclaw skills install` doesn't show those names**, your version may deliver them differently. Run:

```
[zima-oc]$ openclaw docs gmail
```

That queries the live doc index for the current install path.

### 8.6 Safety guardrails

```
[zima-oc]$ nano ~/.openclaw/openclaw.json
```

Add:

```json
{
  "skills": {
    "gmail": {
      "confirmSend": true,
      "maxRecipients": 5,
      "auditLog": "/mnt/nas/workspace/audit/gmail.log"
    },
    "calendar": {
      "confirmModify": true
    }
  }
}
```

### 8.7 (Optional) Gmail Pub/Sub push

For real-time email triggers (e.g., "auto-summarise emails from my accountant"), see `https://docs.openclaw.ai/automation/gmail-pubsub`. Skip for now — pull-based ("any new emails?") works fine without it.

### 8.8 Restrict Google skills to `main` only

Family agents in the `agents.list[]` block already have `"skills": ["memory", "web"]` — explicitly not including gmail/calendar/drive. That's the restriction.

Restart and verify:

```
[zima-oc]$ systemctl --user restart openclaw
[zima-oc]$ openclaw agent --message "List my 3 most recent emails."
```

Then have Meenakshi's bot try the same — it should say it can't.

**Phase 8 complete.**

---

## Phase 9 — Memory, web search, automations (25 min)

### 9.1 Point embeddings at the Jetson

```
[zima-oc]$ nano ~/.openclaw/openclaw.json
```

Merge this into your `models` block:

```json
{
  "models": {
    "providers": {
      "ollama": {
        "baseUrl": "http://192.168.0.12:11434"
      },
      "ollama-embed": {
        "baseUrl": "http://192.168.0.6:11434"
      }
    },
    "embeddings": {
      "provider": "ollama-embed",
      "model": "nomic-embed-text"
    }
  }
}
```

This defines two separate Ollama providers — `ollama` for inference (GX10), `ollama-embed` for embeddings (Jetson). Memory and document ingestion use the embeddings provider; chat uses the inference provider.

Note: if the exact config key for a second provider differs in your OpenClaw version, run `openclaw docs embeddings` to verify. The concept (two separate base URLs) is correct; the JSON schema details may need a tweak.

### 9.2 Ollama Web Search

You already did `ollama signin` on the GX10 in Phase 3. Now wire it:

```
[zima-oc]$ openclaw configure --section web
```

Select **Ollama Web Search**. Confirm the Ollama host is `http://192.168.0.12:11434`.

Equivalent manual config:

```json
{
  "tools": {
    "web": {
      "search": {
        "provider": "ollama"
      }
    }
  }
}
```

Test:

```
[zima-oc]$ openclaw agent --message "Search the web for today's weather in Singapore and give me a 2-sentence summary."
```

### 9.3 Memory — already working per agent

Memory is workspace-scoped automatically. Verify:

```
[zima-oc]$ openclaw memory status
```

Each agent's memory lives under its workspace and uses the Jetson for embedding generation. Zero cross-contamination.

### 9.4 Cron automations

Example daily briefing for `main`:

```
[zima-oc]$ openclaw agent --message "Create a cron job that runs every day at 07:00 Asia/Singapore. It should: (1) summarise unread emails from the last 24 hours, (2) list today's calendar events, (3) search the web for 3 headlines each on AI, semiconductors, and Singapore business news. Send the result to me on Telegram. Name the job 'daily-briefing'."
```

List jobs:

```
[zima-oc]$ openclaw cron list
```

Other high-value ideas (ask Molty to create them):
- Weekly NAS index update: "every Sunday 02:00, scan /mnt/nas/readonly for new PDFs and index them"
- Weekly review: "every Friday 17:00, list open loops from this week's emails"
- Monthly subscription audit: "first of every month, flag recurring charges I haven't mentioned"

### 9.5 Document ingestion from NAS

```
[zima-oc]$ openclaw agent --message "Index all PDFs and .docx files under /mnt/nas/readonly into memory. Skip any file larger than 50 MB. Tell me what you ingested when done."
```

Runs slow first time (Jetson chugging through embeddings). Re-run as you add new docs, or schedule via cron.

### 9.6 ClawHub (community skills)

```
[zima-oc]$ openclaw skills list --available
[zima-oc]$ openclaw docs clawhub
```

Worth exploring: `rss`, `weather`, `github`, `obsidian`. Install with `openclaw skills install <n>`.

**Phase 9 complete.**

---

## Phase 10 — Backup, monitoring, maintenance (15 min)

### 10.1 Nightly backup of the brains

Everything the agents have learned lives in `~/.openclaw`. Back it up:

```
[zima]$ sudo nano /etc/cron.d/openclaw-backup
```

```
0 3 * * * openclaw tar czf /mnt/nas/workspace/backups/openclaw-$(date +\%F).tgz -C /home/openclaw .openclaw 2>/dev/null
0 4 * * 0 openclaw find /mnt/nas/workspace/backups -name 'openclaw-*.tgz' -mtime +30 -delete
```

Daily snapshot, weekly cleanup. OAuth tokens are included in the backup — keep the NAS workspace folder private.

### 10.2 Health

```
[zima-oc]$ openclaw doctor
[zima-oc]$ openclaw health
```

Run `openclaw doctor` whenever something feels off.

### 10.3 Logs

```
[zima-oc]$ openclaw logs --follow
# or
[zima-oc]$ journalctl --user -u openclaw -f
```

### 10.4 Updates

```
[zima-oc]$ openclaw update --channel stable
```

Monthly cadence. Run `openclaw doctor` immediately after every update.

### 10.5 Kill switch

```
[zima-oc]$ systemctl --user stop openclaw
```

Revoke external access:
- **Telegram:** BotFather → `/revoke` → new token → update `openclaw.json`
- **Discord:** Dev portal → Reset Token → update config
- **Google:** `https://myaccount.google.com/permissions` → remove `openclaw-personal` → redo Phase 8

---

## Phase 11 — Tailscale (dormant install, activate when needed)

**Skip this if you never leave home.** You can always come back and do it later. The point of doing it now is the "dormant install" so when you do need remote access (travel, emergency, family trip), it's a one-command activation rather than another whole setup.

### 11.1 Install Tailscale on all three servers (but don't bring it up)

```
[zima]$ curl -fsSL https://tailscale.com/install.sh | sh
[gx10]$ curl -fsSL https://tailscale.com/install.sh | sh
[jetson]$ curl -fsSL https://tailscale.com/install.sh | sh
```

This installs the daemon but doesn't authenticate — they sit dormant doing nothing.

### 11.2 When you actually need remote access (future)

From wherever you are:

```
[zima]$ sudo tailscale up --ssh
[gx10]$ sudo tailscale up --ssh
[jetson]$ sudo tailscale up
```

Install the Tailscale app on your phone, authenticate with the same account. You're on the mesh.

### 11.3 When you travel back home

```
[zima]$ sudo tailscale down
[gx10]$ sudo tailscale down
[jetson]$ sudo tailscale down
```

LAN-only again. Zero internet attack surface.

### 11.4 When Tailscale is on, upgrade SSH to keys

If SSH becomes reachable over Tailscale, passwords are no longer appropriate — switch to keys before bringing up `--ssh`:

```
ssh-copy-id <your-user>@192.168.0.13
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

Do this for GX10 and Jetson too if you expose their SSH.

**Phase 11 complete — dormant.**

---

## Phase 12 — Things you didn't ask but should know

### 12.1 Optional cloud failover

If local ever struggles on long research or complex reasoning:

```json
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "ollama/qwen3.6:latest",
        "fallbacks": ["anthropic/claude-opus-4-6"]
      }
    }
  }
}
```

Hard-cap monthly spend at the provider dashboard. See the docs on `/concepts/model-failover`.

### 12.2 Browser tool — still skip

The OpenClaw browser tool downloads Chromium (~500 MB) and runs it headless. On a Celeron N3450 with 8 GB RAM this chokes, and it's a large attack surface. Skip unless you have a specific must-have workflow.

### 12.3 Git-backup the workspaces (belt-and-braces)

Alongside the nightly tarball, OpenClaw docs recommend each workspace as a private git repo:

```
[zima-oc]$ cd ~/.openclaw/workspace
[zima-oc]$ git init && git add . && git commit -m "initial"
[zima-oc]$ git remote add origin git@github.com:<you>/openclaw-workspace-main.git
[zima-oc]$ git push -u origin main
```

Repeat for each workspace. Use **private** repos.

### 12.4 Jetson's `qwen2.5:1.5b` — what to do with it

We kept it installed but unused. Three realistic uses when you're ready:
- **Pre-filter classifier** — route simple messages ("what time is it") to 1.5B, complex ones to 35B. Premature optimisation right now.
- **Kids' agent model** — swap Daanya's and Lohith's model from `qwen3.6:latest` to `qwen2.5:1.5b` on the Jetson. Saves GX10 cycles at the cost of kid-agent quality. Judge by how the kids actually use their bots first.
- **Backup for chat** when the GX10 is down (for urgent, simple questions only — not tool chains).

### 12.5 Monthly review checklist

- `openclaw doctor` — fix anything flagged
- `df -h` on ZimaBoard and NAS backup folder
- Google OAuth still active at `myaccount.google.com/permissions`
- Gmail audit log (`/mnt/nas/workspace/audit/gmail.log`) — skim sent emails
- If Tailscale is active: admin console → remove stale devices

### 12.6 Onboarding each family member

For Meenakshi / Daanya / Lohith:

1. Send them the direct link to their Telegram bot (username).
2. Have them DM it once to register their numeric ID (you already did this in Phase 7.2).
3. Walk them through "ask Molty anything" once.
4. Hand them the one-pager (Appendix C).

### 12.7 What NOT to do

- Don't give `main` `sudo`.
- Don't share `~/.openclaw/*.json` token files — they're passwords.
- Don't expose port 18789 (gateway) publicly.
- Don't run `openclaw` commands as root — the daemon is `openclaw` user on purpose.
- Don't ignore `openclaw doctor` output.

---

## Troubleshooting

| Symptom | First check |
|---|---|
| Bot doesn't respond on Telegram | `openclaw channels status --probe`, then `openclaw logs --follow` |
| "Connection refused" to GX10 | `curl http://192.168.0.12:11434/api/tags` — if fails, Phase 3 firewall/systemd |
| "Connection refused" to Jetson embeddings | `curl http://192.168.0.6:11434/api/tags` — if fails, Phase 2 firewall/systemd |
| Slow first response | Model cold-start; increase `OLLAMA_KEEP_ALIVE` |
| Family bot talks like main agent | Binding wrong. `openclaw agents list --bindings` |
| Memory not persisting | Embeddings unreachable; check Jetson |
| NAS mount gone after reboot | `sudo mount -a`; verify fstab syntax |
| Gmail auth fails | Token expired; `openclaw configure --section skills` |
| Agent won't stop looping | `openclaw sessions list`, `openclaw sessions kill <id>`; tighten `maxToolCallsPerTurn` |
| Config changes ignored | `systemctl --user restart openclaw` after editing `openclaw.json` |

Universal first command: **`openclaw doctor`**.

---

## Appendix A — Architecture

```
                          Internet (outbound only: news, search, Google APIs)
                                               ^
                                               |
  [Phones, LAN or mobile data] ----Telegram/Discord---- (cloud) ---- OpenClaw gateway
                                                                    (outbound polling)

  HOME LAN (192.168.0.0/24):

  +-----------------+           NFS           +------------------------------+
  | ZimaOS NAS      |<------------------------|   ZimaBoard Gen1             |
  | 192.168.0.10    |  /mnt/nas/readonly (ro) |   192.168.0.13               |
  |                 |  /mnt/nas/workspace(rw) |   OpenClaw gateway           |
  +-----------------+                         |   4 isolated agents          |
                                              +-------+---------+------------+
                                                      |         |
                                  Ollama inference    |         |   Ollama embeddings
                                                      v         v
                                       +----------------+   +---------------------+
                                       | GX10 Ascent    |   | Jetson Orin Nano    |
                                       | 192.168.0.12   |   | 192.168.0.6         |
                                       | qwen3.6:latest |   | nomic-embed-text    |
                                       | Web Search     |   | (qwen2.5:1.5b spare)|
                                       +----------------+   +---------------------+

  (Tailscale installed dormant on all three servers for future remote activation.)
```

---

## Appendix B — File map

```
/home/openclaw/
├── .openclaw/
│   ├── openclaw.json                # master config
│   ├── google-creds.json            # OAuth client secret (BACK UP, 600 perms)
│   ├── agents/
│   │   ├── main/agent/auth-profiles.json         # BACK UP — OAuth refresh tokens
│   │   ├── meenakshi/agent/auth-profiles.json
│   │   ├── daanya/agent/auth-profiles.json
│   │   └── lohith/agent/auth-profiles.json
│   ├── workspace/                   # main
│   │   ├── SOUL.md
│   │   ├── AGENTS.md
│   │   ├── cron.json
│   │   └── skills/
│   ├── workspace-meenakshi/
│   │   ├── SOUL.md
│   │   └── AGENTS.md
│   ├── workspace-daanya/
│   └── workspace-lohith/
│
/mnt/nas/
├── readonly/                        # NAS data main agent can read
└── workspace/
    ├── audit/gmail.log              # email-send audit
    └── backups/
        └── openclaw-YYYY-MM-DD.tgz  # nightly snapshots
```

---

## Appendix C — One-pager for family

Print one per person.

> **Meet Molty — your personal AI helper**
>
> Molty is a helper that lives on our home server. You talk to your own Molty on Telegram.
> Your Molty is yours — it doesn't know what the others are saying.
>
> **What Molty can do**
> - Answer questions
> - Help with writing, schoolwork, curiosity
> - Remember stuff you tell it ("my piano recital is in March")
> - Search the web for facts
>
> **What Molty can't do**
> - Send messages to other people for you
> - Delete or change files on the computer
> - See or talk about anyone else's Molty
>
> **If Molty says something odd**
> - Tell Gopala. It's a computer, it occasionally glitches.
>
> **If Molty stops replying**
> - Tell Gopala.
>
> **Fun prompts to try**
> - "Tell me a weird fact about octopuses"
> - "Help me plan a birthday party for 10 kids"
> - "Explain photosynthesis like I'm 8"

---

## Done

Phase 1 tonight, then stop. Every phase is a checkpoint. First command when anything's off: **`openclaw doctor`**.
