# ReVanced Manager Plus — patching manual (installer-chooser)

A runbook for repeating this patch on a **new ReVanced Manager Plus release**. It documents the
full pipeline used on 3.6.21: locate the hooks, patch, rebuild, sign, verify on an emulator,
deliver to the car. Read `README.md` first for the background and design decisions.

> Why this exists: the published `vancedto/vanced-manager-plus` source does not compile (the
> `data/` layer is private/omitted), so all work happens on the **compiled official APK** with the
> same smali + extra-dex pipeline used for the Waze XPENG patches.

---

## 0. Version-specific truth table (3.6.21, used as the worked example)

| Role | Obfuscated symbol | How to find it again |
| --- | --- | --- |
| `RevancedPackageInstaller` | `o82` | log tag `"RevancedPackageInstaller"`; class with `Context` field `a` |
| Install wrapper (`AppManager`, `ih.c` = install entry, log tag `"AppManager"`) | `ih` | caller of `Lo82;->e(String,String)Z` |
| AppBloc (UI state) | `Lud` | log tag `"AppBloc"`; has field `g:Landroid/content/Context;` |
| AppBloc install statics | `u83` | contains `"Installation aborted by user: "` |
| Install runner (`runInstallation`) | `fe` | contains `"Starting installation: "` and `"] Preflight OK for "` |
| `AppStatus` enum | `fi` | `sget-object ..., Lfi;->j` right after the "Preflight OK" log = `INSTALLING` |

Class letters change per build — **never hardcode them**; locate via the strings above each time.

---

## 1. Obtain the official APK

Releases live in the `vancedto/vanced.to` repo (the source repo publishes no APKs):

```sh
# list current manager_revanced builds
gh api -H "Accept: application/vnd.github+json" \
  "repos/vancedto/vanced.to/releases?per_page=10" \
  --jq '.[] | .tag_name as $t | .assets[] | select(.name|test("manager_plus")) | "\($t)  \(.name)  \(.browser_download_url)"'
curl -L -o official.apk <url>
aapt dump badging official.apk | head -1   # confirm versionCode/versionName
```

Record the SHA-256. Keep it: it is the base every subsequent verification compares against.

---

## 2. Decode

```sh
apktool d -f -o decode official.apk
```

The app is R8-obfuscated; only a handful of classes keep real names (`MainActivity`,
`data/manager/DownloadWorker`, `data/manager/UpdateCheckWorker`, `RevancedManagerApplication`, …).
All app code is under `decode/smali/` (single dex in 3.6.21).

---

## 3. Locate the hooks in the new build

Work from strings that survive obfuscation (log tags and literal messages), not class names.

```sh
cd decode
grep -rln '"AppManager"' smali/                                   # install wrapper candidate (ih)
grep -rln 'Installation aborted by user: ' smali/                 # abort handler (u83.x)
grep -rln 'Starting installation: ' smali/                        # runInstallation (fe)
grep -rln '"RevancedPackageInstaller"' smali/                     # package installer impl (o82)
```

Then trace the chain the way the patcher found it the first time:

```sh
# 1) the commit site: which method calls PackageInstaller.Session.commit?
grep -n 'PackageInstaller$Session;->commit' <installer-impl>.smali   # -> find method g(...)
grep -n 'public final e' <installer-impl>.smali                      # e(pkg, apkPath):Z = install entry

# 2) its caller = the install wrapper (AppManager)
grep -rn 'Lo[0-9a-z]*;->e(Ljava/lang/String;Ljava/lang/String;)Z' smali/ih.smali

# 3) that wrapper is called from the repository (AppRepositoryImpl in be.smali, log "AppRepositoryImpl")
grep -rn 'Lih;->c(Ljava/lang/String;Ljava/lang/String;)Z' smali/be.smali
```

The three edits are documented as fence blocks in:

- `smali/ih.smali.patch.md` — the installer-chooser **gate** (before the session is created).
- `smali/u83.smali.patch.md` — the **settle message** (abort handler).
- `smali/fe.smali.patch.md` — the **60 s → 10 s** no-result wait.

Adapt class letters (`ih`, `o82`, `u83`, `Lud`, `fi`, `Lu32`) to the new build. `build.sh` asserts
each anchor matches exactly once, so a stale letter fails the build instead of producing a broken
APK.

