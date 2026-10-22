# Installer-chooser patch for ReVanced Manager Plus

Status: **built, signed, and verified on an emulator (2026-10-22).** Artifact:
`dist/ReVanced-Manager-Plus-3.6.21-installer-chooser.apk` (SHA-256 `6fce0cf38464938aa08d4aab0fcdcc1ce0019af98ef74a742e97b8075ba89a47`).

## Problem

On some head units (the XPENG in this workspace is one) the system package installer refuses or
fails on apps like ReVanced Manager Plus that install other apps via the silent `PackageInstaller`
session API. The fix that already works in **DiPlay** (`common/.../DiPlayActivity.kt`,
`startInstaller`) is: when more than one installer for APK files exists on the device, present the
user with the Android chooser so they can pick another installer (e.g. **MT Manager**). This patch
ports exactly that behavior to ReVanced Manager Plus **3.6.21**.

## Why a binary patch and not a source build

The published `vancedto/vanced-manager-plus` source on GitHub **cannot compile**:

- it references a private `data/` layer (`AppDownloadManager`, `RevancedPackageInstaller`,
  `InstallationResult`, `DownloadState`, `UpdateCheckWorker`, …) that is not committed — only 48
  Kotlin files exist, `git status` is clean, and no fork contains the missing classes
  (GitHub code search finds only the upstream import);
- the official compiled APK (from `vancedto/vanced.to` releases) does contain that layer, so the
  working app is real — the public repo is a partial publication.

Therefore the change is made to the **compiled release APK** using the same surgical
smali + extra-dex pipeline this workspace uses for the Waze XPENG patches.

## What the patch does (exact DiPlay behavior)

When the user starts an install **and more than one installer can open APK files** on the device:

1. the downloaded APK (app-private storage) is copied to public `Downloads/ReVancedManager/`
   (MediaStore, API 29+; below that the stock in-app install is kept);
2. the app opens `Intent.createChooser(ACTION_VIEW application/vnd.android.package-archive)` so the
   driver picks which installer to use;
3. the silent in-app `PackageInstaller` session is **not** created.

When only one installer exists (the common case), the app's normal in-app install runs exactly as
before. Everything is defensive: any error falls back to the stock path.

## Files

| File | What it is |
| --- | --- |
| `PATCHING-MANUAL.md` | Runbook to repeat this patch on a **new** release (hook re-location, build, verify, car deploy). |
| `src/InstallerChooserPatcher.java` | The helper, compiled into `classes2.dex` (count installers, expose APK, chooser, hand-off bookkeeping). |
| `smali/ih.smali.patch.md` | Gate hook in the install wrapper (`AppManager.c`, obfuscated `ih.smali`): run the helper before committing a session; on hand-off return success and skip the session. |
| `smali/u83.smali.patch.md` | Abort-handler hook (`handleInstallationAborted`, obfuscated `u83.smali`): when a hand-off settled, show "Installation opened in the installer you chose" instead of a misleading "cancelled". |
| `smali/fe.smali.patch.md` | Timeout tweak in `runInstallation` (`fe.smali`): 60 s → 10 s no-result wait so handed-off installs settle quickly. Real installs are unaffected because the wait loop keeps going while a session is active. |
| `build.sh` | Reproduces the APK from the official 3.6.21 release (+ dex files + keystore). |

The three smali targets are the obfuscated class names found in the 3.6.21 build
(dex: `ih` = install wrapper / "AppManager", `u83` = install logic companion, `fe` = install run
coroutine, `o82` = `RevancedPackageInstaller`, `Lud` = `AppBloc`). Re-find them for a newer build
by their log tags / strings (see each `.patch.md`).

## Build

```sh
# from this directory
set -a; source ../../signing/local.env; set +a   # or export KEYSTORE/KEYSTORE_PASS/KEY_ALIAS/KEY_PASS
./build.sh                                        # downloads the official 3.6.21 APK
./build.sh --apk /path/to/vanced.to_revanced_manager_plus_v3.6.21.apk
```

The script asserts every smali anchor matches exactly once and fails loudly otherwise. The final
zip contains the original entries byte-identical except `classes.dex` (re-assembled from patched
smali) plus the added `classes2.dex`. Resources, manifest and native libs are untouched.

> The helper dex (`classes2.dex`) is **functionally** identical when recompiled from `src/` but not
> byte-identical (javac debug line tables differ by whitespace layout). If you need the exact bytes
> of the shipped build, extract `classes2.dex` from the APK in `dist/`.

## Verification performed (disposable API-35 AVD)

- App launches, catalog loads, no crashes with the patch installed.
- **Single installer (regression):** a clean in-app install (MicroG) downloaded, passed the gate
  (1 installer → no chooser) and completed via the stock session API. Log: `Exposed …` (public
  copy) is not made in this case.
- **Two installers:** with a second `ACTION_VIEW` package-archive handler installed, starting an
  install logs
  `InstallerChooser: Chooser launched for <pkg> (2 installers)` and the Android chooser opens
  (`ChooserActivityLauncher`) listing both installers.
- **External hand-off:** picking the external installer launches it with the public MediaStore
  content URI.
- **Queue:** two queued installs each hand off in sequence (two choosers fired back-to-back).
- **Settle:** after a hand-off the card settles in ~10 s (60 s stock) with the hand-off message.

## Installing on the car

The build is signed with a **new local key** (`signing/rvmp-patch.jks` — upstream's release key is
private), so it **must be installed over an uninstalled** ReVanced Manager Plus:

1. copy `dist/ReVanced-Manager-Plus-3.6.21-installer-chooser.apk` to the car (e.g. over the ADB nc
   relay to `/sdcard/Download/`);
2. uninstall the old manager (or install with the "different signature" flow);
3. install the APK; optionally install MT Manager (or any second APK installer) on the car so the
   tool offers a choice; with no second installer the app behaves exactly as stock.

The manager's own data/preferences reset on reinstall (same as any re-sign), but the patched apps
it manages are untouched.

> **Required after install:** grant the install permission once, or Update/install attempts are
> blocked by the system "Approve app installs" dialog and downloads never start
> (since v3.6.17 downloads are gated on `canRequestPackageInstalls()`). Over adb:
> `appops set com.revanced.net.revancedmanager REQUEST_INSTALL_PACKAGES allow` (also
> `REQUEST_DELETE_PACKAGES`), or on the car: Settings → Apps → ReVanced Manager Plus →
> Install unknown apps → Allow. Details in PATCHING-MANUAL.md §7.