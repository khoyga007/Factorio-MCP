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


def _rotate(port: dict, direction: int) -> dict:
    px, py = port["x"], port["y"]
    for _ in range(direction // 4):
        px, py = -py, px
    return {**port, "x": px, "y": py, "direction": (port["direction"] + direction) % 16}


def _fluid_cell(recipe, ingredients, products, machine, width, height, count, x, y,
                belt, inserter, long_inserter, pole, fluid_ports):
    fluids_in = [part["name"] for part in ingredients if part.get("type") == "fluid"]
    fluids_out = [part["name"] for part in products if part.get("type") == "fluid"]
    solids = [part["name"] for part in ingredients if part.get("type") != "fluid"]
    solid_products = [part["name"] for part in products if part.get("type") != "fluid"]
    if len(solids) > 2:
        raise ValueError(f"cell-fluid-too-many-solids:{len(solids)}")

    chosen = None
    for direction in (N, 8, E, 12):
        if direction in (E, 12) and width != height:
            continue
        rotated = [_rotate(port, direction) for port in fluid_ports]
        inputs = [p for p in rotated if p["production_type"] in ("input", "input-output")
                  and p["direction"] == N and p["y"] == -(height + 1) / 2]
        outputs = [p for p in rotated if p["production_type"] in ("output", "input-output")
                   and p["direction"] == 8 and p["y"] == (height + 1) / 2]
        if len(inputs) >= len(fluids_in) and len(outputs) >= len(fluids_out):
            chosen = direction, inputs[:len(fluids_in)], outputs[:len(fluids_out)]
            break
    if chosen is None:
        raise ValueError(f"cell-fluid-ports:{machine}")
    direction, inputs, outputs = chosen
    for fluid, port in zip(fluids_in + fluids_out, inputs + outputs):
        if port.get("filter") and port["filter"] != fluid:
            raise ValueError(f"cell-fluid-filter:{fluid}")

    two_belts = len(solids) > 1
    belt_start = y + 2 * len(fluids_in)
    y_b = belt_start if two_belts else None
    y_a = belt_start + int(two_belts) if solids else None
    y_in = (y_a + 1) if solids else belt_start
    y_m = y_in + 1
    y_out = y_m + height
    y_belt_out = y_out + 1 if solid_products else None
    out_bus_start = y_out + (3 if solid_products else 2)
    length = count * width
    rows = []

    def add(name, cx, cy, facing=N, **extra):
        rows.append({"name": name, "x": cx, "y": cy, "direction": facing, **extra})

    for i in range(count):
        left = x + i * width
        center_x = left + width / 2
        add(machine, center_x, y_m + height / 2, direction, recipe=recipe)
        occupied_in = set()
        occupied_out = set()
        for j, port in enumerate(inputs):
            px = center_x + port["x"]
            occupied_in.add(px)
            add("pipe-to-ground", px, y_in + 0.5, 8)
            add("pipe-to-ground", px, y + 2 * j + 1.5, N)
        for j, port in enumerate(outputs):
            px = center_x + port["x"]
            occupied_out.add(px)
            add("pipe-to-ground", px, y_out + 0.5, N)
            add("pipe-to-ground", px, out_bus_start + 2 * j - 0.5, 8)
        slots = [left + k + 0.5 for k in range(width)]
        free_in = [sx for sx in slots if sx not in occupied_in]
        if two_belts:
            if len(free_in) < 2:
                raise ValueError(f"cell-fluid-inserter-space:{machine}")
            add(long_inserter, free_in[0], y_in + 0.5)
            add(inserter, free_in[-1], y_in + 0.5)
            free_in = free_in[1:-1]
        elif solids:
            if not free_in:
                raise ValueError(f"cell-fluid-inserter-space:{machine}")
            sx = min(free_in, key=lambda value: abs(value - center_x))
            add(inserter, sx, y_in + 0.5)
            free_in.remove(sx)
        free_out = [sx for sx in slots if sx not in occupied_out]
        if solid_products:
            if not free_out:
                raise ValueError(f"cell-fluid-output-space:{machine}")
            sx = min(free_out, key=lambda value: abs(value - center_x))
            add(inserter, sx, y_out + 0.5)
            free_out.remove(sx)
        pole_slots = free_out or free_in
        if pole_slots:
            add(pole, pole_slots[-1], (y_out if free_out else y_in) + 0.5)

    for belt_y in [b for b in (y_b, y_a, y_belt_out) if b is not None]:
        for k in range(length):
            add(belt, x + k + 0.5, belt_y + 0.5, E)
    for bus_y in [y + 2 * j for j in range(len(inputs))] + [
            out_bus_start + 2 * j for j in range(len(outputs))]:
        for k in range(length):
            add("pipe", x + k + 0.5, bus_y + 0.5)

    ports = {"box": [x, y, x + length,
                     max(y_belt_out + 1 if y_belt_out is not None else y_out + 1,
                         out_bus_start + 2 * (len(outputs) - 1) + 1 if outputs else 0)],
             "fluid_in": [{"kind": "pipe", "x": x + 0.5, "y": y + 2 * j + 0.5,
                           "fluid": fluid} for j, fluid in enumerate(fluids_in)],
             "fluid_out": [{"kind": "pipe", "x": x + length - 0.5,
                            "y": out_bus_start + 2 * j + 0.5, "fluid": fluid}
                           for j, fluid in enumerate(fluids_out)]}
    if solids:
        ports["in_a"] = {"x": x + 0.5, "y": y_a + 0.5, "dir": E, "items": solids[:1]}
        if two_belts:
            ports["in_b"] = {"x": x + 0.5, "y": y_b + 0.5, "dir": E, "items": solids[1:]}
    if solid_products:
        ports["out"] = {"x": x + length - 0.5, "y": y_belt_out + 0.5,
                        "dir": E, "items": solid_products}
    return rows, ports


def cell(recipe: str, ingredients: list[dict], products: list[dict], machine: str,
         width: int, height: int, count: int, x: int, y: int,
         belt: str = "transport-belt", inserter: str = "fast-inserter",
         long_inserter: str = "long-handed-inserter",
         pole: str = "small-electric-pole", fuel: str | None = None,
         fluid_ports: list[dict] | None = None) -> tuple[list[dict], dict]:
    """Return (design rows in world centers, ports). x,y = top-left tile of the cell.
    fuel: burner machine; rides belt A's second lane, the same inserter fuels it."""
    if count < 1:
        raise ValueError("cell-count-must-be-positive")
    if any(part.get("type") == "fluid" for part in list(ingredients) + list(products)):
        if fuel:
            raise ValueError("cell-fluid-fuel-unsupported")
        if width < 3:
            raise ValueError(f"cell-machine-too-narrow:{machine}")
        return _fluid_cell(recipe, ingredients, products, machine, width, height,
                           count, x, y, belt, inserter, long_inserter, pole,
                           fluid_ports or [])
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
