# NemoClaw on PCAI — Helm import

Deploys **NemoClaw** (the OpenClaw agent gateway) OR **Hermes Agent** (Nous Research) to
**HPE Private Cloud AI (PCAI)** as a Helm import, exposed through the EZUA portal and
an Istio `VirtualService`. The LLM is the PCAI-internal LiteLLM proxy.

**Pick ONE agent** via `agent:` in values.yaml — `openclaw` (default, backward-compatible)
or `hermes`. Exactly one agent container runs per pod. For two side-by-side deployments
(one per agent), use a **different bot token per agent** (Telegram allows only one
long-poll `getUpdates` per token) and a different `domain.appPrefix` /
`fullnameOverride` per deployment so the hosts and resource names don't collide.

Everything in this repo is managed **through the PCAI web UI**. You import the app and verify it in the portal.

## Layout

```
logo.png                       Logo shown in the PCAI portal (NVIDIA symbol)
porting.md                     How NemoClaw was ported to PCAI
nemoclaw-0.2.1.tgz             Helm package of the chart (root level; top-level dir = nemoclaw)
nemoclaw/
├── 0.2.1/                     Version folder — the current Helm chart (v0.2.1)
│   ├── Chart.yaml
│   ├── values.yaml            agent: openclaw|hermes (default: openclaw)
│   ├── files/patch-ui.js        Boot-time UI patcher (OpenClaw only)
│   ├── files/telegram-verify.js One-off Telegram channel validation (both agents)
│   └── templates/           deployment, service, configmap, secret, pvc, virtualservice
└── 0.1.0/                     Previous chart version (kept for history)
```

The importable artifact is **`nemoclaw-0.2.1.tgz` at the repo root**. Rebuild it after
changing the chart with `helm package nemoclaw/0.2.1 -d .`.

## What gets deployed

Resource names follow `<fullnameOverride>-…`. By default `fullnameOverride` is empty and
resources are named `nemoclaw-…` (backward-compatible). For parallel per-agent
deployments, set `fullnameOverride: nemoclaw-openclaw` / `nemoclaw-hermes` so the
two frameworks are distinguishable in the cluster and the portal.

| Resource (default names) | Purpose                                             |
|--------------------------|-----------------------------------------------------|
| Secret `nemoclaw-gateway-token` | Static gateway token + (hermes) API key, dashboard password, litellm key, Telegram |
| ConfigMap `nemoclaw-openclaw-config` | Seeded agent config (openclaw.json OR hermes config) |
| PVC `nemoclaw-agent-state`   | Agent state (10Gi, shared sub-paths per agent)      |
| Service `nemoclaw`               | ClusterIP — port 80→18789 (OC) or 80→18790+8642 (Hermes) |
| Deployment `nemoclaw`               | Single agent container (istio sidecar)              |
| VirtualService `nemoclaw-vs`            | `https://<appPrefix>.<domain.base>` (default prefix `nemoclaw`) |

## Deploy (via the PCAI portal — no kubectl)

1. **Open the PCAI portal → Applications → Import / Deploy** (the BYOA /
   "Bring Your Own App" flow).
2. **Point it at this framework** — upload **`nemoclaw-0.2.1.tgz`** (the
   portal also picks up `logo.png` and `porting.md`).
3. **Fill in the values** in the portal's values form. **Empty fields are
   auto-detected from the cluster at install time** — you only need to fill in
   the ones you want to override:
   - **`agent`** — `openclaw` (default, NemoClaw gateway) or `hermes` (Hermes Agent).
   - **`domain.base`** — *(auto)* the PCAI base domain, detected from the most
     common host suffix across the Istio VirtualServices (e.g.
     `aie.cs1.ctc.sg.lab`). Set to override. The dashboard host is
     `<appPrefix>.<domain.base>`.
   - **`domain.appPrefix`** — the host prefix (default `nemoclaw`). Use
     `hermes` for a Hermes deployment next to an existing `nemoclaw` one.
   - **`fullnameOverride`** *(optional)* — e.g. `nemoclaw-hermes` for distinct
     resource names per agent runtime.
   - **`litellm.keyRef.namespace`** — *(auto)* the namespace owning the
     `litellm-helm-masterkey` secret; falls back to the release namespace. Set
     explicitly if LiteLLM lives elsewhere.
   - **`litellm.baseUrl`** — *(auto)* `http://litellm-helm.<ns>.svc.cluster.local:4000/v1`
     built from the resolved namespace.
   - **`litellm.apiKey`** — the LiteLLM master key (paste it, or have the
     portal fetch it from the `litellm-helm-masterkey` secret). The committed
     value is a `CHANGE_ME` placeholder and is never stored in the repo.
   - **`litellm.model`** — `qwen3-8-27b-int4-dflash2-r2` (default).
   - **`persistence.storageClassName`** — *(auto)* the cluster's default
     StorageClass (annotation `storageclass.kubernetes.io/is-default-class=true`).
     Set to override.
   - **`telegram.*`** (optional) — `botToken` from @BotFather (one token per
     deployment — two agents must NOT share a token), `testChatId`,
     `allowAll` (default `true`). The real token is entered here, never committed.
   - **`hermes.apiServerKey`** (hermes only) — API key for the Hermes dashboard
     + OpenAI-compatible API. Required when `agent: hermes`.
   - **`hermes.dashboardAuth.password`** (hermes only) — dashboard admin
     password. Empty → a random 24-char password generated at install. Pin a
     value (e.g. `EZP@ssw0rd`) for a known admin login (username `admin`).
