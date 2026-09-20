"""Engine test: underground pipe pairing refused before the build (polarity + range)."""
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
UG = "pipe-to-ground"
# dir 12 = west-facing opening, so its tunnel runs east; dir 4 is its mirror.
GOOD = [{"name": UG, "x": 0.5, "y": 0.5, "direction": 12},
        {"name": UG, "x": 8.5, "y": 0.5, "direction": 4}]
FAR = [{"name": UG, "x": 0.5, "y": 0.5, "direction": 12},
       {"name": UG, "x": 12.5, "y": 0.5, "direction": 4}]
FLIP = [{"name": UG, "x": 0.5, "y": 0.5, "direction": 12},
        {"name": UG, "x": 8.5, "y": 0.5, "direction": 12}]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--player-save", type=Path, required=True)
    args = parser.parse_args()
    sync_mod(MOD)
    shutil.copy2(HERE / "test_pipe_runtime.lua", MOD / "test_pipe_runtime.lua")
    with (MOD / "control.lua").open("a", encoding="utf-8") as f:
        # A Lua table literal: JSON object syntax is not Lua.
        f.write('\nrequire("test_pipe_runtime")(HANDLERS, bridge_state, {good='
                + json.dumps(encode_blueprint(GOOD)) + ", far="
                + json.dumps(encode_blueprint(FAR)) + ", flip="
                + json.dumps(encode_blueprint(FLIP)) + "})\n")
    save = SANDBOX / "saves" / "pipe-player.zip"
    shutil.copy2(args.player_save, save)
    result = SANDBOX / "script-output" / "pipe-check.json"
    result.unlink(missing_ok=True)
    log = SANDBOX / "pipe-benchmark.log"
    with log.open("w", encoding="utf-8") as output:
        run = subprocess.run([
            str(EXE), "--config", str(SANDBOX / "config.ini"),
            "--mod-directory", str(SANDBOX / "mods"),
            "--benchmark", str(save), "--benchmark-ticks", "12000",
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
