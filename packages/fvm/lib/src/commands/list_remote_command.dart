import 'package:args/command_runner.dart';

import '../core/channel.dart';
import '../core/context.dart';

/// `fvm list-remote` — List the releases available from the Flutter archive.
class ListRemoteCommand extends Command<int> {
  ListRemoteCommand({required this.context}) {
    argParser
      ..addOption(
        'channel',
        abbr: 'c',
        allowed: [for (final channel in Channel.values) channel.token],
        defaultsTo: Channel.stable.token,
        help: 'Which release channel to list.',
      )
      ..addFlag(
        'all',
        negatable: false,
        help: 'Show every release instead of the newest $_defaultLimit.',
      );
  }

  final FvmContext context;

  @override
  String get name => 'list-remote';

  @override
  String get description =>
      'List the releases available from the Flutter archive.';

  /// Stable alone carries ~177 releases; a full dump buries the ones anybody
  /// is about to install.
  static const int _defaultLimit = 25;

  @override
  Future<int> run() async {
    final channel = Channel.tryParse(argResults!.option('channel')!)!;
    final all = argResults!.flag('all');

    final releases = await context.releases.listReleases(channel);
    if (releases.isEmpty) {
      context.out.writeln('The archive lists no ${channel.token} releases.');
      return 0;
    }

    final shown = all || releases.length <= _defaultLimit
        ? releases
        : releases.take(_defaultLimit).toList();

    for (final version in shown) {
      final installed = context.installer.isInstalled(version);
      context.out.writeln('  $version${installed ? '  (installed)' : ''}');
    }

    if (shown.length < releases.length) {
      context.out.writeln(
        '\nShowing the newest ${shown.length} of ${releases.length} '
        '${channel.token} releases. Pass --all to see them all.',
      );
    }
    return 0;
  }
}
