#!/usr/bin/env bash
# Installs NixOS on a machine that is booted into the fleet's installer.
#
# In order:
#   1. checks that the machine at the address is the installer, by its SSH
#      host key
#   2. partitions and formats the OS disk and the Docker disk (nixos-anywhere,
#      disko phase)
#   3. prepares the persistent disk. It is formatted only when it holds
#      nothing at all. One that holds an ext4 filesystem is mounted as it is.
#   4. decrypts the host's SSH host keys and puts them on the persistent disk
#   5. builds and installs the system (nixos-anywhere, install phase)
#   6. reboots
set -euo pipefail

usage() {
  cat <<'END'
Usage: install-host --fleet <fleet-dir> [--flake <flake>]
                    [--build-on local|remote] <host> <address>

Installs <host> on the machine at <address>, which has to be booted into
the fleet's installer. The OS disk and the Docker disk are wiped.

  --fleet <fleet-dir>  Checkout of the repository that describes the fleet
  --flake <flake>      The flake to build from. Default: the flake this
                       command came from
  --build-on <where>   remote builds on the machine being installed, local
                       builds here and copies the result. Default: remote
  --help               Show this text

Reading the host's keys and the installer's key needs the deploy key or
the admin key, in SOPS_AGE_KEY or SOPS_AGE_KEY_FILE.
END
}

fail() {
  echo "install-host: $1" >&2
  exit 1
}

fleet_directory=
flake=$FLEET_DEFAULT_FLAKE
build_on=remote
positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help)
      usage
      exit 0
      ;;
    --fleet | --flake | --build-on)
      [[ $# -ge 2 ]] || fail "$1 needs a value"
      case "$1" in
        --fleet) fleet_directory=$2 ;;
        --flake) flake=$2 ;;
        --build-on) build_on=$2 ;;
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

[[ -d $fleet_directory ]] || fail "$fleet_directory is not a folder"
fleet_directory=$(realpath "$fleet_directory")
host_file=$fleet_directory/nixos/hosts/$host.json
[[ -f $host_file ]] || fail "the fleet has no nixos/hosts/$host.json"
host_keys=$fleet_directory/secrets/host-keys/$host.yaml
[[ -f $host_keys ]] || fail "the fleet has no secrets/host-keys/$host.yaml, make it with new-host-key"
installer_key=$fleet_directory/secrets/installer.yaml
[[ -f $installer_key ]] || fail "the fleet has no secrets/installer.yaml, make it with new-installer-key"

# git+file takes the files git tracks and nothing else, so an ignored or
# untracked file in the checkout never reaches the store.
if [[ -e $fleet_directory/.git ]]; then
  fleet_input="git+file://$fleet_directory"
else
  fleet_input="path:$fleet_directory"
fi

# A flake given as a folder is made absolute, since it is named below from
# inside another folder.
if [[ -d $flake ]]; then
  flake=$(realpath "$flake")
  if [[ -e $flake/.git ]]; then
    flake="git+file://$flake"
  else
    flake="path:$flake"
  fi
fi

# Both go into a generated flake.nix as Nix strings.
for value in "$flake" "$fleet_input"; do
  case $value in
    *\"* | *\\* | *\$\{*)
      fail "'$value' holds a character that cannot go into a Nix string"
      ;;
  esac
done

if ! jq -e '.features | has("docker")' "$host_file" >/dev/null 2>&1 \
  || ! has_persistent_disk=$(jq -r '.features.docker | tostring' "$host_file"); then
  fail "nixos/hosts/$host.json has no features.docker"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
chmod 0700 "$work"

# The keys are decrypted before anything is wiped, so a missing sops key
# stops the install while the machine is still untouched.
key_files=(
  ssh_host_ed25519_key
  ssh_host_ed25519_key.pub
  ssh_host_rsa_key
  ssh_host_rsa_key.pub
)
mkdir "$work/keys"
for key_file in "${key_files[@]}"; do
  if ! (umask 077 && sops decrypt --extract "[\"$key_file\"]" "$host_keys" >"$work/keys/$key_file" 2>/dev/null); then
    fail "cannot read $key_file from secrets/host-keys/$host.yaml, check SOPS_AGE_KEY or SOPS_AGE_KEY_FILE"
  fi
  [[ -s $work/keys/$key_file ]] || fail "$key_file in secrets/host-keys/$host.yaml is empty"
done

