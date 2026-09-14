# NemoClaw (OpenClaw) + Hermes Agent — PCAI port

This repo ports **NVIDIA NemoClaw / OpenClaw** (an always-on AI-agent gateway)
**and Hermes Agent (Nous Research)** to HPE Private Cloud AI (PCAI) as a BYOA
Helm import, following the
[frameworks repo structure](https://github.com/ai-solution-eng/frameworks).

## Layout (per the frameworks guideline)

| Path | Purpose |
|------|---------|
| `logo.png` | Logo shown in the PCAI portal (NVIDIA symbol). |
| `nemoclaw-0.2.1.tgz` | The importable Helm package, **at the repo root** (top-level dir = `nemoclaw`). |
| `nemoclaw/0.2.1/` | Version folder — the current Helm chart (v0.2.1; OpenClaw 2026.3.11 + Hermes sandbox). |
| `nemoclaw/0.1.0/` | Previous chart version (kept for history). |
| `porting.md` | This file — how the framework was ported to PCAI. |

Rebuild the package with `helm package nemoclaw/0.2.1 -d .` (keeps the tgz at
the root). The chart is imported through the PCAI portal — there is no
deploy script in this repo (CS1 dev-stage deployment automation is kept
outside the repo).

## What the chart does

A single-gateway sandbox app exposed on the PCAI Istio `ezaf-gateway` as
`https://<appPrefix>.<your-pcai-domain>` (an Istio `VirtualService`), with:

- **Agent selector** — `agent: openclaw` (default, NemoClaw/OpenClaw gateway) or
  `agent: hermes` (Hermes Agent, Nous Research). Exactly one agent container per
  pod. Both agents use the same LiteLLM endpoint.
- **Per-runtime resource names** — `fullnameOverride` (e.g. `nemoclaw-openclaw`
  / `nemoclaw-hermes`) gives each agent runtime its own deployment/service/secret/
  PVC/VirtualService names so two side-by-side deployments are distinguishable
  in the cluster and the portal. `domain.appPrefix` gives each its own VS host.
- **OpenClaw path** (`agent: openclaw`): static dashboard URL + static gateway
  token baked at import time (no post-deploy curl/scrape). The token is generated
  by the PCAI portal or entered in the values form.
- **Hermes path** (`agent: hermes`): Hermes Agent with OpenAI-compatible API on
  port 8642 + web dashboard on port 18790 (same host as the API). The API server
  key and the dashboard admin password are baked at import time. The chart seeds
  `~/.hermes/config.yaml` + `.env` from the ConfigMap at pod start.
- **OpenClaw gateway** bound to LAN on port 18789, `dangerouslyDisableDeviceAuth`
  enabled (all-device pairing) and `allowedOrigins: ["*"]`.
- **LLM via the PCAI internal LiteLLM proxy** (`litellm-helm` in
  `<litellm-namespace>`), model `qwen3-8-27b-int4-dflash2-r2` (the registered
  name — note the `-r2` variant).
- **Telegram channel (optional)** — `telegram.enabled` + `telegram.botToken`
  register the channel for the selected agent. On each pod start a **one-off
  validation** (`files/telegram-verify.js`) runs *before* the gateway starts:
  `getMe` proves the token + outbound egress to `api.telegram.org`, then a
  single test message is sent to a chat (the most recent from `getUpdates`, or
  `telegram.testChatId`). It is bounded (20s) and non-fatal (`|| true`), so it
  can never block the deploy; results land in
  `/sandbox/.openclaw/telegram-verify.log` (OpenClaw) or
  `/sandbox/.hermes/telegram-verify.log` (Hermes).
- **Access control** — `telegram.allowAll` (default `true`) sets
  `dmPolicy`/`groupPolicy=open` + `allowFrom=["*"]` so **anyone** can use the
  bot (no per-device pairing approval).
- **Persistence** — `/sandbox/.openclaw` (OpenClaw) or `/sandbox/.hermes` (Hermes)
  on the PVC (`<pcai-storageclass>`, default `nfs-csi`), 10Gi.

## PCAI-specific adaptations

- **Agent selector** — `agent: openclaw` (default, backward-compatible) or
  `agent: hermes`. Exactly one agent container per pod. The chart renders
  different ConfigMaps, Secrets, Services, and VirtualServices per agent.
- **Domain / gateway**: exposed on the `ezaf-gateway` Istio gateway. The base
  domain (`domain.base`) and host prefix (`domain.appPrefix`) are deploy-time
  variables, so the dashboard host `<appPrefix>.<domain.base>` is fully dynamic
  and not tied to any single PCAI platform.
- **Distinct framework names** — the EzAppConfig `label` (what the portal shows
  as the framework/app name) is per-agent: `NemoClaw (OpenClaw)` vs
  `Hermes Agent`, so the two frameworks are distinguishable in the UI.
- **OpenClaw path** (`agent: openclaw`): same as before — static token + UI
  auto-connect via `patch-ui.js`.
- **Hermes path** (`agent: hermes`): uses the NemoClaw Hermes sandbox image
  (`ghcr.io/nvidia/nemoclaw/hermes-sandbox`), seeds `~/.hermes/config.yaml` +
  `.env` from the ConfigMap at pod start, exposes the API on port 8642 and the
  dashboard on port 18790 (same VS host). Dashboard admin basic-auth
  (`hermes.dashboardAuth`, username `admin`) — pin `password` at import for a
  known login, or leave empty for a random generated password.
- **LiteLLM auth**: the master key is a deploy-time value (`litellm.apiKey`)
  — pasted in the portal values form or fetched from the
  `litellm-helm-masterkey` secret. It is **never committed** (the committed
  `values.yaml` uses a `CHANGE_ME-litellm-master-key` placeholder).
- **Istio sidecar**: the agent pod gets a sidecar (namespace
  `istio-injection: enabled`); the sidecar forwards `X-Forwarded-For`.
- **Memory / probes**: the OpenClaw gateway's V8 heap is capped by the
  container memory limit (~521MB at 1Gi); a Telegram long-poll pushes it past
  that, so OpenClaw uses **2Gi** limits. Hermes (Python) uses **4Gi**
  (`hermes.resources.limits.memory`) — its boot loads ~50 plugins from NFS and
  the dashboard + gateway + Telegram long-poll together need more headroom.
  Both deployments get a **300s liveness initial delay** so the slow NFS boot
  isn't killed by the probe (a 60s delay crash-looped the Hermes gateway).
- **One Telegram bot token per deployment** — Telegram allows a single
  long-poll `getUpdates` per token; two deployments sharing a token collide
  and the losing gateway tears down. Use a distinct bot per agent runtime.

## Deploy (via the PCAI portal — no kubectl)

1. **PCAI portal → Applications → Import / Deploy** (the BYOA flow).
2. **Point it at this framework** — upload **`nemoclaw-0.2.1.tgz`** from the
   repo root (the portal also picks up `logo.png` and `porting.md`). It creates
   the `EzAppConfig` and installs the chart.
3. **Fill in the values** in the portal's values form:
   - **`agent`** — `openclaw` (default) or `hermes`.
   - `domain.base` (your PCAI base domain) and `domain.appPrefix` (host
     prefix; use `hermes` for a second deployment so the hosts differ).
   - `fullnameOverride` (optional; e.g. `nemoclaw-openclaw` / `nemoclaw-hermes`
     for distinct resource names).
   - `litellm.apiKey` (the LiteLLM master key), `litellm.baseUrl` /
     `litellm.model`, `persistence.storageClassName`, and optional `telegram.*`
     (a **distinct** bot token per deployment).
   - **`hermes.apiServerKey`** + **`hermes.dashboardAuth.password`** (hermes only).
   - Secrets are entered in the UI and are **never committed**.
4. **Deploy.** The portal shows install progress and, once done, a **ready**
   health state plus the dashboard URL and "Open" button.

The import is idempotent — re-running it re-applies the values and re-deploys.

## Verification (via the PCAI portal — no kubectl)

1. **App health** — PCAI portal → **Applications** → the app → status
   **ready**. Open the app's **Logs** tab for the agent logs.
2. **Dashboard** — click **"Open"** (or `https://<appPrefix>.<domain.base>`).
   - OpenClaw: **Health OK** + working **Chat** section.
   - Hermes: web dashboard with model routing + chat (admin login `admin` +
     the pinned password).
3. **Telegram channel** (if enabled) — the bot sends a **one-off test message**
   on first deploy (after you `/start` it); after that it replies to DMs / group
   messages. A pairing code means `telegram.allowAll` is `false` — set it to
   `true` and re-deploy.

> No `kubectl` is needed — the portal gives app status, the "Open" button, and
> a Logs view.
