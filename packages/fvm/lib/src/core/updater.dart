import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:file/file.dart';
import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart';

import '../archive/sdk_extractor.dart';
import '../gen/version.dart';
import 'exceptions.dart';
import 'paths.dart';
import 'platform.dart';

/// The GitHub repository fvm publishes its own releases from.
const String releaseRepository = 'mrgnhnt96/fvm';

/// The name of the release asset carrying the binary for [platform].
///
/// **THIS IS A CONTRACT, NOT A DETAIL.** Three places construct this name and
/// they must agree forever: this function, `install.sh`, and
/// `tool/package_release_assets.sh` (which is what actually creates the file).
/// Renaming an asset breaks `fvm update` for every copy already installed —
/// those binaries are already compiled with the old name in them and cannot be
/// told otherwise. See ARCHITECTURE.md, "Distribution".
///
/// Throws [UnsupportedPlatformException] for a host fvm has no build for. Note
/// that this is a *narrower* set than [HostPlatform.publishedArchitectures]:
/// Flutter publishes an SDK for linux/arm and linux/riscv64, fvm does not publish
/// a binary for them, so such a host can run fvm built from source but cannot
/// install or update it from a release.
String releaseAssetName(HostPlatform platform) {
  const supported = {
    'linux-x64',
    'linux-arm64',
    'macos-x64',
    'macos-arm64',
    'windows-x64',
  };
  final target = '${platform.os}-${platform.arch}';
  if (!supported.contains(target)) {
    throw UnsupportedPlatformException(
      'fvm does not publish a binary for $target. Released binaries are: '
      '${supported.join(', ')}. You can still build fvm from source with '
      '`dart compile exe bin/fvm.dart`.',
    );
  }
  return 'fvm-$target.zip';
}

/// The sha256 published beside [assetName]. Its body is `<hex>  <filename>`,
/// the format `sha256sum` and `shasum -a 256` both write and read.
String checksumAssetName(String assetName) => '$assetName.sha256';

/// The bare executable inside a release asset.
String executableNameFor(HostPlatform platform) =>
    platform.os == 'windows' ? 'fvm.exe' : 'fvm';

/// Something went wrong updating fvm itself.
class UpdateException extends FvmException {
  const UpdateException(super.message);
}

/// One published fvm release, reduced to what the updater needs.
class FvmRelease {
  const FvmRelease({
    required this.tag,
    required this.version,
    required this.assets,
  });

  /// The git tag, e.g. `v0.2.0`.
  final String tag;

  /// [tag] without its leading `v`, e.g. `0.2.0`.
  final String version;

  /// Asset name -> where to download it from.
  final Map<String, Uri> assets;

  /// The download URL for [name], or null if this release does not carry it.
  Uri? assetUrl(String name) => assets[name];
}

/// What an update run concluded.
enum UpdateStatus {
  /// Already on what was asked for. Nothing was touched.
  upToDate,

  /// Something to install was found and deliberately not installed — `--check`.
  available,

  /// The binary on disk was replaced.
  installed,
}

/// What [Updater.update] did.
class UpdateOutcome {
  const UpdateOutcome({
    required this.from,
    required this.to,
    required this.status,
  });

  /// The version that was running.
  final String from;

  /// The version that was resolved.
  final String to;

  final UpdateStatus status;

  /// Whether the binary on disk was replaced. False for `--check` and for an
  /// update that turned out to be a no-op.
  bool get installed => status == UpdateStatus.installed;

  bool get isUpToDate => status == UpdateStatus.upToDate;
}

