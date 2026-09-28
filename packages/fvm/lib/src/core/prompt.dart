import 'dart:io' as io;

/// Asks the person at the terminal a yes/no question.
///
/// A seam, like the output sinks, so that every command stays runnable from a
/// test and from CI. Nothing may call [confirm] without checking
/// [isInteractive] first: a question nobody can answer must not block a
/// script, and it must not be answered for them either.
abstract class Prompter {
  const Prompter();

  /// Whether a person is there to answer.
  bool get isInteractive;

  /// Prints [question] and waits for yes or no.
  ///
  /// An empty answer takes [defaultValue]. End of input is a "no": a closed
  /// stdin is nobody agreeing to anything.
  bool confirm(String question, {required bool defaultValue});
}

/// The prompter for a run nobody is watching: tests, CI, and pipes.
class NonInteractivePrompter extends Prompter {
  const NonInteractivePrompter();

  @override
  bool get isInteractive => false;

  @override
  bool confirm(String question, {required bool defaultValue}) =>
      throw StateError('confirm() called without a terminal to ask: $question');
}

/// Reads answers from the process's own stdin.
class StdinPrompter extends Prompter {
  StdinPrompter({required this.out});

  /// Where the question is written. The same sink as the command's output, so
  /// the question sits next to what it is asking about.
  final StringSink out;

  @override
  bool get isInteractive => io.stdin.hasTerminal && io.stdout.hasTerminal;

  @override
  bool confirm(String question, {required bool defaultValue}) {
    final hint = defaultValue ? '[Y/n]' : '[y/N]';
    while (true) {
      out.write('$question $hint ');
      final answer = io.stdin.readLineSync()?.trim().toLowerCase();
      if (answer == null) return false;
      if (answer.isEmpty) return defaultValue;
      if (answer == 'y' || answer == 'yes') return true;
      if (answer == 'n' || answer == 'no') return false;
      out.writeln('Answer y or n.');
    }
  }
}
