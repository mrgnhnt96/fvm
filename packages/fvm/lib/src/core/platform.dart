import 'exceptions.dart';

/// The `<os>` and `<arch>` tokens that appear in a flutter-archive filename.
///
/// Construct with [HostPlatform.detect] in production and with the constructor
/// in tests: the host is an input, not an ambient fact.
class HostPlatform {
  const HostPlatform({required this.os, required this.arch});

  /// `macos`, `linux` or `windows`.
  final String os;

  /// `x64` or `arm64`; availability is checked in the release manifest.
  final String arch;

  /// What the archive bucket publishes, per ARCHITECTURE.md.
  static const Map<String, Set<String>> publishedArchitectures = {
    'macos': {'x64', 'arm64'},
    'linux': {'x64', 'arm64'},
    'windows': {'x64', 'arm64'},
  };

  /// Whether an SDK archive exists for this combination.
  bool get isPublished => publishedArchitectures[os]?.contains(arch) ?? false;

  /// The host fvm is running on.
  ///
  /// [platformVersion] is `Platform.version`, whose tail is the only place
  /// dart:io exposes the architecture. Callers pass it in so this stays
  /// testable; `lib/fvm.dart` supplies the real one.
  factory HostPlatform.detect(String platformVersion) {
    final match = RegExp(r'on "([a-z0-9]+)_([a-z0-9]+)"').firstMatch(
      platformVersion,
    );
    if (match == null) {
      throw UnsupportedPlatformException(
        'Cannot tell what platform this is: the Dart version string '
        '"$platformVersion" does not end in the expected `on "<os>_<arch>"`.',
      );
    }
    return HostPlatform(
      os: match.group(1)!,
      // Dart reports compressed-pointer builds as `x64c` / `arm64c`. They run
      // the same archive as their uncompressed counterpart.
      arch: match.group(2)!.replaceFirst(RegExp(r'c$'), ''),
    );
  }

  /// Like [detect], but fails immediately on a host with no published SDK.
  factory HostPlatform.detectSupported(String platformVersion) {
    final platform = HostPlatform.detect(platformVersion);
    if (!platform.isPublished) {
      throw UnsupportedPlatformException(platform._unsupportedMessage());
    }
    return platform;
  }

  String _unsupportedMessage() {
    final supported = publishedArchitectures.entries
        .map((entry) => '${entry.key} ${entry.value.join('/')}')
        .join(', ');
    return 'Flutter does not publish an SDK for $os/$arch, so fvm cannot install '
        'one here. Published platforms are: $supported.';
  }

  @override
  String toString() => '$os-$arch';

  @override
  bool operator ==(Object other) =>
      other is HostPlatform && other.os == os && other.arch == arch;

  @override
  int get hashCode => Object.hash(os, arch);
}
