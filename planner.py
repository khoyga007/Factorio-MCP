"""Nominal recipe-tree rates from Factorio prototype data."""

from __future__ import annotations

from collections import defaultdict
from math import ceil, isfinite
import os

from factorio_model import belt_capacity_from_spec, crafting_rate, mining_rate
from spec_loader import (SCHEMA_VERSION, Spec, entity_fields, recipe_fields,
                         spec_from_dict)


BELTS = ("transport-belt", "fast-transport-belt", "express-transport-belt")


def _amount(row: dict) -> float:
    amount = row.get("amount")
    if amount is None:
        lo, hi = row.get("amount_min"), row.get("amount_max")
        if lo is None or hi is None:
            raise ValueError(f"missing product amount: {row.get('name')}")
        amount = (lo + hi) / 2
    return amount * row.get("probability", 1)


def _cost(spec: Spec, name: str) -> float:
    recipe = spec.recipes.get(name)
    if recipe is None or recipe.enabled is False:
        return float("inf")
    return sum(row["amount"] for row in recipe.ingredients)


def _machine(spec: Spec, category: str, candidates: tuple[str, ...], overrides: dict) -> str:
    selected = overrides.get(category)
    if selected:
        candidates = (selected,)
    elif not candidates:
        candidates = tuple(name for name, entity in spec.entities.items()
                           if category in entity.crafting_categories)
    eligible = [(name, spec.entities[name]) for name in candidates if name in spec.entities
                and (not spec.entities[name].crafting_categories
                     or category in spec.entities[name].crafting_categories)]
    if not eligible:
        raise ValueError(f"no machine for crafting category {category}; pass machines={{'{category}': name}}")
    return min(eligible, key=lambda pair: (_cost(spec, pair[0]),
                                            pair[1].energy_usage_watts or float("inf"),
                                            pair[0]))[0]


def _raw_source(spec: Spec, name: str, kind: str, rate: float, overrides: dict) -> dict:
    resource = spec.entities.get(name)
    if kind == "fluid" and (resource is None or not resource.miners):
        pump_name = overrides.get(f"pump:{name}", "offshore-pump" if name == "water" else None)
        pump = spec.entities.get(pump_name) if pump_name else None
        speed = pump.pumping_speed * 3600 if pump and pump.pumping_speed else None
        return {"per_min": rate, "machine": pump_name if speed else None,
                "exact_count": rate / speed if speed else None,
                "count": ceil(rate / speed) if speed else None}
    candidates = resource.miners if resource else ()
    if not candidates and resource and resource.resource_category:
        candidates = tuple(key for key, entity in spec.entities.items()
                           if resource.resource_category in entity.resource_categories)
    selected = overrides.get(f"mining:{name}") or overrides.get("mining")
    if selected:
        candidates = (selected,)
    eligible = [key for key in candidates if key in spec.entities]
    miner_name = min(eligible, key=lambda key: (_cost(spec, key), key)) if eligible else None
    miner = spec.entities.get(miner_name) if miner_name else None
    product = next((row for row in (resource.mining_products if resource else ())
                    if row.get("name") == name), None)
    yield_per_cycle = _amount(product) if product else 1
    speed = (mining_rate(miner.mining_speed, resource.mining_time, yield_per_cycle) * 60
             if miner and miner.mining_speed and resource and resource.mining_time else None)
    return {"per_min": rate, "machine": miner_name if speed else None,
            "exact_count": rate / speed if speed else None,
            "count": ceil(rate / speed) if speed else None}


