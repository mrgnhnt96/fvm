import 'dart:async';
import 'dart:convert';

import 'package:file/file.dart';
import 'package:fvm/fvm.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late CommandHarness harness;
  late FakeProcesses processes;

  /// The other fvm's default cache, under the harness's HOME.
  const otherCache = '/home/dev/fvm';

  setUp(() {
    harness = CommandHarness();
    processes = FakeProcesses();
    harness
      ..processes = processes
      ..releases = FakeReleases();
  });

  void write(String path, String contents) => harness.fileSystem.file(path)
    ..createSync(recursive: true)
    ..writeAsStringSync(contents);

  String read(String path) => harness.fileSystem.file(path).readAsStringSync();

  bool exists(String path) =>
      harness.fileSystem.typeSync(path, followLinks: false) !=
      FileSystemEntityType.notFound;

  /// A project the way the other fvm leaves one after `fvm use 3.19.0`.
  void otherFvmProject(
    String path, {
    String pin = '3.19.0',
    Map<String, Object?> extra = const {},
  }) {
    write(
      '$path/.fvmrc',
      jsonEncode({'flutter': pin, ...extra}),
    );
    write('$path/.fvm/release', pin);
    write('$path/.fvm/version', pin);
    harness.fileSystem.directory('$otherCache/versions/$pin').createSync(
          recursive: true,
        );
    harness.fileSystem
        .link('$path/.fvm/versions/$pin')
        .createSync('$otherCache/versions/$pin', recursive: true);
    harness.fileSystem
        .link('$path/.fvm/flutter_sdk')
        .createSync('$otherCache/versions/$pin');
  }

  void registry(List<String> projects) => write(
        '$otherCache/projects.json',
        jsonEncode({'schemaVersion': 1, 'projects': projects}),
      );

  void scriptInstall() => write('$otherCache/bin/fvm', 'their binary');

  group('a project', () {
    test('moves the pin over and drops what has no equivalent', () async {
      otherFvmProject('/project', extra: {
        'flavors': {'prod': '3.16.0', 'dev': '3.19.0'},
        'updateVscodeSettings': true,
      });
      write(
        '/project/.vscode/settings.json',
        '{\n  "dart.flutterSdkPath": ".fvm/versions/3.19.0"\n}\n',
      );

      expect(await harness.run(['migrate']), 0);

      expect(harness.readFvmrc(), '{\n  "flutter": "3.19.0"\n}\n');
      expect(
        harness.fileSystem.link('/project/.fvm/flutter_sdk').targetSync(),
        '/fvm/versions/3.19.0',
      );
      expect(harness.installer.requests.single.version, '3.19.0');
      for (final leftover in ['release', 'version', 'versions']) {
        expect(exists('/project/.fvm/$leftover'), isFalse, reason: leftover);
      }
      expect(
        read('/project/.vscode/settings.json'),
        contains('".fvm/flutter_sdk"'),
      );
      expect(harness.output, contains('Migrated /project to Flutter 3.19.0'));
      expect(harness.output, contains('Removed flavors prod, dev'));
      expect(harness.output, contains('updateVscodeSettings'));
    });

    test('reads the pre-3.0 .fvm/fvm_config.json', () async {
      write(
        '/project/.fvm/fvm_config.json',
        jsonEncode({'flutterSdkVersion': '3.10.0'}),
      );

      expect(await harness.run(['migrate']), 0);

      expect(harness.readFvmrc(), '{\n  "flutter": "3.10.0"\n}\n');
      expect(exists('/project/.fvm/fvm_config.json'), isFalse);
    });

    test('turns release@channel into the release', () async {
      otherFvmProject('/project', pin: '3.20.0-1.2.pre@beta');

      expect(await harness.run(['migrate']), 0);

      expect(harness.readFvmrc(), contains('"3.20.0-1.2.pre"'));
      expect(harness.installer.requests.single.channel, Channel.beta);
    });

    test('pins a channel to the release it points at now', () async {
      otherFvmProject('/project', pin: 'stable');

      expect(await harness.run(['migrate']), 0);

      expect(harness.readFvmrc(), contains('"3.44.0"'));
      expect(harness.readConfig().channels, {'stable': '3.44.0'});
      expect(harness.output, contains('(was "stable")'));
    });

    test('leaves a fork untouched and says why', () async {
      // Only the .fvmrc: a fork pin must be reported even when nothing else
      // marks the project as the other fvm's.
      write('/project/.fvmrc', jsonEncode({'flutter': 'myfork/3.19.0'}));
      final before = harness.readFvmrc();

      expect(await harness.run(['migrate']), 0);

      expect(harness.readFvmrc(), before);
      expect(harness.installer.requests, isEmpty);
      expect(harness.output, contains('it is a fork'));
    });

    test('skips a project that already uses this fvm', () async {
      write('/project/.fvmrc', '{\n  "flutter": "3.19.0"\n}\n');

      expect(await harness.run(['migrate']), 0);

      expect(harness.output, contains('already works with this fvm'));
      expect(harness.installer.requests, isEmpty);
    });

    test('migrates every project in the registry', () async {
      otherFvmProject('/work/a');
      otherFvmProject('/work/b');
      registry(['/work/a', '/work/b', '/work/gone']);

      expect(await harness.run(['migrate']), 0);

      expect(harness.readFvmrc('/work/a/.fvmrc'), contains('"3.19.0"'));
      expect(harness.readFvmrc('/work/b/.fvmrc'), contains('"3.19.0"'));
      // One install for two projects on the same version.
      expect(harness.installer.requests, hasLength(1));
    });
  });

  group('the global version', () {
    setUp(() {
      harness.fileSystem.directory('$otherCache/versions/3.16.0').createSync(
            recursive: true,
          );
      harness.fileSystem
          .link('$otherCache/default')
          .createSync('$otherCache/versions/3.16.0');
    });

    test('becomes this fvm global when none is set', () async {
      expect(await harness.run(['migrate']), 0);

      expect(harness.readConfig().global, '3.16.0');
    });

    test('says nothing when it is already the same', () async {
      harness.writeConfig(const FvmConfig(global: '3.16.0'));

      expect(await harness.run(['migrate']), 0);

      expect(harness.output, isNot(contains('global')));
    });

    test('never replaces one that is already set', () async {
      harness.writeConfig(const FvmConfig(global: '3.13.2'));

      expect(await harness.run(['migrate']), 0);

      expect(harness.readConfig().global, '3.13.2');
      expect(harness.output, contains('Kept your global version 3.13.2'));
    });
  });

  group('uninstalling', () {
    test('asks nothing and changes nothing without a terminal', () async {
      scriptInstall();

      expect(await harness.run(['migrate']), 0);

      expect(exists('$otherCache/bin/fvm'), isTrue);
      expect(harness.output, contains('Kept leoafarias/fvm'));
      expect(harness.output, contains('--uninstall'));
    });

    test('--uninstall removes a script install and keeps its SDKs', () async {
      scriptInstall();
      harness.fileSystem.directory('$otherCache/versions/3.19.0').createSync(
            recursive: true,
          );

      expect(await harness.run(['migrate', '--uninstall']), 0);

      expect(exists('$otherCache/bin'), isFalse);
      expect(exists('$otherCache/versions/3.19.0'), isTrue);
      expect(harness.output, contains('SDKs are still in $otherCache'));
    });

    test('runs brew for a Homebrew install', () async {
      harness.fileSystem
          .directory('/opt/homebrew/Cellar/fvm/4.0.0/bin')
          .createSync(recursive: true);
      harness.fileSystem.link('/opt/homebrew/bin/fvm').createSync(
            '/opt/homebrew/Cellar/fvm/4.0.0/bin/fvm',
            recursive: true,
          );

      expect(await harness.run(['migrate', '--uninstall']), 0);

      expect(processes.calls, [
        ['brew', 'uninstall', 'fvm'],
      ]);
    });

    test('reports a failed uninstall command', () async {
      write('/home/dev/.pub-cache/global_packages/fvm/pubspec.lock', '');
      processes.exitCode = 1;

      expect(await harness.run(['migrate', '--uninstall']), 1);

      expect(harness.errors, contains('dart pub global deactivate fvm'));
    });

    test('asks at a terminal, and takes no for an answer', () async {
      scriptInstall();
      final prompter = FakePrompter([false]);
      harness.prompter = prompter;

      expect(await harness.run(['migrate']), 0);

      expect(prompter.questions.single, contains('Uninstall leoafarias/fvm'));
      expect(exists('$otherCache/bin/fvm'), isTrue);
    });

    test('points out startup lines left behind', () async {
      scriptInstall();
      write('/home/dev/.zshrc', 'export PATH="\$HOME/fvm/bin:\$PATH"\n');

      expect(await harness.run(['migrate', '--uninstall']), 0);

      expect(harness.output, contains('/home/dev/.zshrc:1'));
    });
  });

  test('--dry-run changes nothing', () async {
    otherFvmProject('/project');
    scriptInstall();
    final before = harness.readFvmrc();

    expect(await harness.run(['migrate', '--dry-run']), 0);

    expect(harness.readFvmrc(), before);
    expect(harness.installer.requests, isEmpty);
    expect(exists('$otherCache/bin/fvm'), isTrue);
    expect(exists('/project/.fvm/release'), isTrue);
    expect(harness.output, contains('Would migrate /project'));
    expect(harness.output, contains('Would uninstall leoafarias/fvm'));
  });

  test('says so when there is nothing to migrate', () async {
    expect(await harness.run(['migrate']), 0);

    expect(harness.output, contains('Nothing to migrate'));
  });

  group('after setup', () {
    setUp(() {
      harness.environment['SHELL'] = '/bin/zsh';
      write('/usr/local/bin/ours', 'a compiled binary');
      otherFvmProject('/work/app');
      registry(['/work/app']);
      scriptInstall();
    });

    test('points at fvm migrate without a terminal', () async {
      expect(
        await harness.run(['setup', '--fvm-path', '/usr/local/bin/ours']),
        0,
      );

      expect(harness.output, contains('leoafarias/fvm is also on this'));
      expect(harness.output, contains('fvm migrate'));
      expect(harness.installer.requests, isEmpty);
    });

    test('migrates and uninstalls when the user says yes', () async {
      final prompter = FakePrompter([true, true]);
      harness.prompter = prompter;

      expect(
        await harness.run(['setup', '--fvm-path', '/usr/local/bin/ours']),
        0,
      );

      expect(prompter.questions, hasLength(2));
      expect(harness.readFvmrc('/work/app/.fvmrc'), contains('"3.19.0"'));
      expect(exists('$otherCache/bin'), isFalse);
    });
  });
}

/// Answers prompts from a script, and records what was asked.
class FakePrompter extends Prompter {
  FakePrompter(this.answers);

  final List<bool> answers;
  final List<String> questions = [];

  @override
  bool get isInteractive => true;

  @override
  bool confirm(String question, {required bool defaultValue}) {
    questions.add(question);
    return answers.removeAt(0);
  }
}

/// Records commands instead of running them.
class FakeProcesses implements ProcessRunner {
  final List<List<String>> calls = [];
  int exitCode = 0;

  @override
  Future<int> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    String? workingDirectory,
  }) async {
    calls.add([executable, ...arguments]);
    return exitCode;
  }
}

/// Knows one answer: stable is 3.44.0.
class FakeReleases implements ReleaseClient {
  @override
  Future<String> latestVersion(Channel channel) async => '3.44.0';

  @override
  Future<List<String>> listReleases(Channel channel) async => ['3.44.0'];

  @override
  Future<Channel> channelFor(String version) async => Channel.stable;

  @override
  FutureOr<ReleaseArtifact> artifactFor({
    required Channel channel,
    required String version,
    required HostPlatform platform,
  }) =>
      throw UnimplementedError();
}
