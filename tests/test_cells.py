import runpy
from pathlib import Path


def test_cells_self_check():
    runpy.run_path(str(Path(__file__).resolve().parent.parent / "cells.py"), run_name="__main__")
