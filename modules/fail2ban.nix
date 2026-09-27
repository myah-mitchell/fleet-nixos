# Bans an address for ten minutes after five failed SSH logins. The sshd
# jail is on whenever fail2ban is.
{ config, lib, ... }:
{
  config = lib.mkIf config.fleet.features.fail2ban {
    services.fail2ban = {
      enable = true;
      maxretry = 5;
      bantime = "10m";
      daemonSettings.Definition = {
        loglevel = "INFO";
        dbpurgeage = "1d";
        dbmaxmatches = 10;
      };
    };
  };
}
