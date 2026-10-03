#!/usr/bin/env bash
# Builds the installer ISO for a fleet and prints the path of the ISO.
#
# The ISO takes the SSH keys that may log in from the fleet's
# nixos/fleet.json, and holds no secret. Its sshd makes a new host key at
# every boot, which install-host reads through Proxmox.
set -euo pipefail

usage() {
  cat <<'END'
Usage: build-installer --fleet <fleet-dir> [--flake <flake>]

Builds the installer ISO of the fleet in <fleet-dir> and prints the path of
the ISO file. Nothing is built when nothing changed since the last build.

  --fleet <fleet-dir>  Checkout of the repository that describes the fleet
  --flake <flake>      The flake to build from. Default: the flake this
                       command came from
  --help               Show this text

END
}

fail() {
  echo "build-installer: $1" >&2
  exit 1
}

fleet_directory=
flake=$FLEET_DEFAULT_FLAKE
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help)
      usage
      exit 0
      ;;
    --fleet | --flake)
      [[ $# -ge 2 ]] || fail "$1 needs a value"
      case "$1" in
        --fleet) fleet_directory=$2 ;;
        --flake) flake=$2 ;;
      esac
      shift 2
      ;;
    *)
      fail "unknown argument $1, see --help"
      ;;
  esac
done
[[ -n $fleet_directory ]] || fail "--fleet <fleet-dir> is required, see --help"

[[ -d $fleet_directory ]] || fail "$fleet_directory is not a folder"
fleet_directory=$(realpath "$fleet_directory")
[[ -f $fleet_directory/nixos/fleet.json ]] || fail "the fleet has no nixos/fleet.json, write it with ansible's nixos-sync.yml"

# git+file takes the files git tracks and nothing else, so an ignored or
# untracked file in the checkout never reaches the store.
if [[ -e $fleet_directory/.git ]]; then
  fleet_input="git+file://$fleet_directory"
else
  fleet_input="path:$fleet_directory"
fi

if [[ -d $flake ]]; then
  flake=$(realpath "$flake")
  if [[ -e $flake/.git ]]; then
    flake="git+file://$flake"
  else
    flake="path:$flake"
  fi
fi

if ! built=$(nix build "$flake#installer-iso" \
  --override-input fleet "$fleet_input" \
  --no-write-lock-file --no-link --print-out-paths); then
  fail "building the installer ISO failed"
fi

# The store path is a folder that holds the ISO under iso/. The folder's
# own name ends in .iso too, so only files count.
iso=$(find "$built/" -type f -name '*.iso' -print -quit)
[[ -n $iso ]] || fail "the build at $built holds no ISO"
echo "$iso"
