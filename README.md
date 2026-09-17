# FVM

Choose a Flutter version for each project and run its Flutter and Dart commands.
Projects using the same version share one installed SDK.

[Documentation](https://fvm.mrgnhnt.com) · [Installation](https://fvm.mrgnhnt.com/getting-started/installation) · [Troubleshooting](https://fvm.mrgnhnt.com/guides/troubleshooting)

## Install

On macOS or Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/mrgnhnt96/fvm/main/install.sh | sh
```

You do not need Dart or Flutter installed first. Run the setup command printed
by the installer. For the default location:

```sh
"$HOME/.fvm/bin/fvm" setup --write-path-line
```

Open a new terminal and run `fvm --version`.

On Windows, download `fvm-windows-x64.zip` and its matching `.sha256` file from
[FVM releases](https://github.com/mrgnhnt96/fvm/releases).
Follow the [Windows installation steps](https://fvm.mrgnhnt.com/getting-started/installation)
to verify the download, extract it, and configure PATH.

## Set up a project

From your Flutter project's root directory:

```sh
fvm install stable
fvm use stable --gitignore
fvm flutter pub get
fvm flutter run
```

This saves the installed stable release's **version number** in `.fvmrc`.
The project stays on that version until you select another one.
Commit `.fvmrc` and the `.gitignore` change; keep `.fvm/` out of Git.

For a specific release, run `fvm use 3.44.0 --gitignore` (replace the version
with the one you need). FVM installs it if necessary. When joining an existing
project, run `fvm use` with the version recorded in its `.fvmrc`.

## Configure your editor

In VS Code, add this to your project's `.vscode/settings.json`:

```json
{
  "dart.flutterSdkPath": ".fvm/flutter_sdk"
}
```

In Android Studio or IntelliJ, set the Flutter SDK path to the full path of
`.fvm/flutter_sdk` inside your project. Restart the editor after changing it.

## Everyday use

```sh
fvm flutter test
fvm dart analyze
fvm which
fvm list
```

After shell setup, plain `flutter` also follows your project's version.
Use `fvm dart` for the Dart bundled with Flutter; plain `dart` keeps your
existing Dart setup.

To set a default outside pinned projects, run `fvm global <version>`.
Use `fvm doctor` if the wrong SDK runs.

## Update

Update FVM:

```sh
fvm update
```

Move the current project to the latest stable Flutter release:

```sh
fvm install stable
fvm use stable
```

Test your app and commit the changed `.fvmrc`. Other projects keep their
saved versions.

See the [command reference](https://fvm.mrgnhnt.com/commands/install) for all
commands, or run `fvm <command> --help`. For `flutter`, `dart`, and `exec`,
`--help` is passed to the tool you are running.
