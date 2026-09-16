---
title: "fvm exec"
description: "Run any command with the selected SDK first on PATH."
---

## Usage

```sh
fvm exec flutter test
fvm exec dart analyze
```

## Behavior

The child inherits your environment with the selected SDK bin directory prefixed to PATH. Nested tools find that SDK. All arguments after the command are passed through.
