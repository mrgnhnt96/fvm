---
title: "fvm config"
description: "Choose when FVM uses colored terminal output."
---

## Show your color preference

```sh
fvm config color
```

## Save a preference

```sh
fvm config color auto
```

Choose `auto`, `always`, or `never`. `auto` adapts to the terminal and respects `NO_COLOR` and `TERM=dumb`.

## Override one command

```sh
fvm --color=never list
```

This overrides the saved preference for that invocation. It controls FVM's output; Flutter and Dart control their own output.
