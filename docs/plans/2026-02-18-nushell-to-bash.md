# Nushell → Bash Migration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Remove nushell from all hosts (NixOS + macOS) and replace it with bash as the login shell, migrating all aliases and env-sourcing blocks.

**Architecture:** Create a new `modules/core/bash.nix` to hold the aliases and neofetch startup that currently live in `nushell.nix`. Delete `nushell.nix`. Remove all `programs.nushell.*` blocks from every module. Update the shell default and per-host variables.

**Tech Stack:** Nix/NixOS, home-manager `programs.bash.*`, nix-darwin.

---

### Task 1: Create `modules/core/bash.nix` with aliases and neofetch

**Files:**
- Create: `modules/core/bash.nix`

This replaces `modules/core/nushell.nix`. It carries the kubectl/git aliases and the neofetch interactive-startup call.

**Step 1: Create the file**

```nix
# Bash baseline — aliases and interactive startup (home-manager module)
{ ... }:
{
  programs.bash = {
    enable = true;
    shellAliases = {
      gco  = "git checkout";
      k    = "kubectl";
      kg   = "kubectl get";
      kd   = "kubectl describe";
      ka   = "kubectl apply -f";
      kdel = "kubectl delete";
      kgp  = "kubectl get pods";
      kgs  = "kubectl get svc";
      kgd  = "kubectl get deploy";
      kgn  = "kubectl get nodes";
      kga  = "kubectl get all";
    };
    initExtra = ''
      neofetch
    '';
  };
}
```

`initExtra` is appended to `.bashrc`, which is only sourced for interactive shells, so no extra guard needed.

**Step 2: Verify the file is valid Nix**

```bash
nix-instantiate --parse modules/core/bash.nix
```

Expected: no output (parses successfully).

**Step 3: Commit**

```bash
git add modules/core/bash.nix
git commit -m "feat: add modules/core/bash.nix with aliases and neofetch"
```

---

### Task 2: Update all home.nix imports — swap nushell.nix for bash.nix

**Files:**
- Modify: `hosts/acer-swift/home.nix:8`
- Modify: `hosts/lenovo-21CB001PMX/home.nix:8`
- Modify: `hosts/msi-ms7758/home.nix:8`
- Modify: `hosts/workstation-template/home.nix:15`
- Modify: `home/lukas.nix:7`

In each file, replace `nushell.nix` with `bash.nix` in the imports list. The path depth is the same so only the filename changes.

For the three physical NixOS hosts (acer-swift, lenovo, msi) and workstation-template, the line looks like:
```nix
../../modules/core/nushell.nix
```
Replace with:
```nix
../../modules/core/bash.nix
```

For `home/lukas.nix` (macOS, one level shallower):
```nix
../modules/core/nushell.nix
```
Replace with:
```nix
../modules/core/bash.nix
```

**Step 1: Update all five files** (the changes are mechanical; do them in sequence or parallel)

**Step 2: Verify workstation-template evaluates**

```bash
nix eval .#nixosConfigurations.workstation-template.config.system.build.toplevel --apply builtins.toString
```

Expected: a store path is printed (no error).

**Step 3: Commit**

```bash
git add hosts/acer-swift/home.nix hosts/lenovo-21CB001PMX/home.nix \
        hosts/msi-ms7758/home.nix hosts/workstation-template/home.nix \
        home/lukas.nix
git commit -m "feat: replace nushell.nix import with bash.nix in all home configs"
```

---

### Task 3: Remove `programs.nushell.extraEnv` from `mcp.nix`

**Files:**
- Modify: `modules/programs/cli/claude-code/mcp.nix:47-57`

Delete the entire nushell block (lines 47–57). The bash block on lines 41–45 already covers the same token-sourcing logic for all hosts.

Remove this block:
```nix
  programs.nushell.extraEnv = lib.mkAfter ''
    if ($"($env.HOME)/.env" | path exists) {
      let token_line = (open $"($env.HOME)/.env" | lines | where { |l| $l | str starts-with "CLAUDE_CODE_OAUTH_TOKEN=" } | first?)
      if ($token_line != null) {
        { CLAUDE_CODE_OAUTH_TOKEN: ($token_line | str replace "CLAUDE_CODE_OAUTH_TOKEN=" "") } | load-env
      }
    }
    if ("/run/secrets/claude_oauth_token" | path exists) {
      { CLAUDE_CODE_OAUTH_TOKEN: (open /run/secrets/claude_oauth_token | str trim) } | load-env
    }
  '';
```

**Step 1: Delete the block**

**Step 2: Verify the file still evaluates**

```bash
nix eval .#nixosConfigurations.workstation-template.config.system.build.toplevel --apply builtins.toString
```

Expected: store path printed, no error.

**Step 3: Commit**

```bash
git add modules/programs/cli/claude-code/mcp.nix
git commit -m "feat: remove nushell extraEnv from claude-code/mcp.nix"
```

---

### Task 4: Remove `programs.nushell.extraEnv` from `claude-code/default.nix`

**Files:**
- Modify: `modules/programs/cli/claude-code/default.nix:165-179`

Delete the entire nushell env-loading block. The `programs.bash.profileExtra` block on lines 157–161 already handles the same sourcing for bash.

