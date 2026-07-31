# shellcheck shell=bash
# Shared identity, ownership, capture, and publication rules for the generic
# process-to-event runner.
# Usage: . bin/fm-procevent-lib.sh   (requires fm-pr-lib.sh and fm-wake-lib.sh)
#
# The runner lets firstmate learn that a registered long-polling source produced
# a result without holding that blocking process in its conversational turn. It
# is domain-neutral: a thin adapter supplies source identity, the argv to run,
# and how to classify a completed result. Everything else - ownership, durable
# capture, publication, and restart recovery - lives here.
#
# It adds no second notification control plane: a completed result is published
# as an ordinary `check` wake through the existing durable wake queue, which is
# the same mechanism merge polls and X mode already use.
#
# DURABILITY BOUNDARY, stated precisely. This runner proves exactly one thing:
# once a child process has exited and its output has been read, that output is
# stored atomically at mode 0600 BEFORE any event referencing it is published,
# and an unannounced stored result is re-announced after a restart. It proves
# nothing about the source side of the handoff. In particular the currently
# published `lavish-axi poll` destructively clears feedback before returning it,
# so a result lost between that clearing and this runner reading the process
# output is unrecoverable. A Firstmate wrapper cannot close that window. Never
# describe this runner as at-least-once, no-loss, or lossless.

# Machine-wide claim root. Homes can share one underlying source store, so the
# "one owner per canonical source" rule cannot live inside a single home.
fm_procevent_claim_root() {
  printf '%s\n' "${FM_PROCEVENT_CLAIM_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/procevent-claims}"
}

fm_procevent_registry_dir() { printf '%s\n' "$1/procevent"; }
fm_procevent_inbox_dir()    { printf '%s\n' "$1/procevent-inbox"; }

# A source id names a private file and a bounded wake slug, so it is held to the
# same path-safe shape as a task id. Adapters derive it from canonical source
# identity, never from a caller-supplied display string.
fm_procevent_source_id_valid() {
  local id=${1-}
  fm_task_id_path_safe "$id" || return 1
  [ "${#id}" -le 64 ]
}

fm_procevent_adapter_valid() {
  local a=${1-}
  case "$a" in
    ''|*[!a-z0-9-]*) return 1 ;;
  esac
  [ "${#a}" -le 32 ]
}

