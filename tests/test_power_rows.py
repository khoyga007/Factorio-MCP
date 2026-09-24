"""power:true pole planning, 23/09 live gaps: from-blocked start and dark chain cells."""
import unittest
from unittest import mock

import factorio_goal_mcp as g


class PoleBridges(unittest.TestCase):
    def test_island_gets_one_bridge_pole(self):
        # cable cell pole 8 below the circuit cell pole: no wire, one bridge between them
        added = g._pole_bridges([(0.5, 0.5), (0.5, 12.5)], [(0.5, -5.5)], set(), [], 7)
        self.assertEqual(1, len(added))
        t = added[0]
        self.assertLessEqual(max(abs(t[1] - 0.5), abs(t[1] - 12.5)), 7)

    def test_bridge_skips_boxes_and_taken_tiles(self):
        box = [[-3, 3, 3, 10]]  # cell body between the two poles
        added = g._pole_bridges([(0.5, 0.5), (0.5, 12.5)], [(0.5, -5.5)],
                                {(0.5, 6.5)}, box, 7)
        self.assertTrue(added)
        for x, y in added:
            self.assertFalse(-3 < x < 3 and 3 < y < 10)

    def test_lit_layout_adds_nothing(self):
        self.assertEqual([], g._pole_bridges([(0.5, 0.5), (0.5, 6.5)], [(0.5, -5.5)], set(), [], 7))

    def test_unbridgeable_gap_raises(self):
        with self.assertRaisesRegex(ValueError, "power-bridge"):
            g._pole_bridges([(0.5, 40.5)], [(0.5, 0.5)], set(), [], 7)


class PoleLine(unittest.TestCase):
    def test_blocked_start_tries_next_tile(self):
        calls = []

        def fake(body, **_):
            calls.append((body["from"]["x"], body["from"]["y"]))
            if len(calls) == 1:
                return {"ok": False, "error": "from-blocked"}
            return {"ok": True, "design": [{"x": body["to"]["x"], "y": body["to"]["y"]}]}
        with mock.patch.object(g, "request", fake):
            line = g._pole_line("nauvis", {"x": 20.5, "y": 2.5}, (0, 0, 6, 6),
                                [(3.5, 3.5)], [], [], [[0, 0, 6, 6]], 7)
        self.assertEqual(2, len(calls))
        self.assertNotEqual(calls[0], calls[1])
        self.assertEqual(calls[1], line[0])  # line starts where the route did


if __name__ == "__main__":
    unittest.main()
