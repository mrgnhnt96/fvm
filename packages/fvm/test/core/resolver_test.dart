import 'package:fvm/fvm.dart';
import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:test/test.dart';

/// The two-line POSIX shim fvm writes to `~/.fvm/shims/flutter`.
const String shimBody =
    '#!/bin/sh\nexec /usr/local/bin/fvm exec flutter "\$@"\n';

void main() {
  late MemoryFileSystem fs;
  late Map<String, String> environment;
  late FvmPaths paths;
  late ConfigStore config;
  late FvmrcStore fvmrc;

  /// Builds a resolver over the *current* [environment] map.
  VersionResolver resolverFor() => VersionResolver(
        fileSystem: fs,
        paths: paths,
        config: config,
        fvmrc: fvmrc,
        environment: environment,
      );

  setUp(() {
    fs = MemoryFileSystem.test();
    environment = {'HOME': '/home/dev'};
    paths = FvmPaths(fileSystem: fs, environment: environment);
    config = ConfigStore(fileSystem: fs, paths: paths);
    fvmrc = FvmrcStore(fileSystem: fs);
  });

  /// Creates a plausible installed SDK under `~/.fvm/versions/<version>`.
  Directory installSdk(String version) {
    final dir = paths.versionDir(version);
    paths.flutterExecutable(dir)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('#!/not/a/real/binary');
    dir.childFile('version').writeAsStringSync('$version\n');
    return dir;
  }

  /// Creates a non-fvm SDK, e.g. one installed by Homebrew.
  File installUnmanagedSdk(String root) {
    final flutter = fs.file('$root/bin/flutter');
    flutter
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('#!/not/a/real/binary');
    return flutter;
  }

  void writeFvmrc(String at, String contents) {
    final file = fs.file('$at/.fvmrc');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  Directory project(String path) {
    final dir = fs.directory(path)..createSync(recursive: true);
    return dir;
  }

  group('rule 1 — FVM_FLUTTER_VERSION', () {
    test('wins over everything else', () {
      installSdk('3.9.0');
      installSdk('3.13.2');
      writeFvmrc('/code/app', '{"flutter": "3.13.2"}');
      config.write(const FvmConfig(global: '3.13.2'));
      environment['FVM_FLUTTER_VERSION'] = '3.9.0';

      final resolved = resolverFor().resolve(from: project('/code/app'));

      expect(resolved.rule, ResolutionRule.environmentVariable);
      expect(resolved.version, '3.9.0');
      expect(resolved.source, 'FVM_FLUTTER_VERSION');
      expect(resolved.sdkDir.path, '/home/dev/.fvm/versions/3.9.0');
      expect(resolved.isManaged, isTrue);
    });

    test('an empty value is ignored rather than treated as a pin', () {
      installSdk('3.13.2');
      config.write(const FvmConfig(global: '3.13.2'));
      environment['FVM_FLUTTER_VERSION'] = '  ';

      expect(
        resolverFor().resolve(from: project('/code/app')).rule,
        ResolutionRule.globalDefault,
      );
    });
  });

  group('rule 2 — the nearest .fvmrc', () {
    test('wins over the global default and reports which file matched', () {
      installSdk('3.9.0');
      installSdk('3.13.2');
      writeFvmrc('/code/app', '{"flutter": "3.9.0"}');
      config.write(const FvmConfig(global: '3.13.2'));

      final resolved = resolverFor().resolve(from: project('/code/app/lib'));

      expect(resolved.rule, ResolutionRule.fvmrc);
      expect(resolved.version, '3.9.0');
      expect(resolved.source, '/code/app/.fvmrc');
    });

    test('a bare-version .fvmrc resolves the same as the JSON form', () {
      installSdk('3.9.0');
      writeFvmrc('/code/app', '3.9.0\n');

      final resolved = resolverFor().resolve(from: project('/code/app'));

      expect(resolved.rule, ResolutionRule.fvmrc);
      expect(resolved.version, '3.9.0');
    });

    test('a malformed .fvmrc errors instead of falling through to global', () {
      installSdk('3.13.2');
      config.write(const FvmConfig(global: '3.13.2'));
      writeFvmrc('/code/app', '{"flutter": "3.9.0"');

      expect(
        () => resolverFor().resolve(from: project('/code/app')),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('/code/app/.fvmrc'),
          ),
        ),
      );
    });

    test('a pinned but uninstalled version errors, naming what to run', () {
      installSdk('3.13.2');
      config.write(const FvmConfig(global: '3.13.2'));
      writeFvmrc('/code/app', '{"flutter": "3.9.0"}');

      expect(
        () => resolverFor().resolve(from: project('/code/app')),
        throwsA(
          isA<SdkNotInstalledException>()
              .having((e) => e.version, 'version', '3.9.0')
              .having((e) => e.source, 'source', '/code/app/.fvmrc')
              .having(
                (e) => e.message,
                'message',
                contains('fvm install 3.9.0'),
              ),
        ),
      );
    });

    test('a version directory with no bin/flutter is wreckage, not an install',
        () {
      paths.versionDir('3.9.0').createSync(recursive: true);
      writeFvmrc('/code/app', '{"flutter": "3.9.0"}');

      expect(
        () => resolverFor().resolve(from: project('/code/app')),
        throwsA(
          isA<SdkNotInstalledException>().having(
            (e) => e.message,
            'message',
            contains('no flutter executable'),
          ),
        ),
      );
    });
  });

  group('rule 3 — the global default', () {
    test('applies when there is no .fvmrc anywhere above', () {
      installSdk('3.13.2');
      config.write(const FvmConfig(global: '3.13.2'));

      final resolved = resolverFor().resolve(from: project('/code/app'));

      expect(resolved.rule, ResolutionRule.globalDefault);
      expect(resolved.version, '3.13.2');
      expect(resolved.source, '/home/dev/.fvm/config.json');
    });
  });

  group('rule 4 — the next flutter on PATH', () {
    test('finds a non-fvm SDK and reports it as unmanaged', () {
      installUnmanagedSdk('/opt/flutter-sdk');
      environment['PATH'] = '/usr/bin:/opt/flutter-sdk/bin';

      final resolved = resolverFor().resolve(from: project('/code/app'));

      expect(resolved.rule, ResolutionRule.pathFallback);
      expect(resolved.sdkDir.path, '/opt/flutter-sdk');
      expect(resolved.version, isNull);
      expect(resolved.isManaged, isFalse);
      expect(resolved.source, '/opt/flutter-sdk/bin');
    });

    test('SKIPS fvm\'s own shims directory and keeps looking', () {
      // This is the loop: PATH puts ~/.fvm/shims first (that is the whole
      // point of the shim), the shim runs `fvm exec flutter`, and a scan that
      // takes the first `flutter` it finds re-enters here and forks forever.
      paths.flutterShim
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(shimBody);
      installUnmanagedSdk('/opt/flutter-sdk');
      environment['PATH'] = '/home/dev/.fvm/shims:/opt/flutter-sdk/bin';

      final resolved = resolverFor().resolve(from: project('/code/app'));

      expect(resolved.sdkDir.path, '/opt/flutter-sdk');
      expect(resolved.executable.path, isNot(contains('shims')));
    });

    test('skips the shims directory however it is spelled on PATH', () {
      paths.flutterShim
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(shimBody);
      installUnmanagedSdk('/opt/flutter-sdk');
      environment['PATH'] =
          '/home/dev/.fvm/./shims/:/home/dev/.fvm/versions/../shims'
          ':/opt/flutter-sdk/bin';

      expect(
        resolverFor().resolve(from: project('/code/app')).sdkDir.path,
        '/opt/flutter-sdk',
      );
    });

    test('skips a symlink that points into the shims directory', () {
      paths.flutterShim
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(shimBody);
      fs.directory('/home/dev/.local/bin').createSync(recursive: true);
      fs
          .link('/home/dev/.local/bin/flutter')
          .createSync('/home/dev/.fvm/shims/flutter');
      installUnmanagedSdk('/opt/flutter-sdk');
      environment['PATH'] = '/home/dev/.local/bin:/opt/flutter-sdk/bin';

      expect(
        resolverFor().resolve(from: project('/code/app')).sdkDir.path,
        '/opt/flutter-sdk',
      );
    });

    test('skips a COPY of the shim, which no path check could catch', () {
      fs.file('/usr/local/bin/flutter')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(shimBody);
      installUnmanagedSdk('/opt/flutter-sdk');
      environment['PATH'] = '/usr/local/bin:/opt/flutter-sdk/bin';

      expect(
        resolverFor().resolve(from: project('/code/app')).sdkDir.path,
        '/opt/flutter-sdk',
      );
    });

    test('when the shim is the ONLY flutter on PATH it fails, never loops', () {
      paths.flutterShim
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(shimBody);
      environment['PATH'] = '/home/dev/.fvm/shims';

      expect(
        () => resolverFor().resolve(from: project('/code/app')),
        throwsA(isA<ResolutionException>()),
      );
    });

    test('follows a symlink to report the real SDK root', () {
      installUnmanagedSdk('/opt/homebrew/Cellar/flutter/3.13.2');
      fs.directory('/opt/homebrew/bin').createSync(recursive: true);
      fs
          .link('/opt/homebrew/bin/flutter')
          .createSync('/opt/homebrew/Cellar/flutter/3.13.2/bin/flutter');
      environment['PATH'] = '/opt/homebrew/bin';

      expect(
        resolverFor().resolve(from: project('/code/app')).sdkDir.path,
        '/opt/homebrew/Cellar/flutter/3.13.2',
      );
    });

    test('a real binary is not misread as a shim', () {
      // Larger than the shim-sniffing size cap and not valid UTF-8.
      fs.file('/opt/flutter-sdk/bin/flutter')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(List<int>.filled(4096, 0xff));
      environment['PATH'] = '/opt/flutter-sdk/bin';

      expect(
        resolverFor().resolve(from: project('/code/app')).sdkDir.path,
        '/opt/flutter-sdk',
      );
    });

    test('empty and non-existent PATH entries are skipped', () {
      installUnmanagedSdk('/opt/flutter-sdk');
      environment['PATH'] = ':/nope::/also/nope:/opt/flutter-sdk/bin';

      expect(
        resolverFor().resolve(from: project('/code/app')).sdkDir.path,
        '/opt/flutter-sdk',
      );
    });
  });

  group('rule 5 — nothing applies', () {
    test('names each rule that did not fire and what to run', () {
      final error = () {
        try {
          resolverFor().resolve(from: project('/code/app'));
        } on ResolutionException catch (e) {
          return e;
        }
        fail('expected a ResolutionException');
      }();

      expect(error.message, contains('/code/app'));
      expect(error.message, contains('FVM_FLUTTER_VERSION'));
      expect(error.message, contains('.fvmrc'));
      expect(error.message, contains('/home/dev/.fvm/config.json'));
      expect(error.message, contains('fvm use <version>'));
      expect(error.message, contains('fvm global <version>'));
    });
  });

  group('aliases', () {
    test('a .fvmrc naming an alias resolves through the config', () {
      installSdk('3.9.0');
      config.write(const FvmConfig(aliases: {'work': '3.9.0'}));
      writeFvmrc('/code/app', 'work');

      final resolved = resolverFor().resolve(from: project('/code/app'));

      expect(resolved.version, '3.9.0');
      expect(resolved.requested, 'work');
      expect(resolved.describe(), contains('via "work"'));
    });

    test('the global default may be an alias', () {
      installSdk('3.9.0');
      config.write(
        const FvmConfig(global: 'work', aliases: {'work': '3.9.0'}),
      );

      expect(
        resolverFor().resolve(from: project('/code/app')).version,
        '3.9.0',
      );
    });

    test('an alias may point at another alias', () {
      installSdk('3.9.0');
      config.write(
        const FvmConfig(aliases: {'work': 'client', 'client': '3.9.0'}),
      );
      writeFvmrc('/code/app', 'work');

      expect(
        resolverFor().resolve(from: project('/code/app')).version,
        '3.9.0',
      );
    });

    test('an alias may point at a channel', () {
      installSdk('3.13.2');
      config.write(
        const FvmConfig(
          aliases: {'latest': 'stable'},
          channels: {'stable': '3.13.2'},
        ),
      );
      writeFvmrc('/code/app', 'latest');

      expect(
        resolverFor().resolve(from: project('/code/app')).version,
        '3.13.2',
      );
    });

    test('a self-referential alias errors instead of hanging', () {
      config.write(const FvmConfig(aliases: {'work': 'work'}));
      writeFvmrc('/code/app', 'work');

      expect(
        () => resolverFor().resolve(from: project('/code/app')),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('points at itself'),
          ),
        ),
      );
    });

    test('an alias cycle errors instead of hanging', () {
      config.write(const FvmConfig(aliases: {'a': 'b', 'b': 'a'}));
      writeFvmrc('/code/app', 'a');

      expect(
        () => resolverFor().resolve(from: project('/code/app')),
        throwsA(isA<ConfigException>()),
      );
    });
  });

  group('channels', () {
    test('resolve to the version recorded at install time', () {
      installSdk('3.13.2');
      config.write(const FvmConfig(channels: {'stable': '3.13.2'}));
      writeFvmrc('/code/app', '{"flutter": "stable"}');

      final resolved = resolverFor().resolve(from: project('/code/app'));

      expect(resolved.version, '3.13.2');
      expect(resolved.requested, 'stable');
    });

    test('beta and dev resolve independently of stable', () {
      installSdk('3.14.0-beta');
      config.write(
        const FvmConfig(
          channels: {'stable': '3.13.2', 'beta': '3.14.0-beta'},
        ),
      );
      writeFvmrc('/code/app', 'beta');

      expect(
        resolverFor().resolve(from: project('/code/app')).version,
        '3.14.0-beta',
      );
    });

    test('an uninstalled channel says to install it, not to guess', () {
      writeFvmrc('/code/app', 'stable');

      expect(
        () => resolverFor().resolve(from: project('/code/app')),
        throwsA(
          isA<SdkNotInstalledException>().having(
            (e) => e.message,
            'message',
            contains('fvm install stable'),
          ),
        ),
      );
    });
  });

  group('describe', () {
    test('names the rule, the path and the source', () {
      installSdk('3.9.0');
      writeFvmrc('/code/app', '3.9.0');

      final description =
          resolverFor().resolve(from: project('/code/app')).describe();

      expect(description, contains('.fvmrc'));
      expect(description, contains('/home/dev/.fvm/versions/3.9.0'));
      expect(description, contains('Flutter 3.9.0'));
      expect(description, contains('/code/app/.fvmrc'));
    });
  });
}
