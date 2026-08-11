#!/usr/bin/env bash
# ==============================================================================
# gen-pinata-config.sh — bridge .env credentials into the local dev page
# ------------------------------------------------------------------------------
# SINGLE RESPONSIBILITY
# Read PINATA_* values out of the repository .env and write ONE generated file,
# frontend/js/pinata-config.js, that the DApp loads before ipfsHelper.js.
#
# WHY THIS EXISTS
# The DApp uploads to Pinata straight from the browser. A browser cannot read
# .env — nothing bridges a server-side file into a static page — so a valid
# PINATA_JWT sitting in .env was invisible to the page and every upload failed
# with "No Pinata credential configured". This script is that bridge, and it is
# the ONLY thing in the repo that moves a secret from disk into web-served code.
#
# The output is a browser-readable file holding a live credential, so it is
# chmod 600 and git-ignored. This script reports key NAMES and character
# LENGTHS only; it never echoes a value.
#
# Usage: ./scripts/gen-pinata-config.sh [--quiet] [--env-file PATH]
# Exits 0 even when .env or the credential is absent: the UI still offers the
# localStorage path, so a missing credential is a warning, not a build failure.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="${SCRIPT_DIR%/scripts}"

ENV_FILE="${REPO_ROOT}/.env"
OUTPUT_FILE="${REPO_ROOT}/frontend/js/pinata-config.js"
QUIET=0

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
else
  C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''
fi

log_info() { [[ $QUIET -eq 1 ]] || printf '%s  i %s %s\n' "$C_CYAN"   "$C_RESET" "$1"; }
log_ok()   { [[ $QUIET -eq 1 ]] || printf '%s  + %s %s\n' "$C_GREEN"  "$C_RESET" "$1"; }
log_warn() { printf '%s  ! %s %s\n' "$C_YELLOW" "$C_RESET" "$1" >&2; }
die()      { printf '%s  x %s %s\n' "$C_RED" "$C_RESET" "$1" >&2; exit 1; }

usage() {
  cat <<'EOF'
gen-pinata-config.sh — generate frontend/js/pinata-config.js from .env

OPTIONS
    --env-file PATH   Read from PATH instead of ./.env
    --quiet           Suppress the informational lines (warnings still print)
    -h, --help        Show this help

The generated file is git-ignored and written with 600 permissions.
It contains a real credential: never commit it, never serve it publicly.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) ENV_FILE="$2"; shift 2 ;;
    --quiet)    QUIET=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

# ------------------------------------------------------------------------------
# .env parsing
# ------------------------------------------------------------------------------
# Deliberately NOT `set -a; source .env`: that executes the file, and a file that
# is allowed to hold secrets and arbitrary characters must never be executed.
# Each line is parsed and assigned by hand instead.
#
# Handled: CRLF line endings, a leading `export `, surrounding whitespace, and
# one layer of matching single or double quotes.
# NOT handled: inline `# comments` after a value. A JWT is base64url and cannot
# contain '#', and stripping it would silently truncate any value that legally
# contains one. Put comments on their own line.
# ------------------------------------------------------------------------------
PINATA_JWT_VALUE=""
PINATA_API_KEY_VALUE=""
PINATA_API_SECRET_VALUE=""
PINATA_GATEWAY_VALUE=""

read_env_file() {
  local file="$1"
  local line key value

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"                       # CRLF-safe
    line="${line#"${line%%[![:space:]]*}"}"    # ltrim
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue
    [[ "$line" == export\ * ]] && line="${line#export }"
    [[ "$line" != *=* ]] && continue

    key="${line%%=*}"
    value="${line#*=}"
    key="${key//[[:space:]]/}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

    value="${value#"${value%%[![:space:]]*}"}" # ltrim value
    value="${value%"${value##*[![:space:]]}"}" # rtrim value

    # Strip exactly one layer of matching quotes.
    if [[ ${#value} -ge 2 && "$value" == \"*\" ]]; then
      value="${value:1:${#value}-2}"
    elif [[ ${#value} -ge 2 && "$value" == \'*\' ]]; then
      value="${value:1:${#value}-2}"
    fi

    case "$key" in
      PINATA_JWT)        PINATA_JWT_VALUE="$value" ;;
      PINATA_API_KEY)    PINATA_API_KEY_VALUE="$value" ;;
      PINATA_API_SECRET) PINATA_API_SECRET_VALUE="$value" ;;
      PINATA_GATEWAY)    PINATA_GATEWAY_VALUE="$value" ;;
      *) : ;;   # every other key is none of this script's business
    esac
  done <"$file"
}

# Placeholders from .env.example must not be treated as real credentials: a
# generated file that says "credential present" when it holds `your_jwt_here`
# produces a 401 that looks like a Pinata outage instead of a config mistake.
is_placeholder() {
  local value="$1"
  [[ -z "$value" ]] && return 0
  case "$value" in
    your_*|YOUR_*|changeme|CHANGEME|xxx|XXX|"<"*">"|replace_me|REPLACE_ME|paste_*|TODO|todo) return 0 ;;
  esac
  return 1
}

# JSON string escaping. Base64url JWTs need none of it, but a gateway URL or a
# hand-pasted value can legally contain a backslash or a quote, and an unescaped
# one would produce a syntactically broken JS file that takes the whole page down.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g'
}

