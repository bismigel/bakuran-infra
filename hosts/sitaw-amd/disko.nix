# disko manages the OS DISK ONLY (2026-11-24).
#
# It used to declare two disks: the NVMe (ESP + root + scratch) and a data disk for the media
# library. That data entry is what destroyed the library: it named `/dev/sda`, and at install time
# the kernel had enumerated the 1.8 TB TOSHIBA as `sda`, so the installer formatted the library
# instead of the 465 GB staging disk. The bytes are unrecoverable - the btrfs chunk-tree root sat in
# the first 128 MB that the new filesystem's metadata overwrote.
#
# A data disk is not part of an OS install. It is mounted by `fileSystems` in default.nix, by
# `/dev/disk/by-id` path, and never formatted by anything in this repository. If a data disk ever
# needs formatting, that is a deliberate, separate, backed-up decision - not a side effect of
# reinstalling a host.
{
  # Wipe BOTH disks on sitaw-amd:
  #   /dev/nvme0n1 — ESP (1G) + root (100G) + data (rest) at /mnt/media-nvme
  #   /dev/sda     — single ext4 at /mnt/media-sda  (the old NTFS "HDD" is wiped)
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = "/dev/disk/by-id/nvme-KLEVV_CRAS_C700_RGB_M.2_NVMe_SSD_480GB_E201912030050056";
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
    };
  };
}
