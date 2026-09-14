#!/usr/bin/env bash
# Behavior tests for the verified Kimi Code CLI crewmate adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# bin/fm-harness.sh answers from environment markers and process ancestry. A
# suite run from inside Cursor, Claude, Pi, or Grok inherits those markers and
# its own real ancestry, either of which can decide a case the detection cases
# meant to control. Drop the ambient markers so the asserted verdict does not
# depend on which harness launched the suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
KIMI_HOOK="$ROOT/bin/fm-kimi-turnend-hook.sh"
TMP_ROOT=$(fm_test_tmproot fm-kimi-harness)
KIMI_RUNTIME_TASK_TMP=
KIMI_RUNTIME_LAUNCH_DIR=
PYTHON_BIN=$(command -v python3) || fail "test needs python3"
PYTHON_BIN_DIR=$(dirname "$PYTHON_BIN")
JQ_BIN=$(command -v jq) || fail "test needs jq"
BASE_PATH=${FM_TEST_BASE_PATH:-$PYTHON_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}

ai_trailer_hooks_prefix() {  # <home> <id>
  local state
  state=$(CDPATH='' cd -- "$1/state" && pwd -P) || fail "cannot resolve state dir $1/state"
  printf "export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0='%s'; " "$state/$2.git-hooks"
}

cleanup_kimi_harness() {
  [ -z "$KIMI_RUNTIME_TASK_TMP" ] || fm_test_remove_tree "$KIMI_RUNTIME_TASK_TMP"
  [ -z "$KIMI_RUNTIME_LAUNCH_DIR" ] || fm_test_remove_tree "$KIMI_RUNTIME_LAUNCH_DIR"
  fm_test_remove_tree "$TMP_ROOT"
}
trap cleanup_kimi_harness EXIT

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
state=$(cat "$FM_FAKE_KIMI_STATE" 2>/dev/null || true)
fake_screen() {
  case "$state" in
    ready)
      printf 'Welcome to Kimi Code!\ncontext: 0%% (0/256k)\n╭────────────────────────────────╮\n│ >                              │\n╰────────────────────────────────╯\n'
      ;;
    trust)
      printf '╭─ Trust this folder? ─╮\n│ ↑↓ navigate · Enter select · Esc exit │\n│ %s │\n│ ❯ Trust this folder │\n│   Don'"'"'t trust │\n╰──────────────────────────────╯\n' "$FM_FAKE_PANE_PATH"
      ;;
    trust-decoy)
      printf 'Trust this folder?\n%s\n❯ Trust this folder\nDon'"'"'t trust\n' "$FM_FAKE_PANE_PATH"
      ;;
    trust-partial)
      printf 'Welcome to Kimi Code!\nTrust this folder?\n%s\nDon'"'"'t trust\n' "$FM_FAKE_PANE_PATH"
      ;;
    booting)
      printf 'shell starting\n$ \n'
      ;;
    banner-only|banner-first)
      printf 'Welcome to Kimi Code!\nstarting in %s\n' "$FM_FAKE_PANE_PATH"
      ;;
    blank-frame)
      ;;
    trust-wrapped)
      printf '╭─ Trust this folder? ─╮\n│ ↑↓ navigate ·        │\n│ Enter select · Esc   │\n│ exit                 │\n│ %s │\n│ ❯ Trust this folder  │\n│   Don'"'"'t trust         │\n╰──────────────────────╯\n' "$FM_FAKE_PANE_PATH"
      ;;
    pointer-typed)
      printf 'context: 0%% (0/256k)\n╭────────────────────────────────╮\n│ > Read the brief and follow it │\n│                                │\n╰────────────────────────────────╯\n'
      ;;
    delivered)
      printf '✨ Read the brief at %s and follow it exactly.\ncontext: 1%% (2k/256k)\n╭────────────────────────────────╮\n│ >                              │\n╰────────────────────────────────╯\n' "$FM_FAKE_BRIEF_REAL"
      ;;
    *)
      printf 'shell starting\n$ \n'
      ;;
  esac
}
fake_history() {
  if [ "${FM_FAKE_KIMI_HISTORY_KEEPS_DIALOG:-no}" = yes ] \
     && [ -s "$FM_FAKE_KIMI_TRUST_ENTER_LOG" ]; then
    printf '╭─ Trust this folder? ─╮\n│ ↑↓ navigate · Enter select · Esc exit │\n│ ❯ Trust this folder │\n│   Don'"'"'t trust │\n╰──────────────────────╯\n'
  fi
}
fake_cursor_y() {
  case "$state" in
    pointer-typed) printf '3\n' ;;
    ready|delivered) printf '3\n' ;;
    *) printf '1\n' ;;
  esac
}
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{cursor_y}"*) fake_cursor_y; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    literal=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    if [ -n "$literal" ]; then
      case "$literal" in
        ". '"*"'") staged=${literal#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || literal=$(cat "$staged") ;;
      esac
      case "$literal" in
        *' --auto')
          printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
          printf 'launched\n' > "$FM_FAKE_KIMI_STATE"
          ;;
        *)
          printf '%s\n' "$literal" >> "$FM_FAKE_POINTER_LOG"
          case "$state" in
            trust|trust-wrapped|trust-partial|trust-decoy|booting|banner-only|banner-first|blank-frame) ;;
            *) printf 'pointer-typed\n' > "$FM_FAKE_KIMI_STATE" ;;
          esac
          ;;
      esac
      exit 0
    fi
    case " $* " in
      *' Enter '*)
        case "$state" in
          launched)
            if [ "${FM_FAKE_KIMI_READY:-yes}" = yes ]; then
              case "${FM_FAKE_KIMI_TRUST:-remembered}" in
                fresh) printf 'trust\n' > "$FM_FAKE_KIMI_STATE" ;;
                decoy) printf 'trust-decoy\n' > "$FM_FAKE_KIMI_STATE" ;;
                partial) printf 'trust-partial\n' > "$FM_FAKE_KIMI_STATE" ;;
                late) printf 'booting\n' > "$FM_FAKE_KIMI_STATE" ;;
                blink) printf 'banner-first\n' > "$FM_FAKE_KIMI_STATE" ;;
                wrapped) printf 'trust-wrapped\n' > "$FM_FAKE_KIMI_STATE" ;;
                *) printf 'ready\n' > "$FM_FAKE_KIMI_STATE" ;;
              esac
            fi
            ;;
          trust|trust-wrapped)
            printf 'enter\n' >> "$FM_FAKE_KIMI_TRUST_ENTER_LOG"
            trust_enters=$(wc -l < "$FM_FAKE_KIMI_TRUST_ENTER_LOG" | tr -d ' ')
            case "${FM_FAKE_KIMI_TRUST_CLEARS:-yes}" in
              yes) printf 'ready\n' > "$FM_FAKE_KIMI_STATE" ;;
              after-second)
                [ "$trust_enters" -lt 2 ] || printf 'ready\n' > "$FM_FAKE_KIMI_STATE"
                ;;
            esac
            ;;
          ready|delivered)
            printf 'enter\n' >> "$FM_FAKE_KIMI_STRAY_ENTER_LOG"
            ;;
          pointer-typed)
            if [ "${FM_FAKE_KIMI_DELIVERY:-yes}" = yes ]; then
              if [ "${FM_FAKE_KIMI_SWALLOW_FIRST:-no}" = yes ] \
                 && [ ! -f "$FM_FAKE_KIMI_SWALLOWED" ]; then
                : > "$FM_FAKE_KIMI_SWALLOWED"
              else
                printf 'delivered\n' > "$FM_FAKE_KIMI_STATE"
              fi
            else
              printf 'ready\n' > "$FM_FAKE_KIMI_STATE"
            fi
            ;;
        esac
        ;;
    esac
    exit 0
    ;;
  capture-pane)
    start= end= prev=
    for arg in "$@"; do
      case "$prev" in
        -S) start=$arg ;;
        -E) end=$arg ;;
      esac
      case "$arg" in -S|-E) prev=$arg ;; *) prev= ;; esac
    done
    if [ "$start" = -0 ] && [ "${FM_FAKE_TMUX_VISIBLE_FAILS:-no}" = yes ]; then
      echo "can't find pane" >&2
      exit 1
    fi
    case "$start" in
      -0|-120)
        case "$state" in
          booting) printf 'banner-only\n' > "$FM_FAKE_KIMI_STATE" ;;
          banner-first) printf 'blank-frame\n' > "$FM_FAKE_KIMI_STATE" ;;
          blank-frame) printf 'banner-only\n' > "$FM_FAKE_KIMI_STATE" ;;
          banner-only) printf 'trust\n' > "$FM_FAKE_KIMI_STATE" ;;
        esac
        ;;
    esac
    if [ "$start" = -0 ] && [ "${FM_FAKE_KIMI_BLANK_AFTER_TRUST:-no}" = yes ] \
       && [ -s "$FM_FAKE_KIMI_TRUST_ENTER_LOG" ] && [ ! -f "$FM_FAKE_KIMI_BLANKED" ]; then
      : > "$FM_FAKE_KIMI_BLANKED"
      exit 0
    fi
    [ "$start" != -120 ] || fake_history
    case "$start:$end" in
      *[!0-9:]*|'':*|*:'') fake_screen ;;
      *) fake_screen | awk -v start="$start" -v end="$end" \
           'NR - 1 >= start && NR - 1 <= end' ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  fm_fake_exit0 "$fakebin" kimi
  ln -s "$JQ_BIN" "$fakebin/jq"
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$home/.kimi-code"
  printf '# Kimi test config\ndefault_model = "test"\n' > "$home/.kimi-code/config.toml"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise Kimi dispatch.

