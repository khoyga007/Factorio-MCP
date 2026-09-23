-- Read-only views: snapshot, brief, spec, audit, whole-map index, production flow, item supply.
local core = require("core")
local ENTITY_TYPES, MAX_ENTITIES, MAX_RADIUS, bridge_state = core.ENTITY_TYPES, core.MAX_ENTITIES, core.MAX_RADIUS, core.bridge_state
local entity_data, entity_status_name, find_ghosts, force_for = core.entity_data, core.entity_status_name, core.find_ghosts, core.force_for
local ghost_data, number, position, response = core.ghost_data, core.number, core.position, core.response
local surface_for, treasury, treasury_data, treasury_inventory = core.surface_for, core.treasury, core.treasury_data, core.treasury_inventory

-- Forward declared: handle_brief/handle_snapshot use them before their definitions.
local fluid_tile_names
local scan_tiles

local function handle_snapshot(nonce, request)
  local surface = surface_for(request)
  if not surface then return response(nonce, false, {error = "surface-not-found"}) end

  local center = position(request)
  if not center then
    local player = game.get_player(1)
    center = player and player.position or {x = 0, y = 0}
  end
  local radius = math.min(MAX_RADIUS, math.max(1, number(request.radius, 16)))
  local area = {
    {center.x - radius, center.y - radius},
    {center.x + radius, center.y + radius},
  }

  local bins = {}
  for _, entity in pairs(surface.find_entities_filtered {area = area, type = "resource"}) do
    local bx = math.floor(entity.position.x / 8) * 8
    local by = math.floor(entity.position.y / 8) * 8
    local key = entity.name .. ":" .. bx .. ":" .. by
    local bin = bins[key]
    if not bin then
      bin = {name = entity.name, x = bx, y = by, tiles = 0, amount = 0}
      bins[key] = bin
    end
    bin.tiles = bin.tiles + 1
    bin.amount = bin.amount + (entity.amount or 0)
  end
  local resources = {}
  for _, bin in pairs(bins) do resources[#resources + 1] = bin end
  table.sort(resources, function(a, b)
    if a.name ~= b.name then return a.name < b.name end
    if a.x ~= b.x then return a.x < b.x end
    return a.y < b.y
  end)

  local force = force_for(request)
  if not force then return response(nonce, false, {error = "force-not-found"}) end
  local entities = {}
  local found = surface.find_entities_filtered {area = area, type = ENTITY_TYPES, force = force}
  table.sort(found, function(a, b)
    return (a.unit_number or 0) < (b.unit_number or 0)
  end)
  local offset = math.max(0, math.floor(number(request.offset, 0)))
  local limit = math.min(MAX_ENTITIES, math.max(1, math.floor(number(request.limit, MAX_ENTITIES))))
  for i = offset + 1, math.min(#found, offset + limit) do
    entities[#entities + 1] = entity_data(found[i])
  end

  local ghosts, found_ghosts = {}, find_ghosts(surface, area, force)
  for i = offset + 1, math.min(#found_ghosts, offset + limit) do
    ghosts[#ghosts + 1] = ghost_data(found_ghosts[i])
  end

  local ground_items = {}
  for _, entity in pairs(surface.find_entities_filtered {area = area, type = "item-entity"}) do
    local stack = entity.stack
    if stack and stack.valid_for_read then
      ground_items[#ground_items + 1] = {
        name = stack.name,
        count = stack.count,
        x = entity.position.x,
        y = entity.position.y,
      }
    end
  end

  local inventory, owner, kind = treasury_inventory()

  local obstacles, obstacles_total, obstacles_next_offset, obstacle_summary
  if request.obstacles then
    local natural = surface.find_entities_filtered {
      area = area, type = {"tree", "simple-entity", "cliff"},
    }
    table.sort(natural, function(a, b)
      if a.position.x ~= b.position.x then return a.position.x < b.position.x end
      if a.position.y ~= b.position.y then return a.position.y < b.position.y end
      return a.name < b.name
    end)
    -- Per-type count + extent; nearby reads only this, the paged list serves view=entities.
    obstacle_summary = {}
    for _, e in pairs(natural) do
      local p = e.position
      local s = obstacle_summary[e.type]
      if not s then
        s = {count = 0, x1 = p.x, y1 = p.y, x2 = p.x, y2 = p.y}
        obstacle_summary[e.type] = s
      end
      s.count = s.count + 1
      s.x1, s.y1 = math.min(s.x1, p.x), math.min(s.y1, p.y)
      s.x2, s.y2 = math.max(s.x2, p.x), math.max(s.y2, p.y)
    end
    obstacles, obstacles_total = {}, #natural
    for i = offset + 1, math.min(#natural, offset + limit) do
      local e = natural[i]
      obstacles[#obstacles + 1] = {
        name = e.name, type = e.type, x = e.position.x, y = e.position.y,
        bounding_box = e.bounding_box,
      }
    end
    obstacles_next_offset = offset + #obstacles < #natural and offset + #obstacles or nil
  end

  local tiles
  if request.tiles then
    tiles = scan_tiles(surface, center, radius, request.name)
  end

  return response(nonce, true, {
    action = "snapshot",
    tick = game.tick,
    surface = surface.name,
    center = center,
    radius = radius,
    resources = resources,
    entities = entities,
    entities_total = #found,
    entities_offset = offset,
    entities_next_offset = offset + #entities < #found and offset + #entities or nil,
    ghosts = ghosts,
    ghosts_total = #found_ghosts,
    ghosts_next_offset = offset + #ghosts < #found_ghosts and offset + #ghosts or nil,
    ground_items = ground_items,
    obstacles = obstacles,
    obstacles_total = obstacles_total,
    obstacle_summary = obstacle_summary,
    obstacles_next_offset = obstacles_next_offset,
    entities_truncated = offset + #entities < #found,
    autofuel = {
      enabled = bridge_state().autofuel_enabled,
      receipts = bridge_state().autofuel_receipts,
    },
    tiles = tiles,
    treasury = treasury_data(inventory, owner, kind),
  })
end

-- Compact situational awareness in one UDP packet, even for a large base.
local function handle_brief(nonce, request)
  local surface, force = surface_for(request), force_for(request)
  if not surface then return response(nonce, false, {error = "surface-not-found"}) end
  if not force then return response(nonce, false, {error = "force-not-found"}) end
  local center = position(request)
  if not center then
    local player = game.get_player(1)
    center = player and player.position or {x = 0, y = 0}
  end
  local radius = math.min(64, math.max(1, number(request.radius, 32)))
  local area = {
    {center.x - radius, center.y - radius},
    {center.x + radius, center.y + radius},
  }
  local function distance_squared(entity)
    local dx = entity.position.x - center.x
    local dy = entity.position.y - center.y
    return dx * dx + dy * dy
  end
  local counts, issues = {}, {}
  local bad_status = {
    no_power = true, no_fuel = true, no_ingredients = true,
    item_ingredient_shortage = true, fluid_ingredient_shortage = true,
    low_power = true, not_plugged_in_electric_network = true,
  }
  local owned = surface.find_entities_filtered {area = area, type = ENTITY_TYPES, force = force}
  for _, entity in pairs(owned) do
    counts[entity.name] = (counts[entity.name] or 0) + 1
    local status = entity_status_name(entity.status)
    if bad_status[status] then
      issues[#issues + 1] = {
        name = entity.name, status = status,
        x = entity.position.x, y = entity.position.y,
        unit_number = entity.unit_number,
        distance_squared = distance_squared(entity),
      }
    end
  end
  table.sort(issues, function(a, b) return a.distance_squared < b.distance_squared end)
  local issue_total = #issues
  while #issues > 20 do table.remove(issues) end
  for _, issue in pairs(issues) do issue.distance_squared = nil end

  -- Ghosts are what someone PLANNED here. Counted apart from built machines and
  -- summarised (count + extent per name): a pasted blueprint is hundreds of rows.
  local ghost_counts, ghost_total, ghost_box = {}, 0, nil
  for _, g in pairs(find_ghosts(surface, area, force)) do
    local name = g.ghost_name or "unknown"
    ghost_counts[name] = (ghost_counts[name] or 0) + 1
    ghost_total = ghost_total + 1
    local p = g.position
    if not ghost_box then
      ghost_box = {x1 = p.x, y1 = p.y, x2 = p.x, y2 = p.y}
    else
      ghost_box.x1, ghost_box.y1 = math.min(ghost_box.x1, p.x), math.min(ghost_box.y1, p.y)
      ghost_box.x2, ghost_box.y2 = math.max(ghost_box.x2, p.x), math.max(ghost_box.y2, p.y)
    end
  end

  local enemy_force = game.forces.enemy
  local enemies = enemy_force and surface.find_entities_filtered {
    area = area, force = enemy_force, type = {"unit", "unit-spawner", "turret"},
  } or {}
  table.sort(enemies, function(a, b) return distance_squared(a) < distance_squared(b) end)
  local nearest_enemies = {}
  for i = 1, math.min(#enemies, 20) do
    local entity = enemies[i]
    nearest_enemies[#nearest_enemies + 1] = {
      name = entity.name, x = entity.position.x, y = entity.position.y,
      distance = math.sqrt(distance_squared(entity)),
    }
  end
  -- Ore patches in the same area, binned exactly like snapshot.resources.
  local ore_bins, ore_order = {}, {}
  for _, entity in pairs(surface.find_entities_filtered {area = area, type = "resource"}) do
    local bx = math.floor(entity.position.x / 8) * 8
    local by = math.floor(entity.position.y / 8) * 8
    local key = entity.name .. ":" .. bx .. ":" .. by
    local bin = ore_bins[key]
    if not bin then
      bin = {name = entity.name, x = bx, y = by, tiles = 0, amount = 0}
      ore_bins[key] = bin
      ore_order[#ore_order + 1] = bin
    end
    bin.tiles = bin.tiles + 1
    bin.amount = bin.amount + (entity.amount or 0)
  end
  table.sort(ore_order, function(a, b) return a.amount > b.amount end)
  local ore_total = {}
  for _, bin in pairs(ore_order) do
    local agg = ore_total[bin.name]
    if not agg then agg = {tiles = 0, amount = 0}; ore_total[bin.name] = agg end
    agg.tiles = agg.tiles + bin.tiles
    agg.amount = agg.amount + bin.amount
  end
  local ore_patches = {}
  for i = 1, math.min(#ore_order, 30) do
    ore_patches[#ore_patches + 1] = ore_order[i]
  end

  -- Water in the same area: nearest tile plus the closest binned patches.
  local water_tiles = surface.find_tiles_filtered {area = area, name = fluid_tile_names()}
  local nearest_water, nearest_d2
  local water_bins = {}
  for _, tile in pairs(water_tiles) do
    local tx, ty = tile.position.x, tile.position.y
    local dx, dy = tx - center.x, ty - center.y
    local d2 = dx * dx + dy * dy
    if not nearest_d2 or d2 < nearest_d2 then
      nearest_d2 = d2
      nearest_water = {
        x = tx, y = ty,
        fluid = tile.prototype.fluid and tile.prototype.fluid.name or nil,
      }
    end
    local bx = math.floor(tx / 8) * 8
    local by = math.floor(ty / 8) * 8
    local key = bx .. ":" .. by
    local bin = water_bins[key]
    if not bin then bin = {x = bx, y = by, tiles = 0}; water_bins[key] = bin end
    bin.tiles = bin.tiles + 1
  end
  local water_bin_list = {}
  for _, bin in pairs(water_bins) do water_bin_list[#water_bin_list + 1] = bin end
  table.sort(water_bin_list, function(a, b)
    local da = (a.x - center.x) * (a.x - center.x) + (a.y - center.y) * (a.y - center.y)
    local db = (b.x - center.x) * (b.x - center.x) + (b.y - center.y) * (b.y - center.y)
    return da < db
  end)
  while #water_bin_list > 10 do table.remove(water_bin_list) end
  if nearest_water then nearest_water.distance = math.sqrt(nearest_d2) end

  local inv, owner, kind = treasury_inventory()
  return response(nonce, true, {
    action = "brief", tick = game.tick, surface = surface.name,
    center = center, radius = radius,
    owned_total = #owned, counts = counts,
    ghost_total = ghost_total, ghost_counts = ghost_counts, ghost_box = ghost_box,
    issue_total = issue_total, issues = issues,
    enemy_total = #enemies, nearest_enemies = nearest_enemies,
    ore_total = ore_total, ore_patches = ore_patches,
    water_total = #water_tiles, nearest_water = nearest_water, water_bins = water_bin_list,
    treasury = treasury_data(inv, owner, kind),
  })
end

local MAX_TILE_POSITIONS = 200

local FLUID_TILE_NAMES

-- Tiles an offshore pump can draw from are exactly the tile prototypes that
-- declare a fluid. Derived from the running prototype set, never hardcoded.
fluid_tile_names = function()
  if FLUID_TILE_NAMES then return FLUID_TILE_NAMES end
  local names = {}
  for name, proto in pairs(prototypes.tile) do
    if proto.fluid then names[#names + 1] = name end
  end
  table.sort(names)
  FLUID_TILE_NAMES = names
  return names
end

-- Tile scan shared by snapshot (--tiles). Returns a table, not a response:
-- {filter, count, bins, positions, positions_truncated}. `names` is nil to
-- list pumpable water, a string, or a list of tile prototype names.
scan_tiles = function(surface, center, radius, names_arg)
  local min_x, max_x = center.x - radius, center.x + radius
  local min_y, max_y = center.y - radius, center.y + radius
  local area = {{min_x, min_y}, {max_x, max_y}}

  local names = names_arg
  if type(names) == "string" then names = {names} end
  local filter = "name"
  if type(names) ~= "table" then
    names = fluid_tile_names()
    filter = "fluid"
  end

  local base = {filter = filter}
  if #names == 0 then
    base.count = 0
    base.bins = {}
    base.positions = {}
    base.positions_truncated = false
    return base
  end

  local found = surface.find_tiles_filtered {area = area, name = names}

  local bins, order, occupied = {}, {}, {}
  for _, tile in pairs(found) do
    local tx, ty = tile.position.x, tile.position.y
    occupied[tx .. ":" .. ty] = true
    local bx = math.floor(tx / 8) * 8
    local by = math.floor(ty / 8) * 8
    local key = tile.name .. ":" .. bx .. ":" .. by
    local bin = bins[key]
    if not bin then
      local fluid = tile.prototype.fluid
      bin = {
        name = tile.name,
        fluid = fluid and fluid.name or nil,
        x = bx,
        y = by,
        tiles = 0,
      }
      bins[key] = bin
      order[#order + 1] = bin
    end
    bin.tiles = bin.tiles + 1
  end
  table.sort(order, function(a, b)
    if a.name ~= b.name then return a.name < b.name end
    if a.x ~= b.x then return a.x < b.x end
    return a.y < b.y
  end)

  -- A shore tile has a dry 4-neighbour INSIDE the scanned area. Neighbours
  -- outside the area are unknown, so they never count: no false shoreline
  -- on the scan border.
  local function dry_inside(x, y)
    if x < min_x or x > max_x or y < min_y or y > max_y then return false end
    return not occupied[x .. ":" .. y]
  end

  local ranked = {}
  for _, tile in pairs(found) do
    local tx, ty = tile.position.x, tile.position.y
    local shore = dry_inside(tx + 1, ty) or dry_inside(tx - 1, ty)
      or dry_inside(tx, ty + 1) or dry_inside(tx, ty - 1)
    local dx, dy = tx - center.x, ty - center.y
    ranked[#ranked + 1] = {
      x = tx,
      y = ty,
      name = tile.name,
      shore = shore,
      d2 = dx * dx + dy * dy,
    }
  end
  table.sort(ranked, function(a, b)
    if a.shore ~= b.shore then return a.shore end
    if a.d2 ~= b.d2 then return a.d2 < b.d2 end
    if a.x ~= b.x then return a.x < b.x end
    return a.y < b.y
  end)

  local positions = {}
  for i = 1, math.min(#ranked, MAX_TILE_POSITIONS) do
    local p = ranked[i]
    positions[#positions + 1] = {x = p.x, y = p.y, name = p.name, shore = p.shore}
  end

  base.count = #found
  base.bins = order
  base.positions = positions
  base.positions_truncated = #found > MAX_TILE_POSITIONS
  return base
end

-- A small, named prototype read keeps replies bounded and makes predictions
-- traceable to the running game's actual modded values.
local function handle_spec(nonce, request)
  local kind, name = request.kind, request.name
  if type(name) ~= "string" or name == "" then
    local via_entity = kind == "recipe"
      and type(request.entity) == "string" and request.entity ~= ""
    if not via_entity then
      return response(nonce, false, {error = "invalid-prototype-name"})
    end
  end
  if kind == "entity" then
    local proto = prototypes.entity[name]
    if not proto then return response(nonce, false, {error = "entity-not-found"}) end
    local categories = {}
    for category in pairs(proto.crafting_categories or {}) do
      categories[#categories + 1] = category
    end
    table.sort(categories)
    local resource_categories = {}
    for category in pairs(proto.resource_categories or {}) do
      resource_categories[#resource_categories + 1] = category
    end
    table.sort(resource_categories)
    local miners = {}
    if proto.type == "resource" then
      for machine_name, machine in pairs(prototypes.entity) do
        if machine.type == "mining-drill" and machine.resource_categories
          and machine.resource_categories[proto.resource_category]
          and machine.items_to_place_this and #machine.items_to_place_this > 0 then
          miners[#miners + 1] = machine_name
        end
      end
      table.sort(miners)
    end
    local mine = proto.mineable_properties
    local products = {}
    if mine then
      for _, product in pairs(mine.products or {}) do
        products[#products + 1] = {
          name = product.name, type = product.type, amount = product.amount,
          amount_min = product.amount_min, amount_max = product.amount_max,
          probability = product.probability,
        }
      end
    end
    local fluidboxes = {}
    local fluid_ports = {}
    local port_dir = {[0] = {0, -1}, [4] = {1, 0}, [8] = {0, 1}, [12] = {-1, 0}}
    for _, box in pairs(proto.fluidbox_prototypes or {}) do
      fluidboxes[#fluidboxes + 1] = {
        index = box.index, production_type = box.production_type,
        filter = box.filter and box.filter.name or nil,
        pipe_connections = box.pipe_connections,
      }
      for _, connection in pairs(box.pipe_connections or {}) do
        local direction = connection.direction or 0
        local position = connection.positions and connection.positions[1]
        local outward = port_dir[direction]
        if connection.connection_type == "normal" and position and outward then
          fluid_ports[#fluid_ports + 1] = {
            index = box.index, production_type = box.production_type,
            filter = box.filter and box.filter.name or nil,
            x = position.x + outward[1], y = position.y + outward[2],
            direction = direction,
          }
        end
      end
    end
    table.sort(fluid_ports, function(a, b) return a.index < b.index end)
    return response(nonce, true, {
      action = "spec", kind = kind, name = name, entity_type = proto.type,
      mining_speed = proto.mining_speed,
      resource_category = proto.resource_category,
      resource_categories = resource_categories,
      miners = miners,
      crafting_categories = categories,
      crafting_speed = (proto.type == "furnace" or proto.type == "assembling-machine" or proto.type == "rocket-silo")
        and proto.get_crafting_speed() or nil,
      pumping_speed = (proto.type == "offshore-pump" or proto.type == "pump")
        and proto.get_pumping_speed() or nil,
      belt_speed = proto.belt_speed,
      energy_usage_joules_per_tick = proto.energy_usage,
      energy_usage_watts = proto.energy_usage and proto.energy_usage * 60 or nil,
      burner_effectivity = proto.burner_prototype and proto.burner_prototype.effectivity or nil,
      tile_width = proto.tile_width, tile_height = proto.tile_height,
      mining_time = mine and mine.mining_time or nil,
      mining_products = products,
      fluidbox_prototypes = #fluidboxes > 0 and fluidboxes or nil,
      fluid_ports = #fluid_ports > 0 and fluid_ports or nil,
    })
  elseif kind == "item" then
    local proto = prototypes.item[name]
    if not proto then return response(nonce, false, {error = "item-not-found"}) end
    return response(nonce, true, {
      action = "spec", kind = kind, name = name,
      fuel_value_joules = proto.fuel_value,
      fuel_category = proto.fuel_category,
      stack_size = proto.stack_size,
    })
  elseif kind == "recipe" then
    -- Force-level read (was its own `recipe` action): enabled state, live
    -- `have` counts, and the unlocking technology when locked. `entity` maps
    -- a placeable to the recipe its first place item builds.
    local force = force_for(request)
    if not force then return response(nonce, false, {error = "force-not-found"}) end
    local via_entity = nil
    if type(request.entity) == "string" and request.entity ~= "" then
      local proto = prototypes.entity[request.entity]
      if not proto then return response(nonce, false, {error = "entity-not-found"}) end
      local item = proto.items_to_place_this and proto.items_to_place_this[1]
      if not item then
        return response(nonce, false, {error = "entity-has-no-place-item"})
      end
      name = item.name
      via_entity = request.entity
    end
    local recipe = force.recipes[name]
    if not recipe then
      local candidates = {}
      for recipe_name, candidate in pairs(force.recipes) do
        for _, product in pairs(candidate.products) do
          if product.name == name then
            candidates[#candidates + 1] = recipe_name
            break
          end
        end
      end
      table.sort(candidates)
      return response(nonce, false, {error = "recipe-not-found", name = name,
        candidates = candidates})
    end
    local machines = {}
    for machine_name, machine in pairs(prototypes.get_entity_filtered{
      {filter = "crafting-category", crafting_category = recipe.category}
    }) do
      if (machine.type == "assembling-machine" or machine.type == "furnace" or machine.type == "rocket-silo")
        and machine.items_to_place_this and #machine.items_to_place_this > 0 then
        machines[#machines + 1] = machine_name
      end
    end
    table.sort(machines)

    local inventory = treasury_inventory()
    local ingredients = {}
    for _, ing in pairs(recipe.ingredients) do
      local row = {name = ing.name, amount = ing.amount, type = ing.type}
      if inventory and ing.type ~= "fluid" then
        row.have = inventory.get_item_count(ing.name)
      end
      ingredients[#ingredients + 1] = row
    end
    local products = {}
    for _, prod in pairs(recipe.products) do
      products[#products + 1] = {
        name = prod.name, type = prod.type, amount = prod.amount,
        amount_min = prod.amount_min, amount_max = prod.amount_max,
        probability = prod.probability,
      }
    end
    local unlocked_by = {}
    if not recipe.enabled then
      for tech_name, tech in pairs(force.technologies) do
        for _, effect in pairs(tech.prototype.effects or {}) do
          if effect.type == "unlock-recipe" and effect.recipe == name then
            unlocked_by[#unlocked_by + 1] = {
              name = tech_name,
              researched = tech.researched,
              enabled = tech.enabled,
            }
            break
          end
        end
      end
      table.sort(unlocked_by, function(a, b) return a.name < b.name end)
    end

    return response(nonce, true, {
      action = "spec", kind = kind, name = recipe.name,
      via_entity = via_entity,
      enabled = recipe.enabled,
      category = recipe.category,
      machines = machines,
      energy = recipe.energy,
      ingredients = ingredients,
      products = products,
      unlocked_by = unlocked_by,
    })
  end
  return response(nonce, false, {error = "invalid-prototype-kind"})
end

local function handle_audit(nonce, request)
  if type(request.item) ~= "string" or not prototypes.item[request.item] then
    return response(nonce, false, {error = "item-not-found"})
  end
  local surface, force = surface_for(request), force_for(request)
  if not surface then return response(nonce, false, {error = "surface-not-found"}) end
  if not force then return response(nonce, false, {error = "force-not-found"}) end
  local precision = request.precision or "one_minute"
  local allowed = {
    five_seconds = true, one_minute = true, ten_minutes = true,
    one_hour = true,
  }
  if not allowed[precision] then
    return response(nonce, false, {error = "invalid-precision"})
  end
  local stats = force.get_item_production_statistics(surface)
  return response(nonce, true, {
    action = "audit", tick = game.tick, item = request.item,
    surface = surface.name, force = force.name, precision = precision,
    produced_per_minute = stats.get_flow_count {
      name = request.item, category = "input",
      precision_index = defines.flow_precision_index[precision],
    },
    consumed_per_minute = stats.get_flow_count {
      name = request.item, category = "output",
      precision_index = defines.flow_precision_index[precision],
    },
  })
end

-- Whole-map survey index, cached in storage so the AI asks once instead of
-- grid-scanning. Ore/water barely change (only on chunk generation); enemies
-- move, so the whole index is rebuilt after INDEX_TTL_TICKS or a new chunk.
local INDEX_TTL_TICKS = 600
local INDEX_ORE_CAP = 50
local INDEX_ENEMY_CAP = 50
local INDEX_WATER_CAP = 50

local function remember_ore_bins(surface, bins)
  local state = bridge_state()
  state.ore_marks = state.ore_marks or {}
  local marks = state.ore_marks[surface.name] or {}
  state.ore_marks[surface.name] = marks
  local seen = {}
  for _, bin in ipairs(bins) do
    local key = bin.name .. ":" .. bin.x .. ":" .. bin.y
    seen[key] = true
    local mark = marks[key]
    if not mark then
      mark = {name = bin.name, x = bin.x, y = bin.y, first_seen_tick = game.tick}
      marks[key] = mark
    end
    mark.tiles = bin.tiles
    mark.amount = bin.amount
    mark.last_seen_tick = game.tick
    mark.status = "active"
  end
  for key, mark in pairs(marks) do
    if not seen[key] then
      mark.tiles = 0
      mark.amount = 0
      mark.status = "depleted"
    end
  end
end

local function build_index(surface)
  -- Bounds of every generated chunk. get_chunks() is the authoritative list
  -- (see LuaSurface::get_chunks), unlike entity positions which miss empty land.
  local min_x, min_y, max_x, max_y
  for chunk in surface.get_chunks() do
    local tx, ty = chunk.x * 32, chunk.y * 32
    if not min_x or tx < min_x then min_x = tx end
    if not min_y or ty < min_y then min_y = ty end
    if not max_x or tx + 32 > max_x then max_x = tx + 32 end
    if not max_y or ty + 32 > max_y then max_y = ty + 32 end
  end
  if not min_x then
    remember_ore_bins(surface, {})
    return {surface = surface.name, tick = game.tick, bounds = nil, ores = {}, enemies = {}, water = {}}
  end
  local area = {{min_x, min_y}, {max_x, max_y}}

  local ore_bins, ore_order = {}, {}
  for _, entity in pairs(surface.find_entities_filtered {area = area, type = "resource"}) do
    local bx = math.floor(entity.position.x / 32) * 32
    local by = math.floor(entity.position.y / 32) * 32
    local key = entity.name .. ":" .. bx .. ":" .. by
    local bin = ore_bins[key]
    if not bin then
      bin = {name = entity.name, x = bx, y = by, tiles = 0, amount = 0}
      ore_bins[key] = bin
      ore_order[#ore_order + 1] = bin
    end
    bin.tiles = bin.tiles + 1
    bin.amount = bin.amount + (entity.amount or 0)
  end
  table.sort(ore_order, function(a, b) return a.amount > b.amount end)
  remember_ore_bins(surface, ore_order)
  while #ore_order > INDEX_ORE_CAP do table.remove(ore_order) end

  local enemy_bins, enemy_order = {}, {}
  local enemy_force = game.forces.enemy
  if enemy_force then
    for _, entity in pairs(surface.find_entities_filtered {
      area = area, force = enemy_force, type = {"unit", "unit-spawner", "turret"},
    }) do
      local bx = math.floor(entity.position.x / 32) * 32
      local by = math.floor(entity.position.y / 32) * 32
      local key = bx .. ":" .. by
      local bin = enemy_bins[key]
      if not bin then
        bin = {x = bx, y = by, count = 0, names = {}}
        enemy_bins[key] = bin
        enemy_order[#enemy_order + 1] = bin
      end
      bin.count = bin.count + 1
      bin.names[entity.name] = (bin.names[entity.name] or 0) + 1
    end
  end
  table.sort(enemy_order, function(a, b) return a.count > b.count end)
  while #enemy_order > INDEX_ENEMY_CAP do table.remove(enemy_order) end

  local water_bins, water_order = {}, {}
  for _, tile in pairs(surface.find_tiles_filtered {area = area, name = fluid_tile_names()}) do
    local tx, ty = tile.position.x, tile.position.y
    local bx = math.floor(tx / 32) * 32
    local by = math.floor(ty / 32) * 32
    local key = bx .. ":" .. by
    local bin = water_bins[key]
    if not bin then
      bin = {x = bx, y = by, tiles = 0}
      water_bins[key] = bin
      water_order[#water_order + 1] = bin
    end
    bin.tiles = bin.tiles + 1
  end
  table.sort(water_order, function(a, b) return a.tiles > b.tiles end)
  while #water_order > INDEX_WATER_CAP do table.remove(water_order) end

  return {
    surface = surface.name,
    tick = game.tick,
    bounds = {min_x = min_x, min_y = min_y, max_x = max_x, max_y = max_y},
    ores = ore_order,
    enemies = enemy_order,
    water = water_order,
  }
end

local function get_index(surface)
  local state = bridge_state()
  local index = state.index
  if not index or index.surface ~= surface.name
    or index.tick + INDEX_TTL_TICKS < game.tick
    or not (state.ore_marks and state.ore_marks[surface.name]) then
    index = build_index(surface)
    state.index = index
  end
  return index
end

local function handle_ore_marks(nonce, request)
  local surface = surface_for(request)
  if not surface then return response(nonce, false, {error = "surface-not-found"}) end
  get_index(surface)
  local marks = bridge_state().ore_marks[surface.name]
  local name = request.name
  if name ~= nil and (type(name) ~= "string" or name == "") then
    return response(nonce, false, {error = "invalid-resource-name"})
  end
  local ordered = {}
  for _, mark in pairs(marks) do
    if not name or mark.name == name then ordered[#ordered + 1] = mark end
  end
  table.sort(ordered, function(a, b)
    if a.status ~= b.status then return a.status == "active" end
    if a.amount ~= b.amount then return a.amount > b.amount end
    if a.name ~= b.name then return a.name < b.name end
    if a.x ~= b.x then return a.x < b.x end
    return a.y < b.y
  end)
  local offset = math.max(0, math.floor(number(request.offset, 0)))
  local limit = math.min(50, math.max(1, math.floor(number(request.limit, 50))))
  local page = {}
  for i = offset + 1, math.min(#ordered, offset + limit) do
    page[#page + 1] = ordered[i]
  end
  return response(nonce, true, {
    action = "ore_marks", surface = surface.name, total = #ordered,
    offset = offset, next_offset = offset + #page < #ordered and offset + #page or nil,
    marks = page,
  })
end

local function handle_index(nonce, request)
  local surface = surface_for(request)
  if not surface then return response(nonce, false, {error = "surface-not-found"}) end
  local index = get_index(surface)
  return response(nonce, true, {
    action = "index", tick = game.tick, surface = surface.name,
    index_tick = index.tick, bounds = index.bounds,
    ores = index.ores, ore_marks_total = table_size(bridge_state().ore_marks[surface.name]),
    enemies = index.enemies, water = index.water,
  })
end

-- Production statistics (the in-game F-screen), per minute over a window. Snapshots show
-- stock on belts, not rates; on 23/09 every bottleneck call was guessed from belt density
-- and one was wrong. count=true + divide keeps the unit ours, not the API's.
local FLOW_WINDOWS = {["1m"] = {"one_minute", 1}, ["10m"] = {"ten_minutes", 10},
  ["1h"] = {"one_hour", 60}}
local function handle_flow(nonce, request)
  local surface = surface_for(request)
  if not surface then return response(nonce, false, {error = "surface-not-found"}) end
  local force = force_for(request)
  if not force then return response(nonce, false, {error = "force-not-found"}) end
  local w = FLOW_WINDOWS[request.window or "10m"]
  if not w then return response(nonce, false, {error = "window-is-1m-10m-1h"}) end
  local precision = defines.flow_precision_index[w[1]]
  local rows = {}
  for kind, stats in pairs {item = force.get_item_production_statistics(surface),
                             fluid = force.get_fluid_production_statistics(surface)} do
    local names = {}
    if type(request.items) == "table" then
      for _, n in ipairs(request.items) do names[n] = true end
    else
      for n in pairs(stats.input_counts) do names[n] = true end
      for n in pairs(stats.output_counts) do names[n] = true end
    end
    for n in pairs(names) do
      local proto = kind == "item" and prototypes.item[n] or prototypes.fluid[n]
      if proto then
        local made = stats.get_flow_count {name = n, category = "input", precision_index = precision, count = true}
        local used = stats.get_flow_count {name = n, category = "output", precision_index = precision, count = true}
        if made > 0 or used > 0 or type(request.items) == "table" then
          rows[#rows + 1] = {name = n, kind = kind ~= "item" and kind or nil,
            made = math.floor(made / w[2] * 10 + 0.5) / 10,
            used = math.floor(used / w[2] * 10 + 0.5) / 10}
        end
      end
    end
  end
  table.sort(rows, function(a, b)
    if a.made + a.used ~= b.made + b.used then return a.made + a.used > b.made + b.used end
    return a.name < b.name
  end)
  local total = #rows
  for i = total, 61, -1 do rows[i] = nil end
  return response(nonce, true, {action = "flow", tick = game.tick, window = request.window or "10m",
    unit = "per_minute", rows = rows, total = total})
end

-- Where one item lives base-wide: machines making/using it (16-tile clusters),
-- belt tiles carrying it (per-lane counts; Python folds them into runs) and chests.
-- ponytail: full-surface find_entities per call; cache/area-limit if bases get huge.
local function handle_supply(nonce, request)
  local surface = surface_for(request)
  if not surface then return response(nonce, false, {error = "surface-not-found"}) end
  local force = force_for(request)
  if not force then return response(nonce, false, {error = "force-not-found"}) end
  local item = request.item
  if type(item) ~= "string" or not (prototypes.item[item] or prototypes.fluid[item]) then
    return response(nonce, false, {error = "unknown-item"})
  end
  local function has(list)
    for _, p in pairs(list or {}) do if p.name == item then return true end end
  end
  local makers, users = {}, {}
  local function add(bag, e, st)
    local k = math.floor(e.position.x / 16) .. ":" .. math.floor(e.position.y / 16)
    local c = bag[k]
    if not c then c = {n = 0, sx = 0, sy = 0, st = {}}; bag[k] = c end
    c.n, c.sx, c.sy = c.n + 1, c.sx + e.position.x, c.sy + e.position.y
    c.st[st] = (c.st[st] or 0) + 1
    c.r = c.r or e.get_recipe().name
  end
  for _, e in pairs(surface.find_entities_filtered {force = force,
      type = {"assembling-machine", "furnace", "chemical-plant", "oil-refinery"}}) do
    local r = e.get_recipe()
    if r then
      local st = entity_status_name(e.status) or "?"
      if has(r.products) then add(makers, e, st) end
      if has(r.ingredients) then add(users, e, st) end
    end
  end
  local function fold(bag)
    local out = {}
    for _, c in pairs(bag) do
      out[#out + 1] = {x = math.floor(c.sx / c.n + 0.5), y = math.floor(c.sy / c.n + 0.5),
        n = c.n, recipe = c.r, status = c.st}
    end
    table.sort(out, function(a, b) return a.n > b.n end)
    for i = #out, 25, -1 do out[i] = nil end
    return out
  end
  local solid = prototypes.item[item] ~= nil
  local belts, belt_total = {}, 0
  for _, e in pairs(solid and surface.find_entities_filtered {force = force, type = "transport-belt"} or {}) do
    local c1 = e.get_transport_line(1).get_item_count(item)
    local c2 = e.get_transport_line(2).get_item_count(item)
    if c1 + c2 > 0 then
      belt_total = belt_total + 1
      if #belts < 800 then
        belts[#belts + 1] = {e.position.x, e.position.y, e.direction, c1, c2}
      end
    end
  end
  local chests, stored = {}, 0
  for _, e in pairs(solid and surface.find_entities_filtered {force = force,
      type = {"container", "logistic-container"}} or {}) do
    local n = e.get_item_count(item)
    if n > 0 then
      stored = stored + n
      chests[#chests + 1] = {x = e.position.x, y = e.position.y, n = n}
    end
  end
  table.sort(chests, function(a, b) return a.n > b.n end)
  for i = #chests, 21, -1 do chests[i] = nil end
  return response(nonce, true, {action = "supply", item = item, makers = fold(makers),
    users = fold(users), belts = belts, belt_tiles = belt_total, chests = chests,
    stored = stored})
end

return {
  fluid_tile_names = fluid_tile_names,
  handle_audit = handle_audit,
  handle_brief = handle_brief,
  handle_flow = handle_flow,
  handle_index = handle_index,
  handle_ore_marks = handle_ore_marks,
  handle_snapshot = handle_snapshot,
  handle_spec = handle_spec,
  handle_supply = handle_supply,
}
