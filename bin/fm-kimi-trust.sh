#!/usr/bin/env bash
# Pre-register Kimi Code's workspace trust for the directory a kimi spawn is
# about to launch into - the isolated task worktree of a ship or scout
# crewmate, or the seeded home of a secondmate - so the agent reaches its
# brief or charter instead of wedging on the "Trust this folder?" dialog.
#
# Usage: fm-kimi-trust.sh <worktree> <project>
#        fm-kimi-trust.sh --secondmate-home <home> <id>
#   <worktree>  the isolated task worktree this spawn launches into
#   <project>   the primary checkout that worktree belongs to
#   <home>      the seeded secondmate home this spawn launches into
#   <id>        the secondmate id that home must already be marked for
# Prints one line per registered directory; refuses loudly on anything else.
#
# WHY THIS EXISTS. Kimi Code 0.42.0 gates a directory it has never seen
# behind an interactive "Trust this folder?" dialog on first launch, and no
# launch flag suppresses it. The adapter facts in the harness reference were
# verified on 0.29.1, before the dialog existed; a 0.42.0 smoke-test spawn
# failed its readiness gate ("kimi did not show a verified ready signal
# before brief delivery") because the pane was parked on that dialog, which
# firstmate cannot answer. Pre-registering the trust before launch is the
# only control: the captain reviewed the alternatives and chose this one
# deliberately, with no post-launch dialog detection or Enter-answering
# fallback, so bin/fm-spawn.sh treats a failed registration here as fatal
# rather than launching a worker that would wedge.
#
# STORE SHAPE, verified 2026-09-14 against Kimi Code 0.42.0's own records in
# a live store: one file per trusted directory under
# $HOME/.kimi-code/workspace-trust/, named wd_<basename>_<hash>, where
# <basename> is the directory's last path component and <hash> is the first
# 12 hex characters of the sha256 of the directory's absolute path
# (sha256("/Users/lyon")[:12] matches the stored wd_lyon_c1378d9b7afc entry).
# The file holds exactly {"root":"<absolute path>","trustedAt":<epoch
# milliseconds>} as compact single-line JSON with no trailing newline, mode
# 0600, in a 0700 store directory. trustedAt is milliseconds because that is
# what every observed record carries.
#
# LOGICAL AND RESOLVED PATHS. Kimi's own records name absolute paths, but
# whether the running CLI hashes the pane's logical cwd or its fully
# resolved form is not verified, the same gap bin/fm-agy-trust.sh closes by
# registering both when they differ. A path that differs only through a
# symlink therefore gets one file per form; identical forms collapse to one
# file, so the common case writes exactly what a hand-accepted dialog would.
#
# IDEMPOTENCY AND NON-OWNERSHIP. The store is Kimi's, not firstmate's, so an
# existing file is never rewritten: a file whose parsed root matches the
# directory being registered is left byte-for-byte alone (its original
# trustedAt survives a re-spawn), and a file that exists but does not
# parse to that root - a corrupted entry or a hash collision - refuses the
# whole registration rather than overwriting bytes this script does not
# own. Creation itself uses an exclusive create, so a record Kimi writes
# between the check and the create is honored, not clobbered.
#
# THE SCOPE TEST IS THE SAFETY PROPERTY and mirrors bin/fm-claude-trust.sh
# and bin/fm-agy-trust.sh. Each mode has its own, because the two directory
# shapes differ on disk.
#
# WORKTREE MODE. <worktree> must be a LINKED git worktree - its own git dir,
# sharing <project>'s common dir - whose top level is exactly the resolved
# argument. A primary checkout, a worktree of an unrelated repo, a
# subdirectory of a worktree, a plain directory, and a home directory are
# each refused with a non-zero exit, never a warning and never a silent
# skip.
#
# SECONDMATE-HOME MODE. A secondmate home is a whole firstmate instance
# rather than a task worktree, and bin/fm-home-seed.sh produces it in two
# shapes: a leased treehouse worktree (linked) and a standalone clone of the
# firstmate repo (a primary checkout). Git shape is not the evidence here;
# THE SEED IS, exactly as in bin/fm-claude-trust.sh: the home must carry a
# .fm-secondmate-home marker that is a regular file this user owns, never a
# symlink, naming exactly the <id> passed; it must hold the firstmate
# instance files AGENTS.md and bin/; and each of its data, state, config and
# projects paths must resolve inside the home. That is the set
# bin/fm-home-seed.sh writes and bin/fm-spawn.sh's
# validate_firstmate_home_for_spawn re-checks before launch, so this accepts
# exactly the homes a secondmate spawn will launch into and nothing wider.
#
# Only the launching user's own store is written: new files under
# $HOME/.kimi-code/workspace-trust/, which must be a directory this uid owns
# once resolved. Every existing file in the store is preserved untouched.
set -u
# Path resolution must answer from the filesystem, never from the caller's
# environment, because the refusals below are the safety property. CDPATH
# would redirect a relative `cd` operand into an unrelated directory, and
# the git overrides make a primary checkout report a linked worktree's git
# dir, defeating the primary-checkout refusal. Git exports GIT_DIR into
# every hook environment, so an inherited value is ordinary rather than
# hostile. Clear the whole class once here so every subshell inherits it.
unset CDPATH \
  GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_INDEX_FILE \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_NAMESPACE \
  GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_CONFIG GIT_CONFIG_GLOBAL \
  GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT

