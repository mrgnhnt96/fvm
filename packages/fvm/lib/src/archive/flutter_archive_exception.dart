import '../core/exceptions.dart';

/// Something went wrong talking to, or unpacking, the Flutter release archive.
///
/// A [FvmException] so that `lib/fvm.dart` prints the message on its own and
/// exits 1, rather than dumping a stack trace at a user whose wifi dropped.
class FlutterArchiveException extends FvmException {
  const FlutterArchiveException(super.message);
}
