# SICK-Target-CiscoSB

Device type `cisco-sb` for [SICK](https://metacpan.org/dist/SICK) – *Ship
Internal Certificates & Keys*: certificates of your internal CA for the web
interface of **Cisco Small Business switches** (Sx300, SG300, SG500 and their
relatives), installed and kept current without anybody pasting PEM into a
browser.

SICK decides when a certificate is due, has it issued by your
[step-ca](https://smallstep.com/docs/step-ca/) and checks afterwards that the
switch really presents it. This distribution is the part in between: it logs
in to the switch over SSH and types what you would type.

> Status: early, not released. Worked out and tested on an SG300-20 with
> firmware 1.4.11.5; see [docs/device-notes.md](docs/device-notes.md) for what
> that switch does, dialog by dialog.

## Synopsis

```yaml
# /etc/sick/sick.yml
ca:
  url: https://ca.example.internal:9000
  root: /etc/sick/root_ca.crt
  provisioner: sick
  password_file: /etc/sick/provisioner.pw
devices:
  switch:
    type: cisco-sb
    host: 192.0.2.10
    names: [switch.example.internal, 192.0.2.10]
    credentials: /etc/sick/switch.cred
    legacy_algorithms: true
```

```text
$ sick check
DEVICE  STATUS      RENEW  DETAIL
switch  foreign-ca  yes    issued by CN=switch.example.internal

$ sick run --verbose switch
switch: foreign-ca (issued by CN=switch.example.internal)
switch: issuing a certificate for switch.example.internal, 192.0.2.10
switch: deploying
switch: connecting to 192.0.2.10 port 22
switch: logged in, the switch calls itself sw1
switch: sending: terminal datadump
switch: sending: configure terminal
switch: importing the certificate and its key into slot 1
switch: sending: crypto certificate 1 import
switch: pasting 56 lines
switch: making certificate 1 the active one
switch: sending: ip https certificate 1
switch: sending: end
switch: sending: show ip https
switch: saving the configuration
switch: sending: copy running-config startup-config
switch: answering 'Overwrite file [startup-config].... (Y/N)[N] ?' with Y
switch: renewed, the device presents the new certificate
DEVICE  ACTION   REASON      ERROR
switch  renewed  foreign-ca

$ sick run switch
DEVICE  ACTION     REASON  ERROR
switch  unchanged  ok
```

One run takes about 25 seconds per switch.

## Description

### The credentials file

Two lines: the user name, the password. The user needs the privileged command
line (level 15).

```
admin
the-password
```

```bash
chmod 600 /etc/sick/switch.cred
```

The password is typed at the `Password:` prompt of the switch and nowhere
else: it is never on a command line, in the environment, in a log line or in
an error message.

### Options

| Key | Default | |
|---|---|---|
| `credentials` | required | path of the credentials file |
| `ssh_port` | `22` | SSH port of the switch |
| `legacy_algorithms` | `false` | let `ssh` use the old key exchange, host key, cipher and MAC algorithms these switches need; firmware 1.4.11.5 still needs it |
| `slot` | `1` | which of the two certificate slots (`1` or `2`) is filled and made active |
| `mode` | `import` | `import`: SICK makes the key and pastes key and certificate. `csr`: the switch writes a certificate request for its own key |
| `save` | `true` | `copy running-config startup-config` afterwards – which saves *everything* unsaved on the switch |
| `host_key_check` | `strict` | `strict`: the host key has to be in the known hosts file. `accept-new`: a switch that is not in the file yet is added, a changed key is still refused |
| `known_hosts` | that of `ssh` | a known hosts file of your choice |

`host`, `port` (HTTPS, `443`), `names`, `lifetime`, `renew_before` and `key`
are the general settings of SICK. `key` has to be `rsa2048` or `rsa3072`;
`rsa4096` can be imported, but the switch then needs 13 seconds for every TLS
handshake.

### `import` or `csr`

`import` is the default because it works with every CA and every list of
names. The key crosses the SSH connection.

With `csr` the key never leaves the switch. The catch: the request the switch
writes names one host and has no subject alternative names, so the CA would
have to add the names on its own. step-ca signs what a request asks for, and
SICK refuses to send it a request whose names differ from the device's – so
with step-ca, `csr` is for devices with exactly one name. And when the slot
has no key of the right size, the switch generates one first, which takes it
up to a minute and a half.

### What you should know about these switches

- **One certificate, no chain.** The switch stores and presents the
  certificate alone. Clients need the intermediate certificate of your CA
  from somewhere else, and SICK needs it to recognize the certificate as its
  own: let the `root` file of the device list hold root *and* intermediate.
- **RSA only.** EC keys are refused by the switch, and by this target before
  it connects.
- **A wrong certificate costs the key.** Given a certificate that does not
  belong to the key of the slot, the switch refuses it *and deletes key and
  certificate of that slot*. This target compares the keys itself and never
  sends such an import; keep it in mind when you paste by hand.
- **Old SSH.** Key exchange `diffie-hellman-group-exchange-sha1`, host key
  `ssh-rsa`. `legacy_algorithms: true` adds them to what `ssh` offers – for
  this device only.
- **The host key is always checked.** `ssh-keyscan` cannot talk to these
  switches; connect once by hand, or use `host_key_check: accept-new`:

  ```bash
  ssh -o KexAlgorithms=+diffie-hellman-group-exchange-sha1 -o HostKeyAlgorithms=+ssh-rsa admin@192.0.2.10
  ```
- **Login at the prompts of the switch.** SSH-level authentication
  (`ip ssh password-auth`, `ip ssh pubkey-auth`) is not supported.

### How it talks to the switch

`SICK::Target::CiscoSB` knows the certificate commands.
`SICK::Target::CiscoSB::Session` is the dialog: the login, prompts with log
lines behind them, redrawn and scrolled lines, `(Y/N)` questions, paging, and
a time limit on every wait that says what was waited for.
`SICK::Target::CiscoSB::Transport::SSH` carries the bytes through the `ssh`
program of the system (`$SICK_SSH`, else `ssh` from the `PATH`); your
`~/.ssh/config` applies, which is how a jump host is set up.
`SICK::Target::CiscoSB::Transport::Replay` plays a recorded dialog instead –
the tests run on it.

## Installation

```bash
cpanm SICK-Target-CiscoSB
```

From a checkout:

```bash
cpanm --installdeps .
prove -lr t
```

At run time it calls `ssh` (OpenSSH) and, like SICK itself, `openssl`.

## Tests

`prove -lr t` needs no network and no switch: the dialogs are recordings.

To run against a real switch – **this replaces its certificate and saves its
configuration**:

```bash
SICK_LIVE_CISCOSB_HOST=192.0.2.10 \
SICK_LIVE_CISCOSB_CREDENTIALS=/path/to/switch.cred \
prove -lv t/90-live.t
```

More settings of that test are described at the top of `t/90-live.t`.

## License

This is free software; you can redistribute it and/or modify it under the same
terms as the Perl 5 programming language system itself.
