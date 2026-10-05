# Device notes: Cisco Small Business switches

What the command line of an Sx300 does when certificates are involved, as
observed on a real switch on 2026-10-05. Everything `SICK::Target::CiscoSB`
does follows from this file; the dialogs in `t/lib/Test/SICK/CiscoSB.pm` are
these recordings with names and addresses replaced.

| | |
|---|---|
| Model | SG300-20 |
| Firmware | 1.4.11.5 (2020-04-08, the last release for the SG300) |
| Boot code | 1.3.5.06 |
| SSH server | `OpenSSH_5.9p1.RL` |
| HTTPS | TLS 1.2, cipher `AES256-GCM-SHA384` (RSA key exchange) |
| Client | OpenSSH 10.0p2, OpenSSL 3.5 |

In the transcripts the switch is `sw1` at `192.0.2.10`, `\r` and `\n` are
carriage return and line feed, `ESC` is the escape character. Nothing below
is taken from Cisco's documentation unless it says so.

## Summary

- Login is in-band: SSH lets everybody in (method `none`), the switch then
  asks `User Name:` and `Password:` itself.
- Only an interactive shell with a terminal works. `exec` requests hang.
- `crypto certificate <1|2> import` (config mode) takes one certificate, or
  an RSA private key in PKCS#1 form, its public key and one certificate.
- `crypto certificate <1|2> request` (command level, not config mode) writes
  a certificate request for the key of the slot. It has a subject and
  nothing else: **no subject alternative names**.
- `ip https certificate <1|2>` selects the slot; the web server restarts by
  itself in about three seconds. An import into the active slot is served
  right away as well.
- **A certificate that does not fit the key of the slot is refused, and the
  switch then deletes the key and the certificate of that slot.** The target
  compares the keys itself before it imports anything.
