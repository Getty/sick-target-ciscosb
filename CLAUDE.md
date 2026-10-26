# CLAUDE.md — SICK-Target-CiscoSB

Device type `cisco-sb` for SICK (`../sick`): TLS certificates for the web interface of
Cisco Small Business switches (Sx300/SG300/SG500), over the switch's SSH command line.
Dist `SICK-Target-CiscoSB`, main module `SICK::Target::CiscoSB`. What the switch does is
in `docs/device-notes.md`; the family's handbook is in `../sick/docs/handbook/`.

Build and test: `prove -lr t` (serial, no `-j`), `dzil build`. The core comes from the
checkout beside this one: `PERL5LIB=../sick/lib:$PERL5LIB prove -lr t`. Never
`dzil release` without explicit permission. `LICENSE` is committed.

The repository's decisions and hazards are in `.claude/rules/sick-ciscosb-rules.md`; read
the hazards before the first change — the other end of this code is a real switch.

## Delegation

Delegate behavior-relevant code to the right agent instead of touching it yourself —
principle in the shared rule `getty-agent-delegation` (skilletor bundle
`getty-cpan-dist@getty`), lanes in `.claude/rules/sick-ciscosb-rules.md`.

| Task | Agent |
|---|---|
| Implement / refactor / debug / test anything under `lib/` and `t/` | `sick-worker-ciscosb` (default) |
| Commits, `Changes`, card → done, pre-release audit | `sick-release-manager` |
| Route a card to another repository of the family | `karr-coordinator` |
| Read-only research, audit, gap analysis | `sick-worker-ciscosb` ("read-only, change nothing") |

Every subagent is one of these agents — never the built-in `general-purpose`/`Explore`/`Plan`.

The agents carry their skills via `briefing.skills` (see `.claude/agents/`); the main agent
delegates rather than loading them. Everything under `.claude/skills/` and the agent
`karr-coordinator` are installed by skilletor (`.claude/skilletor.json`) and changed in
their source, never here — `sick-core` (the Target contract) and `sick-coordination` (who
owns what in the family) come from `../sick`.

## Layout

```
lib/SICK/Target/CiscoSB.pm                   options, csr, deploy: the certificate commands
lib/SICK/Target/CiscoSB/Session.pm           the dialog: login, prompts, echo, questions, paging, timeouts
lib/SICK/Target/CiscoSB/Transport.pm         the role both transports share
lib/SICK/Target/CiscoSB/Transport/SSH.pm     bytes through `ssh -tt` on pipes
lib/SICK/Target/CiscoSB/Transport/Replay.pm  bytes from a script, strict about what is written
t/lib/Test/SICK/CiscoSB.pm                   the recorded dialogs as script builders
t/bin/fake-ssh                               stand-in for ssh
t/10-session.t, 11-transport-ssh.t, 20-deploy-replay.t, 90-live.t
docs/device-notes.md                         what an SG300-20 (1.4.11.5) does
```
