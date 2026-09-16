---
title: "Installation"
description: "Build the manager from source or download a published binary."
---

## Build from source

FVM is a standalone Dart CLI. You need a Dart SDK to compile it; Flutter is not required. The compiled binary can run without Dart installed.

```sh
git clone https://github.com/mrgnhnt96/fvm.git
cd fvm
dart pub get
mkdir -p build
dart compile exe packages/fvm/bin/fvm.dart -o build/fvm
./build/fvm --help
```

Move the executable to a permanent location before setting up the shim. For example, on macOS or Linux:

```sh
mkdir -p "$HOME/.fvm/bin"
cp build/fvm "$HOME/.fvm/bin/fvm"
"$HOME/.fvm/bin/fvm" setup --write-path-line
```

Restart your shell after the PATH change, then follow [Quick Start](/getting-started/quick-start).

## Install script

Check [GitHub Releases](https://github.com/mrgnhnt96/fvm/releases) for published binaries. The install script requires a published release; source builds work before the first release exists.

```sh
curl -fsSL https://raw.githubusercontent.com/mrgnhnt96/fvm/main/install.sh | sh
```

The installer downloads a compiled binary and verifies its checksum. Set `FVM_VERSION` to select a particular published version, or `FVM_HOME` to change the installation location.

On Windows, download and unpack a Windows release asset when available, or compile from source with Dart. Run `fvm setup` for the Windows PATH instructions.

## SDK availability

Flutter releases are selected from the official manifest for your OS and CPU architecture. ZIP and tar.xz bundles are supported. Stable and beta are supported; historical dev versions work when present. Main/master requires a Git checkout and is not supported by this archive-based manager.
