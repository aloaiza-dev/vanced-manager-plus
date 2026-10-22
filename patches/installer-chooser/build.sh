#!/usr/bin/env bash
#
# Reproducible builder for the "installer chooser" patch on
# ReVanced Manager Plus 3.6.21 (vanced.to_revanced_manager_plus_v3.6.21.apk).
#
# What it does
#   - downloads the official 3.6.21 APK (or uses --apk <file>)
#   - decodes it with apktool
#   - applies the smali hooks from smali/*.patch.md (asserting every anchor matches exactly once)
#   - compiles src/InstallerChooserPatcher.java into classes2.dex
#   - re-assembles classes.dex, injects the new dex files into a copy of the ORIGINAL APK
#     (resources / manifest / libs stay byte-identical), zipaligns and signs
#
# Prerequisites
#   - apktool on PATH, JDK 17+ (javac)
#   - Android SDK: platform android-34 (android.jar) and build-tools 36.0.0
#     (d8, zipalign, apksigner); set ANDROID_HOME or it defaults to ~/Library/Android/sdk
#   - a signing keystore. Pass via env (or source signing/local.env first):
#       KEYSTORE KEYSTORE_PASS KEY_ALIAS KEY_PASS
#
# Usage
#   ./build.sh [--apk /path/to/official.apk] [-o out.apk]
#
# Notes
#   The build uses a NEW signing key (the upstream release key is private), so this APK installs
#   over an official build only after uninstalling it. It is not affiliated with the upstream
#   project. Because the published vanced-manager-plus source omits the app's download/install
#   data layer and cannot compile, this patch modifies the compiled release APK instead
#   (see README.md).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src/InstallerChooserPatcher.java"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
BT="$SDK/build-tools/36.0.0"
ADB_API_JAR="$SDK/platforms/android-34/android.jar"
OUT="${OUT:-$HERE/../../dist/ReVanced-Manager-Plus-3.6.21-installer-chooser.apk}"
APK_INPUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apk) APK_INPUT="$2"; shift 2 ;;
    -o) OUT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

for tool in apktool javac; do command -v "$tool" >/dev/null || { echo "missing: $tool" >&2; exit 1; }; done
for tool in "$BT/d8" "$BT/zipalign" "$BT/apksigner"; do
  [ -x "$tool" ] || { echo "missing: $tool" >&2; exit 1; }
done
[ -f "$ADB_API_JAR" ] || { echo "missing android.jar (platforms/android-34)" >&2; exit 1; }
: "${KEYSTORE:?set KEYSTORE, KEYSTORE_PASS, KEY_ALIAS, KEY_PASS}"

cd "$WORK"

if [ -z "$APK_INPUT" ]; then
  echo ">> downloading official 3.6.21 APK"
  curl -sfL -o official.apk \
    "https://github.com/vancedto/vanced.to/releases/download/2026-41/vanced.to_revanced_manager_plus_v3.6.21.apk"
else
  cp "$APK_INPUT" official.apk
fi
echo ">> original sha256: $(shasum -a 256 official.apk | cut -d' ' -f1)"

echo ">> compiling helper -> classes2.dex"
mkdir -p helper-out
javac --release 11 -cp "$ADB_API_JAR" -d helper-out "$SRC"
"$BT/d8" --release --min-api 26 --lib "$ADB_API_JAR" --output . \
  helper-out/com/revanced/net/revancedmanager/patch/InstallerChooserPatcher.class
mv classes.dex classes2.dex

echo ">> decoding APK"
apktool d -f -o decode official.apk >/dev/null

echo ">> applying smali hooks (anchors must match exactly once)"
python3 - "$HERE/smali" "$PWD/decode/smali" <<'PY'
import pathlib, sys

patches_dir = pathlib.Path(sys.argv[1])
smali_dir = pathlib.Path(sys.argv[2])

def fences(name):
    """Return the (old, new) smali block pairs from a .patch.md file."""
    chunks = (patches_dir / name).read_text().split("```smali")
    # chunks[0] is prose; each following chunk is "CODE\n```", possibly with trailing prose.
    blocks = [c.split("```")[0].strip("\n") for c in chunks[1:]]
    if len(blocks) % 2 != 0:
        raise SystemExit(f"FAIL: odd fenced-block count in {name}")
    return [(blocks[i], blocks[i + 1]) for i in range(0, len(blocks), 2)]

def apply(fname, old, new, label):
    p = smali_dir / fname
    s = p.read_text()
    n = s.count(old)
    if n != 1:
        raise SystemExit(f"FAIL: {label}: expected exactly 1 match in {fname}, found {n}")
    p.write_text(s.replace(old, new))
    print(f"  ok: {label}")

for name, fname in (("ih.smali.patch.md", "ih.smali"),
                    ("u83.smali.patch.md", "u83.smali")):
    for i, (old, new) in enumerate(fences(name)):
        apply(fname, old, new, f"{fname} hunk {i + 1}")

# fe.smali timeout: the three 0xea60 sites are not adjacent, so apply as a rule.
p = smali_dir / "fe.smali"
s = p.read_text()
if s.count("0xea60") != 3 or "0x2710" in s:
    raise SystemExit(f"FAIL: fe.smali expected 3x 0xea60 and no 0x2710 (found {s.count('0xea60')})")
s = s.replace("const-wide/32 v12, 0xea60", "const-wide/32 v12, 0x2710") \
     .replace("const-wide/32 v6, 0xea60", "const-wide/32 v6, 0x2710")
p.write_text(s)
print("  ok: fe timeout 60s -> 10s")
PY

echo ">> re-assembling and extracting patched classes.dex"
apktool b decode -o rebuilt.apk >/dev/null
unzip -o -q rebuilt.apk classes.dex -d dex-out

echo ">> rebuilding APK from ORIGINAL bytes + patched dex files"
cp official.apk base.apk
cd dex-out
zip -q ../base.apk classes.dex
cp "$WORK/classes2.dex" .
zip -q ../base.apk classes2.dex
cd "$WORK"

echo ">> align + sign"
"$BT/zipalign" -f -v 4 base.apk aligned.apk >/dev/null
"$BT/apksigner" sign \
  --ks "$KEYSTORE" --ks-key-alias "$KEY_ALIAS" \
  --ks-pass "env:KEYSTORE_PASS" --key-pass "env:KEY_PASS" \
  --out "$OUT" aligned.apk
"$BT/apksigner" verify "$OUT"
echo ">> built: $OUT"
echo ">> sha256: $(shasum -a 256 "$OUT" | cut -d' ' -f1)"