"""Production cell: a row of identical machines between an input belt and an output belt.

Layout, top to bottom (x grows east, belts run east):

    y    belt B   (2nd ingredient alone, or 3rd-4th on lanes; long inserters reach it)
    +1   belt A   (1st ingredient alone, or 1st-2nd on lanes when there are 3-4)
    +2   input row: per machine [long | fast | pole]
    +3.. machines (w x h from the prototype)
    ..   output row: per machine [- | fast | pole]
    ..   output belt (products)

Without belt B the whole cell starts at y (belt A on y). Inserter direction = pickup side,
so every inserter is dir 0: picks from the north, drops south. One item per belt up to two
ingredients: an inserter takes from either lane, so a feed belt needs no lane planning.
"""
from __future__ import annotations

N, E = 0, 4


def cell(recipe: str, ingredients: list[dict], products: list[dict], machine: str,
         width: int, height: int, count: int, x: int, y: int,
         belt: str = "transport-belt", inserter: str = "fast-inserter",
         long_inserter: str = "long-handed-inserter",
         pole: str = "small-electric-pole", fuel: str | None = None) -> tuple[list[dict], dict]:
    """Return (design rows in world centers, ports). x,y = top-left tile of the cell.
    fuel: burner machine; rides belt A's second lane, the same inserter fuels it."""
    if count < 1:
        raise ValueError("cell-count-must-be-positive")
    for part in list(ingredients) + list(products):
        if part.get("type") == "fluid":
            # ponytail: solid-only cells; fluid needs the prototype's pipe connection
            # positions from spec, add when a fluid recipe gets its own cell.
            raise ValueError(f"cell-fluid-unsupported:{part['name']}")
    solids = [i["name"] for i in ingredients]
    if len(solids) > 4:
        raise ValueError(f"cell-too-many-ingredients:{len(solids)}")
    if fuel and len(solids) != 1:
        raise ValueError(f"cell-fuel-needs-one-ingredient:{len(solids)}")
    two_belts = len(solids) > 1
    if width < (3 if two_belts else 2):
        raise ValueError(f"cell-machine-too-narrow:{machine}")
    a_items, b_items = (solids[:1], solids[1:]) if len(solids) <= 2 else (solids[:2], solids[2:])
    if fuel:
        a_items = solids + [fuel]
    ins = 1.5 if width > 2 else 0.5  # 2-wide (furnace): [fast | pole]
    y_b = y if two_belts else None
    y_a = y + 1 if two_belts else y
    y_in, y_m = y_a + 1, y_a + 2
    y_out = y_m + height
    y_belt_out = y_out + 1
    rows = []

    def add(name, cx, cy, direction=N, **extra):
        rows.append({"name": name, "x": cx, "y": cy, "direction": direction, **extra})

    for i in range(count):
        left = x + i * width
        add(machine, left + width / 2, y_m + height / 2, recipe=recipe)
        if two_belts:
            add(long_inserter, left + 0.5, y_in + 0.5)
        add(inserter, left + ins, y_in + 0.5)
        add(pole, left + width - 0.5, y_in + 0.5)
        add(inserter, left + ins, y_out + 0.5)
        add(pole, left + width - 0.5, y_out + 0.5)
    length = count * width
    for belt_y in [b for b in (y_b, y_a, y_belt_out) if b is not None]:
        for k in range(length):
            add(belt, x + k + 0.5, belt_y + 0.5, E)
    ports = {
        # Two items on one belt (3-4 ingredients): list order = left (north) lane, right lane.
        "in_a": {"x": x + 0.5, "y": y_a + 0.5, "dir": E, "items": a_items},
        "out": {"x": x + length - 0.5, "y": y_belt_out + 0.5, "dir": E,
                "items": [p["name"] for p in products]},
        "box": [x, y, x + length, y_belt_out + 1],
    }
    if two_belts:
        ports["in_b"] = {"x": x + 0.5, "y": y_b + 0.5, "dir": E, "items": b_items}
    return rows, ports


if __name__ == "__main__":
    gear = [{"name": "iron-plate", "type": "item", "amount": 2}]
    rows, ports = cell("iron-gear-wheel", gear, [{"name": "iron-gear-wheel"}],
                       "assembling-machine-2", 3, 3, 2, 0, 0)
    taken = [(r["x"], r["y"]) for r in rows if r["name"] != "assembling-machine-2"]
    assert len(taken) == len(set(taken)), "overlap"
    assert ports["in_a"]["y"] == 0.5 and ports["out"]["y"] == 6.5, ports
    assert [r for r in rows if r["name"] == "assembling-machine-2"][1]["x"] == 4.5
    four = [{"name": n, "type": "item", "amount": 1} for n in "abcd"]
    rows, ports = cell("x", four, [{"name": "x"}], "assembling-machine-2", 3, 3, 1, 0, 0)
    assert ports["in_b"]["y"] == 0.5 and ports["in_a"]["y"] == 1.5 and ports["out"]["y"] == 7.5
    ore = [{"name": "iron-ore", "type": "item", "amount": 1}]
    rows, ports = cell("iron-plate", ore, [{"name": "iron-plate"}], "stone-furnace", 2, 2, 3,
                       0, 0, fuel="coal")
    taken = [(r["x"], r["y"]) for r in rows if r["name"] != "stone-furnace"]
    assert len(taken) == len(set(taken)), "furnace overlap"
    assert ports["in_a"]["items"] == ["iron-ore", "coal"] and "in_b" not in ports
    assert ports["out"] == {"x": 5.5, "y": 5.5, "dir": E, "items": ["iron-plate"]}, ports
    try:
        cell("x", [{"name": "water", "type": "fluid"}], [], "m", 3, 3, 1, 0, 0)
        raise AssertionError("fluid accepted")
    except ValueError:
        pass
    print("ok")
