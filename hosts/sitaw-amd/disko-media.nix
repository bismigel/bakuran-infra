# Step 1 of 2: split the 1.8 TB TOSHIBA into media (1 TB) + Longhorn (the rest).
#
# NOT imported by the host. `disko.nix` is what `nixos-anywhere` runs, and it declares the OS disk
# only - an installer must never format a data disk. (A device letter once made one format the
# 1.8 TB library; the btrfs chunk-tree root was inside the first 128 MB the new filesystem wrote, so
# it was unrecoverable.) This file is the same declaration, applied on purpose:
#
#   sudo nix run github:nix-community/disko -- --mode destroy,format,mount \
#     /path/to/hosts/sitaw-amd/disko-media.nix
#
# Run this BEFORE disko-longhorn-wdc.nix: the WDC still holds the media at this point, and step 2
# wipes it. The copy between the two steps is `rsync` and it is verified by file count.
{
  disko.devices.disk.toshiba = {
    # Hardware id, never a device letter. 1.8 TB TOSHIBA MG04ACA200NY.
    # SMART 2026-11-25: PASSED, 0 reallocated, 0 pending, 5 216 power-on hours.
    device = "/dev/disk/by-id/ata-TOSHIBA_MG04ACA200NY_18F1Y0C8F7EE";
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        # 1000 GiB rather than "everything": media shares this disk with a replica store, and a
        # library that may grow without limit is a library that eventually fills the disk a rebuild
        # needs.
        media = {
          size = "1000G";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/mnt/media";
            mountOptions = [ "noatime" ];
          };
        };
        longhorn = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/mnt/longhorn";
            mountOptions = [ "noatime" ];
          };
        };
      };
    };
  };
}
