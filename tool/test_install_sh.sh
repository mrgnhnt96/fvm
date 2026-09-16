#!/bin/sh
# Tests the pure parts of install.sh: platform detection and release picking.
#
# install.sh is the one piece of fvm that is not Dart and therefore not covered
# by `dart test`, and it is also the piece that runs on a machine with nothing
# on it. It is sourced here in library mode (FVM_INSTALL_SH_LIB=1) so its
# functions can be called without downloading anything.
#
# `uname` is shadowed by a shell function below — a function beats an external
# command in POSIX name resolution, which is what makes host detection testable
# without a fleet of machines.
#
# Usage: sh tool/test_install_sh.sh
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
failures=0

check() {
  # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "ok   $1"
  else
    echo "FAIL $1"
    echo "       expected: [$2]"
    echo "       actual:   [$3]"
    failures=$((failures + 1))
  fi
}

FVM_INSTALL_SH_LIB=1
export FVM_INSTALL_SH_LIB
# shellcheck source=/dev/null
. "${root}/install.sh"

# --- platform detection -------------------------------------------------------

fake_uname_s="Linux"
fake_uname_m="x86_64"
uname() {
  case "${1:-}" in
    -s) echo "${fake_uname_s}" ;;
    -m) echo "${fake_uname_m}" ;;
    *) echo "${fake_uname_s}" ;;
  esac
}

target_for() {
  fake_uname_s="$1"
  fake_uname_m="$2"
  # In a subshell: detect_target calls die on an unsupported host, and die
  # exits.
  (detect_target) 2> /dev/null || echo "REFUSED"
}

check "linux x86_64"     "linux-x64"    "$(target_for Linux x86_64)"
check "linux aarch64"    "linux-arm64"  "$(target_for Linux aarch64)"
check "macos arm64"      "macos-arm64"  "$(target_for Darwin arm64)"
check "macos x86_64"     "macos-x64"    "$(target_for Darwin x86_64)"
check "windows refused"  "REFUSED"      "$(target_for MINGW64_NT-10.0 x86_64)"
check "freebsd refused"  "REFUSED"      "$(target_for FreeBSD amd64)"
check "riscv refused"    "REFUSED"      "$(target_for Linux riscv64)"

# --- picking a release --------------------------------------------------------

# Assets are abbreviated but the key order is the API's real one: tag_name,
# then draft, then prerelease, then assets. pick_tag depends on that order.
release() {
  # release <tag> <draft> <prerelease> <asset-name>
  printf '{"url":"x","id":1,"tag_name":"%s","name":"n","draft":%s,"prerelease":%s,"assets":[{"name":"%s","browser_download_url":"http://x/%s"}]}' \
    "$1" "$2" "$3" "$4" "$4"
}

releases() {
  printf '['
  first=1
  for entry in "$@"; do
    [ "${first}" = 1 ] || printf ','
    first=0
    printf '%s' "${entry}"
  done
  printf ']'
}

asset="fvm-macos-arm64.zip"

check "newest release wins" "v0.3.0" "$(
  releases \
    "$(release v0.3.0 false false "${asset}")" \
    "$(release v0.2.0 false false "${asset}")" \
    | pick_tag "${asset}"
)"

check "draft skipped" "v0.2.0" "$(
  releases \
    "$(release v0.9.0 true false "${asset}")" \
    "$(release v0.2.0 false false "${asset}")" \
    | pick_tag "${asset}"
)"

check "prerelease skipped" "v0.2.0" "$(
  releases \
    "$(release v0.9.0 false true "${asset}")" \
    "$(release v0.2.0 false false "${asset}")" \
    | pick_tag "${asset}"
)"

# The whole reason /releases/latest is not used: a newer release for something
# else takes the "latest" slot and carries no fvm binary at all.
check "release without our asset skipped" "v0.2.0" "$(
  releases \
    "$(release v0.4.0 false false "some-other-package.zip")" \
    "$(release v0.2.0 false false "${asset}")" \
    | pick_tag "${asset}"
)"

check "another platform's asset is not ours" "v0.2.0" "$(
  releases \
    "$(release v0.4.0 false false "fvm-linux-x64.zip")" \
    "$(release v0.2.0 false false "${asset}")" \
    | pick_tag "${asset}"
)"

check "nothing matching gives nothing" "" "$(
  releases "$(release v0.4.0 false false "fvm-linux-x64.zip")" | pick_tag "${asset}"
)"

check "no releases at all gives nothing" "" "$(printf '[]' | pick_tag "${asset}")"

# A tag that LOOKS like a prerelease but is not flagged as one. This is the
# shape of the very first release: packages/fvm/pubspec.yaml says 0.1.0-dev, and
# the publish step passes no --prerelease, so GitHub records prerelease: false.
# The filter above is on the FLAG and never on the tag string, so this is picked
# — which is the answer to "would a 0.1.0-dev release be installable at all".
# Pinned as a test because reading the greps invites the opposite conclusion.
check "dev-suffixed tag is picked when the flag is false" "v0.1.0-dev" "$(
  releases "$(release v0.1.0-dev false false "${asset}")" | pick_tag "${asset}"
)"

# ...and the flag, when it IS set, is what does the skipping.
check "dev-suffixed tag is skipped when the flag is true" "" "$(
  releases "$(release v0.1.0-dev false true "${asset}")" | pick_tag "${asset}"
)"

# --- a prerelease is never picked ---------------------------------------------
#
# pick_tag resolves to published releases and to nothing else. There is no flag
# that widens it, so the only thing to prove is that a prerelease sitting NEWER
# than the newest release does not win — which is the shape a repo is in
# whenever a release candidate is up.
mixed="$(releases \
  "$(release v0.3.0-rc.1 false true "${asset}")" \
  "$(release v0.2.0 false false "${asset}")")"

check "the release is picked over a newer prerelease" "v0.2.0" \
  "$(printf '%s' "${mixed}" | pick_tag "${asset}")"

# THE REGRESSION GUARD FOR THE DEFAULT PATH, as its own case rather than as a
# side effect of the mixed page above: a page with nothing on it but prereleases
# must give NOTHING. A fallback here would install unreleased code on a machine
# that never asked for it, under a success message.
check "never falls back to a prerelease" "" "$(
  releases \
    "$(release v0.3.0-rc.1 false true "${asset}")" \
    "$(release v0.9.0-beta false true "${asset}")" \
    | pick_tag "${asset}"
)"

# --- picking a release, as GitHub ACTUALLY sends it ---------------------------

