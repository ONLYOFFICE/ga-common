# Jenkins review bot

Telegram bot behind the "🤖 Ask Claude" button on Jenkins build messages. It long-polls Telegram (no public URL needed), checks who pressed the button and dispatches the `jenkins-analyze-build.yaml` GitHub Actions workflow for that build.

## Setup

Create `.env` next to `docker-compose.yaml` and fill it in:

```env
TG_BOT_TOKEN=         # should be the same that send messages from Jenkins
GH_TOKEN=             # fine-grained PAT: repo ONLYOFFICE/ga-common, Actions: Read and write
GH_REPO=ONLYOFFICE/ga-common
GH_WORKFLOW=jenkins-analyze-build.yaml
GH_REF=master
ALLOWED_CHAT_IDS=
ALLOWED_USER_IDS=
```

- `ALLOWED_CHAT_IDS` is required: the chat(s) where the button works, comma-separated. Keep it equal to the `BUILD_NOTIFY_TELEGRAM_CHAT_ID` secret in GitHub, since the report goes there.
- `ALLOWED_USER_IDS` is optional: comma-separated user ids allowed to press the button; empty means anyone in the allowed chats.

## Run

```bash
docker compose up -d --build
```

Logs: `docker compose logs -f`.
