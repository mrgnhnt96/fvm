/// The entrypoint for the **server** environment, which for a static build is
/// what pre-renders every page.
library;

import 'package:jaspr/dom.dart';
import 'package:jaspr/server.dart';
import 'package:jaspr_content/components/callout.dart';
import 'package:jaspr_content/components/code_block.dart';
import 'package:jaspr_content/components/header.dart';
import 'package:jaspr_content/components/image.dart';
import 'package:jaspr_content/components/theme_toggle.dart';
import 'package:jaspr_content/jaspr_content.dart';
import 'package:jaspr_content/theme.dart';
import 'package:jaspr_search/jaspr_search.dart';

import 'components/cards.dart';
import 'components/docs_sidebar.dart';
import 'components/terminal.dart';
import 'main.server.options.dart';
import 'src/navigation.dart';

void main() {
  Jaspr.initializeApp(options: defaultServerOptions);

  runApp(
    ContentApp(
      templateEngine: MustacheTemplateEngine(),
      parsers: [MarkdownParser()],
      extensions: [HeadingAnchorsExtension(), TableOfContentsExtension()],
      components: [
        Callout(),
        CodeBlock(
          grammars: {
            // Every language any fence under `content/` uses. A fence tagged
            // with a language that is NOT listed here does not degrade to plain
            // text — `syntax_highlight_lite` throws on the null grammar and the
            // whole route fails to pre-render with a 500. `dockerfile` in
            // content/guides/ci.md is how that was found.
            for (final lang in const ['sh', 'bash', 'text', 'json', 'yaml', 'dart', 'dockerfile'])
              lang: '{"name":"$lang","scopeName":"source.$lang","patterns":[]}',
          },
        ),
        Image(zoom: true),
        const CardGrid(),
        const Card(),
        const SectionCards(),
        const Terminal(),
      ],
      layouts: [
        FvmDocsLayout(
          header: Header(
            title: 'fvm',
            // Root-absolute, like every other reference on the site: the
            // site owns its domain root, so this reaches the browser as-is.
            logo: '/images/logo.svg',
            items: [
              // Client-side search over `web/search-index.json`, which
              // `tool/build_search_index.dart` generates from `content/`. The
              // index path stays RELATIVE — the component's default,
              // `search-index.json` — and the browser resolves it against the
              // page's `<base href>`, so a reader on any nested route still
              // fetches the one copy at the site root.
              const SearchDialog(
                placeholder: 'Search the fvm docs…',
                triggerAriaLabel: 'Search the fvm documentation',
              ),
              // Root-absolute, like every other link on the site.
              const _GitHubLink(),
              ThemeToggle(),
            ],
          ),
          // Generated from `src/navigation.dart` rather than written out here.
          // A hand-written sidebar drifts from `content/` silently — nothing
          // fails when a page is added and not listed. See navigation.dart.
          sidebar: const DocsSidebar(),
        ),
      ],
      theme: ContentTheme(
        primary: ThemeColor(ThemeColors.blue.$600, dark: ThemeColors.blue.$400),
        background: ThemeColor(ThemeColors.slate.$50, dark: ThemeColors.zinc.$950),
      ),
    ),
  );
}

/// The one link in the header that leaves the site.
///
/// Absolute and external on purpose: it leaves the site entirely, so it is the
/// one reference `build_smoke_test.dart` deliberately does not try to fetch.
final class _GitHubLink extends StatelessComponent {
  const _GitHubLink();

  @override
  Component build(BuildContext context) {
    return a(
      classes: 'header-github',
      href: 'https://github.com/mrgnhnt96/fvm',
      attributes: {'aria-label': 'fvm on GitHub', 'target': '_blank', 'rel': 'noopener'},
      [
        Document.head(children: [Style(styles: _githubStyles)]),
        RawText(_githubIcon),
      ],
    );
  }
}

