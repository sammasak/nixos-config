# ESP32 development host: USB-serial and debug-probe access, espflash on PATH.
{ ... }:
{
  imports = [
    ./base.nix
    ../embedded
  ];

  sam.embedded.enable = true;
}
