# boatramp-vmlinux

Reproducible, signed **microVM kernel** (`vmlinux`) for [boatramp](https://github.com/BoatRamp/BoatRamp)'s
embedded VMM. Kept in its own repo so the kernel is patched on its **own
CVE cadence**, independent of boatramp app releases.

## What it is

An **uncompressed `vmlinux` ELF** the boatramp embedded VMM boots via
`linux-loader` (`Elf::load`). Built from a pinned LTS Linux with a **microVM
config**: `virtio-mmio`, `virtio-blk`, `virtio-net`, and `ext4` compiled **in**
(no modules, no initrd), matching the backend's `pci=off root=/dev/vda` +
virtio-MMIO boot cmdline.

## Build

```sh
nix build .#vmlinux
file result/vmlinux    # ELF 64-bit … x86-64
```

The base LTS is pinned in `flake.nix` and bumped deliberately per release.

## Trust model

boatramp verifies a selected kernel **before boot**, scaled by the operator's
security posture:

- **Always:** the kernel bytes must hash to the pinned `sha256` (verify-before-boot).
- **Multi-tenant (strict):** the hash must be on the operator's static allow-list
  **and** carry a signature verifying against a static signing key. Releases here
  are signed by the boatramp kernel-signing key; its **public** half ships as a
  built-in default in boatramp, so the batteries-included default kernel is
  *verified*, not trust-on-first-use.
- **Single-tenant / dev:** a verified hash pin suffices.

## CI

- **`build`** — validates the kernel compiles (this repo).
- **Boot validation** lives in the main boatramp repo, which references this flake
  and boots a guest with the embedded VMM on a KVM runner.
- **`release`** *(wip)* — on a `v*` tag: build, sign the kernel hash with the
  Actions-Secret signing key, and publish `boatramp-vmlinux-<arch>` + `.sig` +
  `.sha256` as GitHub Release assets. boatramp's default `compute.default_kernel`
  points at the latest release.
