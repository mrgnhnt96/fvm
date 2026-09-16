---
title: "Resolution Order"
description: "Five rules select the Flutter SDK, with an explanation you can inspect."
---

## The five rules

1. `FVM_FLUTTER_VERSION` overrides everything for a process and its children.
2. The nearest `.fvmrc` pins the current project, including nested directories.
3. The global default in `$FVM_HOME/config.json` covers unpinned directories.
4. The next real Flutter on PATH is a fallback; FVM skips its own shim.
5. If nothing applies, FVM prints an actionable error.

An explicit but invalid or uninstalled selection fails at that rule. It does not silently choose a lower-priority SDK.

## Inspect the answer

```sh
fvm which
fvm which --path
fvm --verbose flutter --version
```

`which` explains the rule and source. `--path` prints only the executable path. Verbose output goes to stderr.

## One-off overrides

```sh
FVM_FLUTTER_VERSION=3.44.0 fvm flutter test
```

Resolution is offline. Channel names read the concrete versions saved during installation. `fvm exec` prefixes the SDK bin directory and passes the selected concrete version to nested FVM invocations.
