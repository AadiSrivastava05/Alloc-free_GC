#!/usr/bin/env python3
import argparse
import csv
import glob
import math
import os
import statistics
from collections import defaultdict


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


def load_rows(csv_path):
    rows = []
    skipped_rows = 0
    with open(csv_path, "r", newline="") as f:
        reader = csv.DictReader(f)
        required = {"variant", "depth", "threads", "run", "elapsed_sec"}
        if reader.fieldnames is None or not required.issubset(set(reader.fieldnames)):
            raise ValueError("CSV is missing required columns.")
        for idx, r in enumerate(reader, start=2):
            try:
                elapsed_raw = (r.get("elapsed_sec") or "").strip()
                if not elapsed_raw:
                    raise ValueError("elapsed_sec is empty")
                rows.append(
                    {
                        "variant": (r.get("variant") or "").strip(),
                        "depth": int(r["depth"]),
                        "threads": int(r["threads"]),
                        "run": int(r["run"]),
                        "elapsed_sec": float(elapsed_raw),
                    }
                )
            except (ValueError, TypeError, KeyError) as e:
                skipped_rows += 1
                print(f"Warning: skipping malformed CSV row {idx}: {e}")
    if skipped_rows:
        print(f"Warning: skipped {skipped_rows} malformed row(s) from {csv_path}")
    return rows


def mean_by_variant_depth_threads(rows):
    grouped = defaultdict(list)
    for r in rows:
        grouped[(r["variant"], r["depth"], r["threads"])].append(r["elapsed_sec"])

    stats = {}
    for k, vals in grouped.items():
        mean_v = sum(vals) / len(vals)
        std_v = statistics.stdev(vals) if len(vals) > 1 else 0.0
        stats[k] = {
            "mean": mean_v,
            "std": std_v,
            "min": min(vals),
            "max": max(vals),
            "n": len(vals),
        }
    return stats


def evaluate_completeness(rows, variants, depths, threads):
    seen = {(r["variant"], r["depth"], r["threads"]) for r in rows}
    missing = []
    for v in variants:
        for d in depths:
            for t in threads:
                if (v, d, t) not in seen:
                    missing.append((v, d, t))
    return missing


def write_summary_csv(summary_path, stats):
    with open(summary_path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["variant", "depth", "threads", "n", "mean_sec", "std_sec", "min_sec", "max_sec"])
        for (variant, depth, threads), s in sorted(stats.items()):
            w.writerow(
                [
                    variant,
                    depth,
                    threads,
                    s["n"],
                    f"{s['mean']:.6f}",
                    f"{s['std']:.6f}",
                    f"{s['min']:.6f}",
                    f"{s['max']:.6f}",
                ]
            )


def write_comparison_csv(comparison_path, stats, variants, depths, threads):
    with open(comparison_path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["variant", "depth", "threads", "variant_mean", "normal_mean", "speedup_normal_over_variant"])

        for variant in variants:
            if variant == "normal":
                continue

            for d in depths:
                for t in threads:
                    variant_s = stats.get((variant, d, t))
                    normal_s = stats.get(("normal", d, t))

                    variant_mean = variant_s["mean"] if variant_s else None
                    normal_mean = normal_s["mean"] if normal_s else None
                    speedup = normal_mean / variant_mean if variant_mean is not None and normal_mean is not None and variant_mean > 0 else math.nan

                    w.writerow(
                        [
                            variant,
                            d,
                            t,
                            f"{variant_mean:.6f}" if variant_mean is not None else "nan",
                            f"{normal_mean:.6f}" if normal_mean is not None else "nan",
                            "nan" if math.isnan(speedup) else f"{speedup:.6f}",
                        ]
                    )


