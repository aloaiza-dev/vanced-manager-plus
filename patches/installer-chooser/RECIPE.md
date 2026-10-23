# ReVanced Manager Plus — Installer-Chooser Patch: full recipe

End-to-end runbook for reproducing the "installer chooser" patch on ReVanced Manager Plus.
Authoritative home: `patches/installer-chooser/` in the `aloaiza-dev/vanced-manager-plus` fork
(branch `feature/installer-chooser`) — this copy in the workspace is a snapshot of that.

Worked against: **ReVanced Manager Plus 3.6.21** (package `com.revanced.net.revancedmanager`).

---

## 0. Why this exists (constraints that shape everything)

- The public source repo can't compile: its `data/` layer (`AppDownloadManager`,
  `RevancedPackageInstaller`, `DownloadState`, `UpdateCheckWorker`, …) is private/omitted.
- So the patch is applied to the **compiled official APK** with a smali + extra-dex pipeline
  (same as the Waze XPENG patches).
- The official release key is private → every patched build is re-signed with a **local key**,
  which means: uninstall the old manager before installing a patched build; installs of patched
  apps over other-signature builds will ask to uninstall first.
- Since v3.6.17 the app **gates downloads on the `REQUEST_INSTALL_PACKAGES` appop**
  (`canRequestPackageInstalls()`). Fresh installs fail with the system "Approve app installs"
  modal until the appop is granted (see §10).

## 1. Artifacts & state (2026-10-22)

| Item | Value |
| --- | --- |
| Official base APK | `vanced.to_revanced_manager_plus_v3.6.21.apk` from `vancedto/vanced.to` release `2026-41`; SHA-256 `ba6cab6802f002bab339dcccf5facb5ba71d6b94c2f0066961794d7629eebf7c` |
| Patched APK (shipped) | `dist/ReVanced-Manager-Plus-3.6.21-installer-chooser.apk` — SHA-256 `6fce0cf38464938aa08d4aab0fcdcc1ce0019af98ef74a742e97b8075ba89a47` |
| Signing | `signing/rvmp-patch.jks`, alias `rvmp-patch`, DN `CN=Local ReVanced Manager Plus Patch…` (local only, gitignored) |
| Car | XPENG E38B (`au8295_xp`, Android 12), ADB via nc relay `127.0.0.1:15801` |
| Installed on car | patched 3.6.21 (code 381); appops `REQUEST_INSTALL_PACKAGES`/`REQUEST_DELETE_PACKAGES` = `allow` |

## 2. Prerequisites (this machine)

```sh
SDK="$HOME/Library/Android/sdk"
ADB="$SDK/platform-tools/adb"
BT="$SDK/build-tools/36.0.0"                 # d8, zipalign, apksigner, aapt (v1), aapt2
ADB_API_JAR="$SDK/platforms/android-34/android.jar"   # javac compile target
# apktool (brew), javac (JDK 17), zip, curl, gh (fork/pushes), keytool/openssl
# Disposable emulator: AVD "root35" on port 5556 (never the car / never emulator-5554)
```

## 3. Get the official APK

```sh
curl -sfL -o official.apk \
  "https://github.com/vancedto/vanced.to/releases/download/2026-41/vanced.to_revanced_manager_plus_v3.6.21.apk"
shasum -a 256 official.apk        # expect ba6cab68…
"$BT/aapt" dump badging official.apk | head -1    # confirm 3.6.21 / code 381
```

## 4. Decode & locate hooks

```sh
apktool d -f -o decode official.apk            # R8-obfuscated; ~4057 classes under decode/smali
```

Find the obfuscated symbols by strings (they survive obfuscation):

```sh
grep -rln '"RevancedPackageInstaller"'  decode/smali   # -> o82 (impl)
grep -rln 'Installation aborted by user: ' decode/smali # -> u83.x (abort handler)
grep -rln 'Starting installation: '        decode/smali # -> fe (runInstallation)
grep -rn '->commit(Landroid/content/IntentSender;)V' decode/smali/o82.smali  # session commit site
grep -rn 'Lo82;->e(Ljava/lang/String;Ljava/lang/String;)Z' decode/smali      # -> ih
```

