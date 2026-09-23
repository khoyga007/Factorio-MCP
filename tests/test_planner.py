import unittest
from pathlib import Path
import json
from unittest.mock import patch

from factorio_goal_mcp import observe
from planner import live_spec, plan
from spec_loader import load_spec


FIXTURE = Path(__file__).parent / "fixtures" / "rate_planner.json"


class PlannerTest(unittest.TestCase):
    def test_gear_circuit_fluid_and_raw_rates(self):
        result = plan(load_spec(FIXTURE), "coolant-cell", 60)
        rows = {row["recipe"]: row for row in result["rows"]}
        self.assertEqual((2, 2), (rows["coolant-cell"]["exact_count"],
                                  rows["coolant-cell"]["count"]))
        self.assertEqual(30, rows["coolant-cell"]["in"]["electronic-circuit"])
        self.assertEqual(300, rows["coolant-cell"]["in"]["water"])
        self.assertEqual(30, rows["coolant-cell"]["surplus"]["steam"])
        self.assertEqual({"steam": 30}, result["surplus"])
        self.assertEqual("assembler-1", rows["electronic-circuit"]["machine"])
        self.assertEqual(30, rows["iron-gear-wheel"]["out"]["iron-gear-wheel"])
        self.assertEqual(90, result["raw"]["iron-ore"]["per_min"])
        self.assertEqual(45, result["raw"]["copper-ore"]["per_min"])
        self.assertEqual((3, 3), (result["raw"]["iron-ore"]["exact_count"],
                                  result["raw"]["iron-ore"]["count"]))
        self.assertEqual(1, result["raw"]["water"]["count"])
        edge = next(edge for edge in result["belts"]
                    if edge["item"] == "iron-plate" and edge["to"] == "iron-gear-wheel")
        self.assertEqual({"transport-belt": 1, "fast-transport-belt": 1,
                          "express-transport-belt": 1}, edge["lanes"])
        self.assertGreater(result["power_kw"], 0)

    def test_machine_and_recipe_override(self):
        spec = load_spec(FIXTURE)
        result = plan(spec, "coolant-cell", 60,
                      machines={"crafting": "assembler-2"},
                      recipes={"coolant-cell": "coolant-cell"})
        rows = {row["recipe"]: row for row in result["rows"]}
        self.assertEqual("assembler-2", rows["electronic-circuit"]["machine"])
        self.assertAlmostEqual(1 / 3, rows["electronic-circuit"]["exact_count"])

    def test_water_stays_raw_even_if_a_recipe_produces_it(self):
        spec = load_spec(FIXTURE)
        from spec_loader import RecipeSpec, Spec
        spec = Spec(entities=spec.entities, items=spec.items,
                    recipes={**spec.recipes, "ice-melting": RecipeSpec(
                        category="crafting-with-fluid", energy=1,
                        ingredients=({"name": "ice", "amount": 1},),
                        products=({"name": "water", "amount": 10},),
                        machines=("assembler-1",))})
        result = plan(spec, "coolant-cell", 60)
        self.assertNotIn("ice-melting", [row["recipe"] for row in result["rows"]])
        self.assertEqual(300, result["raw"]["water"]["per_min"])

    def test_live_loader_caches_each_spec_request(self):
        source = load_spec(FIXTURE)
        calls = []

        def fetch(body):
            calls.append(tuple(sorted(body.items())))
            kind, name = body["kind"], body.get("name", body.get("entity"))
            if kind == "recipe" and body.get("entity"):
                name = body["entity"]
            table = source.recipes if kind == "recipe" else source.entities
            value = table.get(name)
            if value is None:
                return {"ok": False, "error": "recipe-not-found" if kind == "recipe" else "entity-not-found"}
            from dataclasses import asdict
            return {"ok": True, "name": name, **asdict(value)}

        spec = live_spec("coolant-cell", fetch=fetch)
        self.assertEqual(60, plan(spec, "coolant-cell", 60)["per_min"])
        self.assertEqual(len(calls), len(set(calls)))

    def test_observe_plan_parses_rate_and_recipe_choice(self):
        spec = load_spec(FIXTURE)
        with patch("factorio_goal_mcp.live_spec", return_value=spec) as loader:
            result = observe(view="plan", query="coolant-cell@60/min;recipe=coolant-cell:coolant-cell")
        self.assertFalse(result.isError)
        self.assertEqual(60, json.loads(result.content[0].text)["per_min"])
        loader.assert_called_once_with("coolant-cell", {"coolant-cell": "coolant-cell"})
        self.assertTrue(observe(view="plan", query="coolant-cell@60/s").isError)

    def test_live_recipe_choice_skips_recycling_and_uses_cheapest_fluid_input(self):
        def fetch(body):
            name = body.get("name")
            if body["kind"] == "entity":
                return {"ok": False, "error": "entity-not-found"}
            if name == "solid-fuel":
                return {"ok": False, "error": "recipe-not-found", "candidates": [
                    "rocket-fuel-recycling", "solid-fuel-from-heavy-oil",
                    "solid-fuel-from-light-oil"]}
            if name == "rocket-fuel-recycling":
                return {"ok": True, "name": name, "category": "recycling", "enabled": True,
                        "ingredients": [{"name": "rocket-fuel", "amount": 1}],
                        "products": [{"name": "solid-fuel", "amount": 1}]}
            if name in {"solid-fuel-from-heavy-oil", "solid-fuel-from-light-oil"}:
                return {"ok": True, "name": name, "category": "chemistry", "enabled": True,
                        "ingredients": [{"name": name.removeprefix("solid-fuel-from-"),
                                         "type": "fluid", "amount": 10 if "light" in name else 20}],
                        "products": [{"name": "solid-fuel", "amount": 1}]}
            return {"ok": False, "error": "recipe-not-found"}

        spec = live_spec("solid-fuel", fetch=fetch)
        self.assertEqual("solid-fuel-from-light-oil", spec.selected_recipes["solid-fuel"])


if __name__ == "__main__":
    unittest.main()
