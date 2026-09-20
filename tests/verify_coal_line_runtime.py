"""Export and measure a two-drill coal line in a copied Factorio save."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess

from runtime_mod import sync_mod

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SANDBOX = ROOT / ".runtime-test"
MOD = SANDBOX / "mods" / "factorio-ai-bridge_0.1.0"
EXE = Path(r"D:\Factorio-AnkerGames\Factorio\bin\x64\factorio.exe")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--player-save", type=Path, required=True)
    args = parser.parse_args()
    sync_mod(MOD)
    shutil.copy2(HERE / "test_coal_line_runtime.lua", MOD / "test_coal_line_runtime.lua")
    with (MOD / "control.lua").open("a", encoding="utf-8") as f:
        f.write('\nrequire("test_coal_line_runtime")(HANDLERS, bridge_state)\n')
    save = SANDBOX / "saves" / "coal-line-player.zip"
    shutil.copy2(args.player_save, save)
    result = SANDBOX / "script-output" / "coal-line-check.json"
    blueprint = SANDBOX / "script-output" / "coal-line-v1.blueprint.txt"
    result.unlink(missing_ok=True)
    blueprint.unlink(missing_ok=True)
    log = SANDBOX / "coal-line-benchmark.log"
    with log.open("w", encoding="utf-8") as output:
        run = subprocess.run([
            str(EXE), "--config", str(SANDBOX / "config.ini"),
            "--mod-directory", str(SANDBOX / "mods"),
            "--benchmark", str(save), "--benchmark-ticks", "2700",
            "--benchmark-runs", "1", "--benchmark-ignore-paused",
        ], stdout=output, stderr=subprocess.STDOUT, timeout=180)
    if not result.exists():
        print(log.read_text(encoding="utf-8")[-6000:])
        raise SystemExit(run.returncode or 1)
    data = json.loads(result.read_text(encoding="utf-8"))
    if not blueprint.exists():
        data["ok"], data["error"] = False, "missing-blueprint"
    print(json.dumps(data, indent=2))
    raise SystemExit(0 if data["ok"] and run.returncode == 0 else 1)


if __name__ == "__main__":
    main()
