"""Tiny UDP client for the Factorio AI Bridge mod."""

from __future__ import annotations

import argparse
import json
import secrets
import socket
import sys
import time
from pathlib import Path
from typing import Any

from blueprint_library import artifact_blueprint, record_blueprint


DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 34198


def request(
    body: dict[str, Any],
    *,
    host: str = DEFAULT_HOST,
    port: int = DEFAULT_PORT,
    timeout: float = 1.0,
    retries: int = 3,
    nonce: str | None = None,
) -> dict[str, Any]:
    packet = {"v": 1, "nonce": nonce or secrets.token_hex(12), **body}
    encoded = json.dumps(packet, ensure_ascii=False, separators=(",", ":")).encode()
    if len(encoded) > 32768:
        raise ValueError("request is larger than 32768 bytes")

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind((DEFAULT_HOST, 0))
        for _ in range(retries):
            sock.sendto(encoded, (host, port))
            deadline = time.monotonic() + timeout
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                sock.settimeout(remaining)
                try:
                    data, _ = sock.recvfrom(65535)
                except TimeoutError:
                    break
                reply = json.loads(data)
                if reply.get("nonce") == packet["nonce"]:
                    return reply
    raise TimeoutError(
        f"Factorio did not answer on UDP {host}:{port} within {timeout}s x{retries}; "
        "the engine may be busy on a whole-map scan rather than absent -- check ping "
        "before restarting it with --enable-lua-udp and a loaded map"
    )


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    root.add_argument("--host", default=DEFAULT_HOST)
    root.add_argument("--port", type=int, default=DEFAULT_PORT)
    commands = root.add_subparsers(dest="command", required=True)

    commands.add_parser("ping")

    scan = commands.add_parser("snapshot")
    scan.add_argument("--surface", default="nauvis")
    scan.add_argument("--x", type=float)
    scan.add_argument("--y", type=float)
    scan.add_argument("--radius", type=float, default=16)
    scan.add_argument("--offset", type=int, default=0)
    scan.add_argument("--limit", type=int, default=64)
    scan.add_argument("--tiles", action="store_true", help="also map tiles (default pumpable water)")
    scan.add_argument("--obstacles", action="store_true", help="also page natural trees, rocks and cliffs")
    scan.add_argument("--name", action="append", help="tile prototype name, repeatable; only with --tiles")

    brief = commands.add_parser("brief", help="one-call survey: base counts, machine issues, nearby enemies, ore patches, nearest water, treasury")
    brief.add_argument("--surface", default="nauvis")
    brief.add_argument("--x", type=float)
    brief.add_argument("--y", type=float)
    brief.add_argument("--radius", type=float, default=32)

    index = commands.add_parser("index", help="whole-map survey index: ore patches, enemy clusters, water (cached)")
    index.add_argument("--surface", default="nauvis")

    ore_marks = commands.add_parser("ore-marks", help="saved ore sectors, including depleted ones")
    ore_marks.add_argument("--surface", default="nauvis")
    ore_marks.add_argument("--name")
    ore_marks.add_argument("--offset", type=int, default=0)
    ore_marks.add_argument("--limit", type=int, default=50)

    chest = commands.add_parser("treasury")
    chest.add_argument("x", type=float)
    chest.add_argument("y", type=float)
    chest.add_argument("--surface", default="nauvis")

    place = commands.add_parser("place")
    place.add_argument("name")
    place.add_argument("x", type=float)
    place.add_argument("y", type=float)
    place.add_argument("--surface", default="nauvis")
    place.add_argument("--force", default="player")
    place.add_argument(
        "--direction", choices=("north", "east", "south", "west"), default="north"
    )
    place.add_argument("--dry-run", action="store_true", help="report every blocker, build nothing")
    place.add_argument("--type", choices=("input", "output"), help="underground-belt endpoint type only")

    craft = commands.add_parser("craft")
    craft.add_argument("recipe")
    craft.add_argument("count", type=int, nargs="?", default=1)

    mine = commands.add_parser("mine")
    mine.add_argument("name")
    mine.add_argument("x", type=float)
    mine.add_argument("y", type=float)
    mine.add_argument("--surface", default="nauvis")

    collect = commands.add_parser("collect", help="take real items from a chest or machine output")
    collect.add_argument("item")
    collect.add_argument("count", type=int)
    collect.add_argument("x", type=float)
    collect.add_argument("y", type=float)
    collect.add_argument("--surface", default="nauvis")
    collect.add_argument("--ground", action="store_true", help="pick a ground stack even if a machine occupies the same position")

    autofuel = commands.add_parser("autofuel")
    autofuel.add_argument("state", choices=("on", "off"))

    spec = commands.add_parser("spec", help="read one running-game prototype (recipe is force-level)")
    spec.add_argument("kind", choices=("entity", "item", "recipe"))
    spec.add_argument("name", nargs="?")
    spec.add_argument("--entity", help="resolve the recipe of the item that places this entity")
    spec.add_argument("--force", default="player")
    audit = commands.add_parser("audit", help="read measured item flow")
    audit.add_argument("item")
    audit.add_argument("--surface", default="nauvis")
    audit.add_argument("--force", default="player")
    audit.add_argument(
        "--precision",
        choices=("five_seconds", "one_minute", "ten_minutes", "one_hour"),
        default="one_minute",
    )
    audit.add_argument("--expected-per-second", type=float)
    set_recipe = commands.add_parser("set-recipe", help="commission an empty assembler")
    set_recipe.add_argument("recipe")
    set_recipe.add_argument("x", type=float)
    set_recipe.add_argument("y", type=float)
    set_recipe.add_argument("--surface", default="nauvis")
    set_recipe.add_argument("--force", default="player")
    research = commands.add_parser("research", help="inspect or start technology research")
    research.add_argument("name", nargs="?")
    research.add_argument("--start", action="store_true")
    research.add_argument("--force", default="player")
    insert = commands.add_parser("insert", help="move real items into a lab, assembler, ammo turret, or furnace (fuel by default; --source for its ingredient slot)")
    insert.add_argument("item")
    insert.add_argument("count", type=int)
    insert.add_argument("x", type=float)
    insert.add_argument("y", type=float)
    insert.add_argument("--surface", default="nauvis")
    insert.add_argument("--force", default="player")
    insert.add_argument("--source", action="store_true", help="insert into a furnace's ingredient (source) slot instead of its fuel slot")

    bp_export = commands.add_parser("blueprint-export", help="export a built area to a Factorio blueprint string file")
    bp_export.add_argument("x1", type=float)
    bp_export.add_argument("y1", type=float)
    bp_export.add_argument("x2", type=float)
    bp_export.add_argument("y2", type=float)
    bp_export.add_argument("file", type=Path)
    bp_export.add_argument("--surface", default="nauvis")
    bp_export.add_argument("--force", default="player")

    bp_import = commands.add_parser("blueprint-import", help="build blueprint directly with treasury items")
    bp_import.add_argument("file", type=Path)
    bp_import.add_argument("x", type=float)
    bp_import.add_argument("y", type=float)
    bp_import.add_argument("--surface", default="nauvis")
    bp_import.add_argument("--force", default="player")
    bp_import.add_argument("--ghosts", action="store_true", help="place ghosts for construction robots instead")
    bp_import.add_argument("--direction", type=int, choices=(0, 4, 8, 12), default=0)
    bp_run = commands.add_parser("blueprint-run", help="generic executor: contract-driven site search, gather, build, audit")
    bp_run.add_argument("file", type=Path)
    bp_run.add_argument("--contract", type=Path, help="JSON contract file (site/resources/primer/feeds/verify)")
    bp_run.add_argument("--pattern-id")
    bp_run.add_argument("--x", type=float)
    bp_run.add_argument("--y", type=float)
    bp_run.add_argument("--radius", type=float, default=192)
    bp_run.add_argument("--surface", default="nauvis")
    bp_run.add_argument("--force", default="player")
    bp_run.add_argument("--dry-run", action="store_true")
    bp_job = commands.add_parser("blueprint-job")
    bp_job.add_argument("job_id")

    smelt = commands.add_parser("smelt-plan", help="size, site and preflight one reusable iron-smelting row")
    smelt.add_argument("rate", type=float, help="target iron plates per minute")
    smelt.add_argument("--surface", default="nauvis")
    smelt.add_argument("--force", default="player")
    smelt.add_argument("--x", type=float)
    smelt.add_argument("--y", type=float)
    smelt.add_argument("--input-x", type=float)
    smelt.add_argument("--input-y", type=float)
    smelt_build = commands.add_parser("smelt-build")
    smelt_build.add_argument("plan_id")
    smelt_status = commands.add_parser("smelt-status")
    smelt_status.add_argument("plan_id")
    starter = commands.add_parser("starter-smelt", help="bootstrap real coal, then feed a stone furnace from one burner drill")
    starter.add_argument("product", choices=("iron-plate", "copper-plate"), nargs="?", default="iron-plate")
    starter.add_argument("--x", type=float)
    starter.add_argument("--y", type=float)
    starter.add_argument("--radius", type=float, default=192)
    starter.add_argument("--surface", default="nauvis")
    starter.add_argument("--force", default="player")
    starter.add_argument("--dry-run", action="store_true")
    starter_status = commands.add_parser("starter-status")
    starter_status.add_argument("job_id")
    coal = commands.add_parser("coal-stockpile", help="build one real-coal burner drill and chest cell")
    coal.add_argument("--x", type=float)
    coal.add_argument("--y", type=float)
    coal.add_argument("--radius", type=float, default=192)
    coal.add_argument("--surface", default="nauvis")
    coal.add_argument("--force", default="player")
    coal.add_argument("--dry-run", action="store_true")
    coal_status = commands.add_parser("coal-status")
    coal_status.add_argument("job_id")
    repair = commands.add_parser("repair-demo-economy", help="one-time Sandbox coal-demo ingredient correction")
    repair.add_argument("key")
    return root


