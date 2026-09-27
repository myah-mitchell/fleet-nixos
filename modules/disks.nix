# The disks an install partitions and formats, declared for disko. Both are
# made again at every install, so nothing on them outlives a rebuild of the
# VM. What has to last lives on the persistent disk, which is deliberately
# not declared here: see modules/persist.nix.
#
# Disks are named by the slot Proxmox attaches them to, so a disk keeps its
# job whatever order the kernel finds the disks in.
{ config, lib, ... }:
let
  slot = number: "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi${toString number}";
in
{
  disko.devices.disk = {
    # The OS disk. The first partition holds GRUB's core image, which a
    # BIOS needs on a GPT disk. The rest is the root filesystem, /boot
    # included. disko also tells GRUB to install itself on this disk.
    os = {
      type = "disk";
      device = slot 0;
      content = {
        type = "gpt";
        partitions = {
          bios = {
            priority = 1;
            size = "1M";
            type = "EF02";
          };
          root = {
            size = "100%";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };
        };
      };
    };

    # Docker's images and container layers. They can all be pulled again,
    # so the host still boots when the disk is missing or damaged.
    docker = lib.mkIf config.fleet.features.docker {
      type = "disk";
      device = slot 1;
      content = {
        type = "filesystem";
        format = "ext4";
        extraArgs = [
          "-L"
          "docker-root"
        ];
        mountpoint = "/var/lib/docker";
        mountOptions = [
          "defaults"
          "nofail"
        ];
      };
    };
  };
}