# Everything above is one line of JSON, and the real API is not: GitHub
# pretty-prints /releases across tens of thousands of lines. That difference
# used to be invisible here and fatal in production — pick_tag matched nothing
# on a real response, and install.sh reported it as "no release carries this
# asset", which reads like a rate limit. The `tr` in pick_tag is what handles
# it; these fixtures are the reason it cannot quietly go away again.
#
# Indentation and key order below are copied from a real
# api.github.com/repos/.../releases body.
release_pretty() {
  # release_pretty <tag> <draft> <prerelease> <asset-name>
  printf '  {\n'
  printf '    "url": "https://api.github.com/repos/x/y/releases/1",\n'
  printf '    "id": 1,\n'
  printf '    "tag_name": "%s",\n' "$1"
  printf '    "name": "some release title",\n'
  printf '    "draft": %s,\n' "$2"
  printf '    "prerelease": %s,\n' "$3"
  printf '    "assets": [\n'
  printf '      {\n'
  printf '        "name": "%s",\n' "$4"
  printf '        "browser_download_url": "http://x/%s"\n' "$4"
  printf '      }\n'
  printf '    ]\n'
  printf '  }'
}

releases_pretty() {
  printf '[\n'
  first=1
  for entry in "$@"; do
    [ "${first}" = 1 ] || printf ',\n'
    first=0
    printf '%s' "${entry}"
  done
  printf '\n]\n'
}

check "pretty: newest release wins" "v0.3.0" "$(
  releases_pretty \
    "$(release_pretty v0.3.0 false false "${asset}")" \
    "$(release_pretty v0.2.0 false false "${asset}")" \
    | pick_tag "${asset}"
)"

check "pretty: draft skipped" "v0.2.0" "$(
  releases_pretty \
    "$(release_pretty v0.9.0 true false "${asset}")" \
    "$(release_pretty v0.2.0 false false "${asset}")" \
    | pick_tag "${asset}"
)"

check "pretty: prerelease skipped" "v0.2.0" "$(
  releases_pretty \
    "$(release_pretty v0.9.0 false true "${asset}")" \
    "$(release_pretty v0.2.0 false false "${asset}")" \
    | pick_tag "${asset}"
)"

check "pretty: release without our asset skipped" "v0.2.0" "$(
  releases_pretty \
    "$(release_pretty v0.4.0 false false "some-other-package.zip")" \
    "$(release_pretty v0.2.0 false false "${asset}")" \
    | pick_tag "${asset}"
)"

check "pretty: another platform's asset is not ours" "v0.2.0" "$(
  releases_pretty \
    "$(release_pretty v0.4.0 false false "fvm-linux-x64.zip")" \
    "$(release_pretty v0.2.0 false false "${asset}")" \
    | pick_tag "${asset}"
)"

check "pretty: dev-suffixed tag is picked when the flag is false" "v0.1.0-dev" "$(
  releases_pretty "$(release_pretty v0.1.0-dev false false "${asset}")" \
    | pick_tag "${asset}"
)"

check "pretty: nothing matching gives nothing" "" "$(
  releases_pretty "$(release_pretty v0.4.0 false false "fvm-linux-x64.zip")" \
    | pick_tag "${asset}"
)"

# The prerelease filter, against the response shape GitHub actually sends: a
# regression in the `tr` would break it exactly as invisibly as it once broke
# the asset filter.
mixed_pretty="$(releases_pretty \
  "$(release_pretty v0.3.0-rc.1 false true "${asset}")" \
  "$(release_pretty v0.2.0 false false "${asset}")")"

check "pretty: the release is picked over a newer prerelease" "v0.2.0" \
  "$(printf '%s' "${mixed_pretty}" | pick_tag "${asset}")"

# --- installing, end to end ---------------------------------------------------

# The download functions are shadowed to read from a fixture directory, so
# everything after the download — checksum verification, unzipping, the atomic
# move into place, the PATH advice — runs exactly as it does for a real install.
fixtures=""
fetch_file() {
  cp "${fixtures}/$(basename "$1")" "$2" 2> /dev/null \
    || die "could not download $1"
}

make_fixture() {
  # make_fixture <dir> <zip-entry-name> <checksum-mode>
  rm -rf "$1"
  mkdir -p "$1/build"
  printf '#!/bin/sh\necho fvm\n' > "$1/build/$2"
  (cd "$1/build" && zip -q -X "../fvm-${e2e_target}.zip" "$2")
  if [ "$3" = "bad" ]; then
    printf '%s  fvm-%s.zip\n' "0000000000000000000000000000000000000000000000000000000000000000" \
      "${e2e_target}" > "$1/fvm-${e2e_target}.zip.sha256"
  else
    (cd "$1" && (sha256sum "fvm-${e2e_target}.zip" 2> /dev/null \
      || shasum -a 256 "fvm-${e2e_target}.zip") > "fvm-${e2e_target}.zip.sha256")
  fi
}

if ! command -v zip > /dev/null 2>&1; then
  echo "skip install-into-place checks: no zip on this machine"
