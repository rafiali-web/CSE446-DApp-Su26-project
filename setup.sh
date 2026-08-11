#!/usr/bin/env bash
# ==============================================================================
# BountyPulse — one-shot developer environment setup
# ------------------------------------------------------------------------------
# Idempotent. Safe to re-run any number of times.
#
# This script NEVER runs `sudo` and never modifies anything outside:
#   - this repository
#   - ~/.foundry            (the Foundry toolchain, a per-user install)
#   - ~/.bashrc / ~/.zshrc  (a single guarded PATH line, appended once)
#
# Anything that genuinely requires root is DETECTED, not executed. The exact
# commands are printed at the end for a human to review and run.
#
# Usage:  ./setup.sh [--help] [--skip-foundry] [--skip-node] [--skip-tests]
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# Resolve the repository root from the script's own location so the script works
# regardless of the caller's current working directory.
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly REPO_ROOT="$SCRIPT_DIR"
readonly FOUNDRY_DIR="${HOME}/.foundry"
readonly FOUNDRY_BIN="${FOUNDRY_DIR}/bin"
readonly PATH_MARKER="# >>> BountyPulse: foundry >>>"

# ------------------------------------------------------------------------------
# Terminal colours. Disabled automatically when stdout is not a TTY (CI, pipes)
# so log files do not fill up with escape sequences.
# ------------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''
fi
readonly C_RESET C_BOLD C_DIM C_RED C_GREEN C_YELLOW C_BLUE C_CYAN

log_step()  { printf '\n%s==>%s %s%s%s\n' "$C_BLUE" "$C_RESET" "$C_BOLD" "$1" "$C_RESET"; }
log_info()  { printf '%s  i %s %s\n' "$C_CYAN"   "$C_RESET" "$1"; }
log_ok()    { printf '%s  + %s %s\n' "$C_GREEN"  "$C_RESET" "$1"; }
log_skip()  { printf '%s  = %s %s%s%s\n' "$C_DIM" "$C_RESET" "$C_DIM" "$1" "$C_RESET"; }
log_warn()  { printf '%s  ! %s %s\n' "$C_YELLOW" "$C_RESET" "$1" >&2; }
log_error() { printf '%s  x %s %s\n' "$C_RED"    "$C_RESET" "$1" >&2; }
die()       { log_error "$1"; exit "${2:-1}"; }

# ------------------------------------------------------------------------------
# Root-requiring work is collected here, never executed.
# ------------------------------------------------------------------------------
SUDO_COMMANDS=()
MISSING_SYSTEM_PACKAGES=()

SKIP_FOUNDRY=0
SKIP_NODE=0
SKIP_TESTS=0

usage() {
  cat <<'EOF'
BountyPulse setup
=================

Prepares a local development environment for the BountyPulse decentralized
micro-bounty platform: installs the Foundry toolchain for the current user,
resolves Solidity dependencies, compiles the contracts, runs the test suite and
seeds a local .env from .env.example.

USAGE
    ./setup.sh [OPTIONS]

OPTIONS
    --skip-foundry   Do not install or update the Foundry toolchain.
                     (Still verifies that forge/anvil/cast are reachable.)
    --skip-node      Do not touch Node.js dependencies.
    --skip-tests     Compile the contracts but do not run `forge test`.
    -h, --help       Show this help and exit.

BEHAVIOUR
    * Idempotent  - re-running performs no destructive work.
    * No sudo     - commands needing root are PRINTED, never executed.
    * Never overwrites an existing .env.

AFTER RUNNING
    ./scripts/start-anvil.sh      # terminal 1: local EVM chain on :8545
    ./scripts/deploy-local.sh     # terminal 2: deploy + sync ABI to frontend
    ./scripts/serve-frontend.sh   # terminal 3: static server on :8080
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-foundry) SKIP_FOUNDRY=1; shift ;;
    --skip-node)    SKIP_NODE=1;    shift ;;
    --skip-tests)   SKIP_TESTS=1;   shift ;;
    -h|--help)      usage; exit 0 ;;
    *) log_error "Unknown option: $1"; echo; usage; exit 64 ;;
  esac
done

has_command() { command -v "$1" >/dev/null 2>&1; }

