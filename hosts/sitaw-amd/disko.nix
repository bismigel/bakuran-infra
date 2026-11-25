# disko manages the OS DISK ONLY (2026-11-24).
#
# It used to declare a data disk for the media library. That entry named `/dev/sda`, and at install
# time the kernel had enumerated the 1.8 TB TOSHIBA as `sda`, so the installer formatted the library
# instead of the 465 GB staging disk. The bytes are unrecoverable: the btrfs chunk-tree root sat in
# the first 128 MB the new metadata overwrote.
#
# A data disk is not part of an OS install. It is mounted by `fileSystems` in default.nix, by
# `/dev/disk/by-id` path, and never formatted by anything in this repository.
# STABLE DEVICE NAMES ARE MANDATORY HERE (2026-11-24).
#
# This file used to name `/dev/nvme0n1` and `/dev/sda`. Device letters are not stable across a
# reboot or a reinstall, and on 2026-11-24 the letters landed differently at install time than
# afterwards: `/dev/sda` was the 1.8 TB TOSHIBA media library, so `nixos-anywhere` (which runs
# disko) reformatted the library instead of the 465 GB staging disk. The library's btrfs
# subvolumes - media, books, audiobooks, snapshots - were destroyed. Books and audiobooks were
# recoverable from R2; the media library was not backed up and is gone.
#
# A device letter is a race. A `/dev/disk/by-id` path is a promise: it names the hardware, so a
# reinstall either writes the disk you meant or fails to find it. Every host's disko.nix should
# use by-id paths for this reason - sitaw is converted; the others are still letters and carry the
# same hazard.
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
