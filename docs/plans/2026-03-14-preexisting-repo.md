# Pre-existing Repo Support Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Let users import a public GitHub repo on doable.sammasak.dev and have Claude clone it, create a flake.nix if missing, start the dev server on :8080, then work on their goal.

**Architecture:** A new "Import repo" tab on the landing page sends `repoUrl` through workstation-api into the CRD. The workspace controller prepends a clone preamble to the goal before posting it to Claude. `template-dev` skips Vite if the workspace isn't a Vite project. No new VM boot-time infrastructure.

**Tech Stack:** Rust (workstation-api, CRD/handlers), SvelteKit 2 + Svelte 5 + Tailwind v4 (doable frontend), Nix (claude-worker.nix), SOPS (bootstrap CLAUDE.md)

---

## Task 1: Add `repo_url` to WorkspaceClaimSpec (CRD)

**Files:**
- Modify: `~/workstation-api/src/crd.rs` — add field after `goal`

**Step 1: Open the file and locate the `goal` field**

In `~/workstation-api/src/crd.rs`, find the `goal` field (near line 73-78):
```rust
    /// Goal to seed into the VM's agent queue when it becomes Ready.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub goal: Option<String>,
```

**Step 2: Add `repo_url` field immediately after `goal`**

```rust
    /// Goal to seed into the VM's agent queue when it becomes Ready.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub goal: Option<String>,

    /// Public GitHub repo URL to clone into the workspace before posting the goal.
    /// When set, the controller prepends a clone preamble to the goal.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub repo_url: Option<String>,
```

**Step 3: Verify it compiles**
```bash
cd ~/workstation-api && cargo check 2>&1 | tail -5
```
Expected: `Finished` with no errors.

**Step 4: Commit**
```bash
cd ~/workstation-api
git add src/crd.rs
git commit -m "feat: add repo_url to WorkspaceClaimSpec"
```

---

## Task 2: Add `repo_url` to CreateWorkspaceRequest and wire through to CRD

**Files:**
- Modify: `~/workstation-api/src/handlers.rs` — two places: `CreateWorkspaceRequest` struct and the CRD-building code inside `create_workspace` handler

**Step 1: Add field to `CreateWorkspaceRequest` struct**

Find the struct (around line 659-684). After the `goal` field:
```rust
    /// Initial goal to post to the claude-worker agent once the VM is Ready.
    pub goal: Option<String>,
```

Add:
```rust
    /// Initial goal to post to the claude-worker agent once the VM is Ready.
    pub goal: Option<String>,

    /// Public GitHub repo URL to clone before posting the goal.
    /// Must start with https://github.com/
    pub repo_url: Option<String>,
```

**Step 2: Find where `spec.goal` is set in the `create_workspace` handler**

Search for `goal: req.goal` in `handlers.rs` — it's in the block that builds `WorkspaceClaimSpec`. Add `repo_url` alongside it:

```rust
goal: req.goal,
repo_url: req.repo_url,
```

**Step 3: Add basic validation for repo_url**

In the `create_workspace` handler, before building the spec, add:
```rust
if let Some(ref url) = req.repo_url {
    if !url.starts_with("https://github.com/") {
        return Err(AppError::BadRequest(
            "repo_url must start with https://github.com/".into()
        ));
    }
}
```

(Find the pattern for `AppError::BadRequest` by looking at other validation errors in the same function, and match the existing style exactly.)

**Step 4: Verify it compiles**
```bash
cd ~/workstation-api && cargo check 2>&1 | tail -5
```
Expected: `Finished` with no errors.

**Step 5: Commit**
```bash
cd ~/workstation-api
git add src/handlers.rs
git commit -m "feat: wire repo_url through CreateWorkspaceRequest to CRD"
```

---

## Task 3: Enrich goal with clone preamble in `post_goal_if_needed`

**Files:**
- Modify: `~/workstation-api/src/handlers.rs` — `post_goal_if_needed` function

**Step 1: Find `post_goal_if_needed`**

Search for `post_goal_if_needed` in `handlers.rs`. It reads `spec.goal` and posts it to the VM. Find the line that constructs the goal string to post (something like `let goal = spec.goal.clone().unwrap_or_default()`).

**Step 2: Write a unit test for the preamble logic first**