else
  fake_uname_s="Linux"
  fake_uname_m="x86_64"
  e2e_target="linux-x64"
  workdir="$(mktemp -d)"
  trap 'rm -rf "${workdir}"' EXIT INT TERM

  FVM_VERSION="0.2.0"
  export FVM_VERSION

  # Happy path.
  #
  # HOME is pinned to an empty directory rather than inherited. main now scans
  # the startup files BEFORE it chooses what to print — a shadow changes the
  # message — so a maintainer whose own ~/.zshrc sources the older cbracken/fvm
  # would otherwise see a different branch here than CI does.
  e2e_home="${workdir}/e2e-home"
  mkdir -p "${e2e_home}"
  fixtures="${workdir}/good"
  make_fixture "${fixtures}" fvm ok
  HOME="${e2e_home}" \
    FVM_HOME="${workdir}/home-good" \
    PATH="${PATH}" \
    output="$( (main) 2>&1 )" || output="MAIN FAILED: ${output}"

  check "installs the binary" "0" \
    "$([ -x "${workdir}/home-good/bin/fvm" ] && echo 0 || echo 1)"
  check "no temp file left behind" "1" \
    "$([ -e "${workdir}/home-good/bin/fvm.new" ] && echo 0 || echo 1)"
  check "tells the user about PATH" "0" \
    "$(echo "${output}" \
      | grep -q "export PATH=\"${workdir}/home-good/shims:${workdir}/home-good/bin:" \
      && echo 0 || echo 1)"

  # A checksum that does not match must abort before anything is written.
  fixtures="${workdir}/bad"
  make_fixture "${fixtures}" fvm bad
  if FVM_HOME="${workdir}/home-bad" output="$( (main) 2>&1 )"; then
    check "checksum mismatch refuses" "refused" "installed anyway"
  else
    check "checksum mismatch refuses" "refused" "refused"
  fi
  check "checksum mismatch says so" "0" \
    "$(echo "${output}" | grep -q "checksum mismatch" && echo 0 || echo 1)"
  check "checksum mismatch installs nothing" "1" \
    "$([ -e "${workdir}/home-bad/bin/fvm" ] && echo 0 || echo 1)"

  # An asset that is a zip but holds no fvm.
  fixtures="${workdir}/empty"
  make_fixture "${fixtures}" NOTES.txt ok
  if FVM_HOME="${workdir}/home-empty" output="$( (main) 2>&1 )"; then
    check "asset without a fvm refuses" "refused" "installed anyway"
  else
    check "asset without a fvm refuses" "refused" "refused"
  fi
  check "asset without a fvm installs nothing" "1" \
    "$([ -e "${workdir}/home-empty/bin/fvm" ] && echo 0 || echo 1)"

  # A zip holding fvm inside a directory rather than at the root.
  # tool/package_release_assets.sh zips from inside the binary's directory so the
  # asset is flat, and install.sh looks for exactly "${tmp}/unpacked/fvm" — so a
  # nested one installs nothing. updater.dart:434 takes the basename and would
  # survive it, which is precisely why this asymmetry is worth a test: a change
  # that nested the asset would keep `fvm update` working and silently break
  # every FIRST install, and no unit test on either side would notice.
  fixtures="${workdir}/nested"
  rm -rf "${fixtures}"
  mkdir -p "${fixtures}/build/fvm-${e2e_target}"
  printf '#!/bin/sh\necho fvm\n' > "${fixtures}/build/fvm-${e2e_target}/fvm"
  (cd "${fixtures}/build" && zip -q -X -r "../fvm-${e2e_target}.zip" \
    "fvm-${e2e_target}")
  (cd "${fixtures}" && (sha256sum "fvm-${e2e_target}.zip" 2> /dev/null \
    || shasum -a 256 "fvm-${e2e_target}.zip") > "fvm-${e2e_target}.zip.sha256")

  if FVM_HOME="${workdir}/home-nested" output="$( (main) 2>&1 )"; then
    check "nested asset refuses" "refused" "installed anyway"
  else
    check "nested asset refuses" "refused" "refused"
  fi
  check "nested asset installs nothing" "1" \
    "$([ -e "${workdir}/home-nested/bin/fvm" ] && echo 0 || echo 1)"

  unset FVM_VERSION
fi


# --- a shadowing fvm ----------------------------------------------------------

# The failure this covers, exactly as it happened: install.sh finished cleanly,
# told the user to run `fvm setup`, and `fvm setup` ran the OLDER cbracken/fvm
# because ~/.zshrc:107 sources its shell script and a function beats PATH. The
# scan below is what turns "bad option: -t" into a file and a line number.
shadow_home="$(mktemp -d)"
mkdir -p "${shadow_home}/.config/fish"

# A .zshrc whose 107th line is the one that bit the user. Every line before it
# is filler so the reported number has to be counted and cannot be guessed.
i=1
while [ "${i}" -lt 107 ]; do
  echo "# filler line ${i}"
  i=$((i + 1))
done > "${shadow_home}/.zshrc"
printf '%s\n' '[ -s "$HOME/.fvm/scripts/fvm" ] && . "$HOME/.fvm/scripts/fvm"' \
  >> "${shadow_home}/.zshrc"

check "legacy source line is found" "0" \
  "$(scan_rc_file "${shadow_home}/.zshrc" | grep -q 'sourcing a conflicting fvm shell script' \
    && echo 0 || echo 1)"

# The whole point of the message: a file AND a line, not "found something".
check "legacy source line reports .zshrc:107" "${shadow_home}/.zshrc:107" \
  "$(scan_rc_file "${shadow_home}/.zshrc" | sed -n 's/^\([^ ]*:[0-9]*\):.*/\1/p')"

check "legacy source line quotes the line itself" "0" \
  "$(scan_rc_file "${shadow_home}/.zshrc" \
    | grep -qF '. "$HOME/.fvm/scripts/fvm"' && echo 0 || echo 1)"

# A function definition, in each of the spellings that actually appear.
for definition in 'fvm() {' 'fvm () {' 'fvm(){' 'function fvm {' 'function fvm() {'; do
  printf '%s\n  echo hi\n}\n' "${definition}" > "${shadow_home}/.bashrc"
  check "function definition [${definition}] is found" "0" \
    "$(scan_rc_file "${shadow_home}/.bashrc" | grep -q 'a shell function named fvm' \
      && echo 0 || echo 1)"
done

printf 'alias fvm="~/bin/fvm"\n' > "${shadow_home}/.bash_profile"
check "alias is found" "0" \
  "$(scan_rc_file "${shadow_home}/.bash_profile" | grep -q 'a shell alias named fvm' \
    && echo 0 || echo 1)"
check "alias reports its line" "${shadow_home}/.bash_profile:1" \
  "$(scan_rc_file "${shadow_home}/.bash_profile" | sed -n 's/^\([^ ]*:[0-9]*\):.*/\1/p')"

# FALSE POSITIVES. A startup file that merely mentions fvm is the common case,
# and warning about it sends the user to edit a file that is already correct.
cat > "${shadow_home}/.profile" << 'CLEAN'
# fvm lives in ~/.fvm/bin
export PATH="$HOME/.fvm/bin:$PATH"
fvm use 3.5.0
alias fvmx="fvm --verbose"
# fvm() { echo the old one; }
# alias fvm=nope
echo "run fvm setup"
FVM_HOME="$HOME/.fvm"
CLEAN
check "a clean startup file warns about nothing" "" \
  "$(scan_rc_file "${shadow_home}/.profile")"

# Missing and unreadable files are ordinary, not errors.
check "a missing startup file is silent" "" \
  "$(scan_rc_file "${shadow_home}/.does-not-exist")"

printf 'fvm() { echo hi; }\n' > "${shadow_home}/.zprofile"
chmod 000 "${shadow_home}/.zprofile"
if [ -r "${shadow_home}/.zprofile" ]; then
  # Running as root, where chmod 000 does not make a file unreadable.
  echo "skip unreadable-file check: this user can read a 000 file"