emit_field() {
  # $1 = JS field name, $2 = raw value. Empty becomes `null`, not "".
  if [[ -z "$2" ]]; then
    printf '  %s: null,\n' "$1"
  else
    printf '  %s: "%s",\n' "$1" "$(json_escape "$2")"
  fi
}

# ------------------------------------------------------------------------------
if [[ ! -f "$ENV_FILE" ]]; then
  log_warn "No .env at ${ENV_FILE} — skipping frontend/js/pinata-config.js."
  log_warn "Copy .env.example to .env and set PINATA_JWT, or paste a JWT into the"
  log_warn "IPFS / Pinata panel in the DApp (that path stores it in localStorage)."
  exit 0
fi

read_env_file "$ENV_FILE"

if is_placeholder "$PINATA_JWT_VALUE"; then PINATA_JWT_VALUE=""; fi
if is_placeholder "$PINATA_API_KEY_VALUE"; then PINATA_API_KEY_VALUE=""; fi
if is_placeholder "$PINATA_API_SECRET_VALUE"; then PINATA_API_SECRET_VALUE=""; fi
if is_placeholder "$PINATA_GATEWAY_VALUE"; then PINATA_GATEWAY_VALUE=""; fi

# The legacy pair is all-or-nothing: one half alone cannot authenticate.
if [[ -z "$PINATA_API_KEY_VALUE" || -z "$PINATA_API_SECRET_VALUE" ]]; then
  if [[ -n "$PINATA_API_KEY_VALUE" || -n "$PINATA_API_SECRET_VALUE" ]]; then
    log_warn "PINATA_API_KEY and PINATA_API_SECRET must both be set; ignoring the lone half."
  fi
  PINATA_API_KEY_VALUE=""
  PINATA_API_SECRET_VALUE=""
fi

MODE="none"
if [[ -n "$PINATA_JWT_VALUE" ]]; then
  MODE="jwt"
elif [[ -n "$PINATA_API_KEY_VALUE" ]]; then
  MODE="apiKey"
fi

mkdir -p "$(dirname "$OUTPUT_FILE")"

# umask before creation, so the file is never briefly world-readable between
# open() and chmod(). Written to a temp file and moved, so a reader never sees a
# half-written config.
OLD_UMASK="$(umask)"
umask 077
TMP_FILE="${OUTPUT_FILE}.tmp.$$"

{
  cat <<'HEADER'
// =============================================================================
// GENERATED FILE - DO NOT EDIT, DO NOT COMMIT.
// Produced by scripts/gen-pinata-config.sh from the repository .env.
// Holds a live credential in plaintext: git-ignored, chmod 600.
//
// Precedence in js/ipfsHelper.js:
//   1. a credential saved in this browser's localStorage  (manual override)
//   2. this file                                          (source: "env")
//   3. nothing -> the UI asks the user to configure one
// =============================================================================
window.BOUNTYPULSE_PINATA = Object.freeze({
  source: "env",
HEADER
  printf '  mode: "%s",\n' "$MODE"
  printf '  generatedAt: "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  emit_field jwt       "$PINATA_JWT_VALUE"
  emit_field apiKey    "$PINATA_API_KEY_VALUE"
  emit_field apiSecret "$PINATA_API_SECRET_VALUE"
  emit_field gateway   "$PINATA_GATEWAY_VALUE"
  printf '});\n'
} >"$TMP_FILE"

mv "$TMP_FILE" "$OUTPUT_FILE"
chmod 600 "$OUTPUT_FILE"
umask "$OLD_UMASK"

# ------------------------------------------------------------------------------
# Report. Names and lengths only — a length is enough to tell "the JWT is there"
# from "the JWT is truncated", and it leaks nothing.
# ------------------------------------------------------------------------------
case "$MODE" in
  jwt)
    log_ok "Pinata credential bridged from .env: PINATA_JWT (${#PINATA_JWT_VALUE} chars)"
    ;;
  apiKey)
    log_ok "Pinata credential bridged from .env: PINATA_API_KEY (${#PINATA_API_KEY_VALUE} chars) + PINATA_API_SECRET (${#PINATA_API_SECRET_VALUE} chars)"
    log_info "No PINATA_JWT found, so the legacy key + secret pair is in use."
    ;;
  *)
    log_warn "No usable Pinata credential in ${ENV_FILE} — uploads will fail until one is set."
    log_warn "Set PINATA_JWT (preferred) or PINATA_API_KEY + PINATA_API_SECRET, then re-run this script."
    ;;
esac

if [[ -n "$PINATA_GATEWAY_VALUE" ]]; then
  log_info "PINATA_GATEWAY set (${#PINATA_GATEWAY_VALUE} chars); the DApp will read pinned content through it."
fi

log_info "Wrote ${OUTPUT_FILE#"${REPO_ROOT}/"} ($(wc -c <"$OUTPUT_FILE") bytes, mode $(stat -c '%a' "$OUTPUT_FILE"))"

if [[ "$MODE" != "none" ]]; then
  log_warn "That file holds the credential in plaintext and is served to the browser. Git-ignored; delete it when you are done."
fi
