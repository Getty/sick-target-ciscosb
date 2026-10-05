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
- **Dependencies: core Perl and `SICK`.** The transport is the `ssh` program;
  `Net::LibSSH` 0.004 cannot do what is needed (see the notes). Classes are plain
  `bless`, external programs go through `SICK::Command` / `SICK::OpenSSL`, or the
  fork/exec in `Transport::SSH` - never a shell.
- **No secrets** in code, tests, fixtures, logs or messages. The password is only
  ever written to the transport. Whatever the switch echoes during the login and
  during a paste (it echoes private keys) is dropped unread and never quoted.
- **Recorded dialogs carry neutral names** (`sw1`, `192.0.2.10`, user `admin`) and no
  certificates or keys: tests generate those at run time.
- **Never send an import the switch will refuse for a key mismatch**: it answers by
  deleting key and certificate of the slot (device notes, "The refusal that
  destroys"). `deploy` compares the public keys first; keep that check.
- **Never type ahead** at the switch and never send `?`. One command, then its
  prompt. `Session::command` refuses control characters.
- Unit tests need no network. `t/90-live.t` runs only with
  `SICK_LIVE_CISCOSB_HOST` and `SICK_LIVE_CISCOSB_CREDENTIALS` set, and it
  **changes the switch** (certificate, active slot, saved configuration).
- `# ABSTRACT:` lines are plain ASCII; every file under `lib/` carries its own
  `our $VERSION`.

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
