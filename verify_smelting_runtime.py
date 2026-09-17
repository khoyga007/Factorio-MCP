"""Exercise production Lua and Factorio physics in a separate benchmark save.

Only .runtime-test is changed. The user's running game and installed mod are untouched.
"""
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent
SANDBOX = ROOT / ".runtime-test"
MOD = "factorio-ai-bridge_0.1.0"
EXE = Path(r"D:\Factorio-AnkerGames\Factorio\bin\x64\factorio.exe")


def main():
    dest = SANDBOX / "mods" / MOD
    dest.mkdir(parents=True, exist_ok=True)
    for name in ("control.lua", "smelting.lua", "info.json"):
        shutil.copy2(ROOT / MOD / name, dest / name)
    shutil.copy2(ROOT / "test_smelting_runtime.lua", dest / "test_smelting_runtime.lua")
    with (dest / "control.lua").open("a", encoding="utf-8") as f:
        f.write('\nrequire("test_smelting_runtime")(HANDLERS, bridge_state)\n')
    result = SANDBOX / "script-output" / "smelting-check.json"
    result.unlink(missing_ok=True)
    log = SANDBOX / "smelting-benchmark.log"
    with log.open("w", encoding="utf-8") as output:
        run = subprocess.run([
            str(EXE), "--config", str(SANDBOX / "config.ini"),
            "--mod-directory", str(SANDBOX / "mods"),
            "--benchmark", str(SANDBOX / "saves" / "smoke.zip"),
            "--benchmark-ticks", "5700", "--benchmark-runs", "1", "--benchmark-ignore-paused",
        ], stdout=output, stderr=subprocess.STDOUT, timeout=180)
    if not result.exists():
        print(log.read_text(encoding="utf-8")[-6000:])
        raise SystemExit(run.returncode or 1)
    data = json.loads(result.read_text(encoding="utf-8"))
    print(json.dumps({"ok": data["ok"], "error": data.get("error"),
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
