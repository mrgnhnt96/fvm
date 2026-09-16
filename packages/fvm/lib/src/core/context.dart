import 'package:file/file.dart';

import 'config.dart';
import 'exceptions.dart';
import 'installer.dart';
import 'paths.dart';
import 'platform.dart';
import 'process.dart';
import 'releases.dart';
import 'resolver.dart';
import 'style.dart';
import 'updater.dart';
import 'verbose.dart';

/// Everything a command is allowed to touch, handed to it at construction.
///
/// ARCHITECTURE.md asks for constructor injection and no service locators. This
/// is that: an immutable value passed as a constructor parameter, holding no
/// global state and looking nothing up by name at call time. It exists as one
/// object rather than fifteen separate parameters so that a command gaining a
/// collaborator does not force an edit to `lib/fvm.dart`, where every command
/// is registered.
///
/// Nothing here imports `dart:io`. `lib/fvm.dart` is the composition root and
/// supplies the real filesystem, environment, and output sinks.
class FvmContext {
  FvmContext({
    required this.fileSystem,
    required this.environment,
    required this.paths,
    required this.config,
    required this.fvmrc,
    required this.resolver,
    required this.releases,
    required this.installer,
    required this.processes,
    required this.updater,
    required this.executablePath,
    required this.hostPlatform,
    required this.out,
    required this.err,
    required this.outIsTerminal,
    required this.verbose,
    required this.styles,
  });

  /// Builds a context from the pieces that vary, wiring up the rest.
  ///
  /// [platformVersion] is `Platform.version`; it is the only place dart:io
  /// exposes the host architecture. [executablePath] is
  /// `Platform.resolvedExecutable` — the binary `fvm update` replaces.
  factory FvmContext.wire({
    required FileSystem fileSystem,
    required Map<String, String> environment,
    required String platformVersion,
    required StringSink out,
    required StringSink err,
    bool outIsTerminal = false,
    String executablePath = '',
    VerboseLog? verbose,
    Styles? styles,
    ReleaseClient? releases,
    Installer? installer,
    ProcessRunner? processes,
    Updater? updater,
  }) {
    // Built here when the caller did not supply one so that a context wired
    // by a test is verbose-capable without every test having to say so. It
    // starts off unless the environment asks otherwise; `fvm --verbose` flips
    // it in [FvmCommandRunner], after this point.
    final log = verbose ??
        VerboseLog(sink: err, enabled: VerboseLog.enabledIn(environment));
    // Same shape as [log] above, and for the same reason: a context wired by a
    // test can style without every test having to say so. It starts from the
    // environment and the sink; `fvm --color=…` moves it in
    // [FvmCommandRunner.runCommand], after this point.
    final style = styles ??
        Styles(environment: environment, outIsTerminal: outIsTerminal);

    final paths = FvmPaths(fileSystem: fileSystem, environment: environment);
    final config =
        ConfigStore(fileSystem: fileSystem, paths: paths, verbose: log);
    final fvmrc = FvmrcStore(fileSystem: fileSystem, verbose: log);
    // Lazy: an unsupported host must not stop `fvm --help` from printing.
    HostPlatform hostPlatform() => HostPlatform.detect(platformVersion);
    final releaseClient = releases ?? createReleaseClient(verbose: log);
    return FvmContext(
      fileSystem: fileSystem,
      environment: environment,
      paths: paths,
      config: config,
      fvmrc: fvmrc,
      resolver: VersionResolver(
        fileSystem: fileSystem,
        paths: paths,
        config: config,
        fvmrc: fvmrc,
        environment: environment,
        verbose: log,
      ),
      releases: releaseClient,
      installer: installer ??
          createInstaller(
            fileSystem: fileSystem,
            paths: paths,
            releases: releaseClient,
            hostPlatform: hostPlatform,
            // Download progress is normal output, not a diagnostic.
            progress: out,
            progressIsTerminal: outIsTerminal,
            styles: style,
            verbose: log,
          ),
      processes: processes ?? createProcessRunner(verbose: log),
      updater: updater ??
          Updater(
            fileSystem: fileSystem,
            hostPlatform: hostPlatform,
            environment: environment,
          ),
      executablePath: executablePath,
      hostPlatform: hostPlatform,
      out: out,
      err: err,
      outIsTerminal: outIsTerminal,
      verbose: log,
      styles: style,
    );
  }