else
  check "an unreadable startup file is silent" "" \
    "$(scan_rc_file "${shadow_home}/.zprofile")"
  check "an unreadable startup file does not fail the run" "0" \
    "$(scan_rc_file "${shadow_home}/.zprofile" > /dev/null 2>&1; echo $?)"
fi
chmod 644 "${shadow_home}/.zprofile"

# The whole-home sweep reaches every candidate, and .zprofile is readable again.
check "the sweep reaches .zshrc, .bashrc, .bash_profile and .zprofile" "4" \
  "$(scan_startup_files "${shadow_home}" | wc -l | tr -d ' ')"

check "the sweep on a home with no startup files is silent" "" \
  "$(scan_startup_files "$(mktemp -d)")"

check "the sweep with no home at all is silent" "" "$(scan_startup_files "")"

# --- the closing message ------------------------------------------------------

if ! command -v zip > /dev/null 2>&1; then
  echo "skip closing-message checks: no zip on this machine"
else
  fake_uname_s="Linux"
  fake_uname_m="x86_64"
  e2e_target="linux-x64"
  msgdir="$(mktemp -d)"
  fixtures="${msgdir}/good"
  make_fixture "${fixtures}" fvm ok

  FVM_VERSION="0.2.0"
  export FVM_VERSION

  # A home with nothing shadowing fvm in it.
  clean_home="${msgdir}/clean-home"
  mkdir -p "${clean_home}"
  printf 'export PATH="$HOME/bin:$PATH"\n' > "${clean_home}/.zshrc"

  clean_status=0
  clean_out="$(HOME="${clean_home}" FVM_HOME="${msgdir}/clean-fvm" main 2>&1)" \
    || clean_status=$?

  check "a clean install still exits 0" "0" "${clean_status}"
  check "a clean install prints no shadow warning" "1" \
    "$(echo "${clean_out}" | grep -q 'already defines its own' && echo 0 || echo 1)"

  # OPTION A — one command, by the absolute path this script just wrote. fvm
  # does not have to be on PATH to be RUN, which is the whole reason the setup
  # collapses to one step. Asserted as the FULL command: naming the flag alone
  # would pass on the old three-step message, which named it too.
  check "a clean install offers the one absolute-path command" "0" \
    "$(echo "${clean_out}" \
      | grep -q "${msgdir}/clean-fvm/bin/fvm setup --write-path-line" \
      && echo 0 || echo 1)"

  # OPTION B — one line, for someone who would rather fvm did not edit their
  # files. ONE line covering BOTH directories, not one line each: two lines is
  # two things to paste and two chances to paste only the first.
  check "a clean install offers one combined export line" "0" \
    "$(echo "${clean_out}" \
      | grep -q "export PATH=\"${msgdir}/clean-fvm/shims:${msgdir}/clean-fvm/bin:" \
      && echo 0 || echo 1)"

  # THE REGRESSION GUARD, and the reason it is asserted as literal text: a
  # startup-file line that assigns an EXPANDED absolute PATH discards
  # everything PATH held before it — silently, on every login, erasing whatever
  # the user's own earlier lines added. The line must end with the six
  # characters `$PATH` and a quote, unexpanded. Single quotes below so this
  # test's own shell does not expand it either.
  check "the export line keeps \$PATH literal" "0" \
    "$(echo "${clean_out}" | grep -q 'export PATH="[^"]*:\$PATH"' \
      && echo 0 || echo 1)"
  check "the export line did not bake in an expanded PATH" "1" \
    "$(echo "${clean_out}" | grep -q "export PATH=\"[^\"]*:/usr/bin" \
      && echo 0 || echo 1)"

  # Absolute paths throughout: the point is a line that can be pasted without
  # thinking, and `$HOME/.fvm/...` is a line the reader has to resolve first.
  check "a clean install prints no ~ or \$HOME in its paths" "1" \
    "$(echo "${clean_out}" | grep -q 'PATH="\$HOME\|PATH="~' && echo 0 || echo 1)"

  # THE SAME BYTES, not merely the same facts. main's closing message and
  # print_next_steps' output are asserted equal so the extraction cannot rot
  # into two messages that agree in summary and differ in what a user pastes.
  # Line 4 onward is the message: 1 is "Downloading...", 2 blank, 3 is the
  # "installed at" line, and the function opens with a blank line of its own.
  clean_fn_out="$(
    PATH="/usr/bin:/bin"
    print_next_steps "" "${msgdir}/clean-fvm" "${msgdir}/clean-fvm/bin"
  )"
  check "main's closing message IS print_next_steps, byte for byte" \
    "${clean_fn_out}" "$(printf '%s\n' "${clean_out}" | sed -n '4,$p')"

  # The other branch of the same case: ~/.fvm/bin is already on PATH. The
  # SHIMS half can still be missing, so this branch is not "nothing to do" —
  # it is the same two options, shrunk to the half that is still needed.
  onpath_out="$(HOME="${clean_home}" FVM_HOME="${msgdir}/onpath-fvm" \
    PATH="${msgdir}/onpath-fvm/bin:${PATH}" main 2>&1)"

  check "the already-on-PATH branch still offers the one command" "0" \
    "$(echo "${onpath_out}" \
      | grep -q "${msgdir}/onpath-fvm/bin/fvm setup --write-path-line" \
      && echo 0 || echo 1)"
  check "the already-on-PATH branch offers the shims line" "0" \
    "$(echo "${onpath_out}" \
      | grep -q "export PATH=\"${msgdir}/onpath-fvm/shims:" \
      && echo 0 || echo 1)"
  # ...and does NOT re-add the directory that is already there.
  check "the already-on-PATH branch does not re-add bin" "1" \
    "$(echo "${onpath_out}" | grep -q "shims:${msgdir}/onpath-fvm/bin:" \
      && echo 0 || echo 1)"
  check "the already-on-PATH line keeps \$PATH literal" "0" \
    "$(echo "${onpath_out}" | grep -q 'export PATH="[^"]*:\$PATH"' \
      && echo 0 || echo 1)"

  onpath_fn_out="$(
    PATH="${msgdir}/onpath-fvm/bin:/usr/bin:/bin"
    print_next_steps "" "${msgdir}/onpath-fvm" "${msgdir}/onpath-fvm/bin"
  )"
  check "the already-on-PATH message IS print_next_steps, byte for byte" \
    "${onpath_fn_out}" "$(printf '%s\n' "${onpath_out}" | sed -n '4,$p')"

  # The same install into a home that has the user's .zshrc:107 in it.
  shadowed_home="${msgdir}/shadowed-home"
  mkdir -p "${shadowed_home}"
  i=1
  while [ "${i}" -lt 107 ]; do
    echo "# filler line ${i}"
    i=$((i + 1))
  done > "${shadowed_home}/.zshrc"
  printf '%s\n' '[ -s "$HOME/.fvm/scripts/fvm" ] && . "$HOME/.fvm/scripts/fvm"' \
    >> "${shadowed_home}/.zshrc"

  shadow_status=0
  shadow_out="$(HOME="${shadowed_home}" FVM_HOME="${msgdir}/shadow-fvm" main 2>&1)" \
    || shadow_status=$?

  # The binary is good and on disk; a warning is not a reason to fail.
  check "a shadowed install still exits 0" "0" "${shadow_status}"
  check "a shadowed install still installs the binary" "0" \
    "$([ -x "${msgdir}/shadow-fvm/bin/fvm" ] && echo 0 || echo 1)"

  check "a shadowed install says the shell defines its own fvm" "0" \
    "$(echo "${shadow_out}" | grep -q 'already defines its own' && echo 0 || echo 1)"
  check "a shadowed install names the file and the line" "0" \
    "$(echo "${shadow_out}" | grep -q "${shadowed_home}/.zshrc:107:" && echo 0 || echo 1)"
  check "a shadowed install says to comment the line out" "0" \
    "$(echo "${shadow_out}" | grep -q 'comment out the line' && echo 0 || echo 1)"
  check "a shadowed install says to start a new shell" "0" \
    "$(echo "${shadow_out}" | grep -q 'start a new shell' && echo 0 || echo 1)"

  # --write-path-line REFUSES while a shadow is present (the `blocked:` guard in
  # setup_command.dart), so the message must order it after the fix rather than
  # hand the user a flag that is guaranteed to decline.
  check "a shadowed install defers --write-path-line" "0" \
    "$(echo "${shadow_out}" | grep -q 'refuses to write' && echo 0 || echo 1)"
  check "a shadowed install orders the fix first" "0" \
    "$(echo "${shadow_out}" | grep -q '1. comment out the line' && echo 0 || echo 1)"

  # And the command is step 3 of that fix, not the headline. A shadowed shell
  # is exactly where `--write-path-line` refuses, so leading with the one-step
  # command would be handing the user something guaranteed to decline.
  check "a shadowed install names the command as step 3" "0" \
    "$(echo "${shadow_out}" \
      | grep -q "${msgdir}/shadow-fvm/bin/fvm setup --write-path-line" \
      && echo 0 || echo 1)"
  check "a shadowed install does not lead with the one command" "1" \
    "$(echo "${shadow_out}" | grep -q 'One command finishes the setup' \
      && echo 0 || echo 1)"
  # Nor does it hand out an export line to paste while the shadow is live: the
  # shadow beats PATH, so the line would change nothing.
  check "a shadowed install hands out no export line" "1" \
    "$(echo "${shadow_out}" | grep -q 'export PATH=' && echo 0 || echo 1)"
  check "a shadowed install says what to clear first" "0" \
    "$(echo "${shadow_out}" | grep -q 'startup files to clear' && echo 0 || echo 1)"

  unset FVM_VERSION
  rm -rf "${msgdir}"
