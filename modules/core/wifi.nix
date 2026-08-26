# Declarative WiFi for the laptops — profile survives crashes.
#
# Why this exists (2026-08-26 incident): acer-swift OOM-hung and its
# NetworkManager connection profile (imperative state under
# /etc/NetworkManager/system-connections) was lost in the crash. The
# headless sole worker came back up with no way onto the network — a
# console session and manual password entry were required to recover.
# With the profile declared here, every boot re-asserts it.
#
# Secrets: SSID + PSK live sops-encrypted in secrets/homelab/wifi.yaml
# (key "env", systemd EnvironmentFile format) and are substituted by
# NetworkManager-ensure-profiles at activation. Never plaintext in-repo.
#
# To set/rotate the password:  sops secrets/homelab/wifi.yaml
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
