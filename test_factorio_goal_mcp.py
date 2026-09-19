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
from blueprint_library import record_blueprint


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
                elif action == "starter_smelt":
                    reply.update(state="auditing", job_id="starter-3", product=body["product"],
                                 existing=True, output=2)
                elif action == "starter_status":
                    reply.update(state="verified", audit={"status": "passed", "products": 7})
                elif action == "coal_stockpile":
                    reply.update(state="auditing", job_id="coal-3", coal=2,
                                 site={"drill": {"x": 0, "y": 0}})
                elif action == "coal_status":
                    reply.update(state="verified", coal=8,
                                 audit={"status": "passed", "coal_gained": 6})
                elif action == "smelt_plan":
                    reply.update(plan_id="smelt-2", furnaces=3, missing={}, locked={},
                                 connections={"input": "planned-connection",
                                              "supply_observed": True,
                                              "electricity": "pole-in-reach"})
                    if body["rate"] == 999:
                        reply["connections"]["electricity"] = "needs-power"
                elif action == "smelt_build":
                    reply.update(state="auditing", placed=28, artifact="smelting/smelt-2")
                elif action == "smelt_status":
                    reply.update(state="verified", audit={"status": "passed"})
                elif action == "blueprint_import":
                    reply.update(placed=10, expected=10,
                                 spent={"burner-mining-drill": 2})
                    if body.get("automate"):
                        reply.update(state="planned" if body.get("dry_run") else "preparing",
                                     site_validated=True,job_id="replica-1")
                sock.sendto(json.dumps(reply).encode(), self.client_address)

        server = socketserver.UDPServer(("127.0.0.1", 0), Peer)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as directory:
                catalog_dir = str(Path(directory) / "catalog")
                with patch.dict(os.environ, {"FACTORIO_BLUEPRINT_CATALOG": catalog_dir}):
                    native = (Path(__file__).parent / "blueprints"
                              / "coal-line-v1.blueprint.txt").read_text().strip()
                    pattern_id = record_blueprint(native, state="built", source="test")["pattern_id"]
                params = StdioServerParameters(
                    command=sys.executable,
                    args=[str(Path(__file__).with_name("factorio_goal_mcp.py"))],
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
                            p = await call("observe", {"view": "nearby"}, ["snapshot"])
                            self.assertEqual("working", p["entities"][0]["status_name"])
                            p = await call("observe", {"view": "patterns"}, [])
                            self.assertEqual(pattern_id, p["patterns"][0]["pattern_id"])
                            self.assertNotIn("blueprint_string", p["patterns"][0])
                            p = await call("achieve", {"goal": "reuse_blueprint",
                                                       "pattern_id": pattern_id,
                                                       "x": 10, "y": 20, "dry_run": True}, ["blueprint_import"])
                            self.assertTrue(p["site_validated"])
                            p = await call("achieve", {"goal": "reuse_blueprint",
                                                       "pattern_id": pattern_id,
                                                       }, ["blueprint_import"])
                            self.assertEqual("replica-1", p["job_id"])
                            self.assertNotIn("x", seen[-1])
                            p=await call("report",{"job_id":"replica-1"},["coal_status"])
                            self.assertEqual("verified",p["state"])
                            p = await call("achieve", {"goal": "first_iron_plates"}, ["starter_smelt"])
                            self.assertEqual("starter-3", p["job_id"])
                            self.assertTrue(p["existing"])
                            p = await call("report", {"job_id": "starter-3"}, ["starter_status"])
                            self.assertEqual(7, p["audit"]["products"])
                            p = await call("achieve", {"goal": "coal_stockpile"}, ["coal_stockpile"])
                            self.assertEqual("coal-3", p["job_id"])
                            p = await call("report", {"job_id": "coal-3"}, ["coal_status"])
                            self.assertEqual(6, p["audit"]["coal_gained"])
                            p = await call("achieve", {"goal": "iron_smelting_row",
                                                       "target_per_minute": 60},
                                           ["smelt_plan", "smelt_build"])
                            self.assertEqual("auditing", p["state"])
                            p = await call("report", {"job_id": "smelt-2"}, ["smelt_status"])
                            self.assertEqual("verified", p["state"])
                            p = await call("achieve", {"goal": "iron_smelting_row",
                                                       "target_per_minute": 999}, ["smelt_plan"])
                            self.assertEqual("blocked", p["state"])
                            self.assertIn("power", p["blockers"])
                            for name, args in [
                                ("achieve", {"goal": "iron_smelting_row"}),
                                ("achieve", {"goal": "first_iron_plates", "x": 1}),
                                ("achieve", {"goal": "unknown-goal"}),
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
