#!/usr/bin/env bash
set -euo pipefail

# Benchmarks the OxCaml GC implementations using
# binary_tree_multithreaded_test, with configurable DEPTHS/THREADS/REPEATS.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

DEPTHS=${DEPTHS:-"11 12 13 14"}
THREADS=${THREADS:-"1 2 3 4 5 6 7 8"}
REPEATS=${REPEATS:-1}
OUT_CSV=${OUT_CSV:-"$SCRIPT_DIR/benchmark_results.csv"}
TARGET=${TARGET:-binary_tree_multithreaded_test}
VARIANTS=${VARIANTS:-"zero zero_offheap zero_offheap_threaded zero_stack_threaded normal"}

exe_for_variant() {
  case "$1" in
    zero) echo "$SCRIPT_DIR/alloc_free_gc_zero" ;;
    zero_offheap) echo "$SCRIPT_DIR/alloc_free_gc_zero_offheap" ;;
    zero_offheap_threaded) echo "$SCRIPT_DIR/alloc_free_gc_zero_offheap_threaded" ;;
    zero_stack_threaded) echo "$SCRIPT_DIR/alloc_free_gc_zero_stack_threaded" ;;
    normal) echo "$SCRIPT_DIR/alloc_free_gc_normal" ;;
    *)
      echo "Unknown GC variant: $1" >&2
      echo "Supported variants: zero zero_offheap zero_offheap_threaded zero_stack_threaded normal" >&2
      exit 1
      ;;
  esac
}

if ! [[ "$REPEATS" =~ ^[0-9]+$ ]] || [[ "$REPEATS" -lt 1 ]]; then
  echo "REPEATS must be a positive integer, got: $REPEATS"
  exit 1
fi

build_variant() {
  local variant=$1
  local exe=$2

  echo "Building $variant GC -> $exe"
  rm -f "$PROJECT_ROOT/$TARGET" "$exe"
  make -C "$PROJECT_ROOT" "GC=$variant" "$TARGET" >/dev/null
  cp "$PROJECT_ROOT/$TARGET" "$exe"
}

mkdir -p "$(dirname -- "$OUT_CSV")"

echo "Building binaries..."
for variant in $VARIANTS; do
  build_variant "$variant" "$(exe_for_variant "$variant")"
done

echo "variant,depth,threads,run,elapsed_sec" > "$OUT_CSV"

run_one() {
  local variant=$1
  local exe=$2
  local depth=$3
  local nthreads=$4
  local run_id=$5

  if ! [[ "$depth" =~ ^[0-9]+$ ]] || ! [[ "$nthreads" =~ ^[0-9]+$ ]]; then
    echo "Depth and thread values must be positive integers. Got depth=$depth threads=$nthreads"
    exit 1
  fi

  local elapsed
  if command -v /usr/bin/time >/dev/null 2>&1; then
    local tmp_time
    tmp_time=$(mktemp)
    /usr/bin/time -f "%e" -o "$tmp_time" "$exe" "$depth" "$nthreads" >/dev/null 2>&1
    elapsed=$(tr -d '[:space:]' < "$tmp_time")
    rm -f "$tmp_time"
  else
    local t0 t1
    t0=$(date +%s%N)
    "$exe" "$depth" "$nthreads" >/dev/null 2>&1
    t1=$(date +%s%N)
    elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.6f", (b-a)/1000000000.0 }')
  fi

  if [[ -z "$elapsed" ]]; then
    echo "Failed to collect elapsed time for $variant depth=$depth threads=$nthreads run=$run_id"
    exit 1
  fi

  echo "$variant,$depth,$nthreads,$run_id,$elapsed" >> "$OUT_CSV"
  printf "%-24s depth=%-3s threads=%-2s run=%-2s time=%ss\n" "$variant" "$depth" "$nthreads" "$run_id" "$elapsed"
}

echo "Running benchmark for variants: $VARIANTS"

for depth in $DEPTHS; do
  for nthreads in $THREADS; do
    for run in $(seq 1 "$REPEATS"); do
      for variant in $VARIANTS; do
        run_one "$variant" "$(exe_for_variant "$variant")" "$depth" "$nthreads" "$run"
      done
    done
  done
done

echo
echo "Benchmark complete. CSV written to: $OUT_CSV"
echo "You can summarize quickly with:"
echo '  awk -F, '\''NR>1 {k=$1","$2","$3; s[k]+=$5; c[k]++} END {for (k in s) print k","s[k]/c[k]}'\'' "'"$OUT_CSV"'" | sort'
