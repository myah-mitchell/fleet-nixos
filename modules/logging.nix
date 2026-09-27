# The journal keeps the host's own copy of the logs, capped in size, and
# rsyslog forwards every message to the syslog server on the gateway.
{ config, ... }:
{
  services.journald.extraConfig = "SystemMaxUse=100M";

  # rsyslog is used for the forwarding alone. With an empty default
  # configuration it writes no log files of its own.
  services.rsyslogd = {
    enable = true;
    defaultConfig = "";
    extraConfig = "*.* @@${config.fleet.network.gateway}:514";
  };
}
