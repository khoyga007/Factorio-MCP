import json
from pathlib import Path
import unittest

from perception import ground, natural, summarize

FIXTURE = Path(__file__).parent / "fixtures" / "nearby_r32_live.json"
# Hard caps on what the agent reads. Raise only with a measured reason in the commit message.
LIVE_R32_MAX_CHARS = 6000   # 19/09 baseline 4683 chars for 295 entities (raw dump was 103191)
ARRAY_MAX_CHARS = 400       # a row of identical machines must not grow with its length


def size(value) -> int:
    return len(json.dumps(value, ensure_ascii=False, separators=(",", ":")))


def pipe(x, y, amount=99.99990159273148):
    return {"name": "pipe", "type": "pipe", "x": x, "y": y, "direction": 0, "status_name": "working",
            "fluids": [{"index": 1, "name": "water", "amount": amount, "temperature": 15}]}


def belt(x, y, d, coal=4):
    return {"name": "transport-belt", "type": "transport-belt", "x": x, "y": y, "direction": d,
            "status_name": "working", "lines": [[{"name": "coal", "count": coal}], {}]}


class PerceptionTest(unittest.TestCase):
    def test_twelve_pipes_collapse_to_one_run(self):
        s = summarize([pipe(-55.5 + i, 18.5) for i in range(12)])
        self.assertEqual({"pipe": [{"from": [-55.5, 18.5], "to": [-44.5, 18.5], "fluid": "water:100"}]},
                         s["runs"])

    def test_pipe_corner_splits_and_keeps_every_tile(self):
        rows = [pipe(0.5 + i, 0.5) for i in range(3)] + [pipe(2.5, 1.5 + i) for i in range(2)]
        s = summarize(rows)
        tiles = sum(abs(r["to"][0] - r["from"][0]) + abs(r["to"][1] - r["from"][1]) + 1 if "to" in r else 1
                    for r in s["runs"]["pipe"])
        self.assertEqual(5, tiles)
        self.assertIn({"from": [2.5, 1.5], "to": [2.5, 2.5], "fluid": "water:100"}, s["runs"]["pipe"])

    def test_belt_run_from_is_upstream(self):
        north = summarize([belt(1.5, 5.5 - i, 0) for i in range(4)])["runs"]["transport-belt"][0]
        self.assertEqual(([1.5, 5.5], [1.5, 2.5], 0, "coal:16"),
                         (north["from"], north["to"], north["dir"], north["items"]))
        west = summarize([belt(5.5 - i, 1.5, 12) for i in range(3)])["runs"]["transport-belt"][0]
        self.assertEqual(([5.5, 1.5], [3.5, 1.5]), (west["from"], west["to"]))
        south = summarize([belt(1.5, 0.5 + i, 8) for i in range(2)])["runs"]["transport-belt"][0]
        self.assertEqual(([1.5, 0.5], [1.5, 1.5]), (south["from"], south["to"]))

    def test_opposite_belts_on_one_line_stay_separate(self):
        s = summarize([belt(0.5, 0.5, 4), belt(1.5, 0.5, 4), belt(2.5, 0.5, 12)])
        self.assertEqual([{"from": [0.5, 0.5], "to": [1.5, 0.5], "dir": 4, "items": "coal:8"},
                          {"from": [2.5, 0.5], "dir": 12, "items": "coal:4"}], s["runs"]["transport-belt"])

    def test_faults_raised_waiting_kept_on_row(self):
        rows = [
            {"name": "lab", "type": "lab", "x": -54.5, "y": 30.5, "direction": 0,
             "status_name": "no_research_in_progress", "input": [{"name": "automation-science-pack", "count": 2}]},
            {"name": "inserter", "type": "inserter", "x": 1.5, "y": 1.5, "direction": 8,
             "status_name": "waiting_for_space_in_destination"},
            {"name": "assembling-machine-1", "type": "assembling-machine", "x": 4.5, "y": 4.5,
             "direction": 0, "status_name": "no_power", "recipe": "iron-gear-wheel"},
        ]
        s = summarize(rows)
        self.assertEqual(["assembling-machine-1", "lab"], [m["name"] for m in s["issues"]])
        self.assertEqual("in", [k for k in s["issues"][1] if k == "in"][0])
        self.assertNotIn("dir", s["issues"][1])
        self.assertEqual("blocked", s["machines"]["inserter"][0]["status"])

    def test_rounding_and_poles(self):
        rows = [{"name": "boiler", "type": "boiler", "x": -60.5, "y": 26, "direction": 8,
                 "status_name": "working", "fuel": [{"name": "coal", "count": 5}],
                 "fluids": [{"index": 1, "name": "water", "amount": 200, "temperature": 15},
                            {"index": 2, "name": "steam", "amount": 199.82826709747314, "temperature": 165}]},
                {"name": "small-electric-pole", "type": "electric-pole", "x": -57.5, "y": 30.5, "direction": 0}]
        s = summarize(rows)
        self.assertEqual([{"at": [-60.5, 26], "dir": 8, "fuel": "coal:5",
                           "fluid": "water:200 steam:199.8@165"}], s["machines"]["boiler"])
        self.assertEqual({"small-electric-pole": [[-57.5, 30.5]]}, s["poles"])

    def test_evenly_spaced_identical_machines_become_array(self):
        rows = [{"name": "burner-inserter", "type": "inserter", "x": -69.5 + 2 * i, "y": 22.5, "direction": 8,
                 "status_name": "waiting_for_space_in_destination", "fuel": [{"name": "coal", "count": 1}]}
                for i in range(5)]
        rows.append(dict(rows[0], x=-60.5, y=24.5, direction=0))
        s = summarize(rows)["machines"]["burner-inserter"]
        self.assertEqual([{"at": [-69.5, 22.5], "dir": 8, "status": "blocked", "fuel": "coal:1",
                           "n": 5, "step": [2, 0]},
                          {"at": [-60.5, 24.5], "dir": 0, "status": "blocked", "fuel": "coal:1"}], s)

    def test_gap_in_spacing_breaks_array(self):
        rows = [{"name": "stone-furnace", "type": "furnace", "x": x, "y": 21, "direction": 0,
                 "status_name": "working"} for x in (-69, -65, -61, -53)]
        s = summarize(rows)["machines"]["stone-furnace"]
        self.assertEqual([{"at": [-69, 21], "n": 3, "step": [4, 0]}, {"at": [-53, 21]}], s)