  final FileSystem fileSystem;
  final Map<String, String> environment;
  final FvmPaths paths;
  final ConfigStore config;
  final FvmrcStore fvmrc;
  final VersionResolver resolver;
  final ReleaseClient releases;
  final Installer installer;
  final ProcessRunner processes;

  /// fvm's own releases: what is newest, and how to become it.
  final Updater updater;

  /// The path to the running `fvm` binary, which `fvm update` replaces.
  ///
  /// Empty when fvm is not running as a compiled binary — nothing reads it in
  /// that case, because [Updater] refuses to update a source checkout.
  final String executablePath;

  /// The host OS/arch, computed on demand so that detection failures surface
  /// in the command that needs an archive rather than at startup.
  final HostPlatform Function() hostPlatform;

  /// Normal output. Injected so tests can read what a command printed.
  final StringSink out;

  /// Errors and diagnostics.
  final StringSink err;

  /// The verbose channel: off unless `--verbose` or `FVM_VERBOSE` asked for
  /// it, and always writing to stderr so that no command's stdout changes.
  final VerboseLog verbose;

  /// Whether [out] is a terminal a human is watching, rather than a file, a
  /// pipe or a CI log.
  ///
  /// Only progress that repaints itself may depend on this. A carriage return
  /// sent anywhere but a terminal does not overwrite the line, it extends it,
  /// so `fvm install` captured to a file would otherwise be one 20KB line
  /// holding every percentage it ever printed. Defaults to false: a sink whose
  /// nature is unknown gets the output that is readable either way.
  final bool outIsTerminal;

  /// How output is STYLED: which spans are coloured, dimmed or bolded, and
  /// whether any of that happens at all.
  ///
  /// Beside [display] on purpose. Path rendering already has exactly one place
  /// that decides how a path is printed; this is the same idea for how a line
  /// is emphasised, so the palette is changeable in one file and `ok` cannot be
  /// green in one command and bold-green in the next.
  final Styles styles;

  /// The directory commands act relative to — `.fvmrc` lookup starts here.
  Directory get workingDirectory => fileSystem.currentDirectory;

