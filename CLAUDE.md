# CLAUDE.md — SICK-Target-CiscoSB

Device type `cisco-sb` for SICK (`~/dev/sick`): TLS certificates for the web
interface of Cisco Small Business switches (Sx300/SG300/SG500), over the
switch's SSH command line. Dist `SICK-Target-CiscoSB`, main module
`SICK::Target::CiscoSB`. Design and plan live in the hub:
`~/dev/perl-developer/docs/superpowers/specs/2026-10-05-sick-design.md` (section 4)
and `.../plans/2026-10-05-sick-phase-1.md` (Aufgabe 6).

Build and test: `prove -lr t` (serial, no `-j`), `dzil build`. SICK has to be on
`PERL5LIB` while it is not installed: `PERL5LIB=~/dev/sick/lib:$PERL5LIB prove -lr t`.
Never `dzil release` without explicit permission. `LICENSE` is committed.

## Rules of this repo

- **`docs/device-notes.md` is the source of truth** for what the switch does. Code
  that depends on a behaviour of the switch has that behaviour written down there
  first, with how it was observed. Do not write a dialog from memory or from Cisco's
  manuals.
- **Perl follows the house rules** (skills `getty-perl-core`, `getty-perl-moo`): Moo for
  classes, `Path::Tiny` for files, `JSON::MaybeXS` for JSON, and what CPAN already has is
  taken from there. The two transports share the role `SICK::Target::CiscoSB::Transport`,
  which the session demands.
- **The transport is the `ssh` program.** `Net::LibSSH` 0.004 cannot do what is needed
  (see the notes); that is a finding, not a rule of taste. External programs go through
  `SICK::Command` / `SICK::OpenSSL`, or the fork/exec in `Transport::SSH` - never a shell.
- **No secrets** in code, tests, fixtures, logs or messages. The password is only
  ever written to the transport. Whatever the switch echoes during the login and
  during a paste (it echoes private keys) is dropped unread and never quoted.
- **What can damage a switch or leak a key is in `.claude/rules/sick-ciscosb-rules.md`**
  (hazards): the live test, the refusal that empties a slot, echo, typing ahead, the
  recorded dialogs. Read them before the first change.
- `# ABSTRACT:` lines are plain ASCII; every file under `lib/` carries its own
  `our $VERSION`.

## Delegation

Delegate behavior-relevant code to the right agent instead of touching it yourself — the
principle, the lanes and this repo's hazards are in `.claude/rules/sick-ciscosb-rules.md`.

| Task | Agent |
|---|---|
| Implement / refactor / debug / test anything under `lib/` and `t/` | `sick-worker-ciscosb` (default) |
| Commits, `Changes`, card → done, pre-release audit | `sick-release-manager` |

The agents carry their conventions via `briefing.skills` (see `.claude/agents/`); the main
agent delegates rather than loading them. The skills under `.claude/skills/` are installed
by skilletor (`.claude/skilletor.json`) and are changed in their source, never here —
`sick-core`, the Target contract this distribution implements, comes from `../sick`.

## Layout

```
lib/SICK/Target/CiscoSB.pm                   options, csr, deploy: the certificate commands
lib/SICK/Target/CiscoSB/Session.pm           the dialog: login, prompts, echo, questions, paging, timeouts
lib/SICK/Target/CiscoSB/Transport/SSH.pm     bytes through `ssh -tt` on pipes
lib/SICK/Target/CiscoSB/Transport/Replay.pm  bytes from a script, strict about what is written
t/lib/Test/SICK/CiscoSB.pm                   the recorded dialogs as script builders
t/bin/fake-ssh                               stand-in for ssh
t/10-session.t, 11-transport-ssh.t, 20-deploy-replay.t, 90-live.t
docs/device-notes.md                         what an SG300-20 (1.4.11.5) does
```
