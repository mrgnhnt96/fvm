# fvm

A per-project Flutter version manager, based on the behavior and implementation
of [dvm](https://github.com/mrgnhnt96/dvm).

Keep Flutter SDKs in one cache, pin projects with `.fvmrc`, and let a PATH shim
select the right Flutter whenever you change directories.

Documentation: <https://fvm.mrgnhnt.com>

## Build and try it

This repository contains a standalone Dart CLI. Flutter is not required to build
it; the compiled executable does not require Dart to be installed.

```sh
dart pub get
mkdir -p build
dart compile exe packages/fvm/bin/fvm.dart -o build/fvm
./build/fvm --help
./build/fvm install stable
./build/fvm use stable --gitignore
./build/fvm flutter --version
./build/fvm dart --version
```

`use` installs a missing SDK, writes `.fvmrc`, and creates
`.fvm/flutter_sdk` for IDEs. Commit `.fvmrc`; ignore `.fvm/`. Point VS Code's
`dart.flutterSdkPath` at `.fvm/flutter_sdk`.

The compiled CLI creates its Flutter shim automatically after `install`, `use`,
or `global` makes an SDK available. It prints PATH instructions. To explicitly
set up the shim and add the PATH line to your shell startup file:

```sh
./build/fvm setup --write-path-line
```

Keep the compiled binary in a permanent location before setup: the shim records
its absolute path. Plain `setup` prints instructions without editing your shell.
The shim is `~/.fvm/shims/flutter` (`flutter.bat` on Windows). It must precede
other Flutter installations on PATH. `fvm doctor` diagnoses conflicts.

Only a Flutter shim is installed, so an existing DVM Dart shim can coexist.
Use `fvm dart` or `fvm exec dart` when you need the Dart bundled with Flutter;
`fvm exec` puts the selected Flutter SDK's `bin` first on the child's PATH.

## Commands

| Command | Behavior |
| --- | --- |
| `install <version\|channel\|alias> [--force]` | Download and verify an SDK; force reinstalls it |
| `use <version\|channel\|alias> [--gitignore]` | Pin this project and create the IDE link |
| `global <version\|channel\|alias>` | Set the fallback SDK |
| `list` / `ls` | List installed SDKs |
| `list-remote [--channel channel]` | List published releases for this host architecture |
| `which` / `current` | Explain the selected SDK; `--path` prints just its launcher |
| `flutter <args...>` | Forward arguments and exit status to Flutter |
| `dart <args...>` | Run Dart bundled with the selected Flutter |
| `exec <command> <args...>` | Run a command with the selected SDK on PATH |
| `alias <name> <version\|channel\|alias>` | Save an alias |
| `unalias <name>` | Remove an alias |
| `remove <version\|alias>` | Remove an installed SDK |
| `setup` | Create the Flutter shim and print PATH instructions |
| `doctor` | Diagnose configuration, pins, IDE links, and shell/PATH issues |
| `config color auto\|always\|never` | Save output color preferences |
| `update` | Update a release-built FVM binary from GitHub Releases |

Run a command with `--help` for its options. For `flutter`, `dart`, and `exec`,
all arguments, including `--help`, belong to the child command.

## Resolution

The first matching rule wins:

1. `FVM_FLUTTER_VERSION` environment override.
2. The nearest `.fvmrc`, walking up from the current directory.
3. The global default in `$FVM_HOME/config.json`.
4. The next real Flutter on PATH, excluding FVM's own shim.
5. An actionable error when no SDK can be selected.

```json
{"flutter": "3.44.0"}
```

Pins may also name a channel or alias. Channel resolution during execution is
offline: `install stable` records the concrete version in config. Run it again
to refresh that mapping. `FVM_HOME` defaults to `~/.fvm`; SDKs live under
`versions/<version>`, temporary downloads under `cache/`.

Downloads use Flutter's official per-platform release manifests, select the
host architecture, verify the manifest's SHA-256, and unpack ZIP or tar.xz
archives before publishing the SDK. Stable and beta are supported; historical
dev releases can be installed when present in the manifest. Main/master builds
require a Git checkout and are not supported by this archive-based manager.

## Development and distribution

```sh
dart analyze
(cd packages/fvm && dart test)
bash tool/test_install_sh.sh
```

Tests use memory filesystems and local HTTP fixtures. CI runs on Linux, macOS,
and Windows. `.github/workflows/release.yml` builds standalone binaries,
stamps the version, packages checksummed release assets, and can publish a versioned
release through a manual workflow dispatch. `install.sh` and `fvm update` target `mrgnhnt96/fvm`; they require a
published release. No release has been published as part of creating this repo.

DVM's legacy cbracken migration is intentionally absent because its directory
layout is specific to Dart. This is an independent implementation, not the
pub.dev `fvm` package, and it does not migrate another manager's cache.

## License

MIT. Adapted from DVM; see [LICENSE](LICENSE).

## Documentation site

The Jaspr site lives in `apps/docs` and uses the same layout, search, and GitHub
Pages workflow as DVM. To work on it:

```sh
dart pub get
cd apps/docs
dart run tool/build_search_index.dart
dart run jaspr_cli:jaspr serve
```

Run `dart test` from `apps/docs` to check navigation, content links, search, and
the complete static build. After editing content, regenerate the committed
search index. GitHub Actions → **Deploy docs** publishes the selected ref;
choose `main` for the public site. Deployment is manual.

Pages uses the repository-level custom domain `fvm.mrgnhnt.com`, with a DNS
CNAME pointing to `mrgnhnt96.github.io`. Enable HTTPS enforcement after GitHub
issues the domain certificate. Actions deployments do not need a CNAME file.
