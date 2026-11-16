{ ... }:
{
  # A cushion before the OOM killer reaches anything important.
  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };

  services.journald.settings.Journal = {
    SystemMaxUse = "500M";
    MaxRetentionSec = "1month";
  };

  # User slices only. system.slice is DELIBERATELY left unmanaged: oomd would
  # judge the host services there on cgroup pressure alone, and the ones that
  # matter carry their own MemoryMax and OOMScoreAdjust.
  systemd.oomd = {
    enable = true;
    enableUserSlices = true;
  };

  # Man pages stay — documentation.man.enable keeps its default.
  documentation.nixos.enable = false;
  documentation.info.enable = false;
  documentation.doc.enable = false;

  # ptrace_scope=1 still allows gdb/strace on a process you launched yourself.
  # Deliberately NOT security.lockKernelModules: that breaks on-demand module
  # loading after boot.
  boot.kernel.sysctl = {
    "kernel.dmesg_restrict" = 1;
    "kernel.kptr_restrict" = 1;
    "kernel.yama.ptrace_scope" = 1;
  };
}
