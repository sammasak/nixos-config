# SSH host keys: verified, pinned, fail closed

`modules/core/ssh-known-hosts.nix` (nixos-config#86) pins the Ed25519 host
public key of every managed machine and of github.com in
`/etc/ssh/ssh_known_hosts` on every host, and sets `StrictHostKeyChecking yes`
for all ssh clients and for every deploy-rs node. A known host connects
without a prompt; an unknown name or a changed key fails the connection.
Host keys only: user login keys (`authorized_keys`) live in `lib/users.nix`.
`scripts/test-ssh-known-hosts.py` (gate `nixos:known-hosts-test`, part of
`nixos:qa`) pins the fingerprints below; `scripts/ssh-known-hosts-verify.sh`
re-reads the keys live from their sources.

## Inventory (verified 2026-11-04)

The evidence for every fleet host is independent of any ssh connection: a
NixOS host here decrypts its sops secrets with `/etc/ssh/ssh_host_ed25519_key`,
and the recipient the owner wrote into `secrets/.sops.yaml` for that host at
onboarding is `ssh-to-age` of exactly that key. A pinned key whose age form is
the host's recipient is therefore the key that host has been decrypting with
(for naked-pi this is inferred: it has been seen at its Wi-Fi addresses, and
it can only join that network with the PSK it decrypts with this key). The live read of
`/etc/ssh/ssh_host_ed25519_key.pub` over ssh is a consistency check on top.

| Entry | Names and addresses | SHA256 (Ed25519) | Evidence |
|---|---|---|---|
| github | github.com | `+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU` | `api.github.com/meta` (`ssh_keys`, `ssh_key_fingerprints.SHA256_ED25519`) |
| lenovo-21CB001PMX | lenovo-21CB001PMX, 192.168.10.154 (+ localhost on itself) | `7DLYFLKZ4wrcrO0Bk7MnZ8yYHrVeu5pFsSwYWjvpNGs` | read on the machine; sops recipient `age13lj7p…gqc4y` |
| acer-swift | acer-swift, 192.168.10.110 | `5Ong1jvhk4Hgx82l2fYrKBjqlkVyG5rYvYfVPo7WdRY` | sops recipient `age1uu9y3…xlyuk`; live read equal |
| msi-ms7758 | msi-ms7758, msi, 192.168.10.235 | `JebDBAzSWRc/WHY8wQG7jVcidYFp4eFKyjuTzXl5Jwc` | sops recipient `age1g0k9v…mvcx4r`; live read equal |
| black-pi | black-pi, 192.168.10.137, 192.168.10.136 | `i78xzl+ImmEgGFp0QehlBaa3zuFgkpk2nU5ALIHZMjY` | sops recipient `age16l5rq…yx7tn`; live read equal on .137 |
| naked-pi | naked-pi, 192.168.10.127, 192.168.10.138, 192.168.10.180 | `auOEtU3d4yfB4U6iB7WIt0gSCLwK7hCDPorJAwVs0sY` | sops recipient `age1kdjql…26wer`; unreachable for a live read on 2026-11-04 |

The addresses are routing, not identity: a host's key is pinned for every
address it is reached by (black-pi's .136 and naked-pi's .138/.180 come from
the owner's `~/.ssh/config` aliases). Tailscale addresses and MagicDNS names
are not pinned (only lenovo and the phone are on the tailnet). No Mac or CI
runner is managed by this repository. The ephemeral KubeVirt workstations
(192.168.10.20x) keep changing keys by design; the owner's own
`~/.ssh/config` carries their exception, which the user file wins over the
system file. The `# naked-pi — FILL` comment in `secrets/.sops.yaml` is stale
(the recipient below it is filled in); it is left alone here.

Each host runs the same `ssh_known_hosts`; a host additionally pins
`localhost`, `127.0.0.1` and `::1` to its own key, which is what keeps
lenovo's loopback deploy-rs node working under the strict setting.

## Validate a fingerprint

On the machine, or over a connection already pinned:

```sh
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

compare with the table and with the module. From elsewhere, after the pin:

```sh
scripts/ssh-known-hosts-verify.sh            # all fleet hosts and github.com
scripts/ssh-known-hosts-verify.sh acer-swift # one host
```

It prints, per host, the sops-recipient check (offline) and the live read
(over the pinned connection; a changed key shows as UNREACHABLE because the
connection itself fails). Exit 1 means a mismatch, 2 means something could
not be checked; both deserve a look. Converting a key yourself:
`ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub`.

`ssh-keyscan` is never the verification: it shows what a server claims, not
who it is. It is fine as a cross-check once the fingerprint is known.

## Onboarding a fresh machine

1. Install it; the first boot generates `/etc/ssh/ssh_host_ed25519_key`.
2. On its console (or over a channel you already trust, such as the
   installer's serial console or a key read before the machine left your
   desk) run `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` and note
   the SHA256 fingerprint. `cat` the `.pub` file for the key itself.
3. Add an entry to `hosts` in `modules/core/ssh-known-hosts.nix` with every
   name and address the host is reached by, the key and the fingerprint; add
   the fingerprint to `EXPECTED` and, once the host has a sops recipient
   (`ssh-to-age` of the same key, the usual onboarding step), the recipient to
   `SOPS_RECIPIENTS` in `scripts/test-ssh-known-hosts.py`; add the row above.
   For an SD-image Pi the host key can be generated on this workstation and
   written into the image, which verifies it by construction.
4. `devenv tasks run nixos:known-hosts-test` and `nix flake check --no-build`,
   then open the PR. After the switch, every host connects to the new one
   without a prompt; until then connections to it fail closed, which is the
   intended state for an unverified machine. There is no
   `StrictHostKeyChecking no` step and no unverified `ssh-keyscan` trust.

## Reinstallation and legitimate key rotation

A reinstall or `rm /etc/ssh/ssh_host_*` gives the machine a new key, and
every pinned client refuses it ("REMOTE HOST IDENTIFICATION HAS CHANGED" or
"Host key verification failed"); that refusal is the point. Verify the new
fingerprint on the console as in onboarding, update the module entry, the
test table and this table in one PR, and switch the clients. Until the switch
lands, reach the host only through a channel that does not depend on its ssh
key (console, BMC, serial).

## Recovery

- A pin is wrong (typo, stale key after an unrecorded reinstall): fix the
  entry as above. To reach the host meanwhile, read its key on the console
  (`cat /etc/ssh/ssh_host_ed25519_key.pub`), put that one line, prefixed with
  the host name, into a private temporary file, and connect with the global
  pin file switched off so the stale entry cannot interfere:

  ```sh
  kh=$(mktemp); printf '%s %s\n' host 'ssh-ed25519 AAAA…' > "$kh"
  ssh -o GlobalKnownHostsFile=/dev/null -o UserKnownHostsFile="$kh" -o StrictHostKeyChecking=yes host
  ```

  Still strict: the connection succeeds only if the server holds the key the
  console showed. Remove the file afterwards.
- A whole host must not enforce the pins for a while: set
  `sam.sshKnownHosts.strict = false` (keys stay pinned, unknown hosts prompt
  again) or `sam.sshKnownHosts.enable = false` (nothing pinned) in that
  host's configuration and switch; both are single-option reversals.
- deploy-rs refuses a node: its `sshOpts` carry
  `StrictHostKeyChecking=yes`, so the cause is a missing or changed pin for
  the node's hostname; fix the pin, never the option.

## Scope notes

The lenovo user-identity question (gpg-agent's SSH socket without
identities) is not a host-key matter and is not covered here; see #125 and
the "Git authentication from lenovo" section of `rollout-coordinator.md`.
A host CA would replace this table at a larger fleet size; not needed now.
