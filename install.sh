#!/usr/bin/env bash
# Configure and deploy Fusion to Kubernetes. See README.md.
#
# Answers come from, in order: environment variables, the previous run's saved
# state in .local/<namespace>/, then prompts (or defaults with --yes).
# Secrets are read from the environment or hidden prompts, never from flags,
# because flags are visible in `ps`.
set -euo pipefail
umask 077

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
YES=false
DRY_RUN=false

usage() {
  cat <<'EOF'
Usage: ./install.sh [-y|--yes] [--dry-run] [-n|--namespace NAME]

  -y, --yes         Don't prompt; use environment variables, saved state, defaults
      --dry-run     Render to .local/<namespace>/rendered.yaml; don't touch the cluster
  -n, --namespace   Target namespace (default: fusion)

Environment variables:
  General    FUSION_PASSWORD FUSION_VERSION STORAGE_SIZE STORAGE_CLASS
  Exposure   SERVICE_TYPE PUBLIC_URL FUSION_TRUSTED_PROXIES FUSION_CORS_ALLOWED_ORIGINS
  OIDC      ENABLE_OIDC FUSION_OIDC_ISSUER FUSION_OIDC_CLIENT_ID
             FUSION_OIDC_CLIENT_SECRET FUSION_OIDC_REDIRECT_URI
             FUSION_OIDC_ALLOWED_USER OIDC_ALLOW_ANY_USER OIDC_ALLOW_HTTP_ISSUER
  Tuning     FUSION_FEVER_USERNAME FUSION_ALLOW_PRIVATE_FEEDS FUSION_PULL_INTERVAL
             FUSION_PULL_TIMEOUT FUSION_PULL_CONCURRENCY FUSION_PULL_MAX_BACKOFF
             FUSION_LOGIN_RATE_LIMIT FUSION_LOGIN_WINDOW FUSION_LOGIN_BLOCK
             FUSION_LOG_LEVEL FUSION_LOG_FORMAT

At a prompt, Enter accepts the [default] and "-" clears the value.
EOF
}

info() { printf '%s\n' "$*" >&2; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case $1 in
    -y | --yes) YES=true ;;
    --dry-run) DRY_RUN=true ;;
    -n | --namespace)
      (($# >= 2)) || die "$1 needs a value"
      NAMESPACE=$2
      shift
      ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done

# --- State files: KEY=VALUE per line, parsed by hand and never sourced ----------

kv_get() { # file key
  [[ -f $1 ]] || return 0
  { grep -m1 "^$2=" "$1" || true; } | cut -d= -f2-
}

kv_set() { # file key value; an empty value removes the key
  local file=$1 key=$2 value=${3-} tmp
  # Kustomize env files mangle these (a trailing \r vanishes), so refuse rather
  # than deploy a credential that differs from the one supplied.
  [[ $value != *[[:cntrl:]]* ]] || die "$key must not contain control characters"
  tmp=$(mktemp "$file.XXXXXX")
  if [[ -f $file ]]; then grep -v "^$key=" "$file" >"$tmp" || true; fi
  if [[ -n $value ]]; then printf '%s=%s\n' "$key" "$value" >>"$tmp"; fi
  mv "$tmp" "$file"
}

# --- Prompts: a variable already set in the environment is never asked for ------

read_reply() { # prompt-for-error
  IFS= read -r REPLY || die "input ended at \"$1\" (use --yes with environment variables)"
}

ask() { # VAR prompt [default]
  local var=$1 prompt=$2 def=${3-}
  if [[ -n ${!var+x} ]]; then return 0; fi
  if $YES; then
    printf -v "$var" '%s' "$def"
    return 0
  fi
  printf '%s%s: ' "$prompt" "${def:+ [$def]}" >&2
  read_reply "$prompt"
  case $REPLY in
    '') REPLY=$def ;;
    -) REPLY='' ;;
  esac
  printf -v "$var" '%s' "$REPLY"
}

ask_secret() { # VAR prompt existing-value
  local var=$1 prompt=$2 existing=${3-}
  if [[ -n ${!var+x} ]]; then return 0; fi
  if $YES; then
    printf -v "$var" '%s' "$existing"
    return 0
  fi
  printf '%s%s: ' "$prompt" "${existing:+ [keep existing]}" >&2
  IFS= read -rs REPLY || die "input ended at \"$prompt\" (use --yes with environment variables)"
  printf '\n' >&2
  printf -v "$var" '%s' "${REPLY:-$existing}"
}

