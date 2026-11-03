#!/bin/bash
# Usage: scripts/package-tv.sh <tizen-profile>. Signs tv/app into tv/dist/Throwcast.wgt with your Tizen certificate profile.
# Recompiling the player needs: docker build --platform linux/amd64 -t throwcast-emsdk tv/wasm
#   docker run --rm --platform linux/amd64 -v "$PWD/tv":/tv throwcast-emsdk bash /tv/wasm/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH=~/tizen-studio/tools/ide/bin:$PATH
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cp -R tv/app "$TMP/app"
mkdir -p tv/dist
tizen package -t wgt -s "${1:?Tizen certificate profile name, from Tools > Certificate Manager}" -o "$PWD/tv/dist" -- "$TMP/app" </dev/null | tail -1
test -f tv/dist/Throwcast.wgt
