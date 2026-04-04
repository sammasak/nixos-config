workspaceSrc:
{ lib, pkgs, ... }:
let
  workspaceRepo = "git@github.com:sammasak/workspace.git";
  seedWorkspace = pkgs.writeShellScript "seed-workspace" ''
    set -eu

    workspace_dir="$HOME/workspace"

    if [ -d "$workspace_dir/.git" ]; then
      exit 0
    fi

    if [ -e "$workspace_dir" ] && [ ! -d "$workspace_dir" ]; then
      echo "workspace bootstrap: $workspace_dir exists and is not a directory; skipping" >&2
      exit 0
    fi

    if [ -d "$workspace_dir" ] && [ ! -d "$workspace_dir/.git" ]; then
      echo "workspace bootstrap: $workspace_dir exists without .git; leaving it untouched" >&2
      exit 0
    fi

    mkdir -p "$workspace_dir"

    if ${pkgs.git}/bin/git clone "${workspaceRepo}" "$workspace_dir" 2>/dev/null; then
      echo "workspace bootstrap: cloned ${workspaceRepo}"
      exit 0
    fi

    echo "workspace bootstrap: git clone failed, seeding from the flake snapshot" >&2
    rm -rf "$workspace_dir"
    mkdir -p "$workspace_dir"
    cp -r ${workspaceSrc}/. "$workspace_dir/"
    chmod -R u+w "$workspace_dir"

    ${pkgs.git}/bin/git -C "$workspace_dir" init -b main >/dev/null
    ${pkgs.git}/bin/git -C "$workspace_dir" remote add origin "${workspaceRepo}" >/dev/null 2>&1 || true
    ${pkgs.git}/bin/git -C "$workspace_dir" add -A >/dev/null 2>&1 || true
    ${pkgs.git}/bin/git -C "$workspace_dir" commit -m "Seed workspace from nix snapshot" >/dev/null 2>&1 || true
  '';
in
{
  home.sessionVariables.WORKSPACE_ROOT = "$HOME/workspace";

  home.activation.bootstrapWorkspace = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${seedWorkspace}
  '';
}