def plan(spec: Spec, item: str, per_min: float, machines: dict | None = None,
         recipes: dict | None = None) -> dict:
    """Expand a target rate into nominal machines, raw inputs, power and belt lanes."""
    if not item or not isfinite(per_min) or per_min <= 0:
        raise ValueError("item and positive finite per_min required")
    machines, recipes = machines or {}, {**spec.selected_recipes, **(recipes or {})}
    rows: dict[str, dict] = {}
    raw_rates: dict[str, float] = defaultdict(float)
    raw_kinds: dict[str, str] = {}
    edges: dict[tuple[str, str], float] = defaultdict(float)
    stack: set[str] = set()

    def expand(product: str, rate: float, kind: str = "item") -> None:
        if product == "water" or (product in spec.entities
                                  and spec.entities[product].entity_type == "resource"):
            raw_rates[product] += rate
            raw_kinds[product] = kind
            return
        recipe_name = recipes.get(product, product)
        recipe = spec.recipes.get(recipe_name)
        if recipe is None and product not in recipes:
            choices = sorted(name for name, candidate in spec.recipes.items()
                             if any(r.get("name") == product for r in candidate.products))
            if choices:
                recipe_name = choices[0]
                recipe = spec.recipes[recipe_name]
        if recipe is None:
            if product in recipes:
                raise ValueError(f"recipe not in spec: {recipe_name}")
            raw_rates[product] += rate
            raw_kinds[product] = kind
            return
        if product in stack:
            raise ValueError(f"recipe cycle at {product}; choose a different recipe")
        output = next((r for r in recipe.products if r.get("name") == product), None)
        if output is None:
            raise ValueError(f"recipe {recipe_name} does not produce {product}")
        amount = _amount(output)
        if amount <= 0 or not recipe.energy or recipe.energy <= 0:
            raise ValueError(f"invalid recipe yield/energy: {recipe_name}")
        category = recipe.category or "crafting"
        machine_name = _machine(spec, category, recipe.machines, machines)
        machine = spec.entities[machine_name]
        if not machine.crafting_speed or machine.crafting_speed <= 0:
            raise ValueError(f"missing crafting speed: {machine_name}")
        crafts = rate / amount
        row = rows.setdefault(recipe_name, {"recipe": recipe_name, "machine": machine_name,
                                           "crafts_per_min": 0.0, "in": defaultdict(float),
                                           "out": defaultdict(float), "surplus": defaultdict(float),
                                           "enabled": recipe.enabled})
        if row["machine"] != machine_name:
            raise ValueError(f"conflicting machines for {recipe_name}")
        row["crafts_per_min"] += crafts
        stack.add(product)
        for ingredient in recipe.ingredients:
            name, amount_in = ingredient["name"], ingredient["amount"] * crafts
            row["in"][name] += amount_in
            edges[(name, recipe_name)] += amount_in
            expand(name, amount_in, ingredient.get("type", "item"))
        stack.remove(product)
        for result in recipe.products:
            produced = _amount(result) * crafts
            row["out"][result["name"]] += produced
            if result["name"] != product:
                # ponytail: byproducts remain surplus; add LP only if shared-output balancing matters.
                row["surplus"][result["name"]] += produced

    expand(item, per_min)
    power_watts = 0.0
    finished_rows = []
    for row in rows.values():
        machine = spec.entities[row["machine"]]
        rate = crafting_rate(machine.crafting_speed, spec.recipes[row["recipe"]].energy) * 60
        exact = row["crafts_per_min"] / rate
        count = ceil(exact)
        power_watts += count * (machine.energy_usage_watts or 0)
        finished_rows.append({**row, "exact_count": exact, "count": count,
                              "in": dict(row["in"]), "out": dict(row["out"]),
                              "surplus": dict(row["surplus"])})
    raw = {}
    for name, rate in sorted(raw_rates.items()):
        source = _raw_source(spec, name, raw_kinds[name], rate, machines)
        raw[name] = source
        machine = spec.entities.get(source["machine"])
        if machine and source["count"]:
            power_watts += source["count"] * (machine.energy_usage_watts or 0)
    made: dict[str, float] = defaultdict(float)
    used: dict[str, float] = defaultdict(float)
    for row in finished_rows:
        for name, rate in row["out"].items():
            made[name] += rate
        for name, rate in row["in"].items():
            used[name] += rate
    used[item] += per_min
    surplus = {name: rate - used[name] for name, rate in made.items()
               if rate - used[name] > 1e-9}
    belts = []
    for (name, target), rate in sorted(edges.items()):
        if raw_kinds.get(name) == "fluid" or any(
                part.get("name") == name and part.get("type") == "fluid"
                for part in spec.recipes[target].ingredients):
            continue
        belts.append({"item": name, "to": target, "per_min": rate,
                      "lanes": {belt: ceil(rate / (belt_capacity_from_spec(spec, belt, lanes=1) * 60))
                                for belt in BELTS if belt in spec.entities
                                and spec.entities[belt].belt_speed}})
    return {"item": item, "per_min": per_min, "rows": finished_rows,
            "raw": raw, "surplus": surplus, "power_kw": power_watts / 1000,
            "belts": belts}


