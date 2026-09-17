---
title: "fvm which"
description: "See which Flutter SDK will run and why it was selected."
---

## Explain the current selection

```sh
fvm which
```

Shows the version and whether it came from an environment override, a project pin, your global default, or PATH. `fvm current` runs the same command.

## Print only the executable path

```sh
fvm which --path
```

Use this when a script needs the path to the Flutter executable.

If the result is unexpected, see [Resolution Order](/versions/resolution-order) or run [`fvm doctor`](/commands/doctor).
