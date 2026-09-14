#!/usr/bin/env bash
# NemoClaw PCAI BYOA deploy — packages the chart, uploads to chartmuseum,
# creates an EzAppConfig. Supports deploying MULTIPLE independent apps
# (openclaw and/or hermes) by parameterizing release name, namespace, VS
# prefix, and telegram channel. The litellm master key is fetched live from
# the cluster secret so it is never committed.
#
# Usage:
#   KUBECONFIG=<path> DOMAIN=aie.example.lab LITELLM_NAMESPACE=project-user-aieadmin \
#   AGENT=hermes APP_NAME=hermes NS=nemoclaw-hermes APP_PREFIX=hermes \
#   CREATE_NS=true TELEGRAM_ENABLED=true \
#   TELEGRAM_BOT_TOKEN=<token> ./deploy.sh
#
# Env (all overridable):
#   AGENT              openclaw | hermes                        (required)
#   APP_NAME           EzAppConfig app name + helm release     (default: AGENT;
#                                                             openclaw->nemoclaw)
#   NS                 namespace to install into               (default: nemoclaw
#                                                             for openclaw,
#                                                             nemoclaw-hermes for hermes)
#   APP_PREFIX         VS host prefix (host=<prefix>.<DOMAIN>) (default: APP_NAME)
#   CREATE_NS          create the namespace if absent          (default: false)
#   TELEGRAM_ENABLED   true|false                              (default: true for
#                                                             hermes, false for
#                                                             openclaw — a single
#                                                             bot token can only
#                                                             be long-polled by one
#                                                             gateway)
#   DOMAIN             PCAI base domain (e.g. aie.example.lab) (required)
#   LITELLM_NAMESPACE  namespace of litellm-helm svc           (required)
#   STORAGECLASS       default nfs-csi
#   CHART_VERSION      default 0.2.0
#   TELEGRAM_BOT_TOKEN bot token (required when TELEGRAM_ENABLED=true)
#   HERMES_API_KEY     optional; a random 64-hex key is generated if empty
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:?set KUBECONFIG to your PCAI kubeconfig}"
LITELLM_NAMESPACE="${LITELLM_NAMESPACE:?set LITELLM_NAMESPACE}"
CHARTMUSEUM_NAMESPACE="${CHARTMUSEUM_NAMESPACE:-ez-chartmuseum-ns}"
DOMAIN="${DOMAIN:?set DOMAIN to your PCAI base domain}"
STORAGECLASS="${STORAGECLASS:-nfs-csi}"
CHART_VERSION="${CHART_VERSION:-0.2.0}"
AGENT="${AGENT:?set AGENT to openclaw or hermes}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
# Token can also come from a file (preferred: avoids the token crossing the
# command line, where the tool-layer secret redactor would mangle it to ***).
if [ -n "${TELEGRAM_TOKEN_FILE:-}" ] && [ -f "${TELEGRAM_TOKEN_FILE}" ]; then
  TELEGRAM_BOT_TOKEN="$(head -n 1 "${TELEGRAM_TOKEN_FILE}" | tr -d '\r\n')"
fi
TELEGRAM_TEST_CHAT_ID="${TELEGRAM_TEST_CHAT_ID:-}"
HERMES_API_KEY="${HERMES_API_KEY:-}"
HERMES_DASH_PASS="${HERMES_DASHBOARD_PASSWORD:-EZP@ssw0rd}"
TELEGRAM_ENABLED="${TELEGRAM_ENABLED:-}"
CREATE_NS="${CREATE_NS:-false}"

# Export for the python bake (it reads os.environ).
export DOMAIN LITELLM_NAMESPACE STORAGECLASS CHART_VERSION AGENT APP_PREFIX \
       TELEGRAM_ENABLED TELEGRAM_BOT_TOKEN TELEGRAM_TEST_CHAT_ID HERMES_API_KEY \
       HERMES_DASH_PASS

ROOT="$(cd "$(dirname "$0")" && pwd)"
CHART="$ROOT/nemoclaw/0.2.0"
BUILD="$ROOT/build"

# Defaults per agent.
case "$AGENT" in
  openclaw)
    APP_NAME="${APP_NAME:-nemoclaw}"
    NS="${NS:-nemoclaw}"
    [ -z "$TELEGRAM_ENABLED" ] && TELEGRAM_ENABLED=false
    ;;
  hermes)
    APP_NAME="${APP_NAME:-hermes}"
    NS="${NS:-nemoclaw-hermes}"
    [ -z "$TELEGRAM_ENABLED" ] && TELEGRAM_ENABLED=true
    ;;
  *) echo "ERROR: AGENT must be 'openclaw' or 'hermes', got '$AGENT'" >&2; exit 1;;
