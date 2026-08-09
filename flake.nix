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
              # aarch64: Virtualization.framework presents its virtio devices to the
              # guest over a generic **PCIe host bridge (ECAM)**, not the cmdline
              # virtio-mmio the Firecracker config targets — so the stock config
              # (CONFIG_PCI off) finds no devices and never boots. Enable the generic
              # PCIe host + virtio-pci so VZ's disk/net/console are discovered.
              # (virtio-mmio stays on too, harmlessly.)
              config =
                if isArm then
                  pkgs.runCommand "boatramp-vmlinux.config" { } ''
                    grep -vE '^(# )?CONFIG_(PCI|PCI_HOST_GENERIC|PCI_HOST_COMMON|PCI_ECAM|VIRTIO_PCI)( is not set|=)' \
                      ${fcConfig} > "$out"
                    {
                      echo CONFIG_PCI=y
                      echo CONFIG_PCI_HOST_COMMON=y
                      echo CONFIG_PCI_HOST_GENERIC=y
                      echo CONFIG_PCI_ECAM=y
                      echo CONFIG_VIRTIO_PCI=y
                    } >> "$out"
                  ''
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
                # nixpkgs marks kernels `requiredSystemFeatures = ["big-parallel"]`,
                # which the stock nix-darwin linux-builder doesn't advertise; this
                # minimal kernel builds fine without it and the hint doesn't affect
                # the output bytes, so drop it (native CI runners are unaffected).
                # MUST match the main boatramp flake's `#vmlinux` so both are byte-
                # identical.
                requiredSystemFeatures = [ ];
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
