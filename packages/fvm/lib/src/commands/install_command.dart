import 'package:args/command_runner.dart';

import '../core/channel.dart';
import '../core/context.dart';
import '../core/exceptions.dart';
import 'setup_command.dart';

/// `fvm install` — Download, verify and install a Flutter SDK.
class InstallCommand extends Command<int> {
  InstallCommand({required this.context}) {
    argParser.addFlag(
      'force',
      abbr: 'f',
      negatable: false,
      help: 'Reinstall even if the version is already present.',
    );
  }

  final FvmContext context;

  @override
  String get name => 'install';

  @override
  String get description => 'Download, verify and install a Flutter SDK.';

  @override
  String get invocation => 'fvm install <version|channel|alias>';

  /// How many alias hops to follow before giving up, matching the resolver.
  static const int _maxAliasHops = 8;

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      throw UsageException(
          'Name a version, channel or alias to install.', usage);
    }
    if (rest.length > 1) {
      throw UsageException(
        'Install takes one version at a time, but got: ${rest.join(' ')}',
        usage,
      );
    }

    final requested = rest.single;
    final force = argResults!.flag('force');

    final target = await _resolve(requested);

    if (!force && context.installer.isInstalled(target.version)) {
      // A RESULT line: bold, like the one at the bottom of a real install.
      // The two answer the same question, so they must not read as two
      // different kinds of line.
      context.out.writeln(
        context.styles.heading(
          'Flutter ${target.version} is already installed at '
          '${context.display(context.paths.versionDir(target.version).path)}',
        ),
      );
      _recordChannel(target);
      await setupIfMissing(context);
      return 0;
    }

    final directory = await context.installer.install(
      target.version,
      channel: target.channel,
      force: force,
    );

    _recordChannel(target);
    context.out.writeln(
      context.styles.heading('Installed Flutter ${target.version} to '
          '${context.display(directory.path)}'),
    );
    if (context.installer.isInstalled(target.version)) {
      await setupIfMissing(context);
    }
    return 0;
  }

  /// Turns what the user typed into a concrete version.
  ///
  /// Aliases are followed locally; only a channel name costs a request, and
  /// that one is unavoidable — asking what `stable` means today is the whole
  /// reason to type it. A request that is already a version reaches the
  /// installed-check below without any network I/O at all, so re-running
  /// `fvm install 3.13.2` on a plane still says what it should.
  Future<_InstallTarget> _resolve(String requested) async {
    var current = requested;
    final seen = <String>{};

    while (seen.add(current)) {
      final channel = Channel.tryParse(current);
      if (channel != null) {
        return _InstallTarget(
          version: await context.releases.latestVersion(channel),
          channel: channel,
          // Only a request that named the channel moves what that channel
          // points at. `fvm install 3.9.0` happening to find 3.9.0 published
          // in stable must not rewrite `stable` to a two-year-old SDK.
          recordAs: channel,
        );
      }

      final alias = context.config.read().aliases[current];
      if (alias == null) {
        // A concrete version. The channel it lives in is only needed to build
        // a download URL, so leave it for the installer to look up if it gets
        // that far.
        return _InstallTarget(version: current, channel: null);
      }
      current = alias;

      if (seen.length >= _maxAliasHops) {
        throw ConfigException(
          'The alias "$requested" in '
          '${context.display(context.paths.configFile.path)} does not lead to '
          'a version after $_maxAliasHops hops.',
        );
      }
    }

    throw ConfigException(
      'The alias "$current" in '
      '${context.display(context.paths.configFile.path)} points at itself.',
    );
  }

  /// Writes `channels.<token>` in `~/.fvm/config.json`.
  ///
  /// Version resolution does zero network I/O, so `fvm use stable` can only
  /// work if the version `stable` resolved to was written down here at install
  /// time. Skipping this is what makes `use stable` report that no stable SDK
  /// is installed right after one was.
  void _recordChannel(_InstallTarget target) {
    final channel = target.recordAs;
    if (channel == null) return;

    final config = context.config.read();
    if (config.channels[channel.token] == target.version) return;
    context.config.write(
      config.copyWith(
        channels: {...config.channels, channel.token: target.version},
      ),
    );
  }
}

/// A resolved install request.
class _InstallTarget {
  const _InstallTarget({
    required this.version,
    required this.channel,
    this.recordAs,
  });

  /// The concrete version to install.
  final String version;

  /// The channel to download it from, or null when it still has to be found
  /// by probing — which the installer only does if a download is needed.
  final Channel? channel;

  /// The channel whose recorded version this install updates, or null when the
  /// user asked for a version rather than a channel.
  final Channel? recordAs;
}
