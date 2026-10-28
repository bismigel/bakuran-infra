{
  # Single 256G SATA SSD, laid out like the other nodes:
  #   ESP (1G) + root (100G) + data (rest at /mnt/data)
  #
  # Root is capped at 100G on purpose, same as sitaw-amd/calamansi-intel: a
  # partition boundary is the only thing that stops container images, logs or a
  # runaway workload from eating the whole disk and taking etcd with it.
  #
  # ext4 on purpose, same as the other three nodes. Not btrfs: Longhorn wants
  # ext4/xfs for replica directories, etcd lives on this filesystem where
  # copy-on-write fragmentation shows up as fsync latency, and NixOS generations
  # already give the rollback story btrfs snapshots would be bought for.
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
              size = "100G";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
            data = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/mnt/data";
              };
            };
          };
        };
      };
    };
  };
}
