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

  sharedFolders = lib.genAttrs (map (root: "/opt/docker/${root}") roots) (_: {
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

  # The addresses beyond the internal subnet that an internal rule's port is
  # also open to, from portSources.
  matches = rule: entry: entry.port == rule.port && entry.proto == rule.proto;
  sourcesFor = rule: lib.concatMap (entry: entry.sources) (lib.filter (matches rule) cfg.portSources);
  # Only a Docker host with the firewall on writes the rules above.
  openedInternal = lib.optionals (cfg.features.docker && cfg.features.firewall) (rulesFor "internal");
  unmatchedSources = lib.filter (
    entry: !(lib.any (rule: matches rule entry) openedInternal)
  ) cfg.portSources;
in
{
  config = lib.mkMerge [
    # Checked on every host, so that a source on a host without Docker or a
    # firewall is refused too, and not left unread.
    {
      assertions = [
        {
          assertion =
            unmatchedSources == [ ] && lib.all (entry: lib.all lib.isString entry.sources) cfg.portSources;
          message = "${cfg.name}: portSources names ${
            lib.concatMapStringsSep ", " (entry: "${toString entry.port}/${entry.proto}") unmatchedSources
          }, which no stack on the host opens to the internal subnet with the firewall on.";
        }
      ];
    }

    (lib.mkIf cfg.features.docker (
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

          # The subnet and the sources are IPv4 ones, so these rules are IPv4 only.
          networking.firewall.extraCommands = lib.concatMapStrings (rule: ''
            # ${lib.replaceStrings [ "\n" "\r" ] [ " " " " ] rule.comment}
            ${lib.concatMapStrings (source: ''
              iptables -A nixos-fw -p ${rule.proto} -s ${lib.escapeShellArg source} --dport ${toString rule.port} -j nixos-fw-accept
            '') ([ cfg.internalSubnet ] ++ sourcesFor rule)}
          '') (rulesFor "internal");
        })

        # A port that Docker publishes never reaches the rules above. Docker
        # sends the connection on to the container in the FORWARD chain, and
        # the NixOS firewall filters INPUT. So a published port that is meant
        # for the internal subnet only is closed to every other address in
        # DOCKER-USER, the chain Docker leaves to the host. The rule matches
        # the port the connection was made to, before Docker rewrote it.
        #
        # Docker makes DOCKER-USER when it starts, and keeps what is in it.
        # The firewall may start first, so it makes the chain when it is not
        # there yet.
        #
        # A port with more sources in portSources lets those through first.
        # RETURN hands the connection back to Docker's own rules, as a
        # connection from the internal subnet is.
        (lib.mkIf (cfg.features.firewall && cfg.features.docker && rulesFor "internal" != [ ]) {
          networking.firewall.extraCommands = lib.mkAfter (
            ''
              iptables -N DOCKER-USER 2>/dev/null || true
              iptables -F DOCKER-USER
            ''
            + lib.concatMapStrings (rule: ''
              ${lib.concatMapStrings (source: ''
                iptables -A DOCKER-USER -i ${lib.escapeShellArg cfg.network.interface} -p ${rule.proto} -m conntrack --ctstate NEW --ctorigdstport ${toString rule.port} -s ${lib.escapeShellArg source} -j RETURN
              '') (sourcesFor rule)}
              iptables -A DOCKER-USER -i ${lib.escapeShellArg cfg.network.interface} -p ${rule.proto} -m conntrack --ctstate NEW --ctorigdstport ${toString rule.port} ! -s ${lib.escapeShellArg cfg.internalSubnet} -j DROP
            '') (rulesFor "internal")
          );
        })
      ]
    ))
  ];
}
