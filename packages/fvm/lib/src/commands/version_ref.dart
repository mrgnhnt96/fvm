import '../core/channel.dart';
import '../core/context.dart';
import '../core/exceptions.dart';
import 'setup_command.dart';

/// How many alias hops to follow before giving up, matching the resolver.
const int maxAliasHops = 8;

/// A name the user typed, followed through aliases and channels to the
/// concrete version it stands for.
///
/// The resolver does this too, but only as part of applying the five
/// resolution rules, and only for SDKs that are already installed. `use`,
/// `global`, `remove` and `alias` all need the name-following on its own —
/// often for a version that is not installed yet, which is the whole point of
/// `use` auto-installing.
class VersionRef {
  const VersionRef({
    required this.pin,
    required this.version,
    required this.hops,
    this.channel,
  });

  /// Exactly what the user typed.
  final String pin;

  /// The concrete version [pin] names.
  final String version;

  /// Every name walked through, [pin] first and [version] last. A pin that was
  /// already a version has a single hop.
  final List<String> hops;

  /// The channel that supplied [version], when a channel token was involved.
  final Channel? channel;

  /// Whether the user named the version directly, with nothing in between.
  bool get isDirect => hops.length == 1;

  /// `work -> stable -> 3.13.2`, for output that has to show its working.
  String get trail => hops.join(' -> ');
}

/// Follows [pin] through aliases and channels with **zero network I/O**.
///
/// A channel is answered out of `channels` in `config.json`, where `install`
/// recorded it; there is deliberately no fallback that asks the archive what
/// `stable` means, because that would put a network round-trip behind `fvm
/// use stable` on a plane.
VersionRef resolveVersionRef(FvmContext context, String pin) {
  final config = context.config.read();
  final hops = <String>[pin];
  final seen = <String>{};
  var current = pin;

  for (var hop = 0; hop < maxAliasHops; hop++) {
    if (!seen.add(current)) {
      throw ConfigException(
        'The alias "$current" in '
        '${context.display(context.paths.configFile.path)} points at itself. '
        'Fix it with: fvm alias $current <version>',
      );
    }

    final channel = Channel.tryParse(current);
    if (channel != null) {
      final version = config.versionForChannel(channel);
      if (version == null) {
        throw SdkNotInstalledException(
          'fvm does not know which version "${channel.token}" is: no '
          '${channel.token} SDK has been installed on this machine, and '
          'resolving a channel name never goes to the network. '
          'Run: fvm install ${channel.token}',
          version: channel.token,
        );
      }
      if (version != current) hops.add(version);
      return VersionRef(
        pin: pin,
        version: version,
        hops: hops,
        channel: channel,
      );
    }

    final alias = config.aliases[current];
    // Neither a channel nor an alias: it is a concrete version.
    if (alias == null) {
      return VersionRef(pin: pin, version: current, hops: hops);
    }
    current = alias;
    hops.add(alias);
  }

  throw ConfigException(
    'The alias "$pin" in ${context.display(context.paths.configFile.path)} '
    'goes through more than $maxAliasHops aliases without reaching a version. '
    'Point it straight at one: fvm alias $pin <version>',
  );
}

/// Installs [ref] if it is not already present, reporting what it is doing.
///
/// Returns after the SDK is genuinely usable: an installer that returns
/// without leaving a `bin/flutter` behind is a failure, not a success, and saying
/// so here is cheaper than the confusing error the next command would give.
Future<void> ensureInstalled(FvmContext context, VersionRef ref) async {
  if (context.installer.isInstalled(ref.version)) {
    await setupIfMissing(context);
    return;
  }

  context.out.writeln('Flutter ${ref.version} is not installed yet; '
      'installing it now.');
  await context.installer.install(ref.version, channel: ref.channel);

  if (!context.installer.isInstalled(ref.version)) {
    throw SdkNotInstalledException(
      'Installing Flutter ${ref.version} finished without leaving an SDK at '
      '${context.display(context.paths.versionDir(ref.version).path)}. '
      'Try again with: fvm install ${ref.version} --force',
      version: ref.version,
    );
  }
  await setupIfMissing(context);
}

/// Records [ref] as the machine-wide default in `~/.fvm/config.json`.
///
/// What gets stored is the concrete version, never the name that was typed.
/// `fvm global stable` means "default to the stable I have", not "follow
/// whatever stable becomes": a default that silently moves under you is the
/// exact failure a version manager exists to prevent. The trail is printed so
/// a user who meant the other thing can see what was recorded.
void writeGlobal(FvmContext context, VersionRef ref) {
  final config = context.config.read();
  final previous = config.global;
  context.config.write(config.copyWith(global: ref.version));

  final via = ref.isDirect ? '' : ' (${ref.trail})';
  context.out.writeln(
    'Flutter ${ref.version} is now the global default$via.',
  );
  if (previous != null && previous != ref.version) {
    context.out.writeln('  was: $previous');
  }
  context.out.writeln('  ${context.display(context.paths.configFile.path)}');
  context.out.writeln(
    'A directory with a .fvmrc still uses what its .fvmrc says.',
  );
}

/// Whether [name] would be read as a version rather than as a name.
///
/// Leading-digit rather than a full semver parse: the archive also carries
/// Flutter 1 build numbers like `29803`, and `3.9` is just as confusing as
/// `3.9.0` when it turns up where a version is expected.
bool looksLikeVersion(String name) => RegExp(r'^v?\d').hasMatch(name);

/// Whether adding `[name] -> [target]` to [aliases] would close a loop.
///
/// Checked before writing rather than after, because the config is read by the
/// hot resolution path on every `flutter` invocation: a cycle written here is a
/// cycle every command trips over until the user hand-edits the file.
bool wouldCycle(Map<String, String> aliases, String name, String target) {
  final merged = {...aliases, name: target};
  final seen = <String>{name};
  var current = target;

  for (var hop = 0; hop < maxAliasHops; hop++) {
    if (Channel.tryParse(current) != null) return false;
    final next = merged[current];
    if (next == null) return false;
    if (!seen.add(current)) return true;
    if (next == name) return true;
    current = next;
  }
  // Longer than the resolver will follow. Not literally a loop, but it fails
  // the same way, so refuse it the same way.
  return true;
}
