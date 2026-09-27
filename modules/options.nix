# The options every other module reads. Their names and shapes follow the two
# JSON files a fleet source holds: nixos/fleet.json, shared by every host,
# and nixos/hosts/<name>.json, one host. lib/fleet.nix reads the files and
# flake.nix sets these options from them, so no module parses JSON itself.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;

  text =
    description:
    mkOption {
      type = types.str;
      inherit description;
    };

  textList =
    description:
    mkOption {
      type = types.listOf types.str;
      inherit description;
    };

  feature =
    description:
    mkOption {
      type = types.bool;
      inherit description;
    };

  # null sets no mode: a folder keeps the mode it has, and a seed file is
  # made with 0644.
  mode = mkOption {
    type = types.nullOr (types.strMatching "[0-7]{3,4}");
    description = "Permissions as octal digits, or null to set none.";
  };

  account = mkOption {
    type = types.either types.ints.unsigned types.str;
    description = "A numeric id or a name.";
  };

  certificate = types.submodule {
    options = {
      name = text "What the certificate is called. Only for the reader.";
      content = text "The certificate in PEM form.";
    };
  };

  folder = types.submodule {
    options = {
      project = text "The Compose project the folder belongs to.";
      root = mkOption {
        type = types.enum [
          "volumes"
          "logs"
        ];
        description = "Which of /opt/docker/volumes and /opt/docker/logs holds the folder.";
      };
      path = text "Path of the folder below the project's folder.";
      owner = account;
      group = account;
      inherit mode;
    };
  };

  seedFile = types.submodule {
    options = {
      project = text "The Compose project the file belongs to.";
      path = text "Path of the file below /opt/docker/volumes/<project>.";
      owner = account;
      group = account;
      inherit mode;
      content = text "The text the file starts out with.";
    };
  };

  firewallRule = types.submodule {
    options = {
      port = mkOption {
        type = types.port;
        description = "The port to open.";
      };
      proto = mkOption {
        type = types.enum [
          "tcp"
          "udp"
        ];
        description = "The protocol the port is opened for.";
      };
      allowFrom = mkOption {
        type = types.enum [
          "internal"
          "any"
        ];
        description = "internal admits only fleet.internalSubnet. any admits every address.";
      };
      comment = text "What listens on the port.";
    };
  };
in
{
  options.fleet = {
    name = text ''
      The host's name in the inventory: the name of its JSON file, of its
      nixosConfiguration, and of its files under secrets/. The install,
      deploy and reset commands call the host by this name.
    '';

    # nixos/fleet.json
    shortName = text "The organisation's short name.";
    abbrName = text "The organisation's abbreviation.";
    locationAbbr = text "The location's abbreviation. May be empty.";
    domainName = text "The organisation's domain.";
    locationDomain = text "The domain the hosts of this location are named under.";
    timeZone = text "Time zone of every host, as a tz database name.";
    adminName = text "Name of the admin account.";
    adminList = text "Address that mail for root is sent to.";
    clientAccount = text "Name of the client account.";
    deployAccount = text "Name of the account that deploys connect as.";
    adminSshKeys = textList "SSH public keys that may log in to the admin account.";
    deploySshKeys = textList "SSH public keys that may log in to the deploy account.";
    clientSshKeys = textList "SSH public keys that may log in to the client account.";
    caCertificates = mkOption {
      type = types.listOf (types.either types.str certificate);
      description = "Certificate authorities the hosts trust, beyond the ones NixOS ships.";
    };
    ntpServers = textList "Time servers. Empty keeps the NixOS default pool.";
    sshBannerName = text "The name drawn in large letters at the top of the SSH banner.";
    sshBannerBody = text "The text shown below the name in the SSH banner.";
    komodoCoreAddress = text "Address of Komodo Core, which Periphery connects to.";
    komodoCorePublicKey = text "Komodo Core's public key, which Periphery checks Core against.";

    # nixos/hosts/<name>.json
    hostName = text "The host's own name, without a domain.";
    network = {
      interface = text "Name of the network interface in the guest.";
      address = text "The host's IPv4 address.";
      prefixLength = mkOption {
        type = types.ints.between 0 32;
        description = "Prefix length of the address.";
      };
      gateway = text "The default gateway. It also receives the forwarded syslog.";
      dns = textList "Nameservers.";
    };
    features = {
      firewall = feature "Filter incoming traffic and rate limit SSH.";
      docker = feature "Run Docker, on its own disk, with remapped user ids.";
      komodo = feature "Run Komodo Periphery.";
      nodeExporter = feature "Serve host metrics on port 9100.";
      fail2ban = feature "Ban addresses that keep failing to log in.";
      auditd = feature "Record security events with the Linux audit system.";
      mail = feature "Send mail for root to the admin list.";
      mosh = feature "Accept mosh sessions.";
    };
    swapMiB = mkOption {
      type = types.ints.unsigned;
      description = "Size of the swap file in MiB. 0 means no swap file.";
    };
    internalSubnet = text "The subnet, in CIDR form, that ports marked internal are opened to. May be empty.";
    stacks = {
      names = textList "The stacks the host runs.";
      projects = textList "The Compose projects of those stacks.";
      folders = mkOption {
        type = types.listOf folder;
        description = "Folders the containers expect to exist.";
      };
      files = mkOption {
        type = types.listOf seedFile;
        description = "Files put in place once, and left alone when they already exist.";
      };
      firewall = mkOption {
        type = types.listOf firewallRule;
        description = "Ports the stacks listen on.";
      };
    };

    fqdn = mkOption {
      type = types.str;
      readOnly = true;
      default = "${config.fleet.hostName}.${config.fleet.locationDomain}";
      description = "The host's full name.";
    };
  };
}
