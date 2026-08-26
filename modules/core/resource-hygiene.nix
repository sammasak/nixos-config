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
}