# ==============================================================================
# 1. Environment detection
# ==============================================================================
detect_environment() {
  log_step "Detecting environment"

  local os_name kernel arch
  os_name="$(uname -s)"
  kernel="$(uname -r)"
  arch="$(uname -m)"

  DISTRO_ID="unknown"
  DISTRO_PRETTY="$os_name"
  PKG_MANAGER=""

  if [[ "$os_name" == "Linux" && -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    DISTRO_ID="$(. /etc/os-release && printf '%s' "${ID:-unknown}")"
    DISTRO_PRETTY="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-Linux}")"
  elif [[ "$os_name" == "Darwin" ]]; then
    DISTRO_ID="macos"
    DISTRO_PRETTY="macOS $(sw_vers -productVersion 2>/dev/null || echo '')"
  fi

  # Pick the package manager purely to build a correct *suggested* command line.
  if   has_command apt-get; then PKG_MANAGER="apt-get"
  elif has_command dnf;     then PKG_MANAGER="dnf"
  elif has_command pacman;  then PKG_MANAGER="pacman"
  elif has_command brew;    then PKG_MANAGER="brew"
  fi

  log_info "OS            : ${DISTRO_PRETTY} (${os_name} ${kernel} ${arch})"
  log_info "Package mgr   : ${PKG_MANAGER:-none detected}"
  log_info "Shell         : ${SHELL:-unknown}"
  log_info "Repository    : ${REPO_ROOT}"

  if [[ "$(id -u)" -eq 0 ]]; then
    log_warn "Running as root. Foundry would be installed into /root/.foundry."
    log_warn "Re-run this script as your normal user."
  fi
}

# ==============================================================================
# 2. System prerequisites — detect only, never install
# ==============================================================================
#
# Root is required to install these, so we record the exact command instead of
# running it. On a machine that already has them (the common case) this whole
# section degrades to "nothing needed".
# ==============================================================================
queue_system_package() {
  local binary="$1" apt_pkg="$2" dnf_pkg="$3" pacman_pkg="$4" brew_pkg="$5"
  if has_command "$binary"; then
    log_ok "${binary} present ($(command -v "$binary"))"
    return 0
  fi

  log_warn "${binary} is MISSING"
  case "$PKG_MANAGER" in
    apt-get) MISSING_SYSTEM_PACKAGES+=("$apt_pkg") ;;
    dnf)     MISSING_SYSTEM_PACKAGES+=("$dnf_pkg") ;;
    pacman)  MISSING_SYSTEM_PACKAGES+=("$pacman_pkg") ;;
    brew)    MISSING_SYSTEM_PACKAGES+=("$brew_pkg") ;;
    *)       MISSING_SYSTEM_PACKAGES+=("$binary") ;;
  esac
}

check_system_prerequisites() {
  log_step "Checking system prerequisites (no changes will be made)"

  #                  binary   apt              dnf              pacman        brew
  queue_system_package git    git              git              git           git
  queue_system_package curl   curl             curl             curl          curl
  queue_system_package unzip  unzip            unzip            unzip         unzip
  queue_system_package cc     build-essential  gcc              base-devel    ""
  queue_system_package python3 python3         python3          python        python3

  if [[ ${#MISSING_SYSTEM_PACKAGES[@]} -eq 0 ]]; then
    log_ok "All system prerequisites satisfied — no root privileges required."
    return 0
  fi

  # De-duplicate and drop empties (brew ships a compiler via Xcode CLT).
  local -a pkgs=()
  local pkg
  for pkg in "${MISSING_SYSTEM_PACKAGES[@]}"; do
    [[ -z "$pkg" ]] && continue
    [[ " ${pkgs[*]-} " == *" $pkg "* ]] && continue
    pkgs+=("$pkg")
  done
  [[ ${#pkgs[@]} -eq 0 ]] && return 0

  case "$PKG_MANAGER" in
    apt-get)
      SUDO_COMMANDS+=("sudo apt-get update")
      SUDO_COMMANDS+=("sudo apt-get install -y ${pkgs[*]}")
      ;;
    dnf)    SUDO_COMMANDS+=("sudo dnf install -y ${pkgs[*]}") ;;
    pacman) SUDO_COMMANDS+=("sudo pacman -S --needed --noconfirm ${pkgs[*]}") ;;
    brew)   SUDO_COMMANDS+=("brew install ${pkgs[*]}   # no sudo needed for brew") ;;
    *)      SUDO_COMMANDS+=("# Install with your package manager: ${pkgs[*]}") ;;
  esac

  log_warn "${#pkgs[@]} system package(s) must be installed by a human with root."
}

# ==============================================================================
# 3. Shell PATH wiring
# ==============================================================================
add_foundry_to_path_file() {
  local rc_file="$1"
  [[ -e "$rc_file" ]] || return 0          # do not create shell rc files we do not own

  if grep -Fq "$PATH_MARKER" "$rc_file" 2>/dev/null; then
    log_skip "$(basename "$rc_file") already wired for Foundry"
    return 0
  fi
  # A pre-existing hand-rolled entry is good enough; do not add a second one.
  if grep -Fq '.foundry/bin' "$rc_file" 2>/dev/null; then
    log_skip "$(basename "$rc_file") already references ~/.foundry/bin"
    return 0
  fi

  {
    printf '\n%s\n' "$PATH_MARKER"
    printf 'export PATH="$HOME/.foundry/bin:$PATH"\n'
    printf '%s\n' "# <<< BountyPulse: foundry <<<"
  } >>"$rc_file"
  log_ok "Appended Foundry PATH entry to $(basename "$rc_file")"
}

wire_shell_path() {
  log_step "Wiring ~/.foundry/bin into shell startup files"
  add_foundry_to_path_file "${HOME}/.bashrc"
  add_foundry_to_path_file "${HOME}/.zshrc"
  # Make the toolchain visible to the rest of THIS script run.
  case ":${PATH}:" in
    *":${FOUNDRY_BIN}:"*) : ;;
    *) export PATH="${FOUNDRY_BIN}:${PATH}" ;;
  esac
}

