{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (import ../../lib/firewall.nix lib) mkDualBackendFirewall;
in
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/hardware/video/intel.nix
    ../../modules/homelab/journal-collector.nix
    ../../modules/homelab/ollama-host.nix
    ../../modules/homelab/monitoring/node-exporter.nix
  ];

  homelab.journalCollector.enable = true;

  # 15.9 GiB RAM, ~2.8G of it the host's own: a 10G pool reserves 2G each for at most 5, 3 recommended
  # (docs/nspawn-workers.md, Sizing). No ghHostsFile: msi's lukas has no gh login (git push works over the SSH key).
  sam.workers = {
    # With no instance declared, the activation that ages out `.trash` runs only while this list is
    # non-empty: these two, the newest in .trash, stay until it is empty.
    retired = [
      "research"
      "nats"
    ];
    labelPrefix = "msi";
    shutdownNotice = "Mon-Fri 20:40";
    pool.memory = "10G";
  };

  sam.profile = {
    username = "lukas";
    hostname = "msi-ms7758";
    nativeOtel = true;
  };
  sam.herdr.trustedDirs = map (d: "/home/${config.sam.profile.username}/${d}") [
    "nixos-config"
    ".cache/wt"
  ];

  # Off at midnight, when the fleet's GC and optimise slots fall, and the runtime-host role drops
  # their catch-up at boot: both run inside the Mon-Fri power window instead.
  nix.gc.dates = lib.mkForce "Mon *-*-01..07 12:00";
  nix.optimise.dates = lib.mkForce [ "Wed 12:00" ];

  # The existing Windows ESP is small. Keep GRUB's mutable directory on root,
  # while leaving only the EFI loader on /boot.
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.grub = {
    enable = true;
    device = "nodev";
    efiSupport = true;
    useOSProber = false;
    configurationLimit = 5;
    mirroredBoots = lib.mkForce [
      {
        path = "/boot-nix";
        efiSysMountPoint = "/boot";
        devices = [ "nodev" ];
      }
    ];
    extraEntries = ''
      menuentry "Windows Boot Manager" {
        insmod part_gpt
        insmod fat
        insmod chain
        search --no-floppy --file --set=root /EFI/Microsoft/Boot/bootmgfw.efi
        chainloader /EFI/Microsoft/Boot/bootmgfw.efi
      }
    '';
  };

  # The llm-gateway's bigger tier, off with msi at 21:00 (the gateway falls back to acer).
  services.ollama = {
    enable = true;
    # The pod's tags (five pulled, the factum one below): the gateway's /api fails over on a failed connect, not a 404.
    # qwen2.5-coder:7b is the instruct tag's alias (same blob), Pi's name for it; qwen2.5-coder:3b is pi-harness's.
    loadModels = [
      "llama3.1:8b"
      "llama3.2:3b"
      "qwen2.5-coder:7b-instruct-q4_K_M"
      "qwen2.5-coder:7b"
      "qwen2.5-coder:3b"
    ];
    environmentVariables.OLLAMA_CONTEXT_LENGTH = "16384";
  };
  # factum's worker tag: the /v1 endpoint discards a request's num_ctx, so the repair loop's 8192 lives in the
  # served model (sammasak/factum dev/ollama/Modelfile.factum-qwen2.5-coder-7b). Same weights, a manifest only.
  systemd.services.ollama-model-loader.script = lib.mkAfter ''
    ${lib.getExe config.services.ollama.package} create factum-qwen2.5-coder-7b:q4_K_M-ctx8192 -f ${pkgs.writeText "Modelfile.factum" ''
      FROM qwen2.5-coder:7b-instruct-q4_K_M
      PARAMETER num_ctx 8192
    ''}
  '';
  # llama3.1:8b (4.9G) and a 16K q8_0 KV cache (about 0.9G), as in the pod's 8Gi limit
  systemd.services.ollama.serviceConfig.MemoryMax = "8G";
  # Pi on lenovo, and Pi and the gateway on acer, call it directly.
  networking.firewall = {
    inherit
      (mkDualBackendFirewall {
        nftComment = "Ollama answers Pi on lenovo and acer only.";
        ports = [ config.services.ollama.port ];
        sources = map (h: config.sam.fleet.hosts.${h}.address) [
          "lenovo-21CB001PMX"
          "acer-swift"
        ];
        interfaces = [ ];
        backend = config.networking.firewall.backend;
      })
      extraInputRules
      extraCommands
      ;
  };

  networking.interfaces.enp3s0.wakeOnLan.enable = true;
  systemd.services.wol-enp3s0 = {
    description = "Enable Wake on LAN for enp3s0";
    after = [ "network-addresses-enp3s0.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.ethtool}/sbin/ethtool -s enp3s0 wol g";
    };
  };

}
