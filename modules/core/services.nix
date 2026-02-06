# Core services (audio, bluetooth, etc.)
{ host, ... }:
let
  vars = import ../../hosts/${host}/variables.nix;
  username = vars.username;
in
{
  services = {
    libinput.enable = true;
    fstrim.enable = true;
    devmon.enable = true;
    gvfs.enable = true;
    udisks2.enable = true;

    openssh = {
      enable = true;
      ports = [ 22 ];
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        AllowUsers = [ username ];
        UseDns = false;
        X11Forwarding = false;
        PermitRootLogin = "no";
        PubkeyAuthentication = true;
      };
    };

    blueman.enable = true;
    tumbler.enable = true;

    pulseaudio.enable = false;
    pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
      jack.enable = true;
      extraConfig.pipewire."92-low-latency" = {
        "context.properties" = {
          "default.clock.rate" = 48000;
          "default.clock.quantum" = 256;
          "default.clock.min-quantum" = 256;
          "default.clock.max-quantum" = 256;
        };
      };
    };
  };

  security.rtkit.enable = true;
}
