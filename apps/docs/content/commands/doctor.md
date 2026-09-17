---
title: "fvm doctor"
description: "Find and fix problems with your FVM setup."
---

## Check your setup

```sh
fvm doctor
```

Run this from the affected project directory. Doctor checks your selected SDK, project configuration, editor link, and shell PATH. Follow the correction printed for each issue, then rerun the command.

## Check Flutter itself

```sh
fvm flutter doctor
```

Use Flutter's doctor to check platform build tools and devices after FVM selects the right SDK.

For missing commands or incorrect versions, see [Troubleshooting](/guides/troubleshooting).
