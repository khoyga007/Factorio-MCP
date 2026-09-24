-- Shared bridge core: limits, storage state, response envelope, request parsing, treasury, entity views.
local BRIDGE_VERSION = 1
local BRIDGE_BUILD = "2026-09-24-idle"
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
  "train-stop", "transport-belt", "underground-belt", "wall", "lamp",
  "constant-combinator", "arithmetic-combinator", "decider-combinator", "power-switch",
  "loader", "loader-1x1", "car", "land-mine", "heat-pipe"
}

local DIRECTIONS = {
  north = defines.direction.north,
  east = defines.direction.east,
  south = defines.direction.south,
  west = defines.direction.west,
}

-- Forward declaration so handle_ping can advertise the live action list.
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

-- A ghost is a plan, not a machine: it answers ghost_name/ghost_type and nothing
-- else entity_data reads, so it gets its own shape. `ghost = true` marks it in any
-- list that mixes the two.
local function ghost_data(entity)
  local box = entity.bounding_box
  return {
    ghost = true,
    name = entity.ghost_name,
    type = entity.ghost_type,
    unit_number = entity.unit_number,
    x = entity.position.x,
    y = entity.position.y,
    direction = entity.direction,
    bounding_box = {
      left_top = {x = box.left_top.x, y = box.left_top.y},
      right_bottom = {x = box.right_bottom.x, y = box.right_bottom.y},
    },
  }
end

local function find_ghosts(surface, area, force)
  local found = surface.find_entities_filtered {area = area, type = "entity-ghost", force = force}
  table.sort(found, function(a, b)
    if a.position.x ~= b.position.x then return a.position.x < b.position.x end
    if a.position.y ~= b.position.y then return a.position.y < b.position.y end
    return (a.ghost_name or "") < (b.ghost_name or "")
  end)
  return found
end

return {
  BRIDGE_BUILD = BRIDGE_BUILD,
  BRIDGE_VERSION = BRIDGE_VERSION,
  CHEST_TYPES = CHEST_TYPES,
  DIRECTIONS = DIRECTIONS,
  ENTITY_TYPES = ENTITY_TYPES,
  MAX_ENTITIES = MAX_ENTITIES,
  MAX_PACKET_BYTES = MAX_PACKET_BYTES,
  MAX_RADIUS = MAX_RADIUS,
  autofuel_surface = autofuel_surface,
  bridge_state = bridge_state,
  entity_data = entity_data,
  entity_status_name = entity_status_name,
  find_ghosts = find_ghosts,
  force_for = force_for,
  ghost_data = ghost_data,
  number = number,
  position = position,
  remember_response = remember_response,
  response = response,
  send = send,
  surface_for = surface_for,
  treasury = treasury,
  treasury_data = treasury_data,
  treasury_inventory = treasury_inventory,
}