## Firstmate spec
Verify launch and delivery behavior.
EOF
  printf 'kimi\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  : > "$case_dir/pointer.log"
  : > "$case_dir/kimi.state"
  : > "$case_dir/trust-enter.log"
  : > "$case_dir/stray-enter.log"
  : > "$case_dir/tmux-calls.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_POINTER_LOG="$case_dir/pointer.log" \
    FM_FAKE_KIMI_STATE="$case_dir/kimi.state" \
    FM_FAKE_KIMI_TRUST_ENTER_LOG="$case_dir/trust-enter.log" \
    FM_FAKE_KIMI_TRUST="${FM_FAKE_KIMI_TRUST:-remembered}" \
    FM_FAKE_KIMI_TRUST_CLEARS="${FM_FAKE_KIMI_TRUST_CLEARS:-yes}" \
    FM_FAKE_KIMI_HISTORY_KEEPS_DIALOG="${FM_FAKE_KIMI_HISTORY_KEEPS_DIALOG:-no}" \
    FM_FAKE_KIMI_STRAY_ENTER_LOG="$case_dir/stray-enter.log" \
    FM_FAKE_KIMI_BLANK_AFTER_TRUST="${FM_FAKE_KIMI_BLANK_AFTER_TRUST:-no}" \
    FM_FAKE_KIMI_BLANKED="$case_dir/kimi.blanked" \
    FM_FAKE_TMUX_VISIBLE_FAILS="${FM_FAKE_TMUX_VISIBLE_FAILS:-no}" \
    FM_FAKE_KIMI_SWALLOWED="$case_dir/kimi.swallowed" \
    FM_FAKE_KIMI_SWALLOW_FIRST="${FM_FAKE_KIMI_SWALLOW_FIRST:-no}" \
    FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    FM_FAKE_BRIEF_REAL="$(cd "$home/data/$id" && pwd -P)/launch-brief.md" \
    FM_KIMI_READY_POLLS="${FM_KIMI_READY_POLLS:-2}" FM_KIMI_DELIVERY_POLLS=2 FM_KIMI_POLL_INTERVAL=0 \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness kimi --mode no-mistakes --yolo off "$@" 2>&1
}

read_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

# --- workspace-trust pre-registration ----------------------------------------
#
# The unit half drives bin/fm-kimi-trust.sh directly against a throwaway HOME,
# so nothing here touches the developer's real ~/.kimi-code store. The spawn
# half below rides the kimi fake world above, whose HOME is the fixture home,
# for the same reason.

TRUST="$ROOT/bin/fm-kimi-trust.sh"

make_trust_case() {  # <name> -> "<case>|<proj>|<wt>|<home>"
  local name=$1 case_dir proj wt home
  case_dir="$TMP_ROOT/trust-$name"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  home="$case_dir/home"
  mkdir -p "$home"
  fm_git_worktree "$proj" "$wt" "wt-trust-$name"
  printf '%s|%s|%s|%s\n' "$case_dir" "$proj" "$wt" "$home"
}

read_trust_case() {
  IFS='|' read -r TRUST_CASE_DIR TRUST_PROJ TRUST_WT TRUST_HOME <<EOF
$1
EOF
}

run_trust() {  # <home> <worktree> <project>
  HOME="$1" "$TRUST" "$2" "$3" 2>&1
}

run_home_trust() {  # <seeded-home> <user-home> <id>
  HOME="$2" "$TRUST" --secondmate-home "$1" "$3" 2>&1
}

trust_store() {  # <home>
  printf '%s\n' "$1/.kimi-code/workspace-trust"
}

# The record file name Kimi itself computes, rebuilt here from the verified
# store contract so the assertions judge the on-disk shape rather than the
# script's own bytes.
kimi_record_path() {  # <store> <root>
  # shellcheck disable=SC2016 # The template literal is JavaScript, not this test shell.
  node -e '
    const path = require("node:path");
    const crypto = require("node:crypto");
    const root = process.argv[2];
    const hash = crypto.createHash("sha256").update(root, "utf8").digest("hex").slice(0, 12);
    process.stdout.write(path.join(process.argv[1], `wd_${path.basename(root)}_${hash}`));
  ' "$1" "$2"
}

assert_kimi_trusted() {  # <store> <root> <msg>
  local file
  file=$(kimi_record_path "$1" "$2")
  [ -f "$file" ] || fail "$3 (no record at $file)"
  node -e 'process.exit(JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")).root === process.argv[2] ? 0 : 1)' \
    "$file" "$2" || fail "$3 (record at $file names another root: $(cat "$file"))"
}

assert_kimi_not_trusted() {  # <store> <root> <msg>
  [ ! -e "$(kimi_record_path "$1" "$2")" ] || fail "$3"
  return 0
}

file_mode() {  # <file> -> symbolic-free octal mode on macOS and Linux alike
  stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"
}

# seed_secondmate_home <home> <id> [shape]: the on-disk shape
# bin/fm-home-seed.sh leaves behind, in both seeded shapes - "clone" (the
# default) a standalone repo checkout, "worktree" a linked worktree.
seed_secondmate_home() {
  local home=$1 id=$2 shape=${3:-clone} src
  case "$shape" in
    worktree)
      src="$home.src"
      fm_git_worktree "$src" "$home" "sm-$id"
      ;;
    *)
      mkdir -p "$home"
      fm_git_init_commit "$home"
      ;;
  esac
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
}

# A PATH carrying the tools the scope test needs but no node, so the
# missing-interpreter path is exercised without disturbing the real PATH.
node_free_path() {  # <case-dir>
  local dir=$1/nonode-bin tool
  mkdir -p "$dir"
  for tool in bash env git mkdir; do
    ln -sf "$(command -v "$tool")" "$dir/$tool"
  done
  printf '%s\n' "$dir"
}

test_kimi_launch_then_send_is_verified() {
  local id rec out rc launch pointer brief_real meta task_tmp launch_dir launch_file launch_base
  id="kimi-success-z1-$$"
  task_tmp="/tmp/fm-$id"
  KIMI_RUNTIME_TASK_TMP=$task_tmp
  rm -rf "$task_tmp"
  rec=$(make_spawn_case success "$id")
  read_spawn_record "$rec"
  launch_dir=$(kimi_launch_dir "$id" "$HOME_DIR")
  KIMI_RUNTIME_LAUNCH_DIR=$launch_dir
  rm -rf "$launch_dir"
  out=$(FM_FAKE_KIMI_SWALLOW_FIRST=yes run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model kimi-code/k3 --effort high)
  rc=$?
  expect_code 0 "$rc" "verified kimi launch-then-send should succeed"
  assert_contains "$out" "spawned $id harness=kimi" "kimi spawn did not report success"

  launch=$(cat "$CASE_DIR/launch.log")
  [ "$launch" = "export COMPACT_ADVISER_DISABLE=1; $(ai_trailer_hooks_prefix "$HOME_DIR" "$id")env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI '$FAKEBIN_DIR/kimi' --model 'kimi-code/k3' --auto" ] \
    || fail "kimi launch did not use the absolute binary, model, and --auto only: $launch"
  assert_not_contains "$launch" "--effort" "kimi launch emitted a nonexistent effort flag"
  assert_not_contains "$launch" "turn-ended" "kimi launch embedded a turn-end path"
  assert_not_contains "$launch" "__TURNEND__" "kimi launch retained a turn-end placeholder"

  brief_real="$(cd "$HOME_DIR/data/$id" && pwd -P)/launch-brief.md"
  pointer=$(cat "$CASE_DIR/pointer.log")
  [ "$pointer" = "Read the brief at $brief_real and follow it exactly." ] \
    || fail "kimi pointer was not the exact absolute-path-only instruction: $pointer"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'model=kimi-code/k3' "$meta" "kimi meta lost the requested model"
  assert_grep 'effort=high' "$meta" "kimi meta did not retain the unsupported effort axis"
  assert_grep "tasktmp=$task_tmp" "$meta" "kimi meta did not record its task temp root"
  assert_present "$task_tmp/gotmp" "kimi spawn did not create its Go temp directory"
  [ "$(path_mode "$task_tmp")" = 700 ] \
    || fail "kimi spawn left its task temp root readable by others: $(path_mode "$task_tmp")"
  launch_file=$(kimi_typed_launch_file "$CASE_DIR/tmux-calls.log")
  launch_base=$(basename "$launch_file")
  case "$launch_file" in
    "$launch_dir"/launch.*) ;;
    *) fail "kimi spawn typed a launch path outside its home namespace: $launch_file" ;;
  esac
  [ "$launch_base" != launch.sh ] \
    || fail "kimi spawn reused a mutable launch.sh name"
  [ "$launch_file" != "$task_tmp/launch.sh" ] \
    || fail "kimi spawn staged its launch command at the shared per-id path"
  [ "$(path_mode "$launch_dir")" = 700 ] \
    || fail "kimi spawn left its launch directory readable by others: $(path_mode "$launch_dir")"
  [ "$(path_mode "$launch_file")" = 600 ] \
    || fail "kimi spawn staged its launch command without mode 0600: $(path_mode "$launch_file")"
  grep -qF -- "-l . '$launch_file'" "$CASE_DIR/tmux-calls.log" \
    || fail "kimi spawn did not type a short line sourcing its staged launch command"
  assert_grep "export GOTMPDIR=$task_tmp/gotmp" "$CASE_DIR/tmux-calls.log" \
    "kimi spawn did not export its Go temp directory into the pane"
  assert_grep "export FM_TASK_ID=$id" "$CASE_DIR/tmux-calls.log" \
    "kimi spawn did not mark the pane with its task id"
  assert_grep 'BEGIN FIRSTMATE KIMI TURN-END HOOK' "$HOME_DIR/.kimi-code/config.toml" \
    "kimi spawn did not install its guarded global hook region"
  assert_grep 'token=' "$WT_DIR/.fm-kimi-turnend" "kimi spawn did not write its token pointer"
  assert_present "$HOME_DIR/state/$id.kimi-turnend-token" "kimi spawn did not record its token"
  pass "fm-spawn: kimi launches, delivers its brief, and registers a guarded turn-end token"
}

path_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
}

kimi_launch_dir() {
  local id=$1 home=$2 root hash
  root=$(cd "$home" 2>/dev/null && pwd -P) || root=$home
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | shasum -a 256 | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | sha256sum | awk '{print $1}')
  else
    fail "test needs shasum or sha256sum"
  fi
  printf '/tmp/fm-%s+%s' "$id" "$hash"
}

