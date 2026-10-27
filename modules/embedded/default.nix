# Host-side USB-serial + debug-probe access for ESP32 dev. Grants device access
# on the HOST only; firmware and flashing live in the separate embedded-lab repo.
{ config, lib, pkgs, ... }:
let
  cfg = config.sam.embedded;
  username = config.sam.profile.username;

  # ID_MM_DEVICE_IGNORE stops ModemManager AT-probing the adapter (garbles flashing),
  # set per-device so this module does not depend on rf-lab masking ModemManager.
  ttyRule = vendor: products: lib.concatMapStrings
    (p: ''SUBSYSTEM=="tty", ATTRS{idVendor}=="${vendor}", ATTRS{idProduct}=="${p}", GROUP="dialout", MODE="0660", ENV{ID_MM_DEVICE_IGNORE}="1"'' + "\n")
    products;

  # CP210x, CH340/341/343, FTDI serial bridges.
  serialRules =
    ttyRule "10c4" [ "ea60" ]
    + ttyRule "1a86" [ "7523" "5523" "55d4" "55d3" ]
    + ttyRule "0403" [ "6001" "6010" "6011" "6014" "6015" ];

  # Espressif native USB-Serial/JTAG: tty node for flashing + raw usb node so
  # probe-rs/JTAG works for a headless SSH user (no logind seat for uaccess).
  espressifRules =
    ''SUBSYSTEM=="tty", ATTRS{idVendor}=="303a", GROUP="dialout", MODE="0660", ENV{ID_MM_DEVICE_IGNORE}="1"'' + "\n"
    + ''SUBSYSTEM=="usb", ATTR{idVendor}=="303a", ATTR{idProduct}=="1001", GROUP="dialout", MODE="0660"'' + "\n";
in
{
  options.sam.embedded.enable = lib.mkEnableOption "USB-serial and debug-probe access for ESP32 development";

  config = lib.mkIf cfg.enable {
    users.users.${username}.extraGroups = [ "dialout" ];

    services.udev.packages = [ pkgs.probe-rs-tools ];
    services.udev.extraRules = serialRules + espressifRules;

    environment.systemPackages = [ pkgs.espflash ];
  };
}
