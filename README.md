# NemoClaw on PCAI — Helm import

Deploys **NemoClaw** (the OpenClaw agent gateway) OR **Hermes Agent** (Nous Research) to
**HPE Private Cloud AI (PCAI)** as a Helm import, exposed through the EZUA portal and
an Istio `VirtualService`. The LLM is the PCAI-internal LiteLLM proxy.

**Pick ONE agent** via `agent:` in values.yaml — `openclaw` (default, backward-compatible)
or `hermes`. Exactly one agent container runs per pod. Both agents can use the same
Telegram bot token.

Everything in this repo is managed **through the PCAI web UI**. You import the app and verify it in the portal.


## Layout

```
logo.svg                     Logo shown in the PCAI portal (NVIDIA symbol)
porting.md                   How NemoClaw was ported to PCAI
nemoclaw/
├── 0.1.0/                   Version folder — the Helm chart (v0.1.0)
│   ├── Chart.yaml
│   ├── values.yaml          agent: openclaw|hermes (default: openclaw)
│   ├── files/patch-ui.js        Boot-time UI patcher (OpenClaw only)
│   ├── files/telegram-verify.js One-off Telegram channel validation (both agents)
│   └── templates/           deployment, service, configmap, secret, pvc, virtualservice
└── nemoclaw-0.1.0.tgz       Helm package of 0.1.0/ (top-level dir = nemoclaw)
```


## What gets deployed

| Resource       | Name                     | Purpose                                             |
|----------------|--------------------------|-----------------------------------------------------|
| Secret         | `nemoclaw-gateway-token` | Static gateway token + (hermes) API key + Telegram  |
| ConfigMap      | `nemoclaw-openclaw-config` | Seeded agent config (openclaw.json OR hermes config) |
| PVC            | `nemoclaw-agent-state`   | Agent state (10Gi, shared sub-paths per agent)      |
| Service        | `nemoclaw`               | ClusterIP — port 80→18789 (OC) or 80→18790+8642 (Hermes) |
| Deployment     | `nemoclaw`               | Single agent container (istio sidecar)              |
| VirtualService | `nemoclaw-vs`            | `https://nemoclaw.<your-pcai-domain>`               |


## Deploy (via the PCAI portal — no kubectl)

1. **Open the PCAI portal → Applications → Import / Deploy** (the BYOA /
   "Bring Your Own App" flow).
2. **Point it at this framework** — upload the `nemoclaw-0.1.0.tgz` chart (the
   portal also picks up `logo.png`).
3. **Fill in the values** in the portal's values form:
   - **`agent`** — `openclaw` (default, NemoClaw gateway) or `hermes` (Hermes Agent).
   - **`domain.base`** — your PCAI base domain (e.g. `aie.example.lab`); the
     dashboard host becomes `nemoclaw.<domain.base>`.
   - **`litellm.apiKey`** — the LiteLLM master key (the portal fetches it from
     the `litellm-helm-masterkey` secret in the LiteLLM namespace, or you paste
     it). The committed value is a placeholder and is never stored in the repo.
   - **`litellm.baseUrl`** / **`litellm.model`** — the internal LiteLLM proxy
     (`qwen3-8-27b-int4-dflash2-r2`).
   - **`persistence.storageClassName`** — your PCAI storage class.
   - **`telegram.*`** (optional) — `botToken` from @BotFather, `testChatId`,
     `allowAll` (default `true`). The real token is entered here, never
     committed.
   - **`hermes.apiServerKey`** (hermes only) — API key for the Hermes dashboard
     + OpenAI-compatible API. Required when `agent: hermes`.
4. **Deploy.** The portal shows the app's install progress and, once done, a
   **ready / ok** health state plus the dashboard URL and the "Open" button.

The import is idempotent — re-running it re-applies the current values and
re-deploys. Secrets are supplied in the UI (or read from the cluster) and are
**never committed** to the repo. `domain.base` is a deploy-time value, so the
same chart works on any PCAI platform / domain.


## Key values

### Common (both agents)

- `agent: openclaw` (default) or `agent: hermes`
- `litellm.baseUrl` = `http://litellm-helm.<litellm-namespace>.svc.cluster.local:4000/v1`
- `litellm.model` = `qwen3-8-27b-int4-dflash2-r2`
- `telegram.enabled` / `telegram.botToken` — optional Telegram channel; on
  first start a **one-off validation** runs (`files/telegram-verify.js`):
  `getMe` proves the token + egress, then a single test message is sent to a
  chat (non-fatal)
- `telegram.allowAll=true` (default) — the bot accepts **anyone** (no per-user
  pairing approval)
- `resources.limits.memory=2Gi` — required when a chat channel (Telegram) is
  enabled

### OpenClaw (`agent: openclaw`)

- `gateway.bind=lan`, `gateway.port=18789` — exposed on 0.0.0.0 so the
  Service/Istio can reach it
- `gateway.dangerouslyDisableDeviceAuth=true` — allow pairing from all devices
- `gateway.controlUi.root=/sandbox/.openclaw/ui` — writable UI root so the bare
  dashboard URL auto-connects (the "Open" button URL)
- `ui.root` = `/sandbox/.openclaw/ui`

### Hermes (`agent: hermes`)

- `hermes.apiServerKey` — API key authenticating the dashboard + API
- `hermes.apiPort=8642` — OpenAI-compatible API port (exposed on the service)
- `hermes.dashboardPort=18790` — web dashboard port (VHosts same nemoclaw.<domain>)
- `hermes.dashboardInternalPort=19119` — Hermes binds here on 127.0.0.1
- `hermes.model` — LLM model (same litellm endpoint as OpenClaw)
- The chart seeds `~/.hermes/config.yaml` + `.env` from the ConfigMap at pod start


## Verify (via the PCAI portal — no kubectl)

1. **App health** — PCAI portal → **Applications → `nemoclaw`**. The status
   should read **ready / ok**.
2. **Dashboard** — click the **"Open"** button (or the dashboard URL
   `https://nemoclaw.<domain.base>`). It should show a working dashboard.
   - OpenClaw: **Health OK** + working **Chat** section
   - Hermes: web dashboard with model routing + chat
3. **Telegram channel** (if enabled) — on first deploy the bot sends a **one-off
   test message** to your chat; after that it replies to DMs / group messages.
   A pairing code means `telegram.allowAll` is `false` — set it to `true` and
   re-deploy.

> No `kubectl` is needed at any point — the portal's Applications page gives
> you app status, the "Open" button, and a Logs view for the gateway.

## Deploy script (optional, for CLI deploys)

`./deploy.sh` packages the chart, uploads to chartmuseum, and creates the EzAppConfig.
Environment variables:

| Variable | Required | Default | Notes |
|----------|----------|---------|-------|
| `KUBECONFIG` | yes | — | PCAI kubeconfig path |
| `DOMAIN` | yes | — | PCAI base domain |
| `LITELLM_NAMESPACE` | yes | — | Namespace holding litellm master key |
| `CHARTMUSEUM_NAMESPACE` | no | `ez-chartmuseum-ns` | Chartmuseum namespace |
| `STORAGECLASS` | no | `nfs-csi` | PVC storage class |
| `AGENT` | no | `openclaw` | `openclaw` or `hermes` |
| `HERMES_API_KEY` | hermes only | — | Hermes API server key |
| `TELEGRAM_BOT_TOKEN` | no | — | Telegram bot token |
| `TELEGRAM_TEST_CHAT_ID` | no | — | Test message target chat |
