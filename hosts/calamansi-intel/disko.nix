{
  # Wipe BOTH disks on calamansi-intel:
  #   /dev/nvme0n1 — ESP (1G) + root (100G) + data (rest) at /mnt/scratch
  #   /dev/sda     — single ext4 at /mnt/longhorn
  #
  # Both were media branches of the mergerfs union until 2026-11-02. After the
  # cutover the library is served from .82 over NFS, so these partitions were
  # repurposed (STORAGE-PLAN.md section 4c):
  #   nvme -> /mnt/scratch   incomplete downloads and transcode temp, off the root fs
  #   sda  -> /mnt/longhorn  a dedicated Longhorn disk (~230G), which is what lets the
  #                          four volumes stuck at 2 replicas take a third copy
  # by mergerfs (see hosts/calamansi-intel/default.nix).
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = "/dev/nvme0n1";
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
                mountpoint = "/mnt/scratch";
              };
            };
          };
        };
      };
      hdd = {
        type = "disk";
        device = "/dev/sda";
        content = {
          type = "gpt";
          partitions = {
            data = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/mnt/longhorn";
              };
            };
          };
        };
      };
    };
  };
}