Version truth table (3.6.21): `o82`=RevancedPackageInstaller, `ih`=AppManager install wrapper,
`u83`=AppBloc install statics, `fe`=runInstallation, `Lud`=AppBloc (field `g` = Context),
`fi`=AppStatus. **Class letters change per build — always re-locate from strings.**

## 5. Apply the three smali hooks

Anchors + exact old/new blocks are in `patches/installer-chooser/smali/*.patch.md`
(`build.sh` applies them and **fails loudly unless each anchor matches exactly once**):

1. **`ih.smali` — installer gate.** In the install wrapper, before committing the session: call
   `InstallerChooserPatcher.launchIfMultipleInstallers(context, pkg, apkPath)`; on `true`, return
   success and **skip** the in-app session.
2. **`u83.smali` — settle message.** `handleInstallationAborted`: when a hand-off flag is set,
   toast "Installation opened in the installer you chose" instead of "cancelled" (bump `.locals 2→3`,
   keep the package name in `v2`).
3. **`fe.smali` — settle speed.** `const-wide/32 …, 0xea60` → `0x2710` (60 s → 10 s) at the three
   no-result wait sites. Safe: real installs keep waiting while a session is active.

## 6. Build the helper dex (`classes2.dex`)

```sh
mkdir -p out
javac --release 11 -cp "$ADB_API_JAR" -d out src/InstallerChooserPatcher.java
"$BT/d8" --release --min-api 26 --lib "$ADB_API_JAR" --output . \
  out/com/revanced/net/revancedmanager/patch/InstallerChooserPatcher.class
mv classes.dex classes2.dex
```

Key logic (see source): count `ACTION_VIEW application/vnd.android.package-archive` handlers with
`queryIntentActivities` — **the probe must carry a `content://` data URI** (the system installer
ignores type-only intents, so type-only probes under-count by one). Only when `>1`: copy the
private APK to public Downloads (MediaStore, API 29+) and launch `Intent.createChooser(...)`.
Any failure → return `false` → stock in-app install.

## 7. Reassemble, inject, align, sign

```sh
apktool b decode -o rebuilt.apk
unzip -o -q rebuilt.apk classes.dex -d dex-out

cp official.apk base.apk                     # resources/manifest/libs stay byte-identical
(cd dex-out && zip -q ../base.apk classes.dex && cp "$OLDPWD/classes2.dex" . && zip -q ../base.apk classes2.dex)

"$BT/zipalign" -f -v 4 base.apk aligned.apk
set -a; source signing/local.env; set +a     # KEYSTORE/KEYSTORE_PASS/KEY_ALIAS/KEY_PASS
"$BT/apksigner" sign --ks "$KEYSTORE" --ks-key-alias "$KEY_ALIAS" \
  --ks-pass "env:KEYSTORE_PASS" --key-pass "env:KEY_PASS" --out out.apk aligned.apk
"$BT/apksigner" verify out.apk && shasum -a 256 out.apk
```

## 8. Verify on the disposable emulator

Boot `root35` on 5556 (read-only). Install the patched APK, then:

```sh
"$ADB" -s emulator-5556 shell pm grant com.revanced.net.revancedmanager android.permission.POST_NOTIFICATIONS
"$ADB" -s emulator-5556 shell appops set com.revanced.net.revancedmanager REQUEST_INSTALL_PACKAGES allow
```

- **Regression (1 installer):** download + Install an app → stock in-app install completes
  (`dumpsys package <pkg> | grep versionName`), no chooser.