  /// A path as it should be PRINTED: relative to [workingDirectory] when it
  /// lies under it, and byte-for-byte unchanged otherwise.
  ///
  /// The signal in `Pinned Flutter 3.13.2 for …/zonai` and
  /// `…/zonai/.fvmrc -> commit this` is WHICH file, and the repeated prefix in
  /// front of it is the directory the reader is already standing in. So
  /// `.fvmrc`, `.fvm/flutter_sdk`, `packages/api/.fvmrc` — with no `./` on the
  /// front, which is noise for the same reason the prefix was.
  ///
  /// Deliberately only that one case. A path in a PARENT directory stays
  /// absolute rather than becoming `../..`, and a path under `$HOME` stays
  /// absolute rather than becoming `~/…`: both were considered and declined,
  /// because counting `..` segments is work the absolute path does not ask for.
  ///
  /// WHAT MUST NEVER PRINT RELATIVE — three kinds of path, and the rule is
  /// about what the path NAMES, not where it happens to sit:
  ///
  ///  * a PATH entry (`~/.fvm/shims`, `~/.fvm/bin`),
  ///  * a shell startup file, or a backup of one (`~/.zshrc`, `~/.profile`),
  ///  * anything in the fvm home — the SDK store, `config.json`, the shim, the
  ///    fvm binary itself.
  ///
  /// The third kind is now ENFORCED here rather than left to each caller: see
  /// [_isInFvmHome]. Everything in the fvm home is under one root, so this
  /// method can recognise the whole category without the caller having to know
  /// which kind of path it is holding.
  ///
  /// This USED to be phrased as "the SDK store needs no special case, it is
  /// never inside a project". That reasoning was wrong, and it shipped: it
  /// assumed nobody's working directory is `$HOME`, when `$HOME` is exactly
  /// where people stand to run `fvm setup` and `fvm doctor`. Standing there,
  /// `~/.fvm/shims` IS under the working directory, so doctor printed
  /// `FAIL PATH: .fvm/shims is not on PATH` three lines above the absolute
  /// `export PATH="/Users/…/.fvm/shims:\$PATH"` that fixes it — one directory,
  /// two spellings, and the relative one is not a thing the reader can paste
  /// anywhere. `setup` printed `source .profile` the same way.
  ///
  /// A relative PATH entry is worse than ugly: a shell resolves it against
  /// whatever directory each process happens to be in.
  ///
  /// `commands/setup_command.dart` therefore calls this NOWHERE — every path it
  /// names is one of the three above — and `commands/doctor_command.dart` calls
  /// it only for project files, which are the case this method exists for.
  ///
  /// But NOT calling it was the whole defence, and it did not hold. `install`
  /// went on printing `Installed Flutter 3.13.2 to .fvm/versions/3.13.2` long
  /// after `doctor` and `setup` were fixed, and the audit that found it found
  /// seven more: `list`, `remove`, `global`, `alias`, `which` and `use` all
  /// routed the SDK store or `config.json` through here. A convention upheld by
  /// remembering it at every call site is not upheld. The first two kinds above
  /// are still the caller's job — a `~/.zshrc` is not under the fvm home — but
  /// they live in one command, which is a much smaller thing to remember.
  ///
  /// One collision is accepted rather than carved out: if a project's root IS
  /// `\$HOME`, its `.fvm/flutter_sdk` symlink sits inside `~/.fvm` and prints
  /// absolute like anything else there. Naming exceptions by filename would put
  /// back exactly the per-call-site knowledge this removes, and an absolute
  /// path there is merely longer, where a relative SDK store is wrong. `test/commands/home_cwd_output_test.dart`
  /// pins both commands' output with the working directory set to `\$HOME`,
  /// which is the case nobody thought to try.
  ///
  /// The working directory ITSELF is not under itself, so it keeps its absolute
  /// path. `Pinned Flutter 3.13.2 for .` names the pin worse than the directory's
  /// own name does.
  ///
  /// The one degenerate case is the filesystem ROOT. Everything is under `/`,
  /// so the literal rule would turn every path fvm prints into a relative one
  /// the moment somebody runs a command from there — `/fvm/versions/3.13.2`
  /// becomes `fvm/versions/3.13.2`, which reads like it could be anywhere. The
  /// prefix this rule exists to remove is noise the reader already knows; at
  /// the root that prefix is one separator, and it is the character carrying
  /// the only thing the path was telling you for certain. So a root working
  /// directory formats nothing, and output from `/` is byte-for-byte what it
  /// was before this method existed.
  ///
  /// Purely lexical, and no filesystem is touched: this runs on output, and
  /// two spellings of one file is a display question, not a resolution one.
  ///
  /// This is the ONLY place output-formatting a path is allowed to happen.
  /// `fvm which`'s machine-readable lines are the carve-out and they do not
  /// call it; see `which_command.dart`. Anything fvm WRITES — `.fvmrc`
  /// contents, the `.fvm/flutter_sdk` target, the PATH line — is not output and
  /// must never come through here.
  String display(String path) {
    final context = fileSystem.path;
    final base = context.normalize(workingDirectory.absolute.path);
    if (context.equals(context.rootPrefix(base), base)) return path;

    final target = context.normalize(
      context.isAbsolute(path) ? path : context.join(base, path),
    );
    if (!context.isWithin(base, target)) return path;
    // The fvm home is never relativized, wherever the user is standing. This
    // is the rule ENFORCED rather than remembered: it used to hold only
    // because each call site was individually careful not to call this method,
    // which is why `fvm install` still printed `Installed Flutter 3.13.2 to
    // .fvm/versions/3.13.2` long after `doctor` and `setup` were fixed. One
    // directory printing two ways depending on where the reader stands is the
    // bug, and a caller cannot reintroduce it now without going around this
    // method entirely.
    if (_isInFvmHome(target)) return target;
    return context.relative(target, from: base);
  }

  /// Whether [target] — absolute and normalized — is the fvm home or inside it.
  ///
  /// Covers the SDK store, `config.json`, the shims and bin directories that go
  /// on PATH, the cache, and the fvm binary itself, because every one of them
  /// lives under the one root. A caller therefore does not have to know which
  /// category a path falls into, which is exactly the knowledge the old rule
  /// depended on and did not have.
  bool _isInFvmHome(String target) {
    final context = fileSystem.path;
    final String home;
    try {
      home = context.normalize(paths.home.absolute.path);
    } on ConfigException {
      // Neither FVM_HOME nor HOME is set. Constructing [FvmPaths] is allowed
      // to fail that way so `fvm --help` works on such a machine, and
      // formatting a path must not be the thing that finally throws.
      return false;
    }
    return context.equals(home, target) || context.isWithin(home, target);
  }
}
