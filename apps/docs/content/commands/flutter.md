---
title: "fvm flutter"
description: "Run Flutter using your project\u2019s selected SDK."
---

## Run Flutter commands

From your project directory:

```sh
fvm flutter pub get
fvm flutter run
fvm flutter test
fvm flutter build apk
```

Choose the project's SDK with [`fvm use`](/commands/use) first. If the selected SDK is missing, install the version named in the error.

## Check the version or get Flutter help

```sh
fvm flutter --version
fvm flutter --help
```

Everything after `fvm flutter` is passed to Flutter, including `--help`. A failing Flutter command returns the same exit status through FVM.

To type just `flutter`, follow [Shell Setup](/getting-started/shell-setup).