Add a test module at the bottom of `handlers.rs`:
```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn build_goal_payload(goal: &str, repo_url: Option<&str>) -> String {
        match repo_url {
            Some(url) => format!(
                "Before starting, set up the workspace:\n\
                 1. rm -rf ~/workspace/* ~/workspace/.[^.]*\n\
                 2. git clone {url} ~/workspace\n\
                 3. If no flake.nix exists, create one for this stack\n\
                 4. Start the dev server on :8080 in the background\n\
                 Then: {goal}",
            ),
            None => goal.to_string(),
        }
    }

    #[test]
    fn test_goal_payload_no_repo() {
        let result = build_goal_payload("add dark mode", None);
        assert_eq!(result, "add dark mode");
    }

    #[test]
    fn test_goal_payload_with_repo() {
        let result = build_goal_payload(
            "add dark mode",
            Some("https://github.com/user/my-app"),
        );
        assert!(result.contains("git clone https://github.com/user/my-app ~/workspace"));
        assert!(result.contains("Then: add dark mode"));
        assert!(result.contains("flake.nix"));
    }
}
```

**Step 3: Run the tests (they'll fail — function not extracted yet)**
```bash
cd ~/workstation-api && cargo test tests:: 2>&1 | tail -20
```
Expected: FAIL — `build_goal_payload` not in scope.

**Step 4: Extract the helper and call it in `post_goal_if_needed`**

Add the `build_goal_payload` helper as a free function (not in test module):
```rust
fn build_goal_payload(goal: &str, repo_url: Option<&str>) -> String {
    match repo_url {
        Some(url) => format!(
            "Before starting, set up the workspace:\n\
             1. rm -rf ~/workspace/* ~/workspace/.[^.]*\n\
             2. git clone {url} ~/workspace\n\
             3. If no flake.nix exists, create one for this stack\n\
             4. Start the dev server on :8080 in the background\n\
             Then: {goal}",
        ),
        None => goal.to_string(),
    }
}
```

In `post_goal_if_needed`, find where the goal text is assembled and replace with:
```rust
let enriched_goal = build_goal_payload(
    &goal_text,
    spec.repo_url.as_deref(),
);
// Use enriched_goal instead of goal_text when posting to the VM
```

**Step 5: Run the tests**
```bash
cd ~/workstation-api && cargo test tests:: 2>&1 | tail -20
```
Expected: all tests PASS.

**Step 6: Also expose `repo_url` in `WorkspaceResponse` and `claim_to_response`**

In the `WorkspaceResponse` struct, add after the `goal` field:
```rust
    /// Public GitHub repo URL, if set.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub repo_url: Option<String>,
```

In `claim_to_response`, add alongside `goal: spec.goal.clone()`:
```rust
repo_url: spec.repo_url.clone(),
```

**Step 7: Compile check**
```bash
cd ~/workstation-api && cargo check 2>&1 | tail -5
```

**Step 8: Commit**
```bash
cd ~/workstation-api
git add src/handlers.rs
git commit -m "feat: enrich goal with repo clone preamble when repo_url is set"
```

---

## Task 4: Build and deploy workstation-api

**Step 1: Build and release**
```bash
cd ~/workstation-api && just release
```
Expected: builds Rust binary, pushes image, Flux or rollout restarts the deployment.

**Step 2: Verify it's running**
```bash
kubectl get pods -n workstations | grep workstation-api
```
Expected: pod Running.

**Step 3: Smoke-test the API**
```bash
curl -s http://workstation-api.sammasak.dev/api/v1/workspaces 2>&1 | head -5
```
Expected: JSON array (not 500 error).

---

## Task 5: Add `repoUrl` to frontend API client

**Files:**
- Modify: `/tmp/doable/src/lib/api/workstation.ts`

**Step 1: Add `repoUrl` to `CreateWorkspaceRequest` interface**

Find the interface (around line 14-31). After `goal?: string`:
```typescript
export interface CreateWorkspaceRequest {
  name: string;
  containerDiskImage: string;
  bootstrapSecretName: string;
  runStrategy: string;
  idleHaltAfterMinutes: number;
  goal?: string;
  repoUrl?: string;  // ← add this
}
```

**Step 2: Verify TypeScript compiles**
```bash
cd /tmp/doable && npm run check 2>&1 | tail -10
```
Expected: no errors.

**Step 3: Commit**
```bash
cd /tmp/doable
git add src/lib/api/workstation.ts
git commit -m "feat: add repoUrl to CreateWorkspaceRequest interface"
```

---

## Task 6: Add "Import repo" tab to the landing page

**Files:**
- Modify: `/tmp/doable/src/routes/+page.svelte`

**Step 1: Add tab state and import form state at the top of `<script>`**

Find the existing reactive state declarations (around line 17-45). Add:
```typescript
// Tab state
let activeTab: 'build' | 'import' = $state('build');

// Import tab state
let importRepoUrl = $state('');
let importRepoUrlError = $state('');
```

**Step 2: Add `handleImport` function alongside `handleCreate`**

After `handleCreate`, add:
```typescript
async function handleImport() {
  // Validate name
  if (!name.trim()) {
    nameError = 'Project name is required';
    return;
  }
  if (!/^[a-z0-9][a-z0-9-]{0,30}[a-z0-9]$/.test(name) && name.length > 1) {
    nameError = 'Name must be lowercase letters, numbers, and hyphens';
    return;
  }
  // Validate repo URL
  if (!importRepoUrl.trim().startsWith('https://github.com/')) {
    importRepoUrlError = 'Must be a public GitHub URL (https://github.com/...)';
    return;
  }
  // Validate goal
  if (!prompt.trim()) {
    return;
  }

  importRepoUrlError = '';
  nameError = '';

  try {
    const workspace = await createWorkspace({
      name: name.trim(),
      containerDiskImage: 'registry.sammasak.dev/agents/claude-worker:latest',
      bootstrapSecretName: 'claude-worker-bootstrap',
      runStrategy: 'Always',
      idleHaltAfterMinutes: 60,
      goal: prompt.trim(),
      repoUrl: importRepoUrl.trim(),
    });
    goto(`/projects/${workspace.name}`);
  } catch (e) {
    console.error('Failed to import workspace', e);
  }
}
```

**Step 3: Add tab switcher UI**

Find the opening of the form/card area in the template. Add tab buttons before the existing form content:

```svelte
<!-- Tab switcher -->
<div class="flex gap-2 mb-6">
  <button
    onclick={() => activeTab = 'build'}
    class="px-4 py-2 rounded-lg text-sm font-medium transition-colors {activeTab === 'build'
      ? 'bg-[--accent] text-white'
      : 'bg-white/10 text-white/60 hover:text-white'}"
  >
    Build from scratch
  </button>
  <button
    onclick={() => activeTab = 'import'}
    class="px-4 py-2 rounded-lg text-sm font-medium transition-colors {activeTab === 'import'
      ? 'bg-[--accent] text-white'
      : 'bg-white/10 text-white/60 hover:text-white'}"
  >
    Import repo
  </button>
</div>
```

**Step 4: Wrap existing form in `{#if activeTab === 'build'}` and add import form**

Wrap the existing form/prompt area:
```svelte
{#if activeTab === 'build'}
  <!-- existing build form content unchanged -->
{:else}
  <!-- Import repo form -->
  <div class="flex flex-col gap-4">
    <div>
      <label class="block text-sm text-white/60 mb-1">GitHub repo URL</label>
      <input
        type="url"
        placeholder="https://github.com/user/my-app"
        bind:value={importRepoUrl}
        class="w-full rounded-lg bg-white/10 px-4 py-3 text-white placeholder:text-white/30
               outline-none focus:ring-2 focus:ring-[--accent]
               {importRepoUrlError ? 'ring-2 ring-red-400' : ''}"
      />
      {#if importRepoUrlError}
        <p class="text-red-400 text-xs mt-1">{importRepoUrlError}</p>
      {/if}
    </div>

    <!-- Reuse the existing name input and prompt textarea here —
         they share state with the build tab, no duplication needed -->

    <button
      onclick={handleImport}
      class="self-end px-6 py-3 rounded-lg bg-[--accent] text-white font-medium
             hover:opacity-90 transition-opacity"
    >
      Import →
    </button>
  </div>
{/if}
```

Note: the name field and goal textarea are shared between both tabs (same `name` and `prompt` state variables). Keep them outside the tab conditional if they're in a shared section, or duplicate the relevant inputs inside the import tab block — match whatever structure the existing template has.

**Step 5: Check for TypeScript/Svelte errors**
```bash
cd /tmp/doable && npm run check 2>&1 | tail -15
```
Expected: no errors.

**Step 6: Commit**
```bash
cd /tmp/doable
git add src/routes/+page.svelte
git commit -m "feat: add Import repo tab to landing page"
```

---

## Task 7: Build and deploy doable frontend

**Step 1: Build**
```bash
cd /tmp/doable && npm run build 2>&1 | tail -10
```
Expected: `✓ built in ...`

**Step 2: Build and push container image**
```bash
cd /tmp/doable
buildah build --isolation=chroot -t registry.sammasak.dev/lab/doable-ui:latest .
buildah push --creds "admin:Harbor12345" registry.sammasak.dev/lab/doable-ui:latest
```

**Step 3: Restart the deployment**
```bash
kubectl rollout restart deployment/doable -n doable
kubectl rollout status deployment/doable -n doable
```
Expected: `successfully rolled out`

**Step 4: Smoke-test in browser**

Open https://doable.sammasak.dev — verify two tabs appear: "Build from scratch" and "Import repo". Click "Import repo" — verify form shows URL field, name field, goal textarea, and "Import →" button.

---

## Task 8: Make template-dev Vite start conditional

**Files:**
- Modify: `~/nixos-config/modules/homelab/claude-worker.nix` line 145

**Step 1: Read the current ExecStart line**

Current (line 145):
```nix
ExecStart = "${pkgs.nodejs_22}/bin/node ${cfg.workerHome}/workspace/node_modules/.bin/vite dev --port 8080 --host 0.0.0.0";
```

**Step 2: Replace with a conditional bash script**

```nix
ExecStart = "${pkgs.bash}/bin/bash -c '\
  if [ -f ${cfg.workerHome}/workspace/package.json ] && \
     grep -q \\'\"vite\"\\' ${cfg.workerHome}/workspace/package.json 2>/dev/null; then \
    exec ${pkgs.nodejs_22}/bin/node ${cfg.workerHome}/workspace/node_modules/.bin/vite dev --port 8080 --host 0.0.0.0; \
  else \
    exec sleep infinity; \
  fi'";
```

Note on quoting: Nix string interpolation uses `${}`, bash uses `$()`, single quotes inside a Nix double-quoted string need escaping as `\\'`. Test the quoting carefully — if it looks messy, factor it into a separate derivation script file. The key logic is: check for `"vite"` in `package.json`; if found, start Vite; otherwise sleep.

**Step 3: Verify Nix syntax**
```bash
cd ~/nixos-config && nix flake check --no-build 2>&1 | tail -20
```
Expected: no errors (or only unrelated warnings).

**Step 4: Commit**
```bash
cd ~/nixos-config
git add modules/homelab/claude-worker.nix
git commit -m "feat: make template-dev Vite start conditional on project type"
```

---

## Task 9: Rebuild and publish agent image

**Step 1: Rebuild the agent image**
```bash
cd ~/nixos-config && just release-agent latest
```
Expected: builds `claude-worker-template` OCI image, pushes to `registry.sammasak.dev/agents/claude-worker:latest`.

**Step 2: Restart any running workstation VMs (optional)**

Existing VMs use the old image. New VMs will pull the updated image automatically. No action required unless you want to test the change immediately.

---

## Task 10: Add repo mode section to template-stack SKILL.md

**Files:**
- Modify: `~/claude-code-skills/skills/template-stack/SKILL.md`

**Step 1: Add repo mode section before "When to Use This Skill" (section 10)**

Insert a new section 10 (renumber the existing section 10 to 11):

```markdown
## 10. Repo Mode (When Workspace Was Cloned from GitHub)

If your goal starts with "Before starting, set up the workspace:", you are in **repo mode**. The workspace contains a cloned GitHub repo, not the default SvelteKit template.

**First actions (always do these before anything else):**

```bash
# 1. Understand the repo
git log --oneline -5
ls -la ~/workspace/

# 2. Detect the stack
cat ~/workspace/package.json 2>/dev/null | head -20   # JS/TS
cat ~/workspace/Cargo.toml 2>/dev/null | head -10     # Rust
cat ~/workspace/pyproject.toml 2>/dev/null | head -10 # Python
cat ~/workspace/go.mod 2>/dev/null | head -5          # Go

# 3. Check for flake.nix
ls ~/workspace/flake.nix 2>/dev/null || echo "No flake.nix — create one"
```

**If no `flake.nix` exists, create one for the detected stack.** Examples:

*Node.js/SvelteKit:*
```nix
{
  inputs.nixpkgs.url = "nixpkgs";
  outputs = { nixpkgs, ... }:
    let pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in {
      devShells.x86_64-linux.default = pkgs.mkShell {
        packages = [ pkgs.nodejs_22 pkgs.postgresql_16 ];
      };
    };
}
```

*Python:*
```nix
{
  inputs.nixpkgs.url = "nixpkgs";
  outputs = { nixpkgs, ... }:
    let pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in {
      devShells.x86_64-linux.default = pkgs.mkShell {
        packages = [ pkgs.python312 pkgs.uv ];
      };
    };
}
```

**Start the dev server on `:8080` in the background:**

```bash
# SvelteKit (if package.json has "vite" — template-dev already handles this)
# If template-dev Vite is NOT running (check: curl localhost:8080), start it:
nix develop --command npm run dev -- --port 8080 --host 0.0.0.0 &

# Python (FastAPI / uvicorn):
nix develop --command uvicorn main:app --host 0.0.0.0 --port 8080 --reload &

# Go:
nix develop --command go run . &   # ensure your server listens on :8080

# Rust (axum/actix):
nix develop --command cargo watch -x run &   # ensure your server listens on :8080
```

Then work on the user's goal. Everything else in this skill still applies: deploy via buildah, use port :8080 for live preview, Kubernetes manifests go to the homelab-gitops repo.
```

**Step 2: Commit and push to GitHub**
```bash
cd ~/claude-code-skills
git add skills/template-stack/SKILL.md
git commit -m "feat: add repo mode section for pre-existing GitHub repos"
git push origin main
```

**Step 3: Update flake input and rebuild**
```bash
cd ~/nixos-config
nix flake update claude-code-skills
git add flake.lock
git commit -m "chore: update claude-code-skills flake input"
sudo nixos-rebuild switch --flake .#$(hostname)
```

---

## Task 11: Update bootstrap CLAUDE.md with repo mode instructions

**Files:**
- Modify: `~/homelab-gitops/apps/workstations/secrets/claude-worker-bootstrap.secret.yaml` (SOPS-encrypted)

**Step 1: Decrypt and edit**
```bash
cd ~/homelab-gitops
sops apps/workstations/secrets/claude-worker-bootstrap.secret.yaml
```

This opens your editor. Find the CLAUDE.md content block (look for the `content:` key). Add a **Repo Mode** section near the top of the CLAUDE.md content, after the "Dev Preview" section:

```markdown
## Repo Mode

If your goal begins with "Before starting, set up the workspace:", you are working on an imported GitHub repo.

**First, execute the setup steps in order** (they are listed in your goal). Then use the `template-stack` skill — it has a "Repo Mode" section with stack detection, flake.nix templates, and dev server startup commands.

The live preview proxy forwards `:8080`. Start your dev server there before working on UI changes.
```

Save and exit — SOPS re-encrypts automatically.

**Step 2: Push to trigger Flux reconcile**
```bash
cd ~/homelab-gitops
git add apps/workstations/secrets/claude-worker-bootstrap.secret.yaml
git commit -m "feat: add repo mode instructions to bootstrap CLAUDE.md"
git push origin main
```

**Step 3: Wait for Flux reconcile**
```bash
flux reconcile source git flux-system
kubectl get secret claude-worker-bootstrap -n workstations -o jsonpath='{.data.user-data}' | base64 -d | grep -A5 "Repo Mode"
```
Expected: "Repo Mode" section visible in the decoded secret.

---

## Task 12: End-to-end test

**Step 1: Open https://doable.sammasak.dev — click "Import repo"**

Fill in:
- GitHub URL: `https://github.com/sveltejs/realworld` (or any small public repo)
- Project name: `test-import-01`
- Goal: `Add a dark mode toggle to the header`

Click "Import →".

**Step 2: Watch the project page**

Expected sequence:
1. Provisioning overlay ("Getting ready…")
2. VM boots (~40s on cached node)
3. Activity feed: Claude clones repo, creates flake.nix if needed, starts dev server
4. Live preview appears on :8080 once dev server is up
5. Claude works on goal
6. Completion: friendly message with deployed URL

**Step 3: Verify no regressions on "Build from scratch"**

Create a fresh project using the "Build from scratch" tab with a normal goal. Confirm the SvelteKit template Vite preview still appears instantly (~40s).