# ==============================================================================
# 4. Foundry toolchain
# ==============================================================================
install_foundry() {
  log_step "Foundry toolchain (forge / anvil / cast)"

  if [[ $SKIP_FOUNDRY -eq 1 ]]; then
    log_skip "--skip-foundry given"
  elif [[ -x "${FOUNDRY_BIN}/foundryup" ]]; then
    log_skip "foundryup already installed at ${FOUNDRY_BIN}/foundryup"
  else
    has_command curl || die "curl is required to install Foundry. See the SUDO COMMANDS section."
    log_info "Downloading the Foundry installer from https://foundry.paradigm.xyz ..."
    # The installer is a per-user install: it only writes to ~/.foundry and rc files.
    if ! curl -fsSL --retry 3 --retry-delay 2 https://foundry.paradigm.xyz | bash; then
      die "Foundry installer failed. Check network connectivity and retry."
    fi
    log_ok "foundryup installed"
  fi

  wire_shell_path

  if [[ $SKIP_FOUNDRY -eq 0 ]]; then
    [[ -x "${FOUNDRY_BIN}/foundryup" ]] || die "foundryup not found at ${FOUNDRY_BIN}/foundryup after installation."

    # Is a working toolchain already on disk? This decides whether a foundryup
    # failure is fatal or merely inconvenient.
    local toolchain_present=1
    local binary
    for binary in forge anvil cast; do
      [[ -x "${FOUNDRY_BIN}/${binary}" ]] || toolchain_present=0
    done

    # `foundryup` with no arguments installs/updates the latest stable release.
    # It is safe to re-run: it is a no-op when already on the latest version.
    log_info "Running foundryup (installs or updates the stable toolchain) ..."
    if ! "${FOUNDRY_BIN}/foundryup"; then
      if [[ $toolchain_present -eq 1 ]]; then
        # The common cause is a running anvil/forge holding the binaries open —
        # exactly what happens when a developer re-runs setup.sh with the chain
        # up in another terminal. The toolchain is already usable, so this is a
        # warning, not a failure. Being non-fatal here is what makes the script
        # genuinely idempotent.
        log_warn "foundryup could not update the toolchain."
        log_warn "This is expected if anvil or forge is currently running — stop them and"
        log_warn "re-run ./setup.sh to pick up a newer release."
        log_warn "Continuing with the already-installed toolchain."
      else
        die "foundryup failed and no usable toolchain is installed. Check network connectivity."
      fi
    fi
  fi

  local tool
  for tool in forge anvil cast; do
    has_command "$tool" || die "${tool} is not on PATH. Open a new shell, or: export PATH=\"\$HOME/.foundry/bin:\$PATH\""
  done

  log_ok "forge : $(forge --version 2>/dev/null | head -n1)"
  log_ok "anvil : $(anvil --version 2>/dev/null | head -n1)"
  log_ok "cast  : $(cast  --version 2>/dev/null | head -n1)"
}

