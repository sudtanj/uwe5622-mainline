#!/usr/bin/env python3
"""Assemble metrics.json and compare it with the previous main run.

  metrics.py collect --out metrics.json --kernel VER --flavour perf --mem 1024 \
      --modules DIR METRICS.txt [METRICS.txt...]
  metrics.py compare --cur metrics.json [--prev prev/metrics.json] \
      [--summary FILE] [--max-regress 20] [--min-abs-kb 64]

collect: merges the guest's "key value" lines with the section sizes of
the .ko files (GNU size -A: .text, .data, .rodata, .bss, ...).

compare: prints a Markdown table (to stdout and --summary) of every metric
with the previous value and the change. Exit status 1 only when the gated
metric, the unreclaimable memory pinned by loading the modules
(mem.load.pinned_kb, and sim.up.pinned_kb when present), grew by more than
--max-regress percent and by more than --min-abs-kb kB; everything else is
informational.
"""
import argparse
import json
import os
import subprocess
import sys

GATED = ("mem.load.pinned_kb", "sim.up.pinned_kb")
HEADLINE = (
    ("mem.load.pinned_kb", "Unreclaimable memory pinned by insmod (kB)"),
    ("mem.load.sunreclaim_kb", "  of which unreclaimable slab (kB)"),
    ("mem.load.vmallocused_kb", "  of which vmalloc, incl. module text (kB)"),
    ("mem.load.memavailable_kb", "MemAvailable drop after insmod (kB)"),
    ("mem.unload_residue.pinned_kb", "Pinned memory left after rmmod (kB)"),
    ("mem.load.kthreads", "Kernel threads started by the modules"),
    ("idle.baseline.irq_per_s", "Interrupts/s idle, no modules"),
    ("idle.loaded.irq_per_s", "Interrupts/s idle, modules loaded"),
    ("idle.loaded.timer_expire_entry.driver_per_s", "Driver timer expiries/s (idle)"),
    ("idle.loaded.hrtimer_expire_entry.driver_per_s", "Driver hrtimer expiries/s (idle)"),
    ("idle.loaded.workqueue_execute_start.driver_per_s", "Driver work items/s (idle)"),
    ("idle.loaded.driver_kthread_cpu_ms", "Driver kthread CPU over the idle window (ms)"),
    ("ko.total.text", "Module .text, all three (bytes)"),
    ("ko.total.data", "Module .data, all three (bytes)"),
    ("ko.total.bss", "Module .bss, all three (bytes)"),
    ("sim.up.pinned_kb", "Sim: pinned memory with wlan0 up (kB)"),
    ("sim.assoc.irq_per_s", "Sim: interrupts/s idle, associated"),
    ("sim.assoc.driver_kthread_cpu_ms", "Sim: driver kthread CPU idle, associated (ms)"),
    ("sim.tput.tx_frames", "Sim: TX frames seen by the chip over 100 pings"),
    ("sim.tput.cpu_ticks_per_100_pings", "Sim: CPU ticks for 100 pings"),
    ("sim.down_residue.pinned_kb", "Sim: pinned memory left after unload (kB)"),
)


def num(s):
    try:
        v = float(s)
    except ValueError:
        return None
    return int(v) if v.is_integer() else v


def ko_sizes(moddir):
    out = {}
    total = {}
    for name in sorted(os.listdir(moddir)):
        if not name.endswith(".ko"):
            continue
        mod = name[:-3]
        res = subprocess.run(["size", "-A", os.path.join(moddir, name)],
                             capture_output=True, text=True, check=True)
        for line in res.stdout.splitlines():
            parts = line.split()
            if len(parts) < 2 or not parts[1].isdigit():
                continue
            sec = parts[0].lstrip(".")
            # group .text.unlikely etc. under their main section
            for main in ("text", "rodata", "data", "bss"):
                if sec == main or sec.startswith(main + "."):
                    key = f"ko.{mod}.{main}"
                    out[key] = out.get(key, 0) + int(parts[1])
                    if mod in ("uwe5622_bsp_sdio", "sprdwl_ng", "sprdbt_tty"):
                        total[main] = total.get(main, 0) + int(parts[1])
                    break
    for main, v in total.items():
        out[f"ko.total.{main}"] = v
    return out


