# The SSH server: keys only for root (who cannot log in anyway), a short
# leash on idle and parallel sessions, verbose logs, and a banner shown
# before login.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.fleet;

  # Drawn once, when the system is built, so no host needs figlet.
  banner =
    pkgs.runCommand "ssh-banner"
      {
        nativeBuildInputs = [
          pkgs.figlet
          pkgs.python3
        ];
        body = cfg.sshBannerBody;
        passAsFile = [ "body" ];
      }
      ''
        figlet -f big -w 100 ${lib.escapeShellArg cfg.sshBannerName} > name
        python3 ${./ssh-banner/frame_banner.py} name "$bodyPath" > $out
      '';
in
{
  services.openssh = {
    enable = true;

    # Port 22 is opened by modules/firewall.nix, with a rate limit.
    openFirewall = false;

    settings = {
      Banner = "${banner}";
      SyslogFacility = "AUTH";
      LogLevel = "VERBOSE";
      AllowAgentForwarding = true;
      PermitEmptyPasswords = false;
      PermitRootLogin = "no";
      StrictModes = true;
      MaxSessions = 2;

      # A client that stops answering is dropped after two probes, five
      # minutes apart. The probes travel inside the encrypted connection,
      # unlike TCP keepalives, so they cannot be forged.
      TCPKeepAlive = false;
      ClientAliveInterval = 300;
      ClientAliveCountMax = 2;
    };

    extraConfig = ''
      Match User root
        PasswordAuthentication no
    '';
  };

  # Lets an admin hop from this host to the next one with the key held by
  # the agent on their own machine.
  programs.ssh.extraConfig = "ForwardAgent yes";
}
