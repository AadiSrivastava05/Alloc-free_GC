#!/usr/bin/env python3
import csv
import glob
import math
import statistics
import sys
from collections import defaultdict


def percentile(values, pct):
    if not values:
        return math.nan
    ordered = sorted(values)
    rank = (len(ordered) - 1) * pct
    lo = math.floor(rank)
    hi = math.ceil(rank)
    if lo == hi:
        return ordered[lo]
    frac = rank - lo
    return ordered[lo] * (1.0 - frac) + ordered[hi] * frac


def load_wall(path):
    rows = []
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            row["depth"] = int(row["depth"])
            row["threads"] = int(row["threads"])
            row["elapsed_sec"] = float(row["elapsed_sec"])
            rows.append(row)
    return rows


def print_wall(rows):
    by_variant = defaultdict(list)
    by_config = defaultdict(list)
    wins = defaultdict(int)

    for row in rows:
        by_variant[row["variant"]].append(row["elapsed_sec"])
        by_config[(row["depth"], row["threads"])].append(row)

    print("wall_clock_mean_sec")
    print("variant,mean_sec")
    for variant in sorted(by_variant):
        print(f"{variant},{statistics.mean(by_variant[variant]):.6f}")

    for config_rows in by_config.values():
        winner = min(config_rows, key=lambda r: r["elapsed_sec"])
        wins[winner["variant"]] += 1

    print()
    print("win_count")
    print("variant,wins")
    for variant in sorted(by_variant):
        print(f"{variant},{wins[variant]}")


def print_pauses(root):
    paths = sorted(glob.glob(f"{root}/gc_pauses_*.csv"))
    print()
    print("gc_pause_sec")
    print("variant,collections,mean_sec,p50_sec,p99_sec")

    if not paths:
        summary_path = f"{root}/benchmark_plots/gc_pause_stats.csv"
        try:
            with open(summary_path, newline="") as f:
                for row in csv.DictReader(f):
                    print(
                        f"{row['variant']},{row['collections']},"
                        f"{float(row['mean_sec']):.9f},"
                        f"{float(row['p50_sec']):.9f},"
                        f"{float(row['p99_sec']):.9f}"
                    )
            return
        except FileNotFoundError:
            return

    for path in paths:
        pauses = []
        variant = None
        with open(path, newline="") as f:
            for row in csv.reader(f):
                if len(row) != 3:
                    continue
                variant = row[0]
                pauses.append(float(row[2]))
        if pauses and variant:
            print(
                f"{variant},{len(pauses)},"
                f"{statistics.mean(pauses):.9f},"
                f"{percentile(pauses, 0.50):.9f},"
                f"{percentile(pauses, 0.99):.9f}"
            )


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "benchmarking/results.csv"
    rows = load_wall(path)
    print_wall(rows)
    root = path.rsplit("/", 1)[0] if "/" in path else "."
    print_pauses(root)


if __name__ == "__main__":
    main()
