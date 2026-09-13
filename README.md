# NemoClaw on PCAI — Helm import

Deploys **NemoClaw** (the OpenClaw agent gateway) to **HPE Private Cloud AI
(PCAI)** as a Helm import, exposed through the EZUA portal (`EzAppConfig`) and
an Istio `VirtualService`. The LLM is the PCAI-internal LiteLLM proxy running
`qwen3-8-27b-int4-dflash2-r2`.

Everything in this repo is managed **through the PCAI web UI** — there is no
`kubectl` and no CLI. You import the app and verify it in the portal.

The repo follows the
[frameworks repo structure](https://github.com/ai-solution-eng/frameworks):
one framework folder (`nemoclaw/`) holding a version folder with the chart and
the chart tarball, plus a `logo.svg` and a `porting.md` at the root.

## Layout

```
logo.svg                     Logo shown in the PCAI portal (NVIDIA symbol)
porting.md                   How NemoClaw was ported to PCAI
nemoclaw/
├── 0.1.0/                   Version folder — the Helm chart (v0.1.0)
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── files/patch-ui.js        Boot-time UI patcher (injected into the ConfigMap)
│   ├── files/telegram-verify.js One-off Telegram channel validation (getMe + test message)
│   └── templates/           deployment, service, configmap, secret, pvc, virtualservice
└── nemoclaw-0.1.0.tgz       Helm package of 0.1.0/ (top-level dir = nemoclaw)
```

## What gets deployed

| Resource       | Name                     | Purpose                                             |
|----------------|--------------------------|-----------------------------------------------------|
| Secret         | `nemoclaw-gateway-token` | Static gateway token (baked at import time)         |
| ConfigMap      | `nemoclaw-openclaw-config` | Seeded `openclaw.json` + `patch-ui.js`             |
| PVC            | `nemoclaw-openclaw-state` | `/sandbox/.openclaw` agent state (10Gi)             |
| Service        | `nemoclaw`               | ClusterIP :80 → 18789                               |
| Deployment     | `nemoclaw`               | OpenClaw gateway (istio sidecar)                    |
| VirtualService | `nemoclaw-vs`            | `https://nemoclaw.<your-pcai-domain>`               |

Plus an **`EzAppConfig`** that registers the app with the EZUA portal so the
dashboard URL + token are shown to users automatically.

## Deploy (via the PCAI portal — no kubectl)

1. **Open the PCAI portal → Applications → Import / Deploy** (the BYOA /
   "Bring Your Own App" flow).
2. **Point it at this framework** — upload the `nemoclaw-0.1.0.tgz` chart (the
   portal also picks up `logo.svg` and `porting.md`). The portal creates the
   `EzAppConfig` and installs the chart for you.
3. **Fill in the values** in the portal's values form (the chart's defaults
   carry placeholders that the UI prompts for):
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
4. **Deploy.** The portal shows the app's install progress and, once done, a
   **ready / ok** health state plus the dashboard URL and the "Open" button.

The import is idempotent — re-running it re-applies the current values and
re-deploys. Secrets are supplied in the UI (or read from the cluster) and are
**never committed** to the repo. `domain.base` is a deploy-time value, so the
same chart works on any PCAI platform / domain.

## Key values (set in the portal values form)

- `image`: `ghcr.io/nvidia/openshell-community/sandboxes/openclaw@sha256:b3d8…`
  (pinned digest from the NemoClaw blueprint)
- `gateway.bind=lan`, `gateway.port=18789` — exposed on 0.0.0.0 so the
  Service/Istio can reach it
- `gateway.dangerouslyDisableDeviceAuth=true` — allow pairing from all devices
- `gateway.controlUi.root=/sandbox/.openclaw/ui` — writable UI root so the bare
  dashboard URL auto-connects (the "Open" button URL)
- `litellm.baseUrl` = `http://litellm-helm.<litellm-namespace>.svc.cluster.local:4000/v1`
- `litellm.model` = `qwen3-8-27b-int4-dflash2-r2`
- `domain.base` = `<your-pcai-domain>` (deploy-time value) — the dashboard
  host is derived as `nemoclaw.<domain.base>`
- `telegram.enabled` / `telegram.botToken` — optional Telegram channel; on
  first start a **one-off validation** runs (`files/telegram-verify.js`):
  `getMe` proves the token + egress, then a single test message is sent to a
  chat (non-fatal)
- `telegram.allowAll=true` (default) — the bot accepts **anyone** (no per-user
  pairing approval): `dmPolicy`/`groupPolicy=open` + `allowFrom=["*"]`. Set
  `false` to use OpenClaw's default "pairing" gate (new users must send a
  pairing code and an operator approves it).
- `resources.limits.memory=2Gi` — required when a chat channel (Telegram) is
  enabled, so the gateway's JS heap doesn't OOM at startup.

## Verify (via the PCAI portal — no kubectl)

1. **App health** — PCAI portal → **Applications → `nemoclaw`**. The status
   should read **ready / ok** (the portal health-checks the app and the
   VirtualService). If it shows a warning, open the app's **Logs** tab in the
   portal — it surfaces the same gateway logs you'd get from the cluster.
2. **Dashboard** — click the **"Open"** button (or the dashboard URL
   `https://nemoclaw.<domain.base>`). It should show **Health OK** and a
   working **Chat** section — send a message and you should get an LLM reply.
3. **Telegram channel** (if enabled) — on first deploy the bot sends a **one-off
   test message** to your chat (the `testChatId`), proving the channel is live.
   After that, message the bot (DM or group) and it should reply. If you see a
   **pairing code** instead, that means `telegram.allowAll` is `false`; set it
   to `true` and re-deploy to allow anyone.

> No `kubectl` is needed at any point — the portal's Applications page gives
> you app status, the "Open" button, and a Logs view for the gateway.
