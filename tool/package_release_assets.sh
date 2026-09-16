#!/usr/bin/env bash
# Package compiled fvm binaries into the release assets, with checksums.
#
# Usage: tool/package_release_assets.sh <artifacts-dir> [output-dir]
#
# Expects one directory per target, as release.yml's build matrix uploads them:
#   <artifacts-dir>/fvm-linux-x64/fvm
#   <artifacts-dir>/fvm-linux-arm64/fvm
#   <artifacts-dir>/fvm-macos-x64/fvm
#   <artifacts-dir>/fvm-macos-arm64/fvm
#   <artifacts-dir>/fvm-windows-x64/fvm.exe
#
# Produces, in <output-dir>:
#   fvm-<os>-<arch>.zip          one bare executable, no directory inside
#   fvm-<os>-<arch>.zip.sha256   `<hex>  <filename>`, sha256sum's own format
#
# THESE NAMES ARE A CONTRACT, NOT A DETAIL. `install.sh` builds them to decide
# what to download, and every already-installed `fvm update` builds them from
# code compiled months ago (see releaseAssetName in
# packages/fvm/lib/src/core/updater.dart). Renaming an asset does not break the
# next release — it breaks every copy of fvm already on someone's machine, which
# cannot be fixed by a later release because those binaries can no longer fetch
# one. If you are renaming these, you are choosing to strand users.
set -euo pipefail

artifacts_dir="${1:?artifacts directory required}"
output_dir="${2:-release-assets}"

# Every target the release publishes. `install.sh` and updater.dart carry the
# same five; a target added here has to be added there too or nothing will ever
# ask for it.
targets=(
  "linux-x64:fvm"
  "linux-arm64:fvm"
  "macos-x64:fvm"
  "macos-arm64:fvm"
  "windows-x64:fvm.exe"
)

mkdir -p "${output_dir}"
output_dir="$(cd "${output_dir}" && pwd)"

# sha256sum on Linux, shasum -a 256 on macOS. Both write `<hex>  <name>`, which
# is also what both READ, so a user can verify an asset by hand with whichever
# one their machine has.
sha256_of() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum "$1"
  else
    shasum -a 256 "$1"
  fi
}

packaged=0
for entry in "${targets[@]}"; do
  target="${entry%%:*}"
  binary_name="${entry##*:}"
  zip_name="fvm-${target}.zip"
  binary_path="${artifacts_dir}/fvm-${target}/${binary_name}"

  if [[ ! -f "${binary_path}" ]]; then
    echo "missing release binary: ${binary_path}" >&2
    exit 1
  fi

  binary_dir="$(cd "$(dirname "${binary_path}")" && pwd)"

  (
    cd "${binary_dir}"
    # upload-artifact does not preserve the executable bit, so the binary
    # arrives here at 644. Set it before zipping: the zip records the mode, and
    # someone who unzips an asset by hand should get something runnable.
    chmod 755 "${binary_name}"
    rm -f "${output_dir}/${zip_name}"
    # -X drops the extra file attributes (uid/gid, timestamps beyond the DOS
    # ones) so two builds of identical bytes produce closer-to-identical zips.
    zip -q -X "${output_dir}/${zip_name}" "${binary_name}"
  )

  (
    cd "${output_dir}"
    # From inside the directory, so the recorded name is the bare asset name
    # rather than a path that only made sense on the runner.
    sha256_of "${zip_name}" > "${zip_name}.sha256"
  )

  echo "Packaged ${zip_name} ($(cat "${output_dir}/${zip_name}.sha256"))"
  packaged=$((packaged + 1))
done

if [[ "${packaged}" -ne "${#targets[@]}" ]]; then
  echo "packaged ${packaged} of ${#targets[@]} targets" >&2
  exit 1
fi

echo "Packaged ${packaged} targets into ${output_dir}"
