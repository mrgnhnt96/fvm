---
title: "Installation"
description: "Install FVM on macOS, Linux, or Windows without an existing Dart or Flutter SDK."
---

## Install FVM on macOS or Linux

Run the install script:

```sh
curl -fsSL https://raw.githubusercontent.com/mrgnhnt96/fvm/main/install.sh | sh
```

You need `curl`, an unzip tool (`unzip` or Python 3), and a checksum tool (`sha256sum`, `shasum`, or `openssl`). You do not need Dart or Flutter first.

Run the setup command printed by the installer. With the default install location, it is:

```sh
"$HOME/.fvm/bin/fvm" setup --write-path-line
```

Close and reopen your terminal, then check the installation:

```sh
fvm --version
```

If the installer reports an existing `fvm` shell function or alias, follow its instructions to remove the conflict before running setup.

## Install FVM on Windows

1. Open [FVM releases](https://github.com/mrgnhnt96/fvm/releases) and choose a release containing `fvm-windows-x64.zip`.
2. Download that ZIP and its matching `.sha256` file. In PowerShell, run `Get-FileHash .\fvm-windows-x64.zip -Algorithm SHA256` and compare the hash with the `.sha256` file.
3. Extract `fvm.exe` to a permanent folder, such as `C:\Tools\fvm`.
4. Run setup using the full path:

```powershell
& "C:\Tools\fvm\fvm.exe" setup
```

Add the executable's folder and the shims folder printed by setup to your **user PATH** in Windows Environment Variables. Put the shims folder before any other Flutter installation. Open a new terminal and run `fvm --version`.

Windows setup prints the paths to add; `--write-path-line` is not available for PowerShell.

## Choose a different install location

On macOS or Linux, set `FVM_HOME` when running the installer:

```sh
curl -fsSL https://raw.githubusercontent.com/mrgnhnt96/fvm/main/install.sh | FVM_HOME="$HOME/tools/fvm" sh
```

Also set `FVM_HOME` to that same directory in your shell startup file for future commands. Run the setup command printed by this installation.

To install a specific FVM release, set `FVM_VERSION` to a version listed on [FVM releases](https://github.com/mrgnhnt96/fvm/releases):

```sh
curl -fsSL https://raw.githubusercontent.com/mrgnhnt96/fvm/main/install.sh | FVM_VERSION="<release-version>" sh
```

Replace `<release-version>` before running the command.

## Next: set up a project

Follow [Quick Start](/getting-started/quick-start) to install Flutter and select your project's version.
