#!/usr/bin/env bash
# ==============================================================================
# serve-frontend.sh — static file server for the DApp
# ------------------------------------------------------------------------------
# The frontend is plain HTML/CSS/JS with no build step, but it MUST be served
# over http:// rather than opened as file://. MetaMask does not inject
# window.ethereum into file:// pages, and fetch() to the Pinata API is blocked by
# CORS on a null origin.
#
# Usage: ./scripts/serve-frontend.sh [--port N] [--open]
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="${SCRIPT_DIR%/scripts}"
readonly FRONTEND_DIR="${REPO_ROOT}/frontend"

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
else
  C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''
fi

log_info() { printf '%s  i %s %s\n' "$C_CYAN"   "$C_RESET" "$1"; }
log_ok()   { printf '%s  + %s %s\n' "$C_GREEN"  "$C_RESET" "$1"; }
log_warn() { printf '%s  ! %s %s\n' "$C_YELLOW" "$C_RESET" "$1" >&2; }
die()      { printf '%s  x %s %s\n' "$C_RED" "$C_RESET" "$1" >&2; exit 1; }

PORT=8080
OPEN_BROWSER=0

usage() {
  cat <<'EOF'
serve-frontend.sh — serve the BountyPulse DApp over http://

OPTIONS
    --port N     Listen port (default 8080)
    --open       Try to open the page in the default browser
    -h, --help   Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)    PORT="$2"; shift 2 ;;
    --open)    OPEN_BROWSER=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ -f "${FRONTEND_DIR}/index.html" ]] || die "frontend/index.html not found."

# ------------------------------------------------------------------------------
# Vendor ethers.js locally when npm dependencies are present, so the DApp keeps
# working with no internet connection. index.html falls back to the CDN when the
# vendored copy is absent.
# ------------------------------------------------------------------------------
ETHERS_SRC="${REPO_ROOT}/node_modules/ethers/dist/ethers.umd.min.js"
ETHERS_DEST="${FRONTEND_DIR}/vendor/ethers.umd.min.js"
if [[ -f "$ETHERS_SRC" ]]; then
  mkdir -p "${FRONTEND_DIR}/vendor"
  if [[ ! -f "$ETHERS_DEST" || "$ETHERS_SRC" -nt "$ETHERS_DEST" ]]; then
    cp "$ETHERS_SRC" "$ETHERS_DEST"
    log_ok "Vendored ethers.js from node_modules (offline-capable)"
  else
    log_info "Vendored ethers.js is up to date"
  fi
else
  log_warn "node_modules/ethers not found — the page will load ethers.js from the CDN."
  log_warn "Run 'npm install' for an offline-capable setup."
fi

if [[ ! -f "${FRONTEND_DIR}/js/contract-address.js" ]]; then
  log_warn "frontend/js/contract-address.js is missing."
  log_warn "Run ./scripts/deploy-local.sh first, or paste the address into the DApp."
fi

# ------------------------------------------------------------------------------
# Bridge the Pinata credential out of .env and into the page.
# A browser cannot read .env, so without this step a perfectly valid PINATA_JWT
# on disk is invisible to the DApp and every upload fails with
# "No Pinata credential configured".
#
# Delegated to one script with one job (scripts/gen-pinata-config.sh) rather
# than inlined here: deploy-local.sh needs exactly the same behaviour, and a
# secret-handling routine must exist in precisely one place.
#
# It never fails the server: a missing credential is recoverable in the UI.
# ------------------------------------------------------------------------------
if [[ -x "${SCRIPT_DIR}/gen-pinata-config.sh" ]]; then
  "${SCRIPT_DIR}/gen-pinata-config.sh" || log_warn "Pinata config generation failed; the DApp will ask for a credential."
else
  log_warn "scripts/gen-pinata-config.sh is missing or not executable — skipping the .env credential bridge."
fi

printf '%s' "$C_BOLD"
cat <<EOF
================================================================================
  BountyPulse DApp
================================================================================
EOF
printf '%s' "$C_RESET"
log_ok   "http://127.0.0.1:${PORT}"
log_info "Serving ${FRONTEND_DIR}"
log_info "Open the page in TWO browser windows with different MetaMask accounts"
log_info "to demonstrate checkpoint 5 (live event auto-sync)."
echo

if [[ $OPEN_BROWSER -eq 1 ]] && command -v xdg-open >/dev/null 2>&1; then
  ( sleep 1 && xdg-open "http://127.0.0.1:${PORT}" >/dev/null 2>&1 & )
fi

if command -v python3 >/dev/null 2>&1; then
  # -u keeps the request log unbuffered so it is useful while debugging.
  exec python3 -u -m http.server "$PORT" --bind 127.0.0.1 --directory "$FRONTEND_DIR"
elif command -v npx >/dev/null 2>&1; then
  exec npx --yes http-server "$FRONTEND_DIR" -p "$PORT" -a 127.0.0.1 -c-1
else
  die "Neither python3 nor npx is available to serve static files."
fi