const _githubIcon =
    '<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="currentColor" '
    'aria-hidden="true"><path d="M12 .5C5.37.5 0 5.87 0 12.5c0 5.3 3.44 9.8 8.21 11.39.6.11.82-.26.82-.58 '
    '0-.29-.01-1.24-.02-2.25-3.34.73-4.04-1.42-4.04-1.42-.55-1.39-1.34-1.76-1.34-1.76-1.09-.75.08-.73.08-.73 '
    '1.2.08 1.84 1.24 1.84 1.24 1.07 1.83 2.81 1.3 3.49.99.11-.78.42-1.3.76-1.6-2.67-.3-5.47-1.34-5.47-5.96 '
    '0-1.32.47-2.39 1.24-3.23-.12-.31-.54-1.53.12-3.19 0 0 1.01-.32 3.3 1.23a11.5 11.5 0 0 1 6.01 0c2.29-1.55 '
    '3.3-1.23 3.3-1.23.66 1.66.24 2.88.12 3.19.77.84 1.24 1.91 1.24 3.23 0 4.63-2.81 5.65-5.49 '
    '5.95.43.37.81 1.1.81 2.22 0 1.61-.01 2.9-.01 3.3 0 .32.22.7.83.58A12.01 12.01 0 0 0 24 12.5C24 5.87 '
    '18.63.5 12 .5z"/></svg>';

List<StyleRule> get _githubStyles => [
  css('.header-github', [
    css('&').styles(display: Display.flex, opacity: .7, alignItems: AlignItems.center, color: Color('inherit')),
    css('&:hover').styles(opacity: 1),
  ]),
];

/// [DocsLayout] with breadcrumbs and prev/next links along the reading order in
/// [navigation].
///
/// [buildBody] reproduces `DocsLayout`'s DOM rather than calling `super`,
/// because the upstream layout offers no hook between the sidebar and the page
/// title. The class names are kept identical so the CSS that `super.buildHead`
/// emits still applies — if `jaspr_content` changes its layout markup, this has
/// to follow it.
final class FvmDocsLayout extends DocsLayout {
  // `header` and `footer` are `DocsLayout`'s own field names, so these
  // super-parameters cannot be renamed without giving up forwarding to them.
  // ignore: avoid_types_as_parameter_names
  const FvmDocsLayout({super.sidebar, super.header, super.footer});

  @override
  Iterable<Component> buildHead(Page page) sync* {
    yield* super.buildHead(page);
    // Root-absolute, like every other reference on the site, and served
    // straight off the domain root. `build_smoke_test.dart` fetches every
    // `href` on the pages it loads, so this one is checked rather than assumed.
    //
    // Yielded here rather than set through jaspr_content's own `favicon` site
    // key, because `PageLayoutBase.buildHead` hardcodes `type: 'image/png'` on
    // the link it emits, which is the wrong MIME type for an SVG icon.
    yield link(rel: 'icon', type: 'image/svg+xml', href: '/images/favicon.svg');
    yield Style(styles: _styles);
  }

  @override
  Component buildBody(Page page, Component child) {
    final pageData = page.data.page;
    final route = page.url;
    final group = groupFor(route);

    return div(classes: 'docs', [
      // `this.header`, not `header`: inside a DocsLayout subclass the bare
      // identifier resolves to Jaspr's `<header>` element class instead of the
      // inherited field, and the error it produces says nothing about that.
      if (this.header case final headerComponent?)
        div(classes: 'header-container', attributes: {if (sidebar != null) 'data-has-sidebar': ''}, [headerComponent]),
      div(classes: 'main-container', [
        div(classes: 'sidebar-barrier', attributes: {'role': 'button'}, []),
        if (sidebar case final sidebarComponent?) div(classes: 'sidebar-container', [sidebarComponent]),
        main_([
          div([
            div(classes: 'content-container', [
              div(classes: 'content-header', [
                if (group != null)
                  nav(
                    classes: 'breadcrumbs',
                    attributes: {'aria-label': 'Breadcrumb'},
                    [
                      a(href: '/', [Component.text('Docs')]),
                      span(classes: 'breadcrumb-sep', [Component.text('/')]),
                      span([Component.text(group.title)]),
                    ],
                  ),
                if (pageData['title'] case final String title) h1([Component.text(title)]),
                if (pageData['description'] case final String description) p([Component.text(description)]),
              ]),
              child,
              div(classes: 'content-footer', [_PageNav(route: route), ?this.footer]),
            ]),
            aside(classes: 'toc', [
              if (page.data['toc'] case final TableOfContents toc)
                div([
                  h3([Component.text('On this page')]),
                  toc.build(),
                ]),
            ]),
          ]),
        ]),
      ]),
    ]);
  }
}