kimi_typed_launch_file() {
  local log=$1 src
  src=$(grep -o "\. '/tmp/fm-[^']*'" "$log" | tail -1)
  src=${src#". '"}
  src=${src%"'"}
  [ -n "$src" ] || fail "spawn did not type a staged launch source line"
  printf '%s' "$src"
}

test_kimi_spawn_refuses_shared_task_temp_root() {
  local id rec out rc task_tmp launch_dir launch_file stale_file
  id="kimi-sharedtmp-z1-$$"
  task_tmp="/tmp/fm-$id"
  KIMI_RUNTIME_TASK_TMP=$task_tmp
  rm -rf "$task_tmp"
  mkdir "$task_tmp"
  chmod 777 "$task_tmp"
  rec=$(make_spawn_case sharedtmp "$id")
  read_spawn_record "$rec"
  launch_dir=$(kimi_launch_dir "$id" "$HOME_DIR")
  KIMI_RUNTIME_LAUNCH_DIR=$launch_dir
  rm -rf "$launch_dir"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  [ "$rc" -ne 0 ] || fail "kimi spawn accepted a world-writable task temp root"
  assert_contains "$out" "is not a private directory owned by this user" \
    "kimi spawn did not name the unsafe task temp root"
  assert_absent "$task_tmp/launch.sh" "kimi spawn staged its launch command in a shared directory"
  assert_absent "$launch_dir" "kimi spawn staged a namespaced launch directory after refusing the shared temp root"
  [ ! -s "$CASE_DIR/launch.log" ] || fail "kimi spawn launched despite an unsafe task temp root"
  rm -rf "$task_tmp"
  mkdir "$task_tmp"
  chmod 755 "$task_tmp"
  rec=$(make_spawn_case ownedtmp "$id")
  read_spawn_record "$rec"
  launch_dir=$(kimi_launch_dir "$id" "$HOME_DIR")
  KIMI_RUNTIME_LAUNCH_DIR=$launch_dir
  rm -rf "$launch_dir"
  mkdir "$launch_dir"
  chmod 755 "$launch_dir"
  stale_file="$launch_dir/launch.sh"
  printf 'stale launch command\n' > "$stale_file"
  chmod 644 "$stale_file"
  printf 'stale shared launch command\n' > "$task_tmp/launch.sh"
  chmod 644 "$task_tmp/launch.sh"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "kimi spawn should reuse an existing temp root it owns: $out"
  launch_file=$(kimi_typed_launch_file "$CASE_DIR/tmux-calls.log")
  [ "$(path_mode "$task_tmp")" = 700 ] \
    || fail "kimi spawn did not tighten its reused task temp root: $(path_mode "$task_tmp")"
  [ "$(path_mode "$launch_dir")" = 700 ] \
    || fail "kimi spawn did not tighten its reused launch directory: $(path_mode "$launch_dir")"
  case "$launch_file" in
    "$launch_dir"/launch.*) ;;
    *) fail "kimi spawn typed a launch path outside its home namespace: $launch_file" ;;
  esac
  [ "$launch_file" != "$stale_file" ] \
    || fail "kimi spawn rebound a pre-existing launch.sh instead of writing a new nonce file"
  [ "$(path_mode "$launch_file")" = 600 ] \
    || fail "kimi spawn staged its launch command without mode 0600: $(path_mode "$launch_file")"
  [ "$(path_mode "$stale_file")" = 644 ] \
    || fail "kimi spawn overwrote a pre-existing launch.sh"
  [ "$(path_mode "$task_tmp/launch.sh")" = 644 ] \
    || fail "kimi spawn reused the shared per-id launch file"
  grep -qF -- "-l . '$launch_file'" "$CASE_DIR/tmux-calls.log" \
    || fail "kimi spawn did not type a short line sourcing its namespaced launch command"
  rm -rf "$task_tmp" "$launch_dir"
  pass "fm-spawn: unsafe task roots are refused, owned roots are tightened, and launch files stay unique and 0600"
}

test_kimi_hook_install_is_surgical_idempotent_and_removable() {
  local home config original once stripped count
  home="$TMP_ROOT/config-surgery"
  config="$home/.kimi-code/config.toml"
  original="$home/original.toml"
  once="$home/once.toml"
  stripped="$home/stripped.toml"
  mkdir -p "$home/.kimi-code"
  cat > "$config" <<'EOF'
# Captain's leading comment stays exactly here.

[ui]
theme = "night" # inline comment
show_usage = true

# Foreign hook with intentionally unusual key ordering.
[[hooks]]
timeout=17
command = "printf foreign"
matcher=""
event = "Stop"

[providers.example]
model = "some/model"
# Final comment and blank line follow.

EOF
  cp "$config" "$original"

  HOME="$home" "$KIMI_HOOK" install || fail "Kimi hook install refused a realistic config"
  cp "$config" "$once"
  HOME="$home" "$KIMI_HOOK" install || fail "second Kimi hook install failed"
  cmp -s "$once" "$config" || fail "second Kimi hook install changed config bytes"
  count=$(grep -c '^# BEGIN FIRSTMATE KIMI TURN-END HOOK' "$config")
  [ "$count" -eq 1 ] || fail "idempotent install left $count Firstmate regions"

  HOME="$home" "$KIMI_HOOK" remove || fail "Kimi hook removal failed"
  cp "$config" "$stripped"
  cmp -s "$original" "$stripped" \
    || fail "config with the Firstmate region excised was not byte-identical to the original"
  assert_absent "$home/.kimi-code/fm-turn-end.sh" "removal left the Firstmate hook script"
  assert_absent "$home/.kimi-code/fm-turn-end.d" "removal left the Firstmate registry"
  pass "Kimi hook install is idempotent and removal restores every foreign config byte"
}

test_kimi_hook_remove_preserves_owned_newline_boundary() {
  local appended config expected home original
  home="$TMP_ROOT/config-owned-newline"
  config="$home/.kimi-code/config.toml"
  original="$home/original.toml"
  expected="$home/expected.toml"
  appended="$home/appended.toml"
  mkdir -p "$home/.kimi-code"
  printf 'default_model = "test"' > "$config"
  cp "$config" "$original"

  HOME="$home" "$KIMI_HOOK" install || fail "Kimi hook install refused config without a final newline"
  HOME="$home" "$KIMI_HOOK" remove || fail "Kimi hook removal failed without appended config"
  cmp -s "$original" "$config" \
    || fail "pristine removal did not restore the absent final newline byte-identically"

  HOME="$home" "$KIMI_HOOK" install || fail "second Kimi hook install refused config without a final newline"
  printf '[captain]\nenabled = true\n' > "$appended"
  cat "$appended" >> "$config"
  HOME="$home" "$KIMI_HOOK" remove || fail "Kimi hook removal joined config appended after its region"
  {
    cat "$original"
    printf '\n'
    cat "$appended"
  } > "$expected"
  cmp -s "$expected" "$config" \
    || fail "removal did not preserve appended captain config on its own line"
  "$PYTHON_BIN" - "$config" <<'PY' || fail "config with appended captain TOML did not parse after removal"
import sys
import tomllib

with open(sys.argv[1], "rb") as stream:
    tomllib.load(stream)
PY
  pass "Kimi hook removal preserves owned newline boundaries and pristine bytes"
}

