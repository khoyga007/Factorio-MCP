"""Exercise real MCP stdio framing against a loopback UDP peer (no game needed)."""
import asyncio
import json
import os
from pathlib import Path
import socketserver
import sys
import tempfile
import threading
import unittest

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

from contract_check import load_actions


class MCPTest(unittest.IsolatedAsyncioTestCase):
    async def test_protocol_all_actions_and_artifacts(self):
        seen = []

        class Peer(socketserver.BaseRequestHandler):
            def handle(self):
                data, sock = self.request
                body = json.loads(data)
                seen.append(body)
                reply = {"nonce": body["nonce"], "ok": True, "action": body["action"]}
                if body["action"] == "audit":
                    reply["produced_per_minute"] = 60
                if body["action"] == "blueprint_export":
                    reply.update(blueprint="0fixture-blueprint", entities=2)
                if body.get("name") == "locked":
                    reply.update(ok=False, error="technology-locked")
                sock.sendto(json.dumps(reply).encode(), self.client_address)

        server = socketserver.UDPServer(("127.0.0.1", 0), Peer)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as temp:
                export = str(Path(temp) / "test.blueprint.txt")
                params = StdioServerParameters(
                    command=sys.executable,
                    args=[str(Path(__file__).parent.parent / "factorio_mcp.py")],
                    env={**os.environ, "FACTORIO_PORT": str(server.server_address[1])},
                )
                with (Path(temp) / "mcp.log").open("w") as log:
                    async with stdio_client(params, errlog=log) as (read, write):
                        async with ClientSession(read, write) as session:
                            await session.initialize()
                            catalog = await session.list_tools()
                            self.assertEqual(set(load_actions()), {t.name for t in catalog.tools})
                            self.assertTrue(next(t for t in catalog.tools if t.name == "snapshot").annotations.readOnlyHint)
                            self.assertFalse(next(t for t in catalog.tools if t.name == "blueprint_run").annotations.readOnlyHint)
                            cases = {
                                "ping": {}, "brief": {}, "snapshot": {"obstacles": True},
                                "index": {}, "ore_marks": {"name": "iron-ore"},
                                "spec": {"kind": "recipe", "entity": "stone-furnace"},
                                "set_treasury": {"x": 1, "y": 2},
                                "place": {"name": "underground-belt", "x": 1.5, "y": 2.5, "type": "output"},
                                "craft": {"recipe": "iron-gear-wheel"},
                                "mine": {"name": "wooden-chest", "x": 1.5, "y": 2.5},
                                "collect": {"item": "iron-plate", "count": 2, "x": 1, "y": 2, "ground": True},
                                "insert": {"item": "iron-ore", "count": 2, "x": 1, "y": 2, "source": True},
                                "autofuel": {"state": "off"},
                                "set_recipe": {"recipe": "iron-gear-wheel", "x": 1, "y": 2},
                                "research": {"name": "automation", "start": True},
                                "audit": {"item": "iron-plate", "expected_per_second": 2},
                                "blueprint_export": {"x1": 0, "y1": 0, "x2": 2, "y2": 2, "file": export},
                                "blueprint_import": {"file": export, "x": 10, "y": 20},
                                "blueprint_run": {"file": export, "contract": {"site": {"mode": "exact"}},
                                                  "x": 1, "y": 2},
                                "blueprint_job": {"job_id": "exec-1"},
                                "drop_ghosts": {"job_id": "exec-1", "dry_run": True},
                                "ledger": {},
                                "ledger_note": {"block": {"name": "hand"}, "x1": 0, "y1": 0, "x2": 2, "y2": 2},
                                "water_sites": {"x": 1, "y": 2},
                                "recall": {"x1": 0, "y1": 0, "x2": 2, "y2": 2, "dry_run": True},
                            }
                            for name, args in cases.items():
                                with self.subTest(tool=name):
                                    before = len(seen)
                                    result = await session.call_tool(name, args)
                                    self.assertFalse(result.isError, result.content)
                                    self.assertEqual(1, len(result.content))
                                    self.assertEqual(before + 1, len(seen), "one tool invocation = one UDP request")
                                    self.assertEqual(name, seen[-1]["action"])
                                    reply = json.loads(result.content[0].text)
                                    if name == "audit":
                                        self.assertEqual(-1, reply["delta_per_second"])
                                    if name == "blueprint_export":
                                        self.assertNotIn("blueprint", reply)
                                        self.assertEqual("0fixture-blueprint\n", Path(export).read_text())
                                    if name == "blueprint_import":
                                        self.assertEqual("0fixture-blueprint", seen[-1]["blueprint"])
                                        self.assertEqual("direct", seen[-1]["mode"])
                                    if name == "blueprint_run":
                                        self.assertEqual({"site": {"mode": "exact"}}, seen[-1]["contract"])
                            for name, args in [("audit", {"item": "iron-plate", "precision": "nope"}), ("brief", {"x": 1}),
                                               ("blueprint_import", {"file": "relative.txt", "x": 0, "y": 0})]:
                                before = len(seen)
                                result = await session.call_tool(name, args)
                                self.assertTrue(result.isError)
                                self.assertEqual(before, len(seen))
                            result = await session.call_tool("place", {"name": "locked", "x": 0, "y": 0})
                            self.assertTrue(result.isError)
                            self.assertEqual("technology-locked", json.loads(result.content[0].text)["error"])
                            # A read-only export must not overwrite an existing artifact.
                            result = await session.call_tool("blueprint_export", cases["blueprint_export"])
                            self.assertTrue(result.isError)
                            self.assertEqual("0fixture-blueprint\n", Path(export).read_text())
                            # Dead UDP peer produces a protocol-level tool error, not broken stdio.
                            await asyncio.to_thread(server.shutdown)
                            server.server_close()
                            result = await session.call_tool("ping", {})
                            self.assertTrue(result.isError)
        finally:
            await asyncio.to_thread(server.shutdown)
            server.server_close()
            thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
