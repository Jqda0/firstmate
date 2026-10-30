#!/bin/sh
# install.sh - one-line installer for firstmate.
#
#   curl -fsSL https://raw.githubusercontent.com/kunchenguid/firstmate/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/kunchenguid/firstmate/main/install.sh | sh -s -- --yes
#   sh install.sh [--yes] [--dry-run] [--dir <path>]
#
# Takes a blank machine to a cloned firstmate with its toolchain in place, in
# two layers with one owner each. This script owns the base system layer (git,
# gh, tmux, jq, node, curl, and ps) and the clone. bin/fm-bootstrap.sh owns the
# toolchain layer: after the clone this script runs `bin/fm-bootstrap.sh install
# <tool>...` for whatever bootstrap reports missing, and never carries a
# toolchain install command of its own.
#
# Platforms: macOS with Homebrew, and Linux with apt, dnf, or pacman (WSL counts
# as Linux). Without Homebrew on macOS it prints the official Homebrew command
# and stops. Anywhere else it says what is needed and exits non-zero.
#
# Safety: it prints the plan first (what is missing, what each step runs, which
# steps use sudo) and asks once, on the terminal rather than stdin, because
# stdin is this script when piped. Nothing runs before that answer. It never
# runs sudo silently, never edits a shell startup file (it prints the exact PATH
# line instead), and never discards anything in an existing clone. A re-run on a
# finished install changes nothing and says so.
#
# Options:
#   -y, --yes       accept the plan without asking (also FM_INSTALL_YES=1)
#   -n, --dry-run   print the plan and run nothing
#       --dir PATH  where the clone goes (default: $HOME/firstmate)
#   -h, --help      print this help
#
# Environment:
#   FM_INSTALL_YES=1       same as --yes
#   FM_INSTALL_DIR=PATH    same as --dir
#   FM_INSTALL_REPO=URL    repository to clone (default: the upstream HTTPS URL)
#   FM_INSTALL_TTY=PATH    terminal to ask on and sign in with (default: /dev/tty)
#
# Exit status: 0 when the install is complete or the plan was only previewed;
# non-zero when the platform is unsupported, a step failed, the plan was not
# accepted, or something firstmate needs is still missing at the end.

# shellcheck disable=SC2329 # Plan steps are dispatched by name, and on_exit by trap.
set -e

# Node floor: quota-axi declares engines.node ">=22.19", so an older Node
# installs the tools and then leaves them unusable.
NODE_MIN=22.19.0
# gh floor: bin/fm-pr-state.sh reads `gh pr checks --json name,state,bucket`,
# which gh added in v2.50.0; older gh breaks every pull request status read.
GH_MIN=2.50.0

REPO_URL="${FM_INSTALL_REPO:-https://github.com/kunchenguid/firstmate.git}"
INSTALL_DIR="${FM_INSTALL_DIR:-}"
ASSUME_YES="${FM_INSTALL_YES:-0}"
TTY_DEVICE="${FM_INSTALL_TTY:-/dev/tty}"
DRY_RUN=0

# Tools the base layer owns. bin/fm-bootstrap.sh reports some of these too; the
# installer filters them out of the toolchain list because it installs them.
BASE_TOOLS="node git gh tmux jq curl ps"

STEPS=''
STEP_COUNT=0
CURRENT_STEP=''
WORK=''
TTY_OPEN=0
SUDO=''
PLATFORM=''
PM=''
PM_CMD=''
ARCH=''
ORIG_PATH=''
LOCAL_BIN=''
NODE_LIB=''

say() {
  printf '%s\n' "$*"
}

warn() {
  printf '%s\n' "$*" >&2
}

die() {
  printf 'install.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: sh install.sh [--yes] [--dry-run] [--dir PATH]
       curl -fsSL https://raw.githubusercontent.com/kunchenguid/firstmate/main/install.sh | sh -s -- [options]

Installs firstmate: the base tools it needs (git, gh, tmux, jq, ps, node 22.19
or newer), a clone of the repository, and the toolchain bin/fm-bootstrap.sh lists.
It prints the plan first, asks once on the terminal, and changes nothing before
the answer.

Options:
  -y, --yes       accept the plan without asking (also FM_INSTALL_YES=1)
  -n, --dry-run   print the plan and run nothing
      --dir PATH  where the clone goes (default: $HOME/firstmate)
  -h, --help      print this help

Environment: FM_INSTALL_YES, FM_INSTALL_DIR, FM_INSTALL_REPO, FM_INSTALL_TTY.
EOF
}

on_exit() {
  rc=$?
  if [ -n "$WORK" ]; then
    rm -rf "$WORK"
  fi
  if [ "$rc" -ne 0 ] && [ -n "$CURRENT_STEP" ]; then
    warn ""
    warn "install.sh: stopped during: $CURRENT_STEP"
    warn "Nothing is left half-done that a re-run cannot repair: fix the problem above and run the installer again."
  fi
}

ensure_work() {
  if [ -z "$WORK" ]; then
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/firstmate-install.XXXXXX") || die "cannot create a temporary directory"
  fi
}

