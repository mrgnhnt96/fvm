/// The three release channels the flutter-archive bucket publishes.
///
/// This lives in its own file rather than in `releases.dart` so that
/// `resolver.dart` can name a channel without importing anything that is
/// allowed to reach the network.
enum Channel {
  stable,
  beta,
  dev;

  /// The token used in archive URLs and in `config.json`. Same as [name].
  String get token => name;

  /// [Channel] for [value], or null if it is a version or an alias instead.
  static Channel? tryParse(String value) {
    for (final channel in Channel.values) {
      if (channel.token == value) return channel;
    }
    return null;
  }

  /// The order to probe when a bare version string could live in any channel.
  static const List<Channel> probeOrder = [
    Channel.stable,
    Channel.beta,
    Channel.dev,
  ];
}