- **Chooser (2 installers):** install a second `application/vnd.android.package-archive` VIEW
  handler. Build the test stub with **aapt v1** + a `<uses-sdk android:minSdkVersion="26"
  android:targetSdkVersion="35"/>` element (aapt v1 ignores manifest-level targetSdk →
  `INSTALL_FAILED_DEPRECATED_SDK_VERSION`), an empty exported activity with
  `<data android:mimeType="application/vnd.android.package-archive"/>`, then zipalign + sign.
  (Real candidates: **MT Manager registers the APK mime; X-plore 4.46 does NOT** — it registers
  `*/*`/zip.)
  Trigger an Install and expect:
  `InstallerChooser: Chooser launched for <pkg> (2 installers)` and
  `dumpsys window` → `ChooserActivityLauncher`; picking the external installer should launch it
  with our public `content://media/…` URI. Card settles ~10 s later (logcat
  `AppBloc: Installation aborted by user: <pkg> - User cancelled or timeout`, toast swapped by §5.2).

## 9. Deploy to the car (nc relay)

```sh
"$ADB" -s 127.0.0.1:15801 push out.apk \
  /sdcard/Download/ReVanced-Manager-Plus-3.6.21-installer-chooser.apk
"$ADB" -s 127.0.0.1:15801 shell sha256sum /sdcard/Download/ReVanced-Manager-Plus-3.6.21-installer-chooser.apk
# compare first field with the local shasum
```

The user installs it in the car (new key → uninstall the old manager first).

## 10. Mandatory: grant install permission on the car (one-time)

Otherwise Update/install attempts dead-end on the system "Approve app installs" modal before any
download starts:

```sh
"$ADB" -s 127.0.0.1:15801 shell appops set com.revanced.net.revancedmanager REQUEST_INSTALL_PACKAGES allow
"$ADB" -s 127.0.0.1:15801 shell appops set com.revanced.net.revancedmanager REQUEST_DELETE_PACKAGES allow
"$ADB" -s 127.0.0.1:15801 shell appops get com.revanced.net.revancedmanager REQUEST_INSTALL_PACKAGES   # -> allow
```

(car UI alternative: Settings → Apps → ReVanced Manager Plus → Install unknown apps → Allow.)

## 11. Sanity checks on the car

```sh
"$ADB" -s 127.0.0.1:15801 shell dumpsys package com.revanced.net.revancedmanager | grep -E "versionName|versionCode"
"$ADB" -s 127.0.0.1:15801 shell cmd package query-activities --brief \
  -a android.intent.action.VIEW -d content://com.revanced.net.revancedmanager.fileprovider/installer-probe/ \
  -t application/vnd.android.package-archive -c android.intent.category.DEFAULT   # -> 8 handlers on this car
```

## 12. Porting to a newer version

- Re-download the newest `manager_plus` asset (gh api on `vancedto/vanced.to` releases).
- Re-locate the four smali symbols from their strings (§4) — class letters change.
- The helper source and `build.sh` don't change; only anchors/letters might.
- Re-run §5–§11. Keep the same signing key so car overlays install over the previous patched build.

## Troubleshooting / gotchas

| Symptom | Fix |
| --- | --- |
| "Approve app installs" modal; download never starts | appop not granted → §10 |
| Chooser never opens (only `Exposed …` or nothing logged) | installers ≤1; the probe needs a **content:// URI**; second handler must register the APK mime |
| Stub won't install (`INSTALL_FAILED_DEPRECATED_SDK_VERSION`) | add `<uses-sdk>` for aapt v1 |
| Card stuck "Installing…" > ~10 s after hand-off | `fe.smali` timeout patch missing, or app backgrounded (`wasAppBackgrounded` extends the wait); settles via `PACKAGE_ADDED` anyway |
| `build.sh` anchor fails | new build renamed a class → re-locate (§4), keep anchor text byte-identical |
| Signature-conflict dialog on a catalog app | different-signature same-package; preflight runs **before** the gate, by design; uninstall the blocker to test the chooser |

## Change notes

- 2026-10-22 — patched 3.6.21 binary: chooser when >1 APK installers (DiPlay parity), clear
  hand-off message, 10 s settle; signed locally, pushed to the car, granted install appops;
  docs + manual + recipe committed to `feature/installer-chooser`.