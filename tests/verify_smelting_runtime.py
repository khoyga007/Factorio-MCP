"""Exercise production Lua and Factorio physics in a separate benchmark save.

Only .runtime-test is changed. The user's running game and installed mod are untouched.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SANDBOX = ROOT / ".runtime-test"
MOD = "factorio-ai-bridge_0.1.0"
EXE = Path(r"D:\Factorio-AnkerGames\Factorio\bin\x64\factorio.exe")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--player-save", type=Path, help="copy this save into the sandbox to also test player item transfers")
    args = parser.parse_args()
    save = SANDBOX / "saves" / "smoke.zip"
    if args.player_save:
        save = SANDBOX / "saves" / "bridge-player.zip"
        if args.player_save.resolve() != save.resolve():
            shutil.copy2(args.player_save, save)
    dest = SANDBOX / "mods" / MOD
    dest.mkdir(parents=True, exist_ok=True)
    for name in ("control.lua", "smelting.lua", "starter.lua", "coal.lua", "replica.lua", "info.json"):
        shutil.copy2(ROOT / MOD / name, dest / name)
    shutil.copy2(HERE / "test_smelting_runtime.lua", dest / "test_smelting_runtime.lua")
    shutil.copy2(HERE / "test_bridge_runtime.lua", dest / "test_bridge_runtime.lua")
    with (dest / "control.lua").open("a", encoding="utf-8") as f:
        bridge = ', require("test_bridge_runtime")' if args.player_save else ''
        f.write('\nrequire("test_smelting_runtime")(HANDLERS, bridge_state' + bridge + ')\n')
    result = SANDBOX / "script-output" / "smelting-check.json"
    result.unlink(missing_ok=True)
    bridge_result = SANDBOX / "script-output" / "bridge-check.json"
    bridge_result.unlink(missing_ok=True)
    log = SANDBOX / "smelting-benchmark.log"
    with log.open("w", encoding="utf-8") as output:
        run = subprocess.run([
            str(EXE), "--config", str(SANDBOX / "config.ini"),
            "--mod-directory", str(SANDBOX / "mods"),
            "--benchmark", str(save),
            "--benchmark-ticks", "5700", "--benchmark-runs", "1", "--benchmark-ignore-paused",
        ], stdout=output, stderr=subprocess.STDOUT, timeout=180)
    if not result.exists():
        print(log.read_text(encoding="utf-8")[-6000:])
        raise SystemExit(run.returncode or 1)
    data = json.loads(result.read_text(encoding="utf-8"))
    bridge_data = json.loads(bridge_result.read_text(encoding="utf-8")) if bridge_result.exists() else {}
    print(json.dumps({"ok": data["ok"], "error": data.get("error"),
                      "bridge_checks": len(bridge_data.get("checks", [])),
                      "checks": len(data["checks"]), "artifact": str(result),
                      "rows": [{"furnaces": r["furnaces"], "entities": r["entities"],
                                "origin": r["origin"], "calls": r.get("workflow_calls"),
                                "reply_bytes": sum(r["workflow_reply_bytes"]),
                                "individual_receipt_bytes": r["individual_place_receipt_bytes"],
                                "audit": r.get("result", {}).get("audit")}
                               for r in data.get("rows", [])]}, indent=2))
    raise SystemExit(0 if data["ok"] and run.returncode == 0 else 1)


if __name__ == "__main__":
    main()
