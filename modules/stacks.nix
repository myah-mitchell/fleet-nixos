# What the host's stacks need from the host before their containers start:
# folders with the right owners, files that must exist before first use,
# and open ports. The lists come from the host's JSON file as they are. No
# stack is named in this module.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.fleet;
  stacks = cfg.stacks;

  # The group that container uid 1000 maps to on the host. Containers that
  # run as that user may enter a project's folder, other users may not.
  containerGroup = "101000";

  roots = [
    "volumes"
    "logs"
  ];

  modeOr = fallback: mode: if mode == null then fallback else mode;

  sharedFolders = lib.genAttrs (map (root: "/opt/docker/${root}") roots) (path: {
    d = {
      user = cfg.adminName;
      mode = "0755";
    };
  });

  projectFolders = lib.listToAttrs (
    lib.concatMap (
      project:
      map (root: {
        name = "/opt/docker/${root}/${project}";
        value.d = {
          user = cfg.adminName;
          group = containerGroup;
          mode = "0750";
        };
      }) roots
    ) stacks.projects
  );

  containerFolders = lib.listToAttrs (
    map (folder: {
      name = "/opt/docker/${folder.root}/${folder.project}/${folder.path}";
      value.d = {
        user = toString folder.owner;
        group = toString folder.group;
        mode = modeOr "-" folder.mode;
      };
    }) stacks.folders
  );

  # C copies the file only when nothing is at the target, so a file that
  # was filled in on the host, with a real token for instance, is never
  # put back to its first state.
  seedFiles = lib.listToAttrs (
    map (file: {
      name = "/opt/docker/volumes/${file.project}/${file.path}";
      value.C = {
        argument = "${pkgs.writeText (baseNameOf file.path) file.content}";
        user = toString file.owner;
        group = toString file.group;
        mode = modeOr "0644" file.mode;
      };
    }) stacks.files
  );

  rulesFor = allowFrom: lib.filter (rule: rule.allowFrom == allowFrom) stacks.firewall;
  portsFor = proto: map (rule: rule.port) (lib.filter (rule: rule.proto == proto) (rulesFor "any"));
in
{
  config = lib.mkIf cfg.features.docker (
    lib.mkMerge [
      {
        systemd.tmpfiles.settings."20-fleet-stacks" = {
          "/opt/docker".d = {
            user = cfg.adminName;
            group = "docker";
            mode = "0775";
          };
        }
        // sharedFolders
        // projectFolders
        // containerFolders
        // seedFiles;
      }

      (lib.mkIf cfg.features.firewall {
        assertions = [
          {
            assertion = rulesFor "internal" == [ ] || cfg.internalSubnet != "";
            message = "${cfg.name}: a stack opens a port to the internal subnet, but internalSubnet is empty.";
          }
        ];

        networking.firewall.allowedTCPPorts = portsFor "tcp";
        networking.firewall.allowedUDPPorts = portsFor "udp";

        # The subnet is an IPv4 one, so these rules are IPv4 only.
        networking.firewall.extraCommands = lib.concatMapStrings (rule: ''
          # ${lib.replaceStrings [ "\n" "\r" ] [ " " " " ] rule.comment}
          iptables -A nixos-fw -p ${rule.proto} -s ${lib.escapeShellArg cfg.internalSubnet} --dport ${toString rule.port} -j nixos-fw-accept
        '') (rulesFor "internal");
      })
    ]
  );
}
