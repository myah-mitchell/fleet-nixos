# /srv/persist holds what must outlive a reinstall: the host's SSH keys,
# and on a Docker host the volumes and logs of its containers.
#
# On a Docker host it is a disk of its own, ext4 on the whole disk. The
# install command formats that disk only when it holds no filesystem, and
# disko never sees it, so an install cannot wipe it. On any other host
# /srv/persist is a folder on the OS disk, and the install command puts the
# host's keys there again at every install.
{ config, lib, ... }:
let
  cfg = config.fleet;
  persist = "/srv/persist";
  bindMounts = [
    "volumes"
    "logs"
  ];
in
{
  config = lib.mkMerge [
    {
      # sshd reads its keys from where the install command put them. The
      # same ed25519 key decrypts the host's secrets: see modules/secrets.nix.
      services.openssh.hostKeys = [
        {
          type = "ed25519";
          path = "${persist}/host/ssh/ssh_host_ed25519_key";
        }
        {
          type = "rsa";
          bits = 4096;
          path = "${persist}/host/ssh/ssh_host_rsa_key";
        }
      ];
    }

    (lib.mkIf cfg.features.docker {
      # Mounted in the initrd, because secrets are decrypted with a key on
      # this disk before the other filesystems are mounted.
      fileSystems.${persist} = {
        device = "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi2";
        fsType = "ext4";
        neededForBoot = true;
      };

      fileSystems."/opt/docker/volumes" = {
        device = "${persist}/volumes";
        fsType = "none";
        options = [ "bind" ];
        depends = [ persist ];
      };

      fileSystems."/opt/docker/logs" = {
        device = "${persist}/logs";
        fsType = "none";
        options = [ "bind" ];
        depends = [ persist ];
      };

      # A bind mount fails when its source is missing, and a failed mount
      # stops the boot. The install command makes both folders. This makes
      # them again if someone removed one.
      systemd.services.persist-folders = {
        description = "Folders on the persistent disk that are mounted elsewhere";
        unitConfig = {
          DefaultDependencies = false;
          RequiresMountsFor = persist;
        };
        requiredBy = [
          "opt-docker-volumes.mount"
          "opt-docker-logs.mount"
        ];
        before = [
          "opt-docker-volumes.mount"
          "opt-docker-logs.mount"
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = lib.concatMapStrings (folder: ''
          mkdir -p ${persist}/${folder}
        '') bindMounts;
      };
    })
  ];
}
