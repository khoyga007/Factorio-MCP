"""Plan -> production chain: stack cells in a column, route a belt for every internal edge.

Each consumer gets its own producer cell (a product used twice is made twice), so every
edge is one belt from one `out` port to one `in` port and no splitter is ever needed.
A cell with 1-2 solid ingredients carries one item per belt, so a routed feed needs no lane
planning. What the chain cannot make itself stays an EXTERNAL input with a port the agent
feeds: fluids, recipes a cell refuses (2x2 furnaces, fluids), and ingredients of 3-4
ingredient cells (two items share a belt there: the agent brings it pre-merged).
"""
from __future__ import annotations

from math import ceil

E = 4


def chain(p: dict, cell_of, route, x: int, y: int, gap: int = 4) -> tuple[list[dict], dict]:
    """p = planner.plan(); cell_of(recipe, count, x, y) -> (rows, ports), ValueError if it
    cannot be a cell; route(frm, to, end_dir, avoid, planned_belts) -> belt rows."""
    producer = {}
    for row in p["rows"]:
        for item in row["out"]:
            if item not in row["surplus"]:
                producer[item] = row
    cells, edges, external = [], [], []
    cursor = [y]

    def place(item: str, rate: float) -> dict | None:
        row = producer.get(item)
        if row is None:
            return None
        share = rate / row["out"][item]
        count = max(1, ceil(row["exact_count"] * share - 1e-9))
        try:
            _, probe = cell_of(row["recipe"], count, 0, 0)
        except ValueError:
            return None
        belts = [probe[k]["items"] for k in ("in_a", "in_b") if k in probe]
        paired = any(len(items) > 1 for items in belts)
        children = {}
        for items in belts:
            for ing in items:
                child = None if paired else place(ing, row["in"][ing] * share)
                if child:
                    children[ing] = child
        rows, ports = cell_of(row["recipe"], count, x, cursor[0])
        cursor[0] = ports["box"][3] + gap
        node = {"recipe": row["recipe"], "count": count, "rows": rows, "ports": ports}
        cells.append(node)
        for key in ("in_a", "in_b"):
            port = ports.get(key)
            if not port:
                continue
            to = (port["x"] - 1, port["y"])
            ing = port["items"][0]
            if ing in children:
                out = children[ing]["ports"]["out"]
                edges.append({"item": ing, "from": (out["x"] + 1, out["y"]), "to": to})
            else:
                # A shared belt arrives pre-merged: `items` in lane order (left = north).
                external.append({"items": port["items"], "x": to[0], "y": to[1], "dir": E,
                                 "cell": row["recipe"],
                                 # Fuel is not a recipe input: None = rate unknown.
                                 "per_min": [row["in"][i] * share if i in row["in"] else None
                                             for i in port["items"]]})
        return node

    root = place(p["item"], p["per_min"])
    if root is None:
        raise ValueError(f"chain-root-not-a-cell:{p['item']}")
    avoid = [c["ports"]["box"] for c in cells]
    reserved = [e["from"] for e in edges] + [e["to"] for e in edges] + \
               [(ext["x"], ext["y"]) for ext in external]
    planned = [[r["x"], r["y"], r["direction"]] for c in cells for r in c["rows"]
               if "belt" in r["name"]]
    routed = []
    for e in edges:
        others = [[tx - 0.5, ty - 0.5, tx + 0.5, ty + 0.5] for tx, ty in reserved
                  if (tx, ty) not in (e["from"], e["to"])]
        rows = route(e["from"], e["to"], E, avoid + others, planned)
        routed += rows
        planned += [[r["x"], r["y"], r["direction"], r.get("type") == "input"] for r in rows
                    if r.get("direction") is not None]
    out = root["ports"]["out"]
    design = [r for c in reversed(cells) for r in c["rows"]] + routed
    return design, {"output": {"item": p["item"], "x": out["x"] + 1, "y": out["y"], "dir": E},
                    "external": external,
                    "cells": [{"recipe": c["recipe"], "count": c["count"],
                               "box": c["ports"]["box"]} for c in cells],
                    "edges": len(edges), "route_belts": len(routed)}


if __name__ == "__main__":
    from cells import cell
    recipes = {"gear": [{"name": "plate", "type": "item", "amount": 2}],
               "engine": [{"name": "gear", "type": "item", "amount": 1},
                          {"name": "pipe", "type": "item", "amount": 2}],
               "pipe": [{"name": "plate", "type": "item", "amount": 1}]}

    def cell_of(recipe, count, cx, cy):
        return cell(recipe, recipes[recipe], [{"name": recipe}], "asm", 3, 3, count, cx, cy)

    calls = []

    def route(frm, to, end_dir, avoid, planned):
        calls.append((frm, to, avoid, planned))
        return [{"name": "transport-belt", "x": frm[0] + 0.5, "y": frm[1] + 0.5, "direction": 4}]

    plan = {"item": "engine", "per_min": 10, "rows": [
        {"recipe": "engine", "out": {"engine": 10}, "surplus": {}, "exact_count": 0.5,
         "in": {"gear": 10, "pipe": 20}},
        {"recipe": "gear", "out": {"gear": 10}, "surplus": {}, "exact_count": 0.2, "in": {"plate": 20}},
        {"recipe": "pipe", "out": {"pipe": 20}, "surplus": {}, "exact_count": 0.1, "in": {"plate": 20}}]}
    design, ports = chain(plan, cell_of, route, 0, 0)
    assert [c["recipe"] for c in ports["cells"]] == ["gear", "pipe", "engine"], ports["cells"]
    assert ports["edges"] == 2 and len(calls) == 2
    assert [e["items"] for e in ports["external"]] == [["plate"], ["plate"]]
    boxes = [c["box"] for c in ports["cells"]]
    assert all(a[3] + 4 == b[1] for a, b in zip(boxes, boxes[1:])), boxes
    frm, to, avoid, planned = calls[0]
    assert to == (-0.5, boxes[2][1] + 1.5) and frm == (3.5, boxes[0][3] - 0.5), (frm, to)
    assert [a for a in avoid[3:] if a[0] + 0.5 == frm[0] and a[1] + 0.5 == frm[1]] == []
    print("ok")
