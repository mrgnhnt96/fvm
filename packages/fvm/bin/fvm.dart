import 'dart:io';

import 'package:fvm/fvm.dart';

Future<void> main(List<String> args) async {
  exitCode = await run(args);
}
