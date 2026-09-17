---
title: "Getting Started"
description: "Install FVM, choose Flutter for your project, and run your app."
---

FVM lets each project use its own Flutter version. Projects on the same version share one installed SDK. You do not need Dart or Flutter installed first.

## Installation

### Install script for macOS and Linux

Run the install script:

```sh
curl -fsSL https://raw.githubusercontent.com/mrgnhnt96/fvm/main/install.sh | sh
```

You need `curl`, an unzip tool (`unzip` or Python 3), and a checksum tool (`sha256sum`, `shasum`, or `openssl`).

Run the setup command printed by the installer. For the default location:

```sh
"$HOME/.fvm/bin/fvm" setup --write-path-line
```

Setup backs up your shell startup file and adds the PATH entries. Open a new terminal and check:

```sh
fvm --version
```

If the installer reports a conflicting `fvm` function or alias, follow its instructions before running setup.

### Install FVM on Windows

1. Open [FVM releases](https://github.com/mrgnhnt96/fvm/releases). Download `fvm-windows-x64.zip` and its matching `.sha256` file from the same release.
2. Run `Get-FileHash .\fvm-windows-x64.zip -Algorithm SHA256` in PowerShell and compare the hash with the `.sha256` file.
3. Extract `fvm.exe` to a permanent folder, such as `C:\Tools\fvm`.
4. Run setup using its full path:

```powershell
& "C:\Tools\fvm\fvm.exe" setup
```

Add the executable's folder and the shims folder printed by setup to your **user PATH** in Windows Environment Variables. Put the shims folder before other Flutter installations. Open a new terminal and run `fvm --version`.

### Custom location or FVM release

On macOS or Linux, set `FVM_HOME` to choose an installation directory:

```sh
curl -fsSL https://raw.githubusercontent.com/mrgnhnt96/fvm/main/install.sh | FVM_HOME="$HOME/tools/fvm" sh
```

Set `FVM_HOME` to that same directory in your shell startup file for future commands, then run the setup command printed by the installer.

To choose a specific FVM release, set `FVM_VERSION` on the installer process instead. For example, use `FVM_VERSION="<release-version>" sh` at the end of the install command, replacing the placeholder with a version from [FVM releases](https://github.com/mrgnhnt96/fvm/releases).

## Quick start

From your Flutter project's root directory:

```sh
fvm install stable
fvm use stable --gitignore
fvm flutter --version
```

`install stable` downloads the current stable release. `use stable` saves that release's **version number** in `.fvmrc`. The project stays on that version until you choose another one.

For a specific release, use `fvm use 3.44.0 --gitignore`, replacing the version with the one you need. FVM installs it if necessary. Find available releases with `fvm list-remote`.

Commit `.fvmrc` and the `.gitignore` change. Keep `.fvm/` out of Git.

### Join an existing project

Read the version in `.fvmrc`, then select it. For `{"flutter": "3.44.0"}`:

```sh
fvm use 3.44.0
fvm flutter pub get
```

This installs the SDK if needed and creates the editor link on your computer. Running `fvm flutter` alone does not install a missing SDK.

## Editor setup

In VS Code, merge this setting into your project's `.vscode/settings.json`:

```json
{
  "dart.flutterSdkPath": ".fvm/flutter_sdk"
}
```

In Android Studio or IntelliJ, set the Flutter SDK path to the full path of `.fvm/flutter_sdk` inside your project. Restart the editor if it still shows the previous SDK.

## Run your app

```sh
fvm flutter pub get
fvm flutter run
fvm flutter test
fvm dart analyze
```

Use `fvm dart` for the Dart bundled with your project's Flutter SDK. Plain `dart` keeps your existing Dart setup.

## Shell setup

After the setup step above, plain `flutter` also follows your project's version. From a configured project, check:

```sh
flutter --version
fvm which
fvm doctor
```

FVM's launcher, called a shim, must come before other Flutter installations on PATH. Follow `fvm doctor` if the wrong version runs.

To manage PATH yourself, run `fvm setup` and follow its printed instructions. On Windows, update your user PATH manually; PowerShell does not support `--write-path-line`.

If you move the FVM executable, run setup from its new location. To undo the automatic PATH edit, run `fvm setup --remove-path-line` and open a new terminal. This leaves manually added PATH entries and installed SDKs in place.

## Next steps

- [Manage versions](/versions): project pins, channels, aliases, and defaults.
- [Commands](/commands): all FVM commands and options.
- [Update FVM and Flutter](/updating).
- [Run in CI](/ci).
- [Troubleshoot your setup](/troubleshooting).

[Documentation for AI assistants](/llms.txt) is also available.