# Echo a command before running it, so no step is ever silent about what it does.
run() {
  printf '    $ %s\n' "$*"
  "$@"
}

# Run a command as root: directly when already root, otherwise through sudo,
# which the plan announced before anything started.
as_root() {
  if [ -n "$SUDO" ]; then
    run "$SUDO" "$@"
  else
    run "$@"
  fi
}

have() {
  command -v "$1" >/dev/null 2>&1
}

# Open the terminal once, on fd 3. A regular file works as the terminal too, and
# consecutive reads then advance through it.
have_tty() {
  if [ "$TTY_OPEN" = 1 ]; then
    return 0
  fi
  ( exec 3< "$TTY_DEVICE" ) 2>/dev/null || return 1
  exec 3< "$TTY_DEVICE"
  TTY_OPEN=1
}

ask() {
  printf '%s [y/N] ' "$1"
  answer=''
  IFS= read -r answer <&3 || answer=''
  case "$answer" in
    y|Y|yes|Yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# The leading dotted version in the text on stdin, with any package epoch gone.
clean_version() {
  sed -n 's/^[0-9][0-9]*://; s/^[^0-9]*\([0-9][0-9]*\(\.[0-9][0-9]*\)*\).*/\1/p' | head -n 1
}

# True when dotted version $1 is at least $2; false for an empty $1.
version_ge() {
  vg_have=$1
  vg_need=$2
  [ -n "$vg_have" ] || return 1
  while [ -n "$vg_have" ] || [ -n "$vg_need" ]; do
    vg_h=${vg_have%%.*}
    vg_n=${vg_need%%.*}
    [ -n "$vg_h" ] || vg_h=0
    [ -n "$vg_n" ] || vg_n=0
    [ "$vg_h" -gt "$vg_n" ] && return 0
    [ "$vg_h" -lt "$vg_n" ] && return 1
    case $vg_have in *.*) vg_have=${vg_have#*.} ;; *) vg_have='' ;; esac
    case $vg_need in *.*) vg_need=${vg_need#*.} ;; *) vg_need='' ;; esac
  done
  return 0
}

# Node's Linux builds link libatomic, which minimal images do not ship.
have_libatomic() {
  { ldconfig -p 2>/dev/null || /sbin/ldconfig -p 2>/dev/null; } | grep 'libatomic\.so\.1' >/dev/null 2>&1
}

node_version() {
  node --version 2>/dev/null | clean_version
}

gh_version() {
  gh --version 2>/dev/null | clean_version
}

# The version the platform's package manager would install for package $1, or
# nothing when it cannot say (an apt index that was never refreshed, a name the
# distribution does not carry).
distro_candidate() {
  case "$PM" in
    apt) apt-cache policy "$1" 2>/dev/null | sed -n 's/^ *Candidate: *//p' | head -n 1 | clean_version ;;
    dnf) dnf -q repoquery --latest-limit=1 --queryformat '%{version}\n' "$1" 2>/dev/null | clean_version ;;
    pacman) pacman -Si "$1" 2>/dev/null | sed -n 's/^Version *: *//p' | head -n 1 | clean_version ;;
  esac
}

add_step() {
  STEPS="${STEPS}$1|$2|$3
"
  STEP_COUNT=$((STEP_COUNT + 1))
  if [ "$1" = 1 ]; then
    SUDO_STEPS=$((SUDO_STEPS + 1))
  fi
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -y|--yes) ASSUME_YES=1 ;;
      -n|--dry-run) DRY_RUN=1 ;;
      --dir)
        [ $# -ge 2 ] || die "--dir needs a path"
        INSTALL_DIR=$2
        shift
        ;;
      --dir=*) INSTALL_DIR=${1#--dir=} ;;
      -h|--help)
        usage
        exit 0
        ;;
      *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
  done
  case "$ASSUME_YES" in
    1|true|yes) ASSUME_YES=1 ;;
    *) ASSUME_YES=0 ;;
  esac
}

unsupported() {
  warn "install.sh: this system is not supported: $1"
  warn ""
  warn "firstmate needs git, gh $GH_MIN or newer, tmux, jq, curl, ps, and node $NODE_MIN or newer."
  warn "This installer supports macOS with Homebrew and Linux with apt, dnf, or pacman (WSL counts as Linux)."
  warn "Install those tools with your own package manager, then follow the manual steps in the README:"
  warn "  https://github.com/kunchenguid/firstmate#install-and-launch"
  exit 1
}

