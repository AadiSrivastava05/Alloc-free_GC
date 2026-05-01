#!/usr/bin/env python3
import argparse
import csv
import glob
import math
import os
import statistics
from collections import defaultdict


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_VARIANT_ORDER = [
    "normal",
    "zero",
    "zero_offheap",
    "zero_offheap_threaded",
    "zero_stack_threaded",
]


def variant_sort_key(variant):
    try:
        return (0, DEFAULT_VARIANT_ORDER.index(variant))
    except ValueError:
        return (1, variant)


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


def load_rows(csv_path):
    rows = []
    skipped = 0
    with open(csv_path, "r", newline="") as f:
        reader = csv.DictReader(f)
        required = {"variant", "depth", "threads", "run", "elapsed_sec"}
        if reader.fieldnames is None or not required.issubset(set(reader.fieldnames)):
            raise ValueError("CSV is missing required columns.")

        for idx, row in enumerate(reader, start=2):
            try:
                elapsed = (row.get("elapsed_sec") or "").strip()
                if not elapsed:
                    raise ValueError("elapsed_sec is empty")
                rows.append(
                    {
                        "variant": (row.get("variant") or "").strip(),
                        "depth": int(row["depth"]),
                        "threads": int(row["threads"]),
                        "run": int(row["run"]),
                        "elapsed_sec": float(elapsed),
                    }
                )
            except (ValueError, TypeError, KeyError) as e:
                skipped += 1
                print(f"Warning: skipping malformed CSV row {idx}: {e}")

    if skipped:
        print(f"Warning: skipped {skipped} malformed row(s) from {csv_path}")
    return rows


def mean_by_variant_depth_threads(rows):
    grouped = defaultdict(list)
    for row in rows:
        grouped[(row["variant"], row["depth"], row["threads"])].append(row["elapsed_sec"])

    stats = {}
    for key, values in grouped.items():
        stats[key] = {
            "n": len(values),
            "mean": statistics.mean(values),
            "std": statistics.stdev(values) if len(values) > 1 else 0.0,
            "min": min(values),
            "max": max(values),
        }
    return stats


def evaluate_completeness(rows, variants, depths, threads):
    seen = {(r["variant"], r["depth"], r["threads"]) for r in rows}
    missing = []
    for variant in variants:
        for depth in depths:
            for thread_count in threads:
                if (variant, depth, thread_count) not in seen:
                    missing.append((variant, depth, thread_count))
    return missing


def write_summary_csv(path, stats):
    with open(path, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["variant", "depth", "threads", "n", "mean_sec", "std_sec", "min_sec", "max_sec"])
        for (variant, depth, threads), stat in sorted(stats.items(), key=lambda item: (variant_sort_key(item[0][0]), item[0][1], item[0][2])):
            writer.writerow(
                [
                    variant,
                    depth,
                    threads,
                    stat["n"],
                    f"{stat['mean']:.6f}",
                    f"{stat['std']:.6f}",
                    f"{stat['min']:.6f}",
                    f"{stat['max']:.6f}",
                ]
            )


def write_speedup_csv(path, stats, variants, depths, threads, baseline):
    with open(path, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["variant", "depth", "threads", "baseline", "baseline_mean_sec", "variant_mean_sec", "speedup"])
        for depth in depths:
            for thread_count in threads:
                base = stats.get((baseline, depth, thread_count))
                for variant in variants:
                    if variant == baseline:
                        continue
                    current = stats.get((variant, depth, thread_count))
                    if base is None or current is None or current["mean"] <= 0:
                        speedup = math.nan
                    else:
                        speedup = base["mean"] / current["mean"]
                    writer.writerow(
                        [
                            variant,
                            depth,
                            thread_count,
                            baseline,
                            "nan" if base is None else f"{base['mean']:.6f}",
                            "nan" if current is None else f"{current['mean']:.6f}",
                            "nan" if math.isnan(speedup) else f"{speedup:.6f}",
                        ]
                    )


def write_win_counts_csv(path, stats, variants, depths, threads):
    wins = defaultdict(int)
    for depth in depths:
        for thread_count in threads:
            candidates = []
            for variant in variants:
                stat = stats.get((variant, depth, thread_count))
                if stat is not None:
                    candidates.append((variant, stat["mean"]))
            if candidates:
                winner, _ = min(candidates, key=lambda item: item[1])
                wins[winner] += 1

    with open(path, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["variant", "wins"])
        for variant in variants:
            writer.writerow([variant, wins[variant]])


