# The accounts: root, the admin, the client, and the deploy account. They
# exist exactly as written here. A password or key changed by hand on a host
# is put back by the next deploy.
{
  config,
  lib,
  ...
}:
let
  cfg = config.fleet;
  passwordFile = config.sops.secrets.server-password-hash.path;

  passwordlessSudo = user: {
    users = [ user ];
    commands = [
      {
        command = "ALL";
        options = [ "NOPASSWD" ];
      }
    ];
  };

  # Docker maps container user ids into the range that starts at 100000, and
  # stack folders are owned by ids in it. Accounts for people get no range
  # of their own, so nothing else ever lands there.
  person = {
    isNormalUser = true;
    autoSubUidGidRange = false;
    homeMode = "750";
    extraGroups = [ "users" ] ++ lib.optional cfg.features.docker "docker";
  };
in
{
  users.mutableUsers = false;

  # One password for root, the admin and the client, kept as a hash. It
  # has to be readable before the accounts are made, which is earlier than
  # other secrets are.
  sops.secrets.server-password-hash.neededForUsers = true;

  users.users = {
    # The password works on the console only, which is the way in when
    # SSH does not work. sshd refuses root.
    root.hashedPasswordFile = passwordFile;

    ${cfg.adminName} = person // {
      hashedPasswordFile = passwordFile;
      openssh.authorizedKeys.keys = cfg.adminSshKeys;
    };

    ${cfg.clientAccount} = person // {
      hashedPasswordFile = passwordFile;
      openssh.authorizedKeys.keys = cfg.clientSshKeys;
    };

    # deploy-host connects as this account. It has no password, only keys.
    ${cfg.deployAccount} = {
      isNormalUser = true;
      autoSubUidGidRange = false;
      homeMode = "750";
      hashedPassword = "!";
      openssh.authorizedKeys.keys = cfg.deploySshKeys;
    };
  };

  security.sudo.extraRules = map passwordlessSudo [
    cfg.adminName
    cfg.clientAccount
    cfg.deployAccount
  ];

  # A deploy copies store paths to the host as the deploy account. Only a
  # trusted user may add paths that the host did not build itself.
  nix.settings.trusted-users = [ cfg.deployAccount ];

  # Keeps a user's processes, such as a tmux session, alive after logout.
  services.logind.settings.Login.KillUserProcesses = false;
}