/// fvm's view of its own GitHub releases: what is newest, and how to become it.
///
/// Modelled on zonai's `Versions` (`apps/zonai/lib/src/domain/versions.dart`),
/// which is the same job in a shipped tool. The deliberate differences are
/// commented where they occur; the biggest is that this one verifies the
/// asset's published sha256 before writing anything.
class Updater {
  Updater({
    required this.fileSystem,
    required HostPlatform Function() hostPlatform,
    required Map<String, String> environment,
    this.isCompiled = kIsCompiled,
    this.currentVersion = kVersion,
    http.Client? httpClient,
    Uri? apiBase,
    ModeApplier? modeApplier,
  })  : _hostPlatform = hostPlatform,
        _environment = environment,
        _injectedHttp = httpClient,
        _apiBase = apiBase ?? defaultApiBase,
        _modeApplier = modeApplier ?? const ChmodModeApplier();

  /// The GitHub API root for [releaseRepository]. Trailing slash on purpose so
  /// `resolve('releases')` appends rather than replaces the last segment.
  static final Uri defaultApiBase =
      Uri.parse('https://api.github.com/repos/$releaseRepository/');

  final FileSystem fileSystem;

  /// Whether this is a release build. Everything that touches the network or
  /// the installed binary refuses when it is false — see [kIsCompiled].
  final bool isCompiled;

  /// The version this build reports, normally [kVersion].
  final String currentVersion;

  final HostPlatform Function() _hostPlatform;
  final Map<String, String> _environment;
  final http.Client? _injectedHttp;
  final Uri _apiBase;
  final ModeApplier _modeApplier;

  /// Built on first use, never at construction: `FvmContext.wire` makes an
  /// [Updater] on every single `fvm` invocation, including the `fvm exec flutter`
  /// that the PATH shim runs, and that path is not allowed to pay for
  /// anything it does not use.
  late final http.Client _http = _injectedHttp ?? http.Client();

  /// Releases newest-first, matching what a `fvm update` would install.
  ///
  /// **Not `/releases/latest`.** GitHub's "latest" is simply the newest
  /// non-draft non-prerelease release of *any* kind, so the day this repo
  /// publishes a release for something other than the CLI, "latest" becomes a
  /// release with no `fvm-<os>-<arch>.zip` in it — the update check then
  /// reports a new version that `fvm update` cannot install. That is not
  /// hypothetical: it happened to zonai on 2026-08-10 (see the comment on its
  /// `_fetchLatestRelease`). Scanning instead, and requiring *this platform's
  /// asset to actually be present*, makes the answer true by construction.
  Future<FvmRelease> latestRelease() async {
    final assetName = releaseAssetName(_hostPlatform());
    final body = await _getJson(_apiBase.resolve('releases?per_page=100'));
    if (body is! List) {
      throw const UpdateException(
        'GitHub did not return a list of releases for fvm.',
      );
    }

    for (final entry in body) {
      final release = _parseRelease(entry);
      if (release == null) continue;
      if (release.assetUrl(assetName) == null) continue;
      return release;
    }

    throw UpdateException(
      'No published fvm release carries a $assetName. Looked at the '
      '${body.length} most recent releases of $releaseRepository.',
    );
  }

  /// The release tagged `v[version]`, whatever its position in the list.
  Future<FvmRelease> releaseForVersion(String version) async {
    final tag = version.startsWith('v') ? version : 'v$version';
    final body = await _getJson(_apiBase.resolve('releases/tags/$tag'));
    final release = _parseRelease(body, allowPrerelease: true);
    if (release == null) {
      throw UpdateException('$releaseRepository has no release tagged $tag.');
    }
    return release;
  }

  /// Whether [candidate] is a later release than the one running.
  ///
  /// Semver, not string comparison: `0.13.0` is newer than `0.9.0` and sorts
  /// below it as text. A development build (`0.1.0-dev`) is older than the
  /// release of the same number, which is what makes the notice fire the first
  /// time a real `0.1.0` is published.
  bool isNewerThanCurrent(String candidate) {
    try {
      return Version.parse(candidate) > Version.parse(currentVersion);
    } on FormatException {
      // A tag neither side can parse is not evidence of anything.
      return false;
    }
  }