def load_pause_stats(benchmark_dir):
    result = {}
    for path in sorted(glob.glob(os.path.join(benchmark_dir, "gc_pauses_*.csv"))):
        variant = None
        pauses = []
        with open(path, "r", newline="") as f:
            for row in csv.reader(f):
                if len(row) != 3:
                    continue
                variant = row[0]
                try:
                    pauses.append(float(row[2]))
                except ValueError:
                    pass
        if variant and pauses:
            result[variant] = {
                "collections": len(pauses),
                "mean": statistics.mean(pauses),
                "p50": percentile(pauses, 0.50),
                "p99": percentile(pauses, 0.99),
                "min": min(pauses),
                "max": max(pauses),
            }
    return result


def write_pause_stats_csv(path, pause_stats, variants):
    with open(path, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["variant", "collections", "mean_sec", "p50_sec", "p99_sec", "min_sec", "max_sec"])
        for variant in variants:
            stat = pause_stats.get(variant)
            if stat is None:
                continue
            writer.writerow(
                [
                    variant,
                    stat["collections"],
                    f"{stat['mean']:.9f}",
                    f"{stat['p50']:.9f}",
                    f"{stat['p99']:.9f}",
                    f"{stat['min']:.9f}",
                    f"{stat['max']:.9f}",
                ]
            )


def remove_stale_outputs(out_dir):
    patterns = [
        "time_vs_threads_depth_*.png",
        "speedup_vs_normal_depth_*.png",
        "mean_wall_by_variant.png",
        "win_counts.png",
        "gc_pause_mean_p99.png",
    ]
    for pattern in patterns:
        for path in glob.glob(os.path.join(out_dir, pattern)):
            os.remove(path)


def plot_outputs(out_dir, stats, variants, depths, threads, baseline, pause_stats):
    import matplotlib.pyplot as plt

    for depth in depths:
        plt.figure(figsize=(9, 5))
        for variant in variants:
            y_vals = []
            for thread_count in threads:
                stat = stats.get((variant, depth, thread_count))
                y_vals.append(float("nan") if stat is None else stat["mean"])
            plt.plot(threads, y_vals, marker="o", linewidth=2, label=variant)
        plt.title(f"Mean Time vs Threads (depth={depth})")
        plt.xlabel("Worker Threads")
        plt.ylabel("Elapsed Time (s)")
        plt.xticks(threads)
        plt.grid(True, alpha=0.3)
        plt.legend()
        plt.tight_layout()
        plt.savefig(os.path.join(out_dir, f"time_vs_threads_depth_{depth}.png"), dpi=150)
        plt.close()

    if baseline in variants:
        for depth in depths:
            plt.figure(figsize=(9, 5))
            for variant in variants:
                if variant == baseline:
                    continue
                y_vals = []
                for thread_count in threads:
                    base = stats.get((baseline, depth, thread_count))
                    current = stats.get((variant, depth, thread_count))
                    if base is None or current is None or current["mean"] <= 0:
                        y_vals.append(float("nan"))
                    else:
                        y_vals.append(base["mean"] / current["mean"])
                plt.plot(threads, y_vals, marker="o", linewidth=2, label=variant)
            plt.axhline(1.0, color="black", linestyle="--", linewidth=1)
            plt.title(f"Speedup vs {baseline} (depth={depth})")
            plt.xlabel("Worker Threads")
            plt.ylabel(f"Speedup ({baseline} / variant)")
            plt.xticks(threads)
            plt.grid(True, alpha=0.3)
            plt.legend()
            plt.tight_layout()
            plt.savefig(os.path.join(out_dir, f"speedup_vs_{baseline}_depth_{depth}.png"), dpi=150)
            plt.close()

    overall = []
    for variant in variants:
        means = [stat["mean"] for (v, _d, _t), stat in stats.items() if v == variant]
        overall.append(statistics.mean(means) if means else float("nan"))
    plt.figure(figsize=(9, 5))
    plt.bar(variants, overall)
    plt.title("Mean Wall Time by Variant")
    plt.xlabel("Variant")
    plt.ylabel("Mean elapsed time (s)")
    plt.xticks(rotation=20, ha="right")
    plt.grid(True, axis="y", alpha=0.3)
    plt.tight_layout()
    plt.savefig(os.path.join(out_dir, "mean_wall_by_variant.png"), dpi=150)
    plt.close()

    wins = []
    for variant in variants:
        count = 0
        for depth in depths:
            for thread_count in threads:
                candidates = []
                for v in variants:
                    stat = stats.get((v, depth, thread_count))
                    if stat is not None:
                        candidates.append((v, stat["mean"]))
                if candidates and min(candidates, key=lambda item: item[1])[0] == variant:
                    count += 1
        wins.append(count)
    plt.figure(figsize=(9, 5))
    plt.bar(variants, wins)
    plt.title("Win Count by Variant")
    plt.xlabel("Variant")
    plt.ylabel("Fastest configs")
    plt.xticks(rotation=20, ha="right")
    plt.grid(True, axis="y", alpha=0.3)
    plt.tight_layout()
    plt.savefig(os.path.join(out_dir, "win_counts.png"), dpi=150)
    plt.close()

    pause_variants = [variant for variant in variants if variant in pause_stats]
    if pause_variants:
        x = list(range(len(pause_variants)))
        width = 0.38
        means = [pause_stats[v]["mean"] for v in pause_variants]
        p99s = [pause_stats[v]["p99"] for v in pause_variants]
        plt.figure(figsize=(9, 5))
        plt.bar([i - width / 2 for i in x], means, width=width, label="mean")
        plt.bar([i + width / 2 for i in x], p99s, width=width, label="p99")
        plt.title("GC Pause Time by Variant")
        plt.xlabel("Variant")
        plt.ylabel("Pause time (s)")
        plt.xticks(x, pause_variants, rotation=20, ha="right")
        plt.grid(True, axis="y", alpha=0.3)
        plt.legend()
        plt.tight_layout()
        plt.savefig(os.path.join(out_dir, "gc_pause_mean_p99.png"), dpi=150)
        plt.close()


