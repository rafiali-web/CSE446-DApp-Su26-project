#!/usr/bin/env bash
# ==============================================================================
# deploy-local.sh — deploy BountyPulse to the local chain and wire up the DApp
# ------------------------------------------------------------------------------
# 1. verifies the RPC endpoint is alive and on the expected chain
# 2. compiles
# 3. runs script/Deploy.s.sol with --broadcast
# 4. reads back the deployed address and the freshly compiled ABI
# 5. generates frontend/js/contract-address.js so the DApp needs zero manual setup
#
# Idempotent in the sense that it can be re-run at will; each run deploys a NEW
# instance (anvil forgets everything on restart) and overwrites the generated
# frontend file, which is git-ignored precisely because it is generated.
#
# Usage: ./scripts/deploy-local.sh [--rpc-url URL] [--gas-report]
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="${SCRIPT_DIR%/scripts}"

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''
fi

log_step() { printf '\n%s==>%s %s%s%s\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$1" "$C_RESET"; }
log_info() { printf '%s  i %s %s\n' "$C_CYAN"   "$C_RESET" "$1"; }
log_ok()   { printf '%s  + %s %s\n' "$C_GREEN"  "$C_RESET" "$1"; }
log_warn() { printf '%s  ! %s %s\n' "$C_YELLOW" "$C_RESET" "$1" >&2; }
die()      { printf '%s  x %s %s\n' "$C_RED" "$C_RESET" "$1" >&2; exit 1; }

RPC_URL_ARG=""
GAS_REPORT=0

usage() {
  cat <<'EOF'
deploy-local.sh — deploy BountyPulse to a local chain and sync the frontend

OPTIONS
    --rpc-url URL   Override the RPC endpoint (default: $RPC_URL or
                    http://127.0.0.1:8545)
    --gas-report    Also print `forge test --gas-report` after deploying
    -h, --help      Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rpc-url)    RPC_URL_ARG="$2"; shift 2 ;;
    --gas-report) GAS_REPORT=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

export PATH="${HOME}/.foundry/bin:${PATH}"
command -v forge >/dev/null 2>&1 || die "forge not found. Run ./setup.sh first."
command -v cast  >/dev/null 2>&1 || die "cast not found. Run ./setup.sh first."

# ------------------------------------------------------------------------------
# Load .env WITHOUT executing it. `set -a; source .env` would run arbitrary shell
# from a file that is allowed to contain secrets and stray characters, so each
# line is parsed and assigned explicitly instead.
# ------------------------------------------------------------------------------
load_env_file() {
  local file="${REPO_ROOT}/.env"
  [[ -f "$file" ]] || { log_warn ".env not found — using defaults (run ./setup.sh to create it)."; return 0; }

  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" != *=* ]] && continue

    key="${line%%=*}"
    value="${line#*=}"
    key="${key//[[:space:]]/}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

    # Strip one layer of matching quotes.
    value="${value%\"}"; value="${value#\"}"
    value="${value%\'}"; value="${value#\'}"

    export "${key}=${value}"
  done <"$file"
  log_ok "Loaded configuration from .env"
}

log_step "Configuration"
load_env_file

RPC_URL="${RPC_URL_ARG:-${RPC_URL:-http://127.0.0.1:8545}}"
EXPECTED_CHAIN_ID="${CHAIN_ID:-31337}"
log_info "RPC URL  : ${RPC_URL}"
log_info "Chain id : ${EXPECTED_CHAIN_ID} (expected)"

# ------------------------------------------------------------------------------
log_step "Checking the chain is reachable"
# ------------------------------------------------------------------------------
if ! ACTUAL_CHAIN_ID="$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null)"; then
  log_warn "No JSON-RPC endpoint responded at ${RPC_URL}."
  die "Start the chain first:  ./scripts/start-anvil.sh"
fi

if [[ "$ACTUAL_CHAIN_ID" != "$EXPECTED_CHAIN_ID" ]]; then
  log_warn "Chain id mismatch: the node reports ${ACTUAL_CHAIN_ID}, .env expects ${EXPECTED_CHAIN_ID}."
  log_warn "Continuing, but MetaMask must be pointed at chain id ${ACTUAL_CHAIN_ID}."
fi
log_ok "Chain id ${ACTUAL_CHAIN_ID} at block $(cast block-number --rpc-url "$RPC_URL")"

# ------------------------------------------------------------------------------
log_step "Compiling"
# ------------------------------------------------------------------------------
( cd "$REPO_ROOT" && forge build )

# ------------------------------------------------------------------------------
log_step "Deploying BountyPulse"
# ------------------------------------------------------------------------------
mkdir -p "${REPO_ROOT}/deployments"
(
  cd "$REPO_ROOT"
  forge script script/Deploy.s.sol:Deploy \
    --rpc-url "$RPC_URL" \
    --broadcast \
    -vvv
)

DEPLOYMENT_FILE="${REPO_ROOT}/deployments/${ACTUAL_CHAIN_ID}.local.json"
[[ -f "$DEPLOYMENT_FILE" ]] || die "Deployment record not written: ${DEPLOYMENT_FILE}"

# ------------------------------------------------------------------------------
log_step "Reading back the deployment"
# ------------------------------------------------------------------------------
extract_json_string() {
  # $1 = file, $2 = key. Uses jq when available, otherwise a portable fallback.
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$2" '.[$k] | tostring' "$1"
  else
    sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$1" | head -n1
  fi
}

CONTRACT_ADDRESS="$(extract_json_string "$DEPLOYMENT_FILE" address)"
ARBITER_ADDRESS="$(extract_json_string "$DEPLOYMENT_FILE" arbiter)"
DEPLOY_BLOCK="$(extract_json_string "$DEPLOYMENT_FILE" blockNumber)"

[[ "$CONTRACT_ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "Could not parse a contract address from ${DEPLOYMENT_FILE}"
log_ok "Address : ${CONTRACT_ADDRESS}"
log_ok "Arbiter : ${ARBITER_ADDRESS}"

# Independent verification: ask the chain, do not trust the file.
ONCHAIN_ARBITER="$(cast call "$CONTRACT_ADDRESS" 'arbiter()(address)' --rpc-url "$RPC_URL")"
RUNTIME_CODE="$(cast code "$CONTRACT_ADDRESS" --rpc-url "$RPC_URL")"
[[ "$RUNTIME_CODE" != "0x" && -n "$RUNTIME_CODE" ]] || die "No runtime code at ${CONTRACT_ADDRESS} — the deployment did not take."
CODE_SIZE=$(( (${#RUNTIME_CODE} - 2) / 2 ))   # strip the 0x, two hex chars per byte
log_ok "Verified on-chain: arbiter() = ${ONCHAIN_ARBITER}, runtime code = ${CODE_SIZE} bytes"

# ------------------------------------------------------------------------------
log_step "Syncing the ABI and address into the frontend"
# ------------------------------------------------------------------------------
ARTIFACT="${REPO_ROOT}/out/BountyPulse.sol/BountyPulse.json"
[[ -f "$ARTIFACT" ]] || die "Compiler artifact missing: ${ARTIFACT}"

GENERATED="${REPO_ROOT}/frontend/js/contract-address.js"
mkdir -p "$(dirname "$GENERATED")"

if command -v jq >/dev/null 2>&1; then
  ABI_JSON="$(jq -c '.abi' "$ARTIFACT")"
else
  die "jq is required to extract the ABI. Install it, or copy out/BountyPulse.sol/BountyPulse.json .abi manually."
fi

# Written atomically: a half-written file would leave the DApp in a broken state.
TMP_FILE="${GENERATED}.tmp.$$"
cat >"$TMP_FILE" <<EOF
// ==============================================================================
// GENERATED FILE — DO NOT EDIT, DO NOT COMMIT (.gitignore excludes it).
// Produced by scripts/deploy-local.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
//
// Regenerate by re-running:  ./scripts/deploy-local.sh
// ==============================================================================
window.BOUNTYPULSE_DEPLOYMENT = {
  address: "${CONTRACT_ADDRESS}",
  arbiter: "${ARBITER_ADDRESS}",
  chainId: ${ACTUAL_CHAIN_ID},
  rpcUrl: "${RPC_URL}",
  deployedAtBlock: ${DEPLOY_BLOCK:-0},
  generatedAt: "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  abi: ${ABI_JSON}
};
EOF
mv "$TMP_FILE" "$GENERATED"
log_ok "Wrote frontend/js/contract-address.js ($(wc -c <"$GENERATED") bytes, ABI inlined)"

# ------------------------------------------------------------------------------
# The contract address is only half of what the page needs. The other half is
# the Pinata credential, which lives in .env and which a browser cannot read.
# Generating it here too means one command leaves the DApp fully wired up.
# ------------------------------------------------------------------------------
if [[ -x "${SCRIPT_DIR}/gen-pinata-config.sh" ]]; then
  "${SCRIPT_DIR}/gen-pinata-config.sh" || log_warn "Pinata config generation failed; set the credential in the DApp instead."
else
  log_warn "scripts/gen-pinata-config.sh is missing — the DApp will ask for a Pinata credential."
fi

# ------------------------------------------------------------------------------
# Publish the ABI as a standalone artifact as well. Anything outside this repo
# (a script, a subgraph, a second frontend) wants the plain ABI, not a JS file
# with a window assignment wrapped around it.
# ------------------------------------------------------------------------------
mkdir -p "${REPO_ROOT}/abi"
printf '%s\n' "$(jq '.abi' "$ARTIFACT")" >"${REPO_ROOT}/abi/BountyPulse.json"
log_ok "Wrote abi/BountyPulse.json ($(wc -c <"${REPO_ROOT}/abi/BountyPulse.json") bytes)"

if [[ $GAS_REPORT -eq 1 ]]; then
  log_step "Gas report"
  ( cd "$REPO_ROOT" && forge test --gas-report )
fi

# ------------------------------------------------------------------------------
printf '\n%s%s\n' "$C_BOLD" "================================================================================"
printf '  Deployed and wired up\n'
printf '%s%s\n' "================================================================================" "$C_RESET"
cat <<EOF

  Contract : ${C_BOLD}${CONTRACT_ADDRESS}${C_RESET}
  Arbiter  : ${ARBITER_ADDRESS}
  Chain    : ${ACTUAL_CHAIN_ID} via ${RPC_URL}

  Next:
    ./scripts/serve-frontend.sh      then open http://127.0.0.1:8080

  ${C_DIM}The DApp reads the address above automatically — no copy-paste needed.
  Re-run this script after every anvil restart; the chain forgets everything.${C_RESET}

EOF