detect_platform() {
  uname_s=$(uname -s 2>/dev/null || echo unknown)
  ARCH=$(uname -m 2>/dev/null || echo unknown)
  case "$uname_s" in
    Darwin)
      PLATFORM=macos
      PM=brew
      if ! have brew; then
        warn "install.sh: Homebrew is required on macOS and was not found."
        warn "Install it with the official command, then run this installer again:"
        # shellcheck disable=SC2016 # The command is printed for the user to run, not expanded here.
        warn '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
        exit 1
      fi
      ;;
    Linux)
      PLATFORM=linux
      if have apt-get; then
        PM=apt
        PM_CMD=apt-get
      elif have dnf; then
        PM=dnf
        PM_CMD=dnf
      elif have pacman; then
        PM=pacman
        PM_CMD=pacman
      else
        unsupported "Linux without apt, dnf, or pacman"
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*)
      unsupported "Windows without WSL; run this from a WSL shell instead"
      ;;
    *)
      unsupported "$uname_s"
      ;;
  esac
}

# Names the toolchain bin/fm-bootstrap.sh reports as not installed, one per
# line, with the base layer's own tools left out.
toolchain_missing() {
  bootstrap_detect | sed -n 's/^MISSING: \([^ ]*\) .*/\1/p; s/^PRESENTATION_UNAVAILABLE: \([^ ]*\) .*/\1/p' | while read -r tm_tool; do
    case " $BASE_TOOLS " in
      *" $tm_tool "*) ;;
      *) printf '%s\n' "$tm_tool" ;;
    esac
  done
}

bootstrap_detect() {
  FM_HOME="$INSTALL_DIR" FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip \
    "$INSTALL_DIR/bin/fm-bootstrap.sh" 2>&1 || true
}

need() {
  NEED="${NEED}  - $1
"
}

