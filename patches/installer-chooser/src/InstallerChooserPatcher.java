package com.revanced.net.revancedmanager.patch;

import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.provider.MediaStore;
import android.util.Log;

import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.List;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Installer-choice patch (DiPlay-style, see DiPlay's {@code startInstaller}): when an install is
 * about to start and more than one installer handles APK files on the device, launch the system
 * chooser and let the driver pick which installer to use (e.g. MT Manager on head units whose own
 * installer refuses). When only one installer exists (the usual case), the app's normal in-app
 * PackageInstaller flow is left untouched.
 *
 * <p>This class is compiled into its own dex (classes2.dex) that the patched APK loads at runtime;
 * the stock app's classes are untouched except for three small smali hooks (see
 * patches/installer-chooser/README.md).
 *
 * <p>All logic is defensive: any failure returns false, so the stock install path always runs.
 */
public final class InstallerChooserPatcher {

    private static final String TAG = "InstallerChooser";
    private static final String MIME_APK = "application/vnd.android.package-archive";
    private static final String DOWNLOADS_DIR = Environment.DIRECTORY_DOWNLOADS + "/ReVancedManager";

    /** Packages that were handed off to an external installer in this process. */
    private static final ConcurrentHashMap<String, Boolean> HANDED_OFF = new ConcurrentHashMap<>();

    private InstallerChooserPatcher() {
    }

    /**
     * If more than one installer can open {@code apkPath}, expose the APK to them, launch the
     * system chooser and return true. Otherwise (lone system installer) return false so the caller
     * keeps its normal in-app install path.
     */
    public static boolean launchIfMultipleInstallers(Context context, String packageName, String apkPath) {
        try {
            File apk = new File(apkPath);
            if (!apk.isFile() || !apk.canRead()) {
                return false;
            }
            // Count installers first for this content type. The probe MUST carry a content:// URI:
            // the system package installer only matches VIEW intents that have a data URI (a
            // type-only intent resolves to just the non-system installers, so a lone system
            // installer would wrongly look like "no second installer"). The URI does not have to
            // resolve; no public copy is made for the probe.
            Intent probe = new Intent(Intent.ACTION_VIEW)
                    .setDataAndType(
                            Uri.parse("content://com.revanced.net.revancedmanager.fileprovider/installer-probe/"),
                            MIME_APK);
            List<ResolveInfo> installers =
                    context.getPackageManager().queryIntentActivities(probe, PackageManager.MATCH_DEFAULT_ONLY);
            if (installers == null || installers.size() <= 1) {
                // Lone system installer: let the app's normal in-app install run, as before.
                return false;
            }
            // Private app downloads cannot be read by other installers; hand them a public copy.
            Uri uri = exposeForInstallers(context, packageName, apk);
            if (uri == null) {
                return false;
            }
            Intent view = new Intent(Intent.ACTION_VIEW)
                    .setDataAndType(uri, MIME_APK)
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            Intent chooser = Intent.createChooser(view, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            context.startActivity(chooser);
            HANDED_OFF.put(packageName, Boolean.TRUE);
            Log.i(TAG, "Chooser launched for " + packageName + " (" + installers.size() + " installers)");
            return true;
        } catch (Throwable t) {
            Log.w(TAG, "Installer chooser failed for " + packageName + ": " + apkPath, t);
            return false;
        }
    }

    /**
     * True (and clears the record) if this package was handed off to an external installer.
     * Called by the install-abort handler so it can report "chosen installer" rather than
     * "cancelled" once the app's wait settles.
     */
    public static boolean consumeHandoff(String packageName) {
        if (packageName == null) {
            return false;
        }
        return Boolean.TRUE.equals(HANDED_OFF.remove(packageName));
    }

    /** Toast text shown after the app settles a handed-off install. */
    public static String handoffToastText(Context context, String packageName) {
        return "Installation opened in the installer you chose"
                + (packageName == null ? "" : " (" + packageName + ")");
    }

    /**
     * Copy the (private) APK into public Downloads and return its MediaStore URI, or null when this
     * cannot be done (old API levels, no storage). The public copy also lets file managers such as
     * MT Manager open the APK directly.
     */
    private static Uri exposeForInstallers(Context context, String packageName, File apk) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            // FileProvider would be needed below Android 10; keep the old in-app flow there.
            return null;
        }
        try {
            ContentResolver resolver = context.getContentResolver();
            ContentValues values = new ContentValues();
            values.put(MediaStore.Downloads.DISPLAY_NAME, safeName(packageName) + ".apk");
            values.put(MediaStore.Downloads.MIME_TYPE, MIME_APK);
            values.put(MediaStore.Downloads.RELATIVE_PATH, DOWNLOADS_DIR);
            values.put(MediaStore.Downloads.IS_PENDING, 1);
            Uri uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values);
            if (uri == null) {
                Log.w(TAG, "MediaStore insert failed for " + packageName);
                return null;
            }
            boolean ok = false;
            try (InputStream in = new FileInputStream(apk);
                 OutputStream out = resolver.openOutputStream(uri)) {
                if (out != null) {
                    byte[] buffer = new byte[64 * 1024];
                    int n;
                    while ((n = in.read(buffer)) > 0) {
                        out.write(buffer, 0, n);
                    }
                    out.flush();
                    ok = true;
                }
            }
            values.clear();
            values.put(MediaStore.Downloads.IS_PENDING, 0);
            resolver.update(uri, values, null, null);
            if (!ok) {
                resolver.delete(uri, null, null);
                return null;
            }
            Log.i(TAG, "Exposed " + packageName + " -> " + uri);
            return uri;
        } catch (Throwable t) {
            Log.w(TAG, "Failed to expose APK for " + packageName, t);
            return null;
        }
    }

    private static String safeName(String packageName) {
        if (packageName == null || packageName.isEmpty()) {
            return "app";
        }
        return packageName.replaceAll("[^A-Za-z0-9._-]", "_");
    }
}