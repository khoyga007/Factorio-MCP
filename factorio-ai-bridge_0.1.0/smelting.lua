-- One reusable, measured pattern. Geometry is fixed; rates come from prototypes.
local M = {}
local VERSION = 1
local STEP = {[0] = {0, -1}, [4] = {1, 0}, [8] = {0, 1}, [12] = {-1, 0}}
local SIZES = {
  ["stone-furnace"] = {2, 2}, ["inserter"] = {1, 1},
  ["transport-belt"] = {1, 1}, ["small-electric-pole"] = {1, 1},
  ["wooden-chest"] = {1, 1},
}

local function finite(n)
  return type(n) == "number" and n == n and math.abs(n) < 1000000
end

local function rotate(x, y, turn)
  for _ = 1, turn do x, y = -y, x end
  return x, y
end

function M.layout(n, x, y, turn)
  local entities = {}
  local function add(name, dx, dy, direction)
    dx, dy = rotate(dx, dy, turn)
    entities[#entities + 1] = {name = name, x = x + dx, y = y + dy,
      direction = ((direction or 0) + turn * 4) % 16}
  end
  for i = 0, n * 3 - 1 do
    add("transport-belt", i + 0.5, -2.5, 4)
  end
  for i = 0, n - 1 do
    add("stone-furnace", 1 + i * 3, 0)
    add("inserter", 1.5 + i * 3, -1.5, 0)
    add("inserter", 1.5 + i * 3, 1.5, 0)
    add("wooden-chest", 1.5 + i * 3, 2.5)
    add("small-electric-pole", 2.5 + i * 3, 0.5)
  end
  local ix, iy = rotate(0.5, -2.5, turn)
  return entities, {x = x + ix, y = y + iy, direction = (4 + turn * 4) % 16}
end

local function footprint(entities)
  local occupied, bounds = {}, {1e9, 1e9, -1e9, -1e9}
  for _, e in ipairs(entities) do
    local size = SIZES[e.name]
    local w, h = size[1], size[2]
    if e.direction == 4 or e.direction == 12 then w, h = h, w end
    local left, top = e.x - w / 2, e.y - h / 2
    bounds[1], bounds[2] = math.min(bounds[1], left), math.min(bounds[2], top)
    bounds[3], bounds[4] = math.max(bounds[3], left + w), math.max(bounds[4], top + h)
    for tx = math.floor(left + 0.001), math.ceil(left + w - 0.001) - 1 do
      for ty = math.floor(top + 0.001), math.ceil(top + h - 0.001) - 1 do
        local key = tx .. ":" .. ty
        if occupied[key] then return nil end
        occupied[key] = true
      end
    end
  end
  return occupied, bounds
end