> Class name changes are the #1 porting hazard. If `grep` finds the string but not the class, the
> newer build simply moved it — search the smali text for the method signature instead.

---

## 4. The helper (unchanged across versions)

`src/InstallerChooserPatcher.java` is compiled into **`classes2.dex`** (the APK's class loader picks
up `classesN.dex` natively on API 21+; this APK ships one dex, so `classes2` is free):

- **Count installers** with `queryIntentActivities` on `content://…/installer-probe/` +
  `application/vnd.android.package-archive`, `MATCH_DEFAULT_ONLY`.
  ⚠️ The probe **must carry a content:// data URI**: the system package installer ignores
  type-only intents, so a type-only count under-counts (this bug was found and fixed during
  verification).
- Only when `>1`: copy the private APK to public Downloads (MediaStore, API 29+) and launch
  `Intent.createChooser`. Below API 29 it returns false (stock in-app install).
- Bookkeeping: `HANDED_OFF` map + `consumeHandoff()` so the abort handler can say
  "chosen installer" instead of "cancelled".

Compile (deterministic functional equivalent; byte-identical only to the exact shipped caveat
below):

```sh
SDK="$HOME/Library/Android/sdk"; BT="$SDK/build-tools/36.0.0"
mkdir -p out
javac --release 11 -cp "$SDK/platforms/android-34/android.jar" -d out src/InstallerChooserPatcher.java
"$BT/d8" --release --min-api 26 --lib "$SDK/platforms/android-34/android.jar" --output . \
  out/com/revanced/net/revancedmanager/patch/InstallerChooserPatcher.class
mv classes.dex classes2.dex
```

---

## 5. Re-assemble, inject, align, sign

```sh
apktool b decode -o rebuilt.apk                      # re-assembles classes.dex from patched smali
unzip -o -q rebuilt.apk classes.dex -d dex-out

cp official.apk base.apk                              # byte-identical resources/manifest/libs
(cd dex-out && zip -q ../base.apk classes.dex && cp <helper>/classes2.dex . && zip -q ../base.apk classes2.dex)

"$BT/zipalign" -f -v 4 base.apk aligned.apk
set -a; source signing/local.env; set +a             # KEYSTORE / KEYSTORE_PASS / KEY_ALIAS / KEY_PASS
"$BT/apksigner" sign --ks "$KEYSTORE" --ks-key-alias "$KEY_ALIAS" \
  --ks-pass "env:KEYSTORE_PASS" --key-pass "env:KEY_PASS" --out out.apk aligned.apk
"$BT/apksigner" verify out.apk
shasum -a 256 out.apk
```

Only `classes.dex` + `classes2.dex` differ from the official APK. `apktool b` recompresses
resources, but you never ship its output as-is — you take only its `classes.dex`.

---

## 6. Verify on the disposable emulator

