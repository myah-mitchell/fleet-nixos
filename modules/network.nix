# The host's name, time zone and static address. Nothing is asked of DHCP,
# and cloud-init plays no part on an installed host: the address comes from
# the host's JSON file.
{ config, ... }:
let
  cfg = config.fleet;
in
{
  networking.hostName = cfg.hostName;
  networking.domain = cfg.locationDomain;
  time.timeZone = cfg.timeZone;

  networking.useNetworkd = true;
  networking.useDHCP = false;
  networking.interfaces.${cfg.network.interface}.ipv4.addresses = [
    {
      inherit (cfg.network) address prefixLength;
    }
  ];
  networking.defaultGateway = {
    address = cfg.network.gateway;
    inherit (cfg.network) interface;
  };
  networking.nameservers = cfg.network.dns;
}
