#!/usr/bin/env bash
# Invoked via:  bash scripts/mpv.sh <fn> <args...>

PIDFILE="/tmp/noctalia-ytmusic-mpv.pid"
SOCK="${XDG_RUNTIME_DIR:-/tmp}/noctalia-ytmusic-mpv.sock"

mpv_play() {   # $1=volume
  local vol="${1:-100}"
  URL=$(cat /tmp/noctalia-ytmusic-url.txt)
  TITLE=$(cat /tmp/noctalia-ytmusic-title.txt 2>/dev/null)
  if [ -f "$PIDFILE" ]; then
    PREV=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$PREV" ] && kill "$PREV" >/dev/null 2>&1
    rm -f "$PIDFILE"
  fi
  pkill -f "input-ipc-server=$SOCK" >/dev/null 2>&1
  sleep 0.3
  rm -f "$SOCK"
  nohup mpv "$URL" --no-video --vo=null --vd=null --audio-display=no --no-osc --no-osd-bar \
    --demuxer-max-bytes=20M --demuxer-readahead-secs=60 --really-quiet --no-terminal \
    --keep-open=yes \
    --force-media-title="$TITLE" \
    --input-ipc-server="$SOCK" --ao=pipewire \
    >/dev/null 2>&1 &
  echo $! > "$PIDFILE"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -S "$SOCK" ] && printf '' | nc -U -N -w1 "$SOCK" >/dev/null 2>&1 && break
    sleep 0.2
  done
  [ -S "$SOCK" ] && { 
    echo "READY=1"
    printf '{"command":["set_property","volume",%s]}\n' "$vol" | nc -U -N -w1 "$SOCK" >/dev/null 2>&1
  }
}

mpv_send() {   # $1=payload json
  local payload="$1"
  [ -S "$SOCK" ] || exit 0
  TMP=$(mktemp)
  printf '%s\n' "$payload" > "$TMP"
  nc -U -N -w2 "$SOCK" < "$TMP" >/dev/null 2>&1
  rm -f "$TMP"
}

mpv_kill() {
  if [ -f "$PIDFILE" ]; then
    PREV=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$PREV" ] && kill -9 "$PREV" >/dev/null 2>&1
    rm -f "$PIDFILE"
  fi
  pkill -9 -f "input-ipc-server=$SOCK" >/dev/null 2>&1
  rm -f "$SOCK" /tmp/noctalia-ytmusic-url.txt
}

mpv_poll() {
  [ -S "$SOCK" ] || { echo "NOMPV=1"; exit 0; }
  RES=$(printf '{"command":["get_property","time-pos"]}\n{"command":["get_property","duration"]}\n{"command":["get_property","pause"]}\n{"command":["get_property","audio-bitrate"]}\n{"command":["get_property","audio-codec-name"]}\n{"command":["get_property","audio-params/samplerate"]}\n{"command":["get_property","eof-reached"]}\n' | nc -U -N -w1 "$SOCK" 2>/dev/null)
  [ -n "$RES" ] || exit 0
  echo "$RES" | awk -F'"data":' '
    NR==1 && NF>1 { split($2,a,"[,}]"); if (a[1] != "null") print "POS=" a[1] }
    NR==2 && NF>1 { split($2,a,"[,}]"); if (a[1] != "null") print "DUR=" a[1] }
    NR==3 && NF>1 { split($2,a,"[,}]"); if (a[1] != "null") print "PAUSE=" a[1] }
    NR==4 && NF>1 { split($2,a,"[,}]"); if (a[1] != "null") print "BITRATE=" a[1] }
    NR==5 && NF>1 { split($2,a,"[\",}]"); if (a[2] != "null") print "CODEC=" a[2] }
    NR==6 && NF>1 { split($2,a,"[,}]"); if (a[1] != "null") print "RATE=" a[1] }
    NR==7 && NF>1 { split($2,a,"[,}]"); if (a[1] != "null" && a[1] == "true") print "eof-reached=true" }
  '
}

fn="${1:?fn required}"; shift
type -t "$fn" >/dev/null 2>&1 || { echo "unknown fn: $fn" >&2; exit 1; }
"$fn" "$@"