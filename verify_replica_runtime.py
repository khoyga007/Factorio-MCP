"""Measure autonomous procurement, crafting, placement and audit in a save copy."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent
SANDBOX = ROOT / ".runtime-test"
MOD = SANDBOX / "mods" / "factorio-ai-bridge_0.1.0"
EXE = Path(r"D:\Factorio-AnkerGames\Factorio\bin\x64\factorio.exe")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--player-save", type=Path, required=True)
    args = parser.parse_args()
    MOD.mkdir(parents=True, exist_ok=True)
    for name in ("control.lua", "smelting.lua", "starter.lua", "coal.lua", "replica.lua", "info.json"):
        shutil.copy2(ROOT / "factorio-ai-bridge_0.1.0" / name, MOD / name)
    shutil.copy2(ROOT / "test_replica_runtime.lua", MOD / "test_replica_runtime.lua")
    with (MOD / "control.lua").open("a", encoding="utf-8") as f:
        f.write('\nrequire("test_replica_runtime")(HANDLERS, bridge_state, ' + json.dumps((ROOT / 'blueprints/coal-line-v1.blueprint.txt').read_text().strip()) + ')\n')
    save = SANDBOX / "saves" / "replica-player.zip"
    shutil.copy2(args.player_save, save)
    result = SANDBOX / "script-output" / "replica-check.json"
    result.unlink(missing_ok=True)
    log = SANDBOX / "replica-benchmark.log"
    with log.open("w", encoding="utf-8") as output:
        run = subprocess.run([
            str(EXE), "--config", str(SANDBOX / "config.ini"),
            "--mod-directory", str(SANDBOX / "mods"),
            "--benchmark", str(save), "--benchmark-ticks", "4500",
            "--benchmark-runs", "1", "--benchmark-ignore-paused",
        ], stdout=output, stderr=subprocess.STDOUT, timeout=180)
    if not result.exists():
        print(log.read_text(encoding="utf-8")[-6000:])
        raise SystemExit(run.returncode or 1)
    data = json.loads(result.read_text(encoding="utf-8"))
    print(json.dumps({"ok":data["ok"],"checks":len(data["checks"]),
                      "error":data.get("error"),"status":data.get("status")}, indent=2))
    raise SystemExit(0 if data["ok"] and run.returncode == 0 else 1)


if __name__ == "__main__":
    main()
