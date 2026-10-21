# SICK-Target-CiscoSB House Rules

Apply to every task in this repository unless explicitly overridden. Bias: caution over speed — the other end of this code is a switch that cannot be reinstalled from here. Subagents get their conventions from the skills force-loaded via `briefing.skills`; skill content is never restated here, this file is for the orchestrating agent. House style, Moo, POD and release mechanics live in `getty-perl-core`, `getty-perl-moo`, `getty-perl-pod` and `getty-perl-release-author-getty`, the Target contract in `sick-core` (installed from `../sick`, changed there).

## Engineering discipline

1. **Think before coding** — State assumptions; ask rather than guess. Push back when a simpler approach exists. Stop when confused; name what's unclear.
2. **A design choice of yours is not a requirement of the maintainer** — write down who decided what. "Core Perl and `SICK`, plain `bless`" is his recorded rule for this repository, not yours.
3. **Simplicity first, surgically applied** — minimum code that solves the problem, nothing speculative; touch only what you must.
4. **Read before you write** — `docs/device-notes.md` first, then the module. A dialog comes from an observation recorded there, never from memory and never from Cisco's manuals.
5. **Tests verify intent, not just behavior** — reproduce a bug before fixing it, leave the regression test behind. A red test is a claim: say what it asserts before you change code to turn it green.
6. **Checkpoint and fail loud** — summarize done / verified / left after each significant step. "Tests pass" says which ran: `t/90-live.t` is skipped unless asked for.
7. **Surface conflicts, don't average them** — where the code and the device notes disagree, the notes are right until a new observation is written into them.

## Delegation

Depends on whether the Agent/Task tool is available to you.

- **You can spawn subagents** (orchestrating main agent): do NOT touch behavior-relevant code yourself — delegate. Your lane: coordinate, inspect, plan, review diffs, run tests, edit prose. When in doubt, delegate. Why: only the `sick-*` agents get their skills force-loaded via `briefing.skills`; you get no briefing.

  | Task | Agent |
  |---|---|
  | Implement / refactor / debug / test anything under `lib/` and `t/` | `sick-worker-ciscosb` (default) |
  | Commits, `Changes`, card → done, pre-release audit | `sick-release-manager` |

- **You cannot spawn subagents** (you ARE a `sick-*` agent): the lock does not apply — work per these rules.

Behavior-relevant = everything under `lib/` and `t/`. Prose in `README.md`, `docs/` and `CLAUDE.md` is not — but `docs/device-notes.md` only ever gains what was observed.

**Only `sick-release-manager` commits.** The worker leaves a commit-ready tree and hands its card to `review`; you then dispatch the release-manager.

## Coordination — karr board (always in scope)

`karr` is always in scope — just use it. State lives in `refs/karr/*` of this repo.

- `karr list --compact` / `karr board` — open work · `karr show ID` — detail
- `karr create "Title" --priority high --tags a,b --body '…'` · `karr edit ID -a "note"` · `karr move ID in-progress --claim NAME` — full surface: skill `kanban-issues-karr-coordination`

What this distribution needs from the core (`SICK::Target`, `SICK::Command`, `SICK::OpenSSL`, `SICK::Bundle`, `SICK::Temp`) is a card on the board of `../sick`, with a pointer here — never an edit over there. **Serialize board mutations when fanning out** — collect the results, then loop `karr move`/`handoff`/`sync` one after the other.

## Release and everything outward — never without permission

`dzil build` / `dzil test` are fine anytime. `dzil release`, `git push` and any change to the visibility of the GitHub repository need the maintainer's explicit go-ahead — also when a plan lists them as the next step. For anything heading toward release: stop and ask.

## Public issues (GitHub) — never act without instruction

`github.com/Getty/sick-target-ciscosb` is a **public tracker**. Never act on an issue there on your own initiative — not even to read it: no listing, viewing, commenting, editing, closing or creating unless explicitly told to handle a specific issue. GitHub issues are not a queue to drain; karr is the internal agent board.

## Hazards specific to this repository

Short form; the mechanisms live in `docs/device-notes.md` and in the agents' own lane notes.

- **`t/90-live.t` changes a real switch** — certificate, active slot, saved configuration — as soon as `SICK_LIVE_CISCOSB_HOST` and `SICK_LIVE_CISCOSB_CREDENTIALS` are set. Never set them, never run it, unless told to for a named switch.
- **A refused import empties the certificate slot.** The check that key and certificate belong together is never weakened, reordered or skipped for a test.
- **What the switch echoes during a paste is a private key.** Echo of the login and of a paste is dropped unread: never logged, never quoted in a message, a test name, a card or a report. The password goes to the transport and nowhere else.
- **Never type ahead, never send `?`.** One command, then its prompt. `Session::command` refuses control characters; keep it that way.
- **Recorded dialogs are evidence.** A dialog is not edited to make a test pass; it changes when the notes do.
- **Two checks look like one** — the key against the certificate, and the certificate in the slot against the public key. Neither replaces the other.
- **SICK is not installed** — `PERL5LIB=../sick/lib:$PERL5LIB prove -lr t`; without it every file fails at `use`. `../sick` moving is the usual reason for a red suite here: check its log before you look for the bug in this repository.
- **An untracked file does not exist for `dzil`** — `[@Author::GETTY]` gathers tracked files only; `prove` runs the untracked test and stays green. `git add` early.