ask_bool() { # VAR prompt default(true|false)
  local var=$1 prompt=$2 def=$3 hint=y/N
  [[ $def == true ]] && hint=Y/n
  if [[ -z ${!var+x} ]]; then
    if $YES; then
      printf -v "$var" '%s' "$def"
    else
      printf '%s [%s]: ' "$prompt" "$hint" >&2
      read_reply "$prompt"
      printf -v "$var" '%s' "${REPLY:-$def}"
    fi
  fi
  case ${!var,,} in
    true | yes | y | 1) printf -v "$var" true ;;
    false | no | n | 0) printf -v "$var" false ;;
    *) die "$var must be true or false, got: ${!var}" ;;
  esac
}

require_match() { # name value regex description
  [[ $2 =~ $3 ]] || die "invalid $1 \"$2\": expected $4"
}

# --- OIDC checks ----------------------------------------------------------------

# Fusion runs discovery at startup and exits if the provider's issuer differs
# from the configured one by even a trailing slash, which would crash-loop the
# pod. Being unreachable from here proves nothing, since the provider may only be
# reachable in-cluster, so that is only a warning.
check_oidc_issuer() {
  local issuer=$1 doc found
  if ! doc=$(curl -fsS --max-time 10 "${issuer%/}/.well-known/openid-configuration" 2>/dev/null); then
    warn "could not fetch OIDC discovery for $issuer from this machine. Fusion will crash-loop if its pod can't reach it either."
    return 0
  fi
  found=$(printf '%s' "$doc" | tr -d '\n' |
    sed -nE 's/.*"issuer"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | sed 's#\\/#/#g')
  [[ -n $found ]] || die "$issuer did not return an OIDC discovery document"
  [[ $found == "$issuer" ]] ||
    die "issuer must match the provider exactly: provider says \"$found\", you entered \"$issuer\""
  info "OIDC discovery OK: $issuer"
}

configure_oidc() {
  ask FUSION_OIDC_ISSUER "OIDC issuer URL" "$(kv_get "$CONFIG" FUSION_OIDC_ISSUER)"
  # Saved answers only count for the issuer they were given for. A client secret
  # or allowed user must not follow you to a different provider.
  local saved_id='' saved_secret='' saved_user='' any_default=false
  if [[ $FUSION_OIDC_ISSUER == "$(kv_get "$CONFIG" FUSION_OIDC_ISSUER)" ]]; then
    saved_id=$(kv_get "$CONFIG" FUSION_OIDC_CLIENT_ID)
    saved_secret=$(kv_get "$SECRET" FUSION_OIDC_CLIENT_SECRET)
    saved_user=$(kv_get "$CONFIG" FUSION_OIDC_ALLOWED_USER)
    any_default=$(kv_get "$INSTALL" OIDC_ALLOW_ANY_USER | grep -x true || echo false)
  fi
  ask FUSION_OIDC_CLIENT_ID "OIDC client ID" "$saved_id"
  ask_secret FUSION_OIDC_CLIENT_SECRET "OIDC client secret (blank for a public PKCE client)" "$saved_secret"

  local default_redirect
  if [[ -n $PUBLIC_URL ]]; then
    default_redirect="$PUBLIC_URL/api/oidc/callback"
  else
    default_redirect=$(kv_get "$CONFIG" FUSION_OIDC_REDIRECT_URI)
  fi
  ask FUSION_OIDC_REDIRECT_URI "OIDC redirect URI" "$default_redirect"

  [[ -n $FUSION_OIDC_ISSUER ]] || die "OIDC needs an issuer URL (FUSION_OIDC_ISSUER)"
  [[ -n $FUSION_OIDC_CLIENT_ID ]] || die "OIDC needs a client ID (FUSION_OIDC_CLIENT_ID)"
  [[ -n $FUSION_OIDC_REDIRECT_URI ]] ||
    die "OIDC needs a redirect URI (FUSION_OIDC_REDIRECT_URI, or set PUBLIC_URL)"
  require_match FUSION_OIDC_ISSUER "$FUSION_OIDC_ISSUER" '^https?://[^[:space:]]+$' "an http(s) URL"
  require_match FUSION_OIDC_REDIRECT_URI "$FUSION_OIDC_REDIRECT_URI" \
    '^https?://[^/[:space:]]+(/api)?/oidc/callback$' "https://<host>/api/oidc/callback"
  # Signing keys come from the issuer too, so plain HTTP risks more than eavesdropping.
  [[ $FUSION_OIDC_ISSUER == https://* || ${OIDC_ALLOW_HTTP_ISSUER:-} == true ]] ||
    die "the OIDC issuer must be HTTPS, because logins can't be trusted otherwise. OIDC_ALLOW_HTTP_ISSUER=true overrides this."
  case $FUSION_OIDC_REDIRECT_URI in
    https://* | http://localhost[:/]* | http://127.0.0.1[:/]*) ;;
    *) warn "the redirect URI is not HTTPS, so the login code and session cookie travel unencrypted." ;;
  esac
  check_oidc_issuer "$FUSION_OIDC_ISSUER"

  # Without an allowed user, anyone who can log in at the issuer gets full access.
  ask FUSION_OIDC_ALLOWED_USER "Only allow this user (their OIDC sub is safest; an email also works)" "$saved_user"
  if [[ -z $FUSION_OIDC_ALLOWED_USER ]]; then
    ask_bool OIDC_ALLOW_ANY_USER "Allow EVERY account at this issuer into Fusion?" "$any_default"
    $OIDC_ALLOW_ANY_USER ||
      die "set FUSION_OIDC_ALLOWED_USER, or OIDC_ALLOW_ANY_USER=true if every account at the issuer should have access"
    warn "every account at $FUSION_OIDC_ISSUER will be able to log in."
  else
    OIDC_ALLOW_ANY_USER=false
    # Fusion matches the email claim without checking email_verified.
    [[ $FUSION_OIDC_ALLOWED_USER != *@* ]] ||
      warn "Fusion doesn't check email_verified. Use the OIDC sub instead if accounts at this issuer can set an unverified email."
  fi
}

# --- Collect configuration ------------------------------------------------------

ask NAMESPACE "Namespace" fusion
require_match namespace "$NAMESPACE" '^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$' "a DNS label"

STATE="$ROOT/.local/$NAMESPACE"
mkdir -p "$STATE"
chmod 700 "$ROOT/.local" "$STATE"
INSTALL="$STATE/install.env"
CONFIG="$STATE/config.env"
SECRET="$STATE/secret.env"
touch "$INSTALL" "$CONFIG" "$SECRET"

# Password login and the Fever API stay on with or without OIDC, so they always
# get a real password.
case "${FUSION_ALLOW_EMPTY_PASSWORD:-$(kv_get "$CONFIG" FUSION_ALLOW_EMPTY_PASSWORD)}" in
  '' | 0 | f | F | false | FALSE | False) ;;
  *) die "FUSION_ALLOW_EMPTY_PASSWORD is not supported by this installer" ;;
