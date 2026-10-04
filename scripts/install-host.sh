#!/usr/bin/env bash
# Installs NixOS on a machine that is booted into the fleet's installer.
#
# In order:
#   1. reads the installer's SSH host key from the VM's guest agent, through
#      the Proxmox host, and checks that the machine at the address is the
#      installer and answers with that key
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
Usage: install-host --fleet <fleet-dir> --proxmox <user@address>
                    --proxmox-host-key <key> --vmid <vmid>
                    [--flake <flake>] [--build-on local|remote]
                    <host> <address>

Installs <host> on the machine at <address>, which has to be booted into
the fleet's installer. The OS disk and the Docker disk are wiped.

  --fleet <fleet-dir>  Checkout of the repository that describes the fleet
  --proxmox <user@address>
                       Login on the Proxmox node that runs the VM. The
                       account needs sudo without a password, for qm
  --proxmox-host-key <key>
                       The node's SSH host key, as "ssh-ed25519 AAAA...".
                       No other key is accepted from the node
  --vmid <vmid>        The VM's ID on that node
  --flake <flake>      The flake to build from. Default: the flake this
                       command came from
  --build-on <where>   remote builds on the machine being installed, local
                       builds here and copies the result. Default: remote
  --help               Show this text

Reading the host's keys needs the deploy key or the admin key, in
SOPS_AGE_KEY or SOPS_AGE_KEY_FILE.
END
}

fail() {
  echo "install-host: $1" >&2
  exit 1
}