usage() {
  echo "usage: fm-kimi-trust.sh <worktree> <project>" >&2
  echo "       fm-kimi-trust.sh --secondmate-home <home> <id>" >&2
  exit 2
}

# MODE selects which structural scope test decides the argument, and
# SCOPE_NOUN names what the argument was expected to be so every shared
# refusal below reads correctly in both modes.
case "${1:-}" in
  --secondmate-home)
    [ "$#" -eq 3 ] || usage
    MODE=secondmate-home
    TARGET_ARG=$2
    SUB_ID=$3
    SCOPE_NOUN="secondmate home"
    ;;
  '' | -h | --help)
    usage
    ;;
  *)
    [ "$#" -eq 2 ] || usage
    MODE=worktree
    TARGET_ARG=$1
    PROJ_ARG=$2
    SCOPE_NOUN="task worktree"
    ;;
esac

refuse() { echo "error: refusing to pre-register Kimi trust: $1" >&2; exit 1; }

real_dir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }
logical_dir() { (cd -- "$1" 2>/dev/null && pwd -L); }
real_file() { node -e 'process.stdout.write(require("node:fs").realpathSync(process.argv[1]))' "$1" 2>/dev/null; }

# The resolved common dir of a git worktree, or empty. --git-common-dir can be
# relative, so it is resolved from inside the worktree rather than joined here.
common_dir_of() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  (cd -P -- "$dir" && real_dir "$common")
}

TARGET_REAL=$(real_dir "$TARGET_ARG") || true
[ -n "$TARGET_REAL" ] || refuse "$SCOPE_NOUN '$TARGET_ARG' is not an accessible directory"
TARGET_LOGICAL=$(logical_dir "$TARGET_ARG") || true
[ -n "$TARGET_LOGICAL" ] || TARGET_LOGICAL=$TARGET_REAL
if [ "$MODE" = worktree ]; then
  PROJ_REAL=$(real_dir "$PROJ_ARG") || true
  [ -n "$PROJ_REAL" ] || refuse "project '$PROJ_ARG' is not an accessible directory"
fi

[ -n "${HOME:-}" ] || refuse "HOME is not set, so Kimi's trust store cannot be located"
HOME_REAL=$(real_dir "$HOME") || true
[ -n "$HOME_REAL" ] || refuse "HOME '$HOME' is not an accessible directory"

# The filesystem root and the home directory are never something this
# registers, in either mode. Checked explicitly so the refusal names the real
# reason instead of the scope verdict behind it.
[ "$TARGET_REAL" != / ] || refuse "'/' is the filesystem root, not a $SCOPE_NOUN"
[ "$TARGET_REAL" != "$HOME_REAL" ] || refuse "'$TARGET_REAL' is the home directory, not a $SCOPE_NOUN"

