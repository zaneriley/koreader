#!/usr/bin/env python3
"""Seed a local Bookshelf QA library with public-domain test books.

The generated corpus is intentionally scratch data. It lives under .tmp/ so we
can exercise dense grids, page overflow, missing covers, long names, and real
EPUB cover art without committing binary book assets to the repository.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LIBRARY = ROOT / ".tmp" / "bookshelf-sample-library"
DEFAULT_SETTINGS = ROOT / ".tmp" / "koreader-home" / "settings.reader.lua"
DEFAULT_RUNTIME_LIBRARY = "/work/.tmp/bookshelf-sample-library"
OVERFLOW_FIXTURES = ROOT / ".tmp" / "bookshelf-overflow-docs"
USER_AGENT = "KOReader bookshelf QA seed/0.1"


@dataclass(frozen=True)
class GutenbergBook:
    ebook_id: int
    filename: str

    @property
    def source_url(self) -> str:
        return f"https://www.gutenberg.org/ebooks/{self.ebook_id}"

    @property
    def epub_url(self) -> str:
        return f"https://www.gutenberg.org/ebooks/{self.ebook_id}.epub.images"


GUTENBERG_BOOKS = [
    GutenbergBook(11, "01-alice-adventures-in-wonderland.epub"),
    GutenbergBook(84, "02-frankenstein.epub"),
    GutenbergBook(345, "03-dracula.epub"),
    GutenbergBook(35, "04-the-time-machine.epub"),
    GutenbergBook(36, "05-the-war-of-the-worlds.epub"),
    GutenbergBook(174, "06-the-picture-of-dorian-gray.epub"),
    GutenbergBook(1661, "07-adventures-of-sherlock-holmes.epub"),
    GutenbergBook(2701, "08-moby-dick.epub"),
    GutenbergBook(1952, "09-the-yellow-wallpaper.epub"),
    GutenbergBook(844, "10-the-importance-of-being-earnest.epub"),
    GutenbergBook(408, "11-the-souls-of-black-folk.epub"),
    GutenbergBook(514, "12-little-women.epub"),
    GutenbergBook(2591, "13-grimms-fairy-tales.epub"),
]

LOCAL_TEXT_FIXTURES = {
    "90-document-without-cover.txt": "Document without cover\n\nThis plain text file should always render with a placeholder cover.\n",
    "91-long-title-manual-without-cover.txt": (
        "A very long manual title that should wrap calmly across two lines without changing the card width\n\n"
        "Used to test all-books overflow and truncation without embedded artwork.\n"
    ),
    "92-dictionary-adjacent-notes.txt": "Dictionary adjacent notes\n\nA simple no-cover document near the bottom navigation.\n",
}

RECENT_ORDER = [
    "13-grimms-fairy-tales.epub",
    "12-little-women.epub",
    "90-document-without-cover.txt",
    "11-the-souls-of-black-folk.epub",
    "10-the-importance-of-being-earnest.epub",
    "local-05-japanese-typography-probe.epub",
]


def run(cmd: list[str]) -> None:
    subprocess.run(cmd, check=True)


def display_path(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def download_books(library: Path) -> None:
    library.mkdir(parents=True, exist_ok=True)
    for book in GUTENBERG_BOOKS:
        target = library / book.filename
        if target.exists() and target.stat().st_size > 0:
            continue
        print(f"download {book.source_url} -> {display_path(target)}")
        run([
            "curl",
            "--fail",
            "--location",
            "--retry",
            "2",
            "--connect-timeout",
            "15",
            "--max-time",
            "180",
            "-A",
            USER_AGENT,
            "-o",
            str(target),
            book.epub_url,
        ])


def write_local_text_fixtures(library: Path) -> None:
    for filename, body in LOCAL_TEXT_FIXTURES.items():
        (library / filename).write_text(body, encoding="utf-8")


def copy_overflow_fixtures(library: Path) -> int:
    if not OVERFLOW_FIXTURES.is_dir():
        return 0

    copied = 0
    for source in sorted(OVERFLOW_FIXTURES.iterdir()):
        if source.is_file() and source.suffix.lower() in {".pdf", ".epub", ".djvu", ".txt"}:
            target = library / ("local-" + source.name)
            if not target.exists() or target.stat().st_size != source.stat().st_size:
                shutil.copy2(source, target)
            copied += 1
    return copied


def stamp_library_for_recent_sort(library: Path) -> None:
    now = int(time.time())
    ordered = []
    seen = set()
    for filename in RECENT_ORDER:
        path = library / filename
        if path.exists():
            ordered.append(path)
            seen.add(path.name)
    ordered.extend(path for path in sorted(library.iterdir()) if path.is_file() and path.name not in seen)

    for offset, path in enumerate(ordered):
        timestamp = now - offset * 60
        os.utime(path, (timestamp, timestamp))


def lua_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def upsert_lua_setting(text: str, key: str, value: str) -> str:
    line = f'    ["{key}"] = {lua_string(value)},\n'
    pattern = re.compile(rf'^\s+\["{re.escape(key)}"\]\s*=.*,\n', re.MULTILINE)
    if pattern.search(text):
        return pattern.sub(line, text, count=1)
    return text.replace("return {\n", "return {\n" + line, 1)


def configure_settings(settings: Path, runtime_library: str) -> None:
    if not settings.exists():
        print(f"skip settings update; missing {display_path(settings)}")
        return

    text = settings.read_text(encoding="utf-8")
    first_book = runtime_library.rstrip("/") + "/" + GUTENBERG_BOOKS[0].filename
    for key, value in {
        "download_dir": runtime_library,
        "home_dir": runtime_library,
        "lastdir": runtime_library,
        "lastfile": first_book,
        "start_with": "library",
    }.items():
        text = upsert_lua_setting(text, key, value)
    settings.write_text(text, encoding="utf-8")
    print(f"configured {display_path(settings)}")


def configure_history(settings: Path, runtime_library: str) -> None:
    data_dir = settings.parent
    if settings.name != "settings.reader.lua":
        return
    if not data_dir.exists():
        return

    history = data_dir / "history.lua"
    first_book = runtime_library.rstrip("/") + "/" + GUTENBERG_BOOKS[0].filename
    second_book = runtime_library.rstrip("/") + "/" + "13-grimms-fairy-tales.epub"
    history.write_text(
        "-- generated by tools/bookshelf_seed_sample_library.py\n"
        "return {\n"
        f"    [1] = {{ [\"file\"] = {lua_string(first_book)}, [\"time\"] = {int(time.time())} }},\n"
        f"    [2] = {{ [\"file\"] = {lua_string(second_book)}, [\"time\"] = {int(time.time()) - 60} }},\n"
        "}\n",
        encoding="utf-8",
    )
    print(f"configured {display_path(history)}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, default=DEFAULT_LIBRARY)
    parser.add_argument("--runtime-library", default=DEFAULT_RUNTIME_LIBRARY)
    parser.add_argument("--settings", type=Path, default=DEFAULT_SETTINGS)
    parser.add_argument("--no-settings", action="store_true")
    args = parser.parse_args()

    library = args.library.resolve()
    download_books(library)
    write_local_text_fixtures(library)
    copied = copy_overflow_fixtures(library)
    if copied:
        print(f"copied {copied} local overflow fixtures")
    stamp_library_for_recent_sort(library)
    if not args.no_settings:
        settings = args.settings.resolve()
        configure_settings(settings, args.runtime_library)
        configure_history(settings, args.runtime_library)
    print(f"sample library: {library}")
    print(f"files: {sum(1 for path in library.iterdir() if path.is_file())}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
