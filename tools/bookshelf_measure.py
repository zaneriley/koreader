#!/usr/bin/env python3
"""Record and summarize bookshelf prototype timing samples."""

from __future__ import annotations

import argparse
import csv
import math
import statistics
import subprocess
import sys
import time
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path


SCENARIOS = (
    "default_bookshelf_launch",
    "reader_home_bookshelf_return",
    "enter_home_bookshelf",
    "downloaded_books_cached_load",
    "first_visible_paint",
    "first_thumbnail_row_resolved",
    "shelf_page_transition",
    "tap_acknowledgement",
    "downloaded_book_open",
    "dictionary_lookup_open",
    "add_books_open",
)

SAMPLE_FIELDS = (
    "timestamp",
    "commit",
    "device",
    "scenario",
    "cache_state",
    "library_size",
    "iteration",
    "elapsed_ms",
    "notes",
)

SUMMARY_FIELDS = (
    "timestamp",
    "commit",
    "device",
    "scenario",
    "cache_state",
    "library_size",
    "median_ms",
    "p95_ms",
    "max_ms",
    "notes",
)


class MeasurementError(ValueError):
    """Raised when a measurement row cannot be recorded or summarized."""


def utc_timestamp():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def git_commit():
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def ensure_parent(path):
    path = Path(path)
    if path.parent and not path.parent.exists():
        path.parent.mkdir(parents=True, exist_ok=True)


def parse_elapsed_ms(value):
    try:
        elapsed_ms = float(value)
    except (TypeError, ValueError) as err:
        raise MeasurementError(f"elapsed_ms must be a number, got {value!r}") from err
    if elapsed_ms < 0:
        raise MeasurementError(f"elapsed_ms must be non-negative, got {value!r}")
    return elapsed_ms


def parse_library_size(value):
    try:
        library_size = int(value)
    except (TypeError, ValueError) as err:
        raise MeasurementError(f"library_size must be an integer, got {value!r}") from err
    if library_size < 0:
        raise MeasurementError(f"library_size must be non-negative, got {value!r}")
    return str(library_size)


def validate_scenario(value):
    if value not in SCENARIOS:
        raise MeasurementError(
            f"unknown scenario {value!r}; expected one of {', '.join(SCENARIOS)}"
        )
    return value


def format_ms(value):
    return f"{value:.3f}"


def p95_nearest_rank(values):
    if not values:
        raise MeasurementError("cannot compute p95 with no values")
    ordered = sorted(values)
    rank = max(1, math.ceil(0.95 * len(ordered)))
    return ordered[rank - 1]


def build_sample(args, elapsed_ms, iteration):
    return {
        "timestamp": utc_timestamp(),
        "commit": args.commit or git_commit(),
        "device": args.device,
        "scenario": validate_scenario(args.scenario),
        "cache_state": args.cache_state,
        "library_size": parse_library_size(args.library_size),
        "iteration": str(iteration),
        "elapsed_ms": format_ms(parse_elapsed_ms(elapsed_ms)),
        "notes": args.notes or "",
    }


def normalize_sample(sample):
    row = {field: sample.get(field, "") for field in SAMPLE_FIELDS}
    row["scenario"] = validate_scenario(row["scenario"])
    row["library_size"] = parse_library_size(row["library_size"])
    row["elapsed_ms"] = format_ms(parse_elapsed_ms(row["elapsed_ms"]))
    return row


def append_samples(path, samples):
    path = Path(path)
    ensure_parent(path)
    write_header = not path.exists() or path.stat().st_size == 0
    with path.open("a", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=SAMPLE_FIELDS, lineterminator="\n")
        if write_header:
            writer.writeheader()
        for sample in samples:
            writer.writerow(normalize_sample(sample))


def read_samples(path):
    path = Path(path)
    if not path.is_file():
        raise MeasurementError(f"samples file does not exist: {path}")
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames is None:
            return []
        missing = [field for field in SAMPLE_FIELDS if field not in reader.fieldnames]
        if missing:
            raise MeasurementError(f"{path} is missing sample columns: {', '.join(missing)}")
        return list(reader)


def summarize_samples(samples, timestamp=None):
    grouped = defaultdict(list)
    notes_by_group = defaultdict(list)

    for row in samples:
        scenario = validate_scenario(row.get("scenario", ""))
        library_size = parse_library_size(row.get("library_size", ""))
        elapsed_ms = parse_elapsed_ms(row.get("elapsed_ms", ""))
        key = (
            row.get("commit", ""),
            row.get("device", ""),
            scenario,
            row.get("cache_state", ""),
            library_size,
        )
        grouped[key].append(elapsed_ms)
        note = row.get("notes", "").strip()
        if note and note not in notes_by_group[key]:
            notes_by_group[key].append(note)

    summary_timestamp = timestamp or utc_timestamp()
    summaries = []
    for key in sorted(grouped):
        values = grouped[key]
        notes = [f"n={len(values)}"] + notes_by_group[key]
        summaries.append(
            {
                "timestamp": summary_timestamp,
                "commit": key[0],
                "device": key[1],
                "scenario": key[2],
                "cache_state": key[3],
                "library_size": key[4],
                "median_ms": format_ms(statistics.median(values)),
                "p95_ms": format_ms(p95_nearest_rank(values)),
                "max_ms": format_ms(max(values)),
                "notes": "; ".join(notes),
            }
        )
    return summaries


