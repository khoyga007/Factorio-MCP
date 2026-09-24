"""Engine test: insert into a rocket-silo (input slots + rocket cargo) in a save copy."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys

from runtime_mod import FACTORIO_EXE, sync_mod

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SANDBOX = ROOT / ".runtime-test"
sys.path.insert(0, str(ROOT))
MOD = SANDBOX / "mods" / "factorio-ai-bridge_0.1.0"
EXE = FACTORIO_EXE


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--player-save", type=Path, required=True)
    args = parser.parse_args()
    sync_mod(MOD)
    shutil.copy2(HERE / "test_silo_runtime.lua", MOD / "test_silo_runtime.lua")
    with (MOD / "control.lua").open("a", encoding="utf-8") as f:
        f.write('\nrequire("test_silo_runtime")(HANDLERS, bridge_state)\n')
    save = SANDBOX / "saves" / "silo-player.zip"
    shutil.copy2(args.player_save, save)
    result = SANDBOX / "script-output" / "silo-check.json"
    result.unlink(missing_ok=True)
    log = SANDBOX / "silo-benchmark.log"
    with log.open("w", encoding="utf-8") as output:
        run = subprocess.run([
            str(EXE), "--config", str(SANDBOX / "config.ini"),
            "--mod-directory", str(SANDBOX / "mods"),
            "--benchmark", str(save), "--benchmark-ticks", "120",
            "--benchmark-runs", "1", "--benchmark-ignore-paused",
        ], stdout=output, stderr=subprocess.STDOUT, timeout=600)
    if not result.exists():
        print(log.read_text(encoding="utf-8")[-6000:])
        raise SystemExit(run.returncode or 1)
    data = json.loads(result.read_text(encoding="utf-8"))
    print(json.dumps({"ok": data["ok"], "checks": [c[:120] for c in data["checks"]],
                      "error": data.get("error")}, indent=2))
    raise SystemExit(0 if data["ok"] and run.returncode == 0 else 1)


if __name__ == "__main__":
    main()
