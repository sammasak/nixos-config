# `dev-init` stamps these into repos that lack a devenv; each template
# carries flake.nix + .envrc so one init wires both the shell and direnv.
{ ... }:
{
  flake.templates = {
    rust = {
      path = ../templates/rust;
      description = "Rust devShell (cargo, clippy, rust-analyzer) + direnv";
    };
    node = {
      path = ../templates/node;
      description = "Node/SvelteKit devShell (nodejs, vtsls, svelte-ls) + direnv";
    };
    generic = {
      path = ../templates/generic;
      description = "Minimal devShell + direnv";
    };
  };
}