4. **Deploy.** The portal shows the app's install progress and, once done, a
   **ready** health state plus the dashboard URL and the "Open" button.

The import is idempotent — re-running it re-applies the current values and
re-deploys. Secrets are supplied in the UI and are **never committed** to the repo.
`domain.base` / `domain.appPrefix` are deploy-time values, so the same chart
works on any PCAI platform / domain.

## Key values

### Common (both agents)

- `agent: openclaw` (default) or `agent: hermes`
- `fullnameOverride` (optional) — distinct resource names per runtime
- `domain.appPrefix` + `domain.base` — dashboard host `<appPrefix>.<base>`
- `litellm.baseUrl` = `http://litellm-helm.<litellm-namespace>.svc.cluster.local:4000/v1`
- `litellm.model` = `qwen3-8-27b-int4-dflash2-r2`
- `telegram.enabled` / `telegram.botToken` — optional Telegram channel; on
  first start a **one-off validation** runs (`files/telegram-verify.js`):
  `getMe` proves the token + egress, then a single test message is sent to a
  chat (non-fatal). **One bot token per deployment only** — two deployments
  polling the same token collide on `getUpdates`.
- `telegram.allowAll=true` (default) — the bot accepts **anyone** (no per-user
  pairing approval)

### OpenClaw (`agent: openclaw`)

- `gateway.bind=lan`, `gateway.port=18789` — exposed on 0.0.0.0 so the
  Service/Istio can reach it
- `gateway.dangerouslyDisableDeviceAuth=true` — allow pairing from all devices
- `gateway.controlUi.root=/sandbox/.openclaw/ui` — writable UI root so the bare
  dashboard URL auto-connects (the "Open" button URL)
- `ui.root` = `/sandbox/.openclaw/ui`
- Memory: `resources.limits.memory=2Gi` when a chat channel is enabled (the
  OpenClaw gateway's V8 heap is capped by the container limit).

### Hermes (`agent: hermes`)

- `hermes.apiServerKey` — API key authenticating the dashboard + API
- `hermes.apiPort=8642` — OpenAI-compatible API port (exposed on the service)
- `hermes.dashboardPort=18790` — web dashboard port (same host as the API)
- `hermes.dashboardAuth.username`/`password` — admin basic-auth (username
  `admin`); pin `password` for a known login
- `hermes.model` — LLM model (same litellm endpoint as OpenClaw)
- The chart seeds `~/.hermes/config.yaml` + `.env` from the ConfigMap at pod start
- Memory: `hermes.resources.limits.memory=4Gi` (gateway + dashboard + Telegram
  long-poll; the boot loads ~50 plugins). The liveness probe has a 300s
  initial delay so the slow NFS boot isn't mistaken for a crash.

## Verify (via the PCAI portal — no kubectl)

1. **App health** — PCAI portal → **Applications** → the app. The status
   should read **ready**.
2. **Dashboard** — click the **"Open"** button (or `https://<appPrefix>.<domain.base>`).
   - OpenClaw: **Health OK** + working **Chat** section
   - Hermes: web dashboard with model routing + chat (admin login: `admin` +
     the password you pinned)
3. **Telegram channel** (if enabled) — on first deploy the bot sends a **one-off
   test message** to your chat; after that it replies to DMs / group messages.
   A pairing code means `telegram.allowAll` is `false` — set it to `true` and
   re-deploy. Note: a bot cannot message first — send `/start` to it once.

> No `kubectl` is needed at any point — the portal's Applications page gives
> you app status, the "Open" button, and a Logs view for the gateway.
