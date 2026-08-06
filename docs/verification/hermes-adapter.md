# Hermes / Zeus adapter verification

Audience: maintainer verification.

This record supports the Hermes Agent and Zeus crew worker adapters in `bin/fm-spawn.sh`, `bin/fm-zeus-worker.sh`, `bin/fm-harness.sh`, and `bin/fm-busy-lib.sh`.
Operator knowledge lives in `.agents/skills/harness-adapters/SKILL.md`.
Task chronology stays in private reports or PR evidence.

## Boundary

| Surface | Role |
| --- | --- |
| Local `hermes` process | Firstmate coding worker; `cwd` is the task worktree. |
| VPS `aerolot-zeus` on `root@178.156.175.68` | Coach / ACP container for Desktop and Buzz. |
| `zeus-acp` / `hermes acp` | Out of scope for Firstmate crew launch. |

Inference may use the DeepSeek API with the same model defaults as VPS Zeus.
The worker process itself is local.

## Versions (2026-08-06)

| Where | Version |
| --- | --- |
| Local CLI | Hermes Agent v0.18.2 (2026.7.7.2), install `/home/david/.hermes/hermes-agent`, wrapper `~/.local/bin/hermes` |
| VPS container `aerolot-zeus` | Hermes Agent v0.19.1 (2026.7.30), install `/opt/hermes` |

## VPS Zeus config (model only)

From `/opt/data/config.yaml` inside `aerolot-zeus` (no secrets):

- `model.default: deepseek-v4-flash`
- `model.provider: deepseek`
- `fallback_model.provider: deepseek`
- `fallback_model.model: deepseek-v4-pro`

## Smoke: inference

Command (local, with `DEEPSEEK_API_KEY` present in the environment):

```sh
hermes chat -q 'Reply exactly HERMES_SMOKE_OK' -m deepseek-v4-flash --provider deepseek -Q
```

Observed result: response body `HERMES_SMOKE_OK`, exit 0.

Same command inside `docker exec aerolot-zeus` also returned `HERMES_SMOKE_OK` with exit 0.
Provider that worked: **deepseek** (not OpenRouter) when the DeepSeek key was present.
Without keys, local hermes refused with `No usable credentials found for provider 'deepseek'`.

## Smoke: tool write in cwd

```sh
cd /tmp/hermes-smoke-$$
hermes chat -q 'Create a file named HERMES_MARKER.txt in the current working directory containing exactly the text MARKER_OK. Do not write anywhere else. Then reply exactly MARKER_WRITTEN.' \
  -m deepseek-v4-flash --provider deepseek --yolo --accept-hooks -Q
```

Observed result: file `HERMES_MARKER.txt` with content `MARKER_OK`, agent reply `MARKER_WRITTEN`, exit 0.

## Interactive launch shape

| Mode | Command | Result |
| --- | --- | --- |
| One-shot | `hermes -z '…' -m deepseek-v4-flash --provider deepseek --yolo --accept-hooks` | Runs one turn and exits (not a supervised pane). |
| Interactive | `hermes chat --yolo --accept-hooks --cli -m deepseek-v4-flash --provider deepseek` | Classic REPL; footer shows `⚠ YOLO`; composer glyph `❯`. |
| Positional brief | `hermes chat … 'hello'` | Rejected: `unrecognized arguments`. |
| Exit | type `/exit` | `Shutting down…` then `Goodbye! ⚕`. |

Firstmate therefore launches via `bin/fm-zeus-worker.sh` (interactive) and delivers the brief after readiness, like Kimi.

## Readiness, delivery, and credentials

Readiness accepts only harness-owned evidence: `Welcome to Hermes Agent!`, the `⚠ YOLO` footer, or a bordered empty `❯` composer.
A bare `❯` row is the default prompt glyph of several shells, so it proves nothing about Hermes and is rejected.
Delivery requires the exact `empty` submit verdict from `fm_tmux_submit_core` together with the pointer visible in a pane that still shows a Hermes signal.
A `pending` verdict means the Enter was swallowed and the pointer is still in the composer; that fails the spawn.

The crewmate pane is created by a long-lived multiplexer daemon and inherits no captain environment.
`fm-spawn.sh` therefore refuses a hermes/zeus spawn when neither `DEEPSEEK_API_KEY` nor `OPENROUTER_API_KEY` is set for firstmate.
Without that guard, a keyless pane exits `fm-zeus-worker.sh` back to a shell and every gate can pass against that shell.

The resolved key reaches the pane through a `0600` file that `mktemp` creates as `$TASK_TMP/zeus-env.XXXXXX` under `umask 077`.
The task temp root is a predictable path in a world-writable `/tmp`, so the spawn first refuses any root that is a symlink or that this user does not own, and `mktemp` then picks an unguessable name and opens the file `O_EXCL`.
The pane receives one line that sources the file, exports its contents, and deletes it; the launch command carries no key.
`spawn_abort_cleanup` removes the file on every exit path, so a signal during the readiness wait cannot strand a credential in `/tmp`.
This matters because everything typed into a pane persists in its scrollback and its shell history file, and `bin/fm-peek.sh` prints raw pane text straight into the captain's context.
Do not restore an environment-prefix on the launch command: forwarding a path is safe, forwarding a credential is not.

## Busy state

No semantic busy source was live-verified for a firstmate-launched Hermes pane on 2026-08-06.
Classifier reports `unknown hermes-unverified`.
Do not open a rendered-tail gate without a new evidence pass in this file and `bin/fm-busy-lib.sh`.

## Detection

Markerless for firstmate.
`bin/fm-harness.sh`, `bin/fm-session-lock-lib.sh`, and `bin/backends/tmux.sh` all match the ancestry command name against `*hermes*`.
`bin/fm-zeus-worker.sh` `exec`s into `hermes`, so the wrapper's own name is never the live foreground command and is not a match token anywhere.

## Regression entry points

```sh
tests/fm-hermes-harness.test.sh
tests/fm-busy-state.test.sh
```
