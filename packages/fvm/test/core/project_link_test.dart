import 'dart:io' as io;

import 'package:fvm/fvm.dart';
import 'package:fvm/src/core/project_link.dart';
import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:file/memory.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `.fvm/flutter_sdk`, the one thing fvm leaves inside a project.
void main() {
  group('on any filesystem', () {
    late MemoryFileSystem fs;

    /// An SDK to point at, and the link that should end up pointing at it.
    (Link, Directory) subject() {
      final target = fs.directory('/fvm/versions/3.9.0')
        ..createSync(recursive: true);
      fs.file('/fvm/versions/3.9.0/bin/flutter').createSync(recursive: true);
      return (fs.link('/project/.fvm/flutter_sdk'), target);
    }

    setUp(() => fs = MemoryFileSystem.test());

    test('creates the .fvm directory and the link inside it', () {
      final (link, target) = subject();

      linkProjectSdk(link: link, target: target);

      expect(link.existsSync(), isTrue);
      expect(link.targetSync(), target.path);
      expect(fs.file('/project/.fvm/flutter_sdk/bin/flutter').existsSync(),
          isTrue);
    });

    test('replaces a link left by an earlier pin', () {
      final (link, target) = subject();
      final old = fs.directory('/fvm/versions/3.8.0')
        ..createSync(recursive: true);
      link.parent.createSync(recursive: true);
      link.createSync(old.path);

      linkProjectSdk(link: link, target: target);

      expect(link.targetSync(), target.path);
    });

    test('replaces a link whose target is gone', () {
      // followLinks would report this one as missing and leave it in place,
      // and the next `fvm use` would fail on a link that is already there.
      final (link, target) = subject();
      link.parent.createSync(recursive: true);
      link.createSync('/fvm/versions/deleted');

      linkProjectSdk(link: link, target: target);

      expect(link.targetSync(), target.path);
    });

    test('refuses to replace something that is not a link', () {
      final (link, target) = subject();
      fs.file(link.path)
        ..createSync(recursive: true)
        ..writeAsStringSync('somebody put a real file here');

      expect(
        () => linkProjectSdk(link: link, target: target),
        throwsA(isA<ConfigException>().having(
          (error) => error.message,
          'message',
          contains('not a symlink'),
        )),
      );
    });
  });

  group('the Windows linker', () {
    test('falls back to a junction when the symlink is refused', () {
      // The failure a stock Windows machine gives: creating a symbolic link
      // needs Developer Mode or elevation, and a default account has neither.
      final refuses = _RefusingLinker();
      final recorded = <String>[];

      expect(
        () => refuses.create(
          _FakeLink(r'C:\project\.fvm\flutter_sdk', recorded),
          _FakeDirectory(r'C:\Users\dev\.fvm\versions\3.9.0'),
        ),
        returnsNormally,
      );
      expect(refuses.junctions, [
        (r'C:\project\.fvm\flutter_sdk', r'C:\Users\dev\.fvm\versions\3.9.0'),
      ]);
    });

    test('reports both failures when neither kind of link can be made', () {
      final refuses = _RefusingLinker(junctionFailure: 'Access is denied.');

      expect(
        () => refuses.create(
          _FakeLink(r'C:\project\.fvm\flutter_sdk', <String>[]),
          _FakeDirectory(r'C:\versions\3.9.0'),
        ),
        throwsA(isA<ConfigException>().having(
          (error) => error.message,
          'message',
          allOf(
            contains('A required privilege is not held'),
            contains('Access is denied.'),
            // The link is for an IDE, so losing it does not mean losing fvm,
            // and a user staring at this should be told that.
            contains('fvm flutter and fvm exec work without it'),
          ),
        )),
      );
    });

    test(
      'a real junction reaches the directory it names',
      () {
        // The branch a CI runner would otherwise never take: the GitHub
        // Windows image can create symbolic links, so `WindowsSdkLinker`
        // succeeds on its first try there and the fallback that every stock
        // machine depends on would go untested. This calls it directly.
        final temp = io.Directory.systemTemp.createTempSync('fvm_junction_');
        addTearDown(() => temp.deleteSync(recursive: true));

        final target = io.Directory(p.join(temp.path, 'versions', '3.9.0'))
          ..createSync(recursive: true);
        io.File(p.join(target.path, 'bin', 'flutter.bat'))
          ..createSync(recursive: true)
          ..writeAsStringSync('an SDK');
        final link = p.join(temp.path, 'project', '.fvm', 'flutter_sdk');
        io.Directory(p.dirname(link)).createSync(recursive: true);

        expect(
          createDirectoryJunction(link, target.path),
          isNull,
          reason: 'mklink /J refused a junction it should have been able to '
              'make with no privileges at all',
        );

        // Read THROUGH it, which is all an IDE ever does with this link.
        expect(
          io.File(p.join(link, 'bin', 'flutter.bat')).readAsStringSync(),
          'an SDK',
        );
        // And Flutter sees it as a link, which is what lets the next `fvm use`
        // replace it instead of refusing.
        expect(
          const LocalFileSystem().typeSync(link, followLinks: false),
          FileSystemEntityType.link,
        );
      },
      testOn: 'windows',
    );
  });
}

/// A [WindowsSdkLinker] whose symlink attempt always fails the way a stock
/// Windows machine fails it, and whose junctions are recorded rather than made.
class _RefusingLinker extends WindowsSdkLinker {
  _RefusingLinker({this.junctionFailure});

  final String? junctionFailure;
  final List<(String, String)> junctions = [];

  @override
  String? makeJunction(String link, String target) {
    junctions.add((link, target));
    return junctionFailure;
  }
}

/// A [Link] that refuses to be created, the way Windows refuses.
class _FakeLink extends _Unimplemented implements Link {
  _FakeLink(this.path, this.attempts);

  @override
  final String path;

  final List<String> attempts;

  @override
  Link createSync(String target, {bool recursive = false}) {
    attempts.add(target);
    throw const io.FileSystemException(
      'Cannot create link',
      '',
      io.OSError('A required privilege is not held by the client.', 1314),
    );
  }
}

class _FakeDirectory extends _Unimplemented implements Directory {
  _FakeDirectory(this.path);

  @override
  final String path;
}

/// Implements everything by throwing, so a fake only has to write down the
/// members a test actually reaches.
class _Unimplemented {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        '${invocation.memberName} is not part of what this fake stands in for.',
      );
}
