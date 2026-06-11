import contextlib
import importlib.util
import io
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[2] / "tools" / "bookshelf_seed_sample_library.py"
SPEC = importlib.util.spec_from_file_location("bookshelf_seed_sample_library", MODULE_PATH)
seed = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = seed
SPEC.loader.exec_module(seed)


class BookshelfSeedSampleLibraryToolTest(unittest.TestCase):
    def test_download_books_accepts_external_absolute_library(self):
        old_books = seed.GUTENBERG_BOOKS
        old_run = seed.run
        calls = []
        try:
            seed.GUTENBERG_BOOKS = [seed.GutenbergBook(1, "book.epub")]
            seed.run = lambda cmd: calls.append(cmd)
            with tempfile.TemporaryDirectory() as tmpdir:
                library = Path(tmpdir) / "sample-library"
                stdout = io.StringIO()

                with contextlib.redirect_stdout(stdout):
                    seed.download_books(library)

                self.assertEqual(1, len(calls))
                self.assertIn(str(library / "book.epub"), stdout.getvalue())
        finally:
            seed.GUTENBERG_BOOKS = old_books
            seed.run = old_run

    def test_configure_settings_missing_external_path_reports_skip(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            settings = Path(tmpdir) / "missing" / "settings.reader.lua"
            stdout = io.StringIO()

            with contextlib.redirect_stdout(stdout):
                seed.configure_settings(settings, "/books")

            self.assertIn("skip settings update; missing", stdout.getvalue())
            self.assertIn(str(settings), stdout.getvalue())


if __name__ == "__main__":
    unittest.main()
