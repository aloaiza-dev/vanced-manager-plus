# smali tweak in the install runner — settle fast after a hand-off

Target file: `smali/fe.smali`, the class holding `runInstallation` (log tag `AppBloc`, string
"Starting installation: "). The install wait uses `const-wide/32 ..., 0xea60` (= 60000 ms) for its
`withTimeoutOrNull` calls. There are exactly three occurrences in the method:

```text
1033:  const-wide/32 v12, 0xea60
1426:  const-wide/32 v6,  0xea60
1474:  const-wide/32 v12, 0xea60
```

The wait loop is safe to shorten because it keeps waiting while a real session is still active
(`hasActiveSessionFor` / backgrounded). A handed-off install has no session at all, so shortening
the no-result timeout from 60 s to 10 s makes the app's card settle (and show the "chosen
installer" toast) quickly instead of an anxious minute of "Installing…".

`build.sh` applies this as a rule (the three lines are not adjacent, so a single old→new block
cannot be matched):

```text
expected: exactly 3 occurrences of "0xea60", none already "0x2710"
replacement:
    const-wide/32 v12, 0xea60  ->  const-wide/32 v12, 0x2710
    const-wide/32 v6,  0xea60  ->  const-wide/32 v6,  0x2710
    const-wide/32 v12, 0xea60  ->  const-wide/32 v12, 0x2710
```

Optional: keep the stock 60 s values — the chooser still works, only the settle is slower.