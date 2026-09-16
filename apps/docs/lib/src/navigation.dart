/// The single source of truth for the docs site's information architecture.
///
/// Consumed by `main.server.dart` to render the sidebar, the breadcrumbs and
/// the prev/next links at the foot of every page.
///
/// The sidebar is GENERATED from this table rather than written out by hand.
/// A hand-maintained sidebar drifts from `content/` silently: adding a page and
/// forgetting to list it fails nothing, builds fine, and leaves a page nobody
/// can reach. `test/navigation_test.dart` is what makes that impossible — every
/// file under `content/` must appear here or in [unlistedRoutes], and every
/// entry here must name a file that exists.
///
/// Keep [navigation] ordered as a reading path: someone who starts at the top
/// and works down should never hit a page that depends on one below it. That
/// order is also what the prev/next links walk.
///
/// Regroup here rather than moving markdown files — a page's URL comes from its
/// path under `content/`, so moving one breaks every inbound link for the sake
/// of a sidebar heading.
library;

/// A single page entry in the sidebar.
final class NavItem {
  const NavItem(this.title, this.href, {this.summary});

  /// Link text. Kept short — the sidebar column is about 17rem.
  final String title;

  /// Root-absolute route, e.g. `/commands/install`.
  ///
  /// The site owns its domain root, so a route written here is the path the
  /// browser actually requests. See `site.dart` for where that is decided.
  final String href;

  /// One-line description, shown on the landing page's cards.
  final String? summary;
}

/// A collapsible group of [NavItem]s in the sidebar.
final class NavGroup {
  const NavGroup(this.title, {required this.icon, required this.items, this.summary});

  /// The group heading, also used as the breadcrumb's second segment.
  final String title;

  /// Inline SVG markup rendered before [title]. See [NavIcons].
  final String icon;

  /// One-line description of what the group covers.
  final String? summary;

  final List<NavItem> items;
}

/// Pages that sit above the grouped navigation.
const List<NavItem> topLevelNavigation = [NavItem('Introduction', '/', summary: 'Flutter versions for every project.')];

const List<NavGroup> navigation = [
  NavGroup(
    "Get Started",
    icon: NavIcons.rocket,
    items: [
      NavItem(
        "Installation",
        "/getting-started/installation",
        summary: "Get the manager with one install script, no Dart or Flutter SDK required.",
      ),
      NavItem(
        "Quick Start",
        "/getting-started/quick-start",
        summary: "Install Flutter, pin a project, and run its bundled tools.",
      ),
      NavItem(
        "The Shim and Your PATH",
        "/getting-started/shell-setup",
        summary: "Make plain flutter use the SDK pinned by the current directory.",
      ),
    ],
  ),
  NavGroup(
    "Pinning Versions",
    icon: NavIcons.pin,
    items: [
      NavItem(
        "The .fvmrc File",
        "/versions/fvmrc",
        summary: "The project pin you commit, and the IDE link you do not.",
      ),
      NavItem(
        "Aliases and Channels",
        "/versions/aliases",
        summary: "Give versions memorable names and understand offline channel pins.",
      ),
      NavItem(
        "Resolution Order",
        "/versions/resolution-order",
        summary: "Five rules select the Flutter SDK, with an explanation you can inspect.",
      ),
    ],
  ),
  NavGroup(
    "Command Reference",
    icon: NavIcons.terminal,
    items: [
      NavItem("fvm install", "/commands/install", summary: "Download and verify a Flutter SDK."),
      NavItem("fvm use", "/commands/use", summary: "Pin a version for this project and create its IDE link."),
      NavItem("fvm global", "/commands/global", summary: "Set the fallback used outside pinned projects."),
      NavItem("fvm list", "/commands/list", summary: "List installed SDKs and the names that point at them."),
      NavItem("fvm list-remote", "/commands/list-remote", summary: "List Flutter releases published for this host."),
      NavItem("fvm remove", "/commands/remove", summary: "Remove an SDK from the shared cache."),
      NavItem("fvm alias", "/commands/alias", summary: "Give a version a name, or list saved names."),
      NavItem("fvm unalias", "/commands/unalias", summary: "Remove a saved alias."),
      NavItem("fvm which", "/commands/which", summary: "Print the selected SDK and explain which rule chose it."),
      NavItem("fvm flutter", "/commands/flutter", summary: "Run Flutter from the selected SDK."),
      NavItem("fvm dart", "/commands/dart", summary: "Run Dart bundled with the selected Flutter SDK."),
      NavItem("fvm exec", "/commands/exec", summary: "Run any command with the selected SDK first on PATH."),
      NavItem("fvm setup", "/commands/setup", summary: "Create the Flutter shim and configure shell integration."),
      NavItem("fvm doctor", "/commands/doctor", summary: "Diagnose SDK selection, PATH, shims, and project links."),
      NavItem("fvm config", "/commands/config", summary: "Read or save FVM output preferences."),
      NavItem("fvm update", "/commands/update", summary: "Update the FVM executable from GitHub Releases."),
    ],
  ),
  NavGroup(
    "Guides",
    icon: NavIcons.book,
    items: [
      NavItem(
        "Using FVM alongside DVM",
        "/guides/dvm",
        summary: "Keep standalone Dart and Flutter SDK selection independent.",
      ),
      NavItem(
        "Using FVM in CI",
        "/guides/ci",
        summary: "Run a build against a concrete Flutter version without a shell profile.",
      ),
      NavItem(
        "Updating FVM",
        "/guides/updating-fvm",
        summary: "Update the manager separately from the Flutter SDKs it manages.",
      ),
      NavItem(
        "Troubleshooting",
        "/guides/troubleshooting",
        summary: "Find why Flutter selected the wrong SDK or failed to start.",
      ),
    ],
  ),
];

