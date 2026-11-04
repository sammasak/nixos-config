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

| Entry | Names and addresses | SHA256 (Ed25519) | Verified against |
|---|---|---|---|
| github | github.com | `+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU` | `api.github.com/meta` (`ssh_keys`, `ssh_key_fingerprints.SHA256_ED25519`) |
| lenovo-21CB001PMX | lenovo-21CB001PMX, 192.168.10.154 (+ localhost on itself) | `7DLYFLKZ4wrcrO0Bk7MnZ8yYHrVeu5pFsSwYWjvpNGs` | `/etc/ssh/ssh_host_ed25519_key.pub` read on the machine |
| acer-swift | acer-swift, 192.168.10.110 | `5Ong1jvhk4Hgx82l2fYrKBjqlkVyG5rYvYfVPo7WdRY` | the file above, read over ssh whose key the operator had pinned |
| msi-ms7758 | msi-ms7758, msi, 192.168.10.235 | `JebDBAzSWRc/WHY8wQG7jVcidYFp4eFKyjuTzXl5Jwc` | same |
| black-pi | black-pi, 192.168.10.137 | `i78xzl+ImmEgGFp0QehlBaa3zuFgkpk2nU5ALIHZMjY` | same |

Not pinned: **naked-pi** (no route on 2026-11-04; the operator's
`~/.ssh/known_hosts` entry for it was accepted on first use, which is not a
verification). black-pi's second address 192.168.10.136 did not answer and is
not listed either. No Mac or CI runner is managed by this repository. The
ephemeral KubeVirt workstations (192.168.10.20x) keep changing keys by
design; the owner's own `~/.ssh/config` carries their exception, which the
user file wins over the system file.

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

`ssh-keyscan` is never the verification: it shows what a server claims, not
who it is. It is fine as a cross-check once the fingerprint is known.

## Onboarding a fresh machine

1. Install it; the first boot generates `/etc/ssh/ssh_host_ed25519_key`.
2. On its console (or over a channel you already trust, such as the
   installer's serial console or a key read before the machine left your
   desk) run `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` and note
   the SHA256 fingerprint. `cat` the `.pub` file for the key itself.
3. Add an entry to `hosts` in `modules/core/ssh-known-hosts.nix` with every
   name and address the host is reached by, the key, the date and the
   fingerprint; add the same fingerprint to `EXPECTED` in
   `scripts/test-ssh-known-hosts.py` and to the table above.
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
  entry as above. To reach the host meanwhile, verify its fingerprint on the
  console first, then connect once with an explicit, throwaway known-hosts
  file: `ssh -o UserKnownHostsFile=/tmp/kh -o StrictHostKeyChecking=accept-new host`
  and compare `ssh-keygen -lf /tmp/kh` with what the console showed before
  doing anything else over that connection.
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
