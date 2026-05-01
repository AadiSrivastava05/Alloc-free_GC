#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT_DIR/benchmarking/results.csv}"

variants=(normal zero zero_offheap zero_offheap_threaded zero_stack_threaded)
depths=(10 11 12 13 14)
threads=(1 2 3 4 5 6 7 8)

cd "$ROOT_DIR"
make all

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
rm -f "$ROOT_DIR"/benchmarking/gc_pauses_*.csv
printf 'variant,depth,threads,run,elapsed_sec\n' > "$OUT"

tmp_time="$(mktemp)"
trap 'rm -f "$tmp_time"' EXIT

for variant in "${variants[@]}"; do
  bin="bin/bench_${variant}"
  for depth in "${depths[@]}"; do
    for nthreads in "${threads[@]}"; do
      printf 'running variant=%s depth=%s threads=%s\n' "$variant" "$depth" "$nthreads" >&2
      /usr/bin/time -f '%e' -o "$tmp_time" "$bin" "$depth" "$nthreads" \
        > "benchmarking/${variant}_d${depth}_t${nthreads}.out" 2>&1
      elapsed="$(cat "$tmp_time")"
      printf '%s,%s,%s,1,%s\n' "$variant" "$depth" "$nthreads" "$elapsed" >> "$OUT"
      printf 'done variant=%s depth=%s threads=%s elapsed=%ss\n' \
        "$variant" "$depth" "$nthreads" "$elapsed" >&2
    done
  done
done