Boot the throwaway AVD (never the car, never the user's emulator-5554):

```sh
"$SDK/emulator/emulator" -avd root35 -read-only -no-window -no-audio -no-boot-anim \
  -no-snapshot-load -no-snapshot-save -port 5556 -memory 2048
"$ADB" -s emulator-5556 root 2>/dev/null; sleep 2
"$ADB" -s emulator-5556 install --no-incremental -r out.apk
"$ADB" -s emulator-5556 shell pm grant com.revanced.net.revancedmanager android.permission.POST_NOTIFICATIONS
"$ADB" -s emulator-5556 shell appops set com.revanced.net.revancedmanager REQUEST_INSTALL_PACKAGES allow
```

**Regression (1 installer):** launch, tap an app's `Download` then `Install`. The gate must return
false and the stock in-app install must complete (`dumpsys package <pkg> | grep versionName`).

**Chooser (2 installers):** the system installer alone is only one handler. Install a second
`ACTION_VIEW application/vnd.android.package-archive` handler — in this workspace a tiny stub APK
was built for the test (empty exported activity, `<data android:mimeType=…/>`), because real
candidates differ: **X-plore 4.46 registers `*/*` + zip but NOT the APK mime** (it won't appear);
MT Manager does register it. Build the stub with aapt v1 + `<uses-sdk>` (aapt v1 ignores
manifest-level targetSdk — `INSTALL_FAILED_DEPRECATED_SDK_VERSION` is the symptom), or use MT
Manager from a trusted mirror.

Then trigger a real install and check:

```sh
adb -s emulator-5556 logcat -d | grep InstallerChooser
# expect: Exposed <pkg> -> content://media/external/downloads/...
#         Chooser launched for <pkg> (2 installers)
adb -s emulator-5556 shell dumpsys window | grep mCurrentFocus
# expect: com.android.intentresolver/.../ChooserActivityLauncher
```

Pick an installer and confirm the external activity receives the public content URI, and that the
card settles ~10 s later with the hand-off message (logcat `AppBloc: Installation aborted by user:
<pkg> - User cancelled or timeout` = the settle path ran; `u83` swaps the toast text).

---

## 7. Deliver to the car (nc relay)

Car serial is `127.0.0.1:15801`; always pass `-s` (an emulator is also usually attached).

```sh
ADB="$HOME/Library/Android/sdk/platform-tools/adb"
"$ADB" -s 127.0.0.1:15801 push out.apk /sdcard/Download/ReVanced-Manager-Plus-<ver>-installer-chooser.apk
"$ADB" -s 127.0.0.1:15801 shell sha256sum /sdcard/Download/ReVanced-Manager-Plus-<ver>-installer-chooser.apk
# compare with the local shasum
```

Installation on the car is a separate, user-driven step (needs uninstall of the old manager first —
the key differs). The relay transfer itself was pre-authorized in the Waze handoff.

### Mandatory: grant the install permission on the car (3.6.17+ blocks downloads without it)

Since v3.6.17 the app pre-flights downloads on `canRequestPackageInstalls()`
(`REQUEST_INSTALL_PACKAGES` appop). On a fresh install the appop is **not granted**, so the first
Update tap shows the system's "Approve app installs" modal (XPENG renders the permission-approval
flow as a blocking dialog) and the download never starts. Grant it once per install — over adb it is
exactly what the dialog's Approve button does:

```sh
"$ADB" -s 127.0.0.1:15801 shell appops set com.revanced.net.revancedmanager REQUEST_INSTALL_PACKAGES allow
"$ADB" -s 127.0.0.1:15801 shell appops set com.revanced.net.revancedmanager REQUEST_DELETE_PACKAGES allow
```

(or on the car: Settings → Apps → ReVanced Manager Plus → Install unknown apps → Allow). Verify:
`appops get com.revanced.net.revancedmanager REQUEST_INSTALL_PACKAGES` must read `allow`.

After that, Update downloads normally and — because the car has several APK handlers — Install
opens the chooser (system installer, MT Manager, App Manager, …) as designed.

---

## 8. Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `build.sh` fails on an anchor | new build renamed a class / changed an instruction → re-locate with §3, keep the anchor block text identical (indentation matters). |
| Stub won't install: `INSTALL_FAILED_DEPRECATED_SDK_VERSION` | missing `<uses-sdk>` element for classic `aapt`; `targetSdk=0`. |
| Chooser never opens; only `Exposed …` logged or nothing | installers counted ≤1. Verify with `cmd package query-activities -a …VIEW -d content://… -t application/vnd.android.package-archive`; remember the **content:// URI requirement** (type-only under-counts). Second handler must register the APK mime (X-plore ≠ MT Manager). |
| Chooser opens but the pick "does nothing" | expected with the stub (empty activity) — on the car a real installer proceeds, and `PACKAGE_ADDED` updates the card. |
| Card stuck on "Installing…" longer than expected | the 60 s→10 s patch wasn't applied, or the app was backgrounded (`wasAppBackgrounded` extends the wait by design). Hand-off settles via `PACKAGE_ADDED` either way. |
| Old test MicroG blocks new installs (signature conflict dialog) | expected — different catalog entry, same package; preflight runs before the gate. Uninstall the blocker to test the chooser path cleanly. |

---

## 9. Keep-alive notes

- Sign with the **same local key** for each new build so car overlays install over the previous
  patched build (`signing/local.env` + `signing/rvmp-patch.jks`; never commit them — `.gitignore`).
- `dist/` holds the ship artifact; the validated pair to re-check after any port is
  `classes.dex` (assembled smali) + `classes2.dex` (helper).
- The helper dex recompiled from `src/` is functionally identical but not byte-identical to the
  shipped one (javac line tables). If byte identity matters, extract `classes2.dex` from the
  shipped APK.