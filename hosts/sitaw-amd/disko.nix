{
  # Wipe BOTH disks on sitaw-amd:
  #   /dev/nvme0n1 — ESP (1G) + root (100G) + data (rest) at /mnt/media-nvme
  #   /dev/sda     — single ext4 at /mnt/media-sda  (the old NTFS "HDD" is wiped)
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
                mountpoint = "/mnt/media-nvme";
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
                mountpoint = "/mnt/media-sda";
              };
            };
          };
        };
      };
    };
  };
}