def command_body(args: argparse.Namespace) -> dict[str, Any]:
    if args.command == "ping":
        return {"action": "ping"}
    if args.command == "snapshot":
        body: dict[str, Any] = {
            "action": "snapshot",
            "surface": args.surface,
            "radius": args.radius,
            "offset": args.offset,
            "limit": args.limit,
        }
        if args.tiles:
            body["tiles"] = True
            if args.name:
                body["name"] = args.name
        if args.obstacles:
            body["obstacles"] = True
        if args.x is not None and args.y is not None:
            body.update(x=args.x, y=args.y)
        elif args.x is not None or args.y is not None:
            raise ValueError("--x and --y must be supplied together")
        return body
    if args.command == "brief":
        body = {"action": "brief", "surface": args.surface, "radius": args.radius}
        if args.x is not None and args.y is not None:
            body.update(x=args.x, y=args.y)
        elif args.x is not None or args.y is not None:
            raise ValueError("--x and --y must be supplied together")
        return body
    if args.command == "index":
        return {"action": "index", "surface": args.surface}
    if args.command == "ore-marks":
        body = {
            "action": "ore_marks", "surface": args.surface,
            "offset": args.offset, "limit": args.limit,
        }
        if args.name:
            body["name"] = args.name
        return body
    if args.command == "treasury":
        return {
            "action": "set_treasury",
            "surface": args.surface,
            "x": args.x,
            "y": args.y,
        }
    if args.command == "craft":
        return {"action": "craft", "recipe": args.recipe, "count": args.count}
    if args.command == "mine":
        return {
            "action": "mine",
            "name": args.name,
            "surface": args.surface,
            "x": args.x,
            "y": args.y,
        }
    if args.command == "collect":
        body = {
            "action": "collect",
            "item": args.item,
            "count": args.count,
            "surface": args.surface,
            "x": args.x,
            "y": args.y,
        }
        if args.ground:
            body["ground"] = True
        return body
    if args.command == "autofuel":
        return {"action": "autofuel", "enabled": args.state == "on"}
    if args.command == "spec":
        if args.kind == "recipe":
            if not args.name and not args.entity:
                raise ValueError("spec recipe needs a name or --entity")
            body = {"action": "spec", "kind": args.kind, "force": args.force}
            if args.name:
                body["name"] = args.name
            if args.entity:
                body["entity"] = args.entity
            return body
        if not args.name:
            raise ValueError("spec needs a prototype name")
        return {"action": "spec", "kind": args.kind, "name": args.name}
    if args.command == "audit":
        return {
            "action": "audit", "item": args.item, "surface": args.surface,
            "force": args.force, "precision": args.precision,
        }
    if args.command == "set-recipe":
        return {
            "action": "set_recipe", "recipe": args.recipe,
            "x": args.x, "y": args.y, "surface": args.surface, "force": args.force,
        }
    if args.command == "research":
        if args.start and not args.name:
            raise ValueError("research --start needs a technology name")
        body = {"action": "research", "force": args.force}
        if args.name:
            body["name"] = args.name
        if args.start:
            body["start"] = True
        return body
    if args.command == "insert":
        return {
            "action": "insert", "item": args.item, "count": args.count,
            "x": args.x, "y": args.y, "surface": args.surface, "force": args.force,
            "source": args.source,
        }
    if args.command == "blueprint-export":
        return {
            "action": "blueprint_export", "x1": args.x1, "y1": args.y1,
            "x2": args.x2, "y2": args.y2, "surface": args.surface, "force": args.force,
        }
    if args.command == "blueprint-import":
        return {
            "action": "blueprint_import", "blueprint": args.file.read_text(encoding="ascii").strip(),
            "x": args.x, "y": args.y, "surface": args.surface, "force": args.force,
            "mode": "ghosts" if args.ghosts else "direct",
            "direction": getattr(args, "direction", 0),
        }
    if args.command == "blueprint-run":
        if (args.x is None) != (args.y is None):
            raise ValueError("x and y must be supplied together")
        body = {"action": "blueprint_run", "blueprint": args.file.read_text(encoding="ascii").strip(),
                "radius": args.radius, "surface": args.surface, "force": args.force}
        if isinstance(args.contract, Path):
            body["contract"] = json.loads(args.contract.read_text(encoding="utf-8"))
        elif args.contract is not None:
            body["contract"] = args.contract
        if args.pattern_id:
            body["pattern_id"] = args.pattern_id
        if args.x is not None:
            body.update(x=args.x, y=args.y)
        if args.dry_run:
            body["dry_run"] = True
        return body
    if args.command == "blueprint-job":
        return {"action": "blueprint_job", "job_id": args.job_id}
    if args.command == "smelt-plan":
        body = {"action": "smelt_plan", "rate": args.rate,
                "surface": args.surface, "force": args.force}
        for x_key, y_key in (("x", "y"), ("input_x", "input_y")):
            x_value, y_value = getattr(args, x_key), getattr(args, y_key)
            if (x_value is None) != (y_value is None):
                raise ValueError(f"{x_key} and {y_key} must be supplied together")
            if x_value is not None:
                body[x_key], body[y_key] = x_value, y_value
        return body
    if args.command == "smelt-build":
        return {"action": "smelt_build", "plan_id": args.plan_id}
    if args.command == "smelt-status":
        return {"action": "smelt_status", "plan_id": args.plan_id}
    if args.command == "starter-smelt":
        if (args.x is None) != (args.y is None):
            raise ValueError("x and y must be supplied together")
        body = {"action": "starter_smelt", "product": args.product,
                "radius": args.radius, "surface": args.surface, "force": args.force}
        if args.x is not None:
            body.update(x=args.x, y=args.y)
        if args.dry_run:
            body["dry_run"] = True
        return body
    if args.command == "starter-status":
        return {"action": "starter_status", "job_id": args.job_id}
    if args.command == "coal-stockpile":
        if (args.x is None) != (args.y is None):
            raise ValueError("x and y must be supplied together")
        body = {"action": "coal_stockpile", "radius": args.radius,
                "surface": args.surface, "force": args.force}
        if args.x is not None:
            body.update(x=args.x, y=args.y)
        if args.dry_run:
            body["dry_run"] = True
        return body
    if args.command == "coal-status":
        return {"action": "coal_status", "job_id": args.job_id}
    if args.command == "repair-demo-economy":
        return {"action": "repair_demo_economy", "key": args.key}
    if args.command == "place":
        body = {
            "action": "place",
            "name": args.name,
            "surface": args.surface,
            "force": args.force,
            "x": args.x,
            "y": args.y,
            "direction": args.direction,
        }
        if args.dry_run:
            body["dry_run"] = True
        if args.type is not None:
            body["type"] = args.type
        return body
    raise ValueError(f"unknown command: {args.command}")


