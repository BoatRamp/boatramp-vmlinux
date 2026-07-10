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
      # VMM boots via `linux-loader` (`Elf::load`). Built from **Firecracker's own
      # microVM kernel config** (pinned): minimal, **no modules, no debug_info** (so
      # the vmlinux is a few MB, not ~380), virtio-mmio/blk/net + ext4 + 8250 console
      # compiled IN — matching the backend's `pci=off root=/dev/vda` + virtio-MMIO
      # cmdline. Base LTS 6.1 matches the config; bumped per release for CVE cadence.
      # MUST stay byte-identical to the main boatramp flake's `#vmlinux` (same
      # nixpkgs pin + config) so the release == the boot-tested kernel.
      packages = forAllSystems (
        { pkgs, lib, ... }:
        rec {
          default = vmlinux;
          vmlinux =
            let
              fcConfig = pkgs.fetchurl {
                url = "https://raw.githubusercontent.com/firecracker-microvm/firecracker/v1.10.1/resources/guest_configs/microvm-kernel-ci-x86_64-6.1.config";
                hash = "sha256-OR2NSY+J5Ws5G+XqSnUB68RObQlDMeyqve/tHaayipY=";
              };
              # nixpkgs only keeps `vmlinux` for MODULAR kernels; this one has
              # CONFIG_MODULES off, so copy the uncompressed ELF into $out ourselves
              # (fixupPhase strips it — still Elf::load-able). `$buildRoot` is the
              # exported out-of-tree build dir.
              micro = (pkgs.linuxManualConfig {
                inherit (pkgs.linux_6_1) version src;
                configfile = fcConfig;
                allowImportFromDerivation = true;
              }).overrideAttrs (old: {
                postInstall = (old.postInstall or "") + ''
                  cp "$buildRoot/vmlinux" "$out/vmlinux"
                '';
              });
            in
            # `micro.dev or micro`: linuxManualConfig may not expose a `dev`
            # output; fall back to the default output and locate the vmlinux ELF.
            pkgs.runCommand "boatramp-vmlinux" { } ''
              mkdir -p "$out"
              v="$(find ${micro} ${micro.dev or micro} -name vmlinux -type f 2>/dev/null | head -1)"
              if [ -z "$v" ]; then
                echo "vmlinux ELF not found in kernel outputs:" >&2
                find ${micro} ${micro.dev or micro} -maxdepth 2 >&2 || true
                exit 1
              fi
              cp "$v" "$out/vmlinux"
            '';
        }
      );
    };
}