  /// Downloads and installs a fvm release over [executablePath].
  ///
  /// With [check] the release is only resolved and reported — nothing is
  /// downloaded and nothing on disk is touched. [version] pins an explicit
  /// release instead of taking the newest one, which is how a user gets back
  /// off a bad release.
  Future<UpdateOutcome> update({
    required String executablePath,
    String? version,
    bool check = false,
  }) async {
    if (!isCompiled) {
      throw const UpdateException(
        'fvm is running from source, so there is no installed binary to '
        'replace. Update the checkout with git instead.',
      );
    }

    final release = version == null
        ? await latestRelease()
        : await releaseForVersion(version);

    // An explicit version is allowed to go backwards; the automatic path is
    // not. Someone typing `fvm update 0.1.4` after a bad 0.1.5 means it.
    if (release.version == currentVersion) {
      return UpdateOutcome(
        from: currentVersion,
        to: release.version,
        status: UpdateStatus.upToDate,
      );
    }
    if (check) {
      return UpdateOutcome(
        from: currentVersion,
        to: release.version,
        status: UpdateStatus.available,
      );
    }

    await _installRelease(release: release, executablePath: executablePath);

    return UpdateOutcome(
      from: currentVersion,
      to: release.version,
      status: UpdateStatus.installed,
    );
  }

  /// Downloads [release]'s asset for this platform, verifies its published
  /// sha256, and puts it in place.
  Future<void> _installRelease({
    required FvmRelease release,
    required String executablePath,
  }) async {
    final platform = _hostPlatform();
    final assetName = releaseAssetName(platform);
    final assetUrl = release.assetUrl(assetName);
    if (assetUrl == null) {
      throw UpdateException(
        'Release ${release.tag} has no $assetName, so there is no fvm binary '
        'in it for ${platform.os}-${platform.arch}.',
      );
    }

    final expected = await _publishedChecksum(release, assetName);
    final bytes = await _download(assetUrl, assetName);

    final actual = sha256.convert(bytes).toString();
    if (actual != expected) {
      // Nothing has been written at this point, and nothing will be. Say so:
      // the one thing a user needs to know here is that their working fvm is
      // still their working fvm.
      throw UpdateException(
        'The download of $assetName does not match the sha256 published with '
        'it.\n'
        '  expected: $expected\n'
        '  actual:   $actual\n'
        'fvm was NOT updated and the binary you are running is untouched. '
        'This is either a corrupted download or a tampered-with asset.',
      );
    }

    await _install(
      executablePath: executablePath,
      zipBytes: bytes,
      platform: platform,
    );
  }

  /// Releases the HTTP client. Safe to call when nothing was ever fetched.
  ///
  /// `IOClient.close()` closes the underlying `HttpClient` with `force: true`,
  /// which aborts in-flight requests instead of waiting for them. That is
  /// exactly what [VersionCheck] needs: without it, a hung request would keep
  /// the VM alive after the command it was checking for had finished.
  void close() {
    if (_injectedHttp != null) return;
    _http.close();
  }

  /// The sha256 published as a sibling asset.
  ///
  /// zonai does not do this at all — it trusts the TLS connection to GitHub.
  /// A version manager replaces the binary that every `flutter` invocation on the
  /// machine goes through, so the extra round trip buys enough: the checksum
  /// is generated on the runner beside the binary and a mismatch means the two
  /// assets did not come from the same build.
  Future<String> _publishedChecksum(
    FvmRelease release,
    String assetName,
  ) async {
    final name = checksumAssetName(assetName);
    final url = release.assetUrl(name);
    if (url == null) {
      throw UpdateException(
        'Release ${release.tag} has no $name, so the download of $assetName '
        'cannot be verified. Refusing to install it.',
      );
    }

    final body = utf8.decode(await _download(url, name));
    final parts = body.trim().split(RegExp(r'\s+'));
    if (parts.length < 2 || !RegExp(r'^[0-9a-f]{64}$').hasMatch(parts.first)) {
      throw UpdateException(
        '$name is not in the expected `<hex>  <filename>` form, so fvm '
        'cannot verify the download.',
      );
    }
    // A checksum naming a different asset would otherwise fail below as a
    // mismatch, which reads like corruption rather than a broken release.
    final named = parts[1].replaceFirst(RegExp(r'^\*'), '');
    if (named != assetName) {
      throw UpdateException(
        '$name is a checksum for "$named", not for "$assetName".',
      );
    }
    return parts.first;
  }