# fm_procevent_any_registered <state>
fm_procevent_any_registered() {
  local reg rec
  reg=$(fm_procevent_registry_dir "$1")
  [ -d "$reg" ] || return 1
  for rec in "$reg"/*.source; do
    [ -e "$rec" ] || continue
    return 0
  done
  return 1
}

# --- ownership --------------------------------------------------------------
# A claim is a single-link 0600 file created exclusively. It records the owning
# home and the runner pid, so a stale claim from a dead runner can be reclaimed
# while a live one is refused rather than duplicated.

fm_procevent_claim_path() {
  printf '%s/%s.claim\n' "$(fm_procevent_claim_root)" "$1"
}

fm_procevent_claim_read() {  # <source-id> -> "home<TAB>pid"
  local claim home pid
  claim=$(fm_procevent_claim_path "$1")
  [ -f "$claim" ] && [ ! -L "$claim" ] || return 1
  IFS= read -r home < "$claim" || return 1
  pid=$(sed -n '2p' "$claim" 2>/dev/null)
  printf '%s\t%s\n' "$home" "$pid"
}

fm_procevent_claim_live() {  # <source-id>: true when a live process holds it
  local rec pid
  rec=$(fm_procevent_claim_read "$1") || return 1
  pid=${rec#*$'\t'}
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}

# fm_procevent_claim_acquire <source-id> <home> <pid>
# 0 acquired, 1 error, 2 held by a live owner (possibly another home).
fm_procevent_claim_acquire() {
  local id=$1 home=$2 pid=$3 root claim tmp
  fm_procevent_source_id_valid "$id" || return 1
  root=$(fm_procevent_claim_root)
  (umask 077; mkdir -p "$root") || return 1
  [ -d "$root" ] && [ ! -L "$root" ] || return 1
  claim=$(fm_procevent_claim_path "$id")
  if [ -e "$claim" ] || [ -L "$claim" ]; then
    fm_procevent_claim_live "$id" && return 2
    # Stale claim from a dead runner: remove only a plain private file.
    [ -f "$claim" ] && [ ! -L "$claim" ] || return 1
    rm -f -- "$claim" || return 1
  fi
  tmp=$(umask 077; mktemp "$root/.claim.XXXXXX") || return 1
  printf '%s\n%s\n' "$home" "$pid" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  # ln is the exclusive-create step: a concurrent winner makes this fail.
  if ! ln "$tmp" "$claim" 2>/dev/null; then
    rm -f -- "$tmp"
    return 2
  fi
  rm -f -- "$tmp"
}

# fm_procevent_claim_release <source-id> <home>
# Releases only a claim this home still owns, so a slow loser cannot drop the
# winner's claim.
fm_procevent_claim_release() {
  local id=$1 home=$2 claim rec
  fm_procevent_source_id_valid "$id" || return 1
  claim=$(fm_procevent_claim_path "$id")
  [ -e "$claim" ] || return 0
  rec=$(fm_procevent_claim_read "$id") || return 1
  [ "${rec%%$'\t'*}" = "$home" ] || return 1
  rm -f -- "$claim"
}

# --- durable capture and publication ----------------------------------------

# fm_procevent_capture <state> <source-id> <output-file>
# Atomically store the completed output at 0600 and print its durable path. The
# rename is the commit point; nothing referencing this result may be published
# before it returns successfully.
fm_procevent_capture() {
  local state=$1 id=$2 src=$3 inbox seq dest tmp
  fm_procevent_source_id_valid "$id" || return 1
  inbox=$(fm_procevent_inbox_dir "$state")
  (umask 077; mkdir -p "$inbox") || return 1
  seq=1
  while [ -e "$inbox/$id.$seq.result" ]; do seq=$((seq + 1)); done
  dest="$inbox/$id.$seq.result"
  tmp=$(umask 077; mktemp "$inbox/.capture.XXXXXX") || return 1
  if ! cat "$src" > "$tmp"; then rm -f -- "$tmp"; return 1; fi
  if ! chmod 0600 "$tmp"; then rm -f -- "$tmp"; return 1; fi
  if ! mv -f -- "$tmp" "$dest"; then rm -f -- "$tmp"; return 1; fi
  printf '%s\n' "$dest"
}

# fm_procevent_pending <state>
# Print every durably captured result that has not been announced yet, oldest
# first. This is what makes a restart between capture and publication recover.
fm_procevent_pending() {
  local state=$1 inbox result
  inbox=$(fm_procevent_inbox_dir "$state")
  [ -d "$inbox" ] || return 0
  for result in "$inbox"/*.result; do
    [ -f "$result" ] && [ ! -L "$result" ] || continue
    [ -e "${result%.result}.announced" ] && continue
    printf '%s\n' "$result"
  done
}

# fm_procevent_event_line <adapter> <source-id>
# The complete normalized event. Bounded by construction: a fixed verb, a
# validated adapter name, and a validated id. No source output, path, or
# caller-supplied text can appear here.
fm_procevent_event_line() {
  local adapter=$1 id=$2
  fm_procevent_adapter_valid "$adapter" || return 1
  fm_procevent_source_id_valid "$id" || return 1
  printf 'procevent %s %s\n' "$adapter" "$id"
}

# fm_procevent_mark_announced <result-path>
# Marked only after the durable wake publication succeeded, so a crash before
# publication leaves the result pending rather than silently consumed.
fm_procevent_mark_announced() {
  local result=$1 marker="${1%.result}.announced"
  [ -f "$result" ] && [ ! -L "$result" ] || return 1
  [ -L "$marker" ] && return 1
  : > "$marker" 2>/dev/null || return 1
  chmod 0600 "$marker" 2>/dev/null || true
}

# fm_procevent_result_source_id <result-path>
fm_procevent_result_source_id() {
  local base=${1##*/}
  base=${base%.result}
  printf '%s\n' "${base%.*}"
}
