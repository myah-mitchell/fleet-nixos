# The system on the installer ISO. A new VM has an empty OS disk, falls
# through to the ISO, and ends up here: a small NixOS that runs from memory,
# takes its address from the drive Proxmox attaches for cloud-init, and
# waits for install-host to log in as root over SSH.
#
# This module is not part of an installed host. Of the fleet's values it
# reads only the SSH keys.
#
# The ISO holds no secret. sshd makes a new host key at every boot, and
# install-host learns it through Proxmox, from the guest agent of the VM it
# installs, before it sends the host its private keys.
{
  config,
  lib,
  modulesPath,
  ...
}:
{
  imports = [
    (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix")
    (modulesPath + "/profiles/qemu-guest.nix")
    ./options.nix
  ];

  nixpkgs.hostPlatform = "x86_64-linux";

  # The name Proxmox and OpenTofu know the ISO by.
  image.baseName = lib.mkForce "fleet-nixos-installer";

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # host-state looks for this file to tell the installer from an installed
  # host, and install-host refuses to touch a machine that lacks it.
  environment.etc."fleet-installer".text = "fleet-nixos installer\n";

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
    # One host key, made at boot. install-host asks for this one key, through
    # the guest agent, and accepts no other.
    hostKeys = lib.mkForce [
      {
        type = "ed25519";
        path = "/etc/ssh/ssh_host_ed25519_key";
      }
    ];
  };
  users.users.root.openssh.authorizedKeys.keys =
    config.fleet.adminSshKeys ++ config.fleet.deploySshKeys;

  # install-host reads the host key through the guest agent, as
  # qm guest exec on the Proxmox host.
  services.qemuGuest.enable = true;

  # The fleet's disks are ext4. Without ZFS the ISO is smaller.
  boot.supportedFilesystems.zfs = lib.mkForce false;

  boot.kernelParams = [
    "console=tty1"
    "console=ttyS0,115200"
  ];

  # cloud-init is here for the network alone. It writes the address, the
  # gateway and the nameservers from the drive into a systemd-networkd
  # configuration, and asks DHCP when there is no drive. Every module that
  # would set a host name, accounts, keys or packages is left out.
  #
  # NetworkManager, which the NixOS installer brings, is off, so that one
  # program alone configures the interface.
  networking.networkmanager.enable = lib.mkForce false;
  networking.wireless.enable = lib.mkForce false;
  networking.useDHCP = false;
  services.resolved.enable = true;
  services.cloud-init = {
    enable = true;
    network.enable = true;
    settings = {
      datasource_list = [
        "NoCloud"
        "ConfigDrive"
        "None"
      ];
      preserve_hostname = true;
      users = [ ];
      cloud_init_modules = [ ];
      cloud_config_modules = [ ];
      cloud_final_modules = [ ];
    };
  };
}
