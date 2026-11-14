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
      # cmdline. Pinned to 6.12 LTS: firecracker ships no 6.12 config and its only
      # >=6.10 one (6.18) turns CONFIG_MODULES back on, so we keep firecracker's
      # no-modules 6.1 microVM config as the device-shape template, let the 6.12
      # kernel's own olddefconfig reconcile it, and enable Landlock on top (ABI 6,
      # >= V5 -- the floor the privsep in-guest sandbox needs; the compute-plane
      # microVM is unaffected). Bumped per release for CVE cadence. MUST stay byte-
      # identical to the main boatramp flake's `#vmlinux` (same nixpkgs pin + config)
      # so the release == the boot-tested kernel.
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
              # Firecracker's published minimal microVM guest config, per arch. This is
              # the firecracker 6.1-series config used as the microVM device-shape
              # template (no-modules; virtio-mmio/blk/net + ext4 + 8250 in); the kernel
              # it is applied to is 6.12 LTS (see above), reconciled by the kernel's own
              # olddefconfig and with Landlock enabled below. (Firecracker ships no 6.12
              # config, and its 6.18 one re-enables modules.)
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
              # The privsep in-guest sandbox requires a **Landlock-V5 floor** (ABI ≥ 5,
              # i.e. a ≥ 6.10 kernel) — this is why the kernel is pinned to 6.12 LTS,
              # whose Landlock is ABI 6. The firecracker microVM config ships Landlock
              # **off**, so enable it here so ONE kernel serves BOTH the compute-plane
              # microVM and the privsep VM substrate (not a privsep-only variant). The
              # ABI follows the kernel version, not a config knob; this just compiles
              # the LSM in (`CONFIG_SECURITY_LANDLOCK=y`) and puts `landlock` in the
              # active LSM list so it initialises at boot — its deps (CONFIG_SECURITY,
              # CONFIG_SECURITYFS) are already `=y` in the firecracker config. The LSM
              # order mirrors firecracker's own Landlock-enabled (6.18) config. Additive,
              # arch-independent; MUST match the main boatramp flake's `#vmlinux` byte-
              # for-byte. (`CONFIG_LSM_*` sub-options are left untouched: the pattern
              # only strips a bare `CONFIG_LSM=`/`CONFIG_SECURITY_LANDLOCK` line.)
              baseConfig = pkgs.runCommand "boatramp-vmlinux.config.landlock" { } ''
                grep -vE '^(# )?CONFIG_(SECURITY_LANDLOCK|LSM)( is not set|=)' ${fcConfig} > "$out"
                {
                  echo CONFIG_SECURITY_LANDLOCK=y
                  echo 'CONFIG_LSM="landlock,lockdown,yama,loadpin,safesetid,integrity,selinux,smack,tomoyo,apparmor,bpf"'
                } >> "$out"
              '';
              config =
                if isArm then
                  pkgs.runCommand "boatramp-vmlinux.config" { } ''
                    grep -vE '^(# )?CONFIG_(PCI|PCI_HOST_GENERIC|PCI_HOST_COMMON|PCI_ECAM|VIRTIO_PCI)( is not set|=)' \
                      ${baseConfig} > "$out"
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
                      ${baseConfig} > "$out"
                  '';
              # x86_64: the embedded VMM boots the uncompressed `vmlinux` ELF (via
              # linux-loader's `Elf::load`). aarch64: VZLinuxBootLoader boots the raw
              # arm64 `Image` (arch/arm64/boot/Image). nixpkgs only keeps `vmlinux` for
              # MODULAR kernels; CONFIG_MODULES is off here, so copy the kernel image
              # out of the exported build dir (`$buildRoot`) ourselves.
              kernelRel = if isArm then "arch/arm64/boot/Image" else "vmlinux";
              kernelName = baseNameOf kernelRel;
              micro = (pkgs.linuxManualConfig {
                inherit (pkgs.linux_6_12) version src;
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