def live_spec(item: str, recipes: dict | None = None, fetch=None) -> Spec:
    """Collect only needed prototypes through read-only spec requests, cached per call."""
    if fetch is None:
        from factorio_ai import DEFAULT_HOST, DEFAULT_PORT, request
        fetch = lambda body: request(body, host=os.environ.get("FACTORIO_HOST", DEFAULT_HOST),
                                     port=int(os.environ.get("FACTORIO_PORT", DEFAULT_PORT)))
    recipes = recipes or {}
    data = {"schema_version": SCHEMA_VERSION, "entities": {}, "items": {},
            "recipes": {}, "selected_recipes": {}}
    cache = {}
    visited: set[str] = set()

    def read(kind: str, name: str | None = None, **extra) -> dict:
        body = {"action": "spec", "kind": kind, **({"name": name} if name else {}), **extra}
        key = (kind, name, tuple(sorted(extra.items())))
        if key not in cache:
            cache[key] = fetch(body)
        return cache[key]

    def entity(name: str) -> dict:
        if name not in data["entities"]:
            reply = read("entity", name)
            if reply.get("ok"):
                data["entities"][name] = entity_fields(reply)
            return reply
        return {"ok": True}

    def visit(product: str) -> None:
        if product in visited:
            return
        visited.add(product)
        if product == "water":
            entity("offshore-pump")
            return
        chosen = recipes.get(product, product)
        reply = read("recipe", chosen)
        if not reply.get("ok") and chosen == product:
            resource = entity(product)
            if resource.get("entity_type") == "resource":
                for miner in resource.get("miners") or ():
                    entity(miner)
                    built = read("recipe", entity=miner)
                    if built.get("ok"):
                        data["recipes"][built["name"]] = recipe_fields(built)
                return
            if reply.get("candidates"):
                options = [read("recipe", candidate) for candidate in reply["candidates"]]
                options = [option for option in options if option.get("ok")
                           and option.get("enabled") is not False
                           and option.get("category") != "recycling"
                           and "barrel" not in option["name"]]
                if options:
                    from_product = [option for option in options
                                    if option["name"].startswith(product + "-from-")]
                    if from_product:
                        options = from_product
                        options.sort(key=lambda option: (
                            sum(part["amount"] for part in option["ingredients"])
                            / _amount(next(part for part in option["products"]
                                           if part["name"] == product)), option["name"]))
                    else:
                        options.sort(key=lambda option: option["name"])
                    reply = options[0]
        if not reply.get("ok"):
            if reply.get("error") != "recipe-not-found" or chosen != product:
                raise ValueError(f"spec recipe {chosen}: {reply.get('error')}")
            if product == item:
                raise ValueError(f"unknown product: {product}")
            return
        name = reply["name"]
        data["recipes"][name] = recipe_fields(reply)
        data["selected_recipes"][product] = name
        for machine in reply.get("machines") or ():
            entity(machine)
            built = read("recipe", entity=machine)
            if built.get("ok"):
                data["recipes"][built["name"]] = recipe_fields(built)
        for ingredient in reply.get("ingredients") or ():
            visit(ingredient["name"])

    visit(item)
    for belt in BELTS:
        entity(belt)
    return spec_from_dict(data)