  /// Replaces the binary at [executablePath] with the one inside [zipBytes].
  Future<void> _install({
    required String executablePath,
    required Uint8List zipBytes,
    required HostPlatform platform,
  }) async {
    final entry = _executableEntry(zipBytes, platform);

    final executable = fileSystem.file(executablePath);
    final directory = executable.parent;
    final base = fileSystem.path.basename(executablePath);
    final incoming = fileSystem.file(
      fileSystem.path.join(directory.path, '$base.new'),
    );

    incoming.writeAsBytesSync(entry, flush: true);
    // Before the rename, so that whatever lands at [executablePath] is
    // runnable the instant it is there. Windows has no unix modes; there
    // executability comes from the extension.
    if (platform.os != 'windows') {
      await _modeApplier.apply({incoming.path: 0x1ED});
    }

    if (platform.os == 'windows') {
      await _installWindows(executable, incoming, directory, base);
      return;
    }

    // On POSIX this is all it takes, and the reason is the inode: `rename`
    // unlinks the old directory entry but the running process still holds the
    // old inode open, so replacing the binary underneath a running fvm is
    // safe. zonai renames the old one aside first as well; that only leaves a
    // `.old` file behind for nobody to clean up.
    incoming.renameSync(executable.path);
  }

  /// The Windows half of [_install].
  ///
  /// Windows refuses to *delete or overwrite* a running `.exe`, but it will
  /// happily *rename* one — the file stays mapped under its new name. So the
  /// running binary is moved aside and the new one takes its place; the
  /// leftover is deleted on a later run, once nothing has it open.
  Future<void> _installWindows(
    File executable,
    File incoming,
    Directory directory,
    String base,
  ) async {
    final aside = fileSystem.file(
      fileSystem.path.join(directory.path, '$base.old'),
    );

    // A leftover from the previous update. It is deletable now precisely
    // because the process that was running it has exited.
    if (aside.existsSync()) {
      try {
        aside.deleteSync();
      } on FileSystemException {
        // Still held by something. Not fatal: the rename below overwrites it.
      }
    }

    try {
      if (executable.existsSync()) executable.renameSync(aside.path);
      incoming.renameSync(executable.path);
    } on FileSystemException catch (error) {
      // Loudly, and with the old binary's whereabouts, rather than leaving
      // someone with a version manager that is half-installed.
      throw UpdateException(
        'Could not replace ${executable.path}: ${error.osError?.message ?? error.message}.\n'
        'The new binary is at ${incoming.path} and the previous one may be at '
        '${aside.path}. Close any running fvm and move it into place by hand.',
      );
    }
  }

