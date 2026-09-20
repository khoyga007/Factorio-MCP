"""Verify the compact MCP surface and one goal spanning multiple bridge actions."""
import asyncio
import json
import os
from pathlib import Path
import socketserver
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from blueprint_library import encode_blueprint, import_reference, record_blueprint


class GoalMCPTest(unittest.IsolatedAsyncioTestCase):
    async def test_three_tools_and_internal_workflows(self):
        seen = []

        class Peer(socketserver.BaseRequestHandler):
            def handle(self):
                raw, sock = self.request
                body = json.loads(raw)
                seen.append(body)
                action = body["action"]
                reply = {"nonce": body["nonce"], "ok": True, "action": action}
                if action == "brief":
                    reply.update(center={"x": 0, "y": 0}, counts={"stone-furnace": 1})
                elif action == "ore_marks":
                    reply.update(total=1, marks=[{"name": "iron-ore", "x": 0, "y": 0}])
                elif action == "snapshot":
                    reply.update(entities=[{"name": "stone-furnace", "x": 0, "y": 0,
                                            "status_name": "working"}], entities_total=1)
                elif action == "blueprint_run":
                    reply.update(state="planned" if body.get("dry_run") else "preparing",
                                 site_validated=True, job_id=None if body.get("dry_run") else "exec-1",
                                 contract_seen=body["contract"])
                elif action == "research":
                    reply.update(current=body.get("name"), queue=[], labs={"working": 1})
                elif action == "blueprint_export":
                    reply.update(entities=10, blueprint=(Path(__file__).parent.parent / "blueprints"
                                 / "coal-line-v1.blueprint.txt").read_text().strip())
                elif action == "water_sites":
                    reply.update(candidates=[{"x": 1.5, "y": 2, "direction": 0}])
                elif action == "recall":
                    reply.update(state="planned" if body.get("dry_run") else "done", count=1)
                elif action == "set_recipe":
                    if body["recipe"] == "locked-recipe":
                        reply.update(ok=False, error="technology-locked")
                    else:
                        reply.update(recipe=body["recipe"], unchanged=False)
                elif action == "craft":
                    if body["recipe"] == "locked-recipe":
                        reply.update(ok=False, error="technology-locked", craftable=0)
                    else:
                        reply.update(recipe=body["recipe"], count=body["count"])
                elif action == "collect":
                    reply.update(item=body["item"], count=body["count"],
                                 source_remaining=7, player_total=99)
                elif action == "insert":
                    reply.update(item=body["item"], count=body["count"],
                                 slot="source" if body.get("source") else "fuel", remaining=3)
                elif action == "blueprint_job":
                    reply.update(state="verified", feed={"coal": 4},
                                 audit={"status": "passed", "windows": [{"index": 1}]})
                sock.sendto(json.dumps(reply).encode(), self.client_address)

        server = socketserver.UDPServer(("127.0.0.1", 0), Peer)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as directory:
                catalog_dir = str(Path(directory) / "catalog")
                with patch.dict(os.environ, {"FACTORIO_BLUEPRINT_CATALOG": catalog_dir}):
                    native = (Path(__file__).parent.parent / "blueprints"
                              / "coal-line-v1.blueprint.txt").read_text().strip()
                    pattern_id = record_blueprint(native, state="built", source="test")["pattern_id"]
                params = StdioServerParameters(
                    command=sys.executable,
                    args=[str(Path(__file__).parent.parent / "factorio_goal_mcp.py")],
                    env={**os.environ, "FACTORIO_PORT": str(server.server_address[1]),
                         "FACTORIO_BLUEPRINT_CATALOG": catalog_dir},
                )
                with (Path(directory) / "mcp.log").open("w") as log:
                    async with stdio_client(params, errlog=log) as (read, write):
                        async with ClientSession(read, write) as session:
                            await session.initialize()
                            catalog = await session.list_tools()
                            self.assertEqual({"observe", "achieve", "report"},
                                             {t.name for t in catalog.tools})
                            schema_bytes = sum(len(json.dumps(t.model_dump(mode="json")))
                                               for t in catalog.tools)
                            self.assertLess(schema_bytes, 4000)

                            async def call(name, args, actions):
                                before = len(seen)
                                result = await session.call_tool(name, args)
                                self.assertFalse(result.isError, result.content)
                                self.assertEqual(actions, [p["action"] for p in seen[before:]])
                                return json.loads(result.content[0].text)

                            p = await call("observe", {}, ["brief"])
                            self.assertEqual(1, p["counts"]["stone-furnace"])
                            p = await call("observe", {"view": "deposits", "resource": "iron-ore"},
                                           ["ore_marks"])
                            self.assertEqual(1, p["total"])
                            p = await call("observe", {"view": "entities", "offset": 12}, ["snapshot"])
                            self.assertEqual(12, seen[-1]["offset"])
                            self.assertEqual("working", p["entities"][0]["status_name"])
                            p = await call("observe", {"view": "nearby"}, ["snapshot"])
                            self.assertEqual(64, seen[-1]["limit"])
                            self.assertEqual([0, 0], p["machines"]["stone-furnace"][0]["at"])
                            self.assertEqual([], p["issues"])
                            p = await call("observe", {"view": "patterns"}, [])
                            self.assertEqual(pattern_id, p["patterns"][0]["pattern_id"])
                            self.assertNotIn("blueprint_string", p["patterns"][0])
                            # Imported human material is readable, but the executor will not
                            # touch it until the agent says what it expects of it.
                            with patch.dict(os.environ,
                                            {"FACTORIO_BLUEPRINT_CATALOG": catalog_dir}):
                                reference = import_reference(encode_blueprint(
                                    [{"name": "stone-furnace", "x": 1, "y": 1}]),
                                    url="https://example.invalid/bp")
                            refused = await session.call_tool(
                                "achieve", {"goal": "reuse_blueprint",
                                            "pattern_id": reference["pattern_id"]})
                            self.assertTrue(refused.isError)
                            p = json.loads(refused.content[0].text)
                            self.assertEqual("reference-pattern-needs-contract", p["error"])
                            self.assertEqual("community", p["origin"]["kind"])
                            p = await call("achieve", {"goal": "reuse_blueprint",
                                                       "pattern_id": reference["pattern_id"],
                                                       "contract": {"site": {"mode": "exact"}},
                                                       "dry_run": True}, ["blueprint_run"])
                            self.assertEqual(reference["pattern_id"], seen[-1]["pattern_id"])
                            own = {"site": {"mode": "exact"}, "primer": []}
                            p = await call("achieve", {"goal": "reuse_blueprint",
                                                       "pattern_id": pattern_id, "contract": own,
                                                       "x": 10, "y": 20, "dry_run": True}, ["blueprint_run"])
                            self.assertTrue(p["site_validated"])
                            self.assertEqual(own, seen[-1]["contract"])
                            self.assertEqual((10, 20), (seen[-1]["x"], seen[-1]["y"]))
                            p = await call("achieve", {"goal": "reuse_blueprint",
                                                       "pattern_id": pattern_id,
                                                       }, ["blueprint_run"])
                            self.assertEqual("exec-1", p["job_id"])
                            self.assertNotIn("x", seen[-1])
                            self.assertEqual({}, seen[-1]["contract"])
                            p = await call("report", {"job_id": "exec-1"}, ["blueprint_job"])
                            self.assertEqual("verified", p["state"])
                            self.assertEqual(4, p["feed"]["coal"])
                            self.assertTrue(p["self_sustaining"])
                            p = await call("observe", {"view": "patterns", "pattern_id": pattern_id}, [])
                            design = p["entities"]
                            self.assertIn("wooden-chest", {e["name"] for e in design})
                            p = await call("achieve", {"goal": "build_design", "design": design,
                                                       "contract": own, "dry_run": True}, ["blueprint_run"])
                            self.assertEqual(pattern_id, p["pattern_id"])
                            # the built pattern + the imported reference, no duplicate
                            self.assertEqual(2, len(os.listdir(catalog_dir)))
                            moved = [dict(e, y=e["y"] + 3) if e["name"] == "wooden-chest" else e
                                     for e in design]
                            p = await call("achieve", {"goal": "build_design", "design": moved,
                                                       "contract": own}, ["blueprint_run"])
                            self.assertNotEqual(pattern_id, p["pattern_id"])
                            self.assertEqual(own, seen[-1]["contract"])
                            saved = json.loads((Path(catalog_dir) / (p["pattern_id"] + ".json")).read_text())
                            self.assertEqual(("designed", own), (saved["state"], saved["contract"]))
                            p = await call("observe", {"view": "water", "x": 5, "y": 6, "radius": 300}, ["water_sites"])
                            self.assertEqual((300, 5), (seen[-1]["radius"], seen[-1]["x"]))
                            self.assertEqual(0, p["candidates"][0]["direction"])
                            p = await call("achieve", {"goal": "recall", "area": [0, 0, 4, 4], "dry_run": True}, ["recall"])
                            self.assertEqual(("planned", 4, True), (p["state"], seen[-1]["x2"], seen[-1]["dry_run"]))
                            # A run longer than the bridge's 64-tile cap is sliced here, not
                            # by hand: one agent intent, one call, several bridge recalls.
                            p = await call("achieve", {"goal": "recall", "area": [0, 0, 200, 10],
                                                       "dry_run": True},
                                           ["recall", "recall", "recall", "recall"])
                            self.assertEqual((4, 4, "planned"),
                                             (p["slices"], p["slices_done"], p["state"]))
                            self.assertEqual([(0, 64), (64, 128), (128, 192), (192, 200)],
                                             [(q["x1"], q["x2"]) for q in seen[-4:]])
                            self.assertEqual({(0, 10)}, {(q["y1"], q["y2"]) for q in seen[-4:]})
                            p = await call("achieve", {"goal": "recall", "design": [{"name": "pipe", "x": 0.5, "y": 0.5}]}, ["recall"])
                            self.assertEqual("pipe", seen[-1]["entities"][0]["name"])
                            p = await call("observe", {"view": "research"}, ["research"])
                            self.assertTrue(seen[-1]["available"])
                            p = await call("achieve", {"goal": "research", "tech": "automation"}, ["research"])
                            self.assertEqual(("automation", True), (seen[-1]["name"], seen[-1]["start"]))
                            # One bridge call per machine, so a refusal names its own target.
                            p = await call("achieve", {"goal": "set_recipe", "design": [
                                {"x": 1.5, "y": 2.5, "recipe": "pipe"},
                                {"x": 4.5, "y": 2.5, "recipe": "repair-pack"}]},
                                ["set_recipe", "set_recipe"])
                            self.assertEqual([], p["failed"])
                            self.assertEqual(["pipe", "repair-pack"], [r["recipe"] for r in p["set"]])
                            self.assertEqual((4.5, "repair-pack"), (seen[-1]["x"], seen[-1]["recipe"]))
                            before = len(seen)
                            partial = await session.call_tool("achieve", {"goal": "set_recipe", "design": [
                                {"x": 1.5, "y": 2.5, "recipe": "pipe"},
                                {"x": 4.5, "y": 2.5, "recipe": "locked-recipe"}]})
                            self.assertTrue(partial.isError)
                            p = json.loads(partial.content[0].text)
                            self.assertEqual(2, len(seen) - before)
                            self.assertEqual(1, len(p["set"]))
                            self.assertEqual("technology-locked", p["failed"][0]["error"])
                            self.assertEqual(4.5, p["failed"][0]["x"])
                            # maintainer's 20/09 rule is MCP-only, so hand work needs a door of
                            # its own: one bridge call per row, batched in one agent call.
                            p = await call("achieve", {"goal": "craft", "design": [
                                {"name": "stone-furnace", "count": 4},
                                {"name": "transport-belt", "count": 20}]}, ["craft", "craft"])
                            self.assertEqual(["stone-furnace", "transport-belt"],
                                             [r["name"] for r in p["rows"]])
                            self.assertEqual((20, "transport-belt"),
                                             (seen[-1]["count"], seen[-1]["recipe"]))
                            self.assertNotIn("x", seen[-1])
                            # The call's own x/y are the default for rows that omit them.
                            p = await call("achieve", {"goal": "collect", "x": -78, "y": 5,
                                                       "design": [{"name": "iron-plate", "count": 50},
                                                                  {"name": "coal", "count": 10,
                                                                   "x": -100.5, "y": 58.5}]},
                                           ["collect", "collect"])
                            self.assertEqual((-78.0, 5.0), (seen[-2]["x"], seen[-2]["y"]))
                            self.assertEqual((-100.5, 58.5), (seen[-1]["x"], seen[-1]["y"]))
                            self.assertEqual(7, p["rows"][0]["source_remaining"])
                            # source=True is the furnace ore slot; without it insert means fuel.
                            p = await call("achieve", {"goal": "insert", "x": -78, "y": 5, "design": [
                                {"name": "coal", "count": 10},
                                {"name": "iron-ore", "count": 30, "source": True}]},
                                ["insert", "insert"])
                            self.assertEqual(["fuel", "source"], [r["slot"] for r in p["rows"]])
                            self.assertNotIn("source", seen[-2])
                            self.assertIs(True, seen[-1]["source"])
                            # A failed row does not hide behind the ones that worked.
                            before = len(seen)
                            partial = await session.call_tool("achieve", {"goal": "craft", "design": [
                                {"name": "stone-furnace", "count": 1},
                                {"name": "locked-recipe", "count": 1}]})
                            self.assertTrue(partial.isError)
                            p = json.loads(partial.content[0].text)
                            self.assertEqual(2, len(seen) - before)
                            self.assertEqual([True, False], [r["ok"] for r in p["rows"]])
                            self.assertEqual("technology-locked", p["rows"][1]["error"])
                            for bad, why in (({"goal": "craft", "design": []}, "design-rows-required"),
                                             ({"goal": "collect", "design": [{"name": "coal", "count": 1}]},
                                              "coordinate-pairs-required:0"),
                                             ({"goal": "craft", "design": [{"name": "coal", "count": 0}]},
                                              "invalid-design-entity:0")):
                                refused_hand = await session.call_tool("achieve", bad)
                                self.assertTrue(refused_hand.isError)
                                self.assertEqual(why, json.loads(
                                    refused_hand.content[0].text)["error"])
                            p = await call("achieve", {"goal": "capture", "area": [0, 0, 9, 9]}, ["blueprint_export"])
                            self.assertEqual((pattern_id, "built"), (p["pattern_id"], p["state"]))
                            self.assertEqual(10, len(p["layout"]))
                            for name, args in [
                                ("achieve", {"goal": "unknown-goal"}),
                                ("achieve", {"goal": "reuse_blueprint", "x": 1}),
                                ("achieve", {"goal": "reuse_blueprint", "area": [0, 0, 1, 1]}),
                                ("achieve", {"goal": "build_design"}),
                                ("observe", {"view": "nearby", "radius": 100}),
                                ("achieve", {"goal": "research"}),
                                ("achieve", {"goal": "capture"}),
                                ("achieve", {"goal": "capture", "tech": "automation"}),
                                ("achieve", {"goal": "recall"}),
                                ("achieve", {"goal": "set_recipe"}),
                                ("achieve", {"goal": "set_recipe", "design": [{"x": 0, "y": 0}]}),
                                ("achieve", {"goal": "recall", "area": [0, 0, 4]}),
                                ("achieve", {"goal": "build_design", "design": [{"name": "x", "x": 0.3, "y": 0}]}),
                                ("achieve", {"goal": "reuse_blueprint", "pattern_id": pattern_id,
                                             "design": [{"name": "x", "x": 0, "y": 0}]}),
                                ("observe", {"view": "unknown-view"}),
                                ("report", {"job_id": "unknown"}),
                            ]:
                                before = len(seen)
                                result = await session.call_tool(name, args)
                                self.assertTrue(result.isError)
                                self.assertEqual(before, len(seen))
        finally:
            await asyncio.to_thread(server.shutdown)
            server.server_close()
            thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
