"""Shared by every verify_*_runtime.py: mirror the real mod into the benchmark sandbox.

One copy list, not eleven. Files deleted from the mod (replica.lua, the old
per-pattern planners) are dropped from the sandbox too, so a stale require()
can never keep a deleted planner alive in an engine test.
"""
from pathlib import Path
import shutil

SOURCE = Path(__file__).resolve().parent.parent / "factorio-ai-bridge_0.1.0"


def sync_mod(mod: Path, source: Path = SOURCE) -> None:
    mod.mkdir(parents=True, exist_ok=True)
    keep = {p.name for p in source.iterdir() if p.suffix in {".lua", ".json"}}
    for stale in mod.iterdir():
        # test_*_runtime.lua harnesses live only in the sandbox; never drop them.
        if stale.suffix in {".lua", ".json"} and stale.name not in keep \
                and not stale.name.startswith("test_"):
            stale.unlink()
    for name in keep:
        shutil.copy2(source / name, mod / name)