  /// The fvm executable inside a release zip.
  Uint8List _executableEntry(Uint8List zipBytes, HostPlatform platform) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zipBytes);
    } on Object catch (error) {
      throw UpdateException('The release asset is not a readable zip: $error');
    }

    final wanted = executableNameFor(platform);
    for (final file in archive) {
      if (!file.isFile) continue;
      // Basename: the asset is flat by construction (see
      // tool/package_release_assets.sh), and taking the basename anyway stops
      // a nested entry from deciding where anything goes.
      if (fileSystem.path.basename(file.name) != wanted) continue;
      final bytes = file.readBytes();
      if (bytes == null || bytes.isEmpty) break;
      return Uint8List.fromList(bytes);
    }

    throw UpdateException(
      'The release asset does not contain a $wanted, so there is nothing to '
      'install from it.',
    );
  }

  Future<Uint8List> _download(Uri url, String what) async {
    final http.Response response;
    try {
      response = await _http.get(url, headers: _headers);
    } on http.ClientException catch (error) {
      throw UpdateException('Could not download $what: ${error.message}');
    }
    if (response.statusCode != 200) {
      throw UpdateException(
        'GitHub returned HTTP ${response.statusCode} for $what ($url).',
      );
    }
    return response.bodyBytes;
  }

  Future<Object?> _getJson(Uri url) async {
    final http.Response response;
    try {
      response = await _http.get(url, headers: _headers);
    } on http.ClientException catch (error) {
      throw UpdateException('Could not reach $url: ${error.message}');
    }
    if (response.statusCode != 200) {
      throw UpdateException(
        'GitHub returned HTTP ${response.statusCode} for $url.'
        '${response.statusCode == 403 ? ' This is usually the unauthenticated '
            'rate limit; set GITHUB_TOKEN and try again.' : ''}',
      );
    }
    try {
      return json.decode(response.body);
    } on FormatException catch (error) {
      throw UpdateException('$url did not return JSON: ${error.message}');
    }
  }

  /// A token is optional — fvm's repo is public. It is used when present
  /// because the unauthenticated API allows only 60 requests an hour per IP,
  /// which CI shares across every job on the runner.
  Map<String, String> get _headers {
    final token = _environment['GITHUB_TOKEN'] ?? _environment['GH_TOKEN'];
    return {
      'Accept': 'application/vnd.github+json',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  /// A release object from the API, or null when it is not a fvm CLI release.
  FvmRelease? _parseRelease(Object? entry, {bool allowPrerelease = false}) {
    if (entry is! Map<String, Object?>) return null;
    if (!allowPrerelease &&
        (entry['draft'] == true || entry['prerelease'] == true)) {
      return null;
    }

    final tag = entry['tag_name'];
    if (tag is! String) return null;
    if (!RegExp(r'^v\d+\.\d+\.\d+').hasMatch(tag)) return null;

    final assets = <String, Uri>{};
    final listed = entry['assets'];
    if (listed is List) {
      for (final asset in listed) {
        if (asset is! Map<String, Object?>) continue;
        final name = asset['name'];
        final url = asset['browser_download_url'] ?? asset['url'];
        if (name is! String || url is! String) continue;
        assets[name] = Uri.parse(url);
      }
    }

    return FvmRelease(
      tag: tag,
      version: tag.substring(1),
      assets: assets,
    );
  }
}

/// The one-line "a newer fvm exists" notice ordinary commands print.
///
/// The hard requirement is that this NEVER blocks, slows or fails a command:
/// `fvm flutter test` runs through the PATH shim on every keystroke-driven
/// rebuild, and a version notice that costs a network round trip there would
/// be a latency bug, not a feature. Three things make that true:
///
///  * a cache, so the network is touched at most once per [cacheTtl];
///  * [start] fires the request *beside* the command instead of before it, so
///    a slow command absorbs the check entirely;
///  * [report] waits only [reportBudget] for an answer and then closes the
///    client outright, so a hung request cannot delay the process exiting.
///
/// Every failure is swallowed. Being unable to check is not news.
class VersionCheck {
  VersionCheck({
    required this.updater,
    required this.paths,
    required this.out,
    this.enabled = true,
    this.cacheTtl = const Duration(hours: 24),
    this.networkTimeout = const Duration(milliseconds: 1500),
    this.reportBudget = const Duration(milliseconds: 400),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Updater updater;
  final FvmPaths paths;
  final StringSink out;

  /// False when `--no-version-check` was passed.
  final bool enabled;

  /// How long a recorded answer is reused before the network is consulted.
  /// A day-old notice is still a useful notice; a per-invocation round trip
  /// is not an acceptable price for a fresher one.
  final Duration cacheTtl;

  final Duration networkTimeout;
  final Duration reportBudget;
  final DateTime Function() _now;

  Future<String?>? _pending;

  /// The recorded answer, written even when the check failed so that an
  /// offline machine does not retry on every invocation.
  File get cacheFile => paths.fileSystem.file(paths.fileSystem.path.join(
        paths.cacheDir.path,
        'update-check.json',
      ));

  /// Begins the check. Returns immediately; nothing is awaited here.
  void start() {
    if (!enabled || !updater.isCompiled) return;
    _pending = _check().timeout(networkTimeout, onTimeout: () => null);
  }

  /// Prints the notice if an answer arrived in time. Never throws.
  Future<void> report() async {
    final pending = _pending;
    if (pending == null) return;

    // `timeout`, not a race against `Future.delayed`. Both give up after the
    // budget, but the delayed future stays pending when it LOSES, and a live
    // timer keeps the VM alive until it fires — measured at +0.4s on every
    // invocation, including cache hits that answered instantly. `timeout`
    // cancels its timer the moment the future completes.
    final latest = await pending.timeout(reportBudget, onTimeout: () => null);
    // Unconditional, and force-closing: if the budget expired, the request is
    // still in flight and would otherwise hold the process open on its own.
    updater.close();

    if (latest == null) return;
    out.writeln(
      'A new version of fvm is available: ${updater.currentVersion} -> '
      '$latest. Run `fvm update` to install it.',
    );
  }

  /// The newer version, or null for "no news, or could not tell".
  ///
  /// The cache records the newest PUBLISHED version rather than the verdict,
  /// so the comparison happens fresh every time. Storing the verdict instead
  /// would keep announcing an update for a day after it was installed.
  Future<String?> _check() async {
    try {
      final String? latest;
      // A fresh entry answers even when its answer is "the check failed":
      // that is what stops an offline machine retrying on every invocation.
      if (_readCache() case final cached?) {
        latest = cached.value;
      } else {
        // Stamped BEFORE the request, not only after it. [report] gives up
        // after [reportBudget] and the process then exits with the request
        // still in flight, so an answer that arrives late is never recorded —
        // and without this line a machine on a slow link pays the budget on
        // every single invocation, forever. Recording the attempt first caps
        // that at one invocation per TTL. A fast answer overwrites it below.
        _writeCache(null);
        latest = (await updater.latestRelease()).version;
        _writeCache(latest);
      }

      if (latest == null) return null;
      return updater.isNewerThanCurrent(latest) ? latest : null;
    } on Object {
      // Deliberately everything, including [FvmException] and whatever the
      // socket layer throws. A failed check is not an event a user asked for.
      try {
        _writeCache(null);
      } on Object {
        // A read-only or missing cache directory is not news either.
      }
      return null;
    }
  }

  _CachedAnswer? _readCache() {
    final file = cacheFile;
    if (!file.existsSync()) return null;

    final decoded = json.decode(file.readAsStringSync());
    if (decoded is! Map<String, Object?>) return null;

    final checkedAt = decoded['checkedAt'];
    if (checkedAt is! int) return null;
    final age = _now().difference(
      DateTime.fromMillisecondsSinceEpoch(checkedAt),
    );
    // A negative age means the clock moved backwards; treat it as stale
    // rather than trusting a stamp from the future forever.
    if (age.isNegative || age > cacheTtl) return null;

    final latest = decoded['latest'];
    // `null` is a recorded failure: fresh enough not to retry, but with no
    // answer in it, so the caller treats it as a miss with no network.
    return latest is String ? _CachedAnswer(latest) : const _CachedAnswer(null);
  }

  void _writeCache(String? latest) {
    // ~/.fvm/cache is documented as safe to delete at any time, which is
    // exactly the right home for this: losing it costs one extra request.
    paths.cacheDir.createSync(recursive: true);
    cacheFile.writeAsStringSync(
      json.encode({
        'checkedAt': _now().millisecondsSinceEpoch,
        'latest': latest,
      }),
    );
  }
}

class _CachedAnswer {
  const _CachedAnswer(this.value);

  /// The newer version recorded last time, or null for "there was none".
  final String? value;
}
