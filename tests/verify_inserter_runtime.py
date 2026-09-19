"""Engine test: executor clears trees/rocks on build tiles, refuses cliffs, in a save copy."""
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
MOD = SANDBOX / "mods" / "factorio-ai-bridge_0.1.0"
EXE = Path(r"D:\Factorio-AnkerGames\Factorio\bin\x64\factorio.exe")
CHEST = {"name": "wooden-chest", "x": 0.5, "y": 1.5}
PASS = {"name": "inserter", "x": 1.5, "y": 1.5, "direction": 12}  # picks west, drops east
BUGGY = [CHEST, PASS, {"name": "lab", "x": 4.5, "y": 1.5}]         # lab one tile too far east
FIXED = [CHEST, PASS, {"name": "lab", "x": 3.5, "y": 1.5}]
FEEDER = [{"name": "inserter", "x": 0.5, "y": 0.5, "direction": 0},  # picks north, drops south
          {"name": "wooden-chest", "x": 0.5, "y": 1.5}]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--player-save", type=Path, required=True)
    args = parser.parse_args()
    MOD.mkdir(parents=True, exist_ok=True)
    (MOD / "replica.lua").unlink(missing_ok=True)
    for name in ("control.lua", "smelting.lua", "starter.lua", "coal.lua", "executor.lua", "field.lua", "info.json"):
        shutil.copy2(ROOT / "factorio-ai-bridge_0.1.0" / name, MOD / name)
    shutil.copy2(HERE / "test_inserter_runtime.lua", MOD / "test_inserter_runtime.lua")
    with (MOD / "control.lua").open("a", encoding="utf-8") as f:
        f.write('\nrequire("test_inserter_runtime")(HANDLERS, bridge_state, '
                + ", ".join(json.dumps(encode_blueprint(d)) for d in (BUGGY, FIXED, FEEDER)) + ")\n")
    save = SANDBOX / "saves" / "inserter-player.zip"
    shutil.copy2(args.player_save, save)
    result = SANDBOX / "script-output" / "inserter-check.json"
    result.unlink(missing_ok=True)
    log = SANDBOX / "inserter-benchmark.log"
    with log.open("w", encoding="utf-8") as output:
        run = subprocess.run([
            str(EXE), "--config", str(SANDBOX / "config.ini"),
            "--mod-directory", str(SANDBOX / "mods"),
            "--benchmark", str(save), "--benchmark-ticks", "3600",
            "--benchmark-runs", "1", "--benchmark-ignore-paused",
        ], stdout=output, stderr=subprocess.STDOUT, timeout=600)
    if not result.exists():
        print(log.read_text(encoding="utf-8")[-6000:])
        raise SystemExit(run.returncode or 1)
    data = json.loads(result.read_text(encoding="utf-8"))
    print(json.dumps({"ok": data["ok"], "checks": [c[:400] for c in data["checks"]],
                      "error": data.get("error")}, indent=2))
    raise SystemExit(0 if data["ok"] and run.returncode == 0 else 1)


if __name__ == "__main__":
    main()
