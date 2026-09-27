# A swap file on the OS disk, made at boot when it does not exist. Swap is a
# last resort here: the kernel is told to avoid it while memory is free.
{ config, lib, ... }:
{
  swapDevices = lib.optional (config.fleet.swapMiB > 0) {
    device = "/swapfile";
    size = config.fleet.swapMiB;
  };

  boot.kernel.sysctl."vm.swappiness" = 1;
}
