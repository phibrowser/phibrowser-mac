#!/bin/sh
# Compares two builds on both scenarios, interleaving them round by round so
# drift on the machine affects both alike, then prints the summary.
#
# usage: run.sh <baseline-label> <baseline.app> <candidate-label> <candidate.app> [rounds]
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
BASE=$1 BASE_APP=$2 CAND=$3 CAND_APP=$4 ROUNDS=${5:-2}
r=1
while [ $r -le "$ROUNDS" ]; do
  for scenario in toggle scroll; do
    sh "$HERE/bench.sh" "$BASE" "$BASE_APP" $scenario $r
    sh "$HERE/bench.sh" "$CAND" "$CAND_APP" $scenario $r
  done
  r=$((r + 1))
done
python3 -I "$HERE/analyze.py" "$BASE" "$CAND"
