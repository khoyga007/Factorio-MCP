import json
import socket
import threading
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from factorio_ai import command_body, parser, request


class BridgeClientTest(unittest.TestCase):
    def test_ore_marks_command(self):
        args = parser().parse_args(["ore-marks", "--name", "iron-ore", "--offset", "50"])
        self.assertEqual(
            {"action": "ore_marks", "surface": "nauvis",
             "name": "iron-ore", "offset": 50, "limit": 50},
            command_body(args),
        )

    def test_blueprint_commands(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "module.txt"
            path.write_text("0example\n", encoding="ascii")
            exported = command_body(parser().parse_args(
                ["blueprint-export", "1", "2", "11", "12", str(path)]
            ))
            self.assertEqual("blueprint_export", exported["action"])
            self.assertEqual((1.0, 2.0, 11.0, 12.0),
                             tuple(exported[key] for key in ("x1", "y1", "x2", "y2")))
            imported = command_body(parser().parse_args(
                ["blueprint-import", str(path), "20.5", "-4.5"]
            ))
            self.assertEqual("0example", imported["blueprint"])
            self.assertEqual((20.5, -4.5), (imported["x"], imported["y"]))
            self.assertEqual("direct", imported["mode"])
            ghosts = command_body(parser().parse_args(
                ["blueprint-import", str(path), "20.5", "-4.5", "--ghosts"]
            ))
            self.assertEqual("ghosts", ghosts["mode"])

    def test_brief_command(self):
        args = parser().parse_args(["brief", "--x", "10", "--y", "-28", "--radius", "64"])
        self.assertEqual(
            {"action": "brief", "surface": "nauvis", "x": 10.0, "y": -28.0, "radius": 64.0},
            command_body(args),
        )
        with self.assertRaises(ValueError):
            command_body(parser().parse_args(["brief", "--x", "10"]))

    def test_snapshot_pagination_command(self):
        args = parser().parse_args(["snapshot", "--x", "27", "--y", "-2", "--radius", "28", "--offset", "64"])
        self.assertEqual(
            {
                "action": "snapshot", "surface": "nauvis", "x": 27.0,
                "y": -2.0, "radius": 28.0, "offset": 64, "limit": 64,
            },
            command_body(args),
        )

    def test_spec_command(self):
        args = parser().parse_args(["spec", "entity", "burner-mining-drill"])
        self.assertEqual(
            {"action": "spec", "kind": "entity", "name": "burner-mining-drill"},
            command_body(args),
        )

    def test_audit_command(self):
        args = parser().parse_args(["audit", "iron-plate", "--expected-per-second", "0.625"])
        self.assertEqual(
            {
                "action": "audit", "item": "iron-plate", "surface": "nauvis",
                "force": "player", "precision": "one_minute",
            },
            command_body(args),
        )

    def test_set_recipe_command(self):
        args = parser().parse_args(["set-recipe", "iron-gear-wheel", "26.5", "-27.5"])
        self.assertEqual(
            {
                "action": "set_recipe", "recipe": "iron-gear-wheel",
                "x": 26.5, "y": -27.5, "surface": "nauvis", "force": "player",
            },
            command_body(args),
        )

    def test_research_status_and_start_commands(self):
        self.assertEqual(
            {"action": "research", "force": "player"},
            command_body(parser().parse_args(["research"])),
        )
        self.assertEqual(
            {"action": "research", "force": "player", "name": "automation", "start": True},
            command_body(parser().parse_args(["research", "automation", "--start"])),
        )
        with self.assertRaises(ValueError):
            command_body(parser().parse_args(["research", "--start"]))

    def test_insert_command(self):
        self.assertEqual(
            {
                "action": "insert", "item": "automation-science-pack", "count": 10,
                "x": 30.5, "y": -23.5, "surface": "nauvis", "force": "player",
                "source": False,
            },
            command_body(parser().parse_args(
                ["insert", "automation-science-pack", "10", "30.5", "-23.5"]
            )),
        )
        self.assertEqual(
            {
                "action": "insert", "item": "iron-ore", "count": 5,
                "x": 1.0, "y": 2.0, "surface": "nauvis", "force": "player",
                "source": True,
            },
            command_body(parser().parse_args(
                ["insert", "iron-ore", "5", "1", "2", "--source"]
            )),
        )

    def test_autofuel_command(self):
        args = parser().parse_args(["autofuel", "off"])
        self.assertEqual(
            {"action": "autofuel", "enabled": False},
            command_body(args),
        )

    def test_collect_command(self):
        args = parser().parse_args(["collect", "iron-plate", "6", "9.5", "-26.5"])
        self.assertEqual(
            {
                "action": "collect",
                "item": "iron-plate",
                "count": 6,
                "surface": "nauvis",
                "x": 9.5,
                "y": -26.5,
            },
            command_body(args),
        )

    def test_mine_command(self):
        args = parser().parse_args(["mine", "stone-furnace", "4", "-23"])
        self.assertEqual(
            {
                "action": "mine",
                "name": "stone-furnace",
                "surface": "nauvis",
                "x": 4.0,
                "y": -23.0,
            },
            command_body(args),
        )

    def test_craft_command(self):
        args = parser().parse_args(["craft", "iron-gear-wheel", "2"])
        self.assertEqual(
            {"action": "craft", "recipe": "iron-gear-wheel", "count": 2},
            command_body(args),
        )

    def test_snapshot_tiles_defaults_to_pumpable_water(self):
        args = parser().parse_args(["snapshot", "--tiles", "--x", "10", "--y", "-28"])
        self.assertEqual(
            {
                "action": "snapshot",
                "surface": "nauvis",
                "radius": 16.0,
                "offset": 0,
                "limit": 64,
                "tiles": True,
                "x": 10.0,
                "y": -28.0,
            },
            command_body(args),
        )

    def test_snapshot_tiles_passes_explicit_names(self):
        args = parser().parse_args(
            ["snapshot", "--tiles", "--name", "water", "--name", "deepwater"]
        )
        body = command_body(args)
        self.assertTrue(body["tiles"])
        self.assertEqual(["water", "deepwater"], body["name"])
        self.assertNotIn("x", body)

    def test_snapshot_tiles_rejects_half_a_position(self):
        args = parser().parse_args(["snapshot", "--tiles", "--x", "10"])
        with self.assertRaises(ValueError):
            command_body(args)

    def test_place_dry_run_command(self):
        args = parser().parse_args(
            ["place", "offshore-pump", "12.5", "-30.5", "--direction", "south", "--dry-run"]
        )
        self.assertEqual(
            {
                "action": "place",
                "name": "offshore-pump",
                "surface": "nauvis",
                "force": "player",
                "x": 12.5,
                "y": -30.5,
                "direction": "south",
                "dry_run": True,
            },
            command_body(args),
        )

    def test_spec_recipe_by_name(self):
        args = parser().parse_args(["spec", "recipe", "lab"])
        self.assertEqual(
            {"action": "spec", "kind": "recipe", "force": "player", "name": "lab"},
            command_body(args),
        )

    def test_spec_recipe_by_entity(self):
        args = parser().parse_args(["spec", "recipe", "--entity", "offshore-pump"])
        self.assertEqual(
            {"action": "spec", "kind": "recipe", "force": "player", "entity": "offshore-pump"},
            command_body(args),
        )

    def test_spec_recipe_needs_a_target(self):
        args = parser().parse_args(["spec", "recipe"])
        with self.assertRaises(ValueError):
            command_body(args)

    def test_retry_reuses_nonce_and_ignores_unrelated_reply(self):
        server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        server.bind(("127.0.0.1", 0))
        port = server.getsockname()[1]
        seen = []

        def serve():
            try:
                for _ in range(2):
                    packet, client = server.recvfrom(4096)
                    body = json.loads(packet)
                    seen.append(body["nonce"])
                server.sendto(json.dumps({"nonce": "wrong", "ok": True}).encode(), client)
                server.sendto(json.dumps({"nonce": seen[-1], "ok": True}).encode(), client)
            finally:
                server.close()

        worker = threading.Thread(target=serve)
        worker.start()
        reply = request(
            {"action": "ping"}, port=port, timeout=0.05, retries=3, nonce="same"
        )
        worker.join(timeout=1)

        self.assertTrue(reply["ok"])
        self.assertEqual(["same", "same"], seen)


if __name__ == "__main__":
    unittest.main()
