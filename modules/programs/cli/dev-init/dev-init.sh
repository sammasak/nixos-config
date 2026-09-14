# Adopt the current repo into the devenv standard: stamp a template devShell
# if none exists, wire direnv, and allow it. Idempotent.

TEMPLATE_FLAKE="${DEV_INIT_TEMPLATES:-$HOME/nixos-config}"

if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "dev-init: run inside a git repository" >&2
  exit 1
fi
root=$(git rev-parse --show-toplevel)
cd "$root"

if [ ! -f flake.nix ]; then
  if [ -f Cargo.toml ]; then
    template=rust
  elif [ -f package.json ]; then
    template=node
  else
    template=generic
  fi
  echo "dev-init: no flake.nix — initialising from template '$template'"
  nix flake init -t "$TEMPLATE_FLAKE#$template"
  git add flake.nix .envrc
else
  echo "dev-init: flake.nix already present"
fi

if [ ! -f .envrc ]; then
  echo "use flake" > .envrc
  git add .envrc
  echo "dev-init: wrote .envrc"
fi

if ! grep -q devShells flake.nix; then
  echo "dev-init: WARNING: flake.nix defines no devShells output; add one (templates: nix flake show $TEMPLATE_FLAKE)" >&2
fi

direnv allow .

echo "dev-init: done. Humans/editors get the shell via direnv on cd;"
echo "          agents and CI use:  nix develop -c -- <cmd>"
