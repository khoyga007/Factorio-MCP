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

from blueprint_library import (BUILD_ENTITY_LIMIT, encode_blueprint, import_reference,
                               list_patterns, load_pattern, pattern_entities,
                               pattern_id_for, read_book, record_blueprint, screen_reference)
from factorio_ai import execute


NATIVE = (Path(__file__).parent.parent / "blueprints" / "coal-line-v1.blueprint.txt").read_text().strip()


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

    def test_agent_design_round_trips_to_same_pattern(self):
        rows = pattern_entities(NATIVE)
        self.assertTrue(all(r["x"] >= 0 and r["y"] >= 0 for r in rows))
        rows.reverse()
        self.assertEqual(pattern_id_for(NATIVE), pattern_id_for(encode_blueprint(rows)))

    def test_bad_design_refused(self):
        for design in ([], [{"name": "boiler", "x": 0.25, "y": 0}],
                       [{"name": "boiler", "x": 0, "y": 0, "direction": 16}],
                       [{"name": "", "x": 0, "y": 0}], [{"x": 0, "y": 0}],
                       [{"name": "assembling-machine-1", "x": 0.5, "y": 0.5, "recipe": 3}]):
            with self.assertRaises(ValueError):
                encode_blueprint(design)

    def test_design_saved_with_contract(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(
            os.environ, {"FACTORIO_BLUEPRINT_CATALOG": directory}
        ):
            value = encode_blueprint([{"name": "stone-furnace", "x": 1, "y": 1},
                                      {"name": "burner-inserter", "x": 2.5, "y": 0.5, "direction": 4}])
            saved = record_blueprint(value, state="designed", source="t", contract={"site": {}})
            self.assertEqual("designed", saved["state"])
            self.assertEqual({"site": {}}, load_pattern(saved["pattern_id"])["contract"])
            self.assertEqual("built", record_blueprint(value, state="built", source="t")["state"])
            self.assertEqual({"site": {}}, load_pattern(saved["pattern_id"])["contract"])

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
            self.assertEqual(1, len(list_patterns()["patterns"]))
            row = load_pattern(first["pattern_id"])
            self.assertEqual("verified", row["state"])
            self.assertEqual(10, row["entity_count"])
            self.assertEqual(2, row["entities"]["burner-mining-drill"])
            self.assertEqual(6, row["entities"]["transport-belt"])
            self.assertEqual(17, row["audit"]["coal_gained"])
            self.assertNotIn("surface", row)
            self.assertNotIn("world_x", row)
            self.assertNotIn("blueprint_string", list_patterns()["patterns"][0])
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
                                      file=Path(__file__).parent.parent / "blueprints" / "coal-line-v1.blueprint.txt",
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
            "ok": True, "state": "verified", "artifact": "executor/exec-1",
            "audit": {"status": "passed", "coal_gained": 8},
        }):
            artifact = Path(directory) / "executor" / "exec-1.blueprint.txt"
            artifact.parent.mkdir()
            artifact.write_text(NATIVE + "\n", encoding="ascii")
            args = argparse.Namespace(command="blueprint-job", job_id="exec-1",
                                      host="127.0.0.1", port=34198)
            reply = execute(args)
            self.assertEqual("verified", reply["pattern"]["state"])
            self.assertEqual(8, load_pattern(reply["pattern"]["pattern_id"])["audit"]["coal_gained"])

    def test_fed_layout_is_built_not_verified(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(
            os.environ, {"FACTORIO_BLUEPRINT_CATALOG": str(Path(directory) / "catalog"),
                         "FACTORIO_SCRIPT_OUTPUT": directory}
        ), patch("factorio_ai.request", return_value={
            "ok": True, "state": "verified", "artifact": "executor/exec-2",
            "audit": {"status": "passed", "windows": [{"feed_moved": 0}, {"feed_moved": 4}]},
        }):
            artifact = Path(directory) / "executor" / "exec-2.blueprint.txt"
            artifact.parent.mkdir()
            artifact.write_text(NATIVE + "\n", encoding="ascii")
            reply = execute(argparse.Namespace(command="blueprint-job", job_id="exec-2",
                                               host="127.0.0.1", port=34198))
            self.assertEqual("built", reply["pattern"]["state"])



class ReferenceImportTest(unittest.TestCase):
    """Community material is stored to be read, and ranks below anything the agent made."""

    def _string(self, count=3, version=562949956239363, name="stone-furnace"):
        entities = [{"entity_number": i + 1, "name": name,
                     "position": {"x": float(i), "y": 0.0}} for i in range(count)]
        raw = json.dumps({"blueprint": {"item": "blueprint", "version": version,
                                        "label": "community row", "entities": entities}})
        return "0" + base64.b64encode(zlib.compress(raw.encode())).decode()

    def test_import_stores_origin_and_never_a_contract(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(
            os.environ, {"FACTORIO_BLUEPRINT_CATALOG": directory}
        ):
            record = import_reference(self._string(), url="https://example.invalid/bp",
                                      note="early smelting")
            self.assertEqual("reference", record["state"])
            saved = load_pattern(record["pattern_id"])
            self.assertIsNone(saved["contract"])
            self.assertEqual("community", saved["origin"]["kind"])
            self.assertEqual("2.0.43.3", saved["origin"]["game_version"])
            # Reference material stays out of the agent's own pattern list.
            self.assertEqual([], list_patterns()["patterns"])
            listed = list_patterns(reference=True)
            self.assertEqual(1, listed["total"])
            self.assertEqual("community row", listed["patterns"][0]["label"])
            self.assertIsNone(listed["next_offset"])
            self.assertEqual([], list_patterns(reference=True, query="nothing")["patterns"])

    def test_agent_work_outranks_reference_and_reference_never_demotes(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(
            os.environ, {"FACTORIO_BLUEPRINT_CATALOG": directory}
        ):
            value = self._string()
            reference = import_reference(value)
            self.assertEqual("verified", record_blueprint(
                value, state="verified", source="audit")["state"])
            self.assertEqual("verified", import_reference(value)["state"])
            self.assertEqual("verified", load_pattern(reference["pattern_id"])["state"])

    def test_refuses_pre_2_0_and_space_age(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(
            os.environ, {"FACTORIO_BLUEPRINT_CATALOG": directory}
        ):
            with self.assertRaises(ValueError) as old:
                import_reference(self._string(version=281479273775104))
            self.assertIn("not-a-2.0-blueprint", str(old.exception))
            with self.assertRaises(ValueError) as dlc:
                import_reference(self._string(name="foundry"))
            self.assertIn("space-age-entities:foundry", str(dlc.exception))
            with self.assertRaises(ValueError) as gone:
                import_reference(self._string(), unknown=["stone-furnace"])
            self.assertIn("entities-not-in-this-game", str(gone.exception))
            self.assertEqual([], list_patterns()["patterns"])

    def test_reference_may_exceed_the_build_limit(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(
            os.environ, {"FACTORIO_BLUEPRINT_CATALOG": directory}
        ):
            big = self._string(count=BUILD_ENTITY_LIMIT + 33)
            self.assertTrue(screen_reference(big)["over_build_limit"])
            record = import_reference(big)
            self.assertEqual(BUILD_ENTITY_LIMIT + 33, record["entity_count"])
            self.assertEqual(BUILD_ENTITY_LIMIT + 33,
                             len(load_pattern(record["pattern_id"])["entities"]) and
                             load_pattern(record["pattern_id"])["entity_count"])
            with self.assertRaises(ValueError):
                record_blueprint(big, state="designed", source="t")


    def test_book_flattens_to_leaves_that_remember_where_they_sat(self):
        leaf = {"item": "blueprint", "version": 562949956239363, "label": "row",
                "entities": [{"entity_number": 1, "name": "stone-furnace",
                              "position": {"x": 0.0, "y": 0.0}}]}
        book = {"blueprint_book": {"item": "blueprint-book", "label": "top", "blueprints": [
            {"blueprint": leaf},
            {"blueprint_book": {"item": "blueprint-book", "label": "inner",
                                "blueprints": [{"blueprint": dict(leaf, label="deep")}]}}]}}
        value = "0" + base64.b64encode(zlib.compress(json.dumps(book).encode())).decode()
        leaves = read_book(value)
        self.assertEqual([[], ["inner"]], [path for path, _ in leaves])
        with tempfile.TemporaryDirectory() as directory, patch.dict(
            os.environ, {"FACTORIO_BLUEPRINT_CATALOG": directory}
        ):
            for path, string in leaves:
                import_reference(string, path=path)
            listed = list_patterns(reference=True, query="inner")
            self.assertEqual(1, listed["total"])
            self.assertEqual("inner", listed["patterns"][0]["book"])
            self.assertEqual("deep", listed["patterns"][0]["label"])

    def test_a_plain_blueprint_is_not_a_book(self):
        with self.assertRaises(ValueError) as exc:
            read_book(encode_blueprint([{"name": "stone-furnace", "x": 1, "y": 1}]))
        self.assertIn("not-a-blueprint-book", str(exc.exception))


if __name__ == "__main__":
    unittest.main()
