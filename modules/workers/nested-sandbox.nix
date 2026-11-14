# Nested sandboxes in a guest, which cannot mount a full procfs: https://github.com/systemd/systemd/issues/34226
{ lib, pkgs, ... }:
let
  # Claude's apply-seccomp helper puts the command in a pid namespace of its own and fails to mount a procfs for it, so
  # /proc keeps numbering the wrapper's namespace and procps dies with "lookup self". The command's first bash mounts
  # subset=pid again; it holds the helper's capabilities there. It replaces any BASH_ENV of the caller.
  remountProc = pkgs.writeText "remount-proc.sh" ''
    read -r _pid _ < /proc/self/stat
    [ "$_pid" = "$$" ] || ${pkgs.util-linux}/bin/mount -t proc -o subset=pid proc /proc 2>/dev/null || :
    unset _pid
  '';

  # The sandbox runs as mapped uid 0 holding only CAP_SETFCAP (Claude's apply-seccomp helper maps uid 0 into a nested
  # user namespace): CAP_SYS_ADMIN is held just long enough to remount procfs subset=pid. bwrap's command starts at the
  # first standalone `--`, so none after the rewritten `--proc /proc` leaves the arguments untouched.
  bwrapSubsetProc = pkgs.writeShellApplication {
    name = "bwrap-subset-proc";
    runtimeInputs = [ pkgs.bubblewrap ];
    text = ''
      split=0
      for ((i = 1; i <= $#; i++)); do
        if [[ ''${!i} == -- ]]; then split=$i; break; fi
      done
      args=() armed=0
      for ((i = 1; i <= $#; i++)); do
        a=''${!i} j=$((i + 1))
        if (( split > 0 && i < split )) && [[ $a == --proc && ''${!j-} == /proc ]]; then
          args+=(--uid 0 --gid 0 --bind /proc /proc --cap-add CAP_SYS_ADMIN --cap-add CAP_SETPCAP --cap-add CAP_SETFCAP)
          armed=1; i=$j
        elif (( armed == 1 && i == split )); then
          args+=(-- ${pkgs.bash}/bin/bash -p -c '${pkgs.util-linux}/bin/mount -t proc -o subset=pid proc /proc && exec ${pkgs.util-linux}/bin/setpriv --no-new-privs --bounding-set=-all,+setfcap --inh-caps=-all --ambient-caps=-all "$@"' bash)
          armed=2
        else
          args+=("$a")
        fi
      done
      if (( armed == 1 )); then
        echo "bwrap-subset-proc: rewrote --proc but found no command separator" >&2
        exit 1
      fi
      if (( armed == 2 )); then export BASH_ENV=${remountProc}; fi
      exec bwrap "''${args[@]}"
    '';
  };

  # The /proc mount of a container comes from the bundle's config.json, which neither podman nor buildah let you edit.
  crunSubsetPid = pkgs.writeShellApplication {
    name = "crun-subset-pid";
    runtimeInputs = [
      pkgs.jq
      pkgs.crun
    ];
    text = ''
      bundle=$PWD sub=
      for ((i = 1; i <= $#; i++)); do
        a=''${!i}
        case $a in
          --root|--log|--log-format|--cgroup-manager) i=$((i + 1)) ;;
          -b|--bundle) j=$((i + 1)); bundle=''${!j}; i=$j ;;
          --bundle=*) bundle=''${a#*=} ;;
          -*) ;;
          *) [[ -n $sub ]] || sub=$a ;;
        esac
      done
      if [[ $sub == create || $sub == run ]]; then
        if ! jq '(.mounts[]? | select(.destination == "/proc" and .type == "proc").options) |= (. + ["subset=pid"] | unique)' \
          "$bundle/config.json" > "$bundle/config.json.new"; then
          echo "crun-subset-pid: cannot add subset=pid to $bundle/config.json" >&2
          exit 1
        fi
        mv "$bundle/config.json.new" "$bundle/config.json"
      fi
      exec crun "$@"
    '';
  };
in
{
  # Claude honours bwrapPath only from managed settings; sandbox.enabled stays the user's choice.
  environment.etc."claude-code/managed-settings.json".text = builtins.toJSON {
    sandbox.bwrapPath = lib.getExe bwrapSubsetProc;
  };

  virtualisation.podman.enable = true;
  virtualisation.containers = {
    storage.settings.storage.driver = "vfs";
    containersConf.settings.engine = {
      cgroup_manager = "cgroupfs";
      events_logger = "file";
      # podman keys runtime features on the runtime's name, which must stay crun
      runtime = "crun";
      runtimes.crun = [ (lib.getExe crunSubsetPid) ];
    };
  };
}
