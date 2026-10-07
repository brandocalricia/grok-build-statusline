#!/usr/bin/env python3
"""format_usd is integer ticks / 1e10."""

import pathlib
import runpy
import sys

SCRIPT = pathlib.Path(__file__).resolve().parent / "statusline.sh"


def main():
    ns = runpy.run_path(str(SCRIPT), run_name="statusline_under_test")
    got = ns["format_usd"](361999360)
    want = "$0.036199936"
    if got != want:
        print(f"FAIL format_usd(361999360) got {got!r} want {want!r}")
        return 1
    print("PASS format_usd(361999360) == $0.036199936")
    return 0


if __name__ == "__main__":
    sys.exit(main())