esac
APP_PREFIX="${APP_PREFIX:-$APP_NAME}"
# The PCAI platform resolves the EzAppConfig `spec.name` to a CHART NAME in
# chartmuseum, so each app must be packaged under its own chart name. The
# chart's resource names don't follow the chart name (fullname is pinned to
# "nemoclaw"), so two apps in different namespaces don't collide.
CHART_NAME="${CHART_NAME:-$APP_NAME}"
[ -z "$TELEGRAM_ENABLED" ] && TELEGRAM_ENABLED=false
[ "$TELEGRAM_ENABLED" = "true" ] && [ -z "$TELEGRAM_BOT_TOKEN" ] && {
  echo "ERROR: TELEGRAM_ENABLED=true requires TELEGRAM_BOT_TOKEN" >&2; exit 1; }

echo "=== BYOA deploy: agent=$AGENT app=$APP_NAME chart=$CHART_NAME ns=$NS prefix=$APP_PREFIX telegram=$TELEGRAM_ENABLED ==="

# ── 1. Fetch the real litellm master key from the cluster secret ────────────
MASTERKEY=$(kubectl -n "$LITELLM_NAMESPACE" get secret litellm-helm-masterkey \
  -o jsonpath='{.data.masterkey}' | base64 -d)
[ -n "$MASTERKEY" ] || { echo "ERROR: empty litellm master key" >&2; exit 1; }
export MASTERKEY
echo "litellm master key length: ${#MASTERKEY}"

# Generated secrets (never committed; baked into values -> Secret at install).
[ -z "$HERMES_API_KEY" ] && HERMES_API_KEY=$(python3 -c "import os;print(os.urandom(32).hex())" | tr -d '\n')
export HERMES_API_KEY
OPENCLAW_TOKEN=$(python3 -c "import os;print('nemoclaw-' + os.urandom(12).hex())" | tr -d '\n')
export OPENCLAW_TOKEN

# ── 2. Bake deploy-time values into a local copy of values.yaml ────────────
WORK="$ROOT/work"
rm -rf "$WORK" && mkdir -p "$WORK"
cp -r "$CHART" "$WORK/nemoclaw"
# Rename the chart to CHART_NAME (the platform looks charts up by this name).
python3 - "$WORK/nemoclaw/Chart.yaml" "$CHART_NAME" <<'PY'
import sys
path, name = sys.argv[1], sys.argv[2]
s = open(path).read()
s = s.replace("name: nemoclaw\n", "name: " + name + "\n", 1)
open(path, "w").write(s)
PY
python3 - "$WORK/nemoclaw/values.yaml" <<'PY'
import os, sys, re
path = sys.argv[1]
s = open(path).read()
env = os.environ
DOMAIN = env["DOMAIN"]; LNS = env["LITELLM_NAMESPACE"]; SC = env["STORAGECLASS"]
AGENT = env["AGENT"]; PREFIX = env["APP_PREFIX"]
TG_ON = env["TELEGRAM_ENABLED"] == "true"; TG_TOKEN = env.get("TELEGRAM_BOT_TOKEN","")
TG_CHAT = env.get("TELEGRAM_TEST_CHAT_ID","")
# Fetch the litellm master key INSIDE this process so it never crosses the
# command line / env, where the tool-layer secret redactor mangles it
# (previously produced a truncated masked value in the deployed values).
import base64, subprocess
_mk = subprocess.run(["kubectl", "-n", LNS, "get", "secret", "litellm-helm-masterkey",
                      "-o", "jsonpath={.data.masterkey}"],
                     capture_output=True, text=True, check=True).stdout.strip()
LM_KEY = base64.b64decode(_mk).decode()
HKEY = env["HERMES_API_KEY"]; OCTOK = env["OPENCLAW_TOKEN"]

s = re.sub(r'(?m)^( *)apiKey: .*$', r'\1apiKey: "' + LM_KEY + '"', s, count=1)
s = s.replace('base: "<your-pcai-domain>"', 'base: "' + DOMAIN + '"')
# The PCAI UI surfaces ezua.virtualService.endpoint as the "endpoint" — it must
# be baked to the real host (appPrefix.base), otherwise the UI shows a literal
# "<your-pcai-domain>" placeholder.
s = s.replace('endpoint: "nemoclaw.<your-pcai-domain>"',
              'endpoint: "' + PREFIX + '.' + DOMAIN + '"')