test_kimi_hook_fails_closed_on_missing_malformed_or_partial_config() {
  local missing malformed partial out rc
  missing="$TMP_ROOT/config-missing"
  malformed="$TMP_ROOT/config-malformed"
  partial="$TMP_ROOT/config-partial"
  mkdir -p "$missing/.kimi-code" "$malformed/.kimi-code" "$partial/.kimi-code"

  rc=0
  out=$(HOME="$missing" "$KIMI_HOOK" install 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "missing Kimi config was accepted"
  assert_contains "$out" "Kimi config is missing" "missing config refusal lacked its concrete reason"
  assert_absent "$missing/.kimi-code/fm-turn-end.sh" "missing config refusal wrote the hook script"

  printf '[broken\n' > "$malformed/.kimi-code/config.toml"
  cp "$malformed/.kimi-code/config.toml" "$malformed/before"
  rc=0
  out=$(HOME="$malformed" "$KIMI_HOOK" install 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "malformed Kimi config was accepted"
  assert_contains "$out" "malformed TOML" "malformed config refusal lacked its concrete reason"
  cmp -s "$malformed/before" "$malformed/.kimi-code/config.toml" \
    || fail "malformed config refusal changed config bytes"
  assert_absent "$malformed/.kimi-code/fm-turn-end.sh" "malformed config refusal wrote the hook script"

  printf '# BEGIN FIRSTMATE KIMI TURN-END HOOK\n' > "$partial/.kimi-code/config.toml"
  cp "$partial/.kimi-code/config.toml" "$partial/before"
  rc=0
  out=$(HOME="$partial" "$KIMI_HOOK" install 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "partial Firstmate marker was accepted"
  assert_contains "$out" "partial, duplicated, or altered" "partial marker refusal lacked its concrete reason"
  cmp -s "$partial/before" "$partial/.kimi-code/config.toml" \
    || fail "partial marker refusal changed config bytes"
  pass "Kimi hook install refuses missing, malformed, and surprising config without writing"
}

test_kimi_hook_install_refuses_without_jq() {
  local home config before fakebin out rc
  home="$TMP_ROOT/config-no-jq"
  config="$home/.kimi-code/config.toml"
  before="$home/config-before.toml"
  fakebin=$(fm_fakebin "$home/no-jq")
  mkdir -p "$home/.kimi-code"
  printf '# Captain config\nmodel = "test"\n' > "$config"
  cp "$config" "$before"
  ln -s "$(command -v bash)" "$fakebin/bash"
  ln -s "$(command -v python3)" "$fakebin/python3"

  rc=0
  out=$(HOME="$home" PATH="$fakebin" "$KIMI_HOOK" install 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "Kimi hook install succeeded without jq"
  assert_contains "$out" "jq is required" "missing-jq refusal did not name jq"
  cmp -s "$before" "$config" || fail "missing-jq refusal changed config bytes"
  assert_absent "$home/.kimi-code/fm-turn-end.sh" "missing-jq refusal wrote the hook script"
  assert_absent "$home/.kimi-code/fm-turn-end.d" "missing-jq refusal wrote the registry"
  pass "Kimi hook install refuses without jq before any config write"
}

test_kimi_hook_is_silent_and_requires_registered_workspace_token() {
  local id rec out rc hook target token no_token snapshot_before snapshot_after fakebin
  id=kimi-hook-auth-z6
  rec=$(make_spawn_case hook-auth "$id")
  read_spawn_record "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "Kimi spawn should succeed before hook authentication checks"
  hook="$HOME_DIR/.kimi-code/fm-turn-end.sh"
  target="$HOME_DIR/state/$id.turn-ended"
  token=$(sed -n 's/^token=//p' "$WT_DIR/.fm-kimi-turnend")
  assert_present "$HOME_DIR/.kimi-code/fm-turn-end.d/$token" "Kimi registry token is missing"

  no_token="$CASE_DIR/no-token-workspace"
  mkdir -p "$no_token"
  snapshot_before=$(find "$no_token" -mindepth 1 -print)
  out=$(printf '{"hook_event_name":"Stop","session_id":"ordinary","cwd":"%s","stop_hook_active":false}\n' "$no_token" \
    | HOME="$HOME_DIR" bash "$hook" 2>&1)
  rc=$?
  expect_code 0 "$rc" "Kimi hook must never block a tokenless session"
  [ -z "$out" ] || fail "Kimi hook printed into a tokenless session: $out"
  snapshot_after=$(find "$no_token" -mindepth 1 -print)
  [ "$snapshot_before" = "$snapshot_after" ] || fail "Kimi hook wrote inside a tokenless workspace"
  assert_absent "$target" "tokenless Kimi hook invocation touched a task marker"

  printf 'token=%s\n' "$token" > "$WT_DIR/.fm-kimi-turnend"
  out=$(printf '{"hook_event_name":"Stop","session_id":"crew","cwd":"%s","stop_hook_active":false}\n' "$WT_DIR" \
    | HOME="$HOME_DIR" bash "$hook" 2>&1)
  rc=$?
  expect_code 0 "$rc" "registered Kimi hook invocation did not exit zero"
  [ -z "$out" ] || fail "registered Kimi hook invocation printed output: $out"
  assert_present "$target" "registered Kimi hook invocation did not touch the turn-end marker"

  rm "$target"
  fakebin=$(fm_fakebin "$CASE_DIR/no-jq")
  ln -s "$(command -v bash)" "$fakebin/bash"
  out=$(printf '{"hook_event_name":"Stop","session_id":"crew","cwd":"%s","stop_hook_active":false}\n' "$WT_DIR" \
    | HOME="$HOME_DIR" PATH="$fakebin" "$hook" 2>&1)
  rc=$?
  expect_code 0 "$rc" "Kimi hook without jq must still exit zero"
  [ -z "$out" ] || fail "Kimi hook without jq printed output: $out"
  assert_absent "$target" "Kimi hook without jq touched the turn-end marker"
  pass "Kimi hook stays silent and inert without a Firstmate registry token"
}

test_kimi_spawn_refuses_unsafe_global_config_before_pane_creation() {
  local id rec out rc
  id=kimi-config-refuse-z7
  rec=$(make_spawn_case config-refuse "$id")
  read_spawn_record "$rec"
  printf '[malformed\n' > "$HOME_DIR/.kimi-code/config.toml"
  rc=0
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "Kimi spawn accepted malformed global config"
  assert_contains "$out" "malformed TOML" "Kimi spawn omitted the concrete config refusal"
  if grep -Eq '(^| )new-(session|window)( |$)' "$CASE_DIR/tmux-calls.log"; then
    fail "unsafe Kimi config refusal created a tmux container or pane"
  fi
  pass "fm-spawn: unsafe Kimi global config refuses before pane creation"
}

test_kimi_teardown_removes_pointer_and_registry_token() {
  local id rec out rc token launch_dir foreign_dir
  id=kimi-teardown-z8
  rec=$(make_spawn_case teardown "$id")
  read_spawn_record "$rec"
  launch_dir=$(kimi_launch_dir "$id" "$HOME_DIR")
  KIMI_RUNTIME_LAUNCH_DIR=$launch_dir
  foreign_dir="/tmp/fm-$id+zzzzzzzz"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "Kimi spawn should succeed before teardown"
  token=$(sed -n 's/^token=//p' "$WT_DIR/.fm-kimi-turnend")
  mkdir -p "$foreign_dir"
  printf 'other home\n' > "$foreign_dir/launch.sh"

  HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$TEARDOWN" "$id" --force >/dev/null 2>&1 || fail "Kimi teardown failed"
  assert_absent "$WT_DIR/.fm-kimi-turnend" "Kimi token pointer survived teardown"
  assert_absent "$HOME_DIR/.kimi-code/fm-turn-end.d/$token" "Kimi registry token survived teardown"
  assert_absent "$HOME_DIR/state/$id.kimi-turnend-token" "Kimi token state survived teardown"
  assert_absent "$launch_dir" "Kimi staged launch directory survived teardown"
  if [ ! -f "$foreign_dir/launch.sh" ]; then
    rm -rf "$foreign_dir"
    fail "teardown removed another home's staged launch directory"
  fi
  rm -rf "$foreign_dir"
  pass "fm-teardown: Kimi task pointer and registry token are removed"
}

test_kimi_falls_back_to_expanded_home_binary() {
  local id rec out rc launch fallback
  id=kimi-fallback-z4
  rec=$(make_spawn_case fallback "$id")
  read_spawn_record "$rec"
  rm "$FAKEBIN_DIR/kimi"
  fallback="$HOME_DIR/.kimi-code/bin/kimi"
  mkdir -p "$(dirname "$fallback")"
  fm_fake_exit0 "$(dirname "$fallback")" kimi
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "Kimi HOME fallback spawn should succeed"
  launch=$(cat "$CASE_DIR/launch.log")
  [ "$launch" = "export COMPACT_ADVISER_DISABLE=1; $(ai_trailer_hooks_prefix "$HOME_DIR" "$id")env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI '$fallback' --auto" ] \
    || fail "Kimi fallback did not expand HOME into an absolute executable: $launch"
  pass "fm-spawn: Kimi fallback expands the active HOME"
}

test_kimi_missing_binary_refuses_before_pane_creation() {
  local id rec out rc fallback
  id=kimi-missing-z5
  rec=$(make_spawn_case missing "$id")
  read_spawn_record "$rec"
  rm "$FAKEBIN_DIR/kimi"
  fallback="$HOME_DIR/.kimi-code/bin/kimi"
  rc=0
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "missing Kimi executable should refuse the spawn"
  assert_contains "$out" "searched PATH for 'kimi'" "missing Kimi diagnostic omitted PATH"
  assert_contains "$out" "fallback '$fallback'" "missing Kimi diagnostic omitted expanded fallback"
  if grep -Eq '(^| )new-(session|window)( |$)' "$CASE_DIR/tmux-calls.log"; then
    fail "missing Kimi executable created a tmux container or pane"
  fi
  pass "fm-spawn: missing Kimi executable refuses before pane creation"
}

test_kimi_unconfirmed_delivery_fails_loudly() {
  local id rec out rc
  id=kimi-drop-z2
  rec=$(make_spawn_case drop "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_KIMI_DELIVERY=no run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "an unconfirmed kimi delivery should fail"
  assert_contains "$out" "kimi brief pointer delivery was not confirmed" \
    "unconfirmed kimi delivery lacked a loud diagnostic"
  assert_grep 'failed: kimi brief pointer delivery was not confirmed' <(sed -E 's/ \[at=[0-9]+\]//' "$HOME_DIR/state/$id.status") \
    "unconfirmed kimi delivery did not leave a supervisor-visible failure"
  pass "fm-spawn: kimi treats a silent pointer drop as a failed spawn"
}

test_kimi_readiness_gate_precedes_pointer() {
  local id rec out rc
  id=kimi-not-ready-z3
  rec=$(make_spawn_case not-ready "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_KIMI_READY=no run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "kimi spawn without a ready signal should fail"
  assert_contains "$out" "kimi did not show a verified ready signal" \
    "kimi readiness failure lacked a loud diagnostic"
  [ ! -s "$CASE_DIR/pointer.log" ] || fail "kimi pointer was sent before readiness"
  jq -e --arg id "$id" 'any(.endpoints[]; .id == $id)' \
    "$HOME_DIR/state/home-summary.json" >/dev/null \
    || fail "kimi readiness failure omitted its durable endpoint from the home summary"
  pass "fm-spawn: kimi never sends the brief pointer before an observable ready signal"
}

test_kimi_fresh_worktree_trust_is_answered_and_verified() {
  local id rec out rc
  id=kimi-trust-z9
  rec=$(make_spawn_case trust "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_KIMI_READY_POLLS=3 FM_FAKE_KIMI_TRUST=fresh run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  expect_code 0 "$rc" "fresh Kimi trust dialog should advance into verified delivery"
  assert_contains "$out" "spawned $id harness=kimi" \
    "Kimi spawn did not continue after the trust dialog cleared"
  [ "$(wc -l < "$CASE_DIR/trust-enter.log" | tr -d ' ')" = 1 ] \
    || fail "a Kimi trust dialog that cleared on its first answer was answered again"
  assert_grep "Read the brief at " "$CASE_DIR/pointer.log" \
    "Kimi brief pointer was not delivered after trust and readiness verification"
  pass "fm-spawn: a fresh Kimi worktree answers the exact trust dialog once and verifies advancement"
}

test_kimi_swallowed_trust_enter_is_retried_until_the_dialog_clears() {
  local id rec out rc
  id=kimi-trust-swallow-y3
  rec=$(make_spawn_case trust-swallow "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_KIMI_READY_POLLS=5 FM_FAKE_KIMI_TRUST=fresh FM_FAKE_KIMI_TRUST_CLEARS=after-second run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  expect_code 0 "$rc" "a swallowed first trust Enter should be retried into a verified spawn"
  assert_contains "$out" "spawned $id harness=kimi" \
    "Kimi spawn did not recover from a swallowed trust keypress"
  [ "$(wc -l < "$CASE_DIR/trust-enter.log" | tr -d ' ')" = 2 ] \
    || fail "Kimi trust dialog was not re-answered exactly until it cleared"
  assert_grep "Read the brief at " "$CASE_DIR/pointer.log" \
    "Kimi brief pointer was not delivered after the retried trust answer"
  pass "fm-spawn: a swallowed Kimi trust keypress is re-sent until the dialog clears"
}

test_kimi_banner_before_the_dialog_paints_does_not_pass_readiness() {
  local id rec out rc
  id=kimi-trust-late-y5
  rec=$(make_spawn_case trust-late "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_KIMI_READY_POLLS=5 FM_FAKE_KIMI_TRUST=late run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  expect_code 0 "$rc" "a banner captured before the dialog painted should wait, then trust and deliver"
  assert_contains "$out" "spawned $id harness=kimi" \
    "Kimi spawn did not survive a banner captured before the trust dialog painted"
  [ "$(wc -l < "$CASE_DIR/trust-enter.log" | tr -d ' ')" = 1 ] \
    || fail "Kimi trust dialog painted after the banner was not answered exactly once"
  [ "$(wc -l < "$CASE_DIR/pointer.log" | tr -d ' ')" = 1 ] \
    || fail "Kimi brief pointer was not typed exactly once, after the dialog cleared"
  assert_grep "Read the brief at " "$CASE_DIR/pointer.log" \
    "Kimi brief pointer was not delivered once the late dialog cleared"
  pass "fm-spawn: a Kimi banner captured before the trust dialog paints does not read as ready"
}

test_kimi_answered_dialog_left_in_history_does_not_restart_the_answer() {
  local id rec out rc
  id=kimi-trust-history-y6
  rec=$(make_spawn_case trust-history "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_KIMI_READY_POLLS=3 FM_FAKE_KIMI_TRUST=fresh FM_FAKE_KIMI_HISTORY_KEEPS_DIALOG=yes run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  expect_code 0 "$rc" "an answered trust dialog still in scrollback should not block the spawn"
  assert_contains "$out" "spawned $id harness=kimi" \
    "Kimi spawn did not complete with the answered trust dialog still in scrollback"
  case "$out" in
    *"did not clear"*) fail "Kimi reported a stuck trust dialog that had already cleared" ;;
  esac
  [ "$(wc -l < "$CASE_DIR/trust-enter.log" | tr -d ' ')" = 1 ] \
    || fail "Kimi answered the trust dialog again from its scrollback copy"
  assert_grep "Read the brief at " "$CASE_DIR/pointer.log" \
    "Kimi brief pointer was not delivered past the scrollback copy of the dialog"
  pass "fm-spawn: an answered Kimi trust dialog left in scrollback neither re-answers nor fails the spawn"
}

test_kimi_blank_viewport_frame_costs_only_its_poll() {
  local id rec out rc
  id=kimi-trust-blank-y7
  rec=$(make_spawn_case trust-blank "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_KIMI_READY_POLLS=4 FM_FAKE_KIMI_TRUST=fresh FM_FAKE_KIMI_BLANK_AFTER_TRUST=yes \
    FM_FAKE_KIMI_HISTORY_KEEPS_DIALOG=yes run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  expect_code 0 "$rc" "a blank viewport frame should cost one poll, not the spawn"
  assert_contains "$out" "spawned $id harness=kimi" \
    "Kimi spawn did not survive a blank viewport frame after the trust answer"
  case "$out" in
    *"did not clear"*) fail "a blank viewport frame was reported as a stuck trust dialog" ;;
  esac
  [ "$(wc -l < "$CASE_DIR/trust-enter.log" | tr -d ' ')" = 1 ] \
    || fail "Kimi answered the trust dialog again after a blank viewport frame"
  [ ! -s "$CASE_DIR/stray-enter.log" ] \
    || fail "Kimi sent a stray Enter into the live composer after a blank viewport frame"
  assert_grep "Read the brief at " "$CASE_DIR/pointer.log" \
    "Kimi brief pointer was not delivered after the blank viewport frame"
  pass "fm-spawn: a blank Kimi viewport frame costs its poll and nothing else"
}

test_kimi_refuses_a_backend_without_a_viewport_capture() {
  local id rec out rc
  id=kimi-no-viewport-y8
  rec=$(make_spawn_case no-viewport "$id")
  read_spawn_record "$rec"
  fm_fake_exit0 "$FAKEBIN_DIR" cmux
  rc=0
  out=$(FM_BACKEND=cmux run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a Kimi spawn on a backend without a viewport capture should refuse"
  assert_contains "$out" "backend 'cmux' has no verified viewport-bounded capture" \
    "Kimi refusal did not name the backend and the missing viewport capability"
  [ ! -s "$CASE_DIR/trust-enter.log" ] \
    || fail "Kimi pressed Enter on a backend it cannot read the viewport of"
  [ ! -s "$CASE_DIR/launch.log" ] \
    || fail "Kimi was launched on a backend without a viewport capture"
  pass "fm-spawn: Kimi refuses a backend that cannot read the viewport, before launching"
}

test_kimi_answers_a_trust_dialog_with_a_wrapped_hint() {
  local id rec out rc
  id=kimi-trust-wrapped-y9
  rec=$(make_spawn_case trust-wrapped "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_KIMI_READY_POLLS=3 FM_FAKE_KIMI_TRUST=wrapped run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  expect_code 0 "$rc" "a trust dialog whose hint wrapped in a narrow pane should be answered"
  assert_contains "$out" "spawned $id harness=kimi" \
    "Kimi spawn did not survive a trust dialog with a wrapped navigation hint"
  [ "$(wc -l < "$CASE_DIR/trust-enter.log" | tr -d ' ')" = 1 ] \
    || fail "Kimi did not answer a trust dialog with a wrapped hint exactly once"
  assert_grep "Read the brief at " "$CASE_DIR/pointer.log" \
    "Kimi brief pointer was not delivered after the wrapped-hint dialog cleared"
  pass "fm-spawn: a Kimi trust dialog with its hint wrapped across rows is answered normally"
}

test_kimi_blank_frame_between_banners_restarts_the_ready_count() {
  local id rec out rc
  id=kimi-trust-blink-z4
  rec=$(make_spawn_case trust-blink "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_KIMI_READY_POLLS=6 FM_FAKE_KIMI_TRUST=blink run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  expect_code 0 "$rc" "banners split by a blank frame should not read as two ready captures"
  assert_contains "$out" "spawned $id harness=kimi" \
    "Kimi spawn did not wait out a blank frame before the trust dialog painted"
  [ "$(wc -l < "$CASE_DIR/trust-enter.log" | tr -d ' ')" = 1 ] \
    || fail "Kimi did not answer the trust dialog that painted after the blank frame"
  [ "$(wc -l < "$CASE_DIR/pointer.log" | tr -d ' ')" = 1 ] \
    || fail "Kimi brief pointer was typed before the trust dialog painted"
  pass "fm-spawn: a blank Kimi frame between banners restarts the two-capture ready count"
}

test_kimi_failed_viewport_read_fails_readiness_at_once() {
  local id rec out rc
  id=kimi-viewport-fail-z5
  rec=$(make_spawn_case viewport-fail "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_KIMI_READY_POLLS=3 FM_FAKE_TMUX_VISIBLE_FAILS=yes FM_FAKE_KIMI_TRUST=fresh run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a Kimi spawn whose viewport read fails should fail"
  assert_contains "$out" "could not read the visible viewport of backend 'tmux'" \
    "failed Kimi viewport read was reported as something other than a capture failure"
  [ ! -s "$CASE_DIR/trust-enter.log" ] \
    || fail "Kimi pressed Enter without being able to read the viewport"
  [ ! -s "$CASE_DIR/pointer.log" ] || fail "Kimi pointer was sent without a readable viewport"
  pass "fm-spawn: a failed Kimi viewport read fails readiness with the backend named"
}

test_kimi_partial_trust_dialog_blocks_the_ready_verdict() {
  local id rec out rc
  id=kimi-trust-partial-y4
  rec=$(make_spawn_case trust-partial "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_KIMI_TRUST=partial run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a banner above an unanswered trust dialog should not pass readiness"
  assert_contains "$out" "trust dialog text stayed on screen without the complete dialog" \
    "partially rendered Kimi trust dialog lacked its concrete failure reason"
  [ ! -s "$CASE_DIR/pointer.log" ] \
    || fail "Kimi pointer was sent while trust dialog markers were still on screen"
  [ ! -s "$CASE_DIR/trust-enter.log" ] \
    || fail "Kimi answered a trust dialog it could not fully read"
  pass "fm-spawn: Kimi refuses the ready verdict while trust dialog markers remain"
}

test_kimi_stuck_trust_dialog_fails_before_delivery() {
  local id rec out rc
  id=kimi-trust-stuck-y1
  rec=$(make_spawn_case trust-stuck "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_KIMI_TRUST=fresh FM_FAKE_KIMI_TRUST_CLEARS=no run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a Kimi trust dialog that never clears should fail"
  assert_contains "$out" "kimi trust dialog did not clear after selecting 'Trust this folder'" \
    "stuck Kimi trust dialog lacked its concrete failure reason"
  assert_contains "$out" "navigation hint, selected 'Trust this folder'" \
    "stuck Kimi trust diagnostic did not name the observed dialog signals"
  [ "$(wc -l < "$CASE_DIR/trust-enter.log" | tr -d ' ')" -gt 1 ] \
    || fail "stuck Kimi trust dialog was not re-answered while it stayed on screen"
  [ ! -s "$CASE_DIR/pointer.log" ] || fail "Kimi pointer was sent through a stuck trust dialog"
  assert_grep 'failed: kimi trust dialog did not clear' <(sed -E 's/ \[at=[0-9]+\]//' "$HOME_DIR/state/$id.status") \
    "stuck Kimi trust dialog did not leave a supervisor-visible failure"
  pass "fm-spawn: a Kimi trust dialog must visibly clear before brief delivery"
}

test_kimi_trust_detection_requires_the_complete_dialog() {
  local id rec out rc
  id=kimi-trust-decoy-y2
  rec=$(make_spawn_case trust-decoy "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_KIMI_TRUST=decoy run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "an incomplete Kimi trust lookalike should not pass readiness"
  assert_contains "$out" "trust dialog text stayed on screen without the complete dialog" \
    "incomplete Kimi trust lookalike did not report the unanswerable dialog text"
  [ ! -s "$CASE_DIR/trust-enter.log" ] \
    || fail "Kimi answered an incomplete trust lookalike with Enter"
  [ ! -s "$CASE_DIR/pointer.log" ] || fail "Kimi pointer was sent through a trust lookalike"
  pass "fm-spawn: Kimi trust detection requires every observed dialog signal"
}

test_kimi_detection_uses_ancestry_after_markers() {
  local dir fakebin cfg out
  dir="$TMP_ROOT/detection"
  fakebin=$(fm_fakebin "$dir")
  cfg="$dir/config"
  mkdir -p "$cfg"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field=
pid=
prev=
for arg in "$@"; do
  [ "$prev" = -o ] && field=$arg
  [ "$prev" = -p ] && pid=$arg
  prev=$arg
done
case "$field:$pid" in
  comm=:4242) printf '/opt/kimi/bin/kimi\n' ;;
  comm=:*) printf '/bin/bash\n' ;;
  ppid=:4242) printf '1\n' ;;
  ppid=:*) printf '4242\n' ;;
  args=:*) printf 'bash\n' ;;
esac
SH
  chmod +x "$fakebin/ps"

  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI \
    PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = kimi ] || fail "kimi ancestry detection returned '$out'"
  # Kimi publishes no identity marker, so an inherited CLAUDECODE used to rename
  # it outright. A structural kimi ancestor now outranks that marker;
  # tests/fm-harness-precedence.test.sh owns the general boundary.
  out=$(env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI \
    CLAUDECODE=1 PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = kimi ] || fail "an inherited CLAUDECODE renamed markerless kimi, got '$out'"
  pass "fm-harness: markerless kimi keeps its ancestry identity under an inherited marker"
}

test_kimi_session_lock_identity() {
  local home fakebin out
  home="$TMP_ROOT/session-lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/session-lock-fake")
  mkdir -p "$home/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/opt/kimi/bin/kimi'; exit 0 ;;
  *"args="*) printf '%s\n' 'kimi'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"

  FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-lock.sh" \
    || fail "fm-lock did not acquire from Kimi ancestry"
  case "$(cat "$home/state/.lock")" in
    ''|*[!0-9]*) fail "fm-lock did not record the Kimi harness ancestor" ;;
  esac
  printf '%s\n' "$$" > "$home/state/.lock"
  out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" \
    "fm-lock did not recognize Kimi as a live holder"
  pass "fm-lock recognizes Kimi ancestry and live lock holders"
}

test_kimi_busy_signature_is_scoped_to_spinner_lines() {
  local capture
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-tmux-lib.sh"
  unset FM_BUSY_REGEX
  capture="$TMP_ROOT/busy-pane"
  tmux() {
    case "${1:-}" in
      capture-pane) cat "$capture" ;;
      *) return 0 ;;
    esac
  }
  # These fixtures reproduce the observed spinner shape rather than byte-exact
  # transcriptions. Leading whitespace is deliberately varied; separator whitespace
  # follows the captured contract.
  local phase
  for phase in 🌑 🌒 🌓 🌔 🌕 🌖 🌗 🌘; do
    printf '  %s · Tip: Kimi is working\n│ > │\n' "$phase" > "$capture"
    fm_pane_is_busy fake kimi || fail "Kimi spinner phase $phase was not recognized as busy"
  done
  printf 'ordinary response ending with 🌕\n│ > │\n' > "$capture"
  if fm_pane_is_busy fake kimi; then
    fail "a moon outside Kimi's spinner-line shape was misread as busy"
  fi
  printf '🌕 Full moon details\n│ > │\n' > "$capture"
  if fm_pane_is_busy fake kimi; then
    fail "moon-led Kimi output without the middot separator was misread as busy"
  fi
  printf '  🌗 · Tip: /plugins: manage plugins ...\n│ > │\n' > "$capture"
  if fm_pane_is_busy fake codex; then
    fail "Kimi's real spinner signature leaked into another harness"
  fi
  printf 'tip: ctrl+c: cancel\n│ > │\n' > "$capture"
  if fm_pane_is_busy fake kimi; then
    fail "kimi's independently rotating idle tip was misread as busy"
  fi
  printf 'Ctrl+c:cancel\n│ > │\n' > "$capture"
  if fm_pane_is_busy fake kimi; then
    fail "Grok's exact busy token leaked into Kimi's harness-scoped matcher"
  fi
  printf 'auto  K2.7 Coding thinking  /some/path\n│ > │\n' > "$capture"
  if fm_pane_is_busy fake kimi; then
    fail "Kimi's idle thinking-effort status label was misread as busy"
  fi
  pass "busy detection: real Kimi moon-plus-middot captures require its harness while idle labels stay idle"
}

test_watcher_never_classifies_kimi_from_its_spinner() (
  local state="$TMP_ROOT/watch-state" busy_capture='  🌑 · Tip: ask Kimi to schedule tasks, e.g. "remind me at 5pm"'
  mkdir -p "$state"
  printf 'window=fake\nharness=kimi\n' > "$state/kimi-watch.meta"
  unset FM_BUSY_REGEX
  FM_HOME="$TMP_ROOT/watch-home"
  FM_STATE_OVERRIDE="$state"
  export FM_HOME FM_STATE_OVERRIDE
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-watch.sh"
  # shellcheck disable=SC2329 # Runtime override called by the sourced watcher.
  fm_backend_busy_state() { printf 'unknown'; }
  # Standalone Kimi has no verified semantic busy source, so it classifies
  # unknown - and unknown is never working. Its moon-phase spinner is
  # deliberately not a state source: the approved redesign forbids inventing a
  # Kimi UI signature, and that glyph set is locale- and emoji-font-sensitive.
  if window_is_busy fake "$busy_capture"; then
    fail "fm-watch classified a Kimi task busy from its spinner instead of unknown"
  fi
  [ "$(fm_busy_classify tmux fake kimi kimi-watch "$state" "$busy_capture")" = "unknown kimi-unverified" ] \
    || fail "a Kimi task must classify unknown kimi-unverified"
  printf 'window=fake\nharness=codex\n' > "$state/kimi-watch.meta"
  if window_is_busy fake "$busy_capture"; then
    fail "fm-watch applied Kimi's spinner to a recorded Codex task"
  fi
  printf 'window=fake\nharness=grok\n' > "$state/kimi-watch.meta"
  if window_is_busy fake "$busy_capture"; then
    fail "Kimi's spinner classified a recorded Grok task through its isolated fallback"
  fi
  window_is_busy fake 'Ctrl+c:cancel' \
    || fail "Grok's own verified token must still classify a recorded Grok task busy"
  pass "fm-watch classifies Kimi as unknown rather than from its spinner, and Grok's fallback stays isolated"
)

test_kimi_bordered_prompt_needs_no_override() {
  local out
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-composer-lib.sh"
  out=$(fm_composer_classify_content 1 '>')
  [ "$out" = empty ] || fail "kimi's bordered bare > composer should read empty, got '$out'"
  out=$(fm_composer_classify_content 0 '>')
  [ "$out" = unknown ] || fail "an unbordered dead-shell > must stay unknown, got '$out'"
  pass "composer classifier: kimi's existing bordered > shape is already safe without an override"
}

# Kimi's store is one file per trusted directory, so a pre-registered spawn is
# indistinguishable from a hand-accepted dialog only when the record carries
# exactly the byte shape this pinned against the live 0.42.0 store: the
# wd_<basename>_<hash> name, compact single-line JSON with no trailing
# newline, a millisecond trustedAt, and mode 0600.
test_kimi_trust_writes_the_verified_store_record_shape() {
  local rec store file out first_copy foreign
  rec=$(make_trust_case record)
  read_trust_case "$rec"
  store=$(trust_store "$TRUST_HOME")
  out=$(run_trust "$TRUST_HOME" "$TRUST_WT" "$TRUST_PROJ")
  expect_code 0 $? "a fresh linked worktree must be trusted: $out"
  assert_contains "$out" "trusted: $TRUST_WT" "registration did not report the trusted path"
  assert_kimi_trusted "$store" "$TRUST_WT" "the worktree was not recorded as trusted"
  file=$(kimi_record_path "$store" "$TRUST_WT")
  node -e '
    const fs = require("node:fs");
    const text = fs.readFileSync(process.argv[1], "utf8");
    const parsed = JSON.parse(text);
    const ok = parsed.root === process.argv[2]
      && Number.isInteger(parsed.trustedAt)
      && parsed.trustedAt > 1e12
      && parsed.trustedAt <= Date.now() + 1000
      && !text.includes("\n")
      && JSON.stringify(parsed) === text;
    process.exit(ok ? 0 : 1);
  ' "$file" "$TRUST_WT" \
    || fail "the trust record is not the compact exact-shape JSON Kimi writes: $(cat "$file")"
  [ "$(file_mode "$file")" = 600 ] \
    || fail "the trust record must be mode 0600 like every Kimi-owned record"
  cp "$file" "$TRUST_CASE_DIR/first-record"
  out=$(run_trust "$TRUST_HOME" "$TRUST_WT" "$TRUST_PROJ")
  expect_code 0 $? "a repeat registration must succeed: $out"
  cmp -s "$TRUST_CASE_DIR/first-record" "$file" \
    || fail "a repeat registration rewrote a record this script does not own"
  foreign="$store/wd_elsewhere_000000000000"
  printf '%s' '{"root":"/elsewhere","trustedAt":1}' > "$foreign"
  out=$(run_trust "$TRUST_HOME" "$TRUST_WT" "$TRUST_PROJ")
  expect_code 0 $? "a registration must succeed beside an unrelated record: $out"
  cmp -s "$foreign" "$foreign" || true
  [ "$(cat "$foreign")" = '{"root":"/elsewhere","trustedAt":1}' ] \
    || fail "a registration disturbed an unrelated record in Kimi's store"
  pass "fm-kimi-trust.sh: writes the exact record shape Kimi writes, idempotently, preserving foreign records"
}

# Whether the running CLI hashes the pane's logical or resolved path is not
# verified, so both forms are registered when they differ, exactly as
# bin/fm-agy-trust.sh does; identical forms must collapse to one record.
test_kimi_trust_registers_the_logical_and_resolved_paths() {
  local rec store link out count
  rec=$(make_trust_case dual-path)
  read_trust_case "$rec"
  store=$(trust_store "$TRUST_HOME")
  link="$TRUST_CASE_DIR/wt-link"
  ln -s "$TRUST_WT" "$link"
  out=$(run_trust "$TRUST_HOME" "$link" "$TRUST_PROJ")
  expect_code 0 $? "a symlinked worktree must be trusted: $out"
  assert_kimi_trusted "$store" "$TRUST_WT" "the resolved worktree path was not registered"
  assert_kimi_trusted "$store" "$TRUST_CASE_DIR/wt-link" "the logical pane path was not registered alongside it"
  count=$(find "$store" -maxdepth 1 -type f | wc -l | tr -d '[:space:]')
  [ "$count" -eq 2 ] || fail "two path forms must leave exactly two records, found $count"
  out=$(run_trust "$TRUST_HOME" "$link" "$TRUST_PROJ")
  expect_code 0 $? "a repeat registration must succeed: $out"
  count=$(find "$store" -maxdepth 1 -type f | wc -l | tr -d '[:space:]')
  [ "$count" -eq 2 ] || fail "a repeat registration duplicated a record ($count files)"
  pass "fm-kimi-trust.sh: registers the logical and resolved paths without duplicating either"
}

test_kimi_trust_refuses_out_of_scope_paths() {
  local rec store out rc plain sub other other_wt
  rec=$(make_trust_case scope)
  read_trust_case "$rec"
  store=$(trust_store "$TRUST_HOME")

  rc=0; out=$(run_trust "$TRUST_HOME" "$TRUST_PROJ" "$TRUST_PROJ") || rc=$?
  [ "$rc" -ne 0 ] || fail "the primary checkout must be refused"
  assert_contains "$out" "primary checkout" "primary-checkout refusal lacked its reason"
  assert_kimi_not_trusted "$store" "$TRUST_PROJ" "a refused primary checkout was registered"

  rc=0; out=$(run_trust "$TRUST_HOME" "$TRUST_HOME" "$TRUST_PROJ") || rc=$?
  [ "$rc" -ne 0 ] || fail "the home directory must be refused"
  assert_contains "$out" "home directory" "home-directory refusal lacked its reason"
  assert_kimi_not_trusted "$store" "$TRUST_HOME" "a refused home directory was registered"

  plain="$TRUST_CASE_DIR/plain"; mkdir -p "$plain"
  rc=0; out=$(run_trust "$TRUST_HOME" "$plain" "$TRUST_PROJ") || rc=$?
  [ "$rc" -ne 0 ] || fail "a plain directory must be refused"
  assert_contains "$out" "not inside a git repository" "plain-directory refusal lacked its reason"
  assert_kimi_not_trusted "$store" "$plain" "a refused plain directory was registered"

  sub="$TRUST_WT/sub"; mkdir -p "$sub"
  rc=0; out=$(run_trust "$TRUST_HOME" "$sub" "$TRUST_PROJ") || rc=$?
  [ "$rc" -ne 0 ] || fail "a worktree subdirectory must be refused"
  assert_contains "$out" "not a worktree root" "subdirectory refusal lacked its reason"
  assert_kimi_not_trusted "$store" "$sub" "a refused worktree subdirectory was registered"

  other="$TRUST_CASE_DIR/other-project"
  other_wt="$TRUST_CASE_DIR/other-wt"
  fm_git_worktree "$other" "$other_wt" wt-other
  rc=0; out=$(run_trust "$TRUST_HOME" "$other_wt" "$TRUST_PROJ") || rc=$?
  [ "$rc" -ne 0 ] || fail "another project's worktree must be refused"
  assert_contains "$out" "not a worktree of project" "foreign-project refusal lacked its reason"
  assert_kimi_not_trusted "$store" "$other_wt" "a foreign project's worktree was registered"

  rc=0; out=$(run_trust "$TRUST_HOME" "$TRUST_CASE_DIR/missing" "$TRUST_PROJ") || rc=$?
  [ "$rc" -ne 0 ] || fail "a nonexistent path must be refused"
  assert_contains "$out" "not an accessible directory" "missing-path refusal lacked its reason"

  pass "fm-kimi-trust.sh: refuses every out-of-scope path"
}

# CDPATH would redirect a relative cd into an unrelated directory and the git
# env overrides make a primary checkout report a linked worktree's git dir, so
# both must fail to move the boundary the refusals above rest on.
test_kimi_trust_scope_survives_hostile_caller_environment() {
  local rec store out rc
  rec=$(make_trust_case hostile-env)
  read_trust_case "$rec"
  store=$(trust_store "$TRUST_HOME")
  mkdir -p "$TRUST_CASE_DIR/decoy/.git"
  CDPATH="$TRUST_CASE_DIR/decoy" \
    GIT_DIR=$(git -C "$TRUST_WT" rev-parse --absolute-git-dir) \
    GIT_WORK_TREE=$TRUST_PROJ \
    out=$(run_trust "$TRUST_HOME" "$TRUST_PROJ" "$TRUST_PROJ") || rc=$?
  unset CDPATH GIT_DIR GIT_WORK_TREE
  [ "${rc:-0}" -ne 0 ] || fail "hostile caller environment let the primary checkout through: $out"
  assert_contains "$out" "primary checkout" "the refusal did not name the primary checkout"
  assert_kimi_not_trusted "$store" "$TRUST_PROJ" "hostile caller environment let the primary checkout be trusted"
  pass "fm-kimi-trust.sh: the scope refusal survives a hostile caller environment"
}

# The store is Kimi's, so a record that exists under the name this registration
# would use but names a different root - a corrupted entry or a hash collision
# - must refuse the whole registration rather than overwrite bytes this script
# does not own.
test_kimi_trust_refuses_a_foreign_record_under_the_same_name() {
  local rec store file out rc before
  rec=$(make_trust_case foreign-record)
  read_trust_case "$rec"
  store=$(trust_store "$TRUST_HOME")
  mkdir -p "$store"
  file=$(kimi_record_path "$store" "$TRUST_WT")
  printf '%s' '{"root":"/somewhere/else","trustedAt":1}' > "$file"
  before=$(cat "$file")
  rc=0; out=$(run_trust "$TRUST_HOME" "$TRUST_WT" "$TRUST_PROJ") || rc=$?
  [ "$rc" -ne 0 ] || fail "a record naming another root must be refused: $out"
  assert_contains "$out" "refusing to overwrite" "the refusal did not name the non-ownership reason"
  [ "$(cat "$file")" = "$before" ] || fail "the foreign record was overwritten despite the refusal"
  printf '%s' 'not json' > "$file"
  before=$(cat "$file")
  rc=0; out=$(run_trust "$TRUST_HOME" "$TRUST_WT" "$TRUST_PROJ") || rc=$?
  [ "$rc" -ne 0 ] || fail "an unparseable record must be refused: $out"
  [ "$(cat "$file")" = "$before" ] || fail "the unparseable record was rewritten"
  pass "fm-kimi-trust.sh: refuses a foreign or broken record under the name it would write"
}

# Registering trust is what keeps a worker off the dialog, so a missing node
# refuses rather than degrades: proceeding would launch the worker straight
# into the dialog this control exists to remove.
test_kimi_trust_missing_node_is_refused() {
  local rec store out rc bindir
  rec=$(make_trust_case no-node)
  read_trust_case "$rec"
  store=$(trust_store "$TRUST_HOME")
  bindir=$(node_free_path "$TRUST_CASE_DIR")
  rc=0; out=$(PATH="$bindir" HOME="$TRUST_HOME" "$TRUST" "$TRUST_WT" "$TRUST_PROJ" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a missing node must refuse rather than degrade: $out"
  assert_contains "$out" "node" "the refusal did not name the missing interpreter"
  assert_kimi_not_trusted "$store" "$TRUST_WT" "a worktree was registered without an interpreter to write the store"
  case "$out" in
    *"trusted:"*) fail "a registration was claimed although none could be written: $out" ;;
  esac
  pass "fm-kimi-trust.sh: a missing node is refused rather than degraded"
}

# The seed is the whole security boundary for home-level trust: both seeded
# shapes are trusted, and every path that is not a home seeded for THIS
# secondmate is refused and left unregistered.
test_kimi_trust_secondmate_home_modes() {
  local rec store home target out rc
  rec=$(make_trust_case secondmate)
  read_trust_case "$rec"
  store=$(trust_store "$TRUST_HOME")

  home="$TRUST_CASE_DIR/sm-clone"
  seed_secondmate_home "$home" clone-n1 clone
  out=$(run_home_trust "$home" "$TRUST_HOME" clone-n1)
  expect_code 0 $? "a standalone-clone secondmate home must be trusted: $out"
  assert_kimi_trusted "$store" "$home" "the standalone-clone home was not registered"

  home="$TRUST_CASE_DIR/sm-worktree"
  seed_secondmate_home "$home" leased-n1 worktree
  out=$(run_home_trust "$home" "$TRUST_HOME" leased-n1)
  expect_code 0 $? "a leased-worktree secondmate home must be trusted: $out"
  assert_kimi_trusted "$store" "$home" "the leased-worktree home was not registered"

  target="$TRUST_CASE_DIR/plain"
  mkdir -p "$target"
  rc=0; out=$(run_home_trust "$target" "$TRUST_HOME" plain-n1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a plain directory must be refused"
  assert_contains "$out" "no .fm-secondmate-home marker" "the refusal did not name the missing marker"
  assert_kimi_not_trusted "$store" "$target" "a plain directory was registered"

  target="$TRUST_CASE_DIR/other-mate"
  seed_secondmate_home "$target" other-n1 clone
  rc=0; out=$(run_home_trust "$target" "$TRUST_HOME" wanted-n1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a home marked for another secondmate must be refused"
  assert_contains "$out" "other-n1" "the refusal did not name the id the home is marked for"
  assert_kimi_not_trusted "$store" "$target" "a home marked for another secondmate was registered"

  target="$TRUST_CASE_DIR/linked-marker"
  seed_secondmate_home "$target" linked-n1 clone
  rm -f "$target/.fm-secondmate-home"
  printf 'linked-n1\n' > "$TRUST_CASE_DIR/planted-id"
  ln -sf "$TRUST_CASE_DIR/planted-id" "$target/.fm-secondmate-home"
  rc=0; out=$(run_home_trust "$target" "$TRUST_HOME" linked-n1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a symlinked marker must be refused"
  assert_contains "$out" "symlink" "the refusal did not name the symlinked marker"
  assert_kimi_not_trusted "$store" "$target" "a home whose marker is a symlink was registered"

  target="$TRUST_CASE_DIR/escaping"
  seed_secondmate_home "$target" escaping-n1 clone
  rm -rf "$target/projects"
  mkdir -p "$TRUST_CASE_DIR/elsewhere"
  ln -s "$TRUST_CASE_DIR/elsewhere" "$target/projects"
  rc=0; out=$(run_home_trust "$target" "$TRUST_HOME" escaping-n1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a home whose operational directory escapes it must be refused"
  assert_contains "$out" "outside the home" "the refusal did not name the escaping directory"
  assert_kimi_not_trusted "$store" "$target" "a home whose projects/ escapes it was registered"

  target="$TRUST_CASE_DIR/user-home"
  seed_secondmate_home "$target" userhome-n1 clone
  rc=0; out=$(run_home_trust "$target" "$target" userhome-n1) || rc=$?
  [ "$rc" -ne 0 ] || fail "the user's home directory must be refused"
  assert_contains "$out" "home directory" "the refusal did not name the home directory"
  assert_kimi_not_trusted "$store" "$target" "the user's home directory was registered"
  out=$(run_home_trust "$target" "$TRUST_HOME" userhome-n1)
  expect_code 0 $? "the same seeded home must be accepted once it is not HOME: $out"

  # A secondmate home is not a linked worktree of the project, so worktree
  # mode must keep refusing it rather than widening to cover the new case.
  target="$TRUST_CASE_DIR/wrong-mode"
  seed_secondmate_home "$target" mode-n1 clone
  rc=0; out=$(run_trust "$TRUST_HOME" "$target" "$target") || rc=$?
  [ "$rc" -ne 0 ] || fail "worktree mode must still refuse a standalone-clone home"
  assert_contains "$out" "primary checkout" "the refusal did not name the primary checkout"
  assert_kimi_not_trusted "$store" "$target" "worktree mode registered a standalone-clone home"

  pass "fm-kimi-trust.sh: home-level trust covers both seeded shapes and refuses everything unseeded"
}

# The spawn half: a real fm-spawn of a kimi worker must pre-register the
# worktree in the store the launching user's kimi reads, and a registration
# that fails must refuse the spawn before any task state or launch exists,
# because the captain chose pre-registration with no dialog-answer fallback.
test_kimi_spawn_pretrusts_its_worktree() {
  local id rec out store
  id="kimi-trust-z1-$$"
  rec=$(make_spawn_case pretrust "$id")
  read_spawn_record "$rec"
  store=$(trust_store "$HOME_DIR")
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  expect_code 0 $? "a kimi spawn into a fresh worktree should succeed"
  assert_contains "$out" "spawned $id harness=kimi" "kimi spawn did not report success"
  assert_kimi_trusted "$store" "$WT_DIR" "the kimi spawn did not pre-register trust for its worktree"
  assert_grep "$FAKEBIN_DIR/kimi" "$CASE_DIR/launch.log" \
    "the launch command was not sent after the registration"
  pass "fm-spawn: a kimi spawn pre-registers its worktree before launching"
}

test_kimi_spawn_refused_when_trust_registration_fails() {
  local id rec out rc store file
  id="kimi-trust-z2-$$"
  rec=$(make_spawn_case trust-refused "$id")
  read_spawn_record "$rec"
  store=$(trust_store "$HOME_DIR")
  mkdir -p "$store"
  file=$(kimi_record_path "$store" "$WT_DIR")
  printf '%s' '{"root":"/somewhere/else","trustedAt":1}' > "$file"
  rc=0
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a spawn whose trust registration is refused must fail: $out"
  assert_contains "$out" "Kimi workspace trust" "the spawn did not report the trust refusal"
  assert_not_contains "$out" "spawned $id" "a refused registration still reported a successful spawn"
  [ "$(cat "$file")" = '{"root":"/somewhere/else","trustedAt":1}' ] \
    || fail "the refused spawn overwrote a record it does not own"
  [ ! -s "$CASE_DIR/launch.log" ] || fail "a refused spawn launched the kimi worker anyway"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn published task metadata"
  [ ! -e "/tmp/fm-$id" ] || { rm -rf "/tmp/fm-$id"; fail "a refused spawn stranded a temp root no teardown can find"; }
  pass "fm-spawn: a kimi spawn whose registration fails is refused before any launch or task state"
}

# The second directory a kimi launch starts in: a --secondmate spawn's home,
# which 0.42.0 gates behind the same dialog a fresh worktree meets.
test_kimi_secondmate_spawn_pretrusts_its_home() {
  local case_dir primary home id fakebin out store
  case_dir="$TMP_ROOT/sm-trust-spawn"
  primary="$case_dir/primary"
  home="$case_dir/fm-homes/nomistakes-k1"
  id="kimi-sm-trust-z3-$$"
  seed_secondmate_home "$home" "$id" clone
  mkdir -p "$home/data/$id"
  printf '%s\n' '# Charter' "## Captain's intent" 'Exercise secondmate dispatch.' > "$home/data/$id/brief.md"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$primary/data" "$primary/projects" "$primary/state" "$primary/config"
  touch "$primary/state/.last-watcher-beat"
  printf 'kimi\n' > "$primary/config/crew-harness"
  mkdir -p "$primary/data/$id"
  printf '%s\n' '# Charter' "## Captain's intent" 'Exercise secondmate dispatch.' > "$primary/data/$id/brief.md"
  : > "$case_dir/launch.log"
  : > "$case_dir/pointer.log"
  : > "$case_dir/kimi.state"
  : > "$case_dir/tmux-calls.log"
  store=$(trust_store "$primary")
  out=$(HOME="$primary" FM_ROOT_OVERRIDE='' FM_HOME="$primary" \
    FM_STATE_OVERRIDE="$primary/state" FM_DATA_OVERRIDE="$primary/data" \
    FM_PROJECTS_OVERRIDE="$primary/projects" FM_CONFIG_OVERRIDE="$primary/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$home" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_POINTER_LOG="$case_dir/pointer.log" \
    FM_FAKE_KIMI_STATE="$case_dir/kimi.state" \
    FM_FAKE_SWALLOWED="$case_dir/kimi.swallowed" \
    FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    FM_FAKE_BRIEF_REAL="$(cd "$home/data/$id" && pwd -P)/launch-brief.md" \
    FM_KIMI_READY_POLLS=2 FM_KIMI_DELIVERY_POLLS=2 FM_KIMI_POLL_INTERVAL=0 \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$home" --harness kimi --secondmate 2>&1)
  expect_code 0 $? "a kimi secondmate spawn into a seeded home should succeed: $out"
  assert_contains "$out" "spawned $id harness=kimi" "kimi secondmate spawn did not report success"
  assert_kimi_trusted "$store" "$home" "the kimi secondmate spawn did not pre-register trust for its home"
  assert_not_contains "$out" "could not pre-register" "a seeded home failed trust pre-registration"
  pass "fm-spawn: a kimi secondmate spawn pre-registers its home"
}

test_kimi_hook_install_is_surgical_idempotent_and_removable
test_kimi_hook_remove_preserves_owned_newline_boundary
test_kimi_hook_fails_closed_on_missing_malformed_or_partial_config
test_kimi_hook_install_refuses_without_jq
test_kimi_launch_then_send_is_verified
test_kimi_spawn_refuses_shared_task_temp_root
test_kimi_hook_is_silent_and_requires_registered_workspace_token
test_kimi_spawn_refuses_unsafe_global_config_before_pane_creation
test_kimi_teardown_removes_pointer_and_registry_token
test_kimi_falls_back_to_expanded_home_binary
test_kimi_missing_binary_refuses_before_pane_creation
test_kimi_unconfirmed_delivery_fails_loudly
test_kimi_readiness_gate_precedes_pointer
test_kimi_fresh_worktree_trust_is_answered_and_verified
test_kimi_swallowed_trust_enter_is_retried_until_the_dialog_clears
test_kimi_banner_before_the_dialog_paints_does_not_pass_readiness
test_kimi_answered_dialog_left_in_history_does_not_restart_the_answer
test_kimi_blank_viewport_frame_costs_only_its_poll
test_kimi_refuses_a_backend_without_a_viewport_capture
test_kimi_answers_a_trust_dialog_with_a_wrapped_hint
test_kimi_blank_frame_between_banners_restarts_the_ready_count
test_kimi_failed_viewport_read_fails_readiness_at_once
test_kimi_partial_trust_dialog_blocks_the_ready_verdict
test_kimi_stuck_trust_dialog_fails_before_delivery
test_kimi_trust_detection_requires_the_complete_dialog
test_kimi_detection_uses_ancestry_after_markers
test_kimi_session_lock_identity
test_kimi_busy_signature_is_scoped_to_spinner_lines
test_watcher_never_classifies_kimi_from_its_spinner
test_kimi_bordered_prompt_needs_no_override
test_kimi_trust_writes_the_verified_store_record_shape
test_kimi_trust_registers_the_logical_and_resolved_paths
test_kimi_trust_refuses_out_of_scope_paths
test_kimi_trust_scope_survives_hostile_caller_environment
test_kimi_trust_refuses_a_foreign_record_under_the_same_name
test_kimi_trust_missing_node_is_refused
test_kimi_trust_secondmate_home_modes
test_kimi_spawn_pretrusts_its_worktree
test_kimi_spawn_refused_when_trust_registration_fails
test_kimi_secondmate_spawn_pretrusts_its_home
