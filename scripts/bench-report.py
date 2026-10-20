#!/usr/bin/env python3
"""Summarizes a bench-compare.py results directory as Markdown tables.

Usage: scripts/bench-report.py <results dir>   (or --self-test)

Per metric and engine: median, IQR and n, warm-up round excluded. The best
median is bold; a cell marked ≈ has an IQR overlapping the best one's, so
its difference from the best isn't clear at this sample size.
"""
import json
import statistics
import sys
from pathlib import Path


def quartiles(xs):
    """(q1, median, q3) of xs; a single sample is its own spread."""
    if len(xs) == 1:
        return xs[0], xs[0], xs[0]
    q1, med, q3 = statistics.quantiles(xs, n=4, method="inclusive")
    return q1, med, q3


def summarize(records):
    """{(suite, metric): (unit, better, {engine: (q1, med, q3, n)})}, warm-ups and missing values dropped."""
    groups = {}
    for r in records:
        if r["warmup"] or r["value"] is None:
            continue
        key = (r["suite"], r["metric"])
        unit, better, per = groups.setdefault(key, (r["unit"], r["better"], {}))
        per.setdefault(r["engine"], []).append(r["value"])
    return {k: (u, b, {e: (*quartiles(xs), len(xs)) for e, xs in per.items()}) for k, (u, b, per) in groups.items()}


def num(x):
    """x with three significant digits, without exponent notation."""
    return f"{x:,.0f}" if abs(x) >= 1000 else f"{x:.3g}"


def cells(better, per):
    """Formatted table cells per engine."""
    pick = max if better == "higher" else min
    best = pick(per, key=lambda e: per[e][1])
    bq1, _, bq3, _ = per[best]
    out = {}
    for e, (q1, med, q3, n) in per.items():
        text = f"{num(med)} ({num(q1)}–{num(q3)}, n={n})"
        if e == best:
            text = f"**{text}**"
        elif q1 <= bq3 and bq1 <= q3:
            text = f"≈ {text}"
        out[e] = text
    return out


def report(directory):
    records = [json.loads(l) for l in (directory / "raw.jsonl").read_text().splitlines() if l.strip()]
    engines = list(dict.fromkeys(r["engine"] for r in records))
    summary = summarize(records)
    lines = []
    for suite in dict.fromkeys(s for s, _ in summary):
        lines += [f"## {suite}", "", "| metric | unit | " + " | ".join(engines) + " |", "|---|---|" + "---|" * len(engines)]
        for (s, metric), (unit, better, per) in summary.items():
            if s == suite:
                c = cells(better, per)
                arrow = "↑" if better == "higher" else "↓"
                lines.append(f"| {metric} | {unit} {arrow} | " + " | ".join(c.get(e, "–") for e in engines) + " |")
        lines.append("")
    return "\n".join(lines)


def self_test():
    rec = lambda e, v, w=False: dict(engine=e, suite="s", metric="m", unit="s", better="lower", value=v, warmup=w)
    records = [rec("a", 100, True), rec("a", 1), rec("a", 2), rec("a", 3), rec("b", 2), rec("b", 2.5), rec("b", 4),
               rec("c", 10), rec("c", 11), rec("c", None)]
    (_, _, per), = summarize(records).values()
    assert per["a"] == (1.5, 2, 2.5, 3), per["a"]
    assert per["c"][3] == 2
    c = cells("lower", per)
    assert c["a"].startswith("**") and c["b"].startswith("≈") and not c["c"].startswith(("≈", "**")), c
    print("ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    elif len(sys.argv) == 2:
        print(report(Path(sys.argv[1])))
    else:
        sys.exit(__doc__)
