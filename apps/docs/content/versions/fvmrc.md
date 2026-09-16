---
title: "The .fvmrc File"
description: "The project pin you commit, and the IDE link you do not."
---

## Format

```json
{"flutter": "3.44.0"}
```

The `flutter` value may name a concrete version, channel, or alias. A bare version on one line is also accepted. JSON is the format `fvm use` writes.

## Nearest pin wins

FVM walks up from the current directory to find the nearest `.fvmrc`. A nested package inherits its parent's pin unless it has its own. `fvm use <version> --here` creates a pin in the current directory even when a parent already has one.

Malformed pins and missing explicitly selected SDKs fail with a useful error. They do not fall through to the global default.

## The IDE link

`fvm use` creates `.fvm/flutter_sdk`, pointing to the complete SDK under `FVM_HOME/versions/<version>`. Set your editor's Flutter SDK path to that link.

Commit `.fvmrc`. Ignore `.fvm/`; use `fvm use <version> --gitignore` to add the ignore entry.
