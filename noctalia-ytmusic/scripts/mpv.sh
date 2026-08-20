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

# Persistent push stream: one connection that lives for the lifetime of the
# mpv instance. mpv pushes `end-file` and `property-change` events natively;
# time-pos is requested once per second (the keep-alive loop doubles as the
# ticker). When mpv dies the socket closes, nc exits, the next printf gets
# SIGPIPE, and the whole pipeline ends -> runStream sees EOF.
mpv_stream() {
  [ -S "$SOCK" ] || exit 0
  {
    printf '{"command":["observe_property",1,"pause"]}\n'
    printf '{"command":["observe_property",2,"duration"]}\n'
    printf '{"command":["observe_property",3,"eof-reached"]}\n'
    printf '{"command":["observe_property",4,"audio-codec-name"]}\n'
    printf '{"command":["observe_property",5,"audio-params/samplerate"]}\n'
    i=0
    while true; do
      printf '{"command":["get_property","time-pos"],"request_id":100}\n'
      if [ $((i % 10)) -eq 0 ]; then
        printf '{"command":["get_property","audio-bitrate"],"request_id":200}\n'
      fi
      i=$((i + 1))
      sleep 1
    done
  } | nc -U "$SOCK"
}

fn="${1:?fn required}"; shift
type -t "$fn" >/dev/null 2>&1 || { echo "unknown fn: $fn" >&2; exit 1; }
"$fn" "$@"