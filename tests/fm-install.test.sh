#!/usr/bin/env bash
# Behavior tests for install.sh, the one-line installer.
#
# Every case runs the real install.sh as a subprocess inside a sandbox: a
# throwaway HOME, a PATH made only of stub package managers, a stub curl serving
# fixture downloads, and a fake upstream repository whose bin/fm-bootstrap.sh is
# a stub that reports and "installs" toolchain tools. The stubs record each call
# in one log, and a stub install drops a stub tool onto the sandbox PATH, so a
# finished install is observable the way a real one is: the tools resolve and a
# second run has nothing to do.
#
# Guarantees under test: --dry-run and a missing terminal change nothing; --yes
# runs the plan in order and also when the script arrives on stdin; a finished
# install is a no-op; an unsupported platform refuses; sudo is announced in the
# plan; the toolchain is delegated to bin/fm-bootstrap.sh and never reimplemented;
# the Node and gh floors, the checksum check, the clone and its fast-forward-only
# update, the sign-in offer, the PATH advice, and the next-step launch commands.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALLER="$ROOT/install.sh"
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-install-tests)
REAL_PATH=$PATH
REAL_GIT=$(command -v git)

# --- shared fixtures ----------------------------------------------------------

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

# One stub for every tool a sandbox can have installed. Its version comes from
# $FM_TEST_W/ver-<name>, so a case sets the installed version by writing a file.
write_tool_template() {
  cat > "$1" <<'SH'
#!/bin/sh
name=$(basename "$0")
ver=$(cat "$FM_TEST_W/ver-$name" 2>/dev/null || echo 1.0.0)
case "$name:${1:-}" in
  node:--version) echo "v$ver"; exit 0 ;;
  gh:--version)
    echo "gh version $ver (2026-01-01)"
    echo "https://github.com/cli/cli/releases/tag/v$ver"
    exit 0
    ;;
  gh:auth)
    case "${2:-}" in
      status) [ -e "$FM_TEST_W/gh-authed" ]; exit $? ;;
      login)
        echo "gh auth login" >> "$FM_TEST_LOG"
        touch "$FM_TEST_W/gh-authed"
        exit 0
        ;;
    esac
    exit 0
    ;;
  no-mistakes:daemon)
    # The real tool rewrites its update cache on a status read unless told not to.
    [ "${NO_MISTAKES_NO_UPDATE_CHECK:-}" = 1 ] || date >> "$HOME/.no-mistakes-update-cache"
    if [ "${FAKE_DAEMON_DOWN:-0}" = 1 ]; then
      echo "  ○ daemon not running"
    else
      echo "  ● daemon running (pid 4242)"
    fi
    exit 0
    ;;
  npm:config)
    case "${2:-} ${3:-}" in
      "get prefix")
        if [ -f "$HOME/.npmrc" ] && grep '^prefix=' "$HOME/.npmrc" >/dev/null 2>&1; then
          sed -n 's/^prefix=//p' "$HOME/.npmrc" | tail -n 1
        elif [ -n "${FAKE_NPM_DEFAULT_PREFIX:-}" ]; then
          echo "$FAKE_NPM_DEFAULT_PREFIX"
        else
          self=$0
          while [ -L "$self" ]; do
            link=$(readlink "$self")
            case "$link" in /*) self=$link ;; *) self=$(dirname "$self")/$link ;; esac
          done
          (cd "$(dirname "$self")/.." && pwd -P)
        fi
        exit 0
        ;;
      "set prefix")
        echo "npm config set prefix $4" >> "$FM_TEST_LOG"
        echo "prefix=$4" >> "$HOME/.npmrc"
        exit 0
        ;;
    esac
    exit 0
    ;;
  *:--version|*:-V|*:version) echo "$name $ver"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$1"
}

# A fake upstream whose bin/fm-bootstrap.sh stands in for the real toolchain
# owner: detect mode lists the tools in FAKE_BOOTSTRAP_TOOLS that are absent
# from PATH, and install mode records the call and drops a stub for each tool.
build_upstream() {
  local work=$TMP_ROOT/upstream-src
  mkdir -p "$work/bin"
  printf '# fake firstmate\n' > "$work/AGENTS.md"
  cat > "$work/bin/fm-bootstrap.sh" <<'SH'
#!/bin/sh
echo "bootstrap $* [DETECT_ONLY=${FM_BOOTSTRAP_DETECT_ONLY:-} NETWORK=${FM_BOOTSTRAP_NETWORK:-} HOME_DIR=${FM_HOME:-}]" >> "$FM_TEST_LOG"
if [ "${1:-}" = install ]; then
  shift
  for t in "$@"; do
    echo "installing $t: stub"
    cp "$FM_TEST_W/tool-template" "$FM_TEST_W/inst/$t"
  done
  exit 0
fi
for t in ${FAKE_BOOTSTRAP_TOOLS-treehouse no-mistakes}; do
  command -v "$t" >/dev/null 2>&1 && continue
  case "$t" in
    lavish-axi) echo "PRESENTATION_UNAVAILABLE: $t (requires >=0.1.77; install: npm install -g $t) - nonvisual work may proceed" ;;
    *) echo "MISSING: $t (install: stub command for $t)" ;;
  esac
done
[ -z "${FAKE_BOOTSTRAP_STUCK:-}" ] || echo "$FAKE_BOOTSTRAP_STUCK"
exit 0
SH
  chmod +x "$work/bin/fm-bootstrap.sh"
  git -C "$work" init -q -b main
  git -C "$work" add -A
  git -C "$work" -c user.name=fmtest -c user.email=fmtest@example.com commit -qm "fake upstream"
  git clone -q --bare "$work" "$TMP_ROOT/upstream.git"
}

# The nodejs.org downloads the stub curl serves: a release index, a tarball with
# stub node and npm, and the published checksum list.
build_node_fixtures() {
  local dir=$TMP_ROOT/nodefix pack=$TMP_ROOT/nodefix/pack/node-v26.13.0-linux-x64
  mkdir -p "$pack/bin"
  printf '#!/bin/sh\necho v26.13.0\n' > "$pack/bin/node"
  write_tool_template "$pack/bin/npm"
  printf '#!/bin/sh\nexit 0\n' > "$pack/bin/npx"
  chmod +x "$pack/bin/node" "$pack/bin/npx"
  tar -czf "$dir/node-v26.13.0-linux-x64.tar.gz" -C "$dir/pack" node-v26.13.0-linux-x64
  printf '%s  node-v26.13.0-linux-x64.tar.gz\n' "$(sha256_of "$dir/node-v26.13.0-linux-x64.tar.gz")" > "$dir/SHASUMS256.txt"
  cat > "$dir/index.json" <<'EOF'
[
{"version":"v27.0.0-alpha.0.0.0","date":"2026-10-29","files":["linux-x64"],"lts":false,"security":false},
{"version":"v26.13.0","date":"2026-10-28","files":["linux-x64"],"lts":"Lithium","security":false},
{"version":"v24.22.2","date":"2026-10-27","files":["linux-x64"],"lts":"Krypton","security":false}
]
EOF
}

# --- one sandbox per case -----------------------------------------------------

# w_new <name>: fresh sandbox with no tools installed; sets W and RUN_ENV.
w_new() {
  W=$TMP_ROOT/$1
  mkdir -p "$W/home" "$W/stubs" "$W/inst" "$W/basic" "$W/tmp"
  : > "$W/log"
  RUN_ENV=()
  VIA=direct
  INTERP=/bin/sh
  write_tool_template "$W/tool-template"
  local u path
  for u in awk basename bash cat chmod cp cut date dirname env grep gzip head install ln ls mkdir mktemp \
    mv readlink rm sed sha256sum sh shasum sleep sort tail tar tee touch tr wc; do
    path=$(PATH=$REAL_PATH command -v "$u" 2>/dev/null) || continue
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$path" > "$W/basic/$u"
    chmod +x "$W/basic/$u"
  done
  write_stubs
}

# w_tool <name> [version]: put a stub tool on the sandbox PATH.
w_tool() {
  if [ "$1" = git ]; then
    ln -sf "$REAL_GIT" "$W/inst/git"
    return 0
  fi
  if [ "$1" = curl ]; then
    cp "$W/curl-stub" "$W/inst/curl"
    return 0
  fi
  cp "$W/tool-template" "$W/inst/$1"
  printf '%s\n' "${2:-1.0.0}" > "$W/ver-$1"
}

# w_base: every base tool already installed at a good version.
w_base() {
  w_tool git
  w_tool tmux
  w_tool jq
  w_tool curl
  w_tool ps
  w_tool gh "${1:-2.103.0}"
  w_tool node "${2:-26.13.0}"
  w_tool npm 11.20.0
}

w_env() {
  RUN_ENV+=("$@")
}

write_stubs() {
  local s=$W/stubs
  cat > "$s/pkglib.sh" <<'SH'
# Shared by the package-manager stubs: "install" a package by dropping a stub
# tool onto the sandbox PATH.
fake_install() {
  case "$1" in
    git) ln -sf "$FM_TEST_REAL_GIT" "$FM_TEST_W/inst/git" ;;
    curl) cp "$FM_TEST_W/curl-stub" "$FM_TEST_W/inst/curl" ;;
    tmux|jq|tar|gzip) cp "$FM_TEST_W/tool-template" "$FM_TEST_W/inst/$1" ;;
    procps|procps-ng) cp "$FM_TEST_W/tool-template" "$FM_TEST_W/inst/ps" ;;
    gh)
      cp "$FM_TEST_W/tool-template" "$FM_TEST_W/inst/gh"
      echo "${FAKE_GH_INSTALL_VERSION:-2.103.0}" > "$FM_TEST_W/ver-gh"
      ;;
    node|nodejs)
      cp "$FM_TEST_W/tool-template" "$FM_TEST_W/inst/node"
      echo "${FAKE_NODE_INSTALL_VERSION:-26.13.0}" > "$FM_TEST_W/ver-node"
      cp "$FM_TEST_W/tool-template" "$FM_TEST_W/inst/npm"
      ;;
  esac
}
candidate() {
  var=$(printf 'FAKE_CAND_%s' "$1" | tr '-' '_')
  eval "val=\${$var:-}"
  if [ "$1" = gh ] && grep 'github-cli.list' "$FM_TEST_LOG" >/dev/null 2>&1 && [ -n "${FAKE_CAND_gh_AFTER:-}" ]; then
    val=$FAKE_CAND_gh_AFTER
  fi
  printf '%s' "$val"
}
SH
  cat > "$s/uname" <<'SH'
#!/bin/sh
case "${1:-}" in
  -m) echo "${FAKE_UNAME_M:-x86_64}" ;;
  *) echo "${FAKE_UNAME_S:-Linux}" ;;
esac
SH
  cat > "$s/id" <<'SH'
#!/bin/sh
echo "${FAKE_UID:-1000}"
SH
  cat > "$s/sudo" <<'SH'
#!/bin/sh
echo "sudo $*" >> "$FM_TEST_LOG"
case "${1:-}" in
  apt-get|dnf|pacman|env) exec "$@" ;;
  *) exit 0 ;;
esac
SH
  cat > "$s/ldconfig" <<'SH'
#!/bin/sh
[ "${FAKE_LIBATOMIC:-0}" = 1 ] && echo "libatomic.so.1 (libc6) => /lib/libatomic.so.1"
exit 0
SH
  cat > "$s/dpkg" <<'SH'
#!/bin/sh
echo amd64
SH
  cat > "$s/apt-get" <<'SH'
#!/bin/sh
. "$FM_TEST_W/stubs/pkglib.sh"
echo "apt-get $*" >> "$FM_TEST_LOG"
case "${1:-}" in
  install)
    shift
    for a in "$@"; do
      case "$a" in -*) ;; *) fake_install "$a" ;; esac
    done
    ;;
esac
exit 0
SH
  cat > "$s/apt-cache" <<'SH'
#!/bin/sh
. "$FM_TEST_W/stubs/pkglib.sh"
pkg=$2
c=$(candidate "$pkg")
echo "$pkg:"
echo "  Installed: (none)"
if [ -n "$c" ]; then echo "  Candidate: 1:$c-1ubuntu1"; else echo "  Candidate: (none)"; fi
SH
  cat > "$s/dnf" <<'SH'
#!/bin/sh
. "$FM_TEST_W/stubs/pkglib.sh"
sub=''
for a in "$@"; do
  case "$a" in -*) ;; *) sub=$a; break ;; esac
done
case "$sub" in
  repoquery)
    eval "last=\${$#}"
    c=$(candidate "$last")
    [ -z "$c" ] || echo "$c"
    ;;
  install|upgrade)
    echo "dnf $*" >> "$FM_TEST_LOG"
    shift
    for a in "$@"; do
      case "$a" in -*) ;; *) fake_install "$a" ;; esac
    done
    ;;
esac
exit 0
SH
  cat > "$s/pacman" <<'SH'
#!/bin/sh
. "$FM_TEST_W/stubs/pkglib.sh"
case "${1:-}" in
  -Si)
    c=$(candidate "$2")
    [ -n "$c" ] || exit 1
    echo "Name            : $2"
    echo "Version         : $c-1"
    ;;
  -Sy)
    echo "pacman $*" >> "$FM_TEST_LOG"
    shift
    for a in "$@"; do
      case "$a" in -*) ;; *) fake_install "$a" ;; esac
    done
    ;;
esac
exit 0
SH
  cat > "$s/brew" <<'SH'
#!/bin/sh
. "$FM_TEST_W/stubs/pkglib.sh"
case "${1:-}" in
  list)
    case " ${FAKE_BREW_MANAGED:-} " in *" $3 "*) exit 0 ;; esac
    exit 1
    ;;
  install|upgrade)
    echo "brew $*" >> "$FM_TEST_LOG"
    cmd=$1
    shift
    for a in "$@"; do fake_install "$a"; done
    ;;
esac
exit 0
SH
  cat > "$s/curl" <<'SH'
#!/bin/sh
echo "curl $*" >> "$FM_TEST_LOG"
out=''
url=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift ;;
    -*) ;;
    *) url=$1 ;;
  esac
  shift
done
src=''
case "$url" in
  https://nodejs.org/dist/index.json) src=$FM_TEST_NODEFIX/index.json ;;
  https://nodejs.org/dist/*/SHASUMS256.txt) src=${FAKE_SHASUMS:-$FM_TEST_NODEFIX/SHASUMS256.txt} ;;
  https://nodejs.org/dist/*/node-*-linux-*.tar.gz) src=$FM_TEST_NODEFIX/node-v26.13.0-linux-x64.tar.gz ;;
  https://cli.github.com/*) src=$FM_TEST_W/tool-template ;;
  *) exit 22 ;;
