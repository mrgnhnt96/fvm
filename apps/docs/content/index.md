---
title: "fvm"
description: "A per-project Flutter SDK version manager. One cache, a committed pin, and the right Flutter for every project."
---

FVM follows the same workflow as [DVM](https://dvm.mrgnhnt.com), with Flutter SDKs and their bundled Dart runtimes.

## Pin a project

<Terminal cwd="~/code/app" caption="Install once, pin your project, and run its Flutter SDK.">

```sh
fvm install stable
fvm use stable --gitignore
fvm flutter --version
fvm dart --version
```

</Terminal>

[`fvm use`](/commands/use) writes `.fvmrc` and creates `.fvm/flutter_sdk` for your IDE. Commit the pin; ignore the SDK link. Every project using the same version shares one SDK in `~/.fvm/versions`.

## Let Flutter follow the directory

[`fvm setup`](/commands/setup) creates a `flutter` shim and prints the PATH line. Add that line, or let setup write it with `--write-path-line`. Then plain `flutter` selects the SDK for your current directory.

FVM installs only a Flutter shim. Your existing DVM-managed `dart` can stay on PATH. Use [`fvm dart`](/commands/dart) for the Dart bundled with the selected Flutter SDK.

## Start here

<CardGrid columns="3">
<Card title="Installation" href="/getting-started/installation" icon="rocket">
Build FVM from source, or install a published binary release.
</Card>
<Card title="Quick Start" href="/getting-started/quick-start" icon="pin">
Pin your first project and configure your editor.
</Card>
<Card title="Resolution Order" href="/versions/resolution-order" icon="terminal">
Understand which Flutter SDK a command will use.
</Card>
</CardGrid>

## Inspect the choice

```sh
fvm which
fvm list
fvm doctor
```

Version resolution is local: environment override, nearest project pin, global default, then Flutter on PATH. A missing explicit pin reports an error instead of silently choosing another SDK.

This repository is an independent Flutter manager, not the pub.dev package named `fvm`. It does not import another manager's cache. See [Using FVM alongside DVM](/guides/dvm).

<SectionCards />
