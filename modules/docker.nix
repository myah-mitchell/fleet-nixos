# Docker, set up so that a container's root is not the host's root, and so
# that containers talk to each other only over networks a stack declares.
{
  config,
  lib,
  ...
}:
let
  cfg = config.fleet;
in
{
  config = lib.mkIf cfg.features.docker {
    virtualisation.docker = {
      enable = true;
      daemon.settings = {
        # Networks made by Compose get small subnets out of one private
        # range, which leaves the rest of the private space to real networks.
        default-address-pools = [
          {
            base = "10.10.0.0/16";
            size = 28;
          }
        ];
        icc = false;
        userns-remap = "default";
        userland-proxy = false;
        no-new-privileges = true;
        live-restore = true;
        log-level = "info";
        log-driver = "json-file";
        log-opts = {
          max-size = "20m";
          max-file = "5";
          compress = "true";
        };
      };
    };

    # With userns-remap set to default, Docker runs containers as the
    # dockremap user's subordinate ids. The range is fixed here, so that
    # container uid 0 is host uid 100000 and container uid 1000 is host uid
    # 101000 on every host. Stack folders are owned by these numbers.
    users.users.dockremap = {
      isSystemUser = true;
      group = "dockremap";
      subUidRanges = [
        {
          startUid = 100000;
          count = 65536;
        }
      ];
      subGidRanges = [
        {
          startGid = 100000;
          count = 65536;
        }
      ];
    };
    users.groups.dockremap = { };

    # Docker waits for the disks its data and its containers' data are on.
    systemd.services.docker.unitConfig.RequiresMountsFor = [
      "/var/lib/docker"
      "/srv/persist"
      "/opt/docker/volumes"
      "/opt/docker/logs"
    ];

    # Pulls and pushes by hand check image signatures.
    environment.variables.DOCKER_CONTENT_TRUST = "1";

    # The network every stack's reverse proxy and its backends share. Stacks
    # declare it as external, so it has to exist before the first one starts.
    systemd.services.docker-proxy-network = {
      description = "Docker network proxy";
      after = [ "docker.service" ];
      requires = [ "docker.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ config.virtualisation.docker.package ];
      script = ''
        docker network inspect proxy > /dev/null 2>&1 || docker network create proxy
      '';
    };
  };
}
