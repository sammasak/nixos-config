# Agent runtime: authorized launch of a created instance (#170)

Epic [#133](https://github.com/sammasak/nixos-config/issues/133). How an
**authorized Coordinator** may START a pre-declared, already-`created` ephemeral
nspawn instance as root, non-interactively, without a broad root grant. Default
**off**; enabling it on a host is a separate owner decision (see below).

Upstream context: `herdrdev/herdr#4732` — a Coordinator agent hands the physical
host a bounded instruction to launch an already-admitted runtime. The worker/
`herdr:message` text is a task reference and a PTY channel; it never becomes a
root command. The only thing that crosses the privilege boundary here is a
**runtime id**, and the payload is derived on the host from the template manifest.

## The hazard this narrows

`agent-runtime-instance start <id> -- <CMD>` enforces exactly one precondition:
the instance is in state `created`. It does **not** re-check admission,
`eligibleTemplates` or digests, and the payload after `--` is **arbitrary**. So
any sudo rule that lets a non-root caller reach `start` at all — with any payload,
or even `start <id> -- …` with a wildcard — is **arbitrary root**: the caller
writes their own `CMD` and nspawn runs it (as container root, but the host-side
`start` runs as real root and the payload choice is the caller's).

The entire trick of #170 is therefore: the privileged entry point must take
**only a bounded runtime id** and **derive the payload itself** from the template
manifest, never from the caller.

## Three options

| option | granted authority | attack surface | eval/ops cost | verdict |
|---|---|---|---|---|
| **A. Reuse the deploy-rs `deploy` account** (`modules/homelab/deploy-target.nix`: `command = "ALL"; NOPASSWD`) | arbitrary root on the host | total: `deploy` already activates arbitrary closures; handing a Coordinator this account is handing it root | none (exists) | **rejected — arbitrary root** |
| **B. Root-owned systemd unit + scoped polkit** | start a templated unit via `systemctl start agent-runtime-start@<id>` gated by a polkit rule on the unit name | medium: the unit's `ExecStart` is fixed, but polkit rules are a second, stringly-typed policy language to get right; the unit still needs the id as an instance parameter and must itself re-derive the payload; a permissive polkit action or a `start/stop/restart` verb slip widens it | a template unit, a polkit JS rule, their own test | workable but **more moving parts**, two policy surfaces |
| **C. Exact-command sudo wrapper that derives its own payload** (this change) | run **one** program — the wrapper's exact store path — as root, which starts **THIS** created, admitted, digest-matched, eligible instance with **ITS OWN** declared entrypoint | narrow: one Cmnd, no wildcard, no flags, no payload; the wrapper fails closed; the only caller input is a charset-bounded id | one `writeShellApplication`, one `security.sudo` rule, one VM test | **chosen — narrowest** |

The precedent for C is `modules/rf-lab/hil.nix:157-169`: a single `NOPASSWD`
command for one wrapper whose own fail-closed gate bounds what it can do.

## Why C is the narrowest

The granted authority collapses from "arbitrary root" (A, and any `start`-level
rule) to:

> start the instance named by this one id, **only if** it is `created`, its
> template is still `enable`d and `eligibleTemplates`, its recorded digests match
> the manifest the record points at, and that manifest declares an executable
> `/nix/store` entrypoint — and then run **that entrypoint**, nothing the caller
> chose.

The wrapper (`modules/agent-runtime/runtime/authorized-start.sh`) re-checks every
gate that `start` skips and **fails closed** (starts nothing, exits non-zero)
unless all hold:

- exactly one argument, matching the same strict id charset as
  `agent-runtime-instance` (a DNS label, so no `/` and no `..` can appear); no
  flags, no payload, no second path;
- `status <id>` reports `.state == "created"` (an already-started instance is an
  idempotent no-op that starts nothing and exits 0; anything else is refused);
- the recorded `instance.json.template.digests` equal the digests of the manifest
  at `instance.json.template.manifest` (rejects a template changed since create,
  or a forged record);
- the template name is in `/etc/agent-runtime/host.json` `.eligibleTemplates` with
  `.enable == true` (the eligibility `start` does not re-check);
- the manifest `.entrypoint` is a non-null `/nix/store/…` path that is executable;
- the instance has a non-empty `.task`.

Only then does it `exec agent-runtime-instance start <id> --wait -- <entrypoint>`,
where `<entrypoint>` is read from the manifest and the instance tool's path is
Nix-interpolated (never a PATH lookup). It emits one structured JSON audit line
(`at`, `id`, `template`, `task`, `digests`, `decision`, `reason`) per invocation.
The `entrypoint` field itself is a first-class, **digest-covered** manifest field
(`manifestOf` in `modules/agent-runtime/default.nix`), so a payload swap changes
the template digest and is caught by the digest re-check.

## The exact host change (shown, NOT enabled)

On a host that already sets `sam.agentRuntime.host.enable = true` (today only
`acer-swift`), enabling this adds:

```nix
sam.agentRuntime.authorizedLaunch = {
  enable = true;
  user = "coordinator";   # the one account granted the wrapper
};
```

which, and only which, installs the wrapper and adds:

```nix
# rendered by modules/agent-runtime/authorized-launch.nix
security.sudo.extraRules = [{
  users = [ "coordinator" ];
  commands = [{
    command = "/nix/store/<hash>-agent-runtime-authorized-start/bin/agent-runtime-authorized-start";
    options = [ "NOPASSWD" ];
  }];
}];
```

Exactly one command, the wrapper's exact store path — no wildcard, no
`agent-runtime-instance`, no `start`. When `authorizedLaunch.enable` is false (the
default on every host), nothing is installed and no sudo rule is added. The
module asserts `authorizedLaunch.enable -> host.enable` and that `user` is set.

**This is not enabled in any `hosts/*` config in this change.** No deploy.

## Enabling it is a separate owner decision

Turning this on grants a named account passwordless root to start admitted
instances. That is a new privileged remote action and only the owner may approve
it — a subagent may draft and review but not enable. To enable later: set the two
options above on the target host, review the rendered sudo rule, then
`just deploy-acer`.

**Rollback:** set `authorizedLaunch.enable = false` and `just deploy-acer`; the
wrapper and the sudo rule disappear from the next generation. Nothing stateful is
touched (the instance lifecycle and `/var/lib/agent-runtime` are independent of
this grant).

## Verification

`nix build .#packages.x86_64-linux.agent-runtime-authorized-launch-test`
(`tests/agent-runtime-authorized-launch.nix`, registered in
`flake-modules/60-agent-runtime-authorized-launch-test.nix`) runs the wrapper
through the real sudo path in one QEMU VM as a non-root `coordinator` user with a
tiny, offline, credential-free template: a valid start succeeds; a `start`-level
payload the coordinator might pass (`start <id> -- /bin/sh -c 'touch /host-pwned'`)
is refused by sudo and leaves no file; a forged id, a non-eligible template, and a
tampered recorded digest each fail closed; a duplicate run starts nothing; and the
host sentinel is untouched with no instance left behind.
