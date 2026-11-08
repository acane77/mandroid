# KernelSU settings

KernelSU support is experimental and off by default. Settings ▸ KernelSU provides:

- **Boot with KernelSU**: select rooted or stock mode for the next boot.
- **Prepare Patched Image**: download verified tools and create a patched copy
  ahead of time, with progress, cancellation, and errors displayed in Settings.
- **Restart to Apply**: restart using the selected mode. Enabling KernelSU also
  prepares the image automatically if needed.

The supported image is Google Play Android 36.1 ARM64 revision 4, with kernel
`6.12.38-android16-5-gbb9513914902-ab13996879-4k`. Updated or different kernels
are rejected until tested. Disable KernelSU to boot an unsupported image.

The implementation uses official [KernelSU v3.3.0 assets](https://github.com/tiann/KernelSU/releases/tag/v3.3.0)
with pinned SHA-256 hashes. Downloads come from GitHub, independently of the
Google SDK mirror setting. KernelSU source and licensing are available in the
[upstream repository](https://github.com/tiann/KernelSU).

Patches live under `boot-patches/kernelsu` in Mandroid's data folder. The stock
SDK image remains unchanged. Rooted boots bypass snapshot loading and saving.
Shutdown flushes guest filesystem writes before stopping the emulator.
Disabling KernelSU and restarting returns to the stock ramdisk, preserves
installed apps and data, and leaves Manager installed but inactive.

On rooted startup Mandroid verifies that the KernelSU kernel module is active,
installs the official Manager if absent, and opens it on the device screen.
Open KernelSU Manager from the app library to manage root grants and modules.
ADB shell is not automatically granted root. Root support does not change
Mandroid's documented Play Integrity limitation.

## Setup and recovery

1. On the first download screen, or on **Create a new emulator**, check
   **Enable KernelSU integration**. That selects Google Play Android 36.1
   ARM64 revision 4 (`arm64-v8a-36.1_r04.zip`). Leave it unchecked to download
   and boot the newest stable Play image.
2. If revision 4 is not installed, Mandroid downloads it and replaces only
   `system-images/android-36.1/google_apis_playstore/arm64-v8a/` before the
   emulator is created. Other installed API levels stay on disk and are not
   used for this boot. The first rooted boot then prepares the patched ramdisk.
   Preparing from Settings does not download a system image or restart the
   current session.
3. Wait for Android to boot. Settings reports activation after checking the
   kernel module, and Manager opens on Device Screen. Use Manager for root
   grants; Mandroid does not grant root to the ADB shell automatically.

To return to stock, turn **Boot with KernelSU** off and select
**Restart to Apply**. This also works after preparation or activation fails.

| Situation | Action |
| --- | --- |
| Unsupported kernel | Turn KernelSU off and restart to boot the installed image. The Android API number alone does not establish compatibility; the full kernel version must match. Settings does not replace a system image while guest data exists. Delete the emulator and create it again with **Enable KernelSU integration** to install revision 4. |
| Download or checksum error | Check access to GitHub, then retry **Prepare Patched Image**. The SDK mirror setting does not redirect these downloads. |
| Preparation cancelled | Retry preparation when ready, or disable KernelSU to boot stock. |
| Patched kernel did not activate | Disable KernelSU and restart; retain logs from Settings ▸ Files ▸ Show Logs for diagnosis. |
| SDK kernel or ramdisk changed | Prepare again. The cache is keyed by both source hashes and validated before reuse. An unsupported new kernel is rejected. |

The earlier [KernelSU experiment](KERNELSU-EXPERIMENT.md) documents a separate
manual investigation. Its shell-root diagnostic option is not enabled by this
Settings feature.

## Validation

The unit suite covers persistence, root/stock snapshot handling with preserved
userdata, exact kernel compatibility, changed/corrupt patch caches, and tool
failure/cancellation. Runtime validation uses a fresh isolated data root and
checks the module version, Manager's Working state, and switching back to stock
with a guest marker preserved. The original SDK kernel and ramdisk hashes are
checked against the published patch manifest after the run.

Verified 2026-09-17: Debug/Release builds, 85 tests in 26 suites, script syntax,
and generated-source checks passed. The final stock → KernelSU → stock run
reported module versions 0 → 32601 → 0 and preserved newly written guest data
at both transitions. Manager displayed Working / LKM / 32601-2. Stock kernel
and ramdisk hashes were unchanged. Runtime used cached official assets verified
against release digests; an uncached network download was not exercised.
Evidence is retained in `~/Library/Caches/mandroid-ui-kernelsu-51mj2fhg`:
`results.json`, `runtime.log`, `tests.log`, `audit.log`, `reproduce.py`, and
mode-specific guest and Settings screenshots.
