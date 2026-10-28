{
  # Single 256G SATA SSD: ESP (1G) + ext4 root (rest).
  #
  # ext4 on purpose, same as the other three nodes. Not btrfs: Longhorn wants
  # ext4/xfs for replica directories, and etcd sits on this filesystem too, where
  # copy-on-write fragmentation shows up as fsync latency. NixOS generations
  # already give us the rollback story btrfs snapshots would be bought for.
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = "/dev/sda";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };
    };
  };
}