fi

rm -rf "${shadow_home}"

# --- the closing message as a CALLABLE function -------------------------------

# It has to be callable, and not merely correct inside main. tool/install_from_main.sh
# installs a build of the checkout and has to close with the same words; while
# this block lived inline in main() it could not be called, so that script
# carried a hand-copy of it, and the copy went stale the day the message was
# rewritten. These checks are what keep it callable — a future refactor that
# folds it back into main fails here before it can grow a second copy.
fn_home="/nowhere/fvm"
fn_bin="${fn_home}/bin"

fn_offpath="$( PATH="/usr/bin:/bin"; print_next_steps "" "${fn_home}" "${fn_bin}" )"
fn_onpath="$( PATH="${fn_bin}:/usr/bin:/bin"; print_next_steps "" "${fn_home}" "${fn_bin}" )"
fn_shadowed="$(
  PATH="/usr/bin:/bin"
  print_next_steps "/nowhere/.zshrc:107: . fvm   (a shell function named fvm)" \
    "${fn_home}" "${fn_bin}"
)"

check "the function is defined by sourcing in library mode" "0" \
  "$(command -v print_next_steps > /dev/null 2>&1 && echo 0 || echo 1)"

# The off-PATH branch: one command by absolute path, and ONE export line
# covering both directories for someone who would rather paste it themselves.
check "off-PATH branch offers the one absolute-path command" "0" \
  "$(echo "${fn_offpath}" | grep -q "${fn_bin}/fvm setup --write-path-line" \
    && echo 0 || echo 1)"
check "off-PATH branch offers one line covering both directories" "0" \
  "$(echo "${fn_offpath}" | grep -q "export PATH=\"${fn_home}/shims:${fn_bin}:" \
    && echo 0 || echo 1)"

# The on-PATH branch: the same two options, shrunk to the shims half.
check "on-PATH branch offers the one absolute-path command" "0" \
  "$(echo "${fn_onpath}" | grep -q "${fn_bin}/fvm setup --write-path-line" \
    && echo 0 || echo 1)"
check "on-PATH branch offers the shims line" "0" \
  "$(echo "${fn_onpath}" | grep -q "export PATH=\"${fn_home}/shims:" \
    && echo 0 || echo 1)"
check "on-PATH branch does not re-add the bin directory" "1" \
  "$(echo "${fn_onpath}" | grep -q "shims:${fn_bin}:" && echo 0 || echo 1)"

