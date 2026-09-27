# The firewall refuses what is not allowed, and logs what it refuses. The
# rules added here are checked in the order written, before the final
# refusal.
{ config, lib, ... }:
{
  config = lib.mkMerge [
    {
      networking.firewall.enable = config.fleet.features.firewall;
    }
    (lib.mkIf config.fleet.features.firewall {
      networking.firewall = {
        logRefusedConnections = true;

        extraCommands = ''
          # Port 113 (ident) is answered with a reset instead of silence, so
          # a mail or IRC server that asks does not wait for a timeout.
          ip46tables -A nixos-fw -p tcp --dport 113 -j LOG --log-level info --log-prefix "refused ident: "
          ip46tables -A nixos-fw -p tcp --dport 113 -j REJECT --reject-with tcp-reset

          # SSH, with a rate limit: an address that opens ten connections
          # within thirty seconds has the tenth refused. One pass of the
          # playbooks makes about six in a row.
          ip46tables -A nixos-fw -p tcp --dport 22 -m conntrack --ctstate NEW -m recent --name ssh --set
          ip46tables -A nixos-fw -p tcp --dport 22 -m conntrack --ctstate NEW -m recent --name ssh --update --seconds 30 --hitcount 10 -j nixos-fw-log-refuse
          ip46tables -A nixos-fw -p tcp --dport 22 -j nixos-fw-accept
        '';
      };
    })
  ];
}
