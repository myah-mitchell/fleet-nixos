#!/usr/bin/env bash
# Builds the installer ISO for a fleet, with the fleet's installer host key
# in it, and prints the path of the ISO.
#
# The key comes from secrets/installer.yaml, which new-installer-key makes.
# It is decrypted into a private folder that is gone when the command ends,
# and reaches the ISO through the flake's input named installer-key.
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

Reading the installer's key needs the deploy key or the admin key, in
SOPS_AGE_KEY or SOPS_AGE_KEY_FILE.

The key ends up in the Nix store of the machine that builds, where every
local account can read it, and in the ISO.
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
installer_key=$fleet_directory/secrets/installer.yaml
[[ -f $installer_key ]] || fail "the fleet has no secrets/installer.yaml, make it with new-installer-key"

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

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
chmod 0700 "$work"

mkdir "$work/installer-key"
if ! (umask 077 && sops decrypt --extract '["ssh_host_ed25519_key"]' "$installer_key" >"$work/installer-key/ssh_host_ed25519_key" 2>/dev/null); then
  fail "cannot read secrets/installer.yaml, check SOPS_AGE_KEY or SOPS_AGE_KEY_FILE"
fi
[[ -s $work/installer-key/ssh_host_ed25519_key ]] || fail "the key in secrets/installer.yaml is empty"

if ! built=$(nix build "$flake#installer-iso" \
  --override-input fleet "$fleet_input" \
  --override-input installer-key "path:$work/installer-key" \
  --no-write-lock-file --no-link --print-out-paths); then
  fail "building the installer ISO failed"
fi

# The store path is a folder that holds the ISO under iso/. The folder's
# own name ends in .iso too, so only files count.
iso=$(find "$built/" -type f -name '*.iso' -print -quit)
[[ -n $iso ]] || fail "the build at $built holds no ISO"
echo "$iso"
