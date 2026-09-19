import unittest

from perception import summarize


def pipe(x, y, amount=99.99990159273148):
    return {"name": "pipe", "type": "pipe", "x": x, "y": y, "direction": 0, "status_name": "working",
            "fluids": [{"index": 1, "name": "water", "amount": amount, "temperature": 15}]}


def belt(x, y, d, coal=4):
    return {"name": "transport-belt", "type": "transport-belt", "x": x, "y": y, "direction": d,
            "status_name": "working", "lines": [[{"name": "coal", "count": coal}], {}]}


class PerceptionTest(unittest.TestCase):
    def test_twelve_pipes_collapse_to_one_run(self):
        s = summarize([pipe(-55.5 + i, 18.5) for i in range(12)])
        self.assertEqual([{"name": "pipe", "from": [-55.5, 18.5], "to": [-44.5, 18.5],
                           "len": 12, "fluid": "water:100"}], s["runs"])
        self.assertEqual({"pipe": 12}, s["counts"])

    def test_pipe_corner_splits_and_keeps_every_tile(self):
        rows = [pipe(0.5 + i, 0.5) for i in range(3)] + [pipe(2.5, 1.5 + i) for i in range(2)]
        s = summarize(rows)
        self.assertEqual(5, sum(r["len"] for r in s["runs"]))
        self.assertIn({"name": "pipe", "from": [2.5, 1.5], "to": [2.5, 2.5], "len": 2,
                       "fluid": "water:100"}, s["runs"])

    def test_belt_run_from_is_upstream(self):
        north = summarize([belt(1.5, 5.5 - i, 0) for i in range(4)])["runs"][0]
        self.assertEqual(([1.5, 5.5], [1.5, 2.5], 0, "coal:16"),
                         (north["from"], north["to"], north["dir"], north["items"]))
        west = summarize([belt(5.5 - i, 1.5, 12) for i in range(3)])["runs"][0]
        self.assertEqual(([5.5, 1.5], [3.5, 1.5]), (west["from"], west["to"]))
        south = summarize([belt(1.5, 0.5 + i, 8) for i in range(2)])["runs"][0]
        self.assertEqual(([1.5, 0.5], [1.5, 1.5]), (south["from"], south["to"]))

    def test_opposite_belts_on_one_line_stay_separate(self):
        s = summarize([belt(0.5, 0.5, 4), belt(1.5, 0.5, 4), belt(2.5, 0.5, 12)])
        self.assertEqual(sorted([2, 1]), sorted(r["len"] for r in s["runs"]))

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
        self.assertEqual("waiting_for_space_in_destination", s["machines"][0]["status"])

    def test_rounding_and_poles(self):
        rows = [{"name": "boiler", "type": "boiler", "x": -60.5, "y": 26, "direction": 8,
                 "status_name": "working", "fuel": [{"name": "coal", "count": 5}],
                 "fluids": [{"index": 1, "name": "water", "amount": 200, "temperature": 15},
                            {"index": 2, "name": "steam", "amount": 199.82826709747314, "temperature": 165}]},
                {"name": "small-electric-pole", "type": "electric-pole", "x": -57.5, "y": 30.5, "direction": 0}]
        s = summarize(rows)
        self.assertEqual({"name": "boiler", "at": [-60.5, 26], "dir": 8, "fuel": "coal:5",
                          "fluid": "water:200 steam:199.8@165"}, s["machines"][0])
        self.assertEqual({"small-electric-pole": [[-57.5, 30.5]]}, s["poles"])


if __name__ == "__main__":
    unittest.main()
