#!/usr/bin/env bash
# Prints a Markdown coverage table from a JaCoCo CSV report: coverage-summary.sh <jacoco.csv> <title>
set -euo pipefail
csv="$1"
title="$2"
if [ ! -f "$csv" ]; then
  echo "_No coverage report found at ${csv}_"
  exit 0
fi
awk -F, -v title="$title" '
  NR > 1 {
    sub(/^com\.gmc\.backend\.?/, "", $2); pkg = ($2 == "" ? "(root)" : $2)
    lm[pkg] += $8; lc[pkg] += $9; bm[pkg] += $6; bc[pkg] += $7
    LM += $8; LC += $9; BM += $6; BC += $7
  }
  function pct(c, m) { return (c + m) ? sprintf("%.1f%%", 100 * c / (c + m)) : "n/a" }
  END {
    print "### " title
    print "| Package | Lines | Branches |"
    print "|---|---|---|"
    for (p in lm) print "| " p " | " pct(lc[p], lm[p]) " | " pct(bc[p], bm[p]) " |"
    print "| **Total** | **" pct(LC, LM) "** | **" pct(BC, BM) "** |"
  }' "$csv"
