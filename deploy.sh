#!/usr/bin/env bash
# NemoClaw PCAI deploy — packages the chart, uploads to chartmuseum, creates the
# EzAppConfig. The litellm master key is fetched live from the cluster secret so
# it is never committed. Usage: KUBECONFIG=<path> ./deploy.sh
set -euo pipefail

# ── Environment overrides (PCAI-generic) ─────────────────────────────────────
export KUBECONFIG="${KUBECONFIG:-<path-to-pcai-kubeconfig>}"
LITELLM_NAMESPACE="${LITELLM_NAMESPACE:-<litellm-namespace>}"
CHARTMUSEUM_NAMESPACE="${CHARTMUSEUM_NAMESPACE:-ez-chartmuseum-ns}"
DOMAIN="${DOMAIN:-}"
STORAGECLASS="${STORAGECLASS:-nfs-csi}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_TEST_CHAT_ID="${TELEGRAM_TEST_CHAT_ID:-}"
# New: agent selector (openclaw or hermes) + hermes API key
AGENT="${AGENT:-openclaw}"
HERMES_API_KEY="${HERMES_API_KEY:-}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
CHART="$ROOT/nemoclaw/0.1.0"
BUILD="$ROOT/build"
NS="nemoclaw"
RELEASE="nemoclaw"
CHART_VERSION="0.1.0"

if [ "$KUBECONFIG" = "<path-to-pcai-kubeconfig>" ]; then
  echo "ERROR: set KUBECONFIG to your PCAI kubeconfig before running deploy.sh" >&2
  exit 1
fi
if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "<your-pcai-domain>" ]; then
  echo "ERROR: set DOMAIN to your PCAI base domain (e.g. DOMAIN=aie.example.lab)" >&2
  exit 1
fi
if [ -z "$LITELLM_NAMESPACE" ] || [ "$LITELLM_NAMESPACE" = "<litellm-namespace>" ]; then
  echo "ERROR: set LITELLM_NAMESPACE to your PCAI litellm namespace" >&2
  exit 1
fi
if [ "$AGENT" != "openclaw" ] && [ "$AGENT" != "hermes" ]; then
  echo "ERROR: AGENT must be 'openclaw' or 'hermes', got '$AGENT'" >&2
  exit 1
fi
if [ "$AGENT" = "hermes" ] && [ -z "$HERMES_API_KEY" ]; then
  echo "ERROR: AGENT=hermes requires HERMES_API_KEY to be set" >&2
  exit 1
fi

# ── 1. Fetch the real litellm master key from the cluster secret ────────────
kubectl -n "$LITELLM_NAMESPACE" get secret litellm-helm-masterkey \
  -o jsonpath='{.data.masterkey}' | base64 -d > /tmp/mk.raw
read -r MASTERKEY < /tmp/mk.raw || true
echo "litellm master key length: ${#MASTERKEY}"

# ── 2. Bake the master key + deploy-time values into a local copy of values.yaml ──
WORK="$ROOT/work"
rm -rf "$WORK" && mkdir -p "$WORK"
cp -r "$CHART" "$WORK/nemoclaw"
python3 - "$WORK/nemoclaw/values.yaml" "$MASTERKEY" <<'PY'
import sys, os
path, key = sys.argv[1], sys.argv[2]
DOMAIN = os.environ.get("DOMAIN", "")
LITELLM_NAMESPACE = os.environ.get("LITELLM_NAMESPACE", "")
STORAGECLASS = os.environ.get("STORAGECLASS", "")
AGENT = os.environ.get("AGENT", "openclaw")
HERMES_API_KEY = os.environ.get("HERMES_API_KEY", "")
TELEGRAM_BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
TELEGRAM_TEST_CHAT_ID = os.environ.get("TELEGRAM_TEST_CHAT_ID", "")
s = open(path).read()
# Replace the apiKey placeholder with the real master key.
s = s.replace('apiKey: "CHANGE_ME-litellm-master-key"', 'apiKey: "' + key + '"')
# Fill PCAI-generic placeholders with the real values for this environment.
s = s.replace('"nemoclaw.<your-pcai-domain>"', f'"nemoclaw.{DOMAIN}"')
s = s.replace('"<your-pcai-domain>"', f'"{DOMAIN}"')
s = s.replace('"<litellm-namespace>"', f'"{LITELLM_NAMESPACE}"')
s = s.replace('"http://litellm-helm.<litellm-namespace>.svc.cluster.local:4000/v1"',
              f'"http://litellm-helm.{LITELLM_NAMESPACE}.svc.cluster.local:4000/v1"')
