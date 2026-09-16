"""Load the machine-readable prototype spec (spec.json).

The schema mirrors exactly the fields ``handle_spec`` returns in
``factorio-ai-bridge_0.1.0/control.lua`` (lines 870-933): entity, item and
recipe prototype numbers. This is the one place ``factorio_model.py`` reads
prototype numbers from, so no constant is hardcoded in the model.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1

# Fields handle_spec returns per kind, in control.lua:870-933. Everything else
# (action, kind, name, v, nonce, ok, error) is transport metadata and is dropped.
_ENTITY_FIELDS = (
    "entity_type",
    "mining_speed",
    "crafting_speed",
    "belt_speed",
    "energy_usage_joules_per_tick",
    "energy_usage_watts",
    "burner_effectivity",
    "tile_width",
    "tile_height",
    "mining_time",
    "mining_products",
)
_ITEM_FIELDS = ("fuel_value_joules", "fuel_category", "stack_size")
_RECIPE_FIELDS = ("category", "energy", "ingredients", "products")


@dataclass(frozen=True)
class EntitySpec:
    entity_type: str | None = None
    mining_speed: float | None = None
    crafting_speed: float | None = None
    belt_speed: float | None = None
    energy_usage_joules_per_tick: float | None = None
    energy_usage_watts: float | None = None
    burner_effectivity: float | None = None
    tile_width: int | None = None
    tile_height: int | None = None
    mining_time: float | None = None
    mining_products: tuple[dict[str, Any], ...] = ()


@dataclass(frozen=True)
class ItemSpec:
    fuel_value_joules: float | None = None
    fuel_category: str | None = None
    stack_size: int | None = None


@dataclass(frozen=True)
class RecipeSpec:
    category: str | None = None
    energy: float | None = None
    ingredients: tuple[dict[str, Any], ...] = ()
    products: tuple[dict[str, Any], ...] = ()


@dataclass(frozen=True)
class Spec:
    entities: dict[str, EntitySpec] = field(default_factory=dict)
    items: dict[str, ItemSpec] = field(default_factory=dict)
    recipes: dict[str, RecipeSpec] = field(default_factory=dict)

    def entity(self, name: str) -> EntitySpec:
        return self.entities[name]

    def item(self, name: str) -> ItemSpec:
        return self.items[name]

    def recipe(self, name: str) -> RecipeSpec:
        return self.recipes[name]


def entity_fields(reply: dict[str, Any]) -> dict[str, Any]:
    """Keep only prototype fields from a live ``spec`` reply for an entity."""
    return {k: reply[k] for k in _ENTITY_FIELDS if k in reply}


def item_fields(reply: dict[str, Any]) -> dict[str, Any]:
    return {k: reply[k] for k in _ITEM_FIELDS if k in reply}


def recipe_fields(reply: dict[str, Any]) -> dict[str, Any]:
    return {k: reply[k] for k in _RECIPE_FIELDS if k in reply}


def _entity_from_dict(d: dict[str, Any]) -> EntitySpec:
    return EntitySpec(
        entity_type=d.get("entity_type"),
        mining_speed=d.get("mining_speed"),
        crafting_speed=d.get("crafting_speed"),
        belt_speed=d.get("belt_speed"),
        energy_usage_joules_per_tick=d.get("energy_usage_joules_per_tick"),
        energy_usage_watts=d.get("energy_usage_watts"),
        burner_effectivity=d.get("burner_effectivity"),
        tile_width=d.get("tile_width"),
        tile_height=d.get("tile_height"),
        mining_time=d.get("mining_time"),
        mining_products=tuple(d.get("mining_products") or ()),
    )


def _item_from_dict(d: dict[str, Any]) -> ItemSpec:
    return ItemSpec(
        fuel_value_joules=d.get("fuel_value_joules"),
        fuel_category=d.get("fuel_category"),
        stack_size=d.get("stack_size"),
    )


def _recipe_from_dict(d: dict[str, Any]) -> RecipeSpec:
    return RecipeSpec(
        category=d.get("category"),
        energy=d.get("energy"),
        ingredients=tuple(d.get("ingredients") or ()),
        products=tuple(d.get("products") or ()),
    )


def load_spec(path: str | Path) -> Spec:
    """Read spec.json into a Spec. Raises ValueError on a schema mismatch."""
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    if data.get("schema_version") != SCHEMA_VERSION:
        raise ValueError(
            f"spec schema_version {data.get('schema_version')!r} != {SCHEMA_VERSION}"
        )
    return Spec(
        entities={
            k: _entity_from_dict(v) for k, v in data.get("entities", {}).items()
        },
        items={k: _item_from_dict(v) for k, v in data.get("items", {}).items()},
        recipes={k: _recipe_from_dict(v) for k, v in data.get("recipes", {}).items()},
    )