def collect(a):
    metrics = {}
    for path in a.files:
        if not os.path.exists(path):
            continue
        with open(path) as f:
            for line in f:
                parts = line.split()
                if len(parts) == 2 and num(parts[1]) is not None:
                    metrics[parts[0]] = num(parts[1])
    if a.modules:
        metrics.update(ko_sizes(a.modules))
    doc = {
        "schema": 1,
        "commit": os.environ.get("GITHUB_SHA", ""),
        "run_id": os.environ.get("GITHUB_RUN_ID", ""),
        "kernel": a.kernel,
        "flavour": a.flavour,
        "mem_mb": a.mem,
        "metrics": dict(sorted(metrics.items())),
    }
    with open(a.out, "w") as f:
        json.dump(doc, f, indent=1)
        f.write("\n")
    print(f"{a.out}: {len(metrics)} metrics")


def fmt(v):
    if v is None:
        return "–"
    if isinstance(v, float):
        return f"{v:.2f}"
    return str(v)


def change(prev, cur):
    if prev is None or cur is None:
        return "", None
    d = cur - prev
    pct = (100.0 * d / abs(prev)) if prev else None
    ds = f"{d:+.2f}" if isinstance(d, float) else f"{d:+d}"
    if pct is not None:
        ds += f" ({pct:+.1f}%)"
    return ds, pct


def compare(a):
    with open(a.cur) as f:
        cur = json.load(f)
    prev = None
    if a.prev and os.path.exists(a.prev):
        with open(a.prev) as f:
            prev = json.load(f)
    cm = cur["metrics"]
    pm = prev["metrics"] if prev else {}
    lines = [f"### Driver metrics ({cur['flavour']} kernel {cur['kernel']}, {cur['mem_mb']} MB)", ""]
    if prev:
        lines.append(f"Compared with main run {prev.get('run_id', '?')} "
                     f"(commit {prev.get('commit', '?')[:12]}).")
    else:
        lines.append("No previous main run with metrics.json found; no comparison.")
    lines += ["", "| Metric | Previous | Now | Change |", "|---|---:|---:|---:|"]
    failed = []
    for key, label in HEADLINE:
        if key not in cm and key not in pm:
            continue
        ds, pct = change(pm.get(key), cm.get(key))
        mark = ""
        if key in GATED and pct is not None and cm[key] - pm[key] > a.min_abs_kb and pct > a.max_regress:
            mark = " :x:"
            failed.append(f"{key}: {pm[key]} -> {cm[key]} kB ({pct:+.1f}%)")
        lines.append(f"| {label} (`{key}`) | {fmt(pm.get(key))} | {fmt(cm.get(key))} | {ds}{mark} |")
    lines += ["", "<details><summary>All metrics</summary>", "",
              "| Key | Previous | Now | Change |", "|---|---:|---:|---:|"]
    for key in sorted(set(cm) | set(pm)):
        ds, _ = change(pm.get(key), cm.get(key))
        lines.append(f"| `{key}` | {fmt(pm.get(key))} | {fmt(cm.get(key))} | {ds} |")
    lines += ["", "</details>", ""]
    if failed:
        lines.append(f"**Memory regression over {a.max_regress}% (and {a.min_abs_kb} kB):** "
                     + "; ".join(failed))
    else:
        lines.append(f"Gate: pinned module memory may not grow by more than {a.max_regress}% "
                     f"(and {a.min_abs_kb} kB) versus the previous main run: passed.")
    text = "\n".join(lines) + "\n"
    print(text)
    if a.summary:
        with open(a.summary, "a") as f:
            f.write(text)
    for msg in failed:
        print(f"::error::metrics: memory regression {msg}")
    return 1 if failed else 0


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("collect")
    c.add_argument("--out", required=True)
    c.add_argument("--kernel", default="")
    c.add_argument("--flavour", default="")
    c.add_argument("--mem", type=int, default=0)
    c.add_argument("--modules")
    c.add_argument("files", nargs="*")
    k = sub.add_parser("compare")
    k.add_argument("--cur", required=True)
    k.add_argument("--prev")
    k.add_argument("--summary")
    k.add_argument("--max-regress", type=float, default=20.0)
    k.add_argument("--min-abs-kb", type=float, default=64.0)
    a = p.parse_args()
    if a.cmd == "collect":
        collect(a)
        return 0
    return compare(a)


if __name__ == "__main__":
    sys.exit(main())
