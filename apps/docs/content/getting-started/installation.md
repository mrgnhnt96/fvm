---
title: "Installation"
description: "Get the manager with one install script, no Dart or Flutter SDK required."
---

## Install script

Install FVM on macOS or Linux with one command:

```sh
curl -fsSL https://raw.githubusercontent.com/mrgnhnt96/fvm/main/install.sh | sh
```

The installer downloads a compiled binary for your machine and verifies its checksum. You do not need Dart or Flutter installed first.

## Set up your shell

Follow the setup command printed by the installer:

```sh
fvm setup --write-path-line
```

Restart your shell, then follow [Quick Start](/getting-started/quick-start) to install Flutter and pin your first project. Setup creates a Flutter shim; it does not replace a DVM-managed Dart shim.

## Choose a version or location

The script installs the latest published release by default. To select a particular release:

```sh
curl -fsSL https://raw.githubusercontent.com/mrgnhnt96/fvm/main/install.sh | FVM_VERSION=0.0.1 sh
```

Set `FVM_HOME` on the installer process to change its home directory. The default is `~/.fvm`.

## Windows

Download `fvm-windows-x64.zip` from [GitHub Releases](https://github.com/mrgnhnt96/fvm/releases/latest), verify its matching SHA-256 file, and extract `fvm.exe` to a permanent directory. Run `fvm setup` for the Windows PATH instructions.

## SDK availability

Flutter releases are selected from the official manifest for your OS and CPU architecture. ZIP and tar.xz bundles are supported. Stable and beta are supported; historical dev versions work when present. Main/master requires a Git checkout and is not supported by this archive-based manager.
