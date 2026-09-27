#!/usr/bin/env bash
# Makes the SSH host key of the installer ISO, and stores it encrypted in
# the fleet.
#
# The installer is the one machine the fleet sends private keys to that has
# no keys of its own yet. With a host key made here and built into the ISO,
# install-host can check that it talks to the fleet's installer before it
# sends a host its keys.
#
# In order:
#   1. adds a rule for secrets/installer.yaml to .sops.yaml when none
#      matches it. The rule names the same keys as the rule for the hosts'
#      SSH host keys, and no host
#   2. makes an ed25519 key pair and stores it encrypted in
#      secrets/installer.yaml. A key that is already there is kept
#
# Running it a second time changes nothing.
set -euo pipefail

usage() {
  cat <<'END'
Usage: new-installer-key --fleet <fleet-dir>

Makes the SSH host key of the installer ISO and stores it encrypted in the
fleet checkout, in secrets/installer.yaml. build-installer builds the key
into the ISO, and install-host checks for it.

  --fleet <fleet-dir>  Checkout of the repository that describes the fleet
  --help               Show this text

Needs the admin key or the deploy key, in SOPS_AGE_KEY or SOPS_AGE_KEY_FILE.
Commit what changed in the checkout afterwards, and build the ISO again.
END
}

fail() {
  echo "new-installer-key: $1" >&2
  exit 1
}

fleet_directory=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help)
      usage
      exit 0
      ;;
    --fleet)
      [[ $# -ge 2 ]] || fail "--fleet needs a value"
      fleet_directory=$2
      shift 2
      ;;
    *)
      fail "unknown argument $1, see --help"
      ;;
  esac
done
[[ -n $fleet_directory ]] || fail "--fleet <fleet-dir> is required, see --help"

[[ -d $fleet_directory ]] || fail "$fleet_directory is not a folder"
cd "$fleet_directory"
rules=.sops.yaml
[[ -f $rules ]] || fail "$fleet_directory has no .sops.yaml"

installer_key=secrets/installer.yaml

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
chmod 0700 "$work"
export work

# Prints the index of the first rule in .sops.yaml whose path_regex matches
# the path, which is the rule sops itself would use. Prints null when no
# rule matches.
rule_for() {
  # shellcheck disable=SC2016 # $regex is a variable of yq, not of the shell
  path=$1 yq '
    .creation_rules
    | to_entries
    | map(select(.value.path_regex != null))
    | map(select(.value.path_regex as $regex | strenv(path) | test($regex)))
    | .[0].key
  ' "$rules"
}

if [[ -f $installer_key ]]; then
  if ! sops --config "$rules" decrypt --extract '["ssh_host_ed25519_key"]' "$installer_key" >/dev/null 2>&1; then
    fail "cannot decrypt the $installer_key that is already there, check SOPS_AGE_KEY or SOPS_AGE_KEY_FILE"
  fi
  echo "new-installer-key: kept the key in $installer_key"
  exit 0
fi

# 1. The rule. It goes right before the rule for the host keys and names
# the same keys, which are the people and the deploy key. sops reads the
# rules only from a file beside the checkout, so .sops.yaml is changed in
# place and put back if the key cannot be encrypted.
cp "$rules" "$work/sops.yaml.orig"
if [[ $(rule_for "$installer_key") == null ]]; then
  keys_rule=$(rule_for secrets/host-keys/installer.yaml)
  [[ $keys_rule != null ]] || fail "no rule in .sops.yaml matches secrets/host-keys/, run new-host-key first"
  # shellcheck disable=SC2016 # $people is a variable of yq, not of the shell
  keys_rule=$keys_rule regex='^secrets/installer\.yaml$' yq -i '
    .creation_rules[env(keys_rule)].key_groups[0].age as $people
    | .creation_rules = .creation_rules[:env(keys_rule)]
      + [{"path_regex": strenv(regex), "key_groups": [{"age": $people}]}]
      + .creation_rules[env(keys_rule):]
  ' "$rules"
  echo "new-installer-key: added a rule for $installer_key to .sops.yaml"
fi

# 2. The key.
ssh-keygen -q -t ed25519 -N "" -C "root@installer" -f "$work/ssh_host_ed25519_key"
(
  umask 077
  yq --null-input '
    .ssh_host_ed25519_key = load_str(strenv(work) + "/ssh_host_ed25519_key")
    | .["ssh_host_ed25519_key.pub"] = load_str(strenv(work) + "/ssh_host_ed25519_key.pub")
  ' >"$work/key.yaml"
)
if ! sops --config "$rules" encrypt --filename-override "$installer_key" "$work/key.yaml" >"$work/key.encrypted.yaml"; then
  cat "$work/sops.yaml.orig" >"$rules"
  fail "sops could not encrypt the key for $installer_key, .sops.yaml is as it was"
fi
mkdir -p secrets
mv "$work/key.encrypted.yaml" "$installer_key"
chmod 0644 "$installer_key"
echo "new-installer-key: made $installer_key"