def main():
    parser = argparse.ArgumentParser(description="Plot benchmark_results.csv for OxCaml GC variants")
    parser.add_argument("--csv", default=os.path.join(SCRIPT_DIR, "benchmark_results.csv"), help="Input CSV path")
    parser.add_argument("--out-dir", default=os.path.join(SCRIPT_DIR, "benchmark_plots"), help="Output directory for PNGs")
    parser.add_argument("--no-plot", action="store_true", help="Only evaluate and write summary CSVs")
    args = parser.parse_args()

    rows = load_rows(args.csv)
    if not rows:
        raise ValueError("CSV has no data rows.")

    stats = mean_by_variant_depth_threads(rows)
    variants = sorted({r["variant"] for r in rows})
    depths = sorted({r["depth"] for r in rows})
    threads = sorted({r["threads"] for r in rows})

    missing = evaluate_completeness(rows, variants, depths, threads)
    if missing:
        preview = ", ".join([f"({v},d={d},t={t})" for v, d, t in missing[:8]])
        tail = " ..." if len(missing) > 8 else ""
        raise ValueError(f"CSV has missing variant/depth/thread combinations: {preview}{tail}")

    os.makedirs(args.out_dir, exist_ok=True)

    for old_png in glob.glob(os.path.join(args.out_dir, "time_vs_threads_depth_*.png")):
        os.remove(old_png)
    stale_speedup = os.path.join(args.out_dir, "zero_speedup.png")
    if os.path.exists(stale_speedup):
        os.remove(stale_speedup)
    stale_speedup = os.path.join(args.out_dir, "normal_relative_speedup.png")
    if os.path.exists(stale_speedup):
        os.remove(stale_speedup)
    stale_comparison = os.path.join(args.out_dir, "zero_vs_normal_speedup.csv")
    if os.path.exists(stale_comparison):
        os.remove(stale_comparison)

    summary_path = os.path.join(args.out_dir, "summary_stats.csv")
    comparison_path = os.path.join(args.out_dir, "normal_relative_speedup.csv")
    write_summary_csv(summary_path, stats)
    write_comparison_csv(comparison_path, stats, variants, depths, threads)

    overall = defaultdict(list)
    for (variant, _d, _t), s in stats.items():
        overall[variant].append(s["mean"])

    print("Logical evaluation (mean of config means):")
    for variant in sorted(overall.keys()):
        mean_of_means = sum(overall[variant]) / len(overall[variant])
        print(f"  {variant}: {mean_of_means:.6f} sec")

    print(f"Summary CSV written: {summary_path}")
    print(f"Comparison CSV written: {comparison_path}")

    if args.no_plot:
        print("Skipping plot generation due to --no-plot")
        return

    try:
        import matplotlib.pyplot as plt
    except ImportError as e:
        raise RuntimeError(
            "matplotlib is required for plotting. In WSL use either apt install python3-matplotlib or a venv."
        ) from e

    for depth in depths:
        plt.figure(figsize=(8, 5))
        for variant in variants:
            y_vals = []
            for t in threads:
                s = stats.get((variant, depth, t))
                y_vals.append(float("nan") if s is None else s["mean"])
            plt.plot(threads, y_vals, marker="o", linewidth=2, label=variant)

        plt.title(f"Mean Time vs Threads (depth={depth})")
        plt.xlabel("Threads")
        plt.ylabel("Elapsed Time (s)")
        plt.xticks(threads)
        plt.grid(True, alpha=0.3)
        plt.legend()
        plt.tight_layout()
        out_path = os.path.join(args.out_dir, f"time_vs_threads_depth_{depth}.png")
        plt.savefig(out_path, dpi=150)
        plt.close()

    if "normal" in variants and len(variants) > 1:
        plt.figure(figsize=(9, 5))
        for variant in variants:
            if variant == "normal":
                continue

            for depth in depths:
                speedups = []
                for t in threads:
                    variant_s = stats.get((variant, depth, t))
                    normal_s = stats.get(("normal", depth, t))
                    if variant_s is None or normal_s is None or variant_s["mean"] == 0.0:
                        speedups.append(float("nan"))
                    else:
                        speedups.append(normal_s["mean"] / variant_s["mean"])

                plt.plot(threads, speedups, marker="o", linewidth=2, label=f"{variant}, depth={depth}")

        plt.axhline(1.0, color="black", linestyle="--", linewidth=1)
        plt.title("Normal / Variant Time Ratio")
        plt.xlabel("Threads")
        plt.ylabel("Ratio (normal / variant)")
        plt.xticks(threads)
        plt.grid(True, alpha=0.3)
        plt.legend()
        plt.tight_layout()
        speedup_path = os.path.join(args.out_dir, "normal_relative_speedup.png")
        plt.savefig(speedup_path, dpi=150)
        plt.close()

    print(f"Plots written to: {args.out_dir}")


if __name__ == "__main__":
    main()