# The installer's host key is built into the ISO. Every connection made
# here accepts that key and no other, so the host's private keys go to the
# fleet's installer or nowhere.
#
# nixos-anywhere makes its own connections, which check no host key: it
# puts StrictHostKeyChecking=no first, and ssh keeps the first value it is
# given for an option. What it sends is the system and the disk layout,
# which hold no secret in the clear. It sets no ForwardAgent of its own,
# so the one given here is the first and holds: a machine that is not the
# installer does not get the agent.
if ! installer_public_key=$(sops decrypt --extract '["ssh_host_ed25519_key.pub"]' "$installer_key" 2>/dev/null); then
  fail "cannot read secrets/installer.yaml, check SOPS_AGE_KEY or SOPS_AGE_KEY_FILE"
fi
read -r key_type key_data _ <<<"$installer_public_key"
[[ $key_type == ssh-ed25519 && -n $key_data ]] || fail "secrets/installer.yaml holds no ed25519 public key"
echo "$address $key_type $key_data" >"$work/known_hosts"

ssh_options=(
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o ForwardAgent=no
  -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile="$work/known_hosts"
  -o GlobalKnownHostsFile=/dev/null
  -o HostKeyAlgorithms=ssh-ed25519
  -o CheckHostIP=no
  -o LogLevel=ERROR
)
on_target() {
  # shellcheck disable=SC2029 # every caller means its command for the target
  ssh "${ssh_options[@]}" "root@$address" "$@"
}

if ! on_target test -e /etc/fleet-installer </dev/null 2>/dev/null; then
  fail "the machine at $address is not booted into the fleet's installer, or its host key is not the installer's, so nothing was touched"
fi

# nixos-anywhere takes a flake and no input to override in it. So it is
# given a flake of two lines' worth, written here, which is the fleet's
# flake with the fleet input set to the checkout.
mkdir "$work/flake"
cat >"$work/flake/flake.nix" <<END
{
  inputs = {
    nixos-fleet.url = "$flake";
    nixos-fleet.inputs.fleet.follows = "fleet";
    fleet = {
      url = "$fleet_input";
      flake = false;
    };
  };
  outputs = { nixos-fleet, ... }: { inherit (nixos-fleet) nixosConfigurations; };
}
END

nixos_anywhere=(
  nixos-anywhere
  --flake "path:$work/flake#$host"
  --target-host "root@$address"
  --build-on "$build_on"
  --ssh-option ForwardAgent=no
)

if ! "${nixos_anywhere[@]}" --phases disko; then
  fail "partitioning the disks of $host failed"
fi

# disko has mounted the new root filesystem at /mnt. The persistent disk
# goes below it, where the installed system will find it.
#
# blkid exits with 2 when it finds no filesystem and no partition table.
# Only then is the disk formatted. Anything else it may hold is left alone.
if [[ $has_persistent_disk == true ]]; then
  if ! on_target sh -s <<'END'; then
set -eu
disk=/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi2
if [ ! -b "$disk" ]; then
  echo "there is no disk at $disk" >&2
  exit 1
fi
status=0
blkid -p "$disk" > /dev/null 2>&1 || status=$?
if [ "$status" -eq 2 ]; then
  mkfs.ext4 -q -L persist "$disk"
elif [ "$status" -ne 0 ]; then
  echo "blkid could not read $disk" >&2
  exit 1
fi
type=$(blkid -p -s TYPE -o value "$disk" || true)
if [ "$type" != ext4 ]; then
  echo "$disk holds something other than an ext4 filesystem, and was left as it is" >&2
  exit 1
fi
mkdir -p /mnt/srv/persist
mountpoint -q /mnt/srv/persist || mount "$disk" /mnt/srv/persist
mkdir -p /mnt/srv/persist/volumes /mnt/srv/persist/logs
END
    fail "preparing the persistent disk of $host failed"
  fi
fi

if ! on_target sh -s <<'END'; then
set -eu
mkdir -p /mnt/srv/persist/host
chmod 0755 /mnt/srv/persist/host
mkdir -p /mnt/srv/persist/host/ssh
chmod 0700 /mnt/srv/persist/host/ssh
END
  fail "making the folder for the host keys of $host failed"
fi

for key_file in "${key_files[@]}"; do
  case "$key_file" in
    *.pub) mode=0644 ;;
    *) mode=0600 ;;
  esac
  target=/mnt/srv/persist/host/ssh/$key_file
  # shellcheck disable=SC2029 # the path and the mode are meant to be filled in here
  if ! on_target "umask 077 && cat > '$target' && chmod $mode '$target'" <"$work/keys/$key_file"; then
    fail "putting $key_file on $host failed"
  fi
done

if ! "${nixos_anywhere[@]}" --phases install,reboot; then
  fail "installing $host failed"
fi

echo "install-host: $host is installed and is rebooting"
