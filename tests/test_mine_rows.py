"""mine / feed:true, 24/09: where two side-loads join a chain port."""
import unittest
from unittest import mock

import factorio_goal_mcp as g


def grid(rows):
    # x0 -45.5: column i is x = -45.5 + i; the port under test sits at x -40.5 (column 5)
    return lambda *a: g._result({"ok": True, "x0": -45.5, "y0": 59.5, "rows": rows})


class MergeCol(unittest.TestCase):
    def test_free_sides_merge_on_the_port(self):
        with mock.patch.object(g, "_grid", grid(["59.5 ..........", "60.5 ......>>..",
                                                 "61.5 .........."])):
            self.assertEqual(-40.5, g._merge_col("nauvis", -40.5, 60.5))

    def test_cell_pole_south_moves_merge_west(self):
        # exec-19 live: the iron cell's pole sits right below the port
        with mock.patch.object(g, "_grid", grid(["59.5 ..........", "60.5 ......>>..",
                                                 "61.5 .....+s+.."])):
            self.assertEqual(-41.5, g._merge_col("nauvis", -40.5, 60.5))

    def test_all_blocked_raises(self):
        with mock.patch.object(g, "_grid", grid(["59.5 ++++++....", "60.5 ......>>..",
                                                 "61.5 .........."])):
            with self.assertRaisesRegex(ValueError, "mine-port-sides-blocked"):
                g._merge_col("nauvis", -40.5, 60.5)


if __name__ == "__main__":
    unittest.main()


class PowerScan(unittest.TestCase):
    def test_pole_past_the_32_clamp_is_found(self):
        # Ariel 23/09: layout centre y=106, live pole at y=65.5 (41.8 away) -> the old single
        # radius-64 scan was clamped to 32 in Lua and raised power-no-pole-within-64.
        pole = {"name": "small-electric-pole", "x": -20.5, "y": 65.5}

        def pull(surface, x, y, radius, obstacles=False):
            seen = abs(pole["x"] - x) <= radius and abs(pole["y"] - y) <= radius
            return None, {}, [pole] if seen else [], [], [], None
        with mock.patch.object(g, "_pull", pull), \
                mock.patch.object(g, "_pole_line", lambda *a: [(-20.5, 72.5)]), \
                mock.patch.object(g, "_pole_bridges", lambda *a: []):
            rows = g._power_rows([{"name": "small-electric-pole", "x": -20.5, "y": 80.5}],
                                 [[-24, 80, -16, 132]], "nauvis", "small-electric-pole")
        self.assertEqual([(-20.5, 72.5)], [(r["x"], r["y"]) for r in rows])
