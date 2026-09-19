local BRIDGE_VERSION = 1
local BRIDGE_BUILD = "2026-09-19-pole-wiring"
local MAX_PACKET_BYTES = 32768
local MAX_RADIUS = 32
local MAX_ENTITIES = 64
local MAX_CACHED_RESPONSES = 128

local CHEST_TYPES = {"container", "logistic-container", "linked-container"}
local ENTITY_TYPES = {
  "accumulator", "ammo-turret", "assembling-machine", "beacon", "boiler",
  "cargo-wagon", "container", "electric-pole", "electric-turret", "furnace",
  "gate", "generator", "inserter", "lab", "locomotive", "logistic-container",
  "mining-drill", "offshore-pump", "pipe", "pipe-to-ground", "pump", "radar",
  "reactor", "roboport", "rocket-silo", "solar-panel", "splitter", "storage-tank",
  "train-stop", "transport-belt", "underground-belt", "wall"
}

local DIRECTIONS = {
  north = defines.direction.north,
  east = defines.direction.east,
  south = defines.direction.south,
  west = defines.direction.west,
}

-- Forward declaration so handle_ping can advertise the live action list.
local HANDLERS
-- Forward declared so handle_brief (defined before it) can reuse the water scan.
local fluid_tile_names
-- Forward declared so handle_snapshot (defined before it) can reuse the tile scan.
local scan_tiles

local function bridge_state()
  storage.factorio_ai_bridge = storage.factorio_ai_bridge or {
    responses = {},
    response_order = {},
  }
  local state = storage.factorio_ai_bridge
  if state.autofuel_enabled == nil then state.autofuel_enabled = true end
  state.autofuel_receipts = state.autofuel_receipts or {}
  return state
end

local function response(nonce, ok, fields)
  local value = fields or {}
  value.v = BRIDGE_VERSION
  value.nonce = nonce
  value.ok = ok
  return value
end

