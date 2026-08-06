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

## Busy state

No semantic busy source was live-verified for a firstmate-launched Hermes pane on 2026-08-06.
Classifier reports `unknown hermes-unverified`.
Do not open a rendered-tail gate without a new evidence pass in this file and `bin/fm-busy-lib.sh`.

## Detection

Markerless for firstmate.
`bin/fm-harness.sh` matches process ancestry command name `hermes` (or `fm-zeus-worker`).

## Regression entry points

```sh
tests/fm-hermes-harness.test.sh
tests/fm-busy-state.test.sh
```