# Both branches, and the whole reason this is asserted as literal text: a
# startup-file line assigning an EXPANDED absolute PATH discards everything
# PATH held before it, silently, on every login. Single quotes so this test's
# own shell does not expand it either.
check "off-PATH branch keeps \$PATH literal" "0" \
  "$(echo "${fn_offpath}" | grep -q 'export PATH="[^"]*:\$PATH"' && echo 0 || echo 1)"
check "on-PATH branch keeps \$PATH literal" "0" \
  "$(echo "${fn_onpath}" | grep -q 'export PATH="[^"]*:\$PATH"' && echo 0 || echo 1)"

# The shadowed case: point at the fix and hand out NOTHING to paste. A `fvm`
# function or alias beats PATH, so an export line would change nothing while
# looking like it worked, and `--write-path-line` refuses to write at all.
# warn_about_shadows is what orders the fix; this only defers to it.
check "the shadowed case says what to clear first" "0" \
  "$(echo "${fn_shadowed}" | grep -q 'startup files to clear' && echo 0 || echo 1)"
check "the shadowed case does not lead with the one command" "1" \
  "$(echo "${fn_shadowed}" | grep -q 'One command finishes the setup' && echo 0 || echo 1)"
check "the shadowed case hands out no export line" "1" \
  "$(echo "${fn_shadowed}" | grep -q 'export PATH=' && echo 0 || echo 1)"

# --- tool/install_from_main.sh, run for real ----------------------------------

# The bug that actually reached a user, and the only kind of check that catches
# it: install_from_main.sh called warn_about_shadows with TWO arguments after
# that function grew a third, so under `set -u` it died on "$3: unbound
# variable" — after installing the binary, before printing one word of
# guidance. It parses fine; `sh -n` sees nothing wrong. Nothing but running it
# fails on a wrong-arity call into install.sh, and nothing ran it, because the
# script was untracked.
#
# `dart` is stubbed rather than invoked: this is about the closing sequence,
# not about compiling fvm, and a real `dart compile exe` is a minute per run.
fromdir="$(mktemp -d)"
fake_bin="${fromdir}/fakebin"
mkdir -p "${fake_bin}"
cat > "${fake_bin}/dart" << 'FAKEDART'
#!/bin/sh
# Stands in for `dart compile exe <src> -o <out>`: writes something executable
# at <out> and nothing else.
out=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then
    out="$2"
    shift
  fi
  shift
done
[ -n "${out}" ] || exit 1
printf '#!/bin/sh\necho fvm\n' > "${out}"
chmod 755 "${out}"
FAKEDART
chmod 755 "${fake_bin}/dart"

from_home="${fromdir}/home"
mkdir -p "${from_home}"
printf 'export PATH="$HOME/bin:$PATH"\n' > "${from_home}/.zshrc"
from_fvm="${fromdir}/fvm"

from_status=0
from_out="$(HOME="${from_home}" FVM_HOME="${from_fvm}" PATH="${fake_bin}:${PATH}" \
  sh "${root}/tool/install_from_main.sh" 2>&1)" || from_status=$?

# EXIT STATUS IS NOT ENOUGH, and finding that out is half of why this section
# exists. The arity bug aborts the script part-way under `set -u` — and
# install_from_main.sh carries a `trap ... EXIT` to remove its temp dir, so the
# trap body succeeds and REPLACES the failing status with 0. Measured on the
# broken script: exits 1 with no trap, 0 with one under bash (macOS /bin/sh),
# 2 under dash. A machine can therefore report a clean install of a script that
# died before saying anything, which is exactly what happened to the user.
#
# So what is asserted is that it REACHED ITS LAST LINE and printed no shell
# error. The status check stays because it is free and it does fail on the
# shells where it works, but nothing here rests on it.
check "install_from_main.sh exits 0" "0" "${from_status}"
check "install_from_main.sh reaches its last line" "0" \
  "$(printf '%s\n' "${from_out}" | tail -n 1 | grep -q -- '-v doctor' \
    && echo 0 || echo 1)"
check "install_from_main.sh reports no shell error" "1" \
  "$(echo "${from_out}" | grep -q 'unbound variable\|parameter not set' \
    && echo 0 || echo 1)"
check "install_from_main.sh installs the binary" "0" \
  "$([ -x "${from_fvm}/bin/fvm" ] && echo 0 || echo 1)"

# Not "it printed something about PATH" — the SAME BYTES install.sh prints. This
# is the assertion the hand-copy could never have passed.
from_fn_out="$(
  PATH="${fake_bin}:${PATH}"
  print_next_steps "" "${from_fvm}" "${from_fvm}/bin"
)"
case "${from_out}" in
  *"${from_fn_out}"*) from_match=0 ;;
  *) from_match=1 ;;
esac
check "install_from_main.sh closes with install.sh's own message, verbatim" "0" \
  "${from_match}"

rm -rf "${fromdir}"

# --- the real script, invoked the way a user invokes it ------------------------
#
# Everything above calls install.sh's functions IN THIS PROCESS, which cannot
# answer the one question a pasted command depends on: does the invocation
# itself work? `sh install.sh` and `curl … | sh` reach the script by different
# routes, and the piped one — the documented one, the one people actually paste
# — is the one most likely to break.
#
# So this runs install.sh as a SUBPROCESS with a fake `curl` first on PATH. Two
# things make that a real test rather than a stub:
#
#   - the fake serves the releases page from a fixture, so the prerelease filter
#     runs on JSON rather than on a mock of pick_tag, and
#   - it serves each asset from a directory named after the TAG in the download
#     URL, and the two tags' binaries differ in their contents. A run that
#     resolves the wrong tag installs the wrong bytes, and the assertions below
#     are on the bytes rather than on the message that claims them.
if ! command -v zip > /dev/null 2>&1; then
  echo "skip real-invocation checks: no zip on this machine"
else
  # The earlier sections leave FVM_VERSION exported, and it would pin every run
  # below to one tag. Cleared here rather than assumed, because which of those
  # blocks ran at all depends on what is installed on the machine.
  unset FVM_VERSION || true

  # THE HOST'S REAL TARGET, not a faked one: this subprocess runs the real
  # `uname`, so the asset it asks for is the one this machine's install would ask
  # for. `command uname` steps past the shell function defined at the top.
  fake_uname_s="$(command uname -s)"
  fake_uname_m="$(command uname -m)"
  cli_target="$( (detect_target) 2> /dev/null || echo "" )"

  if [ -z "${cli_target}" ]; then
    echo "skip real-invocation checks: install.sh does not support this host"
  else
    cli_asset="fvm-${cli_target}.zip"
    cli_dir="$(mktemp -d)"
    cli_bin="${cli_dir}/bin"
    cli_assets="${cli_dir}/assets"
    mkdir -p "${cli_bin}"

    # One asset per tag, each binary saying which tag it came from.
    for cli_tag in v0.3.0-rc.1 v0.2.0; do
      mkdir -p "${cli_assets}/${cli_tag}/build"
      printf '#!/bin/sh\necho fvm from %s\n' "${cli_tag}" \
        > "${cli_assets}/${cli_tag}/build/fvm"
      (
        cd "${cli_assets}/${cli_tag}/build"
        zip -q -X "../${cli_asset}" fvm
      )
      (
        cd "${cli_assets}/${cli_tag}"
        (sha256sum "${cli_asset}" 2> /dev/null || shasum -a 256 "${cli_asset}") \
          > "${cli_asset}.sha256"
      )
    done

    # `curl`, as far as install.sh can tell. It parses the same flags install.sh
    # passes (`-fsSL`, an optional `-H`, an optional `-o`) and exits 22 — curl's
    # own "HTTP error" status — for anything it was not given, so a run that asks
    # for the wrong tag fails the way a 404 does instead of quietly succeeding.
    cat > "${cli_bin}/curl" << 'FAKECURL'
