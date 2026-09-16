/// A terminal transcript: what you typed, and what fvm said back.
///
/// A plain fenced block cannot show a session. Prompt, command and output land
/// in one undifferentiated blob, and the reader has no way to tell the part
/// they would type from the part the tool prints. This renders the two
/// differently, so a landing page can *show* fvm answering.
///
/// Usable directly from markdown:
///
/// ```md
/// <Terminal cwd="~/work/api" caption="The same shell, one directory later.">
///
/// ```text
/// $ dart --version
/// Dart SDK version: 3.13.2 (stable) (Tue Aug 25 01:01:12 2026 -0700) on "macos_arm64"
/// ```
///
/// </Terminal>
/// ```
///
/// Both attributes are optional. `cwd` labels the directory the session is
/// standing in, which most of the demonstrations on the landing page depend on
/// — the whole point of fvm is that the answer changes with the directory.
/// `caption` is one sentence under the frame.
///
/// Line conventions inside the fence:
///
/// - a line starting with `$ ` is a command; the `$` is rendered as decoration
///   and is excluded from selection, so copying the block yields the command
///   and not the prompt,
/// - a line that is exactly `…` marks output elided for length,
/// - every other line is output.
///
/// The blank lines around the fence matter, for the reason spelled out in
/// [CardGrid]'s library comment: `package:markdown` ends an HTML block at the
/// first blank line, and the nodes that follow attach to the still-open
/// element. That is what lets a fenced block sit inside `<Terminal>` at all.
///
/// Everything here renders server-side. The site builds with `jaspr: mode:
/// static`, so a component that needed a browser to paint would pre-render as
/// an empty rectangle.
library;

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_content/jaspr_content.dart';
import 'package:jaspr_content/theme.dart';

/// `<Terminal cwd="…" caption="…">` — a static terminal session.
///
/// Implemented against [CustomComponent.create] rather than as a
/// [CustomComponentBase] like `cards.dart`, because `CustomComponentBase.apply`
/// hands over a child that has already been built into a [Component] and the
/// transcript's raw text cannot be recovered from it. Reading [Node.innerText]
/// off the unbuilt node is what preserves the output verbatim — including the
/// blank lines inside `fvm list`, which is exactly the fidelity this component
/// exists for. `CodeBlock` in `jaspr_content` is shaped the same way and for
/// the same reason.
///
/// Not building the children has a second effect worth knowing: the nested
/// fence is never offered to `CodeBlock`, so it is not syntax-highlighted and
/// its language tag is decorative. `text` is the honest one to write, and it
/// is also what the block degrades to if this component is ever unregistered.
final class Terminal extends CustomComponent {
  const Terminal() : super.base();

  /// What marks a line as something the reader would type.
  static const String _promptPrefix = r'$ ';

  /// What marks a line as output left out for length.
  static const String _elision = '…';

  @override
  Component? create(Node node, NodesBuilder builder) {
    if (node is! ElementNode || node.tag != 'Terminal') return null;

    final transcript = (node.children ?? const <Node>[]).map((child) => child.innerText).join().trim();
    final cwd = node.attributes['cwd'];
    final caption = node.attributes['caption'];

    return Component.fragment([
      Document.head(children: [Style(styles: _styles)]),
      figure(classes: 'terminal', [
        if (cwd != null)
          div(classes: 'terminal-bar', [
            span(
              classes: 'terminal-dots',
              attributes: {'aria-hidden': 'true'},
              [
                span([]),
                span([]),
                span([]),
              ],
            ),
            span(classes: 'terminal-cwd', [Component.text(cwd)]),
          ]),
        pre(classes: 'terminal-body', [
          code(_lines(transcript)),
        ]),
        if (caption != null) figcaption(classes: 'terminal-caption', [Component.text(caption)]),
      ]),
    ]);
  }

  /// One span per line, with the real newlines left between them.
  ///
  /// The spans stay inline and the newlines stay in the document rather than
  /// being replaced by `display: block`, so the transcript is still a
  /// transcript with CSS off and a selection across it copies as the lines the
  /// reader can see.
  List<Component> _lines(String transcript) {
    final lines = transcript.split('\n');
    return [
      for (final (index, line) in lines.indexed) ...[
        if (index > 0) Component.text('\n'),
        if (line.startsWith(_promptPrefix))
          span(classes: 'terminal-command', [
            span(
              classes: 'terminal-prompt',
              attributes: {'aria-hidden': 'true'},
              [
                Component.text(_promptPrefix),
              ],
            ),
            Component.text(line.substring(_promptPrefix.length)),
          ])
        else if (line.trim() == _elision)
          span(classes: 'terminal-elision', [Component.text(line)])
        else
          span(classes: 'terminal-output', [Component.text(line)]),
      ],
    ];
  }
}

