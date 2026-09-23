-- World writes: recipes, research, rocket launch, place, blueprint export/import.
local core = require("core")
local DIRECTIONS, bridge_state, entity_status_name, force_for = core.DIRECTIONS, core.bridge_state, core.entity_status_name, core.force_for
local number, position, response, surface_for = core.number, core.position, core.response, core.surface_for
local treasury, treasury_inventory = core.treasury, core.treasury_inventory

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

-- Backlog refill, 23/09: the cheat drained a 7-deep queue in minutes and labs sat idle.
-- Agent sets an ordered wishlist; each finished research tops the queue up from it.
-- A tech needing a pack no lab holds would stall the queue head (23/09: ICB-4 wanted
-- purple, 12 labs idle), so it waits in the backlog until labs carry that pack.
local function lab_packs(force)
  local held = {}
  for _, surface in pairs(game.surfaces) do
    for _, lab in pairs(surface.find_entities_filtered {type = "lab", force = force}) do
      local inv = lab.get_inventory(defines.inventory.lab_input)
      for _, it in pairs(inv and inv.get_contents() or {}) do held[it.name] = true end
    end
  end
  return held
end

local function refill_research(force)
  local state = bridge_state()
  local left = {}
  local held = lab_packs(force)
  for _, name in ipairs(state.research_backlog or {}) do
    local t = force.technologies[name]
    local feedable = true
    for _, ing in pairs(t and t.research_unit_ingredients or {}) do
      if not held[ing.name] then feedable = false end
    end
    if t and not t.researched and not feedable then
      left[#left + 1] = name
    elseif t and not t.researched then
      local queued = false
      for _, q in pairs(force.research_queue or {}) do if q.name == name then queued = true end end
      if not queued and not force.add_research(name) then left[#left + 1] = name end
    end
  end
  state.research_backlog = left
  return left
end

local function handle_research(nonce, request)
  local force = force_for(request)
  if not force then return response(nonce, false, {error = "force-not-found"}) end
  if request.backlog ~= nil then
    if type(request.backlog) ~= "table" then return response(nonce, false, {error = "invalid-backlog"}) end
    for _, n in ipairs(request.backlog) do
      if type(n) ~= "string" or not force.technologies[n] then
        return response(nonce, false, {error = "technology-not-found", name = n})
      end
    end
    bridge_state().research_backlog = request.backlog
    force.research_queue = {}  -- the backlog is the whole plan; drops stale/stalled heads
    refill_research(force)
  end
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
    backlog = bridge_state().research_backlog,
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

-- Rocket launch, 23/09: the silo holds a finished rocket and nothing else in the bridge
-- could press the GUI button. x,y may be any point on the 9x9 silo.
local function handle_launch(nonce, request)
  local surface = surface_for(request)
  local pos = position(request)
  if not surface or not pos then return response(nonce, false, {error = "invalid-position"}) end
  local silo = surface.find_entities_filtered {position = pos, radius = 5, type = "rocket-silo"}[1]
  if not silo then return response(nonce, false, {error = "silo-not-found"}) end
  local status = entity_status_name(silo.status)
  local ok = silo.launch_rocket()
  return response(nonce, ok, {action = "launch", status = status,
    error = not ok and "not-ready" or nil, x = silo.position.x, y = silo.position.y})
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
    -- create_blueprint hands back the blueprint-index -> source-entity mapping, so the
    -- anchor below is computed from EXACTLY the entities the blueprint holds, ghosts
    -- included. Anything else (re-scanning the area, reading the blueprint's own local
    -- coordinates) is a second guess at the same frame, and a guess is what drifted.
    local mapping = stack.create_blueprint {
      surface = surface, force = force, area = {{x1, y1}, {x2, y2}},
      always_include_tiles = false, include_fuel = false,
    }
    -- The executor anchors a layout at the TOP-LEFT TILE EDGE of its footprint, never at
    -- an entity centre: a 3x3 drill centres on .5 and a 2x2 furnace on an integer, so any
    -- floor() of a centre is off by half a footprint for one of them. Measured 21/09: the
    -- peer session read the centre-based bbox, floored it, and every rebuilt ghost landed
    -- one tile east of the ghosts a human had placed.
    local ax, ay = math.huge, math.huge
    for _, entity in pairs(mapping or {}) do
      if entity.valid then
        local name = entity.type == "entity-ghost" and entity.ghost_name or entity.name
        local proto = prototypes.entity[name]
        if proto then
          local w, h = proto.tile_width, proto.tile_height
          if (entity.direction or 0) % 8 ~= 0 then w, h = h, w end
          ax = math.min(ax, entity.position.x - w / 2)
          ay = math.min(ay, entity.position.y - h / 2)
        end
      end
    end
    local count = stack.get_blueprint_entity_count()
    return {count = count, value = count > 0 and stack.export_stack() or nil,
            anchor = ax < math.huge and {x = ax, y = ay} or nil}
  end)
  inventory.destroy()
  if not ok then return response(nonce, false, {error = "blueprint-export-failed", detail = tostring(result)}) end
  if not result.value then return response(nonce, false, {error = "empty-blueprint"}) end
  if #result.value > 24000 then
    return response(nonce, false, {error = "blueprint-too-large", entities = result.count})
  end
  return response(nonce, true, {
    action = "blueprint_export", surface = surface.name,
    entities = result.count, blueprint = result.value, anchor = result.anchor,
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
  if count > 1000 then
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
  if #ghosts ~= count and mode == "direct" then
    for _, ghost in pairs(ghosts) do if ghost.valid then ghost.destroy() end end
    return response(nonce, false, {error = "blueprint-blocked", expected = count, ghosts = #ghosts})
  end
  if mode == "ghosts" then
    -- Measured 20/09 (tests/verify_ghost_runtime.py): the engine drops ONLY the entity
    -- whose tiles are taken and keeps the rest. A partial paste is the normal case over a
    -- live base, so it is reported, not destroyed.
    return response(nonce, true, {
      action = "blueprint_import", mode = mode, ghosts = #ghosts, planned = count,
      blocked = count - #ghosts,
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

return {
  handle_blueprint_export = handle_blueprint_export,
  handle_blueprint_import = handle_blueprint_import,
  handle_launch = handle_launch,
  handle_place = handle_place,
  handle_research = handle_research,
  handle_set_recipe = handle_set_recipe,
  refill_research = refill_research,
  wire_pole = wire_pole,
}
