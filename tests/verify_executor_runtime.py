"""Engine test of the generic blueprint executor (coal pattern + catalog contract) in a save copy."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SANDBOX = ROOT / ".runtime-test"
MOD = SANDBOX / "mods" / "factorio-ai-bridge_0.1.0"
EXE = Path(r"D:\Factorio-AnkerGames\Factorio\bin\x64\factorio.exe")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--player-save", type=Path, required=True)
    args = parser.parse_args()
    MOD.mkdir(parents=True, exist_ok=True)
    (MOD / "replica.lua").unlink(missing_ok=True)
    for name in ("control.lua", "smelting.lua", "starter.lua", "coal.lua", "executor.lua", "info.json"):
        shutil.copy2(ROOT / "factorio-ai-bridge_0.1.0" / name, MOD / name)
    shutil.copy2(HERE / "test_executor_runtime.lua", MOD / "test_executor_runtime.lua")
    pattern = json.loads((ROOT / "blueprints/catalog/bp-f30d8a84af3098ee.json").read_text(encoding="utf-8"))
    with (MOD / "control.lua").open("a", encoding="utf-8") as f:
        f.write('\nrequire("test_executor_runtime")(HANDLERS, bridge_state, '
                + json.dumps(pattern["blueprint_string"]) + ", "
                + json.dumps(json.dumps(pattern["contract"])) + ")\n")
    save = SANDBOX / "saves" / "executor-player.zip"
    shutil.copy2(args.player_save, save)
    result = SANDBOX / "script-output" / "executor-check.json"
    result.unlink(missing_ok=True)
    log = SANDBOX / "executor-benchmark.log"
    with log.open("w", encoding="utf-8") as output:
        run = subprocess.run([
            str(EXE), "--config", str(SANDBOX / "config.ini"),
            "--mod-directory", str(SANDBOX / "mods"),
            "--benchmark", str(save), "--benchmark-ticks", "42000",
            "--benchmark-runs", "1", "--benchmark-ignore-paused",
        ], stdout=output, stderr=subprocess.STDOUT, timeout=600)
    if not result.exists():
        print(log.read_text(encoding="utf-8")[-6000:])
        raise SystemExit(run.returncode or 1)
    data = json.loads(result.read_text(encoding="utf-8"))
    print(json.dumps({"ok": data["ok"], "checks": data["checks"],
                      "error": data.get("error"), "status": data.get("status")}, indent=2))
    raise SystemExit(0 if data["ok"] and run.returncode == 0 else 1)


if __name__ == "__main__":
    main()