/// The terminal surface is dark under BOTH themes — `ContentColors.preBg` is
/// `gray.800` in light and a translucent black in dark — so the text on it is
/// deliberately a fixed light-on-dark palette rather than a theme-flipping
/// token. `ContentColors.primary` would be the wrong choice for the prompt for
/// exactly this reason: it resolves to a near-black in light mode, which is
/// invisible here. Anything that does flip has to be checked against both ends
/// of the toggle, and on this surface only one end exists.
List<StyleRule> get _styles => [
  css('.terminal', [
    // The surface belongs to the whole frame, not to the `pre` inside it, so
    // that the bar and the caption sit on the same dark background as the
    // transcript. It has to be the figure that carries it: in dark mode
    // `preBg` is a translucent black, so painting it on both would leave the
    // body visibly darker than the chrome around it.
    css('&').styles(
      overflow: Overflow.hidden,
      margin: Margin.symmetric(vertical: 1.5.rem),
      border: Border.all(width: 1.px, color: Color('rgb(255 255 255 / 12%)')),
      radius: BorderRadius.circular(12.px),
      backgroundColor: ContentColors.preBg,
    ),

    css('.terminal-bar', [
      css('&').styles(
        display: Display.flex,
        padding: Padding.symmetric(horizontal: .875.rem, vertical: .5.rem),
        border: Border.only(
          bottom: BorderSide(width: 1.px, color: Color('rgb(255 255 255 / 10%)')),
        ),
        alignItems: AlignItems.center,
        gap: Gap.column(.625.rem),
        backgroundColor: Color('rgb(255 255 255 / 6%)'),
      ),
      css('.terminal-dots', [
        css('&').styles(
          display: Display.flex,
          gap: Gap.column(.3125.rem),
          raw: {'user-select': 'none'},
        ),
        css('span').styles(
          width: .5.rem,
          height: .5.rem,
          radius: BorderRadius.circular(999.px),
          backgroundColor: Color('rgb(255 255 255 / 22%)'),
        ),
      ]),
      css('.terminal-cwd').styles(
        color: ThemeColors.gray.$400,
        fontFamily: FontFamily.list([FontFamilies.monospace]),
        fontSize: .75.rem,
      ),
    ]),

    // `pre` already carries the theme's horizontal scroll and monospace
    // sizing. Only what the frame changes is restated: the margin, the corners
    // and the background now belong to the figure around it.
    //
    // `pre-wrap` rather than the plain `pre` a code block gets, because the
    // lines that matter most here are the longest ones. `Dart SDK version:
    // 3.13.2 (stable) (…) on "macos_arm64"` is 90 characters and the content
    // column holds about 76, so the default clips the answer at exactly the
    // moment the page is trying to show it — and a horizontal scrollbar is a
    // poor place to keep a punchline. Wrapping is visual only: the newlines in
    // the document are untouched, so a selection still copies the transcript
    // line for line.
    css('.terminal-body').styles(
      padding: Padding.symmetric(horizontal: 1.rem, vertical: .875.rem),
      margin: Margin.zero,
      radius: BorderRadius.circular(Unit.zero),
      backgroundColor: Colors.transparent,
      raw: {'white-space': 'pre-wrap', 'overflow-wrap': 'anywhere'},
    ),

    css('.terminal-command', [
      css('&').styles(color: Colors.white, fontWeight: FontWeight.w600),
      css('.terminal-prompt').styles(
        color: ThemeColors.emerald.$400,
        fontWeight: FontWeight.w700,
        raw: {'user-select': 'none'},
      ),
    ]),

    css('.terminal-output').styles(color: ThemeColors.gray.$400, fontWeight: FontWeight.w400),

    css('.terminal-elision').styles(color: ThemeColors.gray.$400, opacity: .6),

    css('.terminal-caption').styles(
      padding: Padding.symmetric(horizontal: 1.rem, vertical: .625.rem),
      border: Border.only(
        top: BorderSide(width: 1.px, color: Color('rgb(255 255 255 / 10%)')),
      ),
      color: ThemeColors.gray.$400,
      fontSize: .8125.rem,
      backgroundColor: Color('rgb(255 255 255 / 4%)'),
    ),
  ]),
];
