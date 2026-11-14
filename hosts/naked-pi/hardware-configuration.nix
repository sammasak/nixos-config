# Pi 3: the firmware's [pi3] section chains u-boot-rpi3.bin into the extlinux boot of modules/hardware/pi-sd-image.nix.
{ pkgs, ... }:
{
  boot.initrd.availableKernelModules = [
    "usbhid"
    "usb_storage"
  ];

  # Ships brcm/BCM43430A1.hcd — the onboard BT firmware patch. Without it
  # hci_uart_bcm detects the chip but Read-Local-Name times out (hci0 unusable).
  hardware.firmware = [ pkgs.raspberrypiWirelessFirmware ];
}