if [ "$MODE" = worktree ]; then
  WT_TOP=$(git -C "$TARGET_REAL" rev-parse --show-toplevel 2>/dev/null) || true
  [ -n "$WT_TOP" ] || refuse "'$TARGET_REAL' is not inside a git repository"
  WT_TOP_REAL=$(real_dir "$WT_TOP") || true
  [ "$WT_TOP_REAL" = "$TARGET_REAL" ] || refuse "'$TARGET_REAL' is not a worktree root (its root is '${WT_TOP_REAL:-unresolvable}')"

  WT_GIT_DIR=$(git -C "$TARGET_REAL" rev-parse --absolute-git-dir 2>/dev/null) || true
  [ -n "$WT_GIT_DIR" ] || refuse "'$TARGET_REAL' has no resolvable git directory"
  WT_GIT_DIR=$(real_dir "$WT_GIT_DIR") || true
  [ -n "$WT_GIT_DIR" ] || refuse "'$TARGET_REAL' has an unresolvable git directory"
  WT_COMMON=$(common_dir_of "$TARGET_REAL") || true
  [ -n "$WT_COMMON" ] || refuse "'$TARGET_REAL' has no resolvable git common directory"
  [ "$WT_GIT_DIR" != "$WT_COMMON" ] || refuse "'$TARGET_REAL' is a primary checkout, not an isolated worktree"

  PROJ_COMMON=$(common_dir_of "$PROJ_REAL") || true
  [ -n "$PROJ_COMMON" ] || refuse "project '$PROJ_REAL' is not inside a git repository"
  [ "$WT_COMMON" = "$PROJ_COMMON" ] || refuse "'$TARGET_REAL' is not a worktree of project '$PROJ_REAL'"
