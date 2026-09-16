---
title: "fvm flutter"
description: "Run Flutter from the selected SDK."
---

## Usage

```sh
fvm flutter --version
fvm flutter pub get
fvm flutter test
```

## Behavior

All arguments belong to Flutter, including `--help` and `--version`. Exit status and signals are forwarded. A leading `--` separator is removed before forwarding.
