#!/usr/bin/env bash
# Generic process-to-event runner: supervise a registered long-polling child
# outside the agent's foreground turn and turn its completed result into one
# normalized durable event.
#
# Usage:
#   fm-procevent.sh register <adapter> <source-id> -- <argv>...
#   fm-procevent.sh start <source-id>
#   fm-procevent.sh reconcile
#   fm-procevent.sh retire <source-id>
#   fm-procevent.sh list
#
# register   Record a source: its adapter, its canonical id, and the exact argv
#            to execute. argv is stored one argument per line and executed
#            directly, so there is no shell surface and no argument splitting.
#            Adapters register sources; nothing here parses user text.
# start      Claim the source, run its child to completion, durably capture the
#            output, publish one normalized event, then release the claim. This
#            blocks for as long as the source blocks and is meant to run as a
#            supervised background process, never in a conversational turn.
# reconcile  Idempotent liveness entry the watcher calls on its ordinary cycle:
#            republish durably captured but unannounced results, and start a
#            runner for any registered source that has no live owner. This is
#            liveness repair only - it never discovers results by polling the
#            source, because the child blocks on the source itself.
# retire     Drop a registration, stop a runner this home owns, release the claim.
# list       Show registered sources, owners, and pending captured results.
#
# Ownership is machine-wide per canonical source, because separate Firstmate
# homes can share one underlying source store. A live owner is never displaced;
# only a claim whose runner is gone is reclaimed.
#
# Durability boundary: see bin/fm-procevent-lib.sh. This runner proves capture
# before publication and restart re-announcement, and nothing about the source
# side of the handoff.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

REG=$(fm_procevent_registry_dir "$STATE")
MAX_OUTPUT_BYTES=${FM_PROCEVENT_MAX_OUTPUT_BYTES:-1048576}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

adapter_script() { printf '%s/bin/fm-procevent-%s.sh\n' "$FM_ROOT" "$1"; }

source_file()  { printf '%s/%s.source\n' "$REG" "$1"; }
runner_file()  { printf '%s/%s.runner\n' "$REG" "$1"; }

read_adapter() {  # <source-id>
  local f; f=$(source_file "$1")
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  sed -n 's/^adapter=//p' "$f" | head -1
}

# Read the stored argv into the ARGV array. One argument per line after the
# argv= count, so an argument containing spaces or newlines can never be
# re-split into two arguments.
read_argv() {  # <source-id>
  local f n; f=$(source_file "$1")
  ARGV=()
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  n=$(sed -n 's/^argc=//p' "$f" | head -1)
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  local i=0 line
  while IFS= read -r line; do
    i=$((i + 1))
    [ "$i" -le "$n" ] && ARGV+=("$line")
  done < <(sed -n '/^argv:$/,$p' "$f" | tail -n +2)
  [ "${#ARGV[@]}" -eq "$n" ]
}

cmd_register() {
  local adapter=${1-} id=${2-} sep=${3-}
  shift 3 2>/dev/null || usage
  fm_procevent_adapter_valid "$adapter" || die "adapter name must be lowercase alphanumeric or dash: $adapter"
  fm_procevent_source_id_valid "$id" || die "source id must be path-safe and at most 64 characters: $id"
  [ "$sep" = -- ] || usage
  [ "$#" -ge 1 ] || die "register needs at least one argv element after --"
  [ -f "$(adapter_script "$adapter")" ] || die "no installed adapter for: $adapter"
  (umask 077; mkdir -p "$REG") || die "cannot create the source registry"
  local tmp dest
  dest=$(source_file "$id")
  tmp=$(umask 077; mktemp "$REG/.source.XXXXXX") || die "cannot stage the registration"
  {
    printf 'adapter=%s\n' "$adapter"
    printf 'argc=%s\n' "$#"
    printf 'argv:\n'
    printf '%s\n' "$@"
  } > "$tmp" || { rm -f -- "$tmp"; die "cannot write the registration"; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; die "cannot secure the registration"; }
  mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; die "cannot publish the registration"; }
  printf 'registered: %s (%s)\n' "$id" "$adapter"
}