else
  # The seed evidence, in the order that names the most useful reason first:
  # the marker decides whether this is a secondmate home at all, the id
  # decides whose, and the instance files and operational directories decide
  # whether it is the shape bin/fm-home-seed.sh leaves behind. The marker is
  # the token the whole boundary rests on, so it is judged as a file rather
  # than as a value: a symlink is refused outright rather than followed,
  # because a link is a way to make some other file's bytes stand in for the
  # seed, and a marker this user does not own was planted by someone else.
  [ -n "$SUB_ID" ] || refuse "no secondmate id was supplied, so '$TARGET_REAL' cannot be matched against its seed marker"
  SUB_MARKER="$TARGET_REAL/.fm-secondmate-home"
  [ ! -L "$SUB_MARKER" ] || refuse "'$SUB_MARKER' is a symlink; a seeded secondmate home carries the marker as a regular file"
  [ -f "$SUB_MARKER" ] || refuse "'$TARGET_REAL' carries no .fm-secondmate-home marker, so it is not a seeded secondmate home"
  [ -O "$SUB_MARKER" ] || refuse "'$SUB_MARKER' is not owned by this user"
  SUB_MARKER_ID=$(cat "$SUB_MARKER" 2>/dev/null) || true
  [ "$SUB_MARKER_ID" = "$SUB_ID" ] || refuse "'$TARGET_REAL' is marked for secondmate '${SUB_MARKER_ID:-unknown}', not '$SUB_ID'"
  [ -f "$TARGET_REAL/AGENTS.md" ] || refuse "'$TARGET_REAL' has no AGENTS.md, so it is not a firstmate home"
  [ -d "$TARGET_REAL/bin" ] || refuse "'$TARGET_REAL' has no bin/, so it is not a firstmate home"
  for sub_dir_name in data state config projects; do
    sub_dir="$TARGET_REAL/$sub_dir_name"
    if [ -L "$sub_dir" ] && [ ! -e "$sub_dir" ]; then
      refuse "'$sub_dir' is a broken symlink, so this home's $sub_dir_name directory cannot be shown to stay inside it"
    fi
    [ -e "$sub_dir" ] || continue
    [ -d "$sub_dir" ] || refuse "'$sub_dir' is not a directory, so '$TARGET_REAL' is not a seeded secondmate home"
    sub_dir_real=$(real_dir "$sub_dir") || true
    [ -n "$sub_dir_real" ] || refuse "'$sub_dir' cannot be resolved"
    case "$sub_dir_real" in
      "$TARGET_REAL"/*) ;;
      *) refuse "'$sub_dir' resolves to '$sub_dir_real', outside the home, so '$TARGET_REAL' is not a safe secondmate home" ;;
    esac
  done
fi

# The store write needs node for the sha256, the millisecond timestamp, and
# the JSON serialization, and a missing interpreter refuses like every other
# failure here. Degrading instead would launch a worker straight into the
# dialog this registration exists to remove. A node-less home never reaches a
# spawn anyway, since bin/fm-bootstrap.sh lists node in COMMON_TOOLS.
command -v node >/dev/null 2>&1 || refuse "node is required to record workspace trust and was not found on PATH"

# The store directory is Kimi's own; it already exists on any machine that
# has answered a trust dialog once, and is created here (not pre-modeled on
# Kimi's 0700, which only Kimi may impose) when it does not.
STORE_DIR="$HOME_REAL/.kimi-code/workspace-trust"
mkdir -p "$STORE_DIR" 2>/dev/null || true
STORE_DIR_REAL=$(real_dir "$STORE_DIR") || true
[ -n "$STORE_DIR_REAL" ] || refuse "Kimi trust store directory '$STORE_DIR' does not exist and could not be created"
STORE_DIR_REAL=$(real_file "$STORE_DIR_REAL") || true
[ -n "$STORE_DIR_REAL" ] || refuse "Kimi trust store directory '$STORE_DIR_REAL' could not be resolved"
[ -d "$STORE_DIR_REAL" ] || refuse "'$STORE_DIR_REAL' is not a directory"
[ -O "$STORE_DIR_REAL" ] || refuse "'$STORE_DIR_REAL' is not owned by this user"
[ -w "$STORE_DIR_REAL" ] || refuse "'$STORE_DIR_REAL' is not writable"

# One node process walks every path form, so the logical and resolved forms
# land (or are found already recorded) under one pass. Each file is created
# with an exclusive create at mode 0600, matching every observed Kimi record;
# compact single-line JSON with no trailing newline is the byte shape of the
# observed store, so a hand-accepted dialog and a pre-registered one are
# indistinguishable on disk.
if ! node - "$STORE_DIR_REAL" "$TARGET_LOGICAL" "$TARGET_REAL" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const [store, ...wanted] = process.argv.slice(2);
const paths = [...new Set(wanted)];
const recordName = (root) => {
  const hash = crypto.createHash("sha256").update(root, "utf8").digest("hex").slice(0, 12);
  return `wd_${path.basename(root)}_${hash}`;
};
const readRoot = (file) => {
  const parsed = JSON.parse(fs.readFileSync(file, "utf8"));
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(`${file} is not a Kimi trust record`);
  }
  return parsed.root;
};
for (const root of paths) {
  const file = path.join(store, recordName(root));
  let existed = false;
  try {
    // Exclusive create at 0600: a record Kimi wrote between the existence
    // check and this create surfaces as EEXIST and is honored below, never
    // clobbered. writeFileSync applies mode before umask can widen it, and
    // 0600 has no group or other bits for umask to strip.
    fs.writeFileSync(file, `${JSON.stringify({ root, trustedAt: Date.now() })}`, {
      mode: 0o600,
      flag: "wx",
    });
  } catch (err) {
    if (err.code !== "EEXIST") throw err;
    existed = true;
  }
  const recorded = readRoot(file);
  if (recorded !== root) {
    throw new Error(
      `${file} already records root '${recorded}', not '${root}'; refusing to overwrite a Kimi trust entry this script does not own`,
    );
  }
  console.log(`trusted: ${root}`);
}
NODE
then
  refuse "could not record trust for '$TARGET_LOGICAL' in '$STORE_DIR_REAL'"
fi
