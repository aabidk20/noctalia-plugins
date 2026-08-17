#!/usr/bin/env bash
# Noctalia YT Music Background Helper Daemon
# Handles yt-dlp stream resolution and thumbnail downloads out of the Luau main thread.

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/noctalia-ytmusic"
THUMB_DIR="$CACHE_DIR/thumbnails"
AUDIO_DIR="$CACHE_DIR/audio"
RESOLVED_DIR="$CACHE_DIR/resolved"
QUEUE_FILE="$CACHE_DIR/queue.txt"
COOKIE_FILE="$CACHE_DIR/cookies.txt"

mkdir -p "$THUMB_DIR" "$AUDIO_DIR" "$RESOLVED_DIR"
touch "$QUEUE_FILE"

export PATH="/etc/profiles/per-user/$USER/bin:$PATH"

log() {
    echo "[ytmusic-daemon] $(date +'%H:%M:%S') $1"
}

log "daemon started"

while true; do
    if [ -s "$QUEUE_FILE" ]; then
        LINE=$(head -n 1 "$QUEUE_FILE")
        sed -i '1d' "$QUEUE_FILE"

        if [ -n "$LINE" ]; then
            CMD_TYPE=$(echo "$LINE" | cut -d'|' -f1)
            VIDEO_ID=$(echo "$LINE" | cut -d'|' -f2)
            URL=$(echo "$LINE" | cut -d'|' -f3-)

            if [ "$CMD_TYPE" = "STREAM" ] && [ -n "$VIDEO_ID" ]; then
                log "resolving stream for $VIDEO_ID"
                COOKIE_ARG=""
                if [ -s "$COOKIE_FILE" ]; then
                    COOKIE_ARG="--cookies $COOKIE_FILE"
                fi

                STREAM_URL=$(yt-dlp -f bestaudio/best -g $COOKIE_ARG "https://www.youtube.com/watch?v=$VIDEO_ID" 2>/dev/null | tail -n 1 | tr -d '\r\n' | tr -cd '\40-\176')

                if [ -n "$STREAM_URL" ]; then
                    log "resolved stream for $VIDEO_ID (${#STREAM_URL} bytes)"
                    echo "$STREAM_URL" > "$RESOLVED_DIR/$VIDEO_ID.txt"
                else
                    log "failed to resolve stream for $VIDEO_ID"
                fi
            elif [ "$CMD_TYPE" = "THUMB" ] && [ -n "$VIDEO_ID" ] && [ -n "$URL" ]; then
                SAFE_ID=$(echo "$VIDEO_ID" | tr -cd 'a-zA-Z0-9_-')
                DEST="$THUMB_DIR/$SAFE_ID.jpg"
                if [ ! -f "$DEST" ]; then
                    curl -s -L -o "$DEST" "$URL" >/dev/null 2>&1 &
                fi
            elif [ "$CMD_TYPE" = "AUDIO" ] && [ -n "$VIDEO_ID" ]; then
                SAFE_ID=$(echo "$VIDEO_ID" | tr -cd 'a-zA-Z0-9_-')
                DEST="$AUDIO_DIR/$SAFE_ID.opus"
                if [ ! -f "$DEST" ]; then
                    log "downloading audio for $VIDEO_ID to $DEST"
                    COOKIE_ARG=""
                    if [ -s "$COOKIE_FILE" ]; then
                        COOKIE_ARG="--cookies $COOKIE_FILE"
                    fi
                    yt-dlp -f bestaudio -o "$DEST" $COOKIE_ARG "https://www.youtube.com/watch?v=$VIDEO_ID" >/dev/null 2>&1 &
                fi
            fi
        fi
    else
        sleep 0.1
    fi
done
