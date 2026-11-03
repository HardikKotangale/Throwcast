#!/bin/bash
# Runs inside the throwcast-emsdk image with the repo's tv/ folder at /tv.
set -euo pipefail
source "$EMSDK/emsdk_env.sh" >/dev/null
cd /tv
em++ wasm/player.cpp -std=c++17 -Os -o app/player.js --bind -pthread \
  -s USE_PTHREADS=1 -s PTHREAD_POOL_SIZE=1 -s ENVIRONMENT_MAY_BE_TIZEN \
  -s TOTAL_MEMORY=67108864 -s NO_EXIT_RUNTIME=1 -s WASM=1 \
  -s 'EXPORTED_FUNCTIONS=["_main","_tc_buffer","_tc_buffer_size","_tc_start","_tc_video","_tc_audio"]' \
  -s 'EXTRA_EXPORTED_RUNTIME_METHODS=["UTF8ToString"]'
ls -la app/
