# Ordering cycles and unit lines systemd rejects or ignores (any `<unit>:<line>: ...` parse message) fail the build: systemd-analyze verify
# in user mode (system mode needs a writable /run/systemd), DynamicUser= removed (user mode refuses it). verify exits 0
# on both, so fixtures (a cycle and a Restartsec= under multi-user.target, a Restartsec= beside each Home Manager user's
# units, which are verified file by file) must be reported first, or the check fails. Not covered: cycles among Home
# Manager units, keys of the NixOS units in /etc/systemd/user, generator-made units, the initrd, units only started on
# demand, and edges only the system manager adds (e.g. After=sysinit.target of sockets, paths and timers).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  trueBin = "${pkgs.coreutils}/bin/true";
  hmTrees = lib.concatStringsSep " " (
    lib.mapAttrsToList (
      user: hm:
      "${user}=${
        pkgs.linkFarm "hm-user-units-${user}" (
          lib.mapAttrsToList (name: f: {
            name = lib.removePrefix "systemd/user/" name;
            path = f.source;
          }) (lib.filterAttrs (name: f: f.enable && lib.hasPrefix "systemd/user/" name) hm.xdg.configFile)
        )
      }"
    ) config.home-manager.users
  );
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
      # allowlist: user mode refuses a system action (reboot, poweroff, soft-reboot-force, ...) in JobTimeoutAction=,
      # SuccessAction= and FailureAction= (27 lines in systemd's own units); the system manager, which runs them, accepts it
      # every <file>:<line>: message systemd logs while parsing (unknown key or section, Failed to parse, a path that is not
      # absolute: not all say "ignoring") and the "bad unit file setting" verdict that follows a refused unit
      ignored() { grep -Ei ':[0-9]+: |has a bad unit file setting' | grep -Ev ': [A-Za-z]+Action= specified as user mode action, ignoring' || true; }

      printf '[Unit]\nWants=fixture-b.service\nAfter=fixture-b.service\n[Service]\nExecStart=${trueBin}\n' > units/fixture-a.service
      printf '[Unit]\nAfter=fixture-a.service\n[Service]\nExecStart=${trueBin}\n' > units/fixture-b.service
      printf '[Service]\nRestartsec=5\nExecStart=${trueBin}\n' > units/fixture-c.service
      printf '[Service]\nWorkingDirectory=relative\nExecStart=${trueBin}\n' > units/fixture-d.service
      wants=units/multi-user.target.wants
      chmod u+w "$wants"
      ln -s ../fixture-a.service "$wants/fixture-a.service"
      ln -s ../fixture-c.service "$wants/fixture-c.service"
      ln -s ../fixture-d.service "$wants/fixture-d.service"
      for target in multi-user.target default.target; do
        output=$(verify "$target")
        found=$(cycles <<<"$output")
        grep -q fixture <<<"$found" || {
          echo "the fixture cycle under $target was not reported: $target does not load or does not reach multi-user.target, verify did not walk this tree, or its message changed"
          [ -z "$found" ] || { echo "cycles it did report:"; echo "$found"; }
          exit 1
        }
        found=$(ignored <<<"$output")
        grep -q "fixture-c.service:.*Restartsec" <<<"$found" || {
          echo "the fixture Restartsec= under $target was not reported: verify did not load fixture-c.service, or its message changed"
          [ -z "$found" ] || { echo "ignored lines it did report:"; echo "$found"; }
          exit 1
        }
        # a parse error whose message does not say "ignoring" must be reported too
        grep -q "fixture-d.service:.*WorkingDirectory" <<<"$found" || {
          echo "the fixture WorkingDirectory=relative under $target was not reported: the pattern misses systemd's parse errors that do not say ignoring"
          exit 1
        }
      done
      rm "$wants/fixture-a.service" "$wants/fixture-c.service" "$wants/fixture-d.service" units/fixture-[abcd].service

      for target in multi-user.target default.target; do
        output=$(verify "$target")
        found=$(cycles <<<"$output")
        [ -z "$found" ] || { echo "ordering cycle reaching $target:"; echo "$found"; exit 1; }
        found=$(ignored <<<"$output")
        [ -z "$found" ] || { echo "unit lines systemd ignores, reaching $target:"; echo "$found"; exit 1; }
      done

      hmverify() { SYSTEMD_UNIT_PATH="$PWD/hm:" systemd-analyze --user verify --man=no "$PWD/$1" 2>&1 || true; }
      n=0
      for tree in ${hmTrees}; do
        user=''${tree%%=*}
        rm -rf hm
        cp -rL "''${tree#*=}" hm
        chmod -R u+w hm
        printf '[Service]\nRestartsec=5\nExecStart=${trueBin}\n' > hm/fixture-c.service
        found=$(hmverify hm/fixture-c.service | ignored)
        grep -q "fixture-c.service:.*Restartsec" <<<"$found" || {
          echo "the fixture Restartsec= in $user's Home Manager units was not reported: verify did not load it, or its message changed"
          exit 1
        }
        rm hm/fixture-c.service
        n=$((n + $(find hm -maxdepth 1 -type f | wc -l)))
        found=$(for f in hm/*; do if [ -f "$f" ]; then hmverify "$f"; fi; done | ignored)
        [ -z "$found" ] || { echo "$user's Home Manager unit lines systemd ignores:"; echo "$found"; exit 1; }
      done
      [ "$n" -gt 0 ] || { echo "no Home Manager user unit on this host: the user trees are not this host's"; exit 1; }
      touch $out
    '')

    # Every OnCalendar= of this host's NixOS and Home Manager timers parses: a typo otherwise shows only as a timer
    # systemd refuses at switch time, or one that never fires. A bad and a good fixture spec run first, so a parser
    # that accepts anything, or does not run in the sandbox, fails instead of passing.
    (pkgs.runCommand "systemd-calendar" { nativeBuildInputs = [ config.systemd.package ]; } ''
      export XDG_RUNTIME_DIR=$PWD/xdg HOME=$PWD/home
      mkdir -p xdg home
      parses() { systemd-analyze calendar --iterations=1 -- "$1" >/dev/null 2>&1; }
      ! parses 'Mon-Fri 25:00' || { echo "the fixture 'Mon-Fri 25:00' parsed: systemd-analyze calendar no longer rejects a bad spec"; exit 1; }
      parses 'Mon-Fri 08:30' || { echo "the fixture 'Mon-Fri 08:30' did not parse: systemd-analyze calendar does not run here"; exit 1; }
      etc=${config.system.build.etc}/etc/systemd
      n=0 bad=0
      specs() {
        while IFS= read -r spec; do
          # an empty OnCalendar= resets the list in a drop-in
          [ -n "$spec" ] || continue
          n=$((n + 1))
          parses "$spec" || { echo "$1: OnCalendar=$spec does not parse"; bad=1; }
        done < <(sed -n 's/^OnCalendar=//p' "$2")
      }
      for f in "$etc"/system/*.timer "$etc"/system/*.timer.d/*.conf "$etc"/user/*.timer "$etc"/user/*.timer.d/*.conf; do
        [ -e "$f" ] || continue
        specs "''${f#"$etc"/}" "$f"
      done
      for tree in ${hmTrees}; do
        dir=''${tree#*=}
        for f in "$dir"/*.timer "$dir"/*.timer.d/*.conf; do
          [ -e "$f" ] || continue
          specs "home-manager ''${tree%%=*}: ''${f#"$dir"/}" "$f"
        done
      done
      [ "$n" -gt 0 ] || { echo "no OnCalendar= in this host's timers: the unit tree is not this host's"; exit 1; }
      [ "$bad" = 0 ] || exit 1
      echo "$n OnCalendar= specs parse"
      touch $out
    '')
  ];
}
