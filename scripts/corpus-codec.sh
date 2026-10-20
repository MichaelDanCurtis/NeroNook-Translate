#!/bin/sh
# Builds the call-codec copy of the corpus (plan §6.1, robustness): every recording under raw/<lang>/ is
# encoded with Opus in VoIP mode at the given bitrate and decoded straight back to 16 kHz mono WAV under
# codec/<lang>/, so the same gold text and checks apply. Every format the corpus loader reads is converted
# (wav, m4a, caf, aif, aiff, mp3, flac; QuickTime records m4a). The two ffmpeg passes are piped, so no
# temporary file is written. Needs ffmpeg with libopus. Recordings never enter git (.gitignore).
#   scripts/corpus-codec.sh Fixtures/Corpus [bitrate]      default bitrate 24k
set -eu
root="${1:?usage: corpus-codec.sh <corpus dir> [bitrate]}"
bitrate="${2:-24k}"
command -v ffmpeg >/dev/null || { echo "ffmpeg not found" >&2; exit 1; }
count=0
for folder in "$root"/raw/*/; do
    [ -d "$folder" ] || continue
    lang=$(basename "$folder")
    mkdir -p "$root/codec/$lang"
    for src in "$folder"*; do
        [ -f "$src" ] || continue
        case "$(printf '%s' "${src##*.}" | tr '[:upper:]' '[:lower:]')" in wav|m4a|caf|aif|aiff|mp3|flac) ;; *) continue ;; esac
        name=$(basename "$src"); name="${name%.*}"
        ffmpeg -nostdin -loglevel error -i "$src" -ac 1 -ar 48000 -c:a libopus -b:a "$bitrate" -application voip -f ogg - \
            | ffmpeg -loglevel error -y -f ogg -i - -ac 1 -ar 16000 -c:a pcm_s16le "$root/codec/$lang/$name.wav"
        count=$((count + 1))
    done
done
printf 'codec copy: opus %s voip, decoded to 16 kHz mono PCM\nffmpeg: %s\ndate: %s\nfiles: %s\n' "$bitrate" "$(ffmpeg -version 2>/dev/null | head -1)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$count" > "$root/codec/codec.txt"
echo "wrote $count codec copies under $root/codec (see codec/codec.txt)"