fleet_directory=
proxmox=
proxmox_host_key=
vmid=
flake=$FLEET_DEFAULT_FLAKE
build_on=remote
positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help)
      usage
      exit 0
      ;;
    --fleet | --proxmox | --proxmox-host-key | --vmid | --flake | --build-on)
      [[ $# -ge 2 ]] || fail "$1 needs a value"
      case "$1" in
        --fleet) fleet_directory=$2 ;;
        --proxmox) proxmox=$2 ;;
        --proxmox-host-key) proxmox_host_key=$2 ;;
        --vmid) vmid=$2 ;;
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
[[ -n $proxmox ]] || fail "--proxmox <user@address> is required, see --help"
[[ -n $proxmox_host_key ]] || fail "--proxmox-host-key <key> is required, see --help"
[[ -n $vmid ]] || fail "--vmid <vmid> is required, see --help"
[[ ${#positional[@]} -eq 2 ]] || fail "expected a host and an address, see --help"
host=${positional[0]}
address=${positional[1]}
[[ $host =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || fail "'$host' is not a host name: letters, digits, - and _ only"
[[ $address =~ ^[A-Za-z0-9][A-Za-z0-9.:-]*$ ]] || fail "'$address' is not an address"
[[ $proxmox =~ ^[a-z_][a-z0-9_-]*@[A-Za-z0-9][A-Za-z0-9.:-]*$ ]] || fail "'$proxmox' is not a login, give it as user@address"
[[ $vmid =~ ^[1-9][0-9]*$ ]] || fail "'$vmid' is not a VMID"
read -r proxmox_key_type proxmox_key_data _ <<<"$proxmox_host_key"
[[ $proxmox_key_type == ssh-* && $proxmox_key_data =~ ^[A-Za-z0-9+/]+=*$ ]] \
  || fail "--proxmox-host-key is not an SSH public key, give it as \"ssh-ed25519 AAAA...\""

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

# The installer makes a new SSH host key at every boot. Its public half is
# read here through Proxmox: the node runs ssh-keygen in the VM, through the
# VM's guest agent, which talks to the VM over a virtual serial port and not
# over the network. A machine that takes the address answers for the
# address, not for the VMID, so it cannot answer here.
#
# The node itself is checked against the host key given on the command line,
# on a connection of its own, and the VMID against the address: the VM's
# cloud-init settings have to give it this address.
proxmox_address=${proxmox#*@}
echo "$proxmox_address $proxmox_key_type $proxmox_key_data" >"$work/proxmox_known_hosts"
proxmox_ssh_options=(
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o ControlMaster=no
  -o ControlPath=none
  -o ForwardAgent=no
  -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile="$work/proxmox_known_hosts"
  -o GlobalKnownHostsFile=/dev/null
  -o HostKeyAlgorithms="$proxmox_key_type"
  -o CheckHostIP=no
  -o LogLevel=ERROR
)
on_proxmox() {
  # shellcheck disable=SC2029 # every caller means its command for the node
  ssh "${proxmox_ssh_options[@]}" "$proxmox" "$@" </dev/null
}

if ! vm_config=$(on_proxmox sudo -n qm config "$vmid"); then
  fail "cannot read the settings of VM $vmid through $proxmox: check the login, that its host key is the one given, and that the account may run sudo qm without a password"
fi
if ! grep -Eq "^ipconfig0: (.*,)?ip=${address//./\\.}/" <<<"$vm_config"; then
  fail "VM $vmid on $proxmox_address does not have the address $address in its cloud-init settings, so it is not the machine to install"
fi

# The guest agent starts with the installer, and sshd's key is made shortly
# before sshd starts, so the first tries may find neither.
installer_public_key=
for _ in $(seq 1 30); do
  if result=$(on_proxmox sudo -n qm guest exec "$vmid" --timeout 20 -- \
    /run/current-system/sw/bin/ssh-keygen -y -f /etc/ssh/ssh_host_ed25519_key 2>/dev/null) \
    && installer_public_key=$(jq -er 'select(.exitcode == 0) | ."out-data"' <<<"$result" 2>/dev/null); then
    break
  fi
  installer_public_key=
  sleep 10
done
[[ -n $installer_public_key ]] || fail "could not read the installer's host key from the guest agent of VM $vmid, so nothing was touched. Check in Proxmox that the VM is booted into the installer"
read -r key_type key_data _ <<<"$installer_public_key"
[[ $key_type == ssh-ed25519 && $key_data =~ ^[A-Za-z0-9+/]+=*$ ]] || fail "VM $vmid answered with no ed25519 public key"
echo "$address $key_type $key_data" >"$work/known_hosts"

# Every connection made here accepts that key and no other, so the host's
# private keys go to the installer in VM $vmid or nowhere. None of them
# shares a connection that ControlMaster in an ssh configuration left open,
# such as one host-state made, since that one's host key was never checked.
ssh_options=(
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o ControlMaster=no
  -o ControlPath=none
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
  fail "the machine at $address is not booted into the fleet's installer, or its host key is not the one VM $vmid has, so nothing was touched"
fi

# nixos-anywhere takes a flake and no input to override in it. So it is
# given a flake of two lines' worth, written here, which is the fleet's
# flake with the fleet input set to the checkout.
mkdir "$work/flake"
cat >"$work/flake/flake.nix" <<END
{
  inputs = {
    fleet-nixos.url = "$flake";
    fleet-nixos.inputs.fleet.follows = "fleet";
    fleet = {
      url = "$fleet_input";
      flake = false;
    };
  };
  outputs = { fleet-nixos, ... }: { inherit (fleet-nixos) nixosConfigurations; };
}
END

# nixos-anywhere makes its own connections, and gives each of them
# StrictHostKeyChecking=no and UserKnownHostsFile=/dev/null. It runs ssh,
# and nix and ssh-copy-id run it for it, by name from PATH, and it puts no
# ssh of its own ahead of the PATH it is started with. So it is started
# with an ssh first on PATH that puts the options above ahead of its
# own, and ssh keeps the first value it is given for an option. Each of
# its connections then accepts the installer's key and no other, and gets
# no agent.
real_ssh=$(command -v ssh)
mkdir "$work/bin"
{
  printf '#!%s\n' "$BASH"
  printf 'exec %q' "$real_ssh"
  printf ' %q' "${ssh_options[@]}"
  printf ' "$@"\n'
} >"$work/bin/ssh"
chmod +x "$work/bin/ssh"

nixos_anywhere=(
  env "PATH=$work/bin:$PATH"
  nixos-anywhere
  --flake "path:$work/flake#$host"
  --target-host "root@$address"
  --build-on "$build_on"
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
