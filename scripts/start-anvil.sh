#!/usr/bin/env bash
# ==============================================================================
# start-anvil.sh — launch the local EVM development chain
# ------------------------------------------------------------------------------
# Chain id 31337, ten pre-funded accounts, instant mining. This is the chain the
# DApp and MetaMask both point at.
#
# Usage: ./scripts/start-anvil.sh [--port N] [--block-time N] [--log FILE]
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="${SCRIPT_DIR%/scripts}"

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
else
  C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''
fi

log_info()  { printf '%s  i %s %s\n' "$C_CYAN"   "$C_RESET" "$1"; }
log_ok()    { printf '%s  + %s %s\n' "$C_GREEN"  "$C_RESET" "$1"; }
log_warn()  { printf '%s  ! %s %s\n' "$C_YELLOW" "$C_RESET" "$1" >&2; }
die()       { printf '%s  x %s %s\n' "$C_RED" "$C_RESET" "$1" >&2; exit 1; }

PORT=8545
CHAIN_ID=31337
BLOCK_TIME=""
LOG_FILE=""

usage() {
  cat <<'EOF'
start-anvil.sh — local EVM chain for BountyPulse

OPTIONS
    --port N         Listen port                (default 8545)
    --chain-id N     Chain id                   (default 31337)
    --block-time N   Seconds per block. Omit for instant mining (default).
                     Use --block-time 2 to watch event listeners fire against
                     realistic block cadence.
    --log FILE       Also tee output to FILE    (default: stdout only)
    -h, --help       Show this help

The first account printed below is the DEPLOYER, and therefore the platform
ARBITER. Import its private key into MetaMask to act as the admin.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)       PORT="$2"; shift 2 ;;
    --chain-id)   CHAIN_ID="$2"; shift 2 ;;
    --block-time) BLOCK_TIME="$2"; shift 2 ;;
    --log)        LOG_FILE="$2"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

export PATH="${HOME}/.foundry/bin:${PATH}"
command -v anvil >/dev/null 2>&1 || die "anvil not found. Run ./setup.sh first."

# ------------------------------------------------------------------------------
# Refuse to start on an occupied port rather than failing with a cryptic bind
# error, and tell the user what is already there.
# ------------------------------------------------------------------------------
if command -v curl >/dev/null 2>&1; then
  if curl -s -m 2 -X POST "http://127.0.0.1:${PORT}" \
       -H 'Content-Type: application/json' \
       --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' >/dev/null 2>&1; then
    log_warn "Something is already answering JSON-RPC on port ${PORT}."
    log_warn "If that is an existing anvil instance, keep using it, or stop it first."
    die "Port ${PORT} is busy."
  fi
fi

mkdir -p "${REPO_ROOT}/deployments"

printf '%s' "$C_BOLD"
cat <<EOF
================================================================================
  BountyPulse — local chain
================================================================================
EOF
printf '%s' "$C_RESET"
log_info "RPC URL   : http://127.0.0.1:${PORT}"
log_info "Chain id  : ${CHAIN_ID}"
log_info "Mining    : ${BLOCK_TIME:+every ${BLOCK_TIME}s}${BLOCK_TIME:-instant (on every transaction)}"
log_ok   "Press Ctrl+C to stop. State is in memory and is LOST on exit —"
log_ok   "re-run ./scripts/deploy-local.sh after every restart."
echo

ANVIL_ARGS=(
  --host 127.0.0.1
  --port "$PORT"
  --chain-id "$CHAIN_ID"
  --accounts 10
  --balance 10000
)
[[ -n "$BLOCK_TIME" ]] && ANVIL_ARGS+=(--block-time "$BLOCK_TIME")

if [[ -n "$LOG_FILE" ]]; then
  log_info "Teeing output to ${LOG_FILE}"
  exec anvil "${ANVIL_ARGS[@]}" 2>&1 | tee "$LOG_FILE"
else
  exec anvil "${ANVIL_ARGS[@]}"
fi
