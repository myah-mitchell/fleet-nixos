# What every host needs before anything else makes sense: the release its
# state follows, the platform, the nix settings, and the marker file that
# tells the fleet's commands this is an installed host.
{ config, ... }:
{
  system.stateVersion = "26.05";
  nixpkgs.hostPlatform = "x86_64-linux";

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Every deploy leaves the previous system in the store, so that a rollback
  # is possible. A month of them is kept.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  # A host changes only when a deploy changes it. It never fetches or
  # applies an update by itself.
  system.autoUpgrade.enable = false;

  # host-state looks for this file to tell an installed host from the
  # installer, and reset-host compares its content with the name it was
  # given before it wipes anything.
  environment.etc."fleet-host".text = "${config.fleet.name}\n";
}
