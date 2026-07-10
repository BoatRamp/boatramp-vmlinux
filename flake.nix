{
  description = "Reproducible microVM kernel (vmlinux) for boatramp's embedded VMM.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f {
            inherit system;
            pkgs = import nixpkgs { inherit system; };
            lib = nixpkgs.lib;
          }
        );
    in
    {
      # `nix build .#vmlinux` → an uncompressed `vmlinux` ELF the boatramp embedded
      # VMM boots via `linux-loader` (`Elf::load`). virtio-mmio/blk/net + ext4 are
      # compiled IN (no modules, no initrd) to match the backend's `pci=off
      # root=/dev/vda` + virtio-MMIO cmdline. The base LTS is pinned deliberately
      # and bumped per release for kernel-CVE cadence, decoupled from the app.
      packages = forAllSystems (
        { pkgs, lib, ... }:
        rec {
          default = vmlinux;
          vmlinux =
            let
              micro = pkgs.linux_6_12.override {
                structuredExtraConfig = with lib.kernel; {
                  VIRTIO = yes;
                  VIRTIO_MMIO = yes;
                  VIRTIO_BLK = yes;
                  VIRTIO_NET = yes;
                  VIRTIO_PCI = yes;
                  VIRTIO_CONSOLE = yes;
                  EXT4_FS = yes;
                  SERIAL_8250 = yes;
                  SERIAL_8250_CONSOLE = yes;
                };
                ignoreConfigErrors = true;
              };
            in
            pkgs.runCommand "boatramp-vmlinux" { } ''
              mkdir -p "$out"
              if [ -f "${micro.dev}/vmlinux" ]; then
                cp "${micro.dev}/vmlinux" "$out/vmlinux"
              elif [ -f "${micro}/vmlinux" ]; then
                cp "${micro}/vmlinux" "$out/vmlinux"
              else
                echo "vmlinux ELF not found in kernel outputs — adjust the derivation" >&2
                find "${micro}" "${micro.dev}" \( -name 'vmlinux' -o -name 'bzImage' \) >&2 || true
                exit 1
              fi
            '';
        }
      );
    };
}
