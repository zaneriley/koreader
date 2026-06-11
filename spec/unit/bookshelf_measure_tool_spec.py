import importlib.util
import contextlib
import io
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[2] / "tools" / "bookshelf_measure.py"
SPEC = importlib.util.spec_from_file_location("bookshelf_measure", MODULE_PATH)
bookshelf_measure = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bookshelf_measure)


def sample(elapsed_ms, notes=""):
    return {
        "timestamp": "2026-05-05T00:00:00Z",
        "commit": "abc1234",
        "device": "remarkable2",
        "scenario": "enter_home_bookshelf",
        "cache_state": "warm",
        "library_size": "100",
        "iteration": "1",
        "elapsed_ms": str(elapsed_ms),
        "notes": notes,
    }


class BookshelfMeasureToolTest(unittest.TestCase):
    def test_summarize_uses_required_schema_and_nearest_rank_p95(self):
        samples = [sample(value) for value in range(10, 110, 10)]

        summary = bookshelf_measure.summarize_samples(
            samples,
            timestamp="2026-05-05T01:02:03Z",
        )

        self.assertEqual(1, len(summary))
        self.assertEqual(list(bookshelf_measure.SUMMARY_FIELDS), list(summary[0].keys()))
        self.assertEqual("55.000", summary[0]["median_ms"])
        self.assertEqual("100.000", summary[0]["p95_ms"])
        self.assertEqual("100.000", summary[0]["max_ms"])
        self.assertEqual("n=10", summary[0]["notes"])

    def test_summarize_preserves_distinct_notes_once(self):
        samples = [
            sample(30, "first run after reboot"),
            sample(40, "first run after reboot"),
            sample(50, "OPDS catalog disabled"),
        ]

        summary = bookshelf_measure.summarize_samples(samples)

        self.assertEqual(
            "n=3; first run after reboot; OPDS catalog disabled",
            summary[0]["notes"],
        )

    def test_append_and_read_samples_round_trip_csv(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "samples.csv"
            rows = [
                sample(12.5, "plain"),
                sample(15.75, "comma, newline\nquote\""),
            ]

            bookshelf_measure.append_samples(path, rows)
            read_back = bookshelf_measure.read_samples(path)

            self.assertEqual("12.500", read_back[0]["elapsed_ms"])
            self.assertEqual("comma, newline\nquote\"", read_back[1]["notes"])

    def test_read_samples_missing_file_raises_measurement_error(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "missing.csv"

            with self.assertRaisesRegex(bookshelf_measure.MeasurementError, "does not exist"):
                bookshelf_measure.read_samples(path)

    def test_main_summarize_missing_samples_returns_clean_error(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "missing.csv"
            stderr = io.StringIO()

            with contextlib.redirect_stderr(stderr):
                code = bookshelf_measure.main(["summarize", "--samples", str(path)])

            self.assertEqual(2, code)
            self.assertIn("bookshelf_measure.py: error:", stderr.getvalue())
            self.assertNotIn("Traceback", stderr.getvalue())

    def test_invalid_scenario_is_rejected(self):
        bad_sample = sample(10)
        bad_sample["scenario"] = "made_up"

        with self.assertRaises(bookshelf_measure.MeasurementError):
            bookshelf_measure.summarize_samples([bad_sample])

    def test_startup_scenarios_are_accepted(self):
        for scenario in ("default_bookshelf_launch", "reader_home_bookshelf_return"):
            row = sample(10)
            row["scenario"] = scenario

            summary = bookshelf_measure.summarize_samples([row])

            self.assertEqual(scenario, summary[0]["scenario"])


if __name__ == "__main__":
    unittest.main()