# Publish every durably captured result that has not been announced. Capture
# already happened, so this only turns durable state into durable events.
publish_pending() {
  local result id adapter line published=0
  while IFS= read -r result; do
    [ -n "$result" ] || continue
    id=$(fm_procevent_result_source_id "$result")
    fm_procevent_source_id_valid "$id" || continue
    adapter=$(read_adapter "$id" 2>/dev/null || true)
    [ -n "$adapter" ] || adapter=unknown
    fm_procevent_adapter_valid "$adapter" || adapter=unknown
    line=$(fm_procevent_event_line "$adapter" "$id") || continue
    fm_wake_append check "procevent:$id" "check: $line" || continue
    fm_procevent_mark_announced "$result" || continue
    published=$((published + 1))
  done < <(fm_procevent_pending "$STATE")
  printf '%s\n' "$published"
}

cmd_start() {
  local id=${1-} adapter out rc claimed
  fm_procevent_source_id_valid "$id" || die "source id must be path-safe: $id"
  [ -f "$(source_file "$id")" ] || die "source is not registered: $id"
  adapter=$(read_adapter "$id") || die "registration is unreadable: $id"
  fm_procevent_adapter_valid "$adapter" || die "registration names an invalid adapter"
  read_argv "$id" || die "registration argv is unreadable: $id"

  fm_procevent_claim_acquire "$id" "$FM_HOME" "$$"
  claimed=$?
  case "$claimed" in
    0) ;;
    2) printf 'already owned: %s\n' "$id"; exit 0 ;;
    *) die "cannot claim source: $id" ;;
  esac
  # shellcheck disable=SC2064 # expand now: the trap must release this exact claim.
  trap "fm_procevent_claim_release '$id' '$FM_HOME' 2>/dev/null || true" EXIT
  printf '%s\n' "$$" > "$(runner_file "$id")" 2>/dev/null || true
  chmod 0600 "$(runner_file "$id")" 2>/dev/null || true

  out=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-procevent.XXXXXX") || die "cannot stage output"
  # Direct execution of the stored argv: no shell, no re-splitting.
  "${ARGV[@]}" > "$out" 2>/dev/null
  rc=$?

  # Bounded output: an oversized result is truncated rather than published whole,
  # and never silently dropped.
  local bytes truncated=0
  bytes=$(wc -c < "$out" | tr -d '[:space:]')
  if [ "${bytes:-0}" -gt "$MAX_OUTPUT_BYTES" ]; then
    head -c "$MAX_OUTPUT_BYTES" "$out" > "$out.cut" 2>/dev/null && mv -f "$out.cut" "$out"
    truncated=1
  fi

  if [ "$rc" -ne 0 ] && [ ! -s "$out" ]; then
    # No usable result. Leave the registration armed; the adapter decides
    # whether a nonzero exit is terminal when it handles the next result.
    rm -f -- "$out" "$(runner_file "$id")"
    printf 'no-result: %s (exit %s)\n' "$id" "$rc"
    exit 0
  fi

  local durable
  durable=$(fm_procevent_capture "$STATE" "$id" "$out") || { rm -f -- "$out"; die "cannot durably capture the result"; }
  rm -f -- "$out"
  [ "$truncated" -eq 1 ] && printf 'truncated: %s at %s bytes\n' "$id" "$MAX_OUTPUT_BYTES" >&2

  publish_pending >/dev/null
  rm -f -- "$(runner_file "$id")"
  printf 'captured: %s\n' "$durable"
}

# Start a runner in its own process group so it outlives the watcher cycle that
# noticed it was missing. macOS has no setsid, so perl's setpgrp is the portable
# equivalent - the same fallback shape bin/fm-watch.sh already uses for bounded
# check execution.
detach_runner() {  # <source-id>
  if command -v setsid >/dev/null 2>&1; then
    FM_HOME="$FM_HOME" setsid "$SCRIPT_DIR/fm-procevent.sh" start "$1" >/dev/null 2>&1 &
  else
    # shellcheck disable=SC2016  # single quotes are deliberate: perl expands its own vars.
    FM_HOME="$FM_HOME" perl -e 'setpgrp(0, 0); exec @ARGV' \
      "$SCRIPT_DIR/fm-procevent.sh" start "$1" >/dev/null 2>&1 &
  fi
}

