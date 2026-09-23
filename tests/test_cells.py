import runpy
from pathlib import Path

from cells import cell


ASM = [
    {"index": 1, "production_type": "input", "x": 0, "y": -2, "direction": 0},
    {"index": 2, "production_type": "output", "x": 0, "y": 2, "direction": 8},
]
CHEM = [
    {"index": 1, "production_type": "input", "x": -1, "y": -2, "direction": 0},
    {"index": 2, "production_type": "input", "x": 1, "y": -2, "direction": 0},
    {"index": 3, "production_type": "output", "x": -1, "y": 2, "direction": 8},
]
REFINERY = [
    {"index": 1, "production_type": "input", "x": -1, "y": 3, "direction": 8},
    {"index": 2, "production_type": "input", "x": 1, "y": 3, "direction": 8},
    {"index": 3, "production_type": "output", "x": -2, "y": -3, "direction": 0},
    {"index": 4, "production_type": "output", "x": 0, "y": -3, "direction": 0},
    {"index": 5, "production_type": "output", "x": 2, "y": -3, "direction": 0},
]


def _valid_geometry(rows):
    positions = [(row["x"], row["y"]) for row in rows]
    assert len(positions) == len(set(positions)), "entities overlap"
    ends = [row for row in rows if row["name"] == "pipe-to-ground"]
    assert len(ends) % 2 == 0
    for end in ends:
        partners = [other for other in ends if other is not end
                    and other["x"] == end["x"]
                    and 1 <= abs(other["y"] - end["y"]) <= 10
                    and other["direction"] == (end["direction"] + 8) % 16]
        assert partners, f"unpaired underground pipe {end}"


def _part(name, kind="item"):
    return {"name": name, "type": kind, "amount": 1}


def test_cells_self_check():
    runpy.run_path(str(Path(__file__).resolve().parent.parent / "cells.py"), run_name="__main__")


def test_mixed_assembler_two_solids_one_fluid():
    rows, ports = cell("processing-unit",
                       [_part("electronic-circuit"), _part("advanced-circuit"),
                        _part("sulfuric-acid", "fluid")], [_part("processing-unit")],
                       "assembling-machine-2", 3, 3, 2, -200, 100, fluid_ports=ASM)
    _valid_geometry(rows)
    assert ports["fluid_in"][0]["fluid"] == "sulfuric-acid"
    assert ports["fluid_in"][0]["kind"] == "pipe"
    assert ports["in_a"]["items"] == ["electronic-circuit"]
    assert ports["in_b"]["items"] == ["advanced-circuit"]
    assert len([row for row in rows if row["name"] == "pipe-to-ground"]) == 4


def test_chemical_plant_two_fluid_inputs_and_fluid_output():
    sulfur, ports = cell("sulfur", [_part("water", "fluid"),
                                    _part("petroleum-gas", "fluid")],
                         [_part("sulfur")], "chemical-plant", 3, 3, 2,
                         20, 40, fluid_ports=CHEM)
    _valid_geometry(sulfur)
    assert [p["fluid"] for p in ports["fluid_in"]] == ["water", "petroleum-gas"]
    lubricant, ports = cell("lubricant", [_part("heavy-oil", "fluid")],
                            [_part("lubricant", "fluid")], "chemical-plant", 3, 3,
                            2, 20, 40, fluid_ports=CHEM)
    _valid_geometry(lubricant)
    assert ports["fluid_out"][0]["fluid"] == "lubricant"
    assert "out" not in ports


def test_refinery_rotates_to_put_inputs_north_outputs_south():
    rows, ports = cell("advanced-oil-processing",
                       [_part("crude-oil", "fluid"), _part("water", "fluid")],
                       [_part("heavy-oil", "fluid"), _part("light-oil", "fluid"),
                        _part("petroleum-gas", "fluid")],
                       "oil-refinery", 5, 5, 1, 0, 0, fluid_ports=REFINERY)
    _valid_geometry(rows)
    assert next(row for row in rows if row["name"] == "oil-refinery")["direction"] == 8
    assert len(ports["fluid_in"]) == 2 and len(ports["fluid_out"]) == 3