/// Previous/next links along the reading order defined in [navigation].
final class _PageNav extends StatelessComponent {
  const _PageNav({required this.route});

  final String route;

  @override
  Component build(BuildContext context) {
    final (:previous, :next) = neighborsOf(route);
    if (previous == null && next == null) return const Component.empty();

    return nav(
      classes: 'page-nav',
      attributes: {'aria-label': 'Pagination'},
      [
        if (previous != null)
          a(classes: 'page-nav-link page-nav-prev', href: previous.href, [
            span(classes: 'page-nav-label', [Component.text('Previous')]),
            span(classes: 'page-nav-title', [Component.text(previous.title)]),
          ])
        else
          span([]),
        if (next != null)
          a(classes: 'page-nav-link page-nav-next', href: next.href, [
            span(classes: 'page-nav-label', [Component.text('Next')]),
            span(classes: 'page-nav-title', [Component.text(next.title)]),
          ]),
      ],
    );
  }
}

List<StyleRule> get _styles => [
  // `DocsLayout` sets the page description to font-size 1.25rem with an equal
  // line-height, so any description that wraps collides with itself.
  css('.docs .content-header p').styles(opacity: .75, lineHeight: 1.6.em),

  css('.breadcrumbs', [
    css('&').styles(
      display: Display.flex,
      margin: Margin.only(bottom: .625.rem),
      opacity: .6,
      gap: Gap.column(.5.rem),
      fontSize: .8125.rem,
    ),
    css('a').styles(color: Color('inherit'), textDecoration: TextDecoration.none),
    css('a:hover').styles(textDecoration: TextDecoration(line: TextDecorationLine.underline)),
    css('.breadcrumb-sep').styles(opacity: .5),
  ]),

  css('.page-nav', [
    css('&').styles(
      display: Display.flex,
      padding: Padding.only(top: 1.5.rem),
      margin: Margin.only(top: 3.rem),
      border: Border.only(
        top: BorderSide(width: 1.px, color: Color('color-mix(in srgb, currentColor 12%, transparent)')),
      ),
      justifyContent: JustifyContent.spaceBetween,
      gap: Gap.column(1.rem),
    ),
    css('.page-nav-link', [
      css('&').styles(
        display: Display.flex,
        maxWidth: 48.percent,
        padding: Padding.symmetric(horizontal: 1.rem, vertical: .75.rem),
        border: Border.all(width: 1.px, color: Color('color-mix(in srgb, currentColor 12%, transparent)')),
        radius: BorderRadius.circular(10.px),
        transition: Transition('all', duration: 150.ms, curve: Curve.easeInOut),
        flexDirection: FlexDirection.column,
        gap: Gap.row(.125.rem),
        color: Color('inherit'),
        textDecoration: TextDecoration.none,
      ),
      css('&:hover').styles(
        border: Border.all(width: 1.px, color: Color('color-mix(in srgb, currentColor 28%, transparent)')),
        backgroundColor: Color('color-mix(in srgb, currentColor 4%, transparent)'),
      ),
      css('.page-nav-label').styles(
        opacity: .55,
        fontSize: .6875.rem,
        textTransform: TextTransform.upperCase,
        letterSpacing: .04.em,
      ),
      css('.page-nav-title').styles(color: ContentColors.primary, fontSize: .9375.rem, fontWeight: FontWeight.w600),
    ]),
    css('.page-nav-next').styles(
      margin: Margin.only(left: Unit.auto),
      textAlign: TextAlign.right,
    ),
  ]),
];
