# FVM

Choose a Flutter version for each project and run its Flutter and Dart commands.
Projects using the same version share one installed SDK.

[Documentation](https://fvm.mrgnhnt.com) · [Installation](https://fvm.mrgnhnt.com/#installation) · [Troubleshooting](https://fvm.mrgnhnt.com/troubleshooting/)

## How this differs from Leo Farias's FVM

This is a separate project from [leoafarias/fvm](https://github.com/leoafarias/fvm),
the widely used Flutter Version Management tool. It shares the name, the
`fvm` command, the `.fvmrc` file, and the `.fvm/flutter_sdk` editor link, but
it is a different implementation:

- **Shims first.** Setup puts a `flutter` shim on your PATH, so plain
  `flutter` runs the version pinned in `.fvmrc`. You do not have to prefix
  every command with `fvm flutter`.
- **Official release archives.** SDKs are downloaded from Flutter's release
  manifest and checked against its SHA-256 digests, rather than cloned from the
  Flutter Git repository.
- **Standalone binary.** FVM ships as a compiled executable from
  [GitHub Releases](https://github.com/mrgnhnt96/fvm/releases). It is not on
  pub.dev, and you do not need Dart or Flutter installed first. `fvm update`
  updates it in place.
- **One Flutter version per project.** `.fvmrc` only records the `flutter`
  version. Other keys, such as flavors, are ignored when reading and dropped
  when `fvm use` rewrites the file.

### Migrating

Both tools provide an `fvm` command, so use only one of them on a machine.
When `fvm setup` finds Leo Farias's FVM, it offers to migrate: your global
version and the projects it tracked move over, then it asks whether to
uninstall the other FVM. To migrate later, or one project at a time, run this
from the project:

```sh
fvm migrate --dry-run   # preview the changes
fvm migrate
```

Forks, commits, `master`, and custom SDKs have no equivalent here and are left
unchanged. Flavors are removed. See [`fvm migrate`](https://fvm.mrgnhnt.com/commands/#fvm-migrate)
for details.

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

Setup installs FVM's `flutter` shim and puts it first on your PATH, so plain
`flutter` runs your project's version. Open a new terminal and run
`fvm --version`.

On Windows, download `fvm-windows-x64.zip` and its matching `.sha256` file from
[FVM releases](https://github.com/mrgnhnt96/fvm/releases).
Follow the [Windows installation steps](https://fvm.mrgnhnt.com/#install-fvm-on-windows)
to verify the download, extract it, and add FVM and its shims folder to PATH.

## Set up a project

From your Flutter project's root directory:

```sh
fvm install stable
fvm use stable --gitignore
flutter pub get
flutter run
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
flutter test
fvm dart analyze
fvm which
fvm list
```

The `flutter` shim picks the SDK pinned in `.fvmrc`, so use `flutter` as you
normally would. FVM only shims `flutter`: use `fvm dart` for the Dart bundled
with your project's Flutter; plain `dart` keeps your existing Dart setup.

To set a default outside pinned projects, run `fvm global <version>`.
If `flutter` runs the wrong SDK, check `fvm which` and `fvm doctor`; the shims
folder must come before other Flutter installations on PATH. Without the shim,
`fvm flutter <args>` runs the same resolution explicitly.

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

See the [command reference](https://fvm.mrgnhnt.com/commands/) for all
commands, or run `fvm <command> --help`. For `flutter`, `dart`, and `exec`,
`--help` is passed to the tool you are running.
