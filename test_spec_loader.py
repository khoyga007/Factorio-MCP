import os
import unittest

from spec_loader import entity_fields, item_fields, load_spec, recipe_fields

SAMPLE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "spec_sample.json")


class SpecLoaderTest(unittest.TestCase):
    def test_loads_sample_numbers(self):
        spec = load_spec(SAMPLE)
        self.assertEqual(0.5, spec.entity("assembler1").crafting_speed)
        self.assertEqual(1.0, spec.entity("stone-furnace").crafting_speed)
        self.assertEqual(0.25, spec.entity("burner-mining-drill").mining_speed)
        self.assertEqual(1.0, spec.entity("burner-mining-drill").mining_time)
        self.assertEqual(0.03125, spec.entity("transport-belt").belt_speed)
        self.assertEqual(4_000_000.0, spec.item("coal").fuel_value_joules)
        self.assertEqual(3.2, spec.recipe("iron-plate").energy)
        self.assertEqual(5.0, spec.recipe("red-science").energy)

    def test_missing_optional_fields_are_none(self):
        spec = load_spec(SAMPLE)
        self.assertIsNone(spec.entity("assembler1").mining_speed)
        self.assertIsNone(spec.item("coal").fuel_category)
        self.assertEqual((), spec.recipe("iron-plate").ingredients)

    def test_rejects_schema_mismatch(self):
        import json
        import tempfile

        with tempfile.NamedTemporaryFile(
            "w", suffix=".json", delete=False, encoding="utf-8"
        ) as f:
            json.dump({"schema_version": 999}, f)
            path = f.name
        try:
            with self.assertRaises(ValueError):
                load_spec(path)
        finally:
            os.unlink(path)

    def test_reply_fields_drop_transport_metadata(self):
        reply = {
            "action": "spec",
            "kind": "entity",
            "name": "transport-belt",
            "ok": True,
            "nonce": "x",
            "v": 1,
            "entity_type": "transport-belt",
            "belt_speed": 0.03125,
        }
        self.assertEqual(
            {"entity_type": "transport-belt", "belt_speed": 0.03125},
            entity_fields(reply),
        )
        self.assertEqual({"fuel_value_joules": 4_000_000}, item_fields({"fuel_value_joules": 4_000_000}))
        self.assertEqual({"energy": 3.2}, recipe_fields({"energy": 3.2}))


if __name__ == "__main__":
    unittest.main()
