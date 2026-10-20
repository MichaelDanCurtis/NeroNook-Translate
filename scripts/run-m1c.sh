#!/bin/sh
# One command for the Milestone 1c comparison once recordings exist (docs/M1C-PLAN.md): scripted gold,
# transcript drafts for natural parts that have none yet, codec copies, the comparison with every
# candidate (paced and under load) for every language pair the recordings allow, and the TTS listening
# set with the speakers' own reference takes. Downloads nothing except the Apple speech asset for the
# chosen Spanish variety (approval 7). Natural recordings whose drafts are not yet corrected are skipped
# by the loader; rerun after correcting them.
#   scripts/run-m1c.sh [es-MX|es-ES|es-US] [out dir]      default es-MX (the owner's choice, October 20, 2026)
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
variety="${1:-es-MX}"
out="${2:-$root/reports/m1c-engine-comparison-$(date +%Y-%m-%d)/run}"
voice="$root/../NeroNook-Voice"
check="$root/.build/debug/TranslateCheck"
asr="$root/Engine/.build/release/TranslateASR"
engine="$root/Engine/.build/release/TranslateEngine"
cd "$root"
[ -x "$check" ] || swift build
[ -x "$asr" ] && [ -x "$engine" ] || swift build -c release --package-path Engine

languages=""
for lang in en es zh; do
    if ls "Fixtures/Corpus/raw/$lang"/* >/dev/null 2>&1; then languages="$languages,$lang"; fi
done
languages="${languages#,}"
[ -n "$languages" ] || { echo "no recordings under Fixtures/Corpus/raw/<lang>/ (see docs/M1C-PLAN.md)"; exit 1; }
pairs="en:es,es:en"
case "$languages" in *zh*) pairs="$pairs,en:zh,zh:en" ;; esac
echo "languages: $languages; pairs: $pairs; Spanish variety: $variety; output: $out"

/usr/bin/python3 -I scripts/corpus-gold.py
"$check" --install-speech-locale "$variety"
"$check" --draft-gold --corpus Fixtures/Corpus --asr-helper "$asr" --languages "$languages" --spanish-locale "$variety"
scripts/corpus-codec.sh Fixtures/Corpus
mkdir -p "$out"
"$check" --compare --corpus Fixtures/Corpus --languages "$languages" --pairs "$pairs" \
    --recognizers nemotron,qwen3asr-0.6b,qwen3asr-1.7b,apple \
    --translators apple,qwen3.5-2b,qwen3.5-2b-nocontext,hymt2 \
    --paced --load --spanish-locale "$variety" \
    --asr-helper "$asr" --engine "$engine" \
    --hymt2-python "$voice/build/interpreter-venv/bin/python" --hymt2-model "$voice/build/interpreter-models/translator" \
    --out "$out/compare"
"$check" --voices-from-corpus --corpus Fixtures/Corpus --out Fixtures/Voices-owner --languages "$languages"
if ls Fixtures/Voices-owner/*.wav >/dev/null 2>&1; then
    "$check" --listening-set --engine "$engine" --voices Fixtures/Voices-owner --languages "$languages" \
        --variants base-1.7b-8bit,base-1.7b-bf16,base-0.6b-8bit --intervals 0.32,0.16 --asr-helper "$asr" --out "$out/listening"
else
    echo "no reference takes: the listening set waits for raw/<lang>/reference recordings"
fi
echo "done: $out/compare/compare-summary.md, $out/compare/translation-review.md, $out/listening/listening-sheet.md (key under private/)"
