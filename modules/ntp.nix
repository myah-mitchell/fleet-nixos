# Keeps the clock right with chrony.
{ config, lib, ... }:
{
  services.chrony = {
    enable = true;
    servers = lib.mkIf (config.fleet.ntpServers != [ ]) config.fleet.ntpServers;
  };
}
