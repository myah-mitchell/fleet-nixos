{
  description = "NixOS fleet on Proxmox";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # What the fleet is: its hosts and its secrets. The default is the
    # example in this repository. Real use puts a private repository in its
    # place: --override-input fleet git+file:///path/to/fleet-private
    fleet = {
      url = "path:./example";
      flake = false;
    };

    # The installer ISO's SSH host key: a folder that holds
    # ssh_host_ed25519_key. The default is the example's key, which is
    # public. build-installer puts the fleet's own key in its place.
    installer-key = {
      url = "path:./example/keys/installer";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      sops-nix,
      disko,
      fleet,
      installer-key,
    }:
    let
      inherit (nixpkgs) lib;
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      fleetSource = fleet.outPath;
      fleetData = (import ./lib/fleet.nix { inherit lib; }).read fleetSource;

      # One host: every module, and the values of the two JSON files as the
      # options the modules read.
      hostSystem =
        name: host:
        lib.nixosSystem {
          specialArgs = { inherit fleetSource; };
          modules = [
            sops-nix.nixosModules.sops
            disko.nixosModules.disko
            ./modules
            { fleet = fleetData.fleet // host // { inherit name; }; }
          ];
        };

      hosts = lib.mapAttrs hostSystem fleetData.hosts;

      installer = lib.nixosSystem {
        specialArgs.installerHostKey = builtins.path {
          path = installer-key.outPath + "/ssh_host_ed25519_key";
          name = "installer-ssh-host-key";
        };
        modules = [
          ./modules/installer.nix
          { inherit (fleetData) fleet; }
        ];
      };

      # A command: the script of the same name under scripts/, with the
      # tools it calls taken from this flake's nixpkgs, whatever is
      # installed where it runs.
      command =
        name: description: runtimeInputs:
        pkgs.writeShellApplication {
          inherit name runtimeInputs;
          text = builtins.readFile (./scripts + "/${name}.sh");
          # The flake a command builds hosts from, unless --flake names
          # another: the one the command itself came from.
          runtimeEnv.FLEET_DEFAULT_FLAKE = "path:${self}";
          meta = { inherit description; };
        };

      commands = {
        new-host-key =
          command "new-host-key" "Make a host's SSH keys and let the host read the fleet's secrets"
            [
              pkgs.age
              pkgs.coreutils
              pkgs.openssh
              pkgs.sops
              pkgs.ssh-to-age
              pkgs.yq-go
            ];
        new-installer-key =
          command "new-installer-key"
            "Make the installer ISO's SSH host key and store it in the fleet's secrets"
            [
              pkgs.coreutils
              pkgs.openssh
              pkgs.sops
              pkgs.yq-go
            ];
        build-installer =
          command "build-installer" "Build the installer ISO with the fleet's installer host key"
            [
              pkgs.coreutils
              pkgs.findutils
              pkgs.sops
            ];
        host-state = command "host-state" "Print installer, installed, or unreachable for an address" [
          pkgs.bash
          pkgs.coreutils
          pkgs.openssh
        ];
        install-host = command "install-host" "Install NixOS on a host that is booted into the installer" [
          pkgs.age
          pkgs.coreutils
          pkgs.jq
          pkgs.nixos-anywhere
          pkgs.openssh
          pkgs.sops
        ];
        deploy-host = command "deploy-host" "Build a host's configuration and activate it on the host" [
          pkgs.age
          pkgs.coreutils
          pkgs.nixos-rebuild
          pkgs.openssh
          pkgs.sops
        ];
        reset-host =
          command "reset-host" "Wipe the start of a host's OS disk, so that it boots the installer again"
            [
              pkgs.openssh
            ];
      };

      # Evaluates a system completely, down to the derivation of its
      # toplevel, without building it. The derivation's path is kept as
      # plain text, so the check does not depend on the system itself.
      evaluated =
        name: configuration:
        "${name} ${builtins.unsafeDiscardStringContext configuration.config.system.build.toplevel.drvPath}";
    in
    {
      nixosConfigurations = hosts // {
        inherit installer;
      };

      packages.${system} = commands // {
        installer-iso = installer.config.system.build.isoImage;
      };

      apps.${system} = lib.mapAttrs (_: package: {
        type = "app";
        program = lib.getExe package;
        meta = { inherit (package.meta) description; };
      }) commands;

      formatter.${system} = pkgs.nixfmt;

      checks.${system} = commands // {
        # Every host evaluates, and every secret a host asks for is in the
        # sops file it names.
        hosts = pkgs.runCommand "hosts-evaluate" {
          evaluations = lib.concatStringsSep "\n" (lib.mapAttrsToList evaluated hosts);
          manifests = lib.concatMap (configuration: [
            configuration.config.system.build.sops-nix-manifest
            configuration.config.system.build.sops-nix-users-manifest
          ]) (lib.attrValues hosts);
        } ''printf '%s\n' "$evaluations" > $out'';

        installer = pkgs.runCommand "installer-evaluates" {
          evaluation = evaluated "installer" installer;
        } ''printf '%s\n' "$evaluation" > $out'';

        formatting = pkgs.runCommand "formatting" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
          find ${self} -name '*.nix' -print0 | xargs -0 nixfmt --check
          touch $out
        '';

        shellcheck = pkgs.runCommand "shellcheck" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
          shellcheck ${self}/scripts/*.sh
          touch $out
        '';
      };
    };
}
