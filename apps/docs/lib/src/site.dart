/// Where the docs site is deployed, and the one fact the whole build hinges on.
///
/// Kept separate from `navigation.dart` — that file is the site's information
/// architecture (what pages exist, in what order), this one is about the origin
/// those pages are served from.
library;

/// The canonical base URL of the deployed site.
///
/// The site owns this domain root. `fvm.mrgnhnt.com` is a REPO-level custom
/// domain, stored in this repository's own Pages configuration, so every route
/// hangs directly off `/` — which is exactly what jaspr's static build emits
/// and what `jaspr serve` serves locally. Routes and links throughout `lib/`
/// and `content/` are written root-absolute and reach the browser unchanged.
///
/// `gh api repos/mrgnhnt96/fvm/pages` reports the live value.
const String docsBaseUrl = 'https://fvm.mrgnhnt.com';