function M.route(source, port, occupied, x_first)
  local ds, dp = STEP[source.direction], STEP[port.direction]
  if not ds or not dp then return nil end
  local x, y = source.x + ds[1], source.y + ds[2]
  local ex, ey = port.x - dp[1], port.y - dp[2]
  if math.abs(x - ex) + math.abs(y - ey) > 32 then return nil end
  local points = {{x, y}}
  for axis = 1, 2 do
    local horizontal = (axis == 1) == x_first
    while (horizontal and x ~= ex) or (not horizontal and y ~= ey) do
      if horizontal then x = x + (ex > x and 1 or -1)
      else y = y + (ey > y and 1 or -1) end
      points[#points + 1] = {x, y}
      if #points > 34 then return nil end
    end
  end
  points[#points + 1] = {port.x, port.y}
  local belts, seen = {}, {}
  for i = 1, #points - 1 do
    local a, b = points[i], points[i + 1]
    local key = math.floor(a[1]) .. ":" .. math.floor(a[2])
    if occupied[key] or seen[key] or (a[1] == source.x and a[2] == source.y) then return nil end
    seen[key] = true
    local dx, dy = b[1] - a[1], b[2] - a[2]
    if math.abs(dx) + math.abs(dy) ~= 1 then return nil end
    local direction = dx == 1 and 4 or dx == -1 and 12 or dy == 1 and 8 or 0
    belts[#belts + 1] = {name = "transport-belt", x = a[1], y = a[2], direction = direction}
  end
  return belts
end

local function model(rate)
  if not finite(rate) or rate <= 0 then return nil, "invalid-rate" end
  for name, size in pairs(SIZES) do
    local p = prototypes.entity[name]
    if not p or p.tile_width ~= size[1] or p.tile_height ~= size[2] then
      return nil, "pattern-prototype-mismatch:" .. name
    end
  end
  local f, belt = prototypes.entity["stone-furnace"], prototypes.entity["transport-belt"]
  local r = prototypes.recipe["iron-plate"]
  if not r or #r.ingredients ~= 1 or r.ingredients[1].name ~= "iron-ore"
    or #r.products ~= 1 or r.products[1].name ~= "iron-plate"
    or not r.products[1].amount or (r.products[1].probability or 1) ~= 1 then
    return nil, "pattern-recipe-mismatch"
  end
  local per_furnace = f.get_crafting_speed() / r.energy * r.products[1].amount * 60
  local n = math.max(1, math.ceil(rate / per_furnace - 1e-9))
  -- ponytail: validate one row of at most six furnaces before adding larger patterns.
  if n > 6 then return nil, "pattern-capacity-exceeded:max=" .. (per_furnace * 6) end
  local ore = per_furnace / 60 / r.products[1].amount * r.ingredients[1].amount * n
  local fuel = f.energy_usage * 60 / f.burner_prototype.effectivity
    / prototypes.item.coal.fuel_value * n
  local lane = belt.belt_speed * 60 / 0.25
  if ore > lane or fuel > lane or per_furnace * n / 60 > lane * 2 then
    return nil, "pattern-belt-capacity-exceeded"
  end
  local pole = prototypes.entity["small-electric-pole"]
  if pole.get_supply_area_distance() < 2 or pole.get_max_wire_distance() < 3 then
    return nil, "pattern-pole-reach-mismatch"
  end
  local inserter = prototypes.entity.inserter
  local pickup, drop = inserter.inserter_pickup_position, inserter.inserter_drop_position
  if pickup[1] ~= 0 or pickup[2] ~= -1 or drop[1] ~= 0 or drop[2] < 1 or drop[2] > 1.3 then
    return nil, "pattern-inserter-reach-mismatch"
  end
  local conservative_cycles = 60 / (1 / inserter.get_inserter_rotation_speed()
    + 2 / inserter.get_inserter_extension_speed())
  if (ore + fuel) / n > conservative_cycles then return nil, "pattern-inserter-capacity-exceeded" end
  return {furnaces = n, target_per_minute = rate, capacity_per_minute = per_furnace * n,
    ore_per_second = ore, coal_per_second = fuel,
    electric_peak_watts = inserter.get_max_energy_usage() * 60 * 2 * n}
end

local function source_info(e)
  if not e or not e.valid or e.type ~= "transport-belt" or not STEP[e.direction]
    or #e.belt_neighbours.outputs > 0 then return nil end
  local contents = {}
  for i = 1, 2 do
    for _, stack in pairs(e.get_transport_line(i).get_contents()) do
      if stack.name ~= "coal" and stack.name ~= "iron-ore" then return nil end
      contents[stack.name] = true
    end
  end
  return {x = e.position.x, y = e.position.y, direction = e.direction,
    unit_number = e.unit_number, materials_seen = contents.coal and contents["iron-ore"] or false}
end

local function clear(surface, force, entities)
  for _, e in ipairs(entities) do
    if not surface.can_place_entity {name = e.name, position = {e.x, e.y},
      direction = e.direction, force = force} then return false end
  end
  return true
end

local function belts_isolated(surface, entities, source)
  local occupied = footprint(entities)
  if not occupied then return false end
  for _, e in ipairs(entities) do
    if e.name == "transport-belt" then
      for _, step in pairs(STEP) do
        local x, y = e.x + step[1], e.y + step[2]
        if not occupied[math.floor(x) .. ":" .. math.floor(y)]
          and not (source and x == source.x and y == source.y) then
          if surface.count_entities_filtered {position = {x, y}, radius = 0.1,
            type = {"transport-belt", "underground-belt", "splitter"}} > 0 then return false end
        end
      end
    end
  end
  return true
end

local function requirements(ctx, force, entities)
  local inventory = ctx.inventory()
  local cost, missing, locked = {}, {}, {}
  for _, e in ipairs(entities) do
    local item = prototypes.entity[e.name].items_to_place_this[1]
    cost[item.name] = (cost[item.name] or 0) + item.count
  end
  for name, count in pairs(cost) do
    local have = inventory and inventory.get_item_count {name = name, quality = "normal"} or 0
    if have < count then missing[name] = count - have end
    local recipe = force.recipes[name]
    if recipe and not recipe.enabled then locked[#locked + 1] = name end
  end
  if not force.recipes["iron-plate"].enabled then locked[#locked + 1] = "iron-plate" end
  table.sort(locked)
  return cost, missing, locked
end

local function power_link(surface, force, entities)
  for _, e in ipairs(entities) do
    if e.name == "small-electric-pole" then
      for _, pole in pairs(surface.find_entities_filtered {
        position = {e.x, e.y}, radius = prototypes.entity[e.name].get_max_wire_distance(),
        force = force, type = "electric-pole",
      }) do
        local distance = math.sqrt((pole.position.x - e.x)^2 + (pole.position.y - e.y)^2)
        if distance <= pole.prototype.get_max_wire_distance(pole.quality) then return true end
      end
    end
  end
  return false
end

function M.attach(ctx)
  local function plans()
    local state = ctx.state()
    state.smelting_plans = state.smelting_plans or {}
    return state.smelting_plans
  end
  local function reply(nonce, ok, value) return ctx.response(nonce, ok, value) end
  local function fail(nonce, why) return reply(nonce, false, {error = why}) end
  local function summary(p)
    return {plan_id = p.id, pattern = "iron-smelting-row-v1", state = p.state,
      furnaces = p.model.furnaces, target_per_minute = p.model.target_per_minute,
      capacity_per_minute = p.model.capacity_per_minute, origin = p.origin,
      footprint = p.bounds, required_supply = {ore_per_second = p.model.ore_per_second,
        coal_per_second = p.model.coal_per_second, peak_watts = p.model.electric_peak_watts},
      entities = #p.entities, materials = p.cost, missing = p.missing,
      locked = p.locked, connections = p.connections, candidates = p.candidates,
      placed = p.placed, audit = p.audit, error = p.error, artifact = p.artifact,
      blueprint_error = p.blueprint_error}
  end

  function M.plan(nonce, request)
    local surface, force = game.get_surface(request.surface or "nauvis"), game.forces[request.force or "player"]
    if not surface or not force then return fail(nonce, "surface-or-force-not-found") end
    local spec, why = model(request.rate)
    if not spec then return fail(nonce, why) end
    local x, y = request.x, request.y
    if x == nil and y == nil then
      local player = game.get_player(1)
      if not player then return fail(nonce, "position-required") end
      x, y = player.position.x, player.position.y
    end
    if not finite(x) or not finite(y) then return fail(nonce, "invalid-position") end
    local source
    if request.input_x ~= nil or request.input_y ~= nil then
      if not finite(request.input_x) or not finite(request.input_y) then return fail(nonce, "invalid-input-position") end
      source = source_info(surface.find_entities_filtered {
        position = {request.input_x, request.input_y}, radius = 0.1,
        type = "transport-belt", force = force,
      }[1])
      if not source then return fail(nonce, "input-must-be-terminal-ore-coal-belt") end
    else
      local best_distance = math.huge
      for _, belt in pairs(surface.find_entities_filtered {
        position = {x, y}, radius = 32, type = "transport-belt", force = force,
      }) do
        local candidate = source_info(belt)
        if candidate and candidate.materials_seen then
          local distance = (candidate.x - x)^2 + (candidate.y - y)^2
          if distance < best_distance then source, best_distance = candidate, distance end
        end
      end
    end
    local origins = {}
    for dx = -24, 24, 4 do
      for dy = -24, 24, 4 do
        origins[#origins + 1] = {x = math.floor(x) + dx, y = math.floor(y) + dy, score = dx^2 + dy^2}
      end
    end
    table.sort(origins, function(a, b)
      if a.score ~= b.score then return a.score < b.score end
      if a.x ~= b.x then return a.x < b.x end
      return a.y < b.y
    end)
    local selected, examined = nil, 0
    for _, origin in ipairs(origins) do
      for turn = 0, 3 do
        examined = examined + 1
        local entities, port = M.layout(spec.furnaces, origin.x, origin.y, turn)
        local occupied, bounds = footprint(entities)
        local area = {{bounds[1], bounds[2]}, {bounds[3], bounds[4]}}
        local suitable = surface.count_entities_filtered {area = area, type = "resource"} == 0
          and surface.count_entities_filtered {area = area, force = force} == 0
          and surface.count_entities_filtered {position = {origin.x, origin.y}, radius = 24, force = "enemy"} == 0
          and clear(surface, force, entities)
        if suitable then
          local core_count, route = #entities, {}
          if source then
            route = M.route(source, port, occupied, true)
            if not route or not clear(surface, force, route) then
              route = M.route(source, port, occupied, false)
            end
            suitable = route ~= nil and clear(surface, force, route)
          end
          if suitable then
            local linked = power_link(surface, force, entities)
            for _, e in ipairs(route) do entities[#entities + 1] = e end
            local score = origin.score + #route * 4 + (linked and 0 or 10000)
            if (not selected or score < selected.score) and belts_isolated(surface, entities, source) then
              local first_output
              for _, e in ipairs(entities) do
                if e.name == "wooden-chest" then first_output = {x = e.x, y = e.y} break end
              end
              local sx, sy = rotate(3, 0, turn)
              selected = {entities = entities, core_count = core_count, bounds = area, score = score,
                origin = {x = origin.x, y = origin.y, turn = turn},
                connections = {input = source and "planned-connection" or "needs-ore-coal-belt",
                  input_port = port, supply_observed = source and source.materials_seen or false,
                  electricity = linked and "pole-in-reach" or "needs-power",
                  output = {first = first_output, step = {x = sx, y = sy}, count = spec.furnaces}}}
            end
          end
        end
      end
      if selected and selected.score < 10000 then break end
    end
    if not selected then return reply(nonce, false, {error = "no-fitting-site", candidates = examined}) end
    local cost, missing, locked = requirements(ctx, force, selected.entities)
    local registry = plans()
    -- Keep a bounded number of plans without evicting an ongoing audit.
    local ids = {}
    for id, p in pairs(registry) do if p.state ~= "auditing" then ids[#ids + 1] = id end end
    table.sort(ids, function(a, b) return registry[a].tick < registry[b].tick end)
    while #ids >= 12 do registry[table.remove(ids, 1)] = nil end
    local state = ctx.state()
    state.smelting_seq = (state.smelting_seq or 0) + 1
    selected.id, selected.tick, selected.version = "smelt-" .. state.smelting_seq, game.tick, VERSION
    selected.model, selected.spec_key = spec, helpers.table_to_json(spec)
    selected.surface, selected.force = surface.name, force.name
    selected.state, selected.source, selected.candidates = "planned", source, examined
    selected.cost, selected.missing, selected.locked = cost, missing, locked
    selected.score = nil
    registry[selected.id] = selected
    return reply(nonce, true, summary(selected))
  end

  function M.build(nonce, request)
    local p = plans()[request.plan_id]
    if not p then return fail(nonce, "plan-not-found") end
    if p.state ~= "planned" then return reply(nonce, not p.error, summary(p)) end
    if p.version ~= VERSION or game.tick - p.tick > 36000 then return fail(nonce, "plan-expired") end
    local spec = model(p.model.target_per_minute)
    if not spec or helpers.table_to_json(spec) ~= p.spec_key then return fail(nonce, "prototype-changed-replan") end
    local surface, force = game.get_surface(p.surface), game.forces[p.force]
    if not surface or not force then return fail(nonce, "surface-or-force-not-found") end
    p.cost, p.missing, p.locked = requirements(ctx, force, p.entities)
    if next(p.missing) or #p.locked > 0 then
      local result = summary(p)
      result.error = next(p.missing) and "insufficient-items" or "technology-locked"
      return reply(nonce, false, result)
    end
    if not clear(surface, force, p.entities) or not belts_isolated(surface, p.entities, p.source)
      or surface.count_entities_filtered {area = p.bounds, type = "resource"} > 0 then
      return fail(nonce, "site-changed-replan")
    end
    if surface.count_entities_filtered {position = {p.origin.x, p.origin.y}, radius = 24, force = "enemy"} > 0 then
      return fail(nonce, "enemy-near-site")
    end
    if p.source then
      local feed = surface.find_entities_filtered {position = {p.source.x, p.source.y},
        radius = 0.1, type = "transport-belt", force = force}[1]
      local current = source_info(feed)
      if not current or current.x ~= p.source.x or current.y ~= p.source.y
        or current.direction ~= p.source.direction then return fail(nonce, "input-changed-replan") end
    end
    p.receipts, p.machines, p.built_entities, p.placed, p.state = {}, {}, {}, 0, "building"
    local _, owner, kind = ctx.inventory()
    p.treasury = {kind = kind, x = owner.position.x, y = owner.position.y,
      surface = owner.surface.name, player_index = kind == "player" and owner.index or nil,
      unit_number = kind == "container" and owner.unit_number or nil}
    for i, e in ipairs(p.entities) do
      local handled, r = pcall(ctx.place, nonce .. ":" .. i, {name = e.name, x = e.x, y = e.y,
        direction = e.direction, surface = p.surface, force = p.force})
      if not handled then r = {ok = false, error = "place-runtime-error", detail = tostring(r)} end
      p.receipts[#p.receipts + 1] = r
      if not r.ok then p.error, p.state = r.error, "partial" break end
      p.placed = p.placed + 1
      local built_entity = surface.find_entity(e.name, {e.x, e.y})
      p.built_entities[#p.built_entities + 1] = built_entity
      if e.name == "stone-furnace" then
        p.machines[#p.machines + 1] = built_entity
      end
    end
    p.artifact = "smelting/" .. p.id
    if not p.error then
      if p.source then p.connections.input = "connected" end
      local b = p.bounds
      local exported = ctx.export(nonce .. ":bp", {surface = p.surface, force = p.force,
        x1 = b[1][1] + 0.01, y1 = b[1][2] + 0.01,
        x2 = b[2][1] - 0.01, y2 = b[2][2] - 0.01})
      if exported.ok and exported.entities == p.core_count then
        helpers.write_file(p.artifact .. ".blueprint.txt", exported.blueprint .. "\n", false)
      else p.blueprint_error = exported.error or ("export-count-mismatch:" .. tostring(exported.entities)) end
      p.state, p.warmup, p.deadline = "auditing", game.tick + 1800, game.tick + 5400
    end
    helpers.write_file(p.artifact .. ".receipt.json", helpers.table_to_json({
      plan = summary(p), source = p.treasury, blueprint_error = p.blueprint_error, receipts = p.receipts,
    }), false)
    return reply(nonce, not p.error, summary(p))
  end

  function M.tick()
    for _, p in pairs(plans()) do
      if p.state == "auditing" and game.tick >= p.warmup then
        local total, missing, missing_entities, wrong_recipe = 0, 0, 0, false
        for _, entity in pairs(p.built_entities) do
          if not entity.valid then missing_entities = missing_entities + 1 end
        end
        local statuses = {}
        for _, e in pairs(p.machines) do
          if not e.valid then missing = missing + 1
          else
            total = total + e.products_finished
            local recipe = e.get_recipe()
            if recipe and recipe.name ~= "iron-plate" then wrong_recipe = true end
            local state = ctx.status_name(e.status)
            statuses[state] = (statuses[state] or 0) + 1
          end
        end
        if not p.baseline then p.baseline, p.baseline_tick = total, game.tick end
        if game.tick >= p.deadline and game.tick > p.baseline_tick then
          local rate = (total - p.baseline) * 3600 / (game.tick - p.baseline_tick)
          local pass = missing == 0 and missing_entities == 0 and not wrong_recipe
            and rate >= p.model.target_per_minute * 0.9
          p.audit = {status = pass and "passed" or "failed", measured_per_minute = rate,
            target_per_minute = p.model.target_per_minute, window_ticks = game.tick - p.baseline_tick,
            missing_machines = missing, missing_entities = missing_entities,
            wrong_recipe = wrong_recipe, machine_states = statuses}
          p.state = pass and "verified" or "needs-attention"
          helpers.write_file(p.artifact .. ".audit.json", helpers.table_to_json(p.audit), false)
        end
      end
    end
  end

  function M.status(nonce, request)
    local p = plans()[request.plan_id]
    if not p then return fail(nonce, "plan-not-found") end
    return reply(nonce, true, summary(p))
  end
  return M
end

return M