# ==============================================================================
# 5. Node.js
# ==============================================================================
setup_node() {
  log_step "Node.js toolchain"

  if [[ $SKIP_NODE -eq 1 ]]; then
    log_skip "--skip-node given"
    return 0
  fi

  if ! has_command node; then
    log_warn "node is MISSING. BountyPulse needs Node.js >= 18 only for the static"
    log_warn "dev server and optional tooling; the contracts build without it."
    SUDO_COMMANDS+=("# Install Node.js 22 LTS (nodesource), review before running:")
    SUDO_COMMANDS+=("curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -")
    SUDO_COMMANDS+=("sudo apt-get install -y nodejs")
    return 0
  fi

  local node_version node_major
  node_version="$(node --version)"          # e.g. v22.18.0
  node_major="${node_version#v}"; node_major="${node_major%%.*}"
  log_ok "node : ${node_version}"

  if (( node_major < 18 )); then
    log_warn "Node ${node_version} is older than the supported minimum (18)."
  fi

  if has_command npm; then
    log_ok "npm  : $(npm --version)"
  else
    log_warn "npm is missing even though node is present."
    return 0
  fi

  if [[ -f "${REPO_ROOT}/package.json" ]]; then
    if [[ -d "${REPO_ROOT}/node_modules" ]]; then
      log_skip "node_modules/ already present — skipping install"
    else
      log_info "Installing npm dependencies ..."
      ( cd "$REPO_ROOT" && npm install --no-audit --no-fund )
      log_ok "npm dependencies installed"
    fi
  else
    log_skip "No package.json — nothing to install"
  fi
}

# ==============================================================================
# 6. Solidity dependencies
# ==============================================================================
#
# forge-std is the only Solidity dependency (test harness + cheatcodes).
#
# Installation mode matters here: this repository IS a git repository, and the
# default `forge install` behaviour is to add the dependency as a git SUBMODULE.
# That would create a gitlink at lib/forge-std while lib/ is .gitignore'd, which
# produces a repo that cannot be cloned cleanly. We therefore prefer `--no-git`
# (plain vendored copy) and fall back across Foundry versions that spell the
# flag differently.
# ==============================================================================
install_solidity_deps() {
  log_step "Solidity dependencies (forge-std)"

  if [[ -f "${REPO_ROOT}/lib/forge-std/src/Test.sol" ]]; then
    log_skip "forge-std already installed at lib/forge-std"
    return 0
  fi

  mkdir -p "${REPO_ROOT}/lib"

  local -a attempts=(
    "forge install foundry-rs/forge-std --no-git"
    "forge install foundry-rs/forge-std --no-commit"
    "forge install foundry-rs/forge-std"
  )
  local attempt
  for attempt in "${attempts[@]}"; do
    log_info "Trying: ${attempt}"
    if ( cd "$REPO_ROOT" && eval "$attempt" ) >/dev/null 2>&1; then
      if [[ -f "${REPO_ROOT}/lib/forge-std/src/Test.sol" ]]; then
        log_ok "forge-std installed (${attempt##* })"
        return 0
      fi
    fi
    log_warn "Attempt failed, trying next strategy ..."
  done

  # Last resort: a shallow git clone is functionally identical to --no-git.
  log_info "Falling back to a shallow git clone of forge-std ..."
  if git clone --depth 1 https://github.com/foundry-rs/forge-std "${REPO_ROOT}/lib/forge-std" >/dev/null 2>&1; then
    log_ok "forge-std installed via git clone"
    return 0
  fi

  die "Could not install forge-std. Check network access to github.com."
}

# ==============================================================================
# 7. Build and test
# ==============================================================================
build_contracts() {
  log_step "Compiling contracts (forge build)"
  if ! compgen -G "${REPO_ROOT}/src/*.sol" >/dev/null; then
    log_warn "No contracts found in src/ — skipping build."
    return 0
  fi
  ( cd "$REPO_ROOT" && forge build )
  log_ok "Contracts compiled"
}

test_contracts() {
  log_step "Running the test suite (forge test)"
  if [[ $SKIP_TESTS -eq 1 ]]; then
    log_skip "--skip-tests given"
    return 0
  fi
  if ! compgen -G "${REPO_ROOT}/test/*.sol" >/dev/null; then
    log_warn "No tests found in test/ — skipping."
    return 0
  fi
  ( cd "$REPO_ROOT" && forge test -vv )
  log_ok "All tests passed"
}

# ==============================================================================
# 8. Local configuration
# ==============================================================================
#
# The .env file is developer-local and may contain a real Pinata JWT. It is
# therefore NEVER overwritten and NEVER committed (.gitignore enforces this).
# ==============================================================================
setup_env_file() {
  log_step "Local configuration (.env)"

  local example="${REPO_ROOT}/.env.example"
  local target="${REPO_ROOT}/.env"

  [[ -f "$example" ]] || { log_warn ".env.example is missing — cannot seed .env"; return 0; }

  if [[ -f "$target" ]]; then
    log_skip ".env already exists — leaving it untouched (no overwrite, by design)"
    log_info "Compare against the template with:  diff .env .env.example"
    return 0
  fi

  cp "$example" "$target"
  chmod 600 "$target"
  log_ok "Created .env from .env.example (mode 600)"
  log_warn "Edit .env and set PINATA_JWT before using the IPFS upload features."
}

