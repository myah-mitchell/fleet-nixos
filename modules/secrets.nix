# Secrets come from the fleet source as sops files and are decrypted on the
# host, at activation, into /run/secrets. The host's age key is not stored
# anywhere: sops-nix derives it from the host's ed25519 SSH key.
{
  config,
  lib,
  fleetSource,
  ...
}:
let
  hostSecrets = fleetSource + "/secrets/hosts/${config.fleet.name}.yaml";
in
{
  options.fleet.hostSecretsFile = lib.mkOption {
    type = lib.types.nullOr lib.types.path;
    readOnly = true;
    default = if builtins.pathExists hostSecrets then hostSecrets else null;
    description = ''
      The sops file with this host's own secrets, or null when the fleet
      source has none for it. A secret that only this host may read names
      this file as its sopsFile.
    '';
  };

  config.sops = {
    # Secrets every host reads. A secret is looked up here unless it names
    # another file.
    defaultSopsFile = fleetSource + "/secrets/fleet.yaml";

    age.sshKeyPaths = [ "/srv/persist/host/ssh/ssh_host_ed25519_key" ];
    gnupg.sshKeyPaths = [ ];
  };
}
