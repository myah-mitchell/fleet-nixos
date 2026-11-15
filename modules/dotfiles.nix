# The fleet-ansible run sets up the client account's dotfiles with dfutil,
# which downloads release builds of each tool into the account's home. Two
# things on the host let that work:
#
# - Python, because that part of the run is ordinary Ansible that logs in to
#   the host, where the rest of the run works from the control node.
# - nix-ld, because several of those builds (nvim, difft, mdcat, tree-sitter)
#   are linked against glibc and ask for /lib64/ld-linux-x86-64.so.2, which
#   NixOS does not have. nix-ld puts a loader there that finds the libraries
#   in its default set, which covers what they need.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  config = lib.mkIf config.fleet.features.dotfiles {
    programs.nix-ld.enable = true;
    environment.systemPackages = [ pkgs.python3 ];
  };
}