esac

ask_secret FUSION_PASSWORD "Fusion password, used for login and Fever even with OIDC (blank = generate)" \
  "$(kv_get "$SECRET" FUSION_PASSWORD)"
PASSWORD_GENERATED=false
if [[ -z ${FUSION_PASSWORD//[[:space:]]/} ]]; then
  FUSION_PASSWORD=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
  PASSWORD_GENERATED=true
elif ((${#FUSION_PASSWORD} < 12)); then
  die "FUSION_PASSWORD must be at least 12 characters. Leave it blank to generate one."
fi

ask SERVICE_TYPE "Service type (ClusterIP, NodePort, LoadBalancer)" \
  "$(kv_get "$INSTALL" SERVICE_TYPE | grep . || echo ClusterIP)"
ask PUBLIC_URL "URL people will open Fusion at, if not only port-forward (blank for port-forward only)" \
  "$(kv_get "$INSTALL" PUBLIC_URL)"
PUBLIC_URL=${PUBLIC_URL%/}
if [[ -n $PUBLIC_URL ]]; then
  require_match PUBLIC_URL "$PUBLIC_URL" '^https?://[^/[:space:]]+$' "a scheme and host, no path"
  ask FUSION_TRUSTED_PROXIES "Trusted proxy IPs/CIDRs, comma separated (your proxy pods)" \
    "$(kv_get "$CONFIG" FUSION_TRUSTED_PROXIES)"
  [[ -n $FUSION_TRUSTED_PROXIES ]] ||
    warn "no trusted proxies set. If a proxy fronts Fusion, all clients share one login rate limit, so bad logins from anyone lock out everyone."
else
  FUSION_TRUSTED_PROXIES=''
fi
require_match SERVICE_TYPE "$SERVICE_TYPE" '^(ClusterIP|NodePort|LoadBalancer)$' "ClusterIP, NodePort or LoadBalancer"
# Too broad a range lets clients spoof X-Forwarded-For to dodge the login rate limit.
IFS=, read -ra proxies <<<"${FUSION_TRUSTED_PROXIES// /}"
for proxy in "${proxies[@]}"; do
  [[ $proxy == */* ]] || continue
  prefix=${proxy#*/}
  min_prefix=8
  [[ $proxy != *:* ]] || min_prefix=32
  if ! [[ $prefix =~ ^[0-9]+$ ]] || ((10#$prefix < min_prefix)) || [[ ${proxy,,} == *ffff:* ]]; then
    die "FUSION_TRUSTED_PROXIES entry \"$proxy\" is too broad"
  fi
done
[[ $SERVICE_TYPE == ClusterIP ]] ||
  warn "a $SERVICE_TYPE Service serves plain HTTP on its own port, so the password and session cookie can travel unencrypted."
case $PUBLIC_URL in
  '' | https://* | http://localhost | http://localhost:* | http://127.0.0.1 | http://127.0.0.1:*) ;;
  *) warn "PUBLIC_URL isn't HTTPS, so the password and session cookie travel unencrypted." ;;
esac

# An empty list means Fusion allows every origin with credentials, and a list
# without the real URL makes logins fail with 403, so derive it from the URL.
# A list you set yourself is saved and wins until you set it to empty.
CORS_OVERRIDE=${FUSION_CORS_ALLOWED_ORIGINS-$(kv_get "$INSTALL" CORS_OVERRIDE)}
FUSION_CORS_ALLOWED_ORIGINS=$CORS_OVERRIDE
if [[ -z $FUSION_CORS_ALLOWED_ORIGINS ]]; then
  FUSION_CORS_ALLOWED_ORIGINS="http://localhost:8080,http://127.0.0.1:8080"
  if [[ -n $PUBLIC_URL ]]; then
    FUSION_CORS_ALLOWED_ORIGINS="$PUBLIC_URL,$FUSION_CORS_ALLOWED_ORIGINS"
  elif [[ $SERVICE_TYPE != ClusterIP ]]; then
    die "a $SERVICE_TYPE Service needs PUBLIC_URL, or FUSION_CORS_ALLOWED_ORIGINS, so logins work from its address"
  fi
fi
IFS=, read -ra origins <<<"$FUSION_CORS_ALLOWED_ORIGINS"
for origin in "${origins[@]}"; do
  require_match FUSION_CORS_ALLOWED_ORIGINS "$origin" '^https?://[^/,[:space:]*]+$' \
    "comma separated origins like https://host, with no spaces or wildcards"
done

oidc_default=false
[[ -z ${FUSION_OIDC_ISSUER:-$(kv_get "$CONFIG" FUSION_OIDC_ISSUER)} ]] || oidc_default=true
ask_bool ENABLE_OIDC "Enable OIDC single sign-on?" "$oidc_default"
if $ENABLE_OIDC; then
  configure_oidc
else
  FUSION_OIDC_ISSUER='' FUSION_OIDC_CLIENT_ID='' FUSION_OIDC_CLIENT_SECRET=''
  FUSION_OIDC_REDIRECT_URI='' FUSION_OIDC_ALLOWED_USER='' OIDC_ALLOW_ANY_USER=false
fi

ask STORAGE_SIZE "Storage size" "$(kv_get "$INSTALL" STORAGE_SIZE | grep . || echo 1Gi)"
require_match STORAGE_SIZE "$STORAGE_SIZE" '^[0-9]+(Mi|Gi|Ti)$' "a size like 1Gi"
ask STORAGE_CLASS "Storage class (blank for the cluster default)" "$(kv_get "$INSTALL" STORAGE_CLASS)"
[[ -z $STORAGE_CLASS ]] ||
  require_match STORAGE_CLASS "$STORAGE_CLASS" '^[a-z0-9]([-.a-z0-9]*[a-z0-9])?$' "a storage class name"
FUSION_VERSION=${FUSION_VERSION:-$(kv_get "$INSTALL" FUSION_VERSION)}
[[ -z $FUSION_VERSION ]] ||
  require_match FUSION_VERSION "$FUSION_VERSION" '^[A-Za-z0-9_][A-Za-z0-9_.-]*$' "an image tag like 1.3.0"

# --- Save state -----------------------------------------------------------------

for key in ENABLE_OIDC OIDC_ALLOW_ANY_USER SERVICE_TYPE PUBLIC_URL CORS_OVERRIDE \
  STORAGE_SIZE STORAGE_CLASS FUSION_VERSION; do
  kv_set "$INSTALL" "$key" "${!key}"
done

for key in FUSION_CORS_ALLOWED_ORIGINS FUSION_TRUSTED_PROXIES FUSION_OIDC_ISSUER \
  FUSION_OIDC_CLIENT_ID FUSION_OIDC_REDIRECT_URI FUSION_OIDC_ALLOWED_USER; do
  kv_set "$CONFIG" "$key" "${!key}"
done
# Tuning values are only changed when set; hand edits to config.env are kept.
for key in FUSION_FEVER_USERNAME FUSION_ALLOW_PRIVATE_FEEDS FUSION_PULL_INTERVAL \
  FUSION_PULL_TIMEOUT FUSION_PULL_CONCURRENCY FUSION_PULL_MAX_BACKOFF \
  FUSION_LOGIN_RATE_LIMIT FUSION_LOGIN_WINDOW FUSION_LOGIN_BLOCK \
  FUSION_LOG_LEVEL FUSION_LOG_FORMAT; do
  if [[ -n ${!key+x} ]]; then kv_set "$CONFIG" "$key" "${!key}"; fi
done

kv_set "$SECRET" FUSION_PASSWORD "$FUSION_PASSWORD"
kv_set "$SECRET" FUSION_OIDC_CLIENT_SECRET "$FUSION_OIDC_CLIENT_SECRET"

# --- Render ---------------------------------------------------------------------

command -v kubectl >/dev/null || die "kubectl not found"

{
  cat <<EOF
# Generated by install.sh. Re-run it rather than editing this file.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: $NAMESPACE
resources:
  - ../../deploy/base
generatorOptions:
  labels:
    fusion.install/generated: "true"
configMapGenerator:
  - name: fusion-config
    envs: [config.env]
secretGenerator:
  - name: fusion-secrets
    envs: [secret.env]
EOF
  if [[ -n $FUSION_VERSION ]]; then
    cat <<EOF
images:
  - name: ghcr.io/0x2e/fusion
    newTag: "$FUSION_VERSION"
EOF
  fi
  cat <<EOF
patches:
  - patch: |-
      apiVersion: v1
      kind: PersistentVolumeClaim
      metadata:
        name: fusion-data
      spec:
        resources:
          requests:
            storage: $STORAGE_SIZE
${STORAGE_CLASS:+        storageClassName: $STORAGE_CLASS}
  - patch: |-
      apiVersion: v1
      kind: Service
      metadata:
        name: fusion
      spec:
        type: $SERVICE_TYPE
EOF
} >"$STATE/kustomization.yaml"

RENDERED="$STATE/rendered.yaml"
kubectl kustomize "$STATE" >"$RENDERED"

if $DRY_RUN; then
  info "Dry run: nothing was applied."
  info "Rendered manifests, including secrets: $RENDERED"
  exit 0
fi

# --- Apply ----------------------------------------------------------------------

CONTEXT=$(kubectl config current-context 2>/dev/null) ||
  die "kubectl has no current context. Use --dry-run to render without a cluster."
if ! $YES; then
  printf 'Apply to context "%s", namespace "%s"? [y/N]: ' "$CONTEXT" "$NAMESPACE" >&2
  read_reply "apply confirmation"
  [[ ${REPLY,,} == y || ${REPLY,,} == yes ]] || die "aborted; nothing was applied"
fi

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f "$RENDERED"

if ! kubectl -n "$NAMESPACE" rollout status deployment/fusion --timeout=180s; then
  kubectl -n "$NAMESPACE" logs deployment/fusion -c fusion --tail=20 >&2 || true
  die "rollout did not finish. Inspect it with: kubectl -n $NAMESPACE describe pod -l app.kubernetes.io/name=fusion"
fi

# Each config change creates a new hash-named Secret. Remove the old ones so that
# rotated credentials don't linger in the cluster. A failure here doesn't hide the
# report of a rollout that worked, but it does fail the run.
CLEANUP_FAILED=''
objects=$(kubectl -n "$NAMESPACE" get secret,configmap -l fusion.install/generated=true -o name) ||
  CLEANUP_FAILED=' (could not list them)'
while IFS= read -r object; do
  [[ -n $object ]] || continue
  grep -q "^  name: ${object#*/}\$" "$RENDERED" ||
    kubectl -n "$NAMESPACE" delete "$object" || CLEANUP_FAILED+=" $object"
done <<<"${objects:-}"

# --- Report ---------------------------------------------------------------------

info ""
info "Fusion is running in namespace $NAMESPACE."
[[ -z $PUBLIC_URL ]] || info "  URL:            $PUBLIC_URL"
info "  In the cluster: http://fusion.$NAMESPACE.svc"
info "  Port-forward:   kubectl -n $NAMESPACE port-forward svc/fusion 8080:80, then http://localhost:8080"
$PASSWORD_GENERATED && info "  Password:       generated and saved in $SECRET"
if $ENABLE_OIDC; then info "  OIDC:           register this redirect URI with your provider: $FUSION_OIDC_REDIRECT_URI"; fi
[[ -z $CLEANUP_FAILED ]] || die "Fusion is up, but these old objects, which may hold old credentials, could not be deleted:$CLEANUP_FAILED"