def execute(args: argparse.Namespace) -> dict[str, Any]:
    """Shared CLI/MCP execution: one UDP operation and the same local artifacts."""
    # ore-marks rides the same whole-map index as `index`: handle_ore_marks calls
    # get_index (control.lua:1639), which rebuilds whenever the cache is older
    # than INDEX_TTL_TICKS = 600 (control.lua:1507, ~10 s of game time). Measured
    # on the live save 2026-09-17: a cold build takes ~4.1 s, so the 1.0 s x3
    # window expired first and every cold ore-marks call reported "did not answer"
    # while the engine was healthy and answering ping/index.
    timeout = 15.0 if args.command in {"smelt-plan", "smelt-build", "starter-smelt", "coal-stockpile", "index", "ore-marks", "blueprint-run"} else 1.0
    body = command_body(args)
    reply = request(body, host=args.host, port=args.port, timeout=timeout)
    if args.command == "audit" and reply.get("ok"):
        actual = reply["produced_per_minute"] / 60
        reply["produced_per_second"] = actual
        if args.expected_per_second is not None:
            reply["expected_per_second"] = args.expected_per_second
            reply["delta_per_second"] = actual - args.expected_per_second
    if args.command == "blueprint-export" and reply.get("ok"):
        blueprint = reply.pop("blueprint")
        with args.file.open("x", encoding="ascii") as output:
            output.write(blueprint + "\n")
        reply["file"] = str(args.file.resolve())
        try:
            reply["pattern"] = record_blueprint(blueprint, state="captured",
                                                  source="blueprint-export")
        except (OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
            reply["catalog_error"] = str(exc)
    if args.command == "blueprint-import" and reply.get("ok") and not args.ghosts:
        try:
            reply["pattern"] = record_blueprint(body["blueprint"], state="built",
                                                  source="blueprint-import",
                                                  materials=reply.get("spent"))
        except (OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
            reply["catalog_error"] = str(exc)
    if args.command in {"starter-status", "coal-status", "smelt-status", "blueprint-job"} \
       and reply.get("ok") and reply.get("state") == "verified" \
       and (reply.get("audit") or {}).get("status") == "passed" \
       and reply.get("artifact"):
        # A layout that only passed because the executor fed it is built, not verified.
        state = "verified" if self_sustaining(reply["audit"]) else "built"
        try:
            reply["pattern"] = record_blueprint(
                artifact_blueprint(reply["artifact"]), state=state,
                source=args.command, audit=reply["audit"])
        except (OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
            reply["catalog_error"] = str(exc)
    return reply


def self_sustaining(audit: dict) -> bool:
    """False when the executor's declared feed still moved items in the deciding (last) window."""
    last = audit.get("last") or (audit.get("windows") or [{}])[-1]
    return not (last.get("feed_moved") or 0)


def main() -> int:
    args = parser().parse_args()
    try:
        reply = execute(args)
    except (OSError, ValueError, TimeoutError, json.JSONDecodeError) as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False))
        return 1
    print(json.dumps(reply, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if reply.get("ok") else 2


if __name__ == "__main__":
    raise SystemExit(main())
