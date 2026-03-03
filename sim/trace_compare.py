#!/usr/bin/env python3
"""trace_compare.py — Compare MAME and RTL execution traces.

Reads two CSV trace files and reports the first N mismatches.

Usage:
    python3 trace_compare.py <mame_trace.csv> <rtl_trace.csv> [--max-diff N]
"""

import csv
import sys
import argparse


def read_trace(filename):
    """Read a trace CSV file and return list of dicts."""
    rows = []
    with open(filename, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(row)
    return rows


def compare_traces(mame_rows, rtl_rows, max_diff=10):
    """Compare two traces and report mismatches."""
    min_len = min(len(mame_rows), len(rtl_rows))
    diffs = 0
    matched = 0

    for i in range(min_len):
        mame = mame_rows[i]
        rtl = rtl_rows[i]

        mismatched_fields = []
        for key in mame.keys():
            if key == 'step':
                continue
            if key in rtl:
                if mame[key].strip() != rtl[key].strip():
                    mismatched_fields.append(
                        f"  {key}: MAME={mame[key]} RTL={rtl[key]}"
                    )

        if mismatched_fields:
            print(f"MISMATCH at step {i}:")
            print(f"  MAME PC={mame.get('PC', '?')}  RTL PC={rtl.get('PC', '?')}")
            for field in mismatched_fields:
                print(field)
            print()
            diffs += 1
            if diffs >= max_diff:
                print(f"... stopping after {max_diff} mismatches")
                break
        else:
            matched += 1

    if len(mame_rows) != len(rtl_rows):
        print(f"WARNING: Trace lengths differ: MAME={len(mame_rows)} RTL={len(rtl_rows)}")

    print(f"\nSummary: {matched} matched, {diffs} mismatched out of {min_len} steps")
    return diffs == 0


def main():
    parser = argparse.ArgumentParser(description='Compare MAME and RTL traces')
    parser.add_argument('mame_trace', help='MAME trace CSV file')
    parser.add_argument('rtl_trace', help='RTL trace CSV file')
    parser.add_argument('--max-diff', type=int, default=10,
                        help='Maximum number of mismatches to report')
    args = parser.parse_args()

    mame_rows = read_trace(args.mame_trace)
    rtl_rows = read_trace(args.rtl_trace)

    print(f"MAME trace: {len(mame_rows)} steps from {args.mame_trace}")
    print(f"RTL trace:  {len(rtl_rows)} steps from {args.rtl_trace}")
    print()

    success = compare_traces(mame_rows, rtl_rows, args.max_diff)
    sys.exit(0 if success else 1)


if __name__ == '__main__':
    main()