#!/bin/sh
set -eu
fake_out=""
fake_url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      fake_out="$2"
      shift 2
      ;;
    -H) shift 2 ;;
    -*) shift ;;
    *)
      fake_url="$1"
      shift
      ;;
  esac
done

case "${fake_url}" in
  *api.github.com*releases*)
    cat "${FAKE_RELEASES_JSON}"
    ;;
  *)
    # .../releases/download/<tag>/<asset>
    fake_asset="${fake_url##*/}"
    fake_rest="${fake_url%/*}"
    fake_tag="${fake_rest##*/}"
    fake_src="${FAKE_ASSET_ROOT}/${fake_tag}/${fake_asset}"
    [ -f "${fake_src}" ] || exit 22
    if [ -n "${fake_out}" ]; then
      cp "${fake_src}" "${fake_out}"
    else
      cat "${fake_src}"
    fi
    ;;
esac
FAKECURL
    chmod 755 "${cli_bin}/curl"

    # A page with a prerelease sitting NEWER than the release, which is the
    # shape a repo is in whenever a release candidate is up.
    releases \
      "$(release v0.3.0-rc.1 false true "${cli_asset}")" \
      "$(release v0.2.0 false false "${cli_asset}")" \
      > "${cli_dir}/both.json"

    cli_home="${cli_dir}/home"
    mkdir -p "${cli_home}"

    # cli_run <fvm-home-name> <releases-fixture> [args...]
    #
    # Runs the real install.sh in a subprocess and leaves its combined output in
    # cli_out and its exit status in cli_status.
    #
    # FVM_INSTALL_SH_LIB IS CLEARED FOR THE SUBPROCESS. This file exports it as
    # 1 so it can source install.sh without running main; a subprocess inherits
    # that and skips main too — exiting 0 having printed nothing and installed
    # nothing, which reads exactly like a successful install to anything that
    # checks only the status.
    #
    # THROUGH A FILE AND NOT A COMMAND SUBSTITUTION, and not for tidiness:
    # `cli_out="$(cli_run …)"` runs the function in a SUBSHELL, so the exit
    # status it recorded would be thrown away with that subshell and every
    # `check` on cli_status would read whatever the previous run left behind.
    # Two variables set here, nothing captured at the call site.
    cli_run() {
      cli_run_home="${cli_dir}/$1"
      cli_run_json="${cli_dir}/$2"
      shift 2
      cli_status=0
      PATH="${cli_bin}:${PATH}" \
        FVM_INSTALL_SH_LIB="" \
        HOME="${cli_home}" \
        FVM_HOME="${cli_run_home}" \
        FAKE_RELEASES_JSON="${cli_run_json}" \
        FAKE_ASSET_ROOT="${cli_assets}" \
        sh "${root}/install.sh" "$@" > "${cli_dir}/out.txt" 2>&1 \
        || cli_status=$?
      cli_out="$(cat "${cli_dir}/out.txt")"
      return 0
    }

    # cli_run_piped <fvm-home-name> <releases-fixture> [args...]
    #
    # THE DOCUMENTED SPELLING. `sh -s --` is what the README's curl line becomes
    # once it is given an option, and it is a different path from `sh
    # install.sh`: sh reads the script from stdin, and `--` is what stops sh from
    # claiming the option for itself. Piped from a file rather than from the
    # network, which is the only part that is faked.
    cli_run_piped() {
      cli_run_home="${cli_dir}/$1"
      cli_run_json="${cli_dir}/$2"
      shift 2
      cli_status=0
      PATH="${cli_bin}:${PATH}" \
        FVM_INSTALL_SH_LIB="" \
        HOME="${cli_home}" \
        FVM_HOME="${cli_run_home}" \
        FAKE_RELEASES_JSON="${cli_run_json}" \
        FAKE_ASSET_ROOT="${cli_assets}" \
        sh -s -- "$@" < "${root}/install.sh" > "${cli_dir}/out.txt" 2>&1 \
        || cli_status=$?
      cli_out="$(cat "${cli_dir}/out.txt")"
      return 0
    }

    # --- a plain install, end to end -----------------------------------------
    #
    # THE REGRESSION GUARD FOR THE DEFAULT PATH, and the whole point of the
    # fixture: the prerelease is right there in the response and NEWER than the
    # release, and a plain install must not go near it. Asserted on the BYTES
    # installed rather than on the message that claims them.

    cli_run stable-default both.json

    check "a plain install exits 0" "0" "${cli_status}"
    check "a plain install installed the RELEASE's asset" "0" \
      "$(grep -q 'from v0.2.0' "${cli_dir}/stable-default/bin/fvm" \
        && echo 0 || echo 1)"
    check "a plain install did not install the prerelease's asset" "1" \
      "$(grep -q 'from v0.3.0-rc.1' "${cli_dir}/stable-default/bin/fvm" \
        && echo 0 || echo 1)"
    check "a plain install names the tag it installed" "0" \
      "$(echo "${cli_out}" | grep -q 'fvm v0.2.0 is installed at' \
        && echo 0 || echo 1)"
    check "a plain install prints the setup step" "0" \
      "$(echo "${cli_out}" | grep -q 'One command finishes the setup' \
        && echo 0 || echo 1)"

    # THE PIPED SPELLING, which is the one the README documents and the one
    # people actually paste. A different path through sh, on the same fixture.
    cli_run_piped stable-piped both.json

    check "a piped plain install exits 0" "0" "${cli_status}"
    check "a piped plain install installed the RELEASE's asset" "0" \
      "$(grep -q 'from v0.2.0' "${cli_dir}/stable-piped/bin/fvm" \
        && echo 0 || echo 1)"

    # --- an unknown flag ------------------------------------------------------

    cli_run bogus-flag both.json --bogus

    check "an unknown flag fails" "1" \
      "$([ "${cli_status}" -eq 0 ] && echo 0 || echo 1)"
    check "an unknown flag names itself" "0" \
      "$(echo "${cli_out}" | grep -q 'unknown option: --bogus' && echo 0 || echo 1)"
    check "an unknown flag prints the usage" "0" \
      "$(echo "${cli_out}" | grep -q 'Usage:' && echo 0 || echo 1)"
    check "an unknown flag installs nothing" "1" \
      "$([ -e "${cli_dir}/bogus-flag/bin/fvm" ] && echo 0 || echo 1)"
    # Exits 2, so a wrapper can tell "you typed it wrong" from "it failed".
    check "an unknown flag exits 2" "2" "${cli_status}"

    # A positional argument is a typo too — `sh install.sh 0.2.0` is the mistake
    # this catches, and the usage it prints names FVM_VERSION.
    cli_run bogus-positional both.json 0.2.0
    check "a positional argument fails" "2" "${cli_status}"
    check "a positional argument installs nothing" "1" \
      "$([ -e "${cli_dir}/bogus-positional/bin/fvm" ] && echo 0 || echo 1)"
    check "the usage names FVM_VERSION for that user" "0" \
      "$(echo "${cli_out}" | grep -q 'FVM_VERSION' && echo 0 || echo 1)"

    # --- --help ---------------------------------------------------------------

    cli_run help both.json --help

    check "--help exits 0" "0" "${cli_status}"
    check "--help installs nothing" "1" \
      "$([ -e "${cli_dir}/help/bin/fvm" ] && echo 0 || echo 1)"
    check "--help documents FVM_VERSION" "0" \
      "$(echo "${cli_out}" | grep -q 'FVM_VERSION' && echo 0 || echo 1)"
    check "--help documents the piped spelling" "0" \
      "$(echo "${cli_out}" | grep -q 'curl -fsSL' && echo 0 || echo 1)"

    # FVM_VERSION names an exact tag and skips the release lookup, which is why
    # the fake API is pointed at a path that does not exist here and nothing
    # notices.
    cli_status=0
    PATH="${cli_bin}:${PATH}" \
      FVM_INSTALL_SH_LIB="" \
      HOME="${cli_home}" \
      FVM_HOME="${cli_dir}/version-only" \
      FVM_VERSION="0.2.0" \
      FAKE_RELEASES_JSON="/does/not/exist" \
      FAKE_ASSET_ROOT="${cli_assets}" \
      sh "${root}/install.sh" > /dev/null 2>&1 || cli_status=$?

    check "FVM_VERSION alone still installs, without an API lookup" "0" \
      "${cli_status}"
    check "FVM_VERSION alone installed the tag it named" "0" \
      "$(grep -q 'from v0.2.0' "${cli_dir}/version-only/bin/fvm" \
        && echo 0 || echo 1)"

    rm -rf "${cli_dir}"
  fi
