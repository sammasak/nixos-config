# Sandboxes inside a guest: nspawn masks parts of /proc, so no new user namespace can mount a full procfs (the kernel
# answers "VFS: Mount too revealing"). Both wrappers mount procfs with subset=pid instead, which has no /proc/sys,
# meminfo or cpuinfo: free, uptime and sysctl fail inside, nproc and builds work. https://github.com/systemd/systemd/issues/34226
{ config, lib, pkgs, ... }:
let
  # Runs bwrap on the guest's /proc with CAP_SYS_ADMIN just long enough to remount it subset=pid in the new pid
  # namespace. Mount needs uid 0 there, so the sandbox runs as mapped root. CAP_SETFCAP stays because Claude's
  # apply-seccomp helper maps uid 0 into a nested user namespace.
  bwrapSubsetProc = pkgs.writeShellApplication {
    name = "bwrap-subset-proc";
    runtimeInputs = [ pkgs.bubblewrap ];
    text = ''
      args=() armed=0
      while (( $# )); do
        if [[ $1 == --proc && ''${2-} == /proc ]]; then
          args+=(--uid 0 --gid 0 --bind /proc /proc --cap-add CAP_SYS_ADMIN --cap-add CAP_SETPCAP --cap-add CAP_SETFCAP)
          armed=1; shift 2; continue
        fi
        if (( armed == 1 )) && [[ $1 == -- ]]; then
          args+=(-- ${pkgs.bash}/bin/bash -c '${pkgs.util-linux}/bin/mount -t proc -o subset=pid proc /proc && exec ${pkgs.util-linux}/bin/setpriv --bounding-set=-all,+setfcap --inh-caps=-all --ambient-caps=-all "$@"' bash)
          armed=2; shift; continue
        fi
        args+=("$1"); shift
      done
      exec bwrap "''${args[@]}"
    '';
  };

  # OCI runtimes get the /proc mount from the bundle's config.json, which neither podman nor buildah let you edit.
  crunSubsetPid = pkgs.writeShellApplication {
    name = "crun-subset-pid";
    runtimeInputs = [ pkgs.jq ];
    text = ''
      bundle=$PWD sub=
      for ((i = 1; i <= $#; i++)); do
        a=''${!i}
        case $a in
          --root|--log|--log-format|--cgroup-manager) ((i++)) || true ;;
          -b|--bundle) j=$((i + 1)); bundle=''${!j} ;;
          --bundle=*) bundle=''${a#*=} ;;
          -*) ;;
          *) [[ -n $sub ]] || sub=$a ;;
        esac
      done
      if [[ $sub == create || $sub == run ]]; then
        jq '(.mounts[] | select(.destination == "/proc" and .type == "proc").options) += ["subset=pid"]' \
          "$bundle/config.json" > "$bundle/config.json.new"
        mv "$bundle/config.json.new" "$bundle/config.json"
      fi
      exec ${lib.getExe pkgs.crun} "$@"
    '';
  };
in
{
  options.sam.workers.nestedSandbox = {
    bwrap = lib.mkOption { type = lib.types.path; readOnly = true; default = lib.getExe bwrapSubsetProc; };
    crun = lib.mkOption { type = lib.types.path; readOnly = true; default = lib.getExe crunSubsetPid; };
  };

  config = {
    # Claude honours bwrapPath only from managed settings; sandbox.enabled stays the user's choice.
    environment.etc."claude-code/managed-settings.json".text = builtins.toJSON {
      sandbox.bwrapPath = config.sam.workers.nestedSandbox.bwrap;
    };

    virtualisation.podman.enable = true;
    # no /dev/fuse (vfs), no systemd user manager (cgroupfs, file events), no /dev/net/tun (run with --network=none)
    virtualisation.containers = {
      storage.settings.storage.driver = "vfs";
      containersConf.settings.engine = {
        cgroup_manager = "cgroupfs";
        events_logger = "file";
        runtime = config.sam.workers.nestedSandbox.crun;
      };
    };
  };
}