local function remember_response(nonce, value)
  local state = bridge_state()
  if state.responses[nonce] then return end
  state.responses[nonce] = value
  state.response_order[#state.response_order + 1] = nonce
  while #state.response_order > MAX_CACHED_RESPONSES do
    local old = table.remove(state.response_order, 1)
    state.responses[old] = nil
  end
end

local function send(event, value)
  helpers.send_udp(event.source_port, helpers.table_to_json(value), event.player_index)
end

local function number(value, fallback)
  local parsed = tonumber(value)
  if parsed == nil then return fallback end
  return parsed
end

local function position(request)
  local x = number(request.x)
  local y = number(request.y)
  if not x or not y then return nil end
  return {x = x, y = y}
end

local function surface_for(request)
  return game.get_surface(request.surface or "nauvis")
end

local function force_for(request)
  return game.forces[request.force or "player"]
end

local function treasury()
  local state = bridge_state()
  local stored = state.treasury_entity
  if stored and stored.valid then return stored end
  state.treasury_entity = nil

  local unit_number = state.treasury_unit_number
  if not unit_number then return nil end
  local entity = game.get_entity_by_unit_number(unit_number)
  if not (entity and entity.valid) then
    state.treasury_unit_number = nil
    return nil
  end
  return entity
end

local function treasury_inventory()
  local entity = treasury()
  if entity then
    return entity.get_inventory(defines.inventory.chest), entity, "container"
  end
  local player = game.get_player(1)
  if not (player and player.valid) then return nil, nil, nil end
  return player.get_main_inventory(), player, "player"
end

local function inventory_contents(inventory)
  local result = {}
  if not inventory then return result end
  for _, stack in pairs(inventory.get_contents()) do
    result[#result + 1] = {name = stack.name, count = stack.count}
  end
  table.sort(result, function(a, b) return a.name < b.name end)
  return result
end

local function entity_status_name(status)
  for name, value in pairs(defines.entity_status) do
    if value == status then return name end
  end
  return nil
end

local function treasury_data(inventory, owner, kind)
  if not owner then return nil end
  return {
    kind = kind,
    name = owner.name,
    unit_number = kind == "container" and owner.unit_number or nil,
    player_index = kind == "player" and owner.index or nil,
    surface = owner.surface.name,
    x = owner.position.x,
    y = owner.position.y,
    contents = inventory_contents(inventory),
  }
end

local function autofuel_surface(surface, force)
  local state = bridge_state()
  if not state.autofuel_enabled then return end
  local chests = surface.find_entities_filtered {type = CHEST_TYPES, force = force}
  table.sort(chests, function(a, b)
    return (a.unit_number or 0) < (b.unit_number or 0)
  end)
  local targets = surface.find_entities_filtered {type = ENTITY_TYPES, force = force}
  for _, entity in pairs(targets) do
    local fuel = entity.get_fuel_inventory()
    local remaining = entity.burner and entity.burner.remaining_burning_fuel or 0
    if fuel and fuel.is_empty() and remaining <= 0 then
      local filled = false
      for _, chest in pairs(chests) do
        local source = chest.get_inventory(defines.inventory.chest)
        if source then
          for _, stack in pairs(source.get_contents()) do
            if stack.count > 0 and fuel.can_insert {name = stack.name, count = 1} then
              local removed = source.remove {name = stack.name, count = 1}
              if removed == 1 then
                local inserted = fuel.insert {name = stack.name, count = 1}
                if inserted == 1 then
                  local receipts = state.autofuel_receipts
                  receipts[#receipts + 1] = {
                    tick = game.tick,
                    item = stack.name,
                    count = 1,
                    source_unit_number = chest.unit_number,
                    source_x = chest.position.x,
                    source_y = chest.position.y,
                    target_unit_number = entity.unit_number,
                    target_name = entity.name,
                    target_x = entity.position.x,
                    target_y = entity.position.y,
                  }
                  while #receipts > 20 do table.remove(receipts, 1) end
                  filled = true
                  break
                end
                source.insert {name = stack.name, count = 1}
              end
            end
          end
        end
        if filled then break end
      end
    end
  end
end

local function entity_data(entity)
  local box = entity.bounding_box
  local data = {
    name = entity.name,
    type = entity.type,
    unit_number = entity.unit_number,
    x = entity.position.x,
    y = entity.position.y,
    direction = entity.direction,
    status = entity.status,
    status_name = entity_status_name(entity.status),
    bounding_box = {
      left_top = {x = box.left_top.x, y = box.left_top.y},
      right_bottom = {x = box.right_bottom.x, y = box.right_bottom.y},
    },
  }
  if entity.type == "inserter" then
    data.pickup_position = entity.pickup_position
    data.drop_position = entity.drop_position
  end
  if entity.type == "underground-belt" then
    data.belt_to_ground_type = entity.belt_to_ground_type
  end
  local fluidbox = entity.fluidbox
  if fluidbox and #fluidbox > 0 then
    data.fluids = {}
    for index = 1, #fluidbox do
      local fluid = fluidbox[index]
      if fluid then
        data.fluids[#data.fluids + 1] = {
          index = index, name = fluid.name, amount = fluid.amount,
          temperature = fluid.temperature,
        }
      end
    end
  end
  if entity.type == "transport-belt" then
    data.lines = {}
    for index = 1, entity.get_max_transport_line_index() do
      data.lines[#data.lines + 1] = inventory_contents(entity.get_transport_line(index))
    end
  end
  local fuel = entity.get_fuel_inventory()
  local output = entity.type ~= "mining-drill" and entity.get_output_inventory() or nil
  if fuel then data.fuel = inventory_contents(fuel) end
  if output then data.output = inventory_contents(output) end
  if entity.type == "lab" or entity.type == "assembling-machine" then
    local index = entity.type == "lab" and defines.inventory.lab_input
      or defines.inventory.assembling_machine_input
    data.input = inventory_contents(entity.get_inventory(index))
  end
  if entity.type == "assembling-machine" then
    local recipe = entity.get_recipe()
    data.recipe = recipe and recipe.name or nil
  end
  if entity.burner then
    data.burner = {
      currently_burning = entity.burner.currently_burning and entity.burner.currently_burning.name or nil,
      remaining_burning_fuel = entity.burner.remaining_burning_fuel,
    }
  end
  return data
end

local function handle_mine(nonce, request)
  if type(request.name) ~= "string" or request.name == "" then
    return response(nonce, false, {error = "invalid-entity-name"})
  end
  local surface = surface_for(request)
  local pos = position(request)
  if not surface then return response(nonce, false, {error = "surface-not-found"}) end
  if not pos then return response(nonce, false, {error = "invalid-position"}) end
  local targets = surface.find_entities_filtered {
    position = pos,
    radius = 0.1,
    name = request.name,
  }
  local entity = targets[1]
  if not entity then return response(nonce, false, {error = "entity-not-found"}) end
  local inventory, owner, kind = treasury_inventory()
  if not inventory then return response(nonce, false, {error = "treasury-not-set"}) end
  local spill_position = {x = entity.position.x, y = entity.position.y}
  local mined = game.create_inventory(100)
  if not entity.mine {inventory = mined, force = false, raise_destroyed = true} then
    mined.destroy()
    return response(nonce, false, {error = "mine-failed"})
  end
  local spilled = {}
  for _, stack in pairs(mined.get_contents()) do
    local inserted = inventory.insert {name = stack.name, count = stack.count}
    local remainder = stack.count - inserted
    if remainder > 0 then
      surface.spill_item_stack {
        position = spill_position,
        stack = {name = stack.name, count = remainder},
        enable_looted = true,
        force = owner.force,
      }
      spilled[#spilled + 1] = {name = stack.name, count = remainder}
    end
  end
  mined.destroy()
  return response(nonce, true, {
    action = "mined",
    name = request.name,
    x = pos.x,
    y = pos.y,
    spilled = spilled,
    treasury = treasury_data(inventory, owner, kind),
  })
end

local function handle_craft(nonce, request)
  if type(request.recipe) ~= "string" or request.recipe == "" then
    return response(nonce, false, {error = "invalid-recipe-name"})
  end
  local count = math.floor(number(request.count, 1))
  if count < 1 then return response(nonce, false, {error = "invalid-count"}) end

  local player = game.get_player(1)
  if not (player and player.valid) then
    return response(nonce, false, {error = "player-not-found"})
  end
  local inventory, owner, kind = treasury_inventory()
  if kind ~= "player" then
    return response(nonce, false, {error = "crafting-requires-player-treasury"})
  end
  local recipe = player.force.recipes[request.recipe]
  if not recipe then return response(nonce, false, {error = "recipe-not-found"}) end
  if not recipe.enabled then
    return response(nonce, false, {error = "technology-locked", recipe = request.recipe})
  end
  -- Sandbox cheat mode makes hand crafting free and instant. Force normal
  -- crafting for this one action so a successful receipt always debits inputs.
  local cheat_mode = player.cheat_mode
  if cheat_mode then player.cheat_mode = false end
  local checked, craftable = pcall(player.get_craftable_count, request.recipe)
  if not checked then
    if cheat_mode then player.cheat_mode = true end
    return response(nonce, false, {error = "craft-check-failed", detail = tostring(craftable)})
  end
  if craftable < count then
    if cheat_mode then player.cheat_mode = true end
    return response(nonce, false, {
      error = "insufficient-ingredients",
      recipe = request.recipe,
      need = count,
      craftable = craftable,
    })
  end
  local crafted, started = pcall(player.begin_crafting, {
    count = count, recipe = request.recipe, silent = true,
  })
  if cheat_mode then player.cheat_mode = true end
  if not crafted then
    return response(nonce, false, {error = "craft-runtime-error", detail = tostring(started)})
  end
  if started ~= count then
    return response(nonce, false, {
      error = "craft-start-failed",
      requested = count,
      started = started,
    })
  end
  return response(nonce, true, {
    action = "crafting-started",
    recipe = request.recipe,
    count = started,
    treasury = treasury_data(inventory, owner, kind),
  })
end

-- One-time correction for the 2026-09-18 Sandbox coal demo, where cheat-mode
-- hand crafting produced a drill/chest without consuming their recipe inputs.
local function handle_repair_demo_economy(nonce, request)
  if request.key ~= "coal-demo-2026-09-18" then
    return response(nonce, false, {error = "invalid-repair-key"})
  end
  local state = bridge_state()
  if state.coal_demo_repair then
    return response(nonce, true, {action = "repair_demo_economy", already_done = true,
      debited = state.coal_demo_repair})
  end
  local inventory, owner, kind = treasury_inventory()
  if kind ~= "player" or not owner or owner.index ~= 1 or not inventory then
    return response(nonce, false, {error = "player-treasury-required"})
  end
  local debit = { ["iron-plate"] = 9, stone = 5, wood = 2,
    ["iron-gear-wheel"] = 3, ["stone-furnace"] = 1 }
  for name, count in pairs(debit) do
    if inventory.get_item_count(name) < count then
      return response(nonce, false, {error = "repair-stock-changed", item = name,
        need = count, have = inventory.get_item_count(name)})
    end
  end
  for name, count in pairs(debit) do
    if inventory.remove {name = name, count = count} ~= count then
      return response(nonce, false, {error = "repair-remove-failed", item = name})
    end
  end
  state.coal_demo_repair = debit
  helpers.write_file("coal/coal-demo-economy-repair.json",
    helpers.table_to_json {tick = game.tick, player_index = 1,
      debited = debit, reason = "cheat-mode-craft-did-not-consume-ingredients"}, false)
  return response(nonce, true, {action = "repair_demo_economy", debited = debit,
    treasury = treasury_data(inventory, owner, kind)})
end

local function handle_autofuel(nonce, request)
  if type(request.enabled) ~= "boolean" then
    return response(nonce, false, {error = "invalid-enabled"})
  end
  local state = bridge_state()
  state.autofuel_enabled = request.enabled
  return response(nonce, true, {
    action = "autofuel-set",
    enabled = state.autofuel_enabled,
    receipts = state.autofuel_receipts,
  })
end

local function handle_collect(nonce, request)
  local surface = surface_for(request)
  local pos = position(request)
  if not surface then return response(nonce, false, {error = "surface-not-found"}) end
  if not pos then return response(nonce, false, {error = "invalid-position"}) end
  if type(request.item) ~= "string" or request.item == "" then
    return response(nonce, false, {error = "invalid-item-name"})
  end
  local count = math.floor(number(request.count, 1))
  if count < 1 then return response(nonce, false, {error = "invalid-count"}) end

  local player = game.get_player(1)
  local destination = player and player.get_main_inventory()
  if not destination then return response(nonce, false, {error = "player-inventory-not-found"}) end
  local candidates = surface.find_entities_filtered {
    position = pos,
    radius = 0.1,
    type = {"container", "logistic-container", "linked-container", "furnace", "assembling-machine"},
    force = player.force,
  }
  local entity = not request.ground and candidates[1] or nil
  if not entity then
    -- Ground items are usually neutral. Copy the real stack to preserve quality,
    -- ammo, durability and tags, and remove only the amount actually transferred.
    for _, drop in pairs(surface.find_entities_filtered {
      position = pos, radius = 0.1, type = "item-entity",
      force = {player.force, game.forces.neutral},
    }) do
      if drop.stack.valid_for_read and drop.stack.name == request.item then
        entity = drop
        break
      end
    end
    if not entity then return response(nonce, false, {error = "source-not-found"}) end
    local stack = entity.stack
    local available, quality = stack.count, stack.quality.name
    if available < count then
      return response(nonce, false, {error = "insufficient-items", have = available, need = count})
    end
    if destination.get_insertable_count {name = stack.name, quality = quality} < count then
      return response(nonce, false, {error = "player-inventory-full"})
    end
    local transfer = game.create_inventory(1)
    transfer[1].set_stack(stack)
    transfer[1].count = count
    local inserted = destination.insert(transfer[1])
    transfer.destroy()
    if inserted == available then entity.destroy()
    elseif inserted > 0 then stack.count = available - inserted end
    return response(nonce, inserted == count, {
      action = "collected", error = inserted ~= count and "partial-transfer" or nil,
      item = request.item, quality = quality, count = inserted, requested = count,
      source_remaining = available - inserted, source_name = "item-on-ground",
      source = {type = "item-entity", surface = surface.name, x = pos.x, y = pos.y},
      target = {player_index = player.index},
    })
  end
  local is_chest = entity.type == "container" or entity.type == "logistic-container"
    or entity.type == "linked-container"
  local source = is_chest and entity.get_inventory(defines.inventory.chest)
    or entity.get_output_inventory()
  if not source then return response(nonce, false, {error = "output-inventory-not-found"}) end
  local available = source.get_item_count(request.item)
  if available < count then
    return response(nonce, false, {
      error = "insufficient-items",
      item = request.item,
      need = count,
      have = available,
    })
  end
  if not destination.can_insert {name = request.item, count = count} then
    return response(nonce, false, {error = "player-inventory-full"})
  end
  if destination.get_insertable_count(request.item) < count then
    return response(nonce, false, {error = "player-inventory-full"})
  end
  local removed = source.remove {name = request.item, count = count}
  if removed ~= count then
    if removed > 0 then source.insert {name = request.item, count = removed} end
    return response(nonce, false, {error = "item-removal-failed"})
  end
  local inserted = destination.insert {name = request.item, count = count}
  if inserted ~= count then
    if inserted > 0 then destination.remove {name = request.item, count = inserted} end
    source.insert {name = request.item, count = count}
    return response(nonce, false, {error = "item-insert-failed-refunded"})
  end
  return response(nonce, true, {
    action = "collected",
    item = request.item,
    count = count,
    source_remaining = source.get_item_count(request.item),
    player_total = destination.get_item_count(request.item),
    chest_unit_number = is_chest and entity.unit_number or nil,
    source_name = entity.name,
    source_unit_number = entity.unit_number,
  })
end

local function handle_ping(nonce)
  local actions = {}
  for name in pairs(HANDLERS or {}) do actions[#actions + 1] = name end
  table.sort(actions)
  return response(nonce, true, {
    action = "pong",
    tick = game.tick,
    players = #game.players,
    mod_version = script.active_mods["factorio-ai-bridge"],
    build = BRIDGE_BUILD,
    actions = actions,
  })
end

local function handle_set_treasury(nonce, request)
  local surface = surface_for(request)
  local pos = position(request)
  if not surface then return response(nonce, false, {error = "surface-not-found"}) end
  if not pos then return response(nonce, false, {error = "invalid-position"}) end

  local candidates = surface.find_entities_filtered {
    position = pos,
    radius = 1.5,
    type = CHEST_TYPES,
  }
  local chest = candidates[1]
  if not chest then return response(nonce, false, {error = "chest-not-found"}) end
  local inventory = chest.get_inventory(defines.inventory.chest)
  if not inventory then return response(nonce, false, {error = "chest-has-no-inventory"}) end

  bridge_state().treasury_entity = chest
  bridge_state().treasury_unit_number = chest.unit_number
  return response(nonce, true, {
    action = "treasury-set",
    treasury = treasury_data(inventory, chest, "container"),
  })
end

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

  local obstacles, obstacles_total, obstacles_next_offset
  if request.obstacles then
    local natural = surface.find_entities_filtered {
      area = area, type = {"tree", "simple-entity", "cliff"},
    }
    table.sort(natural, function(a, b)
      if a.position.x ~= b.position.x then return a.position.x < b.position.x end
      if a.position.y ~= b.position.y then return a.position.y < b.position.y end
      return a.name < b.name
    end)
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
    ground_items = ground_items,
    obstacles = obstacles,
    obstacles_total = obstacles_total,
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
    for _, box in pairs(proto.fluidbox_prototypes or {}) do
      fluidboxes[#fluidboxes + 1] = {
        index = box.index, production_type = box.production_type,
        filter = box.filter and box.filter.name or nil,
        pipe_connections = box.pipe_connections,
      }
    end
    return response(nonce, true, {
      action = "spec", kind = kind, name = name, entity_type = proto.type,
      mining_speed = proto.mining_speed,
      crafting_speed = (proto.type == "furnace" or proto.type == "assembling-machine")
        and proto.get_crafting_speed() or nil,
      belt_speed = proto.belt_speed,
      energy_usage_joules_per_tick = proto.energy_usage,
      energy_usage_watts = proto.energy_usage and proto.energy_usage * 60 or nil,
      burner_effectivity = proto.burner_prototype and proto.burner_prototype.effectivity or nil,
      tile_width = proto.tile_width, tile_height = proto.tile_height,
      mining_time = mine and mine.mining_time or nil,
      mining_products = products,
      fluidbox_prototypes = #fluidboxes > 0 and fluidboxes or nil,
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
      return response(nonce, false, {error = "recipe-not-found", name = name})
    end

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

-- Commission an empty assembling machine. Refuse recipe changes with items
-- present so no returned ingredients are lost or silently moved.
local function handle_set_recipe(nonce, request)
  local surface, force, pos = surface_for(request), force_for(request), position(request)
  if not surface then return response(nonce, false, {error = "surface-not-found"}) end
  if not force then return response(nonce, false, {error = "force-not-found"}) end
  if not pos then return response(nonce, false, {error = "invalid-position"}) end
  if type(request.recipe) ~= "string" or request.recipe == "" then
    return response(nonce, false, {error = "invalid-recipe-name"})
  end
  local recipe = force.recipes[request.recipe]
  if not recipe then return response(nonce, false, {error = "recipe-not-found"}) end
  if not recipe.enabled then return response(nonce, false, {error = "technology-locked"}) end
  local targets = surface.find_entities_filtered {
    position = pos, radius = 0.1, force = force, type = "assembling-machine",
  }
  local entity = targets[1]
  if not entity then return response(nonce, false, {error = "assembler-not-found"}) end
  if not entity.prototype.crafting_categories[recipe.category] then
    return response(nonce, false, {error = "recipe-category-not-supported"})
  end
  local current = entity.get_recipe()
  if current then
    if current.name == recipe.name then
      return response(nonce, true, {action = "recipe-set", name = entity.name,
        x = pos.x, y = pos.y, recipe = recipe.name, unchanged = true})
    end
    return response(nonce, false, {error = "recipe-already-set", current = current.name})
  end
  for _, index in pairs {
    defines.inventory.assembling_machine_input,
    defines.inventory.assembling_machine_output,
    defines.inventory.assembling_machine_dump,
    defines.inventory.assembling_machine_trash,
  } do
    local inventory = entity.get_inventory(index)
    if inventory and not inventory.is_empty() then
      return response(nonce, false, {error = "assembler-not-empty"})
    end
  end
  local removed = entity.set_recipe(recipe.name)
  if #removed > 0 then
    local treasury = treasury_inventory()
    for _, stack in pairs(removed) do
      local item = {name = stack.name, count = stack.count, quality = stack.quality}
      local inserted = treasury and treasury.insert(item) or 0
      if inserted < stack.count then
        item.count = stack.count - inserted
        surface.spill_item_stack {
          position = pos, stack = item, enable_looted = true, force = force,
        }
      end
    end
    return response(nonce, true, {action = "recipe-set", name = entity.name,
      x = pos.x, y = pos.y, recipe = recipe.name, removed = removed})
  end
  return response(nonce, true, {action = "recipe-set", name = entity.name,
    x = pos.x, y = pos.y, recipe = recipe.name, unchanged = false})
end

local function handle_research(nonce, request)
  local force = force_for(request)
  if not force then return response(nonce, false, {error = "force-not-found"}) end
  local name = request.name
  if name ~= nil and (type(name) ~= "string" or name == "") then
    return response(nonce, false, {error = "invalid-technology-name"})
  end
  local tech = name and force.technologies[name] or nil
  if name and not tech then
    return response(nonce, false, {error = "technology-not-found"})
  end
  if request.start ~= nil and type(request.start) ~= "boolean" then
    return response(nonce, false, {error = "invalid-start"})
  end
  if request.start then
    if not tech then return response(nonce, false, {error = "technology-required"}) end
    if tech.researched then return response(nonce, false, {error = "already-researched"}) end
    if not tech.enabled then return response(nonce, false, {error = "technology-disabled"}) end
    -- Busy lab queue: append instead of refusing (2.0 research queue).
    local queued = false
    for _, t in pairs(force.research_queue or {}) do
      if t.name == name then queued = true end
    end
    if not queued and not force.add_research(name) then
      local missing = {}
      for pname, pre in pairs(tech.prerequisites) do
        if not pre.researched then missing[#missing + 1] = pname end
      end
      table.sort(missing)
      return response(nonce, false, {error = "cannot-queue", missing_prerequisites = missing,
        current = force.current_research and force.current_research.name or nil})
    end
  end
  local current = force.current_research
  local ingredients = {}
  local subject = tech or current
  if subject then
    for _, ingredient in pairs(subject.research_unit_ingredients or {}) do
      ingredients[#ingredients + 1] = {name = ingredient.name, amount = ingredient.amount}
    end
  end
  local queue = {}
  for _, t in pairs(force.research_queue or {}) do queue[#queue + 1] = t.name end
  local labs = {}
  local surface = surface_for(request)
  if surface then
    for _, lab in pairs(surface.find_entities_filtered {type = "lab", force = force}) do
      local key = entity_status_name(lab.status) or "unknown"
      labs[key] = (labs[key] or 0) + 1
    end
  end
  local available = {}
  if request.available then
    for tname, t in pairs(force.technologies) do
      if t.enabled and not t.researched then
        local ready = true
        for _, pre in pairs(t.prerequisites) do if not pre.researched then ready = false break end end
        if ready then available[#available + 1] = tname end
      end
    end
    table.sort(available)
  end
  return response(nonce, true, {
    action = "research", tick = game.tick, force = force.name,
    queue = queue, labs = labs, available = request.available and available or nil,
    current = current and current.name or nil,
    progress = current and force.research_progress or nil,
    requested = name,
    researched = tech and tech.researched or nil,
    enabled = tech and tech.enabled or nil,
    unit_count = subject and subject.research_unit_count or nil,
    unit_energy = subject and subject.research_unit_energy or nil,
    ingredients = ingredients,
  })
end

local function handle_insert(nonce, request)
  local surface, force, pos = surface_for(request), force_for(request), position(request)
  if not surface then return response(nonce, false, {error = "surface-not-found"}) end
  if not force then return response(nonce, false, {error = "force-not-found"}) end
  if not pos then return response(nonce, false, {error = "invalid-position"}) end
  if type(request.item) ~= "string" or not prototypes.item[request.item] then
    return response(nonce, false, {error = "item-not-found"})
  end
  local count = number(request.count)
  if not count or count < 1 or count ~= math.floor(count) then
    return response(nonce, false, {error = "invalid-count"})
  end
  local targets = surface.find_entities_filtered {
    position = pos, radius = 0.1, force = force,
  }
  local entity = targets[1]
  if not entity then return response(nonce, false, {error = "entity-not-found"}) end
  local index
  local slot
  if entity.type == "lab" then
    index, slot = defines.inventory.lab_input, "input"
  elseif entity.type == "assembling-machine" then
    index, slot = defines.inventory.assembling_machine_input, "input"
  elseif entity.type == "ammo-turret" then
    index, slot = defines.inventory.turret_ammo, "input"
  elseif entity.type == "furnace" and request.source then
    index, slot = defines.inventory.furnace_source, "source"
  elseif entity.type == "container" or entity.type == "logistic-container"
    or entity.type == "linked-container" then
    index, slot = defines.inventory.chest, "chest"
  else
    slot = "fuel"
  end
  local destination = index and entity.get_inventory(index) or entity.get_fuel_inventory()
  if not destination then
    if index then return response(nonce, false, {error = "input-inventory-not-found"}) end
    return response(nonce, false, {error = "entity-has-no-fuel-inventory"})
  end
  local source, _, kind = treasury_inventory()
  if not source then return response(nonce, false, {error = "treasury-not-set"}) end
  local available = source.get_item_count(request.item)
  if available < count then
    return response(nonce, false, {error = "insufficient-items", have = available, need = count})
  end
  local stack = {name = request.item, count = count}
  if not destination.can_insert(stack) then
    return response(nonce, false, {
      error = slot == "fuel" and "fuel-not-accepted" or "input-rejects-item",
      item = request.item,
    })
  end
  if destination.get_insertable_count(request.item) < count then
    return response(nonce, false, {error = "insufficient-input-capacity"})
  end
  local removed = source.remove(stack)
  if removed ~= count then
    if removed > 0 then source.insert {name = request.item, count = removed} end
    return response(nonce, false, {error = "item-removal-failed"})
  end
  local inserted = destination.insert(stack)
  if inserted < count then
    if inserted > 0 then destination.remove {name = request.item, count = inserted} end
    source.insert(stack)
    return response(nonce, false, {error = "insert-failed-refunded"})
  end
  return response(nonce, true, {
    action = "insert",
    item = request.item, count = inserted, requested = count, slot = slot,
    remaining = source.get_item_count(request.item), treasury_kind = kind,
    target = {name = entity.name, x = entity.position.x, y = entity.position.y},
  })
end

local function handle_place(nonce, request)
  if type(request.name) ~= "string" or request.name == "" then
    return response(nonce, false, {error = "invalid-entity-name"})
  end
  local surface = surface_for(request)
  local force = force_for(request)
  local pos = position(request)
  if not surface then return response(nonce, false, {error = "surface-not-found"}) end
  if not force then return response(nonce, false, {error = "force-not-found"}) end
  if not pos then return response(nonce, false, {error = "invalid-position"}) end

  local prototype = prototypes.entity[request.name]
  if not prototype then return response(nonce, false, {error = "entity-not-found"}) end
  local item = prototype.items_to_place_this and prototype.items_to_place_this[1]
  local recipe = item and force.recipes[item.name]

  local direction = request.direction or "north"
  if type(direction) == "string" then direction = DIRECTIONS[direction] end
  if type(direction) ~= "number" then
    return response(nonce, false, {error = "invalid-direction"})
  end
  if request.type ~= nil and (prototype.type ~= "underground-belt"
    or (request.type ~= "input" and request.type ~= "output")) then
    return response(nonce, false, {error = "invalid-belt-type"})
  end

  -- Dry run: report every blocker, build nothing, spend nothing.
  if request.dry_run then
    local probe_inventory, _, probe_kind = treasury_inventory()
    local have = 0
    if item and probe_inventory then have = probe_inventory.get_item_count(item.name) end
    local recipe_enabled = not recipe or recipe.enabled
    local can_place = surface.can_place_entity {
      name = request.name, position = pos, direction = direction, force = force,
    }
    local blockers = {}
    if not item then blockers[#blockers + 1] = "entity-has-no-place-item" end
    if recipe and not recipe_enabled then blockers[#blockers + 1] = "technology-locked" end
    if not probe_inventory then blockers[#blockers + 1] = "treasury-not-set" end
    if item and probe_inventory and have < item.count then
      blockers[#blockers + 1] = "insufficient-items"
    end
    if not can_place then blockers[#blockers + 1] = "cannot-place" end
    return response(nonce, true, {
      action = "probe", tick = game.tick, name = request.name,
      surface = surface.name, x = pos.x, y = pos.y, direction = direction,
      tile = surface.get_tile(math.floor(pos.x), math.floor(pos.y)).name,
      tile_width = prototype.tile_width, tile_height = prototype.tile_height,
      can_place = can_place,
      place_item = item and {name = item.name, count = item.count} or nil,
      have = have,
      recipe_enabled = recipe_enabled,
      treasury_kind = probe_kind,
      blockers = blockers,
      would_build = #blockers == 0,
    })
  end

  if not item then return response(nonce, false, {error = "entity-has-no-place-item"}) end
  if recipe and not recipe.enabled then
    return response(nonce, false, {error = "technology-locked", item = item.name})
  end

  local inventory, _, treasury_kind = treasury_inventory()
  if not inventory then return response(nonce, false, {error = "treasury-not-set"}) end
  local available = inventory.get_item_count(item.name)
  if available < item.count then
    return response(nonce, false, {
      error = "insufficient-items",
      item = item.name,
      need = item.count,
      have = available,
    })
  end

  local build = {
    name = request.name,
    position = pos,
    direction = direction,
    force = force,
  }
  if not surface.can_place_entity(build) then
    return response(nonce, false, {error = "cannot-place"})
  end

  local removed = inventory.remove {name = item.name, count = item.count}
  if removed ~= item.count then
    if removed > 0 then inventory.insert {name = item.name, count = removed} end
    return response(nonce, false, {error = "item-removal-failed"})
  end

  build.raise_built = true
  build.create_build_effect_smoke = true
  if prototype.type == "underground-belt" then build.type = request.type or "input" end
  local entity = surface.create_entity(build)
  if not entity then
    inventory.insert {name = item.name, count = item.count}
    return response(nonce, false, {error = "create-failed-refunded"})
  end

  return response(nonce, true, {
    action = "placed",
    entity = {
      name = entity.name,
      unit_number = entity.unit_number,
      surface = entity.surface.name,
      x = entity.position.x,
      y = entity.position.y,
      direction = entity.direction,
      belt_to_ground_type = entity.type == "underground-belt" and entity.belt_to_ground_type or nil,
    },
    spent = {name = item.name, count = item.count},
    remaining = inventory.get_item_count(item.name),
    treasury_kind = treasury_kind,
  })
end

local function handle_blueprint_export(nonce, request)
  local surface, force = surface_for(request), force_for(request)
  if not surface then return response(nonce, false, {error = "surface-not-found"}) end
  if not force then return response(nonce, false, {error = "force-not-found"}) end
  local x1, y1 = number(request.x1), number(request.y1)
  local x2, y2 = number(request.x2), number(request.y2)
  if not (x1 and y1 and x2 and y2) or x1 >= x2 or y1 >= y2
    or x2 - x1 > 64 or y2 - y1 > 64 then
    return response(nonce, false, {error = "invalid-area"})
  end
  local inventory = game.create_inventory(1)
  local stack = inventory[1]
  local ok, result = pcall(function()
    stack.set_stack {name = "blueprint", count = 1}
    stack.create_blueprint {
      surface = surface, force = force, area = {{x1, y1}, {x2, y2}},
      always_include_tiles = false, include_fuel = false,
    }
    local count = stack.get_blueprint_entity_count()
    return {count = count, value = count > 0 and stack.export_stack() or nil}
  end)
  inventory.destroy()
  if not ok then return response(nonce, false, {error = "blueprint-export-failed", detail = tostring(result)}) end
  if not result.value then return response(nonce, false, {error = "empty-blueprint"}) end
  if #result.value > 24000 then
    return response(nonce, false, {error = "blueprint-too-large", entities = result.count})
  end
  return response(nonce, true, {
    action = "blueprint_export", surface = surface.name,
    entities = result.count, blueprint = result.value,
  })
end

-- Revived blueprint ghosts do not auto-wire like hand placement: copper-wire a new pole to
-- every own pole in reach (both poles' max wire distance), nearest first, up to 5.
local function wire_pole(entity)
  if not (entity and entity.valid and entity.type == "electric-pole") then return 0 end
  local copper = defines.wire_connector_id.pole_copper
  local function reach(e)
    local ok, d = pcall(function() return e.prototype.get_max_wire_distance(e.quality) end)
    if ok and d then return d end
    return e.prototype.max_wire_distance or 0
  end
  local mine = entity.get_wire_connector(copper, true)
  local r = reach(entity)
  local near = entity.surface.find_entities_filtered {
    position = entity.position, radius = r + 0.01, type = "electric-pole", force = entity.force,
  }
  local function d(e) local dx, dy = e.position.x - entity.position.x, e.position.y - entity.position.y return math.sqrt(dx * dx + dy * dy) end
  table.sort(near, function(a, b) return d(a) < d(b) end)
  local wired = 0
  for _, other in ipairs(near) do
    if wired >= 5 then break end
    if other ~= entity and d(other) <= math.min(r, reach(other)) + 0.01 then
      local theirs = other.get_wire_connector(copper, true)
      if mine.is_connected_to(theirs) or mine.connect_to(theirs, false, defines.wire_origin.player) then
        wired = wired + 1
      end
    end
  end
  return wired
end

local function handle_blueprint_import(nonce, request)
  local surface, force, pos = surface_for(request), force_for(request), position(request)
  if not surface then return response(nonce, false, {error = "surface-not-found"}) end
  if not force then return response(nonce, false, {error = "force-not-found"}) end
  if not pos then return response(nonce, false, {error = "invalid-position"}) end
  if type(request.blueprint) ~= "string" or #request.blueprint > 24000
    or request.blueprint:sub(1, 1) ~= "0" then
    return response(nonce, false, {error = "invalid-blueprint"})
  end
  local inventory = game.create_inventory(1)
  local stack = inventory[1]
  local ok, imported = pcall(function() return stack.import_stack(request.blueprint) end)
  if not ok then
    inventory.destroy()
    return response(nonce, false, {error = "blueprint-import-failed", detail = tostring(imported)})
  end
  if imported ~= 0 or stack.name ~= "blueprint" or not stack.is_blueprint_setup() then
    inventory.destroy()
    return response(nonce, false, {error = "blueprint-import-failed", code = imported})
  end
  local count = stack.get_blueprint_entity_count()
  local tiles = stack.get_blueprint_tiles()
  if tiles and #tiles > 0 then
    inventory.destroy()
    return response(nonce, false, {error = "blueprint-tiles-not-supported"})
  end
  if count > 500 then
    inventory.destroy()
    return response(nonce, false, {error = "blueprint-too-many-entities", entities = count})
  end
  local mode = request.mode or "direct"
  local rotation = request.direction or defines.direction.north
  if rotation ~= 0 and rotation ~= 4 and rotation ~= 8 and rotation ~= 12 then
    inventory.destroy()
    return response(nonce, false, {error = "invalid-blueprint-direction"})
  end
  if mode ~= "direct" and mode ~= "ghosts" then
    inventory.destroy()
    return response(nonce, false, {error = "invalid-blueprint-mode"})
  end
  local source, source_owner, treasury_kind
  local costs = {}
  if mode == "direct" then
    if count > 64 then
      inventory.destroy()
      return response(nonce, false, {error = "direct-blueprint-too-large", entities = count, limit = 64})
    end
    source, source_owner, treasury_kind = treasury_inventory()
    if not source then
      inventory.destroy()
      return response(nonce, false, {error = "treasury-not-set"})
    end
    for _, entry in pairs(stack.get_blueprint_entities() or {}) do
      local prototype = prototypes.entity[entry.name]
      local item = prototype and prototype.items_to_place_this
        and prototype.items_to_place_this[1]
      if not item then
        inventory.destroy()
        return response(nonce, false, {error = "entity-has-no-place-item", name = entry.name})
      end
      local recipe = force.recipes[item.name]
      if recipe and not recipe.enabled then
        inventory.destroy()
        return response(nonce, false, {error = "technology-locked", item = item.name})
      end
      if entry.recipe then
        local configured = force.recipes[entry.recipe]
        if not configured or not configured.enabled then
          inventory.destroy()
          return response(nonce, false, {error = "configured-recipe-locked", recipe = entry.recipe})
        end
      end
      costs[item.name] = (costs[item.name] or 0) + item.count
    end
    for item, need in pairs(costs) do
      local have = source.get_item_count(item)
      if have < need then
        inventory.destroy()
        return response(nonce, false, {
          error = "insufficient-items", item = item, need = need, have = have,
        })
      end
    end
  end
  local built, ghosts = pcall(function()
    return stack.build_blueprint {
      surface = surface, force = force, position = pos,
      direction = rotation,
      build_mode = defines.build_mode.normal, raise_built = true,
    }
  end)
  inventory.destroy()
  if not built then return response(nonce, false, {error = "blueprint-build-failed", detail = tostring(ghosts)}) end
  if #ghosts ~= count then
    for _, ghost in pairs(ghosts) do if ghost.valid then ghost.destroy() end end
    return response(nonce, false, {error = "blueprint-blocked", expected = count, ghosts = #ghosts})
  end
  if mode == "ghosts" then
    return response(nonce, true, {
      action = "blueprint_import", mode = mode, ghosts = count,
      x = pos.x, y = pos.y, surface = surface.name,
    })
  end
  local overflow = game.create_inventory(count + 10)
  local spent, receipts, placed, failure = {}, {}, 0, nil
  for _, ghost in ipairs(ghosts) do
    local name, x, y = ghost.ghost_name, ghost.position.x, ghost.position.y
    local item = prototypes.entity[name].items_to_place_this[1]
    local removed = source.remove {name = item.name, count = item.count}
    if removed ~= item.count then
      if removed > 0 then source.insert {name = item.name, count = removed} end
      failure = "item-removal-failed"
      break
    end
    local ok_revive, _, entity = pcall(function()
      return ghost.revive {raise_revive = false, overflow = overflow}
    end)
    if not ok_revive or not entity then
      source.insert {name = item.name, count = item.count}
      failure = "revive-failed-refunded"
      break
    end
    spent[item.name] = (spent[item.name] or 0) + item.count
    placed = placed + 1
    receipts[#receipts + 1] = {
      name = name, x = x, y = y, item = item.name, count = item.count,
      wires = entity.type == "electric-pole" and wire_pole(entity) or nil,
    }
  end
  if failure then
    for _, ghost in pairs(ghosts) do if ghost.valid then ghost.destroy() end end
  end
  local spilled = {}
  for _, item in pairs(overflow.get_contents()) do
    local inserted = source.insert {name = item.name, count = item.count}
    if inserted < item.count then
      local remaining = item.count - inserted
      surface.spill_item_stack {
        position = pos, stack = {name = item.name, count = remaining},
        enable_looted = true, force = force,
      }
      spilled[#spilled + 1] = {name = item.name, count = remaining}
    end
  end
  overflow.destroy()
  return response(nonce, not failure, {
    action = "blueprint_import", mode = mode, expected = count,
    placed = placed, spent = spent, receipts = receipts, spilled = spilled,
    source = {
      kind = treasury_kind, x = source_owner.position.x,
      y = source_owner.position.y,
      unit_number = treasury_kind == "container" and source_owner.unit_number or nil,
      player_index = treasury_kind == "player" and source_owner.index or nil,
    },
    x = pos.x, y = pos.y,
    surface = surface.name, error = failure,
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

local smelting = require("smelting").attach {
  state = bridge_state, response = response, inventory = treasury_inventory,
  place = handle_place, export = handle_blueprint_export, status_name = entity_status_name,
}
local starter = require("starter").attach {
  state = bridge_state, response = response, inventory = treasury_inventory,
  place = handle_place, insert = handle_insert, mine = handle_mine, export = handle_blueprint_export,
}
local coal = require("coal").attach {
  state = bridge_state, response = response, inventory = treasury_inventory,
  place = handle_place, insert = handle_insert, export = handle_blueprint_export,
}
local executor = require("executor").attach {
  state = bridge_state, response = response, inventory = treasury_inventory,
  import = handle_blueprint_import, craft = handle_craft, collect = handle_collect,
  mine = handle_mine, insert = handle_insert,
}
local field = require("field").attach {
  state = bridge_state, response = response, inventory = treasury_inventory,
  fluid_tiles = fluid_tile_names,
}
local function handle_water_sites(nonce, request) return field.water(nonce, request) end
local function handle_recall(nonce, request) return field.recall(nonce, request) end
local function handle_blueprint_run(nonce, request) return executor.start(nonce, request) end
local function handle_blueprint_job(nonce, request) return executor.status(nonce, request) end
local function handle_smelt_plan(nonce, request) return smelting.plan(nonce, request) end
local function handle_smelt_build(nonce, request) return smelting.build(nonce, request) end
local function handle_smelt_status(nonce, request) return smelting.status(nonce, request) end
local function handle_starter_smelt(nonce, request) return starter.start(nonce, request) end
local function handle_starter_status(nonce, request) return starter.status(nonce, request) end
local function handle_coal_stockpile(nonce, request) return coal.start(nonce, request) end
local function handle_coal_status(nonce, request) return coal.status(nonce, request) end

HANDLERS = {
  audit = handle_audit,
  autofuel = handle_autofuel,
  brief = handle_brief,
  blueprint_export = handle_blueprint_export,
  blueprint_import = handle_blueprint_import,
  blueprint_run = handle_blueprint_run,
  blueprint_job = handle_blueprint_job,
  collect = handle_collect,
  craft = handle_craft,
  repair_demo_economy = handle_repair_demo_economy,
  index = handle_index,
  insert = handle_insert,
  mine = handle_mine,
  ore_marks = handle_ore_marks,
  ping = handle_ping,
  research = handle_research,
  spec = handle_spec,
  set_treasury = handle_set_treasury,
  set_recipe = handle_set_recipe,
  snapshot = handle_snapshot,
  smelt_plan = handle_smelt_plan,
  smelt_build = handle_smelt_build,
  smelt_status = handle_smelt_status,
  starter_smelt = handle_starter_smelt,
  starter_status = handle_starter_status,
  coal_stockpile = handle_coal_stockpile,
  coal_status = handle_coal_status,
  place = handle_place,
  recall = handle_recall,
  water_sites = handle_water_sites,
}

local function on_packet(event)
  local payload = event.payload or ""
  if #payload > MAX_PACKET_BYTES then
    send(event, response(nil, false, {error = "packet-too-large"}))
    return
  end

  local ok, request = pcall(helpers.json_to_table, payload)
  if not ok or type(request) ~= "table" then
    send(event, response(nil, false, {error = "invalid-json"}))
    return
  end
  local nonce = request.nonce
  if type(nonce) ~= "string" or nonce == "" or #nonce > 128 then
    send(event, response(nil, false, {error = "invalid-nonce"}))
    return
  end

  local cached = bridge_state().responses[nonce]
  if cached then
    send(event, cached)
    return
  end
  if request.v ~= BRIDGE_VERSION then
    local value = response(nonce, false, {error = "unsupported-version"})
    remember_response(nonce, value)
    send(event, value)
    return
  end

  local handler = HANDLERS[request.action]
  local value
  if not handler then
    value = response(nonce, false, {error = "unknown-action"})
  else
    local handled, result = pcall(handler, nonce, request)
    value = handled and result or response(nonce, false, {
      error = "internal-error",
      detail = tostring(result),
    })
  end
  remember_response(nonce, value)
  send(event, value)
end

script.on_init(bridge_state)
script.on_configuration_changed(bridge_state)
script.on_event(defines.events.on_udp_packet_received, on_packet)
script.on_nth_tick(1, function() helpers.recv_udp() end)
script.on_nth_tick(60, function()
  smelting.tick()
  starter.tick()
  coal.tick()
  executor.tick()
end)
script.on_nth_tick(300, function()
  for _, surface in pairs(game.surfaces) do
    autofuel_surface(surface, game.forces.player)
  end
end)

-- A newly generated chunk invalidates the cached whole-map bounds; the next
-- index request rebuilds from scratch.
script.on_event(defines.events.on_chunk_generated, function()
  bridge_state().index = nil
end)
