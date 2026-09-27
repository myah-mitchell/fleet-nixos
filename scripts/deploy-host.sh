#!/usr/bin/env bash
# Builds a host's configuration from the flake and a fleet checkout, and
# activates it on the host with nixos-rebuild.
#
# The host is checked against its SSH host key, which the fleet's secrets
# hold, so a deploy only ever talks to the machine that was installed as
# this host.
set -euo pipefail

usage() {
  cat <<'END'
Usage: deploy-host --fleet <fleet-dir> [--flake <flake>] [--user <user>]
                   [--build-on local|remote]
                   [--action switch|boot|test|dry-activate] <host> <address>

Builds the configuration of <host> and activates it on the host at <address>.

  --fleet <fleet-dir>  Checkout of the repository that describes the fleet
  --flake <flake>      The flake to build from. Default: the flake this
                       command came from
  --user <user>        The account to log in as. Default: ansible
  --build-on <where>   remote builds on the host, local builds here and
                       copies the result. Default: remote
  --action <action>    What nixos-rebuild does with the result. Default: switch
  --help               Show this text

Reading the host's key needs the deploy key or the admin key, in
SOPS_AGE_KEY or SOPS_AGE_KEY_FILE.
END
}

fail() {
  echo "deploy-host: $1" >&2
  exit 1
}

fleet_directory=
flake=$FLEET_DEFAULT_FLAKE
user=ansible
build_on=remote
action=switch
positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help)
      usage
      exit 0
      ;;
    --fleet | --flake | --user | --build-on | --action)
      [[ $# -ge 2 ]] || fail "$1 needs a value"
      case "$1" in
        --fleet) fleet_directory=$2 ;;
        --flake) flake=$2 ;;
        --user) user=$2 ;;
        --build-on) build_on=$2 ;;
        --action) action=$2 ;;
      esac
      shift 2
      ;;
    -*)
      fail "unknown option $1"
      ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done
[[ -n $fleet_directory ]] || fail "--fleet <fleet-dir> is required, see --help"
[[ ${#positional[@]} -eq 2 ]] || fail "expected a host and an address, see --help"
host=${positional[0]}
address=${positional[1]}
[[ $host =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || fail "'$host' is not a host name: letters, digits, - and _ only"
[[ $address =~ ^[A-Za-z0-9][A-Za-z0-9.:-]*$ ]] || fail "'$address' is not an address"

case "$build_on" in
  local | remote) ;;
  *) fail "--build-on is local or remote, not '$build_on'" ;;
esac
case "$action" in
  switch | boot | test | dry-activate) ;;
  *) fail "--action is switch, boot, test or dry-activate, not '$action'" ;;
esac

[[ -d $fleet_directory ]] || fail "$fleet_directory is not a folder"
fleet_directory=$(realpath "$fleet_directory")
[[ -f $fleet_directory/nixos/hosts/$host.json ]] || fail "the fleet has no nixos/hosts/$host.json"
host_keys=$fleet_directory/secrets/host-keys/$host.yaml
[[ -f $host_keys ]] || fail "the fleet has no secrets/host-keys/$host.yaml"

# git+file takes the files git tracks and nothing else, so an ignored or
# untracked file in the checkout never reaches the store.
if [[ -e $fleet_directory/.git ]]; then
  fleet_input="git+file://$fleet_directory"
else
  fleet_input="path:$fleet_directory"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if ! public_key=$(sops decrypt --extract '["ssh_host_ed25519_key.pub"]' "$host_keys" 2>/dev/null); then
  fail "cannot decrypt secrets/host-keys/$host.yaml, check SOPS_AGE_KEY or SOPS_AGE_KEY_FILE"
fi
read -r key_type key_data _ <<<"$public_key"
echo "$address $key_type $key_data" >"$work/known_hosts"

export NIX_SSHOPTS="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$work/known_hosts -o HostKeyAlgorithms=ssh-ed25519"

arguments=(
  "$action"
  --flake "$flake#$host"
  --override-input fleet "$fleet_input"
  --no-write-lock-file
  --target-host "$user@$address"
  --sudo
  --no-reexec
)
if [[ $build_on == remote ]]; then
  arguments+=(--build-host "$user@$address")
fi

if ! nixos-rebuild "${arguments[@]}"; then
  fail "nixos-rebuild $action failed for $host at $address"
fi
