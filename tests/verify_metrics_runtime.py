"""Engine test: products_finished + research_units metrics and research queue in a save copy."""
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--player-save", type=Path, required=True)
    parser.add_argument("--design", type=Path, default=HERE / "designs" / "furnace-lab-metrics.json")
    args = parser.parse_args()
    sync_mod(MOD)
    shutil.copy2(HERE / "test_metrics_runtime.lua", MOD / "test_metrics_runtime.lua")
    spec = json.loads(args.design.read_text(encoding="utf-8"))
    parts = [json.dumps(encode_blueprint(spec[k]["design"])) + ", " + json.dumps(json.dumps(spec[k]["contract"]))
             for k in ("furnace", "lab")]
    with (MOD / "control.lua").open("a", encoding="utf-8") as f:
        f.write('\nrequire("test_metrics_runtime")(HANDLERS, bridge_state, ' + ", ".join(parts) + ")\n")
    save = SANDBOX / "saves" / "metrics-player.zip"
    shutil.copy2(args.player_save, save)
    result = SANDBOX / "script-output" / "metrics-check.json"
    result.unlink(missing_ok=True)
    log = SANDBOX / "metrics-benchmark.log"
    with log.open("w", encoding="utf-8") as output:
        run = subprocess.run([
            str(EXE), "--config", str(SANDBOX / "config.ini"),
            "--mod-directory", str(SANDBOX / "mods"),
            "--benchmark", str(save), "--benchmark-ticks", "32000",
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
