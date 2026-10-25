# SICK-Target-CiscoSB House Rules

The shared house rules come from skilletor — bundle `getty-cpan-dist@getty`: engineering
discipline, the delegation lock, the publish gate, karr coordination, CPAN release. They load
as `.claude/rules/.local.*.md`; if they are missing, run `skilletor sync` and publish nothing
until they load. This file adds what is true only here, and wins where it differs. Bias:
caution — the other end of this code is a switch that cannot be reinstalled from here.

## What this repo is

SICK target for Cisco Small Business switches (Sx300, SG300, SG500). Read first:
`docs/device-notes.md`, then the module. A dialog comes from an observation recorded there,
never from memory and never from Cisco's manuals; where the code and the device notes
disagree, the notes are right until a new observation is written into them.

**Who decided what:** "Core Perl and `SICK`, plain `bless`" is the maintainer's recorded rule
for this repository, not yours.

## Agent team

| Task | Agent |
|---|---|
| Implement / refactor / debug / test anything under `lib/` and `t/` | `sick-worker-ciscosb` (default) |
| Commits, `Changes`, card → done, pre-release audit | `sick-release-manager` |
| Read-only research, audit, gap analysis | `sick-worker-ciscosb` ("read-only, change nothing") |

Behavior-relevant = everything under `lib/` and `t/`. Prose in `README.md`, `docs/` and
`CLAUDE.md` is not — but `docs/device-notes.md` only ever gains what was observed.

What this distribution needs from the core (`SICK::Target`, `SICK::Command`, `SICK::OpenSSL`,
`SICK::Bundle`, `SICK::Temp`) is a card on the board of `../sick`, with a pointer here — never
an edit over there. The Target contract lives in `sick-core` (installed from `../sick`,
changed there).

## Release

Any change to the visibility of the GitHub repository is under the publish gate too.

## Hazards

Short form; the mechanisms live in `docs/device-notes.md` and in the agents' own lane notes.

- **`t/90-live.t` changes a real switch** — certificate, active slot, saved configuration — as soon as `SICK_LIVE_CISCOSB_HOST` and `SICK_LIVE_CISCOSB_CREDENTIALS` are set. Never set them, never run it, unless told to for a named switch. "Tests pass" says which ran: `t/90-live.t` is skipped unless asked for.
- **A refused import empties the certificate slot.** The check that key and certificate belong together is never weakened, reordered or skipped for a test.
- **What the switch echoes during a paste is a private key.** Echo of the login and of a paste is dropped unread: never logged, never quoted in a message, a test name, a card or a report. The password goes to the transport and nowhere else.
- **Never type ahead, never send `?`.** One command, then its prompt. `Session::command` refuses control characters; keep it that way.
- **Recorded dialogs are evidence.** A dialog is not edited to make a test pass; it changes when the notes do.
- **Two checks look like one** — the key against the certificate, and the certificate in the slot against the public key. Neither replaces the other.
- **SICK is not installed** — `PERL5LIB=../sick/lib:$PERL5LIB prove -lr t`; without it every file fails at `use`. `../sick` moving is the usual reason for a red suite here: check its log before you look for the bug in this repository.
- **An untracked file does not exist for `dzil`** — `[@Author::GETTY]` gathers tracked files only; `prove` runs the untracked test and stays green. `git add` early.

## Perl specifics — reference, don't restate

House style, Moo, POD and release mechanics live in `getty-perl-core`, `getty-perl-moo`,
`getty-perl-pod` and `getty-perl-release-author-getty` (force-loaded for `sick-*` agents).
