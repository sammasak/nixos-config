{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/homelab/journal-collector.nix
    ../../modules/homelab/monitoring/node-exporter.nix
  ];

  homelab.journalCollector = {
    enable = true;
    lokiUrl = "http://${config.sam.fleet.hosts.black-pi.address}:3100/loki/api/v1/push";
    ntfyUrl = config.sam.workers.ntfyUrl;
  };

  # 32 GB RAM, the host's own use not yet measured (msi's 2.8G assumed): a 20G pool reserves 2G each for at most 10,
  # 4 recommended (docs/nspawn-workers.md, Sizing). No ghHostsFile until lukas has a gh login here.
  sam.workers = {
    labelPrefix = "asus";
    pool.memory = "20G";
  };

  sam.profile = {
    username = "lukas";
    hostname = "asus-b460m";
    nativeOtel = true;
  };
  sam.herdr.trustedDirs = map (d: "/home/${config.sam.profile.username}/${d}") [
    "nixos-config"
    ".cache/wt"
  ];

  # Dual boot on Windows' 256 MB ESP, too small for systemd-boot's kernels: as msi, only the GRUB loader goes
  # there, its directory stays on root, and Windows is a hand-written entry (os-prober off).
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

  networking.interfaces.eno1.wakeOnLan.enable = true;
  systemd.services.wol-eno1 = {
    description = "Enable Wake on LAN for eno1";
    after = [ "network-addresses-eno1.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.ethtool}/sbin/ethtool -s eno1 wol g";
    };
  };
}
