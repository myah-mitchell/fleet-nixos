# Komodo Periphery as a system service. It connects out to Komodo Core, so
# no port is opened for it. Core then uses the connection to deploy the
# host's stacks.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.fleet;
  periphery = pkgs.callPackage ../packages/komodo-periphery.nix { };
  keyFolder = "/srv/persist/host/komodo";

  configFile = (pkgs.formats.toml { }).generate "periphery.config.toml" (
    {
      root_directory = "/opt/docker";
      connect_as = cfg.hostName;
      # Periphery writes a new key here when the file does not exist. On
      # the persistent disk the key, and with it the host's identity
      # towards Core, outlives a reinstall.
      private_key = "file:${keyFolder}/periphery.key";
    }
    // lib.optionalAttrs (cfg.komodoCoreAddress != "") {
      core_address = cfg.komodoCoreAddress;
    }
    // lib.optionalAttrs (cfg.komodoCorePublicKey != "") {
      core_public_keys = cfg.komodoCorePublicKey;
    }
  );
in
{
  config = lib.mkIf cfg.features.komodo {
    assertions = [
      {
        assertion = cfg.features.docker;
        message = "${cfg.name}: features.komodo needs features.docker, since Periphery manages Docker.";
      }
    ];

    warnings = lib.optional (cfg.komodoCoreAddress == "") ''
      ${cfg.name}: komodoCoreAddress is empty, so Periphery has no Komodo Core to connect to.
    '';

    users.users.komodo = {
      isSystemUser = true;
      group = "docker";
      home = "/var/lib/komodo";
      createHome = true;
    };

    # The onboarding key lets a host that Core has not seen before add
    # itself. It reaches Periphery through the environment, so it is in no
    # file the store holds.
    sops.secrets.komodo-onboarding-key = { };
    sops.templates."komodo-periphery.env" = {
      owner = "komodo";
      content = ''
        PERIPHERY_ONBOARDING_KEY=${config.sops.placeholder.komodo-onboarding-key}
      '';
    };

    systemd.tmpfiles.settings."20-komodo-periphery" = {
      "/opt/docker/stacks".d = {
        user = cfg.adminName;
        group = "docker";
        mode = "0775";
      };
      "/opt/docker/builds".d = {
        user = "komodo";
        group = "docker";
        mode = "0755";
      };
      "/opt/docker/repos".d = {
        user = "komodo";
        group = "docker";
        mode = "0755";
      };
      "/opt/docker/ssl".d = {
        user = "komodo";
        group = "root";
        mode = "0700";
      };
      "${keyFolder}".d = {
        user = "komodo";
        group = "docker";
        mode = "0700";
      };
      # After a reinstall the komodo account may have another number than
      # the one the key was written under.
      "${keyFolder}/periphery.key".z = {
        user = "komodo";
        group = "docker";
      };
    };

    systemd.services.komodo-periphery = {
      description = "Komodo Periphery";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      requires = [ "docker.service" ];
      after = [
        "network-online.target"
        "docker.service"
      ];
      unitConfig.RequiresMountsFor = [
        "/srv/persist"
        "/opt/docker/volumes"
        "/opt/docker/logs"
      ];

      # Periphery runs docker, docker compose and git, and opens shells for
      # Core's terminal, so it sees the same programs a logged-in user does.
      path = [
        "/run/wrappers"
        "/run/current-system/sw"
      ];

      restartTriggers = [ configFile ];

      serviceConfig = {
        User = "komodo";
        Group = "docker";
        ExecStart = "${lib.getExe periphery} --config-path ${configFile}";
        EnvironmentFile = config.sops.templates."komodo-periphery.env".path;
        # A wrong or missing onboarding key is not fatal: Periphery keeps
        # trying until Core accepts it.
        Restart = "always";
        RestartSec = 10;
      };
    };
  };
}