# Decide what is missing and build the ordered plan. Nothing here changes the
# machine: it only reads versions, package indexes, and the clone.
detect_and_plan() {
  NEED=''
  PKGS=''
  BREW_NEW=''
  BREW_UP=''
  NODE_VIA=''
  SUDO_STEPS=0

  [ -n "$INSTALL_DIR" ] || INSTALL_DIR="$HOME/firstmate"
  case "$INSTALL_DIR" in
    '~') INSTALL_DIR=$HOME ;;
    '~'/*) INSTALL_DIR="$HOME/${INSTALL_DIR#'~/'}" ;;
  esac
  case "$INSTALL_DIR" in
    /*) ;;
    *) INSTALL_DIR="$PWD/$INSTALL_DIR" ;;
  esac
  while [ "${INSTALL_DIR%/}" != "$INSTALL_DIR" ] && [ "$INSTALL_DIR" != / ]; do
    INSTALL_DIR=${INSTALL_DIR%/}
  done

  for dt_tool in git tmux jq; do
    if ! have "$dt_tool"; then
      PKGS="$PKGS $dt_tool"
      BREW_NEW="$BREW_NEW $dt_tool"
      need "$dt_tool: not found"
    fi
  done
  CURL_MISSING=0
  CURL_FIRST=0
  if [ "$PLATFORM" = linux ] && ! have curl; then
    CURL_MISSING=1
    need "curl: not found"
  fi
  # ps comes from procps, which minimal images omit; firstmate's scripts and the
  # no-mistakes daemon both call it.
  if [ "$PLATFORM" = linux ] && ! have ps; then
    if [ "$PM" = apt ]; then
      PKGS="$PKGS procps"
    else
      PKGS="$PKGS procps-ng"
    fi
    need "ps: not found"
  fi

  GH_NEEDED=0
  GH_STATE=''
  if ! have gh; then
    GH_NEEDED=1
    GH_STATE=missing
    need "gh: not found"
  else
    dt_gh=$(gh_version)
    if ! version_ge "$dt_gh" "$GH_MIN"; then
      GH_NEEDED=1
      GH_STATE=old
      need "gh: ${dt_gh:-unreadable version} is older than $GH_MIN, which firstmate's pull-request scripts need"
    fi
  fi

  NODE_NEEDED=0
  NODE_STATE=''
  if ! have node; then
    NODE_NEEDED=1
    NODE_STATE=missing
    need "node: not found (needs $NODE_MIN or newer)"
  else
    dt_node=$(node_version)
    if ! version_ge "$dt_node" "$NODE_MIN"; then
      NODE_NEEDED=1
      NODE_STATE=old
      need "node: ${dt_node:-unreadable version} is older than $NODE_MIN, which quota-axi requires"
    elif ! have npm; then
      NODE_NEEDED=1
      NODE_STATE=missing
      need "npm: not found (it ships with node)"
    fi
  fi

  if [ "$PM" = brew ]; then
    if [ "$GH_NEEDED" = 1 ]; then
      if [ "$GH_STATE" = old ] && brew list --formula gh >/dev/null 2>&1; then
        BREW_UP="$BREW_UP gh"
      else
        BREW_NEW="$BREW_NEW gh"
      fi
    fi
    if [ "$NODE_NEEDED" = 1 ]; then
      NODE_VIA=brew
      if [ "$NODE_STATE" = old ] && brew list --formula node >/dev/null 2>&1; then
        BREW_UP="$BREW_UP node"
      else
        BREW_NEW="$BREW_NEW node"
      fi
    fi
  else
    if [ "$GH_NEEDED" = 1 ]; then
      PKGS="$PKGS gh"
    fi
    if [ "$NODE_NEEDED" = 1 ]; then
      dt_nc=$(distro_candidate nodejs)
      dt_nn=$(distro_candidate npm)
      if version_ge "$dt_nc" "$NODE_MIN" && [ -n "$dt_nn" ]; then
        NODE_VIA=distro
        PKGS="$PKGS nodejs npm"
      else
        NODE_VIA=tarball
        case "$ARCH" in
          x86_64|amd64|aarch64|arm64) ;;
          *) die "no Node.js download is selected for this CPU ($ARCH); install node $NODE_MIN or newer yourself and run this again" ;;
        esac
        for dt_tool in tar gzip; do
          have "$dt_tool" || PKGS="$PKGS $dt_tool"
        done
        if ! have_libatomic; then
          case "$PM" in
            apt) PKGS="$PKGS libatomic1" ;;
            dnf) PKGS="$PKGS libatomic" ;;
          esac
        fi
      fi
    fi
  fi

  if [ "$PM" = brew ]; then
    if [ -n "$BREW_NEW" ]; then
      add_step 0 step_brew_install "Install with Homebrew:$BREW_NEW"
    fi
    if [ -n "$BREW_UP" ]; then
      add_step 0 step_brew_upgrade "Upgrade with Homebrew:$BREW_UP"
    fi
  else
    dt_repo=0
    if [ "$GH_NEEDED" = 1 ] && [ "$PM" != pacman ]; then
      dt_gc=$(distro_candidate gh)
      if ! version_ge "$dt_gc" "$GH_MIN"; then
        dt_repo=1
        if [ -n "$dt_gc" ]; then
          dt_why="$PM offers gh $dt_gc, older than $GH_MIN"
        elif [ "$PM" = apt ]; then
          dt_why="skipped when the refreshed apt index already offers gh $GH_MIN or newer"
        else
          dt_why="$PM offers no usable gh"
        fi
      fi
    fi
    if [ "$CURL_MISSING" = 1 ]; then
      if [ "$dt_repo" = 1 ]; then
        CURL_FIRST=1
      else
        PKGS="$PKGS curl ca-certificates"
      fi
    fi
    if [ "$PM" = apt ] && { [ -n "$PKGS" ] || [ "$dt_repo" = 1 ]; }; then
      add_step 1 step_apt_update "Refresh the package index: apt-get update"
    fi
    if [ "$CURL_FIRST" = 1 ]; then
      add_step 1 step_curl_first "Install curl first, which is needed to fetch GitHub's repository definition: $PM_CMD install curl ca-certificates"
    fi
    if [ "$dt_repo" = 1 ]; then
      add_step 1 step_gh_repo "Add GitHub's official CLI package repository ($dt_why)"
    fi
    if [ -n "$PKGS" ]; then
      case "$PM" in
        apt) dt_cmd="apt-get install -y" ;;
        dnf) dt_cmd="dnf install -y" ;;
        pacman) dt_cmd="pacman -Sy --noconfirm --needed" ;;
      esac
      add_step 1 step_pkg_install "Install with $PM: $dt_cmd$PKGS"
    fi
  fi

  if [ "$NODE_VIA" = tarball ]; then
    add_step 0 step_node_tarball "Install the current Node.js LTS from nodejs.org into $NODE_LIB, verified against its published SHASUMS256.txt, and link it in $LOCAL_BIN (no sudo)"
  fi
  dt_prefix=0
  case "$NODE_VIA" in
    tarball) dt_prefix=1 ;;
    distro) dt_prefix=1 ;;
    brew) ;;
    *)
      dt_pfx=$(npm config get prefix --logs-max=0 2>/dev/null || true)
      if [ -n "$dt_pfx" ] && [ "$dt_pfx" != "$HOME/.local" ]; then
        case "$dt_pfx" in
          "$NODE_LIB"/*) dt_prefix=1 ;;
          *) [ -w "$dt_pfx" ] || dt_prefix=1 ;;
        esac
      fi
      ;;
  esac
  if [ "$dt_prefix" = 1 ]; then
    add_step 0 step_npm_prefix "Point npm's global prefix at $HOME/.local (writes ~/.npmrc) so global installs never need sudo"
  fi

  CLONE_STATE=absent
  CLONE_CURRENT=0
  if [ -e "$INSTALL_DIR" ] || [ -L "$INSTALL_DIR" ]; then
    if [ -f "$INSTALL_DIR/bin/fm-bootstrap.sh" ] && [ -f "$INSTALL_DIR/AGENTS.md" ] \
      && { [ -d "$INSTALL_DIR/.git" ] || [ -f "$INSTALL_DIR/.git" ]; }; then
      CLONE_STATE=clone
    elif [ -d "$INSTALL_DIR" ] && [ -z "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
      CLONE_STATE=empty
    else
      die "$INSTALL_DIR already exists and is not a firstmate clone; choose another place with --dir"
    fi
  fi
  if [ "$CLONE_STATE" = clone ]; then
    if have git; then
      dt_local=$(git -C "$INSTALL_DIR" rev-parse HEAD 2>/dev/null || true)
      dt_remote=$(GIT_TERMINAL_PROMPT=0 git -C "$INSTALL_DIR" ls-remote origin HEAD 2>/dev/null | cut -f1 | head -n 1 || true)
      if [ -n "$dt_local" ] && [ "$dt_local" = "$dt_remote" ]; then
        CLONE_CURRENT=1
      fi
    fi
    if [ "$CLONE_CURRENT" != 1 ]; then
      add_step 0 step_clone "Update the firstmate clone at $INSTALL_DIR with a fast-forward-only pull; if that is not possible it is reported and left as it is"
    fi
  else
    need "firstmate clone: not found at $INSTALL_DIR"
    add_step 0 step_clone "Clone $REPO_URL into $INSTALL_DIR (plain HTTPS, no GitHub sign-in needed)"
  fi

  dt_tc=''
  if [ "$CLONE_STATE" = clone ] && have bash; then
    dt_tc=$(toolchain_missing | tr '\n' ' ')
    dt_tc=${dt_tc% }
  fi
  if [ "$CLONE_STATE" = clone ] && have bash && [ "$CLONE_CURRENT" = 1 ]; then
    if [ -n "$dt_tc" ]; then
      need "toolchain: $dt_tc"
      add_step 0 step_toolchain "Install the toolchain bin/fm-bootstrap.sh reports missing: bin/fm-bootstrap.sh install $dt_tc"
    fi
  else
    add_step 0 step_toolchain "Install the toolchain: once the clone is current, run bin/fm-bootstrap.sh and install each tool it reports missing with bin/fm-bootstrap.sh install <tool>... (each command is printed as it runs)"
  fi

  if [ "$SUDO_STEPS" -gt 0 ] && [ "$(id -u 2>/dev/null)" != 0 ]; then
    have sudo || die "installing system packages needs administrator rights, but sudo was not found; run this as root or install sudo first"
    SUDO=sudo
  fi
}

print_plan() {
  if [ "$PLATFORM" = macos ]; then
    pp_system="macOS (Homebrew)"
  else
    pp_system="Linux ($PM)"
  fi
  say "firstmate installer"
  say "  system: $pp_system"
  say "  folder: $INSTALL_DIR"
  say ""
  if [ -n "$NEED" ]; then
    say "Missing or out of date:"
    printf '%s' "$NEED"
    say ""
  fi
  if [ "$STEP_COUNT" -eq 0 ]; then
    return 0
  fi
  say "Plan ($STEP_COUNT steps, in this order):"
  pp_n=0
  while IFS='|' read -r pp_sudo pp_fn pp_desc; do
    [ -n "$pp_fn" ] || continue
    pp_n=$((pp_n + 1))
    if [ "$pp_sudo" = 1 ]; then
      say "  $pp_n. [sudo] $pp_desc"
    else
      say "  $pp_n. $pp_desc"
    fi
  done <<EOF
$STEPS
EOF
  say ""
  if [ "$SUDO_STEPS" -gt 0 ]; then
    if [ -n "$SUDO" ]; then
      say "Steps marked [sudo] run through sudo, which may ask for your password. No other step uses it."
    else
      say "Steps marked [sudo] run as root, which you already are. No other step needs it."
    fi
  else
    say "No step needs sudo."
  fi
  say "No shell startup file is edited; if your PATH needs a line, it is printed at the end."
  say ""
}

sha256_of() {
  if have sha256sum; then
    sha256sum "$1" | cut -d ' ' -f 1
  elif have shasum; then
    shasum -a 256 "$1" | cut -d ' ' -f 1
  else
    die "neither sha256sum nor shasum was found, so the Node.js download cannot be verified"
  fi
}

# Fail loudly when a tool this run was meant to provide is not usable.
verify_names() {
  hash -r 2>/dev/null || true
  for vn_t in $1; do
    case "$vn_t" in
      gh)
        vn_v=$(gh_version)
        version_ge "$vn_v" "$GH_MIN" || die "gh is ${vn_v:-not found} after the install, but firstmate needs $GH_MIN or newer"
        ;;
      node|nodejs)
        vn_v=$(node_version)
        if [ -z "$vn_v" ] && have node; then
          die "node is installed but does not run: $(node --version 2>&1 | head -n 1)"
        fi
        version_ge "$vn_v" "$NODE_MIN" || die "node is ${vn_v:-not found} after the install, but firstmate needs $NODE_MIN or newer"
        have npm || die "npm is still not on PATH after the install"
        ;;
      procps|procps-ng) have ps || die "ps is still not on PATH after the install" ;;
      npm|ca-certificates|libatomic1|libatomic) ;;
      *) have "$vn_t" || die "$vn_t is still not on PATH after the install" ;;
    esac
  done
}

step_brew_install() {
  # shellcheck disable=SC2086
  run brew install $BREW_NEW
  verify_names "$BREW_NEW"
}

step_brew_upgrade() {
  # shellcheck disable=SC2086
  run brew upgrade $BREW_UP
  verify_names "$BREW_UP"
}

step_apt_update() {
  as_root apt-get update
}

step_curl_first() {
  case "$PM" in
    apt) as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates ;;
    dnf) as_root dnf install -y curl ca-certificates ;;
  esac
  verify_names curl
}

# Runs after the index refresh on apt, so the version it compares is the one the
# install would really get; the plan announced this step as conditional.
step_gh_repo() {
  ensure_work
  gr_c=$(distro_candidate gh)
  if version_ge "$gr_c" "$GH_MIN"; then
    say "    $PM already offers gh $gr_c, which is recent enough; no extra repository is needed."
    return 0
  fi
  case "$PM" in
    apt)
      run curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o "$WORK/githubcli-archive-keyring.gpg"
      as_root mkdir -p -m 755 /etc/apt/keyrings
      as_root install -m 644 "$WORK/githubcli-archive-keyring.gpg" /etc/apt/keyrings/githubcli-archive-keyring.gpg
      gr_arch=$(dpkg --print-architecture)
      printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' "$gr_arch" > "$WORK/github-cli.list"
      as_root install -m 644 "$WORK/github-cli.list" /etc/apt/sources.list.d/github-cli.list
      as_root apt-get update
      ;;
    dnf)
      run curl -fsSL https://cli.github.com/packages/rpm/gh-cli.repo -o "$WORK/gh-cli.repo"
      as_root install -m 644 "$WORK/gh-cli.repo" /etc/yum.repos.d/gh-cli.repo
      ;;
  esac
}

step_pkg_install() {
  # shellcheck disable=SC2086
  case "$PM" in
    apt)
      as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y $PKGS
      ;;
    dnf)
      as_root dnf install -y $PKGS
      if [ "$GH_STATE" = old ]; then
        as_root dnf upgrade -y gh
      fi
      ;;
    pacman)
      as_root pacman -Sy --noconfirm --needed $PKGS
      ;;
  esac
  verify_names "$PKGS"
}

step_node_tarball() {
  ensure_work
  have tar || die "tar is needed to unpack Node.js and was not found"
  case "$ARCH" in
    x86_64|amd64) nt_arch=x64 ;;
    aarch64|arm64) nt_arch=arm64 ;;
    *) die "no Node.js download is selected for this CPU ($ARCH)" ;;
  esac
  nt_base=https://nodejs.org/dist
  run curl -fsSL "$nt_base/index.json" -o "$WORK/index.json"
  nt_ver=$(sed -n 's/^{"version":"\(v[0-9][0-9.]*\)".*"lts":"[^"]*".*/\1/p' "$WORK/index.json" | head -n 1)
  [ -n "$nt_ver" ] || die "could not read the current Node.js LTS version from $nt_base/index.json"
  version_ge "${nt_ver#v}" "$NODE_MIN" || die "the current Node.js LTS ($nt_ver) is older than the $NODE_MIN firstmate needs"
  nt_file="node-$nt_ver-linux-$nt_arch.tar.gz"
  run curl -fsSL "$nt_base/$nt_ver/SHASUMS256.txt" -o "$WORK/SHASUMS256.txt"
  nt_want=$(awk -v f="$nt_file" '$2 == f { print $1; exit }' "$WORK/SHASUMS256.txt")
  [ -n "$nt_want" ] || die "$nt_file is not listed in the published SHASUMS256.txt"
  run curl -fsSL "$nt_base/$nt_ver/$nt_file" -o "$WORK/$nt_file"
  nt_got=$(sha256_of "$WORK/$nt_file")
  [ -n "$nt_got" ] || die "could not compute the SHA-256 of $nt_file"
  if [ "$nt_got" != "$nt_want" ]; then
    die "checksum mismatch for $nt_file (published $nt_want, downloaded $nt_got); nothing was installed"
  fi
  say "    checksum verified: $nt_want"
  nt_dir="$NODE_LIB/node-$nt_ver-linux-$nt_arch"
  mkdir -p "$WORK/unpack" "$NODE_LIB" "$LOCAL_BIN"
  if [ -e "$nt_dir" ]; then
    [ -x "$nt_dir/bin/node" ] || die "$nt_dir exists but holds no node; move it aside and run again"
    say "    $nt_dir is already in place"
  else
    run tar -xzf "$WORK/$nt_file" -C "$WORK/unpack"
    [ -x "$WORK/unpack/node-$nt_ver-linux-$nt_arch/bin/node" ] || die "$nt_file did not unpack to the expected layout"
    run mv "$WORK/unpack/node-$nt_ver-linux-$nt_arch" "$nt_dir"
  fi
  nt_err=$("$nt_dir/bin/node" --version 2>&1) || die "the downloaded node does not run here: $(printf '%s' "$nt_err" | head -n 1)"
  for nt_bin in node npm npx corepack; do
    [ -e "$nt_dir/bin/$nt_bin" ] || continue
    if [ -e "$LOCAL_BIN/$nt_bin" ] && [ ! -L "$LOCAL_BIN/$nt_bin" ]; then
      die "$LOCAL_BIN/$nt_bin exists and is not a link; move it aside and run again"
    fi
    run ln -sf "$nt_dir/bin/$nt_bin" "$LOCAL_BIN/$nt_bin"
  done
  verify_names node
}

