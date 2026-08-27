# Node resource hygiene: compressed swap and bounded logs.
# Baseline 2026-08-26: no swap on any host; journald at 1.1G (lenovo) /
# 3.9G (acer-swift) with no cap.
{ ... }:
{
  # zram: soft cushion before the OOM killer reaches anything important —
  # near-free insurance on hosts where one node's death is a total outage.
  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };

  services.journald.extraConfig = ''
    SystemMaxUse=500M
    MaxRetentionSec=1month
  '';

  # userspace OOM killer, scoped to user slices only. A runaway editor, browser
  # or agent session gets killed under memory pressure before the kernel OOM
  # killer starts picking victims by badness score.
  #
  # Root and system slices are DELIBERATELY left unmanaged: k3s, containerd and
  # the workloads under them live in system.slice, and systemd-oomd would judge
  # them on cgroup pressure alone — killing a kubelet or a container runtime
  # that kubernetes itself is already responsible for evicting from. Node
  # pressure handling stays with k3s.
  systemd.oomd = {
    enable = true;
    enableUserSlices = true;
  };

  # Trim offline documentation nobody reads on these machines. Man pages stay
  # (documentation.man.enable keeps its default) — those get used.
  documentation.nixos.enable = false;
  documentation.info.enable = false;
  documentation.doc.enable = false;

  # Cheap kernel-info hygiene. Each of these closes a source of the addresses
  # and process state an exploit uses to orient itself, and none of them
  # changes what a normal session can do:
  #   dmesg_restrict   — non-root cannot read the kernel ring buffer
  #   kptr_restrict    — kernel pointers print as zeros to unprivileged readers
  #   yama.ptrace_scope — a process may only ptrace its own descendants
  #                       (gdb/strace still work when you launch the target)
  # Deliberately NOT setting security.lockKernelModules: it would break
  # on-demand module loading, which k3s/containerd rely on.
  boot.kernel.sysctl = {
    "kernel.dmesg_restrict" = 1;
    "kernel.kptr_restrict" = 1;
    "kernel.yama.ptrace_scope" = 1;
  };
}
