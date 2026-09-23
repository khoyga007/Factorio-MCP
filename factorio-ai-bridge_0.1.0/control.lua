local core = require("core")
local BRIDGE_BUILD, BRIDGE_VERSION, MAX_PACKET_BYTES, autofuel_surface = core.BRIDGE_BUILD, core.BRIDGE_VERSION, core.MAX_PACKET_BYTES, core.autofuel_surface
local bridge_state, remember_response, response, send = core.bridge_state, core.remember_response, core.response, core.send
local treasury_inventory = core.treasury_inventory
local items = require("items")
local survey = require("survey")
local build = require("build")
local refill_research = build.refill_research

-- Forward declaration so handle_ping can advertise the live action list.
local HANDLERS

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

local executor = require("executor").attach {
  state = bridge_state, response = response, inventory = treasury_inventory,
  import = build.handle_blueprint_import, craft = items.handle_craft, collect = items.handle_collect,
  mine = items.handle_mine, insert = items.handle_insert, wire = build.wire_pole,
}
local field = require("field").attach {
  state = bridge_state, response = response, inventory = treasury_inventory,
  fluid_tiles = survey.fluid_tile_names,
}

local function handle_water_sites(nonce, request) return field.water(nonce, request) end
local function handle_recall(nonce, request) return field.recall(nonce, request) end
local function handle_route(nonce, request) return field.route(nonce, request) end
local function handle_blueprint_run(nonce, request) return executor.start(nonce, request) end
local function handle_blueprint_job(nonce, request) return executor.status(nonce, request) end
local function handle_drop_ghosts(nonce, request) return executor.drop_ghosts(nonce, request) end
local function handle_ledger(nonce, request) return executor.ledger(nonce, request) end
local function handle_ledger_note(nonce, request) return executor.note(nonce, request) end

HANDLERS = {
  audit = survey.handle_audit,
  autofuel = items.handle_autofuel,
  brief = survey.handle_brief,
  blueprint_export = build.handle_blueprint_export,
  blueprint_import = build.handle_blueprint_import,
  blueprint_run = handle_blueprint_run,
  blueprint_job = handle_blueprint_job,
  drop_ghosts = handle_drop_ghosts,
  flow = survey.handle_flow,
  ledger = handle_ledger,
  ledger_note = handle_ledger_note,
  collect = items.handle_collect,
  launch = build.handle_launch,
  craft = items.handle_craft,
  repair_demo_economy = items.handle_repair_demo_economy,
  index = survey.handle_index,
  insert = items.handle_insert,
  mine = items.handle_mine,
  ore_marks = survey.handle_ore_marks,
  ping = handle_ping,
  research = build.handle_research,
  spec = survey.handle_spec,
  set_treasury = items.handle_set_treasury,
  set_recipe = build.handle_set_recipe,
  snapshot = survey.handle_snapshot,
  supply = survey.handle_supply,
  place = build.handle_place,
  recall = handle_recall,
  route = handle_route,
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
  executor.tick()
end)
script.on_nth_tick(300, function()
  for _, surface in pairs(game.surfaces) do
    autofuel_surface(surface, game.forces.player)
  end
end)

-- A newly generated chunk invalidates the cached whole-map bounds; the next
-- index request rebuilds from scratch.
script.on_event(defines.events.on_research_finished, function(event)
  refill_research(event.research.force)
end)
script.on_nth_tick(600, function()  -- labs briefly empty at a finish must not end the plan
  if next(bridge_state().research_backlog or {}) then refill_research(game.forces.player) end
end)
script.on_event(defines.events.on_chunk_generated, function()
  bridge_state().index = nil
end)