fi

# --- the workflow behind the installer ----------------------------------------
#
# install.sh can only ever find what a workflow publishes, so the property it
# depends on is asserted in the file that decides it: "release.yml is still
# manual" is exactly the kind of claim that gets made in a commit message and
# then quietly stops being true.

# The keys directly under `on:` in the workflow "$1", one per line. Two-space
# indentation only, so a nested key like `branches:` is not mistaken for a
# trigger, and comment lines inside the block are skipped.
workflow_triggers() {
  awk '
    /^on:/ { in_on = 1; next }
    in_on && /^[^[:space:]#]/ { in_on = 0 }
    in_on && /^  [A-Za-z_]+:/ {
      key = $1
      sub(/:.*/, "", key)
      print key
    }
  ' "$1"
}

release_yml="${root}/.github/workflows/release.yml"

# THE GUARANTEE. release.yml's own header says it: a release goes out only after
# a human chose to publish it, and what enforces that is dispatch being its only
# trigger. Anything that wants to publish from CI on a push is exactly the change
# that would tempt someone to put `push:` back there.
check "release.yml is still workflow_dispatch-only" "workflow_dispatch" \
  "$(workflow_triggers "${release_yml}" | tr '\n' ' ' | sed 's/ *$//')"

# ...and stamp_version.sh still refuses a version the pubspec does not claim,
# which is what makes a published binary unable to lie about its version.
check "stamp_version.sh still refuses a mismatched version" "0" \
  "$(grep -q 'REFUSING to stamp a version the package does not claim' \
    "${root}/tool/stamp_version.sh" && echo 0 || echo 1)"

# --- one copy of the message, and only one ------------------------------------

# THE REGRESSION GUARD. Everything above passes just as well with two copies of
# the message in the repo, as long as both are correct today — and "correct
# today" is exactly what the last copy was, right up until install.sh's message
# was rewritten and it was not. So: the prose may appear in install.sh and
# nowhere else.
#
# WHAT THIS DOES NOT CATCH, stated rather than left to be discovered.
#
# It catches a copy AT THE MOMENT IT IS MADE, while it still matches. It does
# NOT catch one that has already drifted — which is the state the copy is in by
# the time it does damage. Measured, not assumed: the stale copy this leaf
# removed contains neither phrase below, because the wording it duplicated is
# the wording that got replaced. That is fine going forward, since a copy has to
# be made before it can drift and this fires on the making, but it means the
# guard is worthless for finding one that is already out there.
#
# It scans shell scripts only, so the same words pasted into a README or a docs
# page go unnoticed. It excludes THIS file, which quotes fragments of the
# message on purpose as expectations. And a copy that paraphrases rather than
# duplicates is invisible to it.
#
# An untracked script counts. The copy that caused this had never been committed
# — that is why no test ran it and no gate covered it — so this walks the tree
# rather than asking git what is tracked.
for phrase in "One command finishes the setup" "before it exists is deliberate"; do
  copies="$(
    find "${root}" -type f -name '*.sh' \
      ! -path "${root}/install.sh" \
      ! -path "${root}/tool/test_install_sh.sh" \
      ! -path "${root}/.git/*" \
      ! -path "${root}/.worktrees/*" \
      ! -path "${root}/.game_loop/*" \
      ! -path "${root}/.showrunner/*" \
      -exec grep -l "${phrase}" {} \; 2> /dev/null \
      | sed "s|^${root}/||" | sort | tr '\n' ' ' | sed 's/ *$//'
  )"
  check "[${phrase}] appears in install.sh only" "" "${copies}"
done

# --- result -------------------------------------------------------------------

if [ "${failures}" -ne 0 ]; then
  echo "${failures} check(s) failed"
  exit 1
fi

echo "install.sh: all checks passed"
