"""Engine test: ghost-mode executor waits on the ground instead of refusing the build."""
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

from runtime_mod import sync_mod
MOD = SANDBOX / "mods" / "factorio-ai-bridge_0.1.0"
EXE = Path(r"D:\Factorio-AnkerGames\Factorio\bin\x64\factorio.exe")
# Top-left of the bounding box is (0,0), so an exact site at x=0,y=0 lands these tiles.
PLAN = [{"name": "wooden-chest", "x": 0.5, "y": 0.5},
        {"name": "wooden-chest", "x": 1.5, "y": 0.5},
        {"name": "small-electric-pole", "x": 2.5, "y": 0.5},
        {"name": "assembling-machine-1", "x": 4.5, "y": 1.5, "recipe": "iron-gear-wheel"}]
# Past the 64 entities the executor used to cap at.
WIDE = [{"name": "transport-belt", "x": 0.5 + i, "y": 0.5} for i in range(70)]
# Past the 500 the executor used to cap at: maintainer's starter base is 508 entities.
POLE = [{"name": "small-electric-pole", "x": 0.5, "y": 0.5}]
HUGE = [{"name": "transport-belt", "x": 0.5 + (i % 26), "y": 0.5 + (i // 26)} for i in range(520)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--player-save", type=Path, required=True)
    args = parser.parse_args()
    sync_mod(MOD)
    shutil.copy2(HERE / "test_ghostbuild_runtime.lua", MOD / "test_ghostbuild_runtime.lua")
    with (MOD / "control.lua").open("a", encoding="utf-8") as f:
        f.write('\nrequire("test_ghostbuild_runtime")(HANDLERS, bridge_state, {plan='
                + json.dumps(encode_blueprint(PLAN)) + ", wide="
                + json.dumps(encode_blueprint(WIDE)) + ", huge="
                + json.dumps(encode_blueprint(HUGE)) + ", pole="
                + json.dumps(encode_blueprint(POLE)) + "})\n")
    save = SANDBOX / "saves" / "ghostbuild-player.zip"
    shutil.copy2(args.player_save, save)
    result = SANDBOX / "script-output" / "ghostbuild-check.json"
    result.unlink(missing_ok=True)
    log = SANDBOX / "ghostbuild-benchmark.log"
    with log.open("w", encoding="utf-8") as output:
        run = subprocess.run([
            str(EXE), "--config", str(SANDBOX / "config.ini"),
            "--mod-directory", str(SANDBOX / "mods"),
            "--benchmark", str(save), "--benchmark-ticks", "9000",
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
