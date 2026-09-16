import 'package:fvm/fvm.dart';
import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:test/test.dart';

void main() {
  late MemoryFileSystem fs;
  late FvmPaths paths;
  late ConfigStore config;
  late FvmrcStore fvmrc;

  setUp(() {
    fs = MemoryFileSystem.test();
    paths = FvmPaths(fileSystem: fs, environment: {'HOME': '/home/dev'});
    config = ConfigStore(fileSystem: fs, paths: paths);
    fvmrc = FvmrcStore(fileSystem: fs);
  });

  void writeConfig(String contents) {
    paths.configFile.parent.createSync(recursive: true);
    paths.configFile.writeAsStringSync(contents);
  }

  File writeFvmrc(String contents, {String at = '/code/app'}) {
    final file = fs.file('$at/.fvmrc');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
    return file;
  }

  group('ConfigStore', () {
    test('a missing config reads as empty, not as an error', () {
      expect(config.read().global, isNull);
      expect(config.read().aliases, isEmpty);
    });

    test('reads global, aliases and channels', () {
      writeConfig('''
{
  "global": "3.13.2",
  "aliases": { "work": "3.9.0" },
  "channels": { "stable": "3.13.2" }
}
''');

      final result = config.read();
      expect(result.global, '3.13.2');
      expect(result.aliases, {'work': '3.9.0'});
      expect(result.versionForChannel(Channel.stable), '3.13.2');
      expect(result.versionForChannel(Channel.beta), isNull);
    });

    test('malformed JSON names the file and the problem', () {
      writeConfig('{"global": "3.9.0"');

      expect(
        config.read,
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('/home/dev/.fvm/config.json'),
              contains('not valid JSON'),
            ),
          ),
        ),
      );
    });

    test('a wrongly typed field names the field', () {
      writeConfig('{"global": 3}');

      expect(
        config.read,
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('"global"'), contains('a number')),
          ),
        ),
      );
    });

    test('an alias whose value is not a string names the alias', () {
      writeConfig('{"aliases": {"work": ["3.9.0"]}}');

      expect(
        config.read,
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('"aliases"."work"'), contains('a list')),
          ),
        ),
      );
    });

    test('write then read round-trips, and keeps unknown keys', () {
      writeConfig('{"global": "3.9.0", "futureSetting": true}');

      config.write(config.read().copyWith(global: '3.13.2'));

      final reread = config.read();
      expect(reread.global, '3.13.2');
      expect(
        paths.configFile.readAsStringSync(),
        contains('"futureSetting": true'),
      );
    });

    test('write creates ~/.fvm when it does not exist yet', () {
      config.write(const FvmConfig(global: '3.9.0'));

      expect(paths.configFile.existsSync(), isTrue);
      expect(config.read().global, '3.9.0');
    });
  });

  group('.fvmrc', () {
    test('reads the canonical JSON form', () {
      expect(fvmrc.read(writeFvmrc('{"flutter": "3.9.0"}')), '3.9.0');
    });

    test('reads the pretty-printed JSON form', () {
      expect(fvmrc.read(writeFvmrc('{\n  "flutter": "3.9.0"\n}\n')), '3.9.0');
    });

    test('reads a bare version on one line, the way .nvmrc works', () {
      expect(fvmrc.read(writeFvmrc('3.9.0\n')), '3.9.0');
    });

    test('reads a bare version with no trailing newline', () {
      expect(fvmrc.read(writeFvmrc('3.9.0')), '3.9.0');
    });

    test('reads a bare alias or channel name', () {
      expect(fvmrc.read(writeFvmrc('stable\n')), 'stable');
      expect(fvmrc.read(writeFvmrc('work')), 'work');
    });

    test('a missing .fvmrc reads as null', () {
      expect(fvmrc.read(fs.file('/code/app/.fvmrc')), isNull);
    });

    test('write always emits the JSON form, even over a bare version', () {
      final file = writeFvmrc('3.9.0\n');

      fvmrc.write(file, '3.13.2');

      expect(file.readAsStringSync(), '{\n  "flutter": "3.13.2"\n}\n');
      expect(fvmrc.read(file), '3.13.2');
    });

    group('malformed', () {
      test('broken JSON is an error naming the file, not a silent fallback',
          () {
        final file = writeFvmrc('{"flutter": "3.9.0"\n');

        expect(
          () => fvmrc.read(file),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('/code/app/.fvmrc'),
                contains('not valid JSON'),
                contains('{"flutter": "3.9.0"}'),
              ),
            ),
          ),
        );
      });

      test('an object with no "flutter" key says so', () {
        expect(
          () => fvmrc.read(writeFvmrc('{"dart": "3.9.0"}')),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              allOf(contains('/code/app/.fvmrc'), contains('no "flutter" key')),
            ),
          ),
        );
      });

      test('a non-string "flutter" value says what it found', () {
        expect(
          () => fvmrc.read(writeFvmrc('{"flutter": 3.9}')),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              allOf(
                  contains('"flutter" must be a string'), contains('a number')),
            ),
          ),
        );
      });

      test('an empty file says so', () {
        expect(
          () => fvmrc.read(writeFvmrc('\n  \n')),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              allOf(contains('/code/app/.fvmrc'), contains('is empty')),
            ),
          ),
        );
      });

      test('several bare lines are an error, not a first-line guess', () {
        expect(
          () => fvmrc.read(writeFvmrc('3.9.0\n3.13.2\n')),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              contains('more than one line'),
            ),
          ),
        );
      });

      test('a bare value containing whitespace is an error', () {
        expect(
          () => fvmrc.read(writeFvmrc('flutter 3.9.0')),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              contains('whitespace'),
            ),
          ),
        );
      });

      test('a JSON list is rejected with the expected shape spelled out', () {
        expect(
          () => fvmrc.read(writeFvmrc('["3.9.0"]')),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              contains('{"flutter": "3.9.0"}'),
            ),
          ),
        );
      });
    });

    group('findNearest', () {
      test('finds the .fvmrc in the directory itself', () {
        writeFvmrc('3.9.0', at: '/code/app');
        fs.directory('/code/app').createSync(recursive: true);

        expect(fvmrc.findNearest(fs.directory('/code/app'))?.path,
            '/code/app/.fvmrc');
      });

      test('walks up to the nearest ancestor that has one', () {
        writeFvmrc('3.9.0', at: '/code');
        fs.directory('/code/app/lib/src').createSync(recursive: true);

        expect(
          fvmrc.findNearest(fs.directory('/code/app/lib/src'))?.path,
          '/code/.fvmrc',
        );
      });

      test('the nearest one wins over an ancestor', () {
        writeFvmrc('3.0.0', at: '/code');
        writeFvmrc('3.9.0', at: '/code/app');
        fs.directory('/code/app/lib').createSync(recursive: true);

        expect(
          fvmrc.findNearest(fs.directory('/code/app/lib'))?.path,
          '/code/app/.fvmrc',
        );
      });

      test('stops at the filesystem root instead of looping', () {
        fs.directory('/code/app').createSync(recursive: true);

        expect(fvmrc.findNearest(fs.directory('/code/app')), isNull);
      });
    });
  });
}
