---
title: "Using FVM in CI"
description: "Run a build against a concrete Flutter version without a shell profile."
---

## Install the manager

Use the install script described in [Installation](/getting-started/installation). Cache `$FVM_HOME/versions` between builds where your CI provider supports it; include OS and CPU architecture in the cache key.

## Install the pinned SDK

Commit a concrete `.fvmrc`. On the build machine, explicitly install the version it names before executing tools. For example, for a repository pinned to `3.44.0`:

```sh
fvm install 3.44.0
fvm flutter pub get
fvm flutter test
```

No shim or startup-file edit is needed when commands are invoked through FVM. `fvm exec` is useful for tools that spawn Flutter or Dart themselves.

## Override one job

```sh
FVM_FLUTTER_VERSION=3.44.0 fvm exec flutter test
```

An override selects a version; it does not install it. Keep the override and installation command in agreement. FVM forwards the child's exit status, so a failing test fails the job.
