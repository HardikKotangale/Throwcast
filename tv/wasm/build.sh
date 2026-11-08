#!/bin/bash
# Runs inside the throwcast-emsdk image with the repo's tv/ folder at /tv.
set -euo pipefail
source "$EMSDK/emsdk_env.sh" >/dev/null
cd /tv
em++ wasm/player.cpp -std=c++17 -Os -o app/player.js --bind -pthread \
  -s USE_PTHREADS=1 -s PTHREAD_POOL_SIZE=4 -s ENVIRONMENT_MAY_BE_TIZEN \
  -s TOTAL_MEMORY=134217728 -s NO_EXIT_RUNTIME=1 -s WASM=1 \
  -s 'EXPORTED_FUNCTIONS=["_main","_tc_buffer","_tc_buffer_size","_tc_start","_tc_video","_tc_audio","_tc_udp_start","_tc_udp_next","_tc_udp_lost","_tc_udp_state","_tc_udp_port","_tc_udp_asked","_tc_udp_in","_tc_udp_refused","_tc_udp_frames","_tc_ws_start","_tc_ws_port","_tc_ws_opened","_tc_ws_closed","_tc_ws_next","_tc_ws_text","_tc_ws_send","_tc_ws_close","_tc_ws_stop","_tc_remote_start","_tc_remote_port","_tc_remote_next","_tc_remote_from","_tc_remote_event","_tc_remote_send","_tc_remote_drop"]' \
  -s 'EXTRA_EXPORTED_RUNTIME_METHODS=["UTF8ToString","ccall"]'
ls -la app/