/// Pages that intentionally live outside the sidebar.
///
/// `test/navigation_test.dart` checks every content page against [navigation]
/// and this set, so a new page that nobody linked fails the suite rather than
/// quietly becoming unreachable.
const Set<String> unlistedRoutes = <String>{};

/// Every navigable page, flattened into reading order.
List<NavItem> get flatNavigation => [
  ...topLevelNavigation,
  for (final group in navigation) ...group.items,
];

/// The group that owns [href], or null for a top-level or unlisted page.
NavGroup? groupFor(String href) {
  for (final group in navigation) {
    for (final item in group.items) {
      if (item.href == href) return group;
    }
  }
  return null;
}

/// The nav entry for [href], or null when the page is unlisted.
NavItem? itemFor(String href) {
  for (final item in flatNavigation) {
    if (item.href == href) return item;
  }
  return null;
}

/// The previous and next pages in reading order, for the page footer.
({NavItem? previous, NavItem? next}) neighborsOf(String href) {
  final flat = flatNavigation;
  final index = flat.indexWhere((item) => item.href == href);
  if (index < 0) return (previous: null, next: null);
  return (previous: index > 0 ? flat[index - 1] : null, next: index < flat.length - 1 ? flat[index + 1] : null);
}

/// Inline SVG icons for [NavGroup]s.
///
/// Lucide-style 24x24 strokes, so they inherit `currentColor` and line weight
/// from the sidebar text rather than needing their own colors.
abstract final class NavIcons {
  static const String _open =
      '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" '
      'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">';

  static const rocket =
      '$_open<path d="M4.5 16.5c-1.5 1.26-2 5-2 5s3.74-.5 5-2c.71-.84.7-2.13-.09-2.91a2.18 2.18 0 0 0-2.91-.09z"/>'
      '<path d="m12 15-3-3a22 22 0 0 1 2-3.95A12.88 12.88 0 0 1 22 2c0 2.72-.78 7.5-6 11a22.35 22.35 0 0 1-4 2z"/>'
      '<path d="M9 12H4s.55-3.03 2-4c1.62-1.08 5 0 5 0"/><path d="M12 15v5s3.03-.55 4-2c1.08-1.62 0-5 0-5"/></svg>';

  static const pin =
      '$_open<path d="M12 17v5"/><path d="M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 '
      '1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H8a2 2 0 0 0 0 4 1 '
      '1 0 0 1 1 1z"/></svg>';

  static const terminal = '$_open<polyline points="4 17 10 11 4 5"/><line x1="12" x2="20" y1="19" y2="19"/></svg>';

  static const book =
      '$_open<path d="M4 19.5v-15A2.5 2.5 0 0 1 6.5 2H19a1 1 0 0 1 1 1v18a1 1 0 0 1-1 1H6.5a1 1 0 0 1 0-5H20"/></svg>';
}