cmd_reconcile() {
  local rec id published started=0 stopped=0 claim claim_rec
  published=$(publish_pending)

  # Stop a runner this home owns whose source is no longer registered. Without
  # this, unregistering a source that never completes leaves its child blocked
  # forever with nothing left to reap it.
  for claim in "$(fm_procevent_claim_root)"/*.claim; do
    [ -e "$claim" ] || continue
    id=${claim##*/}; id=${id%.claim}
    fm_procevent_source_id_valid "$id" || continue
    [ -f "$(source_file "$id")" ] && continue
    claim_rec=$(fm_procevent_claim_read "$id" 2>/dev/null) || continue
    [ "${claim_rec%%$'\t'*}" = "$FM_HOME" ] || continue
    fm_procevent_claim_live "$id" || { fm_procevent_claim_release "$id" "$FM_HOME" 2>/dev/null || true; continue; }
    stop_runner_pid "${claim_rec#*$'\t'}"
    fm_procevent_claim_release "$id" "$FM_HOME" 2>/dev/null || true
    rm -f -- "$(runner_file "$id")"
    stopped=$((stopped + 1))
  done

  if [ -d "$REG" ]; then
    for rec in "$REG"/*.source; do
      [ -e "$rec" ] || continue
      id=${rec##*/}; id=${id%.source}
      fm_procevent_source_id_valid "$id" || continue
      fm_procevent_claim_live "$id" && continue
      # No live owner: start one, detached from this cycle so reconcile never
      # blocks the watcher.
      detach_runner "$id"
      started=$((started + 1))
    done
  fi
  printf 'reconciled: published=%s started=%s stopped=%s\n' "$published" "$started" "$stopped"
}

# Stop a runner and the child it is blocked on. A runner started by reconcile is
# its own process group leader, so the group signal is what actually reaches the
# blocking child - signalling only the runner would leave that child alive and
# reparented, which is exactly how a source that never completes leaks.
stop_runner_pid() {  # <pid>
  local pid=${1-}
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  kill -0 "$pid" 2>/dev/null || return 0
  kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  local i=0
  while [ "$i" -lt 20 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
}

# Resolve this home's runner pid for a source. The in-home record is preferred,
# but the machine-wide claim also carries it, so retirement still works when the
# home's state has already been removed.
runner_pid_for() {  # <source-id>
  local id=$1 runner pid rec
  runner=$(runner_file "$id")
  if [ -f "$runner" ] && [ ! -L "$runner" ]; then
    IFS= read -r pid < "$runner" 2>/dev/null || pid=
    case "$pid" in ''|*[!0-9]*) pid= ;; esac
  fi
  if [ -z "${pid:-}" ] && rec=$(fm_procevent_claim_read "$id" 2>/dev/null); then
    [ "${rec%%$'\t'*}" = "$FM_HOME" ] && pid=${rec#*$'\t'}
    case "${pid:-}" in ''|*[!0-9]*) pid= ;; esac
  fi
  printf '%s\n' "${pid:-}"
}

cmd_retire() {
  local id=${1-} pid
  fm_procevent_source_id_valid "$id" || die "source id must be path-safe: $id"
  pid=$(runner_pid_for "$id")
  rm -f -- "$(runner_file "$id")"
  stop_runner_pid "$pid"
  rm -f -- "$(source_file "$id")"
  fm_procevent_claim_release "$id" "$FM_HOME" 2>/dev/null || true
  printf 'retired: %s\n' "$id"
}

cmd_list() {
  local rec id adapter owner pending
  if ! fm_procevent_any_registered "$STATE"; then
    printf 'no sources registered\n'
    return 0
  fi
  printf '%-28s %-12s %-10s %s\n' SOURCE ADAPTER OWNER PENDING
  for rec in "$REG"/*.source; do
    [ -e "$rec" ] || continue
    id=${rec##*/}; id=${id%.source}
    adapter=$(read_adapter "$id" 2>/dev/null || echo '?')
    if fm_procevent_claim_live "$id"; then owner=live; else owner=none; fi
    pending=$(fm_procevent_pending "$STATE" | grep -c "/$id\." || true)
    printf '%-28s %-12s %-10s %s\n' "$id" "$adapter" "$owner" "$pending"
  done
}

case "${1-}" in
  register)  shift; cmd_register "$@" ;;
  start)     shift; cmd_start "$@" ;;
  reconcile) shift; cmd_reconcile "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  list)      shift; cmd_list "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
