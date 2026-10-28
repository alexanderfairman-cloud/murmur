#!/bin/bash
# Every automatic check this project has. Runs before each commit (see Scripts/install-hooks.sh).
#   1. Unit tests: text cleanup, dictionary, pause detection, history and settings files.
#   2. The floating bar, every window screen and the Dock icon draw.
#   3. The window's logic: adding and deleting words, saving settings, deleting a dictation, fixing a word, a damaged dictionary.
#   4. Speech smoke test: the Mac reads a sentence aloud, the real speech model turns it back into text.
#      This proves the model loads, runs on this Mac, is fast, and the dictionary is applied.
#   5. Pauses: recordings with exact silences become sentences and paragraphs.
#   None of this proves the microphone, the Fn key, typing into other apps, or a real voice work. Those need a person.
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain-fix.sh

echo "== 1/5 Unit tests"
# The Command Line Tools keep the Swift testing library outside the compiler's default search path.
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if [ -d "$FW/Testing.framework" ]; then
  EXTRA=(-Xswiftc -F -Xswiftc "$FW" -Xlinker -rpath -Xlinker "$FW")
else
  EXTRA=()
fi
TEST_OUT="$(swift test ${EXTRA[@]+"${EXTRA[@]}"} 2>&1 || true)"
echo "$TEST_OUT" | tail -3
# The last line of a fully green run is "Test run with N tests passed".
echo "$TEST_OUT" | grep -q "Test run with [0-9]* tests* passed" || { echo "FAIL: unit tests"; exit 1; }

echo "== 2/5 Screens draw"
swift build -c release --product Murmur 2>&1 | tail -1
BIN="$(swift build -c release --show-bin-path)/Murmur"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
"$BIN" --render-hud "$TMP/hud"
for state in listening handsfree thinking message download; do
  # An empty or missing picture means the bar failed to draw.
  [ "$(stat -f %z "$TMP/hud/hud-$state.png" 2>/dev/null || echo 0)" -gt 5000 ] || { echo "FAIL: hud-$state.png did not draw"; exit 1; }
done
echo "PASS: all 5 states of the floating bar drew"
# Every screen of the Murmur window, drawn with sample data. A small or missing picture means a screen failed to draw.
"$BIN" --render-window "$TMP/win"
for screen in history history-dark words words-empty settings first-run first-run-stuck history-fix-pick history-fix-name history-fix-everyday history-fix-saved; do
  [ "$(stat -f %z "$TMP/win/window-$screen.png" 2>/dev/null || echo 0)" -gt 40000 ] || { echo "FAIL: window-$screen.png did not draw"; exit 1; }
done
echo "PASS: all 11 window screens drew"
# The Dock icon must draw at every size macOS asks for.
"$BIN" --render-icon "$TMP/icon.iconset"
[ "$(ls "$TMP/icon.iconset" | wc -l | tr -d ' ')" = "10" ] || { echo "FAIL: icon did not draw"; exit 1; }
iconutil -c icns "$TMP/icon.iconset" -o "$TMP/icon.icns" || { echo "FAIL: icon could not be packaged"; exit 1; }
echo "PASS: Dock icon drew at all 10 sizes"

echo "== 3/5 What the window's buttons do"
"$BIN" --selftest-model

echo "== 4/5 Speech smoke test"
say -v Samantha -o "$TMP/sentence.aiff" "I use clawed code and super base every day. Let's ship it on Friday."
RESULT="$("$BIN" --transcribe "$TMP/sentence.aiff")"
echo "$RESULT"

python3 -I - "$RESULT" <<'PY'
import json, sys
r = json.loads(sys.argv[1])
text = r["text"].lower()
problems = []
for needle in ("claude code", "supabase", "every day", "ship it", "friday"):
    if needle not in text:
        problems.append(f"missing '{needle}'")
if r["transcribeMs"] > 600:  # about 120 ms on an M2 Pro; the Neural Engine path would be 600+
    problems.append(f"too slow: {r['transcribeMs']} ms for {r['audioSeconds']} s of audio")
if problems:
    print("FAIL:", "; ".join(problems)); sys.exit(1)
print(f"PASS: {r['transcribeMs']} ms for {r['audioSeconds']} s of audio (on this Mac, speech model from disk)")
PY

echo "== 5/5 Pauses become sentences and paragraphs"
# The Mac reads three recordings with exact silences in them. The voice alone cannot be used to test this,
# because it barely pauses on its own (about 0.2 s, even between paragraphs).
say -v Samantha -o "$TMP/pause-a.aiff" "I use clawed code and super base every day[[slnc 1200]]then I ship it on Friday[[slnc 2600]]please rebuild everything with all of this logic"
say -v Samantha -o "$TMP/pause-b.aiff" "I would like to[[slnc 1300]]talk about the plan for Friday"
say -v Samantha -o "$TMP/pause-c.aiff" "I think we should[[slnc 500]]ship it on Friday if the tests pass"
A="$("$BIN" --transcribe "$TMP/pause-a.aiff")"
B="$("$BIN" --transcribe "$TMP/pause-b.aiff")"
C="$("$BIN" --transcribe "$TMP/pause-c.aiff")"
python3 -I - "$A" "$B" "$C" <<'PY'
import json, sys
a, b, c = (json.loads(x)["text"] for x in sys.argv[1:4])
problems = []
# 1.2 s of quiet ends a sentence, 2.6 s starts a paragraph
if "every day." not in a: problems.append("1.2 s pause did not end the sentence")
if a.count("\n\n") != 1 or "Friday.\n\nPlease" not in a: problems.append("2.6 s pause did not make exactly one paragraph break")
# a pause after "to" is only thinking: no full stop there
if "to." in b or "to\n" in b or "to talk" not in b: problems.append("unfinished sentence was cut: " + repr(b))
# 0.5 s is too short to count
if "should." in c or "\n" in c or "should ship" not in c: problems.append("0.5 s pause was treated as a break: " + repr(c))
if problems:
    print("FAIL:", "; ".join(problems)); sys.exit(1)
print("PASS: sentence break, paragraph break, unfinished sentence and short pause all handled")
PY
