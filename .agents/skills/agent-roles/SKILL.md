---
name: agent-roles
description: >-
  Agent-only classification procedure for assigning a task an agent role (assistant, planner, architect, designer, builder, debugger, reviewer, researcher, tester) at intake, then wiring that role through fm-brief.sh --role and fm-spawn.sh --role.
  Use before classifying a new task's role, before scaffolding a brief with a role, and before spawning a role-classified crewmate.
user-invocable: false
metadata:
  internal: true
---

# agent-roles

This skill is the single owner of the role catalog and the intake classification procedure.
It assigns every task one role from the fixed set below, then maps that role onto the existing ship/scout kind axis.
Roles are not a new harness, backend, or worker class.
They are a labeling and prompting layer: the worker stays a firstmate crewmate on the verified harness, and the role contract is injected into the brief.

## The role catalog

The canonical role contracts live one file per role in `roles/` under this skill directory.
Each role file opens with a machine-readable `kinds:` line (`scout`, `ship`, or `scout|ship`) declaring which deliverable kinds the role may serve.
`fm-brief.sh --role <name>` reads and injects that file verbatim into the brief (dropping the machine line), and `fm-spawn.sh --role <name>` validates the same catalog and records the role in the task's meta.
Both scripts reject a role-kind contradiction at scaffold or spawn time, so a Builder contract can never land in a report-only scout brief.
Never restate a role contract outside its file (one-owner rule); reference it by name and file instead.

| Role | Kind | When | Handoff |
| --- | --- | --- | --- |
| assistant | inline or scout | Simple questions, status digests, light research, clarification, ad-hoc non-code tasks, parallel support. Default when no specialized role fits. | planner / architect / researcher |
| planner | scout | High-level or multi-step requests, vague requirements, new features with unclear scope, roadmaps, approach questions. | architect / builder |
| architect | scout | Non-trivial features, new subsystems, major refactors, greenfield work, real technical trade-offs. Before substantial coding. | designer / builder |
| designer | scout | User-facing features, frontend components, interface detail, accessibility, interaction flows, after the architect. | builder |
| builder | ship | Clear plan or design exists and the goal is working, tested code. Primary role for most ship tasks. | reviewer / debugger |
| debugger | scout or ship | Bugs, test failures, unexpected behavior, regressions, performance issues. Scout (report only) by default; ship only when a fix is authorized. | builder / reviewer |
| reviewer | scout | Independent quality critique of a PR or branch, or design review, only when the captain requests a separate review deliverable. | - |
| researcher | scout | Deep investigation without mutation: how does X work, library evaluation, codebase mapping, bug reproduction, audits, pre-planning. | planner / architect |
| tester | scout or ship | Verification and test coverage alongside or after the builder, or a standalone test strategy. | reviewer |

The `kinds:` line is the machine-readable form of the Kind column; they never disagree.

## Assign a role at intake

1. Classify the deliverable shape first per ADLC (`docs/adlc-standard.md`): ship is the default once implementation is authorized; scout fires when unresolved uncertainty could change what to build, or the captain asks for investigation or design only.
2. Pick the role that best names the work using the catalog table above.
   Default to `assistant` when no specialized role clearly fits.
   For a bug report, `debugger` is the default role and it is scout until a fix is authorized.
3. Resolve the role onto a concrete spawn:
   - Scout-kind roles spawn with `fm-brief.sh --scout --role <name>` and `fm-spawn.sh --scout --role <name>`.
   - Ship-kind roles spawn with `fm-brief.sh --role <name>` and `fm-spawn.sh --role <name>`.
   - `assistant` work answered inline never spawns and records no task.
4. Map effort per the harness-adapters policy, not a per-role copy of it:
   investigation and design roles (planner, architect, designer, researcher, debugger-scout) default to ambiguous-investigation effort, builder and tester to well-understood-effort, and an explicit captain or standing configured effort always wins.
5. Relay outcomes to the captain in plain role language (the investigation, the plan, the design, the fix, the review, the tests, the PR), per `AGENTS.md` section 9.

## Constraints

- Roles do not change the hard rules in `AGENTS.md` section 1: no project writes by firstmate, no merge without captain word, no discard of unlanded work.
- A role never overrides the configured merge authority or delivery mode; `--role` and `--scout`/`--secondmate` are independent axes.
- `--role` is rejected for `--secondmate` charters: a secondmate is a persistent domain, not a task role.
- The reviewer role is a separate review deliverable only when the captain explicitly requests one; it never stacks on top of the selected delivery path's own gate.
