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
        { pkgs, lib, system }:
        rec {
          default = vmlinux;
          vmlinux =
            let
              # The guest arch is the build system's arch: x86_64-linux → an x86_64
              # kernel (the KVM embedded VMM); aarch64-linux → an arm64 kernel (the
              # macOS Virtualization.framework `vmm-vz` backend).
              isArm = system == "aarch64-linux";
              fcArch = if isArm then "aarch64" else "x86_64";
              # Firecracker's published minimal microVM guest config, per arch.
              fcConfig = pkgs.fetchurl {
                url = "https://raw.githubusercontent.com/firecracker-microvm/firecracker/v1.10.1/resources/guest_configs/microvm-kernel-ci-${fcArch}-6.1.config";
                hash =
                  if isArm then
                    "sha256-yPuMNxRCeCh6aty1F8/TNZ9tsAhhgTcQCqenZxa9BmI="
                  else
                    "sha256-OR2NSY+J5Ws5G+XqSnUB68RObQlDMeyqve/tHaayipY=";
              };
              # x86_64: the boatramp in-process embedded rust-vmm VMM advertises its
              # virtio-MMIO devices via the `virtio_mmio.device=<size>@<addr>:<irq>`
              # kernel cmdline; the stock config ships CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES
              # off (its binary backend discovers over ACPI), so without this the guest
              # never sees `/dev/vda`. Enable it (additive). MUST match the main
              # boatramp flake's `#vmlinux` patch byte-for-byte.
              # aarch64: Virtualization.framework presents its virtio devices via the
              # guest **device tree** it generates, so no cmdline-devices patch is
              # needed (VIRTIO_MMIO + virtio-blk/net/console + ext4 are already =y);
              # the config is used verbatim.
              config =
                if isArm then
                  fcConfig
                else
                  pkgs.runCommand "boatramp-vmlinux.config" { } ''
                    sed 's/# CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES is not set/CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES=y/' \
                      ${fcConfig} > "$out"
                  '';
              # x86_64: the embedded VMM boots the uncompressed `vmlinux` ELF (via
              # linux-loader's `Elf::load`). aarch64: VZLinuxBootLoader boots the raw
              # arm64 `Image` (arch/arm64/boot/Image). nixpkgs only keeps `vmlinux` for
              # MODULAR kernels; CONFIG_MODULES is off here, so copy the kernel image
              # out of the exported build dir (`$buildRoot`) ourselves.
              kernelRel = if isArm then "arch/arm64/boot/Image" else "vmlinux";
              kernelName = baseNameOf kernelRel;
              micro = (pkgs.linuxManualConfig {
                inherit (pkgs.linux_6_1) version src;
                configfile = config;
                allowImportFromDerivation = true;
              }).overrideAttrs (old: {
                postInstall = (old.postInstall or "") + ''
                  cp "$buildRoot/${kernelRel}" "$out/${kernelName}"
                '';
              });
            in
            # `micro.dev or micro`: linuxManualConfig may not expose a `dev` output;
            # fall back to the default output and locate the kernel image. The output
            # is always named `vmlinux` (the release's generic "kernel" artifact);
            # for aarch64 it is a raw arm64 Image, for x86_64 an uncompressed ELF.
            pkgs.runCommand "boatramp-vmlinux" { } ''
              mkdir -p "$out"
              v="$(find ${micro} ${micro.dev or micro} -name ${kernelName} -type f 2>/dev/null | head -1)"
              if [ -z "$v" ]; then
                echo "kernel image (${kernelName}) not found in kernel outputs:" >&2
                find ${micro} ${micro.dev or micro} -maxdepth 2 >&2 || true
                exit 1
              fi
              cp "$v" "$out/vmlinux"
            '';
        }
      );
    };
}
