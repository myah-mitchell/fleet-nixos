# Every module of an installed host. Each one covers one concern, and the
# ones that are optional read their switch from fleet.features.
{
  imports = [
    ./auditd.nix
    ./certificates.nix
    ./disks.nix
    ./docker.nix
    ./fail2ban.nix
    ./firewall.nix
    ./komodo-periphery.nix
    ./logging.nix
    ./mail.nix
    ./mosh.nix
    ./network.nix
    ./node-exporter.nix
    ./ntp.nix
    ./options.nix
    ./packages.nix
    ./persist.nix
    ./proxmox-guest.nix
    ./secrets.nix
    ./ssh.nix
    ./stacks.nix
    ./swap.nix
    ./system.nix
    ./users.nix
  ];
}