def write_summary(rows, output_path=None):
    if output_path:
        ensure_parent(output_path)
        handle = Path(output_path).open("w", newline="", encoding="utf-8")
        close_handle = True
    else:
        handle = sys.stdout
        close_handle = False
    try:
        writer = csv.DictWriter(handle, fieldnames=SUMMARY_FIELDS, lineterminator="\n")
        writer.writeheader()
        for row in rows:
            writer.writerow({field: row.get(field, "") for field in SUMMARY_FIELDS})
    finally:
        if close_handle:
            handle.close()


def parse_values(values_arg):
    if not values_arg:
        return []
    return [part.strip() for part in values_arg.split(",") if part.strip()]


def read_values_file(path):
    values = []
    with Path(path).open(encoding="utf-8") as handle:
        for line in handle:
            stripped = line.strip()
            if stripped and not stripped.startswith("#"):
                values.append(stripped)
    return values


def collect_repeat_values(args):
    values = parse_values(args.values)
    if args.values_file:
        values.extend(read_values_file(args.values_file))

    if values:
        if len(values) != args.iterations:
            raise MeasurementError(
                f"got {len(values)} elapsed values for {args.iterations} iterations"
            )
        return values

    values = []
    print(
        f"Enter {args.iterations} elapsed_ms values for {args.scenario}.",
        file=sys.stderr,
    )
    for iteration in range(1, args.iterations + 1):
        prompt = f"iteration {iteration} elapsed_ms: "
        if sys.stdin.isatty():
            value = input(prompt)
        else:
            print(prompt, end="", file=sys.stderr, flush=True)
            value = sys.stdin.readline()
        if value == "":
            raise MeasurementError("not enough elapsed_ms values on stdin")
        values.append(value.strip())
    return values


def command_for_run(args):
    command = list(args.command)
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        raise MeasurementError("run requires a command after --")
    return command


def add_common_record_args(parser):
    parser.add_argument("--samples", default=".tmp/bookshelf-measure/samples.csv")
    parser.add_argument("--device", required=True)
    parser.add_argument("--scenario", required=True, choices=SCENARIOS)
    parser.add_argument("--cache-state", required=True)
    parser.add_argument("--library-size", required=True)
    parser.add_argument("--commit", default=None)
    parser.add_argument("--notes", default="")


def build_parser():
    parser = argparse.ArgumentParser(
        description="Record raw bookshelf timing samples and summarize them as CSV."
    )
    subparsers = parser.add_subparsers(dest="action", required=True)

    add_parser = subparsers.add_parser("add", help="append one elapsed_ms sample")
    add_common_record_args(add_parser)
    add_parser.add_argument("--elapsed-ms", required=True)
    add_parser.add_argument("--iteration", type=int, default=1)

    repeat_parser = subparsers.add_parser(
        "repeat",
        help="append N manually supplied elapsed_ms samples, defaulting to 10 iterations",
    )
    add_common_record_args(repeat_parser)
    repeat_parser.add_argument("--iterations", type=int, default=10)
    repeat_parser.add_argument("--values", help="comma-separated elapsed_ms values")
    repeat_parser.add_argument("--values-file", help="one elapsed_ms value per line")

    run_parser = subparsers.add_parser(
        "run",
        help="repeat a command N times and record each wall-clock duration",
    )
    add_common_record_args(run_parser)
    run_parser.add_argument("--iterations", type=int, default=10)
    run_parser.add_argument("command", nargs=argparse.REMAINDER)

    summarize_parser = subparsers.add_parser(
        "summarize",
        help="aggregate raw samples into the bookshelf summary schema",
    )
    summarize_parser.add_argument("--samples", default=".tmp/bookshelf-measure/samples.csv")
    summarize_parser.add_argument("--output")

    subparsers.add_parser("scenarios", help="list supported scenario names")
    return parser


def require_positive_iterations(iterations):
    if iterations < 1:
        raise MeasurementError(f"iterations must be at least 1, got {iterations}")


def run_add(args):
    sample = build_sample(args, args.elapsed_ms, args.iteration)
    append_samples(args.samples, [sample])
    print(f"recorded 1 sample in {args.samples}")
    return 0


def run_repeat(args):
    require_positive_iterations(args.iterations)
    samples = []
    for iteration, value in enumerate(collect_repeat_values(args), start=1):
        samples.append(build_sample(args, value, iteration))
    append_samples(args.samples, samples)
    print(f"recorded {len(samples)} samples in {args.samples}")
    return 0


def run_command(args):
    require_positive_iterations(args.iterations)
    command = command_for_run(args)
    samples = []
    for iteration in range(1, args.iterations + 1):
        started = time.monotonic()
        completed = subprocess.run(command, check=False)
        elapsed_ms = (time.monotonic() - started) * 1000
        if completed.returncode != 0:
            raise MeasurementError(
                f"command failed on iteration {iteration} with exit code {completed.returncode}"
            )
        samples.append(build_sample(args, elapsed_ms, iteration))
    append_samples(args.samples, samples)
    print(f"recorded {len(samples)} command samples in {args.samples}")
    return 0


def run_summarize(args):
    samples = read_samples(args.samples)
    write_summary(summarize_samples(samples), args.output)
    if args.output:
        print(f"wrote summary to {args.output}")
    return 0


def run_scenarios():
    for scenario in SCENARIOS:
        print(scenario)
    return 0


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        if args.action == "add":
            return run_add(args)
        if args.action == "repeat":
            return run_repeat(args)
        if args.action == "run":
            return run_command(args)
        if args.action == "summarize":
            return run_summarize(args)
        if args.action == "scenarios":
            return run_scenarios()
        parser.error(f"unknown command {args.action}")
    except MeasurementError as err:
        print(f"bookshelf_measure.py: error: {err}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
