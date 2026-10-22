# smali hook in the install wrapper — installer-choice gate

Target file in the apktool decode tree: `smali/ih.smali` (method `c(Ljava/lang/String;Ljava/lang/String;)Z`,
the `AppManager` install wrapper flagged by the log tag `AppManager`). Version 3.6.21 (381).

Find this block (it is right after the `File(p2).exists()` check passes, immediately before the
`RevancedPackageInstaller` commit):

```smali
    :cond_0
    :try_start_0
    iget-object p0, p0, Lih;->b:Lo82;

    invoke-virtual {p0, p1, p2}, Lo82;->e(Ljava/lang/String;Ljava/lang/String;)Z
```

Replace with:

```smali
    :cond_0
    # PATCH: DiPlay-style installer choice
    # When more than one installer can open this APK, hand the install to the system
    # chooser (e.g. MT Manager on head units) instead of the silent in-app session.
    iget-object v0, p0, Lih;->b:Lo82;

    iget-object v0, v0, Lo82;->a:Landroid/content/Context;

    invoke-static {v0, p1, p2}, Lcom/revanced/net/revancedmanager/patch/InstallerChooserPatcher;->launchIfMultipleInstallers(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)Z

    move-result v0

    if-eqz v0, :goto_patch_installer

    const/4 v0, 0x1

    return v0

    :goto_patch_installer
    :try_start_0
    iget-object p0, p0, Lih;->b:Lo82;

    invoke-virtual {p0, p1, p2}, Lo82;->e(Ljava/lang/String;Ljava/lang/String;)Z
```

Semantics: `p1` = package name, `p2` = APK file path, `v0`/`v1` are free at `:cond_0`
(`.locals 3`). When the chooser is launched the method returns `true` so the app treats it as a
started install; the app's own wait then settles via the `u83.smali` and `fe.smali` patches below.

The class `Lih`, field `Lih;->b:Lo82` (the package installer) and `Lo82;->a` (context) are the
obfuscated names in the 3.6.21 build — re-find them with:
`grep -rln "Lo82;->e(Ljava/lang/String;Ljava/lang/String;)Z" smali/` and then inspect the caller.