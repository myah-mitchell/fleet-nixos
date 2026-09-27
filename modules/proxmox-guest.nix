# What a VM on Proxmox needs: drivers for the virtual hardware, the guest
# agent, GRUB on the OS disk, and a console on the serial port, which is the
# display Proxmox shows for these VMs.
{ lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  services.qemuGuest.enable = true;

  # The VM boots with SeaBIOS, so GRUB goes into the disk's boot sector.
  # modules/disks.nix names the disk.
  boot.loader.grub.enable = true;
  boot.loader.timeout = lib.mkForce 2;

  boot.kernelParams = [
    "console=tty1"
    "console=ttyS0,115200"
  ];
  boot.loader.grub.extraConfig = ''
    serial --speed=115200
    terminal_input console serial
    terminal_output console serial
  '';
}
