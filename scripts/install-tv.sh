#!/bin/bash
# Usage: scripts/install-tv.sh <tv-ip>. Rebuilds nothing; run after `tizen package`. TV must have Developer Mode pointing at this Mac.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH=~/tizen-studio/tools:$PATH
HOST=${1:?tv ip}
sdb connect "$HOST" | tail -1
S="$HOST:26101"
R="/home/owner/share/tmp/sdk_tools/Throwcast-$(date +%s).wgt"
sdb -s "$S" push tv/dist/Throwcast.wgt "$R"
sdb -s "$S" shell 0 vd_appinstall Thrwcast4K.Receiver "$R"
sdb -s "$S" shell 0 applist | grep -q Thrwcast4K.Receiver && echo installed