s = s.replace('"<pcai-storageclass>"', f'"{STORAGECLASS}"')
# Set the agent selector.
s = s.replace('agent: openclaw\n', f'agent: {AGENT}\n')
# If agent=hermes, replace the hermes.apiServerKey placeholder.
if AGENT == "hermes" and HERMES_API_KEY:
    s = s.replace('apiServerKey: "CHANGE_ME-HERMES-API-KEY"',
                  'apiServerKey: "' + HERMES_API_KEY + '"')
# Telegram token (if provided).
if TELEGRAM_BOT_TOKEN:
    s = s.replace('botToken: "CHANGE_ME-telegram-bot-token"',
                  'botToken: "' + TELEGRAM_BOT_TOKEN + '"')
    s = s.replace('testChatId: ""',
                  'testChatId: "' + TELEGRAM_TEST_CHAT_ID + '"')
open(path, "w").write(s)
PY
grep -c "apiKey" "$WORK/nemoclaw/values.yaml" >/dev/null

# ── 3. Package the chart ────────────────────────────────────────────────────
rm -rf "$BUILD" && mkdir -p "$BUILD"
helm package "$WORK/nemoclaw" -d "$BUILD" >/dev/null
TGZ=$(ls -1 "$BUILD"/nemoclaw-*.tgz | head -1)
echo "packaged: $TGZ"

# ── 4. Upload to chartmuseum ────────────────────────────────────────────────
kubectl -n "$CHARTMUSEUM_NAMESPACE" port-forward svc/chartmuseum 8080:8080 >/tmp/chartmuseum-pf.log 2>&1 &
PF_PID=$!
sleep 3
STATUS=$(curl -sS --data-binary "@${TGZ}" "http://127.0.0.1:8080/api/charts" -m 30 -w '%{http_code}' -o /dev/null)
kill "$PF_PID" >/dev/null 2>&1 || true
echo "chartmuseum upload HTTP status: $STATUS"
case "$STATUS" in
  201|409) echo "chart accepted";;
  *) echo "UPLOAD FAILED" >&2; cat /tmp/chartmuseum-pf.log >&2; exit 1;;
esac

# ── 5. Build + apply the EzAppConfig ────────────────────────────────────────
VALUES=$(cat "$WORK/nemoclaw/values.yaml")
python3 - "$VALUES" "$RELEASE" "$CHART_VERSION" "$NS" > /tmp/nemoclaw-ezapp.yaml <<'PY'
import sys, time
values, release, cv, ns = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
ts = str(int(time.time()))
ind = "\n".join(("    " + l if l else l) for l in values.splitlines())
print(f"""apiVersion: ezconfig.hpe.ezaf.com/v1alpha1
kind: EzAppConfig
metadata:
  name: {release}-{cv}-{ts}
  labels:
    hpe-ezua/imported-app: "true"
spec:
  autoHelm: false
  install: true
  name: {release}
  label: NemoClaw
  description: "NemoClaw / Hermes Agent — single-agent PCAI deployment with Telegram channel."
  category: dataScience
  chartVersion: {cv}
  backoffLimit: 3
  options:
    namespace: {ns}
    create-namespace: "false"
    wait: "true"
    timeout: 45m
  values: |-
{ind}""")
PY
kubectl apply -f /tmp/nemoclaw-ezapp.yaml
echo "EzAppConfig created: $RELEASE-$CHART_VERSION-<ts>"
echo "WATCH: kubectl -n $NS get ezappconfig"
