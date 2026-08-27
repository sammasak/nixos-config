{ ... }:
{
  # A soft cushion before the OOM killer reaches anything important, on hosts
  # where one node's death is a total outage.
  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };

  services.journald.extraConfig = ''
    SystemMaxUse=500M
    MaxRetentionSec=1month
  '';

  # User slices only. system.slice is DELIBERATELY left unmanaged: k3s and
  # containerd live there, and oomd would judge them on cgroup pressure alone,
  # killing a kubelet that kubernetes is already responsible for evicting from.
  systemd.oomd = {
    enable = true;
    enableUserSlices = true;
  };

  # Man pages stay — documentation.man.enable keeps its default.
  documentation.nixos.enable = false;
  documentation.info.enable = false;
  documentation.doc.enable = false;

  # ptrace_scope=1 still allows gdb/strace on a process you launched yourself.
  # Deliberately NOT security.lockKernelModules: that breaks the on-demand
  # module loading k3s and containerd rely on.
  boot.kernel.sysctl = {
    "kernel.dmesg_restrict" = 1;
    "kernel.kptr_restrict" = 1;
    "kernel.yama.ptrace_scope" = 1;
  };
}
