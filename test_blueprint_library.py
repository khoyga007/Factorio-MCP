"""A native blueprint becomes one reusable JSON pattern after a successful build."""
import argparse
import base64
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zlib

from blueprint_library import list_patterns, load_pattern, record_blueprint, pattern_id_for
from factorio_ai import execute


NATIVE = (Path(__file__).parent / "blueprints" / "coal-line-v1.blueprint.txt").read_text().strip()


class BlueprintLibraryTest(unittest.TestCase):
    def test_same_layout_at_different_coordinates_has_one_id(self):
        data = json.loads(zlib.decompress(base64.b64decode(NATIVE[1:])))
        entities = data["blueprint"]["entities"]
        entities.reverse()
        for entity in entities:
            entity["position"]["x"] += 42
            entity["position"]["y"] -= 7
        shifted = "0" + base64.b64encode(zlib.compress(json.dumps(data).encode())).decode()
        self.assertEqual(pattern_id_for(NATIVE), pattern_id_for(shifted))

    def test_top_level_wiring_is_not_discarded(self):
        data = json.loads(zlib.decompress(base64.b64decode(NATIVE[1:])))
        data["blueprint"]["wires"] = [[1, 1, 2, 1]]
        wired = "0" + base64.b64encode(zlib.compress(json.dumps(data).encode())).decode()
        self.assertNotEqual(pattern_id_for(NATIVE), pattern_id_for(wired))

    def test_deduplicate_and_upgrade_after_verification(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(
            os.environ, {"FACTORIO_BLUEPRINT_CATALOG": directory}
        ):
            first = record_blueprint(NATIVE, state="captured", source="export")
            built = record_blueprint(NATIVE, state="built", source="import",
                                     materials={"burner-mining-drill": 2,
                                                "transport-belt": 6})
            verified = record_blueprint(NATIVE, state="verified", source="audit",
                                        audit={"status": "passed", "coal_gained": 17})
            self.assertEqual(first["pattern_id"], built["pattern_id"])
            self.assertEqual(first["pattern_id"], verified["pattern_id"])
            self.assertEqual(1, len(list_patterns()))
            row = load_pattern(first["pattern_id"])
            self.assertEqual("verified", row["state"])
            self.assertEqual(10, row["entity_count"])
            self.assertEqual(2, row["entities"]["burner-mining-drill"])
            self.assertEqual(6, row["entities"]["transport-belt"])
            self.assertEqual(17, row["audit"]["coal_gained"])
            self.assertNotIn("surface", row)
            self.assertNotIn("world_x", row)
            self.assertNotIn("blueprint_string", list_patterns()[0])
            self.assertEqual(1, len(list(Path(directory).glob("*.json"))))

    def test_successful_direct_import_autosaves_json(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(
            os.environ, {"FACTORIO_BLUEPRINT_CATALOG": directory}
        ), patch("factorio_ai.request", return_value={
            "ok": True, "action": "blueprint_import", "placed": 10,
            "spent": {"burner-mining-drill": 2, "transport-belt": 6,
                      "burner-inserter": 1, "wooden-chest": 1},
        }):
            args = argparse.Namespace(command="blueprint-import",
                                      file=Path(__file__).parent / "blueprints" / "coal-line-v1.blueprint.txt",
                                      x=10, y=20, surface="nauvis", force="player",
                                      ghosts=False, host="127.0.0.1", port=34198)
            reply = execute(args)
            self.assertTrue(reply["ok"])
            self.assertTrue(reply["pattern"]["pattern_id"].startswith("bp-"))
            saved = load_pattern(reply["pattern"]["pattern_id"])
            self.assertEqual("built", saved["state"])
            self.assertEqual(2, saved["required_items"]["burner-mining-drill"])
            self.assertNotIn("x", saved)
            self.assertNotIn("y", saved)

    def test_rejects_invalid_pattern_id(self):
        with self.assertRaises(ValueError):
            load_pattern("../save.zip")

    def test_verified_goal_status_autosaves_pattern(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(
            os.environ, {"FACTORIO_BLUEPRINT_CATALOG": str(Path(directory) / "catalog"),
                         "FACTORIO_SCRIPT_OUTPUT": directory}
        ), patch("factorio_ai.request", return_value={
            "ok": True, "state": "verified", "artifact": "coal/coal-1",
            "audit": {"status": "passed", "coal_gained": 8},
        }):
            artifact = Path(directory) / "coal" / "coal-1.blueprint.txt"
            artifact.parent.mkdir()
            artifact.write_text(NATIVE + "\n", encoding="ascii")
            args = argparse.Namespace(command="coal-status", job_id="coal-1",
                                      host="127.0.0.1", port=34198)
            reply = execute(args)
            self.assertEqual("verified", reply["pattern"]["state"])
            self.assertEqual(8, load_pattern(reply["pattern"]["pattern_id"])["audit"]["coal_gained"])


if __name__ == "__main__":
    unittest.main()
