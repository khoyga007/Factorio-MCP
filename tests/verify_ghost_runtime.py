"""Engine test: ghost lifetime, partial paste, free revive, recipe across revive."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SANDBOX = ROOT / ".runtime-test"
sys.path.insert(0, str(ROOT))
from blueprint_library import encode_blueprint  # noqa: E402

from runtime_mod import FACTORIO_EXE, sync_mod
MOD = SANDBOX / "mods" / "factorio-ai-bridge_0.1.0"
EXE = FACTORIO_EXE
# One of the three lands on a tile the test occupies first, so the run measures what the
# engine does with a layout that only partly fits.
TRIO = [{"name": "assembling-machine-1", "x": 0.5, "y": 0.5, "recipe": "iron-gear-wheel"},
        {"name": "small-electric-pole", "x": -2.5, "y": 0.5},
        {"name": "wooden-chest", "x": 3.5, "y": 0.5}]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--player-save", type=Path, required=True)
    args = parser.parse_args()
    sync_mod(MOD)
    shutil.copy2(HERE / "test_ghost_runtime.lua", MOD / "test_ghost_runtime.lua")
    with (MOD / "control.lua").open("a", encoding="utf-8") as f:
        f.write('\nrequire("test_ghost_runtime")(HANDLERS, bridge_state, {trio='
                + json.dumps(encode_blueprint(TRIO)) + "})\n")
    save = SANDBOX / "saves" / "ghost-player.zip"
    shutil.copy2(args.player_save, save)
    result = SANDBOX / "script-output" / "ghost-check.json"
    result.unlink(missing_ok=True)
    log = SANDBOX / "ghost-benchmark.log"
    with log.open("w", encoding="utf-8") as output:
        run = subprocess.run([
            str(EXE), "--config", str(SANDBOX / "config.ini"),
            "--mod-directory", str(SANDBOX / "mods"),
            "--benchmark", str(save), "--benchmark-ticks", "3000",
            "--benchmark-runs", "1", "--benchmark-ignore-paused",
        ], stdout=output, stderr=subprocess.STDOUT, timeout=600)
    if not result.exists():
        print(log.read_text(encoding="utf-8")[-6000:])
        raise SystemExit(run.returncode or 1)
    data = json.loads(result.read_text(encoding="utf-8"))
    print(json.dumps(data, indent=2))
    raise SystemExit(0 if data["ok"] and run.returncode == 0 else 1)


if __name__ == "__main__":
    main()
