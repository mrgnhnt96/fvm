---
title: "Quick Start"
description: "Choose Flutter for your project, configure your editor, and run your app."
---

[Install FVM](/getting-started/installation) first. Run the following commands from your Flutter project's root directory.

## Choose Flutter for this project

```sh
fvm install stable
fvm use stable --gitignore
fvm flutter --version
```

`install stable` downloads the current stable Flutter release. `use stable` saves that release's **version number** in `.fvmrc`, so the project stays on it until you choose another version.

To use a particular release instead:

```sh
fvm use 3.44.0 --gitignore
```

`use` downloads the version if it is missing. Find other available versions with `fvm list-remote`.

Commit `.fvmrc` and the `.gitignore` change so teammates use the same version. The `.fvm/` directory stays out of Git.

## Configure your editor

For VS Code, add this setting to your project's `.vscode/settings.json` (merge it with any existing settings):

```json
{
  "dart.flutterSdkPath": ".fvm/flutter_sdk"
}
```

For Android Studio or IntelliJ, set the Flutter SDK path to the full path of your project's `.fvm/flutter_sdk` directory. Restart the editor if it still shows the previous SDK.

## Run your project

```sh
fvm flutter pub get
fvm flutter run
fvm flutter test
fvm dart analyze
```

After [shell setup](/getting-started/shell-setup), you can also run plain `flutter` from this directory.

## Join an existing project

Open its `.fvmrc` and run `fvm use` with the version shown there. For example, if it contains `{"flutter": "3.44.0"}`:

```sh
fvm use 3.44.0
fvm flutter pub get
```

This installs the SDK if needed and creates the editor's SDK link on your computer. Running `fvm flutter` alone does not install a missing SDK.

## Change versions later

Run `fvm use <version>` with the new version and commit the updated `.fvmrc`. To use a newer stable release, repeat both `fvm install stable` and `fvm use stable`.
