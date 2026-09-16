"""Pure capacity predictions for Factorio production plans.

All inputs come from a generated prototype spec. This module never calls the
game and deliberately contains no prototype constants.
"""

from __future__ import annotations

from dataclasses import dataclass

from spec_loader import Spec


TICKS_PER_SECOND = 60
ITEM_SPACING_TILES = 0.25


def mining_rate(
    mining_speed: float, mining_time: float, products_per_cycle: float = 1
) -> float:
    if mining_speed <= 0 or mining_time <= 0 or products_per_cycle <= 0:
        raise ValueError("mining inputs must be positive")
    return mining_speed / mining_time * products_per_cycle


def crafting_rate(
    crafting_speed: float, recipe_energy: float, products_per_craft: float = 1
) -> float:
    if crafting_speed <= 0 or recipe_energy <= 0 or products_per_craft <= 0:
        raise ValueError("crafting inputs must be positive")
    return crafting_speed / recipe_energy * products_per_craft


def belt_capacity(
    belt_speed: float,
    *,
    lanes: int = 2,
    item_spacing_tiles: float = ITEM_SPACING_TILES,
) -> float:
    if belt_speed <= 0 or lanes <= 0 or item_spacing_tiles <= 0:
        raise ValueError("belt inputs must be positive")
    return belt_speed * TICKS_PER_SECOND / item_spacing_tiles * lanes


def fuel_items_per_second(energy_usage_watts: float, fuel_value_joules: float) -> float:
    if energy_usage_watts <= 0 or fuel_value_joules <= 0:
        raise ValueError("fuel inputs must be positive")
    return energy_usage_watts / fuel_value_joules


@dataclass(frozen=True)
class Balance:
    source_rate: float
    consumer_capacity: float
    throughput: float
    surplus: float
    source_utilization: float
    consumer_utilization: float
    bottleneck: str


def balance(source_rate: float, consumer_capacity: float) -> Balance:
    if source_rate < 0 or consumer_capacity < 0:
        raise ValueError("rates cannot be negative")
    throughput = min(source_rate, consumer_capacity)
    surplus = source_rate - consumer_capacity
    if source_rate == consumer_capacity:
        bottleneck = "balanced"
    elif source_rate < consumer_capacity:
        bottleneck = "source"
    else:
        bottleneck = "consumer"
    return Balance(
        source_rate=source_rate,
        consumer_capacity=consumer_capacity,
        throughput=throughput,
        surplus=surplus,
        source_utilization=throughput / source_rate if source_rate else 0,
        consumer_utilization=(
            throughput / consumer_capacity if consumer_capacity else 0
        ),
        bottleneck=bottleneck,
    )


def mining_to_crafting_balance(
    *,
    miners: int,
    mining_speed: float,
    mining_time: float,
    furnaces: int,
    crafting_speed: float,
    recipe_energy: float,
    products_per_cycle: float = 1,
    products_per_craft: float = 1,
) -> Balance:
    if miners < 0 or furnaces < 0:
        raise ValueError("machine counts cannot be negative")
    source = miners * mining_rate(mining_speed, mining_time, products_per_cycle)
    consumer = furnaces * crafting_rate(
        crafting_speed, recipe_energy, products_per_craft
    )
    return balance(source, consumer)


def _require(value: float | None, label: str) -> float:
    if value is None:
        raise ValueError(f"spec missing {label}")
    return value


def mining_to_crafting_from_spec(
    spec: Spec,
    *,
    miner: str,
    recipe: str,
    furnace: str,
    miners: int,
    furnaces: int,
) -> Balance:
    """Predict a miner→furnace line straight from a loaded Spec.

    Numbers come from spec.json, never from hardcoded constants.
    """
    m = spec.entity(miner)
    r = spec.recipe(recipe)
    f = spec.entity(furnace)
    return mining_to_crafting_balance(
        miners=miners,
        mining_speed=_require(m.mining_speed, f"{miner}.mining_speed"),
        mining_time=_require(m.mining_time, f"{miner}.mining_time"),
        furnaces=furnaces,
        crafting_speed=_require(f.crafting_speed, f"{furnace}.crafting_speed"),
        recipe_energy=_require(r.energy, f"{recipe}.energy"),
    )


def belt_capacity_from_spec(spec: Spec, belt: str, *, lanes: int = 2) -> float:
    return belt_capacity(
        _require(spec.entity(belt).belt_speed, f"{belt}.belt_speed"), lanes=lanes
    )
