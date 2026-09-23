-- Real-item handlers: mine, craft, collect, insert, autofuel, treasury. Never spawns items.
local core = require("core")
local CHEST_TYPES, bridge_state, force_for, number = core.CHEST_TYPES, core.bridge_state, core.force_for, core.number
local position, response, surface_for, treasury = core.position, core.response, core.surface_for, core.treasury
local treasury_data, treasury_inventory = core.treasury_data, core.treasury_inventory

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
  elseif entity.type == "roboport" then
    -- Robots go in the robot slots, repair packs in the material slots (21/09: 10
    -- construction robots had no way in short of maintainer loading them by hand).
    if prototypes.item[request.item].type == "repair-tool" then
      index, slot = defines.inventory.roboport_material, "material"
    else
      index, slot = defines.inventory.roboport_robot, "robot"
    end
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

return {
  handle_autofuel = handle_autofuel,
  handle_collect = handle_collect,
  handle_craft = handle_craft,
  handle_insert = handle_insert,
  handle_mine = handle_mine,
  handle_repair_demo_economy = handle_repair_demo_economy,
  handle_set_treasury = handle_set_treasury,
}
