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
  # Each file is copied to the store on its own. Named as a part of the
  # fleet source, a file would bring the whole source into the host's
  # closure, with every other host's encrypted secrets.
  alone =
    file: name:
    builtins.path {
      path = fleetSource + file;
      inherit name;
    };

  hostSecretsPath = fleetSource + "/secrets/hosts/${config.fleet.name}.yaml";
  hostSecrets = alone "/secrets/hosts/${config.fleet.name}.yaml" "${config.fleet.name}-secrets.yaml";
in
{
  options.fleet.hostSecretsFile = lib.mkOption {
    type = lib.types.nullOr lib.types.path;
    readOnly = true;
    default = if builtins.pathExists hostSecretsPath then hostSecrets else null;
    description = ''
      The sops file with this host's own secrets, or null when the fleet
      source has none for it. A secret that only this host may read names
      this file as its sopsFile.
    '';
  };

  config.sops = {
    # Secrets every host reads. A secret is looked up here unless it names
    # another file.
    defaultSopsFile = alone "/secrets/fleet.yaml" "fleet-secrets.yaml";

    age.sshKeyPaths = [ "/srv/persist/host/ssh/ssh_host_ed25519_key" ];
    gnupg.sshKeyPaths = [ ];
  };
}