def main():
    parser = argparse.ArgumentParser(description="Plot alloc-free GC benchmark results")
    parser.add_argument(
        "--csv",
        default=os.path.join(SCRIPT_DIR, "results.csv"),
        help="Input CSV path from benchmarking/bench.sh",
    )
    parser.add_argument(
        "--out-dir",
        default=os.path.join(SCRIPT_DIR, "benchmark_plots"),
        help="Output directory for PNGs and derived CSVs",
    )
    parser.add_argument(
        "--baseline",
        default="normal",
        help="Baseline variant used for speedup plots",
    )
    parser.add_argument(
        "--strict-grid",
        action="store_true",
        help="Fail if any observed variant/depth/thread combination is missing",
    )
    parser.add_argument("--no-plot", action="store_true", help="Only write summary CSVs")
    args = parser.parse_args()

    rows = load_rows(args.csv)
    if not rows:
        raise ValueError("CSV has no valid data rows.")

    stats = mean_by_variant_depth_threads(rows)
    variants = sorted({r["variant"] for r in rows}, key=variant_sort_key)
    depths = sorted({r["depth"] for r in rows})
    threads = sorted({r["threads"] for r in rows})

    missing = evaluate_completeness(rows, variants, depths, threads)
    if missing:
        preview = ", ".join(f"({v},d={d},t={t})" for v, d, t in missing[:8])
        tail = " ..." if len(missing) > 8 else ""
        message = f"CSV has missing variant/depth/thread combinations: {preview}{tail}"
        if args.strict_grid:
            raise ValueError(message)
        print(f"Warning: {message}")

    os.makedirs(args.out_dir, exist_ok=True)
    remove_stale_outputs(args.out_dir)

    summary_path = os.path.join(args.out_dir, "summary_stats.csv")
    speedup_path = os.path.join(args.out_dir, f"speedup_vs_{args.baseline}.csv")
    win_counts_path = os.path.join(args.out_dir, "win_counts.csv")
    pause_stats_path = os.path.join(args.out_dir, "gc_pause_stats.csv")

    write_summary_csv(summary_path, stats)
    write_speedup_csv(speedup_path, stats, variants, depths, threads, args.baseline)
    write_win_counts_csv(win_counts_path, stats, variants, depths, threads)

    pause_stats = load_pause_stats(os.path.dirname(os.path.abspath(args.csv)))
    write_pause_stats_csv(pause_stats_path, pause_stats, variants)

    print("Logical evaluation (mean of config means):")
    for variant in variants:
        means = [stat["mean"] for (v, _d, _t), stat in stats.items() if v == variant]
        print(f"  {variant}: {statistics.mean(means):.6f} sec")
    print(f"Summary CSV written: {summary_path}")
    print(f"Speedup CSV written: {speedup_path}")
    print(f"Win-count CSV written: {win_counts_path}")
    print(f"GC pause CSV written: {pause_stats_path}")

    if args.no_plot:
        print("Skipping plot generation due to --no-plot")
        return

    try:
        plot_outputs(args.out_dir, stats, variants, depths, threads, args.baseline, pause_stats)
    except ImportError as e:
        raise RuntimeError("matplotlib is required for plotting.") from e

    print(f"Plots written to: {args.out_dir}")


if __name__ == "__main__":
    main()