esac
[ -n "$out" ] || { cat "$src"; exit 0; }
cp "$src" "$out"
SH
  chmod +x "$s"/*
  chmod -x "$s/pkglib.sh"
  mv "$s/curl" "$W/curl-stub"
}

# w_pm <apt|dnf|pacman|brew>...: only the named package managers exist.
w_pm() {
  local want=" $* "
  case "$want" in *" apt "*) ;; *) rm -f "$W/stubs/apt-get" "$W/stubs/apt-cache" "$W/stubs/dpkg" ;; esac
  case "$want" in *" dnf "*) ;; *) rm -f "$W/stubs/dnf" ;; esac
  case "$want" in *" pacman "*) ;; *) rm -f "$W/stubs/pacman" ;; esac
  case "$want" in *" brew "*) ;; *) rm -f "$W/stubs/brew" ;; esac
}

# run_installer [args...]: sets OUT (stdout and stderr together) and RC.
run_installer() {
  local pathv="$W/stubs:$W/inst:$W/basic"
  local envs=(-u FM_HOME -u FM_INSTALL_YES -u FM_INSTALL_DIR -u FM_INSTALL_REPO -u FM_INSTALL_TTY -u GIT_TERMINAL_PROMPT
    "PATH=$pathv" "HOME=$W/home" "TMPDIR=$W/tmp" "FM_TEST_W=$W" "FM_TEST_LOG=$W/log"
    "FM_TEST_NODEFIX=$TMP_ROOT/nodefix" "FM_TEST_REAL_GIT=$REAL_GIT"
    "FM_INSTALL_REPO=$TMP_ROOT/upstream.git" "FM_INSTALL_TTY=$W/no-tty")
  if [ "${#RUN_ENV[@]}" -gt 0 ]; then
    envs+=("${RUN_ENV[@]}")
  fi
  if [ "$VIA" = pipe ]; then
    OUT=$(cat "$INSTALLER" | env "${envs[@]}" "$INTERP" -s -- "$@" 2>&1)
  else
    OUT=$(env "${envs[@]}" "$INTERP" "$INSTALLER" "$@" 2>&1 < /dev/null)
  fi
  RC=$?
}

# --- assertions ---------------------------------------------------------------

# assert_order <file> <fixed-string>...: each string appears, in this order.
assert_order() {
  local file=$1 prev=0 pattern n
  shift
  for pattern in "$@"; do
    n=$(grep -n -F -- "$pattern" "$file" | awk -F: -v min="$prev" '$1 > min { print $1; exit }')
    [ -n "$n" ] || fail "expected '$pattern' after line $prev in $(basename "$file"):"$'\n'"$(cat "$file")"
    prev=$n
  done
}

# Mutating calls a sandbox records: anything that would change the machine.
mutating_calls() {
  grep -E '^(sudo |apt-get (install|update)|dnf (install|upgrade)|pacman -Sy|brew (install|upgrade)|curl |npm config set|bootstrap install|gh auth login)' "$W/log" || true
}

home_listing() {
  (cd "$W/home" && find . -print | LC_ALL=C sort)
}

# A snapshot of everything a run could have changed in the sandbox.
world_snapshot() {
  {
    (cd "$W/home" && find . -type f -exec cksum {} + 2>/dev/null | LC_ALL=C sort)
    (cd "$W/home" && find . | LC_ALL=C sort)
    (cd "$W/inst" && find . \( -type l -o -type f \) | LC_ALL=C sort)
    mutating_calls
  }
}

# The standard Ubuntu-like sandbox: apt, curl present, nothing else, an old gh
# in apt that the official repository replaces, and no apt node.
w_ubuntu() {
  w_new "$1"
  w_pm apt
  w_tool curl
  w_tool git
  w_tool ps
  w_env FAKE_CAND_gh=2.45.0 FAKE_CAND_gh_AFTER=2.103.0 FAKE_BOOTSTRAP_TOOLS="treehouse no-mistakes"
}

# install_fully <name>: the standard sandbox taken through a complete install,
# with the script arriving on stdin the way `curl | sh` delivers it.
install_fully() {
  w_ubuntu "$1"
  VIA=pipe
  run_installer --yes
  expect_code 0 "$RC" "the complete install exits 0:"$'\n'"$OUT"
  VIA=direct
}

# --- the plan and the consent gate ---------------------------------------------

test_dry_run_runs_nothing() {
  w_ubuntu dry-run
  run_installer --dry-run
  expect_code 0 "$RC" "dry-run exits 0"
  assert_contains "$OUT" "Plan (7 steps, in this order):" "dry-run prints the whole plan"
  assert_contains "$OUT" "[sudo] Refresh the package index: apt-get update" "the plan names the first command"
  assert_contains "$OUT" "[sudo] Install with apt: apt-get install -y tmux jq gh libatomic1" "the plan names the package command"
  assert_contains "$OUT" "Clone $TMP_ROOT/upstream.git into $W/home/firstmate" "the plan names the clone"
  assert_contains "$OUT" "Dry run: nothing was changed." "dry-run says it changed nothing"
  assert_equals "" "$(mutating_calls)" "dry-run ran nothing that changes the machine"
  assert_equals "." "$(home_listing)" "dry-run left the home directory empty"
  RUN_ENV=()
  w_env FM_INSTALL_YES=1
  run_installer --dry-run
  expect_code 0 "$RC" "dry-run beats --yes"
  assert_equals "" "$(mutating_calls)" "dry-run beats FM_INSTALL_YES"
  pass "--dry-run prints the plan and runs nothing"
}

test_no_terminal_without_yes_changes_nothing() {
  w_ubuntu no-terminal
  run_installer
  expect_code 1 "$RC" "no terminal and no --yes exits non-zero"
  assert_contains "$OUT" "Plan (7 steps, in this order):" "the plan is still printed"
  assert_contains "$OUT" "There is no terminal to ask on and --yes was not given, so nothing was changed." "it says why nothing happened"
  assert_equals "" "$(mutating_calls)" "nothing that changes the machine ran"
  assert_equals "." "$(home_listing)" "the home directory is untouched"
  pass "no terminal and no --yes prints the plan and changes nothing"
}

test_consent_prompt_reads_the_terminal() {
  w_ubuntu consent-no
  printf 'n\n' > "$W/tty"
  w_env "FM_INSTALL_TTY=$W/tty"
  run_installer
  expect_code 1 "$RC" "declining exits non-zero"
  assert_contains "$OUT" "Run these steps now? [y/N]" "it asks once"
  assert_contains "$OUT" "Nothing was changed." "declining changes nothing"
  assert_equals "" "$(mutating_calls)" "a declined plan ran nothing"
  w_ubuntu consent-empty
  printf '\n' > "$W/tty"
  w_env "FM_INSTALL_TTY=$W/tty"
  run_installer
  expect_code 1 "$RC" "an empty answer is a no"
  assert_equals "" "$(mutating_calls)" "an empty answer ran nothing"
  w_ubuntu consent-yes
  printf 'y\nn\n' > "$W/tty"
  w_env "FM_INSTALL_TTY=$W/tty"
  run_installer
  expect_code 0 "$RC" "accepting installs:"$'\n'"$OUT"
  assert_contains "$OUT" "Everything firstmate needs is installed." "an accepted plan completes"
  assert_contains "$OUT" "Run 'gh auth login' now? [y/N]" "the sign-in offer is a second, separate question"
  assert_no_grep "gh auth login" "$W/log" "answering no to the sign-in offer never signs in"
  pass "the plan is accepted or declined on the terminal, not on stdin"
}

test_yes_runs_the_plan_in_order() {
  w_ubuntu yes-order
  VIA=pipe
  run_installer --yes
  expect_code 0 "$RC" "the install exits 0:"$'\n'"$OUT"
  assert_order "$W/log" \
    "sudo apt-get update" \
    "curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg" \
    "sudo mkdir -p -m 755 /etc/apt/keyrings" \
    "sudo install -m 644" \
    "github-cli.list" \
    "sudo apt-get update" \
    "sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y tmux jq gh libatomic1" \
    "curl -fsSL https://nodejs.org/dist/index.json" \
    "curl -fsSL https://nodejs.org/dist/v26.13.0/SHASUMS256.txt" \
    "curl -fsSL https://nodejs.org/dist/v26.13.0/node-v26.13.0-linux-x64.tar.gz" \
    "npm config set prefix $W/home/.local" \
    "bootstrap install treehouse no-mistakes" \
    "DETECT_ONLY=1 NETWORK=skip"
  [ -L "$W/home/.local/bin/node" ] || fail "node is linked into ~/.local/bin"
  [ -f "$W/home/firstmate/bin/fm-bootstrap.sh" ] || fail "the clone exists"
  assert_grep "prefix=$W/home/.local" "$W/home/.npmrc" "npm's global prefix points at the home directory"
  [ -e "$W/inst/treehouse" ] && [ -e "$W/inst/no-mistakes" ] || fail "the toolchain tools resolve on PATH"
  assert_contains "$OUT" "Everything firstmate needs is installed." "the final detect-only check reports a complete install"
  assert_contains "$OUT" "Run it from a terminal: gh auth login" "with no terminal the sign-in command is printed, not run"
  assert_no_grep "gh auth login" "$W/log" "the installer never fakes a sign-in"
  pass "--yes runs the plan in order, with the script arriving on stdin"
}

test_finished_install_is_a_noop() {
  install_fully noop
  local before after
  before=$(world_snapshot)
  run_installer --yes
  expect_code 0 "$RC" "a second run exits 0"
  assert_contains "$OUT" "Nothing to install: everything is already in place, so nothing was changed." "it says there is nothing to do"
  after=$(world_snapshot)
  assert_equals "$before" "$after" "a second run changed nothing in the sandbox"
  run_installer --dry-run
  assert_contains "$OUT" "Nothing to install" "a dry run of a finished install agrees"
  pass "re-running a finished install changes nothing and says so"
}

test_unsupported_platforms_refuse() {
  w_new freebsd
  w_pm apt
  w_env FAKE_UNAME_S=FreeBSD
  run_installer --yes
  expect_code 1 "$RC" "an unsupported OS exits non-zero"
  assert_contains "$OUT" "this system is not supported: FreeBSD" "it names the system"
  assert_contains "$OUT" "macOS with Homebrew and Linux with apt, dnf, or pacman" "it says what is supported"
  assert_contains "$OUT" "git, gh 2.50.0 or newer, tmux, jq, curl, ps, and node 22.19.0 or newer" "it says what firstmate needs"
  assert_equals "" "$(mutating_calls)" "an unsupported platform ran nothing"
  w_new windows
  w_env FAKE_UNAME_S=MINGW64_NT-10.0
  run_installer --yes
  expect_code 1 "$RC" "Windows exits non-zero"
  assert_contains "$OUT" "Windows without WSL" "it points Windows users at WSL"
  w_new bare-linux
  w_pm
  run_installer --yes
  expect_code 1 "$RC" "Linux without a supported package manager exits non-zero"
  assert_contains "$OUT" "Linux without apt, dnf, or pacman" "it names the missing package manager"
  assert_equals "." "$(home_listing)" "nothing was created"
  w_new mac-no-brew
  w_pm
  w_env FAKE_UNAME_S=Darwin
  run_installer --yes
  expect_code 1 "$RC" "macOS without Homebrew exits non-zero"
  assert_contains "$OUT" "Homebrew is required on macOS and was not found." "it names Homebrew"
  # shellcheck disable=SC2016 # The command is matched literally, not expanded.
  assert_contains "$OUT" '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' "it prints the one official Homebrew command"
  assert_equals "" "$(mutating_calls)" "it did not install Homebrew"
  pass "an unsupported platform refuses with a clear message"
}

test_sudo_is_announced_before_it_runs() {
  w_ubuntu sudo-plan
  run_installer --dry-run
  assert_contains "$OUT" "Steps marked [sudo] run through sudo, which may ask for your password. No other step uses it." "the plan announces sudo"
  assert_contains "$OUT" "[sudo] Add GitHub's official CLI package repository (apt offers gh 2.45.0, older than 2.50.0)" "the repository step is marked and explained"
  assert_not_contains "$(printf '%s\n' "$OUT" | grep 'Install the current Node.js LTS')" "[sudo]" "the Node.js step needs no sudo"
  assert_not_contains "$(printf '%s\n' "$OUT" | grep 'Clone ')" "[sudo]" "the clone needs no sudo"
  w_ubuntu sudo-missing
  rm -f "$W/stubs/sudo"
  run_installer --yes
  expect_code 1 "$RC" "no sudo for a non-root user exits non-zero"
  assert_contains "$OUT" "needs administrator rights, but sudo was not found" "it says sudo is missing"
  assert_equals "" "$(mutating_calls)" "nothing ran without sudo"
  w_ubuntu as-root
  w_env FAKE_UID=0 FAKE_CAND_gh=2.60.0
  run_installer --yes
  expect_code 0 "$RC" "root installs"
  assert_contains "$OUT" "Steps marked [sudo] run as root, which you already are." "the plan says root needs no sudo"
  assert_no_grep "sudo " "$W/log" "root never goes through sudo"
  assert_grep "apt-get install -y" "$W/log" "root ran the package install directly"
  pass "sudo is announced in the plan and never runs silently"
}

test_toolchain_is_delegated_to_bootstrap() {
  w_ubuntu toolchain
  w_base
  w_env FAKE_BOOTSTRAP_TOOLS="tmux treehouse lavish-axi no-mistakes node" "FAKE_BOOTSTRAP_STUCK=MISSING: jq (install: brew install jq  # or the platform's package manager)"
  run_installer --yes
  expect_code 1 "$RC" "a tool bootstrap still reports missing makes the run exit non-zero"
  assert_grep "bootstrap install treehouse lavish-axi no-mistakes" "$W/log" "the installer passed bootstrap's own list to bootstrap install, in its order"
  assert_no_grep "install jq" "$W/log" "a base tool bootstrap lists is not handed back to it"
  assert_equals "" "$(grep -v '^bootstrap' "$W/log" | grep -E 'treehouse|no-mistakes|lavish|npm install|gh-axi' || true)" "no toolchain install ran outside bin/fm-bootstrap.sh"
  assert_grep "bootstrap  [DETECT_ONLY=1 NETWORK=skip HOME_DIR=$W/home/firstmate]" "$W/log" "the final check is bootstrap in detect-only form with the network skipped"
  assert_contains "$OUT" "Still needs attention (reported by bin/fm-bootstrap.sh):" "it reports plainly what is still missing"
  assert_contains "$OUT" "MISSING: jq" "it shows the line bootstrap printed"
  pass "the toolchain layer is delegated to bin/fm-bootstrap.sh install"
}

# --- the base layer ------------------------------------------------------------

test_version_floors_decide_what_is_installed() {
  w_ubuntu floors
  w_base 2.50.0 22.19.0
  run_installer --dry-run
  assert_not_contains "$OUT" "gh:" "gh at exactly 2.50.0 is recent enough"
  assert_not_contains "$OUT" "node:" "node at exactly 22.19.0 is recent enough"
  w_tool gh 2.49.9
  w_tool node 22.18.9
  run_installer --dry-run
  assert_contains "$OUT" "gh: 2.49.9 is older than 2.50.0, which firstmate's pull-request scripts need" "gh just below the floor is replaced"
  assert_contains "$OUT" "node: 22.18.9 is older than 22.19.0, which quota-axi requires" "node just below the floor is replaced"
  w_tool node 26.13.0
  rm -f "$W/inst/npm"
  run_installer --dry-run
  assert_contains "$OUT" "npm: not found" "a node without npm is not enough"
  pass "node 22.19.0 and gh 2.50.0 are the floors, and a version below them is replaced"
}

test_curl_is_installed_before_it_is_needed() {
  w_ubuntu curl-first
  rm -f "$W/inst/curl"
  run_installer --yes
  expect_code 0 "$RC" "the install exits 0:"$'\n'"$OUT"
  assert_order "$W/log" \
    "sudo apt-get update" \
    "apt-get install -y curl ca-certificates" \
    "curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg"
  pass "curl is installed before the first step that downloads with it"
}

test_ps_is_part_of_the_base_layer() {
  w_ubuntu ps-apt
  rm -f "$W/inst/ps"
  run_installer --dry-run
  assert_contains "$OUT" "ps: not found" "a missing ps is listed"
  assert_contains "$OUT" "apt-get install -y tmux jq procps gh libatomic1" "apt gets procps"
  run_installer --yes
  expect_code 0 "$RC" "the install exits 0:"$'\n'"$OUT"
  [ -e "$W/inst/ps" ] || fail "ps is on PATH after the install"
  w_new ps-dnf
  w_pm dnf
  w_tool curl
  w_env FAKE_CAND_gh=2.103.0 FAKE_BOOTSTRAP_TOOLS=""
  run_installer --dry-run
  assert_contains "$OUT" "dnf install -y git tmux jq procps-ng gh libatomic" "dnf gets procps-ng"
  w_new ps-mac
  w_pm brew
  w_env FAKE_UNAME_S=Darwin
  run_installer --dry-run
  assert_not_contains "$OUT" "procps" "macOS always has ps, so nothing is planned for it"
  pass "ps is installed with the base layer on Linux"
}

test_end_of_run_check_confirms_the_daemon_and_ps() {
  install_fully daemon-up
  run_installer
  expect_code 0 "$RC" "a healthy install exits 0:"$'\n'"$OUT"
  assert_contains "$OUT" "no-mistakes daemon: running" "it confirms the daemon is running"
  w_env FAKE_DAEMON_DOWN=1
  run_installer
  expect_code 1 "$RC" "a stopped daemon is a failed check"
  assert_contains "$OUT" "The no-mistakes daemon is not running. Start it with: no-mistakes daemon start" "it says how to start it"
  assert_not_contains "$OUT" "Everything firstmate needs is installed." "it does not claim success"
  assert_contains "$OUT" "ps: $W/inst/ps" "it shows the ps it found"
  w_new ps-gone
  w_pm brew
  w_base
  rm -f "$W/inst/ps"
  w_env FAKE_UNAME_S=Darwin FAKE_BOOTSTRAP_TOOLS=""
  run_installer --yes
  expect_code 1 "$RC" "a missing ps is a failed check"
  assert_contains "$OUT" "ps was not found; firstmate's scripts and the no-mistakes daemon need it" "it names ps"
  assert_not_contains "$OUT" "Everything firstmate needs is installed." "it does not claim success"
  pass "the end-of-run check confirms ps exists and the no-mistakes daemon is running"
}

test_node_comes_from_the_distribution_when_it_is_new_enough() {
  w_ubuntu distro-node
  w_env FAKE_CAND_nodejs=24.1.0 FAKE_CAND_npm=11.0.0 "FAKE_NPM_DEFAULT_PREFIX=$W/missing-prefix"
  run_installer --yes
  expect_code 0 "$RC" "the install exits 0:"$'\n'"$OUT"
  assert_grep "install -y tmux jq gh nodejs npm" "$W/log" "node and npm come from apt"
  assert_no_grep "nodejs.org" "$W/log" "no tarball was downloaded"
  assert_grep "npm config set prefix $W/home/.local" "$W/log" "the unwritable global prefix is moved into the home directory"
  [ ! -e "$W/home/.local/lib/nodejs" ] || fail "no tarball node was unpacked"
  w_ubuntu old-distro-node
  w_env FAKE_CAND_nodejs=18.19.1 FAKE_CAND_npm=9.2.0
  run_installer --dry-run
  assert_contains "$OUT" "Install the current Node.js LTS from nodejs.org" "an apt node older than the floor is not used"
  pass "the distribution's node is used when it is new enough, otherwise the tarball"
}

test_node_tarball_is_checksum_verified() {
  w_ubuntu bad-checksum
  printf '%s  node-v26.13.0-linux-x64.tar.gz\n' "0000000000000000000000000000000000000000000000000000000000000000" > "$W/badsums"
  w_env "FAKE_SHASUMS=$W/badsums"
  run_installer --yes
  [ "$RC" -ne 0 ] || fail "a checksum mismatch must fail the install"
  assert_contains "$OUT" "checksum mismatch for node-v26.13.0-linux-x64.tar.gz" "it names the mismatch"
  assert_contains "$OUT" "nothing was installed" "it says nothing was installed"
  [ ! -e "$W/home/.local/bin/node" ] || fail "an unverified node was linked"
  [ ! -e "$W/home/.local/lib/nodejs" ] || fail "an unverified node was unpacked"
  [ ! -e "$W/home/firstmate" ] || fail "the install stopped before the clone"
  w_ubuntu unlisted-file
  printf 'abc  node-v1.0.0-other.tar.gz\n' > "$W/badsums"
  w_env "FAKE_SHASUMS=$W/badsums"
  run_installer --yes
  [ "$RC" -ne 0 ] || fail "a file missing from the published list must fail the install"
  assert_contains "$OUT" "is not listed in the published SHASUMS256.txt" "it names the missing entry"
  pass "the Node.js tarball is verified against the published SHASUMS256.txt"
}

test_node_tarball_needs_a_supported_cpu() {
  w_ubuntu odd-cpu
  w_env FAKE_UNAME_M=riscv64
  run_installer --dry-run
  [ "$RC" -ne 0 ] || fail "an unsupported CPU must stop the plan"
  assert_contains "$OUT" "no Node.js download is selected for this CPU (riscv64)" "it names the CPU"
  assert_equals "" "$(mutating_calls)" "nothing ran"
  pass "an unsupported CPU stops before anything changes"
}

test_homebrew_install_and_upgrade() {
  w_new mac-fresh
  w_pm brew
  w_tool ps
  w_env FAKE_UNAME_S=Darwin FAKE_BOOTSTRAP_TOOLS="treehouse"
  run_installer --yes
  expect_code 0 "$RC" "the macOS install exits 0:"$'\n'"$OUT"
  assert_contains "$OUT" "system: macOS (Homebrew)" "the plan names the platform"
  assert_grep "brew install git tmux jq gh node" "$W/log" "missing tools come from Homebrew"
  assert_no_grep "sudo" "$W/log" "Homebrew needs no sudo"
  assert_no_grep "nodejs.org" "$W/log" "no tarball on macOS"
  assert_no_grep "npm config set prefix" "$W/log" "Homebrew's own prefix is left alone"
  w_new mac-upgrade
  w_pm brew
  w_base 2.40.0 20.1.0
  w_env FAKE_UNAME_S=Darwin "FAKE_BREW_MANAGED=gh" FAKE_BOOTSTRAP_TOOLS="treehouse"
  run_installer --yes
  expect_code 0 "$RC" "the macOS upgrade exits 0:"$'\n'"$OUT"
  assert_grep "brew upgrade gh" "$W/log" "an old gh that Homebrew manages is upgraded"
  assert_grep "brew install node" "$W/log" "an old node Homebrew does not manage is installed beside it"
  pass "macOS installs with Homebrew and upgrades what it manages"
}

test_dnf_and_pacman_plans() {
  w_new fedora
  w_pm dnf
  w_tool curl
  w_env FAKE_CAND_gh=2.40.0 FAKE_BOOTSTRAP_TOOLS="treehouse"
  run_installer --yes
  expect_code 0 "$RC" "the dnf install exits 0:"$'\n'"$OUT"
  assert_order "$W/log" "curl -fsSL https://cli.github.com/packages/rpm/gh-cli.repo" "sudo install -m 644" "sudo dnf install -y git tmux jq procps-ng gh libatomic"
  assert_no_grep "dnf upgrade" "$W/log" "a gh that was not installed is not upgraded"
  w_new fedora-old-gh
  w_pm dnf
  w_tool curl
  w_tool gh 2.40.0
  w_env FAKE_CAND_gh=2.103.0 FAKE_BOOTSTRAP_TOOLS="treehouse"
  run_installer --yes
  expect_code 0 "$RC" "the dnf upgrade exits 0:"$'\n'"$OUT"
  assert_not_contains "$OUT" "official CLI package repository" "a distribution gh that is new enough needs no extra repository"
  assert_grep "sudo dnf upgrade -y gh" "$W/log" "an installed old gh is upgraded explicitly"
  w_new arch
  w_pm pacman
  w_env FAKE_CAND_nodejs=24.1.0 FAKE_CAND_npm=11.0.0 FAKE_CAND_gh=2.103.0 FAKE_BOOTSTRAP_TOOLS="treehouse"
  run_installer --yes
  expect_code 0 "$RC" "the pacman install exits 0:"$'\n'"$OUT"
  assert_grep "sudo pacman -Sy --noconfirm --needed" "$W/log" "pacman installs with a refreshed index"
  assert_grep "nodejs npm" "$W/log" "pacman supplies node and npm"
  assert_no_grep "cli.github.com" "$W/log" "pacman needs no extra gh repository"
  pass "dnf and pacman follow the same plan with their own commands"
}

# --- the clone ------------------------------------------------------------------

# clone_world <name>: every base tool and a firstmate clone of a private copy of
# the upstream, so the case can move the upstream and the clone independently.
clone_world() {
  w_ubuntu "$1"
  w_base
  cp -R "$TMP_ROOT/upstream.git" "$W/upstream.git"
  w_env "FM_INSTALL_REPO=$W/upstream.git" FAKE_BOOTSTRAP_TOOLS=""
  git clone -q "$W/upstream.git" "$W/home/firstmate"
}

upstream_commit() {  # <file> <message>
  rm -rf "$W/pusher"
  git clone -q "$W/upstream.git" "$W/pusher"
  printf '%s\n' "$2" > "$W/pusher/$1"
  git -C "$W/pusher" add "$1"
  git -C "$W/pusher" -c user.name=fmtest -c user.email=fmtest@example.com commit -qm "$2"
  git -C "$W/pusher" push -q origin main
}

test_existing_clone_fast_forwards() {
  clone_world ff
  upstream_commit NEWS.md "news from upstream"
  run_installer --yes
  expect_code 0 "$RC" "the update exits 0:"$'\n'"$OUT"
  assert_contains "$OUT" "Update the firstmate clone at $W/home/firstmate with a fast-forward-only pull" "the plan says it only fast-forwards"
  [ -f "$W/home/firstmate/NEWS.md" ] || fail "the clone picked up the upstream commit"
  pass "an existing clone is updated with a fast-forward-only pull"
}

test_diverged_clone_is_left_alone() {
  clone_world diverged
  printf 'local work\n' > "$W/home/firstmate/LOCAL.md"
  git -C "$W/home/firstmate" add LOCAL.md
  git -C "$W/home/firstmate" -c user.name=fmtest -c user.email=fmtest@example.com commit -qm "local commit"
  printf 'uncommitted\n' > "$W/home/firstmate/scratch.txt"
  upstream_commit NEWS.md "news from upstream"
  local head_before
  head_before=$(git -C "$W/home/firstmate" rev-parse HEAD)
  run_installer --yes
  expect_code 0 "$RC" "a clone that cannot fast-forward does not fail the install:"$'\n'"$OUT"
  assert_contains "$OUT" "could not fast-forward $W/home/firstmate; it is left exactly as it is and the install continues." "it reports the refusal and continues"
  assert_equals "$head_before" "$(git -C "$W/home/firstmate" rev-parse HEAD)" "the local commit is untouched"
  assert_equals "uncommitted" "$(cat "$W/home/firstmate/scratch.txt")" "an uncommitted file survives"
  [ ! -e "$W/home/firstmate/NEWS.md" ] || fail "nothing was merged or reset"
  pass "a clone that cannot fast-forward is reported and left exactly as it is"
}

test_a_directory_that_is_not_a_clone_is_refused() {
  w_ubuntu not-a-clone
  w_base
  mkdir -p "$W/home/firstmate"
  printf 'precious\n' > "$W/home/firstmate/notes.txt"
  run_installer --yes
  expect_code 1 "$RC" "a non-clone directory exits non-zero"
  assert_contains "$OUT" "already exists and is not a firstmate clone; choose another place with --dir" "it says why"
  assert_equals "precious" "$(cat "$W/home/firstmate/notes.txt")" "the directory is untouched"
  assert_equals "" "$(mutating_calls)" "nothing ran"
  w_ubuntu empty-dir
  w_base
  w_env FAKE_BOOTSTRAP_TOOLS=""
  mkdir -p "$W/home/firstmate"
  run_installer --yes
  expect_code 0 "$RC" "an empty directory is cloned into:"$'\n'"$OUT"
  [ -f "$W/home/firstmate/bin/fm-bootstrap.sh" ] || fail "the clone landed in the empty directory"
  pass "a directory that is not a firstmate clone is never touched"
}

test_the_clone_location_is_configurable() {
  w_ubuntu where
  w_base
  w_env FAKE_BOOTSTRAP_TOOLS=""
  run_installer --yes --dir "$W/elsewhere/fm"
  expect_code 0 "$RC" "--dir installs there:"$'\n'"$OUT"
  [ -f "$W/elsewhere/fm/bin/fm-bootstrap.sh" ] || fail "--dir chose the clone location"
  w_ubuntu where-env
  w_base
  w_env "FM_INSTALL_DIR=$W/from-env" FAKE_BOOTSTRAP_TOOLS=""
  run_installer --yes
  [ -f "$W/from-env/bin/fm-bootstrap.sh" ] || fail "FM_INSTALL_DIR chose the clone location"
  w_ubuntu where-tilde
  w_base
  w_env FAKE_BOOTSTRAP_TOOLS=""
  # shellcheck disable=SC2088 # The installer expands the leading ~ itself.
  run_installer --yes --dir '~/custom/fm'
  [ -f "$W/home/custom/fm/bin/fm-bootstrap.sh" ] || fail "a leading ~ means the home directory"
  run_installer --help
  expect_code 0 "$RC" "--help exits 0"
  assert_contains "$OUT" "Usage: sh install.sh [--yes] [--dry-run] [--dir PATH]" "--help prints usage"
  run_installer --nonsense
  expect_code 1 "$RC" "an unknown option exits non-zero"
  assert_contains "$OUT" "unknown option: --nonsense" "it names the option"
  pass "--dir, FM_INSTALL_DIR, --help, and a bad option behave"
}

# --- the end of the run -----------------------------------------------------------

test_sign_in_is_offered_on_a_terminal() {
  install_fully signin
  printf 'y\n' > "$W/tty"
  w_env "FM_INSTALL_TTY=$W/tty"
  run_installer
  expect_code 0 "$RC" "a finished install with a terminal exits 0:"$'\n'"$OUT"
  assert_contains "$OUT" "Run 'gh auth login' now? [y/N]" "it offers the sign-in"
  assert_grep "gh auth login" "$W/log" "an accepted offer runs gh auth login"
  run_installer
  assert_contains "$OUT" "GitHub CLI: signed in." "once signed in it does not ask again"
  assert_not_contains "$OUT" "now? [y/N]" "no second offer"
  pass "gh auth login is offered on a terminal and left to the user otherwise"
}

test_path_line_is_printed_and_startup_files_are_not_edited() {
  w_ubuntu path-line
  local f
  for f in .profile .bashrc .zshrc .bash_profile .zprofile; do
    printf '# mine\n' > "$W/home/$f"
  done
  local before
  before=$(cd "$W/home" && cksum .profile .bashrc .zshrc .bash_profile .zprofile)
  run_installer --yes
  expect_code 0 "$RC" "the install exits 0:"$'\n'"$OUT"
  # shellcheck disable=SC2016 # The line is matched literally, not expanded.
  assert_contains "$OUT" 'export PATH="$HOME/.local/bin:$PATH"' "it prints the exact PATH line"
  assert_contains "$OUT" "This installer did not edit any shell startup file." "it says it edited none"
  assert_equals "$before" "$(cd "$W/home" && cksum .profile .bashrc .zshrc .bash_profile .zprofile)" "no startup file changed"
  w_ubuntu path-ready
  w_env "PATH=$W/home/.local/bin:$W/stubs:$W/inst:$W/basic"
  run_installer --yes
  expect_code 0 "$RC" "the install exits 0:"$'\n'"$OUT"
  assert_not_contains "$OUT" 'export PATH=' "no PATH line when the directory is already first"
  pass "the PATH line is printed, never written to a startup file"
}

test_next_steps_name_the_agents_that_are_installed() {
  install_fully agents-none
  run_installer
  assert_contains "$OUT" "Next: install one of the agents firstmate runs inside, with your own account:" "with no agent it says what to install"
  assert_contains "$OUT" "Claude Code (claude), Grok (grok), Pi (pi), Oh My Pi (omp), Codex (codex), OpenCode (opencode), or Cursor Agent (cursor-agent)" "it names the supported agents"
  assert_contains "$OUT" "https://github.com/kunchenguid/firstmate#install-and-launch" "it points at the README"
  install_fully agents
  local a
  for a in claude grok pi omp codex cursor-agent; do
    w_tool "$a"
  done
  w_tool opencode 2.0.21
  run_installer
  assert_contains "$OUT" "cd $W/home/firstmate" "it says to launch from the firstmate directory"
  local launch
  for launch in "claude +# Claude Code" "grok --trust +# Grok" "pi +# Pi" "omp +# Oh My Pi" "codex +# Codex" \
    "opencode --standalone +# OpenCode 2 or newer" "cursor-agent --trust +# Cursor Agent"; do
    printf '%s\n' "$OUT" | grep -E "^  $launch\$" >/dev/null || fail "missing launch line '$launch' in:"$'\n'"$OUT"
  done
  w_tool opencode 1.18.20
  run_installer
  printf '%s\n' "$OUT" | grep -E '^  opencode +# OpenCode$' >/dev/null || fail "OpenCode 1 launches plainly:"$'\n'"$OUT"
  assert_not_contains "$OUT" "--standalone" "OpenCode 1 gets no --standalone"
  pass "next steps give the README's launch command for each installed agent"
}

test_script_runs_under_every_posix_shell() {
  w_ubuntu shells
  INTERP=/bin/sh
  run_installer --dry-run
  local expected=$OUT shell found=0
  for shell in /bin/sh /bin/bash "$(PATH=$REAL_PATH command -v dash 2>/dev/null || true)" "$(PATH=$REAL_PATH command -v bash 2>/dev/null || true)"; do
    [ -n "$shell" ] && [ -x "$shell" ] || continue
    found=$((found + 1))
    INTERP=$shell
    run_installer --dry-run
    expect_code 0 "$RC" "$shell runs the installer"
    assert_equals "$expected" "$OUT" "$shell prints the same plan"
  done
  [ "$found" -ge 2 ] || fail "fewer than two interpreters were exercised"
  INTERP=/bin/sh
  pass "install.sh runs the same under /bin/sh, bash, and dash"
}

# A real terminal: the answer comes from the controlling terminal while stdin is
# the script, which is exactly the shape of `curl ... | sh`.
test_prompt_uses_the_controlling_terminal() {
  local py
  py=$(PATH=$REAL_PATH command -v python3 2>/dev/null) || {
    pass "skip: python3 not found, so no pseudo-terminal case"
    return 0
  }
  w_ubuntu real-tty
  cat > "$W/pty-driver.py" <<'PY'
import os, pty, select, sys, time
installer = sys.argv[1]
pid, fd = pty.fork()
if pid == 0:
    os.execv("/bin/sh", ["/bin/sh", "-c", 'exec /bin/sh -s < "$1"', "_", installer])
out = b""
sent = False
deadline = time.time() + 60
while time.time() < deadline:
    ready, _, _ = select.select([fd], [], [], 1)
    if not ready:
        continue
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    out += chunk
    if not sent and b"[y/N]" in out:
        os.write(fd, b"n\n")
        sent = True
_, status = os.waitpid(pid, 0)
sys.stdout.write(out.decode("utf-8", "replace"))
sys.stdout.write("\nPTY_EXIT=%d\n" % (os.WEXITSTATUS(status) if os.WIFEXITED(status) else 255))
PY
  OUT=$(env -u FM_INSTALL_TTY -u FM_INSTALL_YES -u FM_HOME "PATH=$W/stubs:$W/inst:$W/basic" "HOME=$W/home" "TMPDIR=$W/tmp" \
    "FM_TEST_W=$W" "FM_TEST_LOG=$W/log" "FM_INSTALL_REPO=$TMP_ROOT/upstream.git" FAKE_CAND_gh=2.45.0 \
    "$py" "$W/pty-driver.py" "$INSTALLER" 2>&1)
  assert_contains "$OUT" "Run these steps now? [y/N]" "it asked on the terminal while the script was on stdin"
  assert_contains "$OUT" "Nothing was changed." "declining on the real terminal changes nothing"
  assert_contains "$OUT" "PTY_EXIT=1" "declining exits non-zero"
  assert_equals "" "$(mutating_calls)" "nothing ran"
  pass "the answer is read from the controlling terminal while stdin is the script"
}

build_upstream
build_node_fixtures

fm_test_run \
  test_dry_run_runs_nothing \
  test_no_terminal_without_yes_changes_nothing \
  test_consent_prompt_reads_the_terminal \
  test_yes_runs_the_plan_in_order \
  test_finished_install_is_a_noop \
  test_unsupported_platforms_refuse \
  test_sudo_is_announced_before_it_runs \
  test_toolchain_is_delegated_to_bootstrap \
  test_version_floors_decide_what_is_installed \
  test_curl_is_installed_before_it_is_needed \
  test_ps_is_part_of_the_base_layer \
  test_end_of_run_check_confirms_the_daemon_and_ps \
  test_node_comes_from_the_distribution_when_it_is_new_enough \
  test_node_tarball_is_checksum_verified \
  test_node_tarball_needs_a_supported_cpu \
  test_homebrew_install_and_upgrade \
  test_dnf_and_pacman_plans \
  test_existing_clone_fast_forwards \
  test_diverged_clone_is_left_alone \
  test_a_directory_that_is_not_a_clone_is_refused \
  test_the_clone_location_is_configurable \
  test_sign_in_is_offered_on_a_terminal \
  test_path_line_is_printed_and_startup_files_are_not_edited \
  test_next_steps_name_the_agents_that_are_installed \
  test_script_runs_under_every_posix_shell \
  test_prompt_uses_the_controlling_terminal
