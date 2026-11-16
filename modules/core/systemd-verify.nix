# Ordering cycles fail the build: systemd-analyze verify over this host's units, in the manager's user mode (system
# mode needs a writable /run/systemd, which the sandbox lacks). User mode refuses DynamicUser= units, which would drop
# them from the transaction, so they are verified with that line removed. verify exits 0 on a cycle: the check reads
# its output, and a fixture cycle wanted by multi-user.target must be reported through it and default.target first,
# so a verify that did not walk this host's tree, or a renamed message, fails instead of passing. Not covered:
# generator-made units (mounts), the initrd, units only started on demand, and edges only the system manager adds,
# e.g. the implicit After=sysinit.target of sockets, paths and timers and the default dependencies of declared mounts
# and swaps, so a cycle through those edges passes.
{ config, pkgs, ... }:
let
  trueBin = "${pkgs.coreutils}/bin/true";
in
{
  system.checks = [
    (pkgs.runCommand "systemd-verify" { nativeBuildInputs = [ config.systemd.package ]; } ''
      export XDG_RUNTIME_DIR=$PWD/xdg HOME=$PWD/home
      mkdir -p xdg home units
      # -r keeps the symlinks: masked units point at /dev/null, and .wants entries must stay links to count
      cp -r ${config.system.build.etc}/etc/systemd/system/. units/
      chmod u+w units
      { grep -l '^DynamicUser=' units/*.service || true; } | xargs -r sed -i '/^DynamicUser=/d'
      for d in units/*.service.d; do
        grep -qs '^DynamicUser=' "$d"/*.conf || continue
        # a copied .d keeps its read-only store mode; a symlinked one is just unlinked
        chmod -R u+w "$d" 2>/dev/null || true
        rm -rf "$d"
        cp -rL "${config.system.build.etc}/etc/systemd/system/''${d#units/}" "$d"
        chmod -R u+w "$d"
        sed -i '/^DynamicUser=/d' "$d"/*.conf
      done
      n=$(find units -maxdepth 1 -name '*.service' | wc -l)
      [ -e units/multi-user.target ] && [ "$n" -gt 20 ] || { echo "only $n service units: the unit tree is not this host's"; exit 1; }

      verify() { SYSTEMD_UNIT_PATH="$PWD/units" systemd-analyze --user verify --man=no "$PWD/units/$1" 2>&1 || true; }
      cycles() { grep -E 'Found ordering cycle|deleted to break ordering cycle' || true; }

      printf '[Unit]\nWants=fixture-b.service\nAfter=fixture-b.service\n[Service]\nExecStart=${trueBin}\n' > units/fixture-a.service
      printf '[Unit]\nAfter=fixture-a.service\n[Service]\nExecStart=${trueBin}\n' > units/fixture-b.service
      wants=units/multi-user.target.wants
      chmod u+w "$wants"
      ln -s ../fixture-a.service "$wants/fixture-a.service"
      for target in multi-user.target default.target; do
        found=$(verify "$target" | cycles)
        grep -q fixture <<<"$found" || {
          echo "the fixture cycle under $target was not reported: $target does not load or does not reach multi-user.target, verify did not walk this tree, or its message changed"
          [ -z "$found" ] || { echo "cycles it did report:"; echo "$found"; }
          exit 1
        }
      done
      rm "$wants/fixture-a.service" units/fixture-a.service units/fixture-b.service

      for target in multi-user.target default.target; do
        found=$(verify "$target" | cycles)
        [ -z "$found" ] || { echo "ordering cycle reaching $target:"; echo "$found"; exit 1; }
      done
      touch $out
    '')
  ];
}
