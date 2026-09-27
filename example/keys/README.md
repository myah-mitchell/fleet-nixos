# Example keys

The private keys of the example fleet. They are public test keys that protect nothing: anyone who has this repository has them. They exist so that the sops files of the example are really encrypted and the flake's checks can read them.

> [!WARNING]
> Never add one of these keys to a real fleet's `.sops.yaml`, and never put one of the host keys on a real host.

| File | What it is |
| --- | --- |
| `age-admin.txt` | age key that stands for a person. Named `admin` in `.sops.yaml` |
| `age-deploy.txt` | age key that stands for what runs the commands. Named `deploy` in `.sops.yaml` |
| `ex01-ssh_host_ed25519_key`, `ex01-ssh_host_rsa_key` | SSH host keys of ex01, with their `.pub` halves |
| `ex02-ssh_host_ed25519_key`, `ex02-ssh_host_rsa_key` | SSH host keys of ex02, with their `.pub` halves |
| `installer/ssh_host_ed25519_key` | SSH host key of the example's installer ISO, with its `.pub` half. The flake's `installer-key` input points at this folder |

The host keys are copies of what `secrets/host-keys/` holds in encrypted form. The age key of a host follows from its ed25519 key:

```bash
nix shell nixpkgs#ssh-to-age -c ssh-to-age -i ex01-ssh_host_ed25519_key.pub
```

The output is the key named `ex01` in `.sops.yaml`.
