# Declarative WiFi for the laptops. NetworkManager's own profiles are imperative
# state, so a crash can lose them — and a headless node that loses its profile
# needs a console session and a typed password to come back.
# See vault: homelab/acer-swift-wifi-resilience.md
#
# SSID + PSK live sops-encrypted in secrets/homelab/wifi.yaml (key "env", systemd
# EnvironmentFile format), substituted at activation. Never plaintext in-repo.
# To set or rotate the password:  sops secrets/homelab/wifi.yaml
{ config, lib, ... }:
let
  inherit (lib) mkEnableOption mkIf;
  cfg = config.sam.wifi;
in
{
  options.sam.wifi = {
    declarativeHomeProfile = mkEnableOption "declarative home-WiFi NetworkManager profile (sops-backed)";
  };

  config = mkIf cfg.declarativeHomeProfile {
    sops.secrets."wifi/env" = {
      sopsFile = ../../secrets/homelab/wifi.yaml;
      key = "env";
      restartUnits = [ "NetworkManager-ensure-profiles.service" ];
    };

    networking.networkmanager.ensureProfiles = {
      environmentFiles = [ config.sops.secrets."wifi/env".path ];
      profiles.home-wifi = {
        connection = {
          id = "home-wifi";
          type = "wifi";
          autoconnect = "true";
          # Win against any stale imperative profile for the same SSID.
          autoconnect-priority = "10";
        };
        wifi = {
          ssid = "$HOME_WIFI_SSID";
          mode = "infrastructure";
        };
        wifi-security = {
          key-mgmt = "wpa-psk";
          psk = "$HOME_WIFI_PSK";
        };
        ipv4.method = "auto";
        ipv6.method = "auto";
      };
    };
  };
}
