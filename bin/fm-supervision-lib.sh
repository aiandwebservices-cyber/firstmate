# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/fm-supervision-lib.sh
#
# Reports whether a firstmate home needs supervision because it has in-flight
# work, an X-mode relay poll, or a process-to-event obligation, and whether its
# watcher has a fresh liveness beacon.
# bin/fm-guard.sh keeps its task-specific grace-based warning predicate;
# bin/fm-turnend-guard.sh uses the status fields here for its banner but performs
# its end-of-turn block decision with the live watcher lock check in
# bin/fm-wake-lib.sh.

FM_SUP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-procevent-lib.sh
. "$FM_SUP_LIB_DIR/fm-procevent-lib.sh"

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_supervision_status <state-dir> [grace-seconds] [home]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   FM_SUP_REGISTRATIONS  count of local process-to-event registrations
#   FM_SUP_OWNED_CLAIMS   count of machine-wide claims owned by this home
#   FM_SUP_PENDING_RESULTS count of unannounced durable results
#   FM_SUP_SOURCES        count of unique process-to-event source obligations
#   FM_SUP_NEEDED         true/false - in-flight work, an X-mode relay poll, or a
#                         process-to-event obligation
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} home=${3:-${FM_HOME:-}} meta source claim owner result id beat m age source_ids
  [ -n "$home" ] || home=$(cd "$state/.." 2>/dev/null && pwd -P || dirname "$state")
  FM_SUP_IN_FLIGHT=0
  FM_SUP_REGISTRATIONS=0
  FM_SUP_OWNED_CLAIMS=0
  FM_SUP_PENDING_RESULTS=0
  FM_SUP_SOURCES=0
  FM_SUP_NEEDED=false
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
  done
  source_ids=$'\n'
  for source in "$state"/procevent/*.source; do
    [ -f "$source" ] && [ ! -L "$source" ] || continue
    FM_SUP_REGISTRATIONS=$((FM_SUP_REGISTRATIONS + 1))
    id=${source##*/}; id=${id%.source}
    case "$source_ids" in
      *$'\n'"$id"$'\n'*) ;;
      *) source_ids+="$id"$'\n'; FM_SUP_SOURCES=$((FM_SUP_SOURCES + 1)) ;;
    esac
  done
  for claim in "$(fm_procevent_claim_root)"/*.claim; do
    [ -f "$claim" ] && [ ! -L "$claim" ] || continue
    IFS= read -r owner < "$claim" 2>/dev/null || continue
    [ "$owner" = "$home" ] || continue
    FM_SUP_OWNED_CLAIMS=$((FM_SUP_OWNED_CLAIMS + 1))
    id=${claim##*/}; id=${id%.claim}
    case "$source_ids" in
      *$'\n'"$id"$'\n'*) ;;
      *) source_ids+="$id"$'\n'; FM_SUP_SOURCES=$((FM_SUP_SOURCES + 1)) ;;
    esac
  done
  for result in "$state"/procevent-inbox/*.result; do
    [ -f "$result" ] && [ ! -L "$result" ] || continue
    [ -e "${result%.result}.announced" ] && continue
    FM_SUP_PENDING_RESULTS=$((FM_SUP_PENDING_RESULTS + 1))
    id=$(fm_procevent_result_source_id "$result")
    case "$source_ids" in
      *$'\n'"$id"$'\n'*) ;;
      *) source_ids+="$id"$'\n'; FM_SUP_SOURCES=$((FM_SUP_SOURCES + 1)) ;;
    esac
  done
  if [ "$FM_SUP_IN_FLIGHT" -gt 0 ] \
    || [ -f "$state/x-watch.check.sh" ] \
    || [ "$FM_SUP_SOURCES" -gt 0 ]; then
    FM_SUP_NEEDED=true
  fi

  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      FM_SUP_BEACON_DESC="${age}s ago"
      [ "$age" -lt "$grace" ] && FM_SUP_WATCHER_FRESH=true
    else
      # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
      FM_SUP_BEACON_DESC=unknown
    fi
  fi

  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
  [ -s "$state/.wake-queue" ] && FM_SUP_QUEUE_PENDING=true
  : "$FM_SUP_REGISTRATIONS" "$FM_SUP_OWNED_CLAIMS" "$FM_SUP_PENDING_RESULTS"
  return 0
}

# fm_supervision_needed <state-dir> [grace-seconds] [home]
# Exit 0 (true) exactly when the home needs a watcher.
fm_supervision_needed() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ]
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly when supervision is needed and no watcher has a fresh
# beacon. Exit 1 (false) otherwise.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ] && [ "$FM_SUP_WATCHER_FRESH" = false ]
}
