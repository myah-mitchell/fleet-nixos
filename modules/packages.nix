# The tools an admin expects to find on any host.
{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    git
    htop
    iftop
    iotop
    mtr
    multitail
    ncdu
    rsync
    sysstat
    unzip
    vim
  ];

  programs.zsh.enable = true;
  environment.variables.EDITOR = "vim";
}
