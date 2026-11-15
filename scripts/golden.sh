#!/bin/zsh
# The plugin against in-process MLXServeEngine: images made on the signed bundle the way Gaea runs them
# (gaea-plugin-check: launch under the launch requirement, configure, prepare, run) and through sensenova-inproc with
# the lane configuration and the request the worker uses. Each pair must be the same PNG, byte for byte.
#
#   scripts/golden.sh <out-dir>     (after scripts/build-plugin.sh)
#
# Cases, all at seed 42:
# - sensenova-u1-fast at 512², the control that 0.2.0 left the earlier models alone;
# - sensenova-u1-tailsteer (0.2.0): a 768² picture, an edit of it, and an edit of that edit (a chain, what TailSteer is
#   for), each turn fed the picture the turn before made over GPP;
# - the same first edit by sensenova-u1-fast: TailSteer must give another picture, or the lane isn't its artifact.
set -uo pipefail
ROOT=${0:A:h:h}
cd $ROOT
OUT=${1:?out dir}; mkdir -p $OUT
B=$ROOT/dist/sensenova.gaeaplugin
MODELS=${CHECK_MODELS_ROOT:-/Volumes/DEV_VOL1/Models}
SWIFTPM=(-c release --build-system swiftbuild)
xcrun swift build $SWIFTPM --product sensenova-inproc > /dev/null && xcrun swift build -c release --product gaea-plugin-check > /dev/null
INPROC=$(xcrun swift build $SWIFTPM --show-bin-path)/sensenova-inproc; CHECK=$(xcrun swift build -c release --show-bin-path)/gaea-plugin-check
LOG=$OUT/golden.log; : > $LOG
pass=0; fail=0
say() { print -r -- "$*" | tee -a $LOG }
say "# SenseNova golden check $(date -u +%FT%TZ): $(python3 -c "import json; m=json.load(open('$B/Contents/Resources/manifest.json')); print(m['id'], m['version'])")"
PROMPT="a red fox sitting in a snowy forest at sunrise, photorealistic"
outputs() { grep -o '"path":"[^"]*"' $1 | sed 's/"path":"//; s/"$//; s/\\\//\//g' | awk '!seen[$0]++' }
verdict() { # name, width, height
  local name=$1 w=$2 h=$3
  say "      $name: over GPP $(grep -o 'ran in [0-9.]* s' $OUT/$name-gpp.log | head -1); in-process $(cat $OUT/$name-inproc.json)"
  local a=$(shasum -a 256 $OUT/$name-gpp.png 2>/dev/null | cut -c1-16) b=$(shasum -a 256 $OUT/$name-inproc.png 2>/dev/null | cut -c1-16)
  local dims=$(sips -g pixelWidth -g pixelHeight $OUT/$name-gpp.png 2>/dev/null | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w "x" h}')
  if [[ -n $a && $a == $b && $dims == ${w}x${h} ]]; then pass=$((pass+1)); say "PASS  $name: the same PNG, sha256 $a…, $dims"
  else fail=$((fail+1)); say "FAIL  $name: $a… / $b…, $dims (want ${w}x${h})"; fi
}

# generate <name> <model> <lane> <width> <height>
generate() {
  local name=$1 model=$2 lane=$3 w=$4 h=$5
  $CHECK $B --operation image.generate --model $model --lane $lane --seed 42 --params "{\"size\":{\"width\":$w,\"height\":$h},\"count\":1}" \
    --text "prompt=$PROMPT" --models-root "$MODELS" --budget 64000000000 --timeout 3600 --session $OUT/$name.gpp > $OUT/$name-gpp.log 2>&1
  local file=$(outputs $OUT/$name-gpp.log | head -1); [[ -f $file ]] && cp $file $OUT/$name-gpp.png
  $INPROC --model $model --lane $lane --width $w --height $h --seed 42 --prompt "$PROMPT" --runs 1 \
    --models-root "$MODELS" --out $OUT/$name-inproc.png 2>> $LOG | tail -1 > $OUT/$name-inproc.json
  verdict $name $w $h
}
# edit <name> <model> <lane> <image> <instruction>: at the image's size
edit() {
  local name=$1 model=$2 lane=$3 image=$4 instruction=$5
  local w=$(sips -g pixelWidth $image | awk '/pixelWidth/{print $2}') h=$(sips -g pixelHeight $image | awk '/pixelHeight/{print $2}')
  $CHECK $B --operation image.edit --model $model --lane $lane --seed 42 --params '{}' --input "images=$image" \
    --text "instruction=$instruction" --models-root "$MODELS" --budget 64000000000 --timeout 3600 --session $OUT/$name.gpp > $OUT/$name-gpp.log 2>&1
  local file=$(outputs $OUT/$name-gpp.log | head -1); [[ -f $file ]] && cp $file $OUT/$name-gpp.png
  $INPROC --model $model --lane $lane --image $image --seed 42 --prompt "$instruction" --runs 1 \
    --models-root "$MODELS" --out $OUT/$name-inproc.png 2>> $LOG | tail -1 > $OUT/$name-inproc.json
  verdict $name $w $h
}

generate fast sensenova-u1-fast int8 512 512
generate tail sensenova-u1-tailsteer int8 768 768
edit tail-edit1 sensenova-u1-tailsteer int8 $OUT/tail-gpp.png "Add a red knitted scarf around the fox's neck. Keep everything else the same."
edit tail-edit2 sensenova-u1-tailsteer int8 $OUT/tail-edit1-gpp.png "Add a small bird perched on a branch behind the fox. Keep everything else the same."
edit fast-edit1 sensenova-u1-fast int8 $OUT/tail-gpp.png "Add a red knitted scarf around the fox's neck. Keep everything else the same."
if [[ -f $OUT/tail-edit1-gpp.png ]] && ! cmp -s $OUT/tail-edit1-gpp.png $OUT/fast-edit1-gpp.png; then
  pass=$((pass+1)); say "PASS  the TailSteer edit is another picture than sensenova-u1-fast's of the same input and seed"
else fail=$((fail+1)); say "FAIL  the TailSteer edit equals sensenova-u1-fast's, or wasn't made"; fi

for s in $OUT/*.gpp; do
  if python3 ${GAEA_SPEC_ROOT:-$ROOT/../gaea-mes-media-server}/tools/validate.py --transcript $s >> $LOG 2>&1; then pass=$((pass+1)); say "PASS  ${s:t} passes validate.py"
  else fail=$((fail+1)); say "FAIL  ${s:t} fails validate.py"; fi
done
say "== $pass passed, $fail failed"
exit $(( fail > 0 ))
