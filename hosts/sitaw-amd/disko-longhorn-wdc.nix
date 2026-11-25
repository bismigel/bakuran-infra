# Step 2 of 2: hand the 465 GB WDC to Longhorn.
#
# NOT imported by the host, and deliberately a separate file so it cannot run in the same breath as
# step 1: at the moment disko-media.nix runs, this disk still holds the media library. The order is
# media -> verify the copy -> this.
#
# The drive is a 2011 desktop disk with 42 306 power-on hours (SMART PASSED, 0 reallocated). As a
# replica store a failure costs one copy of a volume; as a media library a failure costs the library.
# That is the whole argument for the swap.
#
#   sudo nix run github:nix-community/disko -- --mode destroy,format,mount \
#     /path/to/hosts/sitaw-amd/disko-longhorn-wdc.nix
{
  disko.devices.disk.wdc = {
    device = "/dev/disk/by-id/ata-WDC_WD5000AAKX-60U6AA0_WD-WCC2E5ZV3FFF";
    type = "disk";
    content = {
      type = "gpt";
      partitions.longhorn = {
        size = "100%";
        content = {
          type = "filesystem";
          format = "ext4";
          mountpoint = "/mnt/longhorn-wdc";
          mountOptions = [ "noatime" ];
        };
      };
    };
  };
}
