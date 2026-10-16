# Host-side USB-serial + debug-probe access for ESP32 development. This only
# grants device access on the HOST; firmware lives in the separate `embedded-lab`
# repo and there is no flashing logic here (see the embedded:* devenv tasks).
{ config, lib, pkgs, ... }:
let
  cfg = config.sam.embedded;
  username = config.sam.profile.username;

  # CP210x, CH340/CH341, FTDI and Espressif native USB-Serial/JTAG bridges.
  # brltty can claim CH341 (1a86:7523) and steal the port; it is not installed here.
  # ModemManager is already masked by the Pi roles.
  rule = vendor: products: lib.concatMapStrings
    (p: ''SUBSYSTEM=="tty", ATTRS{idVendor}=="${vendor}", ATTRS{idProduct}=="${p}", GROUP="dialout", MODE="0660", TAG+="uaccess"'' + "\n")
    products;
  espressifRule = ''SUBSYSTEM=="tty", ATTRS{idVendor}=="303a", GROUP="dialout", MODE="0660", TAG+="uaccess"'' + "\n";
in
{
  options.sam.embedded.enable = lib.mkEnableOption "USB-serial and debug-probe access for ESP32 development";

  config = lib.mkIf cfg.enable {
    users.users.${username}.extraGroups = [ "dialout" ];

    services.udev.packages = [ pkgs.probe-rs-tools ];
    services.udev.extraRules =
      rule "10c4" [ "ea60" ]
      + rule "1a86" [ "7523" "5523" "55d4" ]
      + rule "0403" [ "6001" "6010" "6014" "6015" ]
      + espressifRule;

    environment.systemPackages = [ pkgs.espflash ];
  };
}