class OutputBudgetTest(unittest.TestCase):
    def test_live_factory_fits_budget(self):
        rows = json.loads(FIXTURE.read_text(encoding="utf-8"))["rows"]
        out = summarize(rows)
        self.assertEqual(295, len(rows))
        self.assertLessEqual(size(out), LIVE_R32_MAX_CHARS,
                             f"nearby output grew to {size(out)} chars; measure before raising the cap")
        faults = {(i["name"], tuple(i["at"]), i["status"]) for i in out["issues"]}
        self.assertIn(("lab", (-54.5, 30.5), "no_research_in_progress"), faults)
        self.assertIn(("assembling-machine-1", (-33.5, 23.5), "item_ingredient_shortage"), faults)

    def test_every_tile_survives_compression(self):
        rows = json.loads(FIXTURE.read_text(encoding="utf-8"))["rows"]
        out = summarize(rows)
        machines = sum(r.get("n", 1) for rs in out["machines"].values() for r in rs) + len(out["issues"])
        tiles = sum(abs(r["to"][0] - r["from"][0]) + abs(r["to"][1] - r["from"][1]) + 1 if "to" in r else 1
                    for rs in out["runs"].values() for r in rs)
        poles = sum(len(p) for p in out["poles"].values())
        self.assertEqual(len(rows), machines + tiles + poles)

    def test_repetition_does_not_grow_output(self):
        def smelters(n):
            return [{"name": "stone-furnace", "type": "furnace", "x": 2 * i, "y": 0, "direction": 0,
                     "status_name": "working", "fuel": [{"name": "coal", "count": 5}]} for i in range(n)]
        small, big = size(summarize(smelters(5))), size(summarize(smelters(200)))
        self.assertLessEqual(big, ARRAY_MAX_CHARS)
        self.assertLessEqual(big - small, 4)  # only the digits of n change
        belts = [{"name": "transport-belt", "type": "transport-belt", "x": i + 0.5, "y": 0.5,
                  "direction": 4, "status_name": "working", "lines": [[], []]} for i in range(500)]
        self.assertLessEqual(size(summarize(belts)), 120)

    def test_nature_and_loose_items_do_not_grow_output(self):
        def forest(n):
            return {"tree": {"count": n, "x1": -30.2, "y1": -31, "x2": 29.9, "y2": 30},
                    "simple-entity": {"count": n // 10, "x1": -5, "y1": -5, "x2": 5, "y2": 5},
                    "cliff": {"count": 3, "x1": 10, "y1": -2, "x2": 18, "y2": -2}}

        def piles(n):
            return [{"name": "wood", "count": 4, "x": 0.3 * i, "y": 1} for i in range(n)] + \
                   [{"name": "stone", "count": 1, "x": 5, "y": 5}]
        self.assertEqual({"rocks": 20, "trees": 200, "cliffs": [3, [10, -2], [18, -2]]}, natural(forest(200)))
        self.assertEqual({"stone": [1, 1, [5, 5]], "wood": [800, 200, [0, 1], [59.7, 1]]}, ground(piles(200)))
        self.assertLessEqual(size(natural(forest(5000))) - size(natural(forest(50))), 4)
        self.assertLessEqual(size(ground(piles(2000))), 80)
        self.assertIsNone(natural({}))
        self.assertIsNone(ground([]))


if __name__ == "__main__":
    unittest.main()
