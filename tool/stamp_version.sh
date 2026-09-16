#!/usr/bin/env bash
# Stamp a release version into the binary, or refuse.
#
# Usage: tool/stamp_version.sh <version>       # e.g. 0.2.0, or v0.2.0
#
# THE REFUSAL IS THE POINT. A release is identified by three things that have to
# agree: the `v*` tag the workflow ran on, `version:` in packages/fvm/pubspec.yaml,
# and `kVersion` in packages/fvm/lib/src/gen/version.dart. Tagging without bumping
# the pubspec is the easy mistake, and its consequence is a published binary that
# reports a version it is not — which then makes `fvm update` compare the wrong
# numbers and either loop or go quiet. So this compares the tag against the pubspec
# and exits non-zero when they differ, rather than writing whichever one it was
# handed. Bump the pubspec, commit, then tag.
#
# Writes packages/fvm/lib/src/gen/version.dart. Does not commit.
set -euo pipefail

version="${1:?version required (e.g. 0.2.0)}"
version="${version#v}"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pubspec="${root}/packages/fvm/pubspec.yaml"
gen_file="${root}/packages/fvm/lib/src/gen/version.dart"

# The first top-level `version:` key. Anchored to column 0 so a nested
# `version:` under `dependencies:` cannot be picked up instead.
pubspec_version="$(sed -n 's/^version:[[:space:]]*\([^[:space:]#]*\).*/\1/p' \
  "${pubspec}" | head -n 1)"

if [[ -z "${pubspec_version}" ]]; then
  echo "stamp_version: ${pubspec} has no top-level version:" >&2
  exit 1
fi

if [[ "${version}" != "${pubspec_version}" ]]; then
  cat >&2 <<EOF
stamp_version: REFUSING to stamp a version the package does not claim.

  tag says     : ${version}
  pubspec says : ${pubspec_version}

Publishing this would ship a binary reporting ${pubspec_version} under the tag
v${version}, and \`fvm update\` compares those numbers. Set version: ${version}
in packages/fvm/pubspec.yaml, commit that, and tag the commit.
EOF
  exit 1
fi

# Only the kVersion line is rewritten; kIsCompiled and every comment in that
# file are hand-written and stay.
tmp="$(mktemp)"
sed "s|^const String kVersion = '.*';\$|const String kVersion = '${version}';|" \
  "${gen_file}" > "${tmp}"
mv "${tmp}" "${gen_file}"

if ! grep -q "^const String kVersion = '${version}';\$" "${gen_file}"; then
  echo "stamp_version: failed to write kVersion into ${gen_file}" >&2
  exit 1
fi

echo "Stamped kVersion = ${version}"
