import 'dart:async';

import '../archive/flutter_archive_client.dart';
import 'channel.dart';
import 'platform.dart';
import 'verbose.dart';

/// A downloadable SDK archive and the checksum that proves it arrived intact.
class ReleaseArtifact {
  const ReleaseArtifact({
    required this.version,
    required this.fileName,
    required this.archive,
    required this.checksum,
    this.sha256,
  });

  /// The concrete version this artifact contains.
  final String version;

  /// The archive's filename, e.g. `flutter_macos_arm64_3.44.0-stable.zip`. It is
  /// also the name that appears in the checksum body, which is `<hex> *<name>`.
  final String fileName;

  /// Where to download the archive from.
  final Uri archive;

  /// The sibling `.sha256sum`.
  final Uri checksum;

  /// SHA-256 from the official Flutter release manifest.
  final String? sha256;
}

/// fvm's view of the official Flutter release manifests.
///
/// This is the only seam allowed to touch the network, and it is deliberately
/// not reachable from `resolver.dart`. Implementations live outside `core/`.
abstract class ReleaseClient {
  /// Concrete semver releases published in [channel], newest first.
  ///
  /// Entries without a concrete semantic version are filtered out.
  Future<List<String>> listReleases(Channel channel);

  /// The concrete version [channel] currently points at.
  ///
  /// Called only by `install` and `upgrade`. Version resolution must never
  /// call this: it reads the version the channel resolved to at install time
  /// out of `config.json` instead.
  Future<String> latestVersion(Channel channel);

  /// The first channel that publishes [version], probing stable, beta, dev.
  ///
  /// A version can exist in more than one channel, which is why a bare version
  /// string needs a lookup before its download URL can be built.
  Future<Channel> channelFor(String version);

  /// The download URL and checksum for [version] on [platform].
  ///
  /// Implementations may fetch a platform release manifest.
  FutureOr<ReleaseArtifact> artifactFor({
    required Channel channel,
    required String version,
    required HostPlatform platform,
  });
}

/// The seam `lib/fvm.dart` calls to get a [ReleaseClient].
///
/// The archive client is built by its own part of the CLI; this is the one
/// line that names it, so `lib/fvm.dart` never has to.
ReleaseClient createReleaseClient({VerboseLog? verbose}) =>
    FlutterArchiveClient(verbose: verbose);
