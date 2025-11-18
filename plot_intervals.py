#!/usr/bin/env python3
import re
import sys
from pathlib import Path
from collections import defaultdict

import numpy as np
import matplotlib.pyplot as plt


def parse_log(path: str, source_label: str):
    """
    Parse a benchmark .log file and extract:
      - dataset (email / images / pride and prejudice, etc.)
      - alphabet (STD / SRP)
      - ctx->length
      - throughput (GB/s)
      - derived newline_interval in bytes (if ctx % 3 == 0)
      - source (main/control)
    """
    text = Path(path).read_text(encoding="utf-8", errors="ignore")
    data = []

    current_dataset = None
    current_alpha = None
    current_ctx = None

    for line in text.splitlines():
        # 📂 Dataset (email) : /path
        # 🖼️ Dataset (images): /path
        # 📖 Dataset (pride and prejudice): /path
        m = re.search(r"Dataset\s*\((.*?)\)\s*:\s*(.*)", line)
        if m:
            current_dataset = m.group(1).strip()
            continue

        # ======================= Alphabet: X =======================
        m = re.search(r"Alphabet:\s*(\S+)", line)
        if m:
            current_alpha = m.group(1).strip()  # STD or SRP
            continue

        # -----------------------Custom ctx->lengths mode: X---------------------------
        m = re.search(r"Custom ctx->lengths mode:\s*(\d+)", line)
        if m:
            current_ctx = int(m.group(1))
            continue

        # Throughput:              X GB/s
        m = re.search(r"Throughput:\s+([\d.]+)\s+GB/s", line)
        if m and current_dataset and current_alpha and current_ctx is not None:
            thr = float(m.group(1))
            ctx = current_ctx

            # Skip ctx->length = 48 (requested outlier skip)
            if ctx == 48:
                current_ctx = None
                continue

            # When ctx is a multiple of 3:
            #   newline_interval = 4 * (ctx / 3) bytes
            if ctx % 3 == 0:
                newline_interval = 4 * (ctx // 3)
            else:
                newline_interval = None  # non-4 interval (scalar-ish fallback)

            data.append(
                {
                    "dataset": current_dataset,
                    "alphabet": current_alpha,
                    "ctx": ctx,
                    "throughput_gbps": thr,
                    "newline_interval": newline_interval,
                    "source": source_label,
                }
            )

            # reset ctx until next "Custom ctx->lengths mode:"
            current_ctx = None

    return data


def color_for_dataset(ds: str, idx: int, color_cycle):
    """Fixed colors for known datasets, fallback to cycle."""
    norm = ds.lower().strip()
    if "email" in norm:
        return "tab:blue"
    if "image" in norm or "mula" in norm:
        return "tab:orange"
    if (
        "pride" in norm
        or "prejudice" in norm
        or "mobi" in norm
        or "one big" in norm
    ):
        return "tab:green"
    return color_cycle[idx % len(color_cycle)]


def main():
    if len(sys.argv) < 2:
        print("Usage:")
        print("  python plot_intervals.py MAIN_LOG [CONTROL_LOG] [ALPHABET] [RANGE]")
        print("  ALPHABET: STD or SRP (default: STD)")
        print("  RANGE   :")
        print("     ge32     -> newline interval ≥ 32 bytes (default)")
        print("     ge16-32  -> 16 ≤ newline interval < 32 bytes")
        print("     non4     -> cases with no 4-byte interval (ctx % 3 != 0, ctx != 1)")
        sys.exit(1)

    main_log = sys.argv[1]

    control_log = None
    if len(sys.argv) >= 3 and sys.argv[2] not in ("", "-"):
        control_log = sys.argv[2]

    alphabet = "STD"
    if len(sys.argv) >= 4 and sys.argv[3]:
        alphabet = sys.argv[3].upper()

    # interval range mode: ge32 (default) or ge16-32 or non4
    range_mode = "ge32"
    if len(sys.argv) >= 5 and sys.argv[4]:
        range_mode = sys.argv[4].lower()

    # Define filtering logic based on range_mode
    if range_mode == "ge32":
        def keep_entry(d):
            inv = d["newline_interval"]
            return (
                d["alphabet"].upper() == alphabet
                and inv is not None
                and inv >= 32
            )
        range_desc = "newline interval ≥ 32 bytes"
        range_suffix = "ge32"

    elif range_mode == "ge16-32":
        def keep_entry(d):
            inv = d["newline_interval"]
            return (
                d["alphabet"].upper() == alphabet
                and inv is not None
                and (inv >= 16) and (inv < 32)
            )
        range_desc = "16 ≤ newline interval < 32 bytes"
        range_suffix = "ge16-32"

    elif range_mode == "non4":
        # non-4 intervals: ctx % 3 != 0 → newline_interval is None
        # additionally skip ctx == 1 as an outlier
        def keep_entry(d):
            return (
                d["alphabet"].upper() == alphabet
                and d["newline_interval"] is None
                and d["ctx"] != 1
            )
        range_desc = "non-4 intervals (ctx % 3 != 0, excluding ctx=1)"
        range_suffix = "non4"

    else:
        print("Unknown RANGE argument:", range_mode)
        print("Use: ge32, ge16-32, or non4")
        sys.exit(1)

    # --- parse logs ---
    all_data = []
    all_data.extend(parse_log(main_log, "main"))
    if control_log is not None:
        all_data.extend(parse_log(control_log, "control"))

    if not all_data:
        print("No data parsed from logs.")
        sys.exit(1)

    # Apply filter
    filtered = [d for d in all_data if keep_entry(d)]

    if not filtered:
        print(f"No entries found for alphabet {alphabet} with {range_desc}.")
        sys.exit(0)

    # Debug summary
    datasets = sorted({d["dataset"] for d in filtered})
    sources = sorted({d["source"] for d in filtered})
    print("Alphabet:", alphabet)
    print("Range   :", range_desc)
    print("Datasets found:", datasets)
    print("Sources found :", sources)
    print("Total points after filtering:", len(filtered))

    # Group per (dataset, source)
    grouped = defaultdict(list)
    for d in filtered:
        key = (d["dataset"], d["source"])
        grouped[key].append(d)

    # --- plotting setup ---
    plt.figure(figsize=(9, 5))

    color_cycle = plt.rcParams["axes.prop_cycle"].by_key()["color"]
    # consistent colors per dataset name
    dataset_colors = {
        ds: color_for_dataset(ds, i, color_cycle)
        for i, ds in enumerate(datasets)
    }

    # line style per source (main vs control)
    linestyle_for_source = {
        "main": "-",
        "control": "--",
    }
    fit_linestyle_for_source = {
        "main": ":",
        "control": ":",
    }

    # --- plot points + linear regression ---
    for (dataset, source), pts in grouped.items():
        pts = sorted(pts, key=lambda x: x["ctx"])
        xs = np.array([p["ctx"] for p in pts], dtype=float)
        ys = np.array([p["throughput_gbps"] for p in pts], dtype=float)

        if len(xs) == 0:
            continue

        print(f"{dataset} [{source}]: {len(xs)} points")

        color = dataset_colors[dataset]
        linestyle = linestyle_for_source.get(source, "-")
        marker = "o"
        label = f"{dataset} ({source})"

        # scatter/line for raw data
        plt.plot(
            xs,
            ys,
            marker=marker,
            linestyle=linestyle,
            color=color,
            label=label,
        )

        # linear regression (only if we have at least 2 points)
        if len(xs) >= 2:
            coeffs = np.polyfit(xs, ys, 1)
            m, b = coeffs
            x_fit = np.linspace(xs.min(), xs.max(), 100)
            y_fit = m * x_fit + b

            fit_label = f"{dataset} ({source} fit)"
            plt.plot(
                x_fit,
                y_fit,
                linestyle=fit_linestyle_for_source.get(source, ":"),
                color=color,
                alpha=0.7,
                label=fit_label,
            )

            # print regression info
            print(f"[{dataset} | {source}] y = {m:.4f} * ctx + {b:.4f}")

    plt.title(
        f"Throughput vs ctx->length — {alphabet}\n({range_desc})"
    )
    plt.xlabel("ctx->length")
    plt.ylabel("Throughput (GB/s)")
    plt.grid(True, alpha=0.3)
    plt.legend()
    plt.tight_layout()

    # output name depends on alphabet + range + control
    base = Path(main_log).with_suffix("")
    if control_log:
        out = base.with_name(
            base.name + f".{range_suffix}_{alphabet}_with_control.png"
        )
    else:
        out = base.with_name(
            base.name + f".{range_suffix}_{alphabet}.png"
        )

    plt.savefig(out)
    print(f"Saved plot to {out}")
    plt.show()


if __name__ == "__main__":
    main()
