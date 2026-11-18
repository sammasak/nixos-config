# GPU telemetry for a host whose sam.fleet entry says gpu = "nvidia": upstream's nvidia_gpu_exporter on the fleet
# address, for black-pi's nvidia-gpu job alone. It runs the host driver's own nvidia-smi per scrape, so it needs the
# NVIDIA driver. The build checks the fields against the exporter and a fake nvidia-smi (flake-modules/llm-bench.nix);
# a field the real driver refuses shows only live, as GpuTelemetryDown.
{ config, lib, ... }:
let
  inherit (config.sam.fleet) hosts;
  gpu = (hosts.${config.networking.hostName} or { }).gpu or null;
in
{
  options.homelab.gpuTelemetry.enable = lib.mkOption {
    type = lib.types.bool;
    default = gpu == "nvidia";
    description = "the exporter; the fleet fact turns it on, the build check seeds it on a host without one";
  };
  options.homelab.gpuTelemetry.fields = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    readOnly = true;
    description = "The nvidia-smi --query-gpu field names the exporter asks for: one series each, for the scorecard (pkgs/llm-bench) and the dashboard.";
    default = [
      "name"
      "uuid"
      "driver_version"
      "memory.total"
      "memory.used"
      "memory.free"
      "utilization.gpu"
      "temperature.gpu"
      "power.draw"
      "power.limit"
      "fan.speed"
      "clocks_throttle_reasons.active"
      "clocks_throttle_reasons.hw_thermal_slowdown"
      "clocks_throttle_reasons.sw_power_cap"
    ];
  };

  config = lib.mkIf config.homelab.gpuTelemetry.enable {
    services.prometheus.exporters.nvidia-gpu = {
      enable = true;
      listenAddress = hosts.${config.networking.hostName}.address;
      extraFlags = [
        "--query-field-names=${lib.concatStringsSep "," config.homelab.gpuTelemetry.fields}"
      ];
    };
    systemd.services.prometheus-nvidia-gpu-exporter = {
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        RestartSec = 5;
        # the nvidia-smi it forks per scrape runs in this cgroup too
        MemoryMax = "128M";
      };
    };

    assertions = [
      {
        assertion = lib.elem "nvidia" config.services.xserver.videoDrivers;
        message = "modules/homelab/monitoring/gpu-exporter.nix: GPU telemetry is on for ${config.networking.hostName} (sam.fleet gpu), but its NVIDIA driver is not configured (services.xserver.videoDrivers has no \"nvidia\"); the exporter runs the driver's nvidia-smi.";
      }
    ];
  };
}