make_scripts_executable() {
  log_step "Marking helper scripts executable"
  local script
  local found=0
  for script in "${REPO_ROOT}"/scripts/*.sh "${REPO_ROOT}/setup.sh"; do
    [[ -f "$script" ]] || continue
    found=1
    if [[ -x "$script" ]]; then
      log_skip "$(basename "$script") already executable"
    else
      chmod +x "$script"
      log_ok "chmod +x $(basename "$script")"
    fi
  done
  [[ $found -eq 1 ]] || log_warn "No helper scripts found in scripts/"
}

# ==============================================================================
# 9. Summary
# ==============================================================================
print_sudo_commands() {
  printf '\n%s%s\n' "$C_BOLD" "================================================================================"
  printf '  SUDO COMMANDS\n'
  printf '%s%s\n' "================================================================================" "$C_RESET"

  if [[ ${#SUDO_COMMANDS[@]} -eq 0 ]]; then
    printf '%s  Nothing needed. Every prerequisite is already installed on this machine.%s\n' \
      "$C_GREEN" "$C_RESET"
    return 0
  fi

  printf '%s  This script does not run sudo. Review and run these yourself:%s\n\n' \
    "$C_YELLOW" "$C_RESET"
  local cmd
  for cmd in "${SUDO_COMMANDS[@]}"; do
    printf '      %s%s%s\n' "$C_BOLD" "$cmd" "$C_RESET"
  done
  printf '\n%s  Then re-run ./setup.sh%s\n' "$C_YELLOW" "$C_RESET"
}

print_next_steps() {
  printf '\n%s%s\n' "$C_BOLD" "================================================================================"
  printf '  BountyPulse is ready — next steps\n'
  printf '%s%s\n' "================================================================================" "$C_RESET"
  cat <<EOF

  ${C_BOLD}1. Start the local chain${C_RESET}            (terminal 1)
       ./scripts/start-anvil.sh
     Anvil listens on http://127.0.0.1:8545 with chain id 31337 and prints ten
     pre-funded accounts (10000 ETH each) with their private keys.

  ${C_BOLD}2. Deploy the contract${C_RESET}              (terminal 2)
       ./scripts/deploy-local.sh
     Deploys BountyPulse.sol, prints the address + gas used, and syncs the ABI
     and address into frontend/js/ automatically.

  ${C_BOLD}3. Serve the DApp${C_RESET}                   (terminal 3)
       ./scripts/serve-frontend.sh
     Opens a static server on http://127.0.0.1:8080

  ${C_BOLD}4. Configure MetaMask${C_RESET}
       Network name : Anvil Local
       RPC URL      : http://127.0.0.1:8545
       Chain ID     : 31337
       Currency     : ETH
     Import one of the private keys anvil printed in step 1. The FIRST account
     is the deployer and therefore the Arbiter.

  ${C_BOLD}5. Pinata (IPFS)${C_RESET}
       Put your JWT in .env (PINATA_JWT=...) and paste it into the DApp's
       "IPFS / Pinata" panel. It is stored in this browser's localStorage only.

  ${C_DIM}Full documentation: README.md${C_RESET}
EOF
}

main() {
  printf '%s\n' "$C_BOLD"
  cat <<'BANNER'
  ____                    _         ____        _
 | __ )  ___  _   _ _ __ | |_ _   _|  _ \ _   _| |___  ___
 |  _ \ / _ \| | | | '_ \| __| | | | |_) | | | | / __|/ _ \
 | |_) | (_) | |_| | | | | |_| |_| |  __/| |_| | \__ \  __/
 |____/ \___/ \__,_|_| |_|\__|\__, |_|    \__,_|_|___/\___|
                              |___/  decentralized escrow
BANNER
  printf '%s' "$C_RESET"

  detect_environment
  check_system_prerequisites
  install_foundry
  setup_node
  install_solidity_deps
  build_contracts
  test_contracts
  setup_env_file
  make_scripts_executable

  print_sudo_commands
  print_next_steps
  printf '\n%s  setup.sh completed successfully.%s\n\n' "$C_GREEN$C_BOLD" "$C_RESET"
}

main "$@"
