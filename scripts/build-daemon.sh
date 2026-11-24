#!/usr/bin/env bash
# Build the Rust player/daemon and install it at bin/omarchy-tidalplayer-<arch>,
# invoked by the bin/omarchy-tidalplayer dispatcher (`omarchy-tidalplayer daemon`
# is the systemd ExecStart, every other command is the CLI client).
#
# Prebuilt x86_64 and aarch64 binaries are committed from CI: the plugin is
# distributed as a git checkout (`omarchy plugin add`) and that step does not
# run a build. Run this script to rebuild locally for your host architecture.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="$(uname -m)"
TARGET="${ROOT}/bin/omarchy-tidalplayer-${ARCH}"

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo not found — install the Rust toolchain to build the daemon" >&2
  exit 1
fi

echo "building daemon (release, ${ARCH})..."
# Remap local Cargo and checkout paths so personal home directories are not
# baked into panic strings in the shipped binary.
CARGO_HOME_DIR="${CARGO_HOME:-${HOME}/.cargo}"
RUSTFLAGS="--remap-path-prefix=${CARGO_HOME_DIR}=/cargo --remap-path-prefix=${ROOT}=/src ${RUSTFLAGS:-}" \
  cargo build --release --locked --manifest-path "${ROOT}/daemon/Cargo.toml"

# Install through a temporary and rename it into place. Writing over the file
# directly fails with ETXTBSY while a daemon is running from it; rename swaps
# the inode and leaves the running process untouched.
tmp="$(mktemp "${ROOT}/bin/.omarchy-tidalplayer-${ARCH}.XXXXXX")"
trap 'rm -f "${tmp}"' EXIT
cp "${ROOT}/daemon/target/release/omarchy-tidalplayer" "${tmp}"
chmod 755 "${tmp}"
mv -f "${tmp}" "${TARGET}"
trap - EXIT

echo "installed ${TARGET} ($(du -h "${TARGET}" | cut -f1))"
echo "restart the daemon to pick it up: bin/omarchy-tidalplayer daemon restart"
