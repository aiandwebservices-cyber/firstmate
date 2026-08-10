#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the crewmate keeps its window,
# worktree, and loaded context; only the contract changes. Flips kind= to ship in
# state/<task-id>.meta so fm-teardown.sh applies the full ship-task teardown protection
# again. Also flips role= to builder: ADLC maps the Implementation stage to the
# Builder role (docs/adlc-standard.md, agent-roles skill), so a promoted scout's
# recorded role must match the ship contract it is about to receive; firstmate
# steers any captain-authorized specialized role (e.g. debugger for a fix) in the
# follow-up message. After promoting, send the crewmate its ship instructions via
# fm-send.sh (inventory scratch state, reset to a clean default-branch base, carry
# over only intended fix changes, create branch fm/<task-id>, implement, then
# report done according to the project's delivery mode) and tell it the scout role
# contract in its brief no longer applies.
# Usage: fm-promote.sh <task-id>
# Refuses (exit 3) when run from a no-mistakes gate context, like every other
# fleet-lifecycle mutation entrypoint (fm-spawn/fm-send/fm-teardown), because
# promotion flips teardown protection on a real task.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
grep -qx 'kind=scout' "$META" || { echo "error: task $ID is not a scout task (kind=scout not in meta)" >&2; exit 1; }

TMP="$META.tmp"
grep -v '^kind=' "$META" | grep -v '^role=' > "$TMP"
echo "kind=ship" >> "$TMP"
echo "role=builder" >> "$TMP"
mv "$TMP" "$META"

HOME_Q=$(printf '%q' "$FM_HOME")
echo "promoted $ID to ship (teardown protection restored)"
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions: your scout role contract no longer applies; you are now the Builder. Review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; report done>'"