s = s.replace('appPrefix: "nemoclaw"', 'appPrefix: "' + PREFIX + '"')
s = s.replace('baseUrl: "http://litellm-helm.<litellm-namespace>.svc.cluster.local:4000/v1"',
              'baseUrl: "http://litellm-helm.' + LNS + '.svc.cluster.local:4000/v1"')
s = s.replace('namespace: "<litellm-namespace>"', 'namespace: "' + LNS + '"')
s = s.replace('storageClassName: "<pcai-storageclass>"', 'storageClassName: "' + SC + '"')
s = s.replace('agent: openclaw\n', 'agent: ' + AGENT + '\n')
# Distinct resource names per agent runtime (deployment/svc/secret/pvc/vs are
# named <fullnameOverride>-*) so the openclaw and hermes deployments are clearly
# distinguishable even though both ship from the "nemoclaw" chart.
s = re.sub(r'(?m)^replicaCount: 1$',
           'replicaCount: 1\nfullnameOverride: "nemoclaw-' + AGENT + '"', s, count=1)
s = s.replace('token: "CHANGE_ME-GENERATED-AT-DEPLOY"', 'token: "' + OCTOK + '"')
# Pin the Hermes dashboard admin password (default EZP@ssw0rd; override with
# HERMES_DASHBOARD_PASSWORD). Empty value => helm generates a random one at install.
DASH_PASS = env.get("HERMES_DASH_PASS", "")
if AGENT == "hermes" and DASH_PASS:
    s = re.sub(r'(?m)^( *)password: "".*$', r'\1password: "' + DASH_PASS + '"', s, count=1)
s = s.replace('apiServerKey: "CHANGE_ME-HERMES-API-KEY"', 'apiServerKey: "' + HKEY + '"')
# telegram block
if TG_ON:
    s = s.replace('botToken: "CHANGE_ME-telegram-bot-token"', 'botToken: "' + TG_TOKEN + '"')
    if TG_CHAT:
        s = s.replace('testChatId: ""', 'testChatId: "' + TG_CHAT + '"')
else:
    s = re.sub(r'(?m)^telegram:\n  enabled: true', 'telegram:\n  enabled: false', s)
open(path, "w").write(s)
PY
echo "baked values -> $WORK/nemoclaw/values.yaml"

# ── 3. Package the chart ────────────────────────────────────────────────────
rm -rf "$BUILD" && mkdir -p "$BUILD"
helm package "$WORK/nemoclaw" -d "$BUILD" >/dev/null
TGZ=$(ls -1 "$BUILD"/*.tgz | head -1)
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
python3 - "$VALUES" "$APP_NAME" "$CHART_NAME" "$CHART_VERSION" "$NS" "$CREATE_NS" "$AGENT" > /tmp/nemoclaw-ezapp-$APP_NAME.yaml <<'PY'
import sys, time
values, app, chart_name, cv, ns, create_ns, agent = sys.argv[1:8]
ts = str(int(time.time()))
ind = "\n".join(("    " + l if l else l) for l in values.splitlines())
desc = ("NemoClaw (OpenClaw) agent gateway with Telegram channel." if agent == "openclaw"
        else "Hermes Agent (Nous Research) gateway with Telegram channel.")
# Distinct framework name per agent so the two apps are distinguishable in the UI.
label = ("NemoClaw (OpenClaw)" if agent == "openclaw" else "Hermes Agent")
print(f"""apiVersion: ezconfig.hpe.ezaf.com/v1alpha1
kind: EzAppConfig
metadata:
  name: {chart_name}-{cv}-{ts}
  labels:
    hpe-ezua/imported-app: "true"
spec:
  autoHelm: false
  install: true
  name: {chart_name}
  label: "{label}"
  description: "{desc}"
  category: dataScience
  chartVersion: {cv}
  backoffLimit: 3
  options:
    namespace: {ns}
    create-namespace: "{create_ns}"
    wait: "true"
    timeout: 45m
  values: |-
{ind}""")
PY
# Ensure the target namespace exists and has the istio sidecar-injection label
# (the ingress VS needs the pod sidecar to route). Idempotent.
if [ "$CREATE_NS" = "true" ]; then
  kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"
fi
kubectl label ns "$NS" istio-injection=enabled --overwrite
kubectl apply -f /tmp/nemoclaw-ezapp-$APP_NAME.yaml
echo "EzAppConfig created: $CHART_NAME-$CHART_VERSION-<ts>"
echo "WATCH: kubectl get ezappconfig $CHART_NAME-$CHART_VERSION-<ts>"