# A distro or Homebrew npm installs globals under a prefix this user may not own,
# and a tarball npm would keep them inside its own versioned folder; either way
# the prefix moves to ~/.local, whose bin directory is the one PATH line printed
# at the end.
step_npm_prefix() {
  np_want="$HOME/.local"
  np_cur=$(npm config get prefix 2>/dev/null || true)
  np_set=0
  if [ "$np_cur" = "$np_want" ]; then
    say "    npm's global prefix is already $np_want"
    return 0
  elif [ -z "$np_cur" ] || [ ! -w "$np_cur" ]; then
    np_set=1
  else
    case "$np_cur" in
      "$NODE_LIB"/*) np_set=1 ;;
    esac
  fi
  if [ "$np_set" = 0 ]; then
    say "    npm's global prefix $np_cur is already writable by you; leaving it"
    return 0
  fi
  mkdir -p "$np_want/bin" "$np_want/lib"
  run npm config set prefix "$np_want"
  np_new=$(npm config get prefix 2>/dev/null || true)
  [ "$np_new" = "$np_want" ] || die "npm still reports its global prefix as ${np_new:-nothing} instead of $np_want"
}

step_clone() {
  if [ "$CLONE_STATE" = clone ]; then
    if run git -C "$INSTALL_DIR" pull --ff-only; then
      :
    else
      warn "    could not fast-forward $INSTALL_DIR; it is left exactly as it is and the install continues."
    fi
  else
    mkdir -p "$(dirname "$INSTALL_DIR")"
    run git clone "$REPO_URL" "$INSTALL_DIR"
  fi
  [ -f "$INSTALL_DIR/bin/fm-bootstrap.sh" ] || die "$INSTALL_DIR has no bin/fm-bootstrap.sh after the clone"
}

step_toolchain() {
  mkdir -p "$LOCAL_BIN"
  tc_missing=$(toolchain_missing | tr '\n' ' ')
  tc_missing=${tc_missing% }
  if [ -z "$tc_missing" ]; then
    say "    bin/fm-bootstrap.sh reports nothing missing"
    return 0
  fi
  say "    bin/fm-bootstrap.sh reports missing: $tc_missing"
  # A subshell keeps FM_HOME from leaking into the rest of the install.
  # shellcheck disable=SC2086
  (FM_HOME="$INSTALL_DIR"; export FM_HOME; run "$INSTALL_DIR/bin/fm-bootstrap.sh" install $tc_missing)
}

run_plan() {
  rp_n=0
  while IFS='|' read -r _ rp_fn rp_desc; do
    [ -n "$rp_fn" ] || continue
    rp_n=$((rp_n + 1))
    say ""
    say "==> [$rp_n/$STEP_COUNT] $rp_desc"
    CURRENT_STEP=$rp_desc
    "$rp_fn" </dev/null
    CURRENT_STEP=''
    hash -r 2>/dev/null || true
  done <<EOF
$STEPS
EOF
}

offer_gh_login() {
  have gh || return 0
  if gh auth status >/dev/null 2>&1; then
    say "GitHub CLI: signed in."
    return 0
  fi
  say "GitHub CLI: not signed in. firstmate works with your own GitHub login."
  if have_tty; then
    if ask "Run 'gh auth login' now?"; then
      gh auth login <&3 || warn "gh auth login did not finish; run it yourself with: gh auth login"
    else
      say "Run it when you are ready: gh auth login"
    fi
  else
    say "Run it from a terminal: gh auth login"
  fi
}

# The end-of-run check: whatever bin/fm-bootstrap.sh still reports, plus the two
# things it cannot see. ps must exist, and the no-mistakes daemon must be running,
# because the daemon needs ps to start where there is no service manager.
report_state() {
  rs_bad=0
  rs_out=$(bootstrap_detect)
  if [ -n "$rs_out" ]; then
    say "Still needs attention (reported by bin/fm-bootstrap.sh):"
    printf '%s\n' "$rs_out" | sed 's/^/  /'
    rs_bad=1
  fi
  if have ps; then
    say "ps: $(command -v ps)"
  else
    say "ps was not found; firstmate's scripts and the no-mistakes daemon need it (the procps package)."
    rs_bad=1
  fi
  if have no-mistakes; then
    # The variable keeps this read from refreshing no-mistakes' update cache, so
    # re-running a finished install leaves every file as it was.
    rs_daemon=$(NO_MISTAKES_NO_UPDATE_CHECK=1 no-mistakes daemon status 2>&1 || true)
    case "$rs_daemon" in
      *"not running"*)
        say "The no-mistakes daemon is not running. Start it with: no-mistakes daemon start"
        rs_bad=1
        ;;
      *"daemon running"*)
        say "no-mistakes daemon: running"
        ;;
      *)
        say "no-mistakes daemon status gave no clear answer: $(printf '%s' "$rs_daemon" | head -n 1)"
        rs_bad=1
        ;;
    esac
  fi
  if [ "$rs_bad" = 0 ]; then
    say "Everything firstmate needs is installed."
  fi
  return "$rs_bad"
}

path_advice() {
  pa_advise=0
  case ":$ORIG_PATH:" in
    *":$LOCAL_BIN:"*)
      pa_saved=$PATH
      PATH=$ORIG_PATH
      pa_v=$(node_version)
      PATH=$pa_saved
      version_ge "$pa_v" "$NODE_MIN" || pa_advise=1
      ;;
    *)
      if [ -d "$LOCAL_BIN" ] && [ -n "$(ls -A "$LOCAL_BIN" 2>/dev/null)" ]; then
        pa_advise=1
      fi
      ;;
  esac
  [ "$pa_advise" = 1 ] || return 0
  say ""
  say "Your PATH needs $LOCAL_BIN first, where node and the firstmate tools were installed."
  say "Add this line to your shell startup file (for example ~/.profile, ~/.bashrc, or ~/.zshrc), then open a new terminal:"
  # shellcheck disable=SC2016 # The line is printed for the user's startup file, not expanded here.
  say '  export PATH="$HOME/.local/bin:$PATH"'
  say "This installer did not edit any shell startup file."
}

# One launch line per supported agent that is already installed. The commands
# are the ones the README's "Install and launch" section gives.
add_hint() {
  have "$1" || return 0
  HINTS="${HINTS}$(printf '  %-26s # %s' "$2" "$3")
"
}

next_steps() {
  HINTS=''
  add_hint claude claude "Claude Code"
  add_hint grok "grok --trust" "Grok"
  add_hint pi pi "Pi"
  add_hint omp omp "Oh My Pi"
  add_hint codex codex "Codex"
  if have opencode; then
    ns_v=$(opencode --version 2>/dev/null | clean_version)
    ns_major=${ns_v%%.*}
    case "$ns_major" in
      ''|*[!0-9]*) add_hint opencode opencode "OpenCode" ;;
      *)
        if [ "$ns_major" -ge 2 ]; then
          add_hint opencode "opencode --standalone" "OpenCode 2 or newer"
        else
          add_hint opencode opencode "OpenCode"
        fi
        ;;
    esac
  fi
  add_hint cursor-agent "cursor-agent --trust" "Cursor Agent"
  say ""
  if [ -z "$HINTS" ]; then
    say "Next: install one of the agents firstmate runs inside, with your own account:"
    say "  Claude Code (claude), Grok (grok), Pi (pi), Oh My Pi (omp), Codex (codex), OpenCode (opencode), or Cursor Agent (cursor-agent)."
    say "Then launch it from $INSTALL_DIR as the README describes:"
    say "  https://github.com/kunchenguid/firstmate#install-and-launch"
    return 0
  fi
  case "$INSTALL_DIR" in
    *[!A-Za-z0-9._/@+-]*) ns_dir="\"$INSTALL_DIR\"" ;;
    *) ns_dir=$INSTALL_DIR ;;
  esac
  say "Next: start the first mate from the firstmate directory with the agent you already have:"
  say "  cd $ns_dir"
  printf '%s' "$HINTS"
}

finish() {
  say ""
  offer_gh_login
  say ""
  fi_rc=0
  report_state || fi_rc=1
  path_advice
  next_steps
  exit "$fi_rc"
}

main() {
  parse_args "$@"
  [ -n "${HOME:-}" ] || die "HOME is not set"
  trap on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  # A prompt for credentials would hang a piped install; the clone is public.
  GIT_TERMINAL_PROMPT=0
  export GIT_TERMINAL_PROMPT
  ORIG_PATH=$PATH
  LOCAL_BIN="$HOME/.local/bin"
  NODE_LIB="$HOME/.local/lib/nodejs"
  detect_platform
  PATH="$LOCAL_BIN:$PATH"
  export PATH
  detect_and_plan
  print_plan
  if [ "$STEP_COUNT" -eq 0 ]; then
    say "Nothing to install: everything is already in place, so nothing was changed."
    if [ "$DRY_RUN" = 1 ]; then
      exit 0
    fi
    finish
  fi
  if [ "$DRY_RUN" = 1 ]; then
    say "Dry run: nothing was changed."
    exit 0
  fi
  if [ "$ASSUME_YES" != 1 ]; then
    if ! have_tty; then
      say "There is no terminal to ask on and --yes was not given, so nothing was changed."
      say "Run this from a terminal, or accept the plan with: curl -fsSL https://raw.githubusercontent.com/kunchenguid/firstmate/main/install.sh | sh -s -- --yes"
      exit 1
    fi
    if ! ask "Run these steps now?"; then
      say "Nothing was changed."
      exit 1
    fi
  fi
  run_plan
  finish
}

main "$@"