Remove this block:
```nix
  # Nushell: load the same env files via load-env.
  # ANTHROPIC_API_KEY is excluded: only for headless agent sessions.
  programs.nushell.extraEnv = ''
    for file in ["/etc/workstation/agent-env" "/etc/workstation/otel-env"] {
      if ($file | path exists) {
        open $file
          | lines
          | where { |line| ($line | str trim | str length) > 0 and not ($line | str starts-with "#") and not ($line | str starts-with "ANTHROPIC_API_KEY") }
          | each { |line|
            let parts = ($line | split column "=" key value)
            { ($parts.0.key | str trim): ($parts.0.value | str trim) }
          }
          | reduce --fold {} { |it, acc| $acc | merge $it }
          | load-env
      }
    }
  '';
```

**Step 1: Delete the block**

**Step 2: Verify**

```bash
nix eval .#nixosConfigurations.workstation-template.config.system.build.toplevel --apply builtins.toString
```

Expected: store path, no error.

**Step 3: Commit**

```bash
git add modules/programs/cli/claude-code/default.nix
git commit -m "feat: remove nushell extraEnv from claude-code/default.nix"
```

---

### Task 5: Remove `programs.nushell.extraEnv` from `github-app-auth/default.nix`

**Files:**
- Modify: `modules/programs/cli/github-app-auth/default.nix:122-131`

Delete the nushell block. The bash `initExtra` block earlier in the same file already handles `GH_TOKEN` export.

Remove this block:
```nix
  # Nushell: export GH_TOKEN when the token file is present
  programs.nushell.extraEnv = lib.mkAfter ''
    if ("/etc/workstation/github-app-env" | path exists) {
      let _rt_dir = ($env | get --ignore-errors XDG_RUNTIME_DIR | default $"/run/user/(^id -u | str trim)")
      let _tf = $"($_rt_dir)/github-token"
      if ($"($_tf)" | path exists) {
        $env.GH_TOKEN = (open --raw $"($_tf)" | str trim)
      }
    }
  '';
```

Also check if `lib` is still used elsewhere in that file. If `lib` is only used for `lib.mkAfter` in the nushell block and the bash `initExtra`, keep it. If bash initExtra still uses `lib.mkAfter`, keep the `lib` argument.

**Step 1: Delete the nushell block**

**Step 2: Verify**

```bash
nix eval .#nixosConfigurations.workstation-template.config.system.build.toplevel --apply builtins.toString
```

Expected: store path, no error.

**Step 3: Commit**

```bash
git add modules/programs/cli/github-app-auth/default.nix
git commit -m "feat: remove nushell extraEnv from github-app-auth/default.nix"
```

---

### Task 6: Change shell default in `system.nix` and remove per-host overrides

**Files:**
- Modify: `modules/core/system.nix:103`
- Modify: `hosts/acer-swift/variables.nix:22`
- Modify: `hosts/lenovo-21CB001PMX/variables.nix:22`
- Modify: `hosts/msi-ms7758/variables.nix:14`

In `system.nix`, change:
```nix
default = "nushell";
```
to:
```nix
default = "bash";
```

In each of the three `variables.nix` files, delete the line:
```nix
shell = "nushell";
```
(It's now the default; the explicit override is redundant.)

**Step 1: Update system.nix and the three variables files**

**Step 2: Verify all physical hosts evaluate**

```bash
nix eval .#nixosConfigurations.acer-swift.config.system.build.toplevel --apply builtins.toString
nix eval .#nixosConfigurations.lenovo-21CB001PMX.config.system.build.toplevel --apply builtins.toString
nix eval .#nixosConfigurations.msi-ms7758.config.system.build.toplevel --apply builtins.toString
```

Expected: three store paths, no errors.

**Step 3: Commit**

```bash
git add modules/core/system.nix \
        hosts/acer-swift/variables.nix \
        hosts/lenovo-21CB001PMX/variables.nix \
        hosts/msi-ms7758/variables.nix
git commit -m "feat: change default shell to bash, remove per-host nushell overrides"
```

---

### Task 7: Update macOS darwin config

**Files:**
- Modify: `darwin/common.nix:24`

Change:
```nix
shell = pkgs.nushell;
```
to:
```nix
shell = pkgs.bash;
```

**Step 1: Update the file**

**Step 2: Verify darwin config evaluates**

```bash
nix eval .#darwinConfigurations.work-mac.config.system.build.toplevel --apply builtins.toString 2>&1 | head -5
```

Expected: store path or "already up to date", no error. (If no darwin config exists in the flake yet, skip verification and note it.)

**Step 3: Commit**

```bash
git add darwin/common.nix
git commit -m "feat: switch macOS login shell from nushell to bash"
```

---

### Task 8: Delete `modules/core/nushell.nix`

**Files:**
- Delete: `modules/core/nushell.nix`

At this point no file imports nushell.nix anymore. Delete it.

**Step 1: Delete the file**

```bash
git rm modules/core/nushell.nix
```

**Step 2: Full build verification — all NixOS hosts**

```bash
nix build .#nixosConfigurations.acer-swift.config.system.build.toplevel --no-link
nix build .#nixosConfigurations.lenovo-21CB001PMX.config.system.build.toplevel --no-link
nix build .#nixosConfigurations.msi-ms7758.config.system.build.toplevel --no-link
nix build .#nixosConfigurations.workstation-template.config.system.build.toplevel --no-link
```

All four must complete without error.

**Step 3: Commit**

```bash
git commit -m "feat: delete modules/core/nushell.nix — nushell fully removed"
```
