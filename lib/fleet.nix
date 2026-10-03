# Reads a fleet source: nixos/fleet.json, the values every host shares, and
# one nixos/hosts/<name>.json per host. The result is plain data. Turning it
# into NixOS options is the job of modules/options.nix.
#
# A missing key stops the evaluation with a message that names the file and
# the key, so a mistake in a generated file is found before any module reads
# a value that is not there.
{ lib }:
let
  fleetKeys = [
    "abbrName"
    "adminList"
    "adminName"
    "adminSshKeys"
    "caCertificates"
    "clientAccount"
    "clientSshKeys"
    "deployAccount"
    "deploySshKeys"
    "domainName"
    "komodoCoreAddress"
    "komodoCorePublicKey"
    "locationAbbr"
    "locationDomain"
    "ntpServers"
    "shortName"
    "sshBannerBody"
    "sshBannerName"
    "timeZone"
  ];

  hostKeys = [
    "features"
    "hostName"
    "internalSubnet"
    "network"
    "portSources"
    "stacks"
    "swapMiB"
  ];

  networkKeys = [
    "address"
    "dns"
    "gateway"
    "interface"
    "prefixLength"
  ];

  featureKeys = [
    "auditd"
    "docker"
    "fail2ban"
    "firewall"
    "komodo"
    "mail"
    "mosh"
    "nodeExporter"
  ];

  stackKeys = [
    "files"
    "firewall"
    "folders"
    "names"
    "projects"
  ];

  folderKeys = [
    "group"
    "mode"
    "owner"
    "path"
    "project"
    "root"
  ];

  fileKeys = [
    "content"
    "group"
    "mode"
    "owner"
    "path"
    "project"
  ];

  firewallKeys = [
    "allowFrom"
    "comment"
    "port"
    "proto"
  ];

  portSourceKeys = [
    "port"
    "proto"
    "sources"
  ];

  # Returns the value unchanged when it is an object holding every key in
  # the list, and stops the evaluation otherwise. `where` names the file and
  # the place inside it, for the message.
  requireKeys =
    where: keys: value:
    let
      missing = lib.filter (key: !(value ? ${key})) keys;
    in
    if !lib.isAttrs value then
      throw "${where}: expected an object"
    else if missing != [ ] then
      throw "${where}: missing key ${lib.concatMapStringsSep ", " (key: "\"${key}\"") missing}"
    else
      value;

  requireKeysInEach =
    where: keys: values:
    if !lib.isList values then
      throw "${where}: expected a list"
    else
      lib.imap0 (index: requireKeys "${where}[${toString index}]" keys) values;

  readJson =
    file:
    if builtins.pathExists file then
      builtins.fromJSON (builtins.readFile file)
    else
      throw "${toString file}: the file does not exist";

  readFleet = file: requireKeys "nixos/fleet.json" fleetKeys (readJson file);

  readHost =
    name: file:
    let
      where = "nixos/hosts/${name}.json";
      host = requireKeys where hostKeys (readJson file);
      stacks = requireKeys "${where}: stacks" stackKeys host.stacks;
    in
    host
    // {
      network = requireKeys "${where}: network" networkKeys host.network;
      features = requireKeys "${where}: features" featureKeys host.features;
      portSources = requireKeysInEach "${where}: portSources" portSourceKeys host.portSources;
      stacks = stacks // {
        folders = requireKeysInEach "${where}: stacks.folders" folderKeys stacks.folders;
        files = requireKeysInEach "${where}: stacks.files" fileKeys stacks.files;
        firewall = requireKeysInEach "${where}: stacks.firewall" firewallKeys stacks.firewall;
      };
    };

  # The names of the hosts in a fleet source: every nixos/hosts/<name>.json.
  hostNames =
    source:
    let
      directory = source + "/nixos/hosts";
      entries = if builtins.pathExists directory then builtins.readDir directory else { };
      jsonFiles = lib.filterAttrs (entry: kind: kind == "regular" && lib.hasSuffix ".json" entry) entries;
    in
    map (lib.removeSuffix ".json") (lib.attrNames jsonFiles);
in
{
  # { fleet = <fleet.json>; hosts = { <name> = <hosts/<name>.json>; }; }
  read = source: {
    fleet = readFleet (source + "/nixos/fleet.json");
    hosts = lib.genAttrs (hostNames source) (
      name:
      if name == "installer" then
        throw "nixos/hosts/installer.json: the name installer is taken by the installer ISO's system"
      else
        readHost name (source + "/nixos/hosts/${name}.json")
    );
  };
}
