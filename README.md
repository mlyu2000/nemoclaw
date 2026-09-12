# NemoClaw on PCAI — Helm deployment

Deploys **NemoClaw** (the OpenClaw agent gateway) to the **PCAI** Kubernetes
platform as a single Helm release, exposed through the EZUA portal
(`EzAppConfig`) and an Istio `VirtualService`. The LLM is the PCAI-internal
LiteLLM proxy running `qwen3-8-27b-int4-dflash2-r2`.

The repo follows the
[frameworks repo structure](https://github.com/ai-solution-eng/frameworks):
one framework folder (`nemoclaw/`) holding a logo, a version folder with the
chart, a `porting.md`, and the chart tarball.

## Layout

```
nemoclaw/
├── logo.svg                 Logo used during the PCAI import
├── 0.1.0/                   Version folder — the Helm chart (v0.1.0)
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── files/patch-ui.js        Boot-time UI patcher (injected into the ConfigMap)
│   ├── files/telegram-verify.js One-off Telegram channel validation (getMe + test message)
│   └── templates/           deployment, service, configmap, secret, pvc, virtualservice
├── porting.md               How NemoClaw was ported to PCAI (PCAI)
└── nemoclaw-0.1.0.tgz       Helm package of 0.1.0/ (top-level dir = nemoclaw)
deploy.sh                    End-to-end deploy: fetch master key → bake →
                             package → upload to chartmuseum → create EzAppConfig
build/                       Generated .tgz (git-ignored)
work/                        Generated chart copy with the real key baked in (git-ignored)
```

## What gets deployed

| Resource       | Name                     | Purpose                                             |
|----------------|--------------------------|-----------------------------------------------------|
| Secret         | `nemoclaw-gateway-token` | Static gateway token (baked at deploy time)         |
| ConfigMap      | `nemoclaw-openclaw-config` | Seeded `openclaw.json` + `patch-ui.js`             |
| PVC            | `nemoclaw-openclaw-state` | `/sandbox/.openclaw` agent state (10Gi, nfs-csi)   |
| Service        | `nemoclaw`               | ClusterIP :80 → 18789                               |
| Deployment     | `nemoclaw`               | OpenClaw gateway (istio sidecar)                    |
| VirtualService | `nemoclaw-vs`            | `https://nemoclaw.<your-pcai-domain>`               |

Plus an **`EzAppConfig`** that registers the app with the EZUA portal so the
dashboard URL + token are shown to users automatically.

## Deploy

```bash
export KUBECONFIG=<path-to-pcai-kubeconfig>
export DOMAIN=<your-pcai-domain>          # e.g. aie.example.lab -> dashboard = https://nemoclaw.$DOMAIN
export LITELLM_NAMESPACE=<litellm-namespace>   # ns of the litellm-helm-masterkey secret
export STORAGECLASS=<pcai-storageclass>   # optional, default nfs-csi
# optional — enables the Telegram channel + one-off test message:
export TELEGRAM_BOT_TOKEN="<id>:<secret>"   # from @BotFather (never committed)
export TELEGRAM_TEST_CHAT_ID="<chat_id>"    # optional; if empty, the bot's most recent chat is used
./deploy.sh
```

`deploy.sh` is **idempotent** — re-running it re-bakes the current values,
re-uploads the chart, and re-creates the EzAppConfig. The litellm master key
is read live from the cluster secret
`<litellm-namespace>/litellm-helm-masterkey` and is **never committed**.
`domain.base` is filled from `$DOMAIN` at deploy time, so the same chart
works on any PCAI platform / domain.

## Key values

- `image`: `ghcr.io/nvidia/openshell-community/sandboxes/openclaw@sha256:b3d8…`
  (pinned digest from the NemoClaw blueprint)
- `gateway.bind=lan`, `gateway.port=18789` — exposed on 0.0.0.0 so the
  Service/Istio can reach it
- `gateway.dangerouslyDisableDeviceAuth=true` — allow pairing from all devices
- `gateway.controlUi.root=/sandbox/.openclaw/ui` — writable UI root so the bare
  dashboard URL auto-connects (the "Open" button URL)
- `litellm.baseUrl` = `http://litellm-helm.<litellm-namespace>.svc.cluster.local:4000/v1`
- `litellm.model` = `qwen3-8-27b-int4-dflash2-r2`
- `domain.base` = `<your-pcai-domain>` (deploy-time variable) — the dashboard
  host is derived as `nemoclaw.<domain.base>`
- `telegram.enabled` / `telegram.botToken` — optional Telegram channel; on
  first start a **one-off validation** runs (`files/telegram-verify.js`):
  `getMe` proves the token + egress, then a single test message is sent to a
  chat (non-fatal; see `telegram-verify.log`)

## Verify

```bash
kubectl -n nemoclaw get deploy,svc,pvc
kubectl -n nemoclaw logs deploy/nemoclaw --tail=50
# in-cluster dashboard check (200 = up):
kubectl -n nemoclaw exec deploy/nemoclaw -c nemoclaw -- \
  curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18789/
```

Dashboard: `https://nemoclaw.<domain.base>` (the "Open" button) — should
show **Health OK** and a working Chat section.

Telegram one-off validation log (per pod start):
```bash
kubectl -n nemoclaw exec deploy/nemoclaw -c nemoclaw -- cat /sandbox/.openclaw/telegram-verify.log
```
Expected: `token valid: bot @@<username>` and, once someone has messaged the
bot, `SUCCESS: one-off test message delivered to chat <id>`.
