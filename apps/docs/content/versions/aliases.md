---
title: "Aliases and Channels"
description: "Give versions memorable names and understand offline channel pins."
---

## Aliases

```sh
fvm alias work 3.44.0
fvm use work
fvm alias list
fvm unalias work
```

Aliases are stored in `$FVM_HOME/config.json`. They can point to versions, channels, or other aliases. Cycles and chains longer than eight hops are rejected. An alias is machine-local, so a committed concrete version is the simplest team pin.

## Channels

```sh
fvm install stable
fvm use stable
fvm list-remote --channel beta
```

Installation records the concrete release that a channel resolves to. Subsequent execution reads that local mapping without requesting the latest release. Run `fvm install stable` again to refresh it.

Stable and beta have current archive releases. Historical dev entries may be available. Main/master is not an archive-installable channel in this manager.