- **Default mode of the target: `import`.** See [the last section](#which-mode-is-the-default-and-why).

## SSH

The server offers (seen with `ssh -v`):

| | Offered by the switch | In OpenSSH 10 defaults |
|---|---|---|
| Key exchange | `diffie-hellman-group-exchange-sha1`, `diffie-hellman-group1-sha1` | neither |
| Host key | `ssh-rsa`, `ssh-dss` | neither |
| Cipher | `aes128-ctr` was negotiated | yes |
| MAC | `hmac-sha1` was negotiated | yes |

So a current `ssh` needs at least

```
-o KexAlgorithms=+diffie-hellman-group-exchange-sha1 -o HostKeyAlgorithms=+ssh-rsa
```

and without them fails with

```
Unable to negotiate with 192.0.2.10 port 22: no matching key exchange method found. Their offer: diffie-hellman-group-exchange-sha1,diffie-hellman-group1-sha1
```

`ssh` prints that at log level INFO, not ERROR. `legacy_algorithms: true`
adds those two and, for older firmware, `diffie-hellman-group14-sha1`,
`diffie-hellman-group1-sha1`, the CBC ciphers `aes128-cbc`, `aes256-cbc`,
`3des-cbc` and `hmac-sha1`. On 1.4.11.5 the ciphers and the MAC are not
needed; older firmware was not available to test.

`diffie-hellman-group14-sha1` is *not* offered by this firmware.

Authentication: `Authenticated to 192.0.2.10 ([192.0.2.10]:22) using "none".`
The user name of the SSH connection is ignored. The target passes
`BatchMode=yes` and switches every authentication method off, so `ssh` never
asks for anything; a switch configured for SSH password or public key
authentication (`ip ssh password-auth`, `ip ssh pubkey-auth`) is not
supported.

`ssh host command` hangs forever: the switch accepts the `exec` request and
never answers. A terminal has to be requested (`-tt`); the target runs `ssh`
on pipes, which works because `-tt` forces the request.

`ssh-keyscan` cannot fetch the host key of this switch (it has no way to
enable the old key exchange). Put the key into `known_hosts` by connecting
once by hand with the two options above, or set `host_key_check: accept-new`.

### Why not Net::LibSSH

The design named `Net::LibSSH` as the transport. Version 0.004 (libssh
0.11.5) cannot reach this switch, for four independent reasons:

1. no `none` authentication (`ssh_userauth_none` is not bound; there are
   `auth_password`, `auth_publickey`, `auth_agent` only);
2. no interactive shell: a channel can `exec`, but there is no
   `request_pty` / `request_shell`;
3. no read with a time limit and no non-blocking read on a channel: `read`
   blocks until data or EOF, so a prompt cannot be waited for;
4. no option for key exchange, host key, cipher or MAC algorithms
   (`option` knows `host`, `port`, `user`, `knownhosts`, `timeout`,
   `compression`, `log_verbosity`, `strict_hostkeycheck`). `connect` fails
   with `kex error : no match for method kex algos: server
   [diffie-hellman-group-exchange-sha1,diffie-hellman-group1-sha1], client [...]`.

The transport is therefore the `ssh` program. It sits behind a five-method
interface (`open`, `write`, `read($seconds)`, `close`, `error`), so a
`Transport::LibSSH` can be added once the binding has those four things.

## Login

```
\r\n\r\r\n\r\n\r\nUser Name:            <- sent by the switch after connecting
admin\r                                 -> typed
admin\r\n\rPassword:                    <- the user name is echoed
<password>\r                            -> typed
**************\r\n\r\r\n\r\nsw1#        <- one asterisk per character, then the prompt
```

About 2.8 seconds from starting `ssh` to the prompt.

A wrong password was **not tried** on the test switch. The target treats a
second `User Name:` or `Password:` prompt after the password as a refused
login; that is how the family is known to react, but it is not a recording.

A user without privilege level 15 would get a `>` prompt and cannot
configure; the target stops there. Also not tried.

## The command line

**Prompt.** `sw1#` at the command level, `sw1(config)#` after
`configure terminal`. `end` leaves config mode, `exit` at the command level
closes the connection.

**Echo.** Every command is echoed and followed by `\r\n\r`; lines of an
answer end in `\r\n` or `\r\r\n`.

```
show version\r                          -> typed
show version\r\n\rSW version    1.4.11.5 ( date  08-Apr-2020 time  13:49:34 )\r\n...\r\nsw1#
```

**Long lines scroll.** A command that does not fit into the 80 columns is
echoed up to the edge, then the line is redrawn shifted, with `$` for what
was cut off:

```
crypto certificate 2 generate key-generate 2048 cn sw1.example.in\rsw1(config)#ESC[K$ficate 2 generate key-generate 2048 cn sw1.example.internal\r\n\r
```

The end of the command always arrives in one piece in front of the line
feed; the target recognizes the echo by that.

**Redrawn prompts.** After an import the switch sometimes draws its prompt
twice, the second time over the first:

```
sw1(config)#\rESC[Ksw1(config)#
```

This was seen both immediately after the answer to the import and at the
first key press afterwards, in which case the redraw can arrive *before* the
echo of the next command. Reading the output the way a terminal shows it
(carriage return = back to column 0, `ESC[K` = erase to end of line) and
skipping to the end of the echo before looking for a prompt deals with both.
This is one of the two places where the first version of the target failed
on the real switch; the other is the empty line in front of the period of
an import, below.

**Log lines.** The switch writes lines of its log into the session, for
example when another session logs in or out:

```
05-Oct-2026 05:43:09 %AAA-I-CONNECT: User CLI session for user admin over ssh , source 192.0.2.50 destination  192.0.2.10 ACCEPTED, aggregated (5)\r\r\n
```

They appear between the lines of an answer, during the silence of a key
generation, and - seen while the switch was set up by hand - directly
behind a prompt on the same line
(`sw1(config-if)#05-Oct-2026 03:01:27 %LINK-W-Down: Po1`), after which the
switch does *not* print a new prompt. There is no per-session command to
turn them off (`terminal ?` offers `datadump`, `history`, `prompt`, `width`).
The target removes everything that looks like
`DD-Mon-YYYY HH:MM:SS %FACILITY-S-MNEMONIC: text`.

**Paging.** Long answers stop after a screen:

```
ESC[0mMore: <space>,  Quit: q or CTRL+Z, One line: <return> 
```

A space continues; the switch then wipes the line with `\r`, 54 blanks and
`\r`. `terminal datadump` turns paging off for the session and is the first
command the target sends.

**Confirmations** have escape sequences around the default letter and are
answered with a single key, without return:

```
Overwrite file [startup-config].... (Y/N)[ESC[1mNESC[0m] ?
```

**Errors** of the command line start with a per cent sign:

```
% Unrecognized command
% Wrong number of parameters or invalid range, size or characters entered
```

The refusals of `crypto certificate import` (below) do not.

**Help.** `?` prints help immediately, without return, and redraws the
line. Ctrl-U clears the line. The target never sends a `?`.

**No typing ahead.** While the switch generates a key it reads nothing, and
what was typed in the meantime is lost - a command sent after 60 seconds of
an 85 second key generation never ran.

## Looking at the certificates

```
sw1#show ip https
HTTPS server enabled. Port: 443
Certificate 1 is active.
 Issued by : C=  , ST= , L= , CN=sw1.example.internal, O= , OU= 
 Valid From: Oct  5 01:25:33 2026 GMT
 Valid to: Oct  2 01:25:33 2036 GMT
 Subject: C=  , ST= , L= , CN=sw1.example.internal, O= , OU= 
 SHA1 Fingerprint: D0AFBF6F 744647A4 0BFD3AE1 68F0398F DBF381F0 
Certificate 2 is not active.
 Issued by : ...
Interactive secure server timeout: 10 minutes, 0 seconds.
```

```
sw1#show crypto certificate mycertificate 1
Certificate 1:
-----BEGIN CERTIFICATE-----
...
-----END CERTIFICATE-----
 Issued by : C=  , ST= , L= , CN=sw1.example.internal, O= , OU= 
 Valid From: ...
```

There are two slots. Both held a certificate and a key on the test switch
from the start (the second one a default from 2013, shown as
`Certificate 2:(default)`); the private key cannot be displayed.

A slot can be empty - after the refusal described under
[Import](#import-mode-import-and-the-second-half-of-mode-csr):

```
sw1#show ip https
...
Certificate 2 does not exist.
sw1#show crypto certificate mycertificate 2
Private key instance 2 does not exist.  To create a certificate, use the "crypto certificate [1-2] generate" in global configuration mode.
```

An import with a key fills an empty slot again; so does `generate`.

## Certificate request (mode `csr`)

At the command level - in config mode the command does not exist:

```
sw1#crypto certificate 1 request cn sw1.example.internal
-----BEGIN CERTIFICATE REQUEST-----
...
-----END CERTIFICATE REQUEST-----
sw1#
```

Parameters: `cn`, `or`, `ou`, `loc`, `st`, `cu`. There is none for
alternative names. The request

- is for the key that is in the slot, generated there or imported;
- has the subject `C=  , ST= , L= , CN=<cn>, O= , OU= ` - the fields that
  were not given are present and hold blanks;
- has no attributes and no extensions, so **no subject alternative names**;
- is signed with SHA-256.

A new key is made in config mode, together with a self-signed certificate
that replaces the one in the slot at once (and is served at once when the
slot is the active one):

```
sw1(config)#crypto certificate 1 generate key-generate 2048 cn sw1.example.internal
```

Key length `<2048-3072>`; further parameters as for `request`, plus
`duration <days>` (365 when left out). The switch prints nothing on success
and is silent while it works: 92 and about 85 seconds for 2048 bits in two
measurements, roughly 30 and roughly 100 in two more (estimated from the
length of the whole run). Without `key-generate` the key of the slot is
kept and the command returns after 4 seconds.

The target generates a key only when the certificate in the slot does not
already have an RSA key of the wanted size, and otherwise reuses the key.

Importing the signed certificate: as below, the certificate alone.

## Import (mode `import`, and the second half of mode `csr`)

```
sw1(config)#crypto certificate 1 import
Please paste the input now, add a period (.) on a separate line after the input
-----BEGIN RSA PRIVATE KEY-----         -> every pasted line is echoed, the key included
...
-----END RSA PRIVATE KEY-----
-----BEGIN RSA PUBLIC KEY-----
...
-----END RSA PUBLIC KEY-----
-----BEGIN CERTIFICATE-----
...
-----END CERTIFICATE-----
.
Certificate imported successfully
 Issued by : CN=Example Test CA
 Valid From: Oct  5 03:35:02 2026 GMT
 Valid to: Nov  4 03:35:02 2026 GMT
 Subject: CN=sw1.example.internal
 SHA1 Fingerprint: 1218A664 871DA758 29941063 B28FD831 0628FC56 
sw1(config)#
```

The switch reads to the period and judges then. The target sends one line
at a time and waits for its echo before the next - the echo is the only
flow control, and it comes back at about five lines a second. (Sending
blind with a pause of 50 ms per line also worked in the experiments.) Because the echo contains the private key, the target throws
it away unread and never logs or quotes anything from this phase.

In about every second recording the switch put an empty line in front of
the echo of the period (`\r\n\r.\r\n` instead of `.\r\n`). The answer
starts behind the period, not behind the next line feed - the second thing
the first version of the target got wrong, and it showed only in the error
path: every refusal was reported as `.`.

What is accepted, and what is left of the slot afterwards:

| Pasted | Answer | Slot afterwards |
|---|---|---|
| `RSA PRIVATE KEY` (PKCS#1) + `RSA PUBLIC KEY` (PKCS#1) + certificate, 2048 bit | `Certificate imported successfully` | new key and certificate |
| the same with 3072 and with 4096 bit | `Certificate imported successfully` | new key and certificate |
| the same into an empty slot | `Certificate imported successfully` | new key and certificate |
| certificate alone, key of the slot matches (after `request`) | `Certificate imported successfully` | old key, new certificate |
| certificate alone, key of the slot does not match | `SSL saved private key did not match the imported certificate.` | **empty: key and certificate deleted** |
| `RSA PRIVATE KEY` + certificate, **without** the public key block | the key is ignored: `SSL saved private key did not match the imported certificate.` | **empty: key and certificate deleted** |
| `PRIVATE KEY` (PKCS#8) + public key + certificate | `Wrong private key header format` | unchanged |
| `EC PRIVATE KEY` + certificate | `Wrong private key header format` | unchanged |
| key + public key + certificate + its intermediate (two certificates) | `Inconsistent value.` | unchanged |
| text that is no PEM | `illegal certificate was entered.` | unchanged |
| key + public key + a certificate issued by an intermediate, alone | accepted | new key and certificate |
| key + public key + an RSA certificate signed by an EC CA (`ecdsa-with-SHA256`) | accepted | new key and certificate |

**The refusal that destroys.** `SSL saved private key did not match the
imported certificate.` is not a harmless "no": afterwards `show ip https`
says `Certificate N does not exist.` Seen twice in a before-and-after test and
once more in hindsight. When it
happened to the active slot, the web server went on presenting the old
certificate - from memory, presumably until its next restart; what a switch
does that restarts with an empty active slot was not tried. The target
never sends such an import: with a key it checks that key and certificate
belong together before it connects, without a key it reads the certificate
of the slot (`show crypto certificate mycertificate N`) and compares the
public keys before it imports. What the switch answers to a key, a public
key and a certificate that do not belong together was not tried, for the
same reason.

`SICK::Issuer::SelfSigned` hands out PKCS#8 keys, `step` PKCS#1; the target
converts whatever it gets with `openssl rsa -traditional` and derives the
public key block with `openssl rsa -RSAPublicKey_out`.

## Activation

```
sw1(config)#ip https certificate 1
sw1(config)#end
sw1#show ip https
```

No answer on success. For about a second afterwards `show ip https` still
reports the old slot as active; the target asks until it names the new one
(20 seconds at most). The web server is unreachable for about three seconds
and then serves the new certificate. An import into the slot that is
already active has the same effect by itself.

The HTTPS service itself (`ip https server`) is not touched by the target.

## Saving

```
sw1#copy running-config startup-config
Overwrite file [startup-config].... (Y/N)[N] ?Y
05-Oct-2026 05:46:46 %COPY-I-FILECPY: Files Copy - source URL running-config destination URL flash://startup-config
05-Oct-2026 05:46:50 %COPY-N-TRAP: The copy operation was completed successfully
Copy succeeded
sw1#
```

About four seconds. Certificates and keys are part of the configuration: an
import that is not saved is gone after a restart. The copy saves the whole
running configuration, including anything else that was changed and not
saved.

## Limits

| | |
|---|---|
| Slots | 2 |
| Key type | RSA only |
| Key size, generated on the switch | 2048 to 3072 bit |
| Key size, imported | 2048, 3072 and 4096 bit accepted; see timing |
| Key format on import | PKCS#1 `RSA PRIVATE KEY`, unencrypted, followed by `RSA PUBLIC KEY` |
| Certificates per slot | exactly one: no chain, no intermediate |
| Names in a request | common name only, no subject alternative names |
| Names in an imported certificate | not restricted; DNS and IP alternative names are served as issued |
| Signature of the certificate | RSA and ECDSA CAs both accepted |

Because the switch presents the certificate alone, a client needs the
intermediate certificates of the CA from somewhere else - and so does SICK
when it decides whether the presented certificate is from its CA: the
`root` of the device list has to hold the intermediate as well.

## Timing

| | |
|---|---|
| SSH connection and login | 3 s |
| Import: 56 lines pasted one by one, and the answer | 13 s |
| Activation until `show ip https` agrees | under 2 s |
| Web server back after import or activation | 3 s |
| Save | 4 s |
| `sick run` for one switch, mode `import`, all in all | 24 s |
| Certificate request for an existing key | 0.1 to 2.5 s |
| Self-signed certificate for an existing key (`generate` without `key-generate`) | 4 s |
| Key generation on the switch, 2048 bit | 30 to 100 s |
| TLS handshake, 2048 bit key | 2 s |
| TLS handshake, 3072 bit key | 6 s |
| TLS handshake, 4096 bit key | 13 s |

The switch does the RSA operation of every handshake itself, with a cipher
suite without forward secrecy, so the key size is felt on every connection.
The target waits 30 seconds for a handshake (the default of SICK is 10) and
gives the switch 90 seconds to present a new certificate. A 4096 bit key is
possible and not a good idea.

## Which mode is the default, and why

`import`.

`csr` is the nicer idea - the key never leaves the switch - and it works:
request, signature and import of the certificate alone were run on the test
switch with `SICK::Issuer::SelfSigned`. But the request cannot carry
alternative names, and a certificate without them is useless to current
browsers. The names therefore have to be added by the CA, against what the
request says. `SICK::Issuer::SelfSigned` does that; a step-ca signs what the
request asks for, and `SICK::Issuer::StepCA` refuses a request whose names
are not exactly those of the device. With step-ca, `csr` thus only works
for a device with a single name, and whether step-ca then accepts the
blank-filled subject was not tried. On top of that a missing or wrongly
sized key costs up to a minute and a half of silence, during which the slot
holds a self-signed certificate. And a certificate that comes back for the
wrong key would cost the slot its key - the target looks before it imports,
but `import` cannot get into that situation at all.

`import` works with every CA and any list of names, takes seconds, and its
cost is that the private key crosses the SSH connection and exists for a
moment in the memory of the machine SICK runs on.

## Not tried

- firmware older than 1.4.11.5, other models of the family, stacks;
- a wrong password, a user below privilege level 15;
- SSH authentication switched on at the switch;
- encrypted private keys on import (Cisco documents an encrypted form);
- a key, a public key and a certificate that do not belong together;
- a restart of the switch or its web server while the active slot is empty;
- common names with blanks or other characters that need quoting - the
  target refuses them;
- a request signed by a real step-ca.
