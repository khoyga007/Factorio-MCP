"""Tiny UDP client for the Factorio AI Bridge mod."""

from __future__ import annotations

import argparse
import json
import secrets
import socket
import sys
import time
from typing import Any


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
        f"Factorio did not answer on UDP {host}:{port}; "
        "start it with --enable-lua-udp and load a map"
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

    brief = commands.add_parser("brief", help="one-call survey: base counts, machine issues, nearby enemies, ore patches, nearest water, treasury")
    brief.add_argument("--surface", default="nauvis")
    brief.add_argument("--x", type=float)
    brief.add_argument("--y", type=float)
    brief.add_argument("--radius", type=float, default=32)

    index = commands.add_parser("index", help="whole-map survey index: ore patches, enemy clusters, water (cached)")
    index.add_argument("--surface", default="nauvis")

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

    fuel = commands.add_parser("fuel")
    fuel.add_argument("item")
    fuel.add_argument("count", type=int)
    fuel.add_argument("x", type=float)
    fuel.add_argument("y", type=float)
    fuel.add_argument("--surface", default="nauvis")
    fuel.add_argument("--force", default="player")

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

    autofuel = commands.add_parser("autofuel")
    autofuel.add_argument("state", choices=("on", "off"))

    tiles = commands.add_parser(
        "tiles", help="map tiles; by default every tile an offshore pump can use"
    )
    tiles.add_argument("--surface", default="nauvis")
    tiles.add_argument("--x", type=float)
    tiles.add_argument("--y", type=float)
    tiles.add_argument("--radius", type=float, default=32)
    tiles.add_argument(
        "--name",
        action="append",
        help="tile prototype name, repeatable; omit to list pumpable water",
    )

    probe = commands.add_parser("probe", help="dry run a placement, build nothing")
    probe.add_argument("name")
    probe.add_argument("x", type=float)
    probe.add_argument("y", type=float)
    probe.add_argument("--surface", default="nauvis")
    probe.add_argument("--force", default="player")
    probe.add_argument(
        "--direction", choices=("north", "east", "south", "west"), default="north"
    )

    recipe = commands.add_parser("recipe", help="read a recipe and what it needs")
    recipe.add_argument("name", nargs="?")
    recipe.add_argument("--entity", help="resolve the recipe of the item that places this entity")
    recipe.add_argument("--force", default="player")
    spec = commands.add_parser("spec", help="read one running-game prototype")
    spec.add_argument("kind", choices=("entity", "item", "recipe"))
    spec.add_argument("name")
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
    insert = commands.add_parser("insert", help="move real items into a lab, assembler, or ammo turret")
    insert.add_argument("item")
    insert.add_argument("count", type=int)
    insert.add_argument("x", type=float)
    insert.add_argument("y", type=float)
    insert.add_argument("--surface", default="nauvis")
    insert.add_argument("--force", default="player")
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
    if args.command == "treasury":
        return {
            "action": "set_treasury",
            "surface": args.surface,
            "x": args.x,
            "y": args.y,
        }
    if args.command == "fuel":
        return {
            "action": "fuel",
            "item": args.item,
            "count": args.count,
            "surface": args.surface,
            "force": args.force,
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
        return {
            "action": "collect",
            "item": args.item,
            "count": args.count,
            "surface": args.surface,
            "x": args.x,
            "y": args.y,
        }
    if args.command == "autofuel":
        return {"action": "autofuel", "enabled": args.state == "on"}
    if args.command == "tiles":
        tiles: dict[str, Any] = {
            "action": "tiles",
            "surface": args.surface,
            "radius": args.radius,
        }
        if args.name:
            tiles["name"] = args.name
        if args.x is not None and args.y is not None:
            tiles.update(x=args.x, y=args.y)
        elif args.x is not None or args.y is not None:
            raise ValueError("--x and --y must be supplied together")
        return tiles
    if args.command == "probe":
        return {
            "action": "probe",
            "name": args.name,
            "surface": args.surface,
            "force": args.force,
            "x": args.x,
            "y": args.y,
            "direction": args.direction,
        }
    if args.command == "recipe":
        if not args.name and not args.entity:
            raise ValueError("recipe needs a name or --entity")
        body = {"action": "recipe", "force": args.force}
        if args.name:
            body["name"] = args.name
        if args.entity:
            body["entity"] = args.entity
        return body
    if args.command == "spec":
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
        }
    return {
        "action": "place",
        "name": args.name,
        "surface": args.surface,
        "force": args.force,
        "x": args.x,
        "y": args.y,
        "direction": args.direction,
    }


def main() -> int:
    args = parser().parse_args()
    try:
        reply = request(command_body(args), host=args.host, port=args.port)
    except (OSError, ValueError, TimeoutError, json.JSONDecodeError) as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False))
        return 1
    if args.command == "audit" and reply.get("ok"):
        actual = reply["produced_per_minute"] / 60
        reply["produced_per_second"] = actual
        if args.expected_per_second is not None:
            reply["expected_per_second"] = args.expected_per_second
            reply["delta_per_second"] = actual - args.expected_per_second
    print(json.dumps(reply, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if reply.get("ok") else 2


if __name__ == "__main__":
    raise SystemExit(main())
