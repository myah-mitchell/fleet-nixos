# mosh keeps a session alive across a changed address or a sleeping laptop.
# It logs in over SSH and then talks over UDP ports 60000 to 61000, which
# the option opens in the firewall.
{ config, lib, ... }:
{
  config = lib.mkIf config.fleet.features.mosh {
    programs.mosh.enable = true;
  };
}
