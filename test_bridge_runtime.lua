-- Isolated fixtures only. Never load this module in the installed player mod.
return function(handlers, bridge_state)
  local checks, seq = {}, 0
  local function check(value, name)
    assert(value, name)
    checks[#checks + 1] = name
  end
  local function call(action, body)
    seq = seq + 1
    body = body or {}
    body.surface = "ai-bridge-test"
    return handlers[action]("bridge-test-" .. seq, body)
  end
  local player = assert(game.get_player(1), "bridge tests need a save with player 1")
  if not player.character then player.create_character() end
  local pocket = assert(player.get_main_inventory())
  pocket.clear()
  local surface = game.create_surface("ai-bridge-test", {
    autoplace_settings = {entity = {treat_missing_as_default = false, settings = {}},
      decorative = {treat_missing_as_default = false, settings = {}}},
  })
  surface.request_to_generate_chunks({0, 0}, 2)
  surface.force_generate_chunk_requests()
  for _, e in pairs(surface.find_entities()) do e.destroy() end
  local tiles = {}
  for x = -32, 32 do for y = -32, 32 do
    tiles[#tiles + 1] = {name = "grass-1", position = {x, y}}
  end end
  surface.set_tiles(tiles)
  local function create(name, x, y, extra)
    local args = extra or {}
    args.name, args.position = name, {x, y}
    args.force = args.force or "player"
    return assert(surface.create_entity(args), name)
  end
  bridge_state().autofuel_enabled = false
  local treasury = create("steel-chest", -20.5, -20.5)
  local stock = treasury.get_inventory(defines.inventory.chest)
  for name, count in pairs({["iron-plate"] = 20, ["iron-ore"] = 20, coal = 20,
    ["underground-belt"] = 4, ["pipe-to-ground"] = 2}) do
    stock.insert {name = name, count = count}
  end
  check(call("set_treasury", {x = -20.5, y = -20.5}).ok, "select-real-stock")
  local chest = create("wooden-chest", 0.5, 0.5).get_inventory(defines.inventory.chest)
  local inserted = call("insert", {item = "iron-plate", count = 10, x = 0.5, y = 0.5})
  check(inserted.ok and inserted.slot == "chest", "insert-into-chest")
  check(stock.get_item_count("iron-plate") == 10 and chest.get_item_count("iron-plate") == 10,
    "chest-transfer-conserves-items")
  local missing = call("insert", {item = "iron-plate", count = 99, x = 0.5, y = 0.5})
  check(not missing.ok and stock.get_item_count("iron-plate") == 10, "shortage-does-not-debit")
  local logistic = create("passive-provider-chest", 3.5, 0.5).get_inventory(defines.inventory.chest)
  check(call("insert", {item = "iron-plate", count = 2, x = 3.5, y = 0.5}).ok
    and logistic.get_item_count("iron-plate") == 2, "insert-logistic-chest")
  local furnace = create("stone-furnace", 7, 0)
  check(call("insert", {item = "iron-ore", count = 2, x = 7, y = 0, source = true}).ok
    and furnace.get_inventory(defines.inventory.furnace_source).get_item_count("iron-ore") == 2,
    "furnace-source-preserved")
  check(call("insert", {item = "coal", count = 2, x = 7, y = 0}).ok
    and furnace.get_fuel_inventory().get_item_count("coal") == 2, "furnace-fuel-preserved")

  local pipe = create("pipe", 0.5, 5.5)
  pipe.fluidbox[1] = {name = "water", amount = 50, temperature = 25}
  create("boiler", 7.5, 6)
  local snap = call("snapshot", {x = 0, y = 0, radius = 24})
  check(snap.ok, "snapshot-with-fluid-entities")
  local fluid_seen, empty_seen
  for _, e in ipairs(snap.entities) do
    if e.name == "pipe" then
      local f = e.fluids[1]
      fluid_seen = f.index == 1 and f.name == "water" and f.amount == 50 and f.temperature == 25
    elseif e.name == "boiler" then empty_seen = #e.fluids == 0 end
  end
  check(fluid_seen, "snapshot-fluid-name-amount-temperature")
  check(empty_seen, "empty-fluidbox-visible")
  local spec = call("spec", {kind = "entity", name = "boiler"})
  check(spec.ok and #spec.fluidbox_prototypes == 2, "spec-fluidboxes")
  local ports = spec.fluidbox_prototypes[1].pipe_connections
  check(#ports == 2 and #ports[1].positions == 4 and ports[1].direction ~= nil,
    "native-fluid-port-positions-all-rotations")
  check(helpers.json_to_table(helpers.table_to_json(spec)).ok, "fluid-spec-serializable")

  create("tree-01", 0, 10, {force = "neutral"})
  create("big-rock", 3, 10, {force = "neutral"})
  local first = call("snapshot", {x = 0, y = 10, radius = 6, obstacles = true, limit = 1})
  check(first.ok and first.obstacles_total == 2 and #first.obstacles == 1
    and first.obstacles_next_offset == 1, "neutral-obstacles-page-one")
  local second = call("snapshot", {x = 0, y = 10, radius = 6, obstacles = true, limit = 1, offset = 1})
  check(#second.obstacles == 1 and not second.obstacles_next_offset
    and second.obstacles[1].name ~= first.obstacles[1].name, "neutral-obstacles-page-two")

  local drop = create("item-on-ground", 15.5, 0.5, {
    force = "neutral", stack = {name = "iron-plate", count = 5, quality = "uncommon"},
  })
  local partial = call("collect", {item = "iron-plate", count = 2, x = 15.5, y = 0.5})
  check(partial.ok and partial.count == 2 and drop.stack.count == 3, "collect-part-of-ground-stack")
  check(pocket.get_item_count {name = "iron-plate", quality = "uncommon"} == 2,
    "ground-transfer-preserves-quality")
  local too_many = call("collect", {item = "iron-plate", count = 4, x = 15.5, y = 0.5})
  check(not too_many.ok and drop.stack.count == 3, "ground-shortage-preserves-stack")
  check(call("collect", {item = "iron-plate", count = 3, x = 15.5, y = 0.5}).ok
    and not drop.valid, "collect-all-removes-empty-ground-entity")
  local magazine = create("item-on-ground", 15.5, 0.5, {force = "neutral",
    stack = {name = "firearm-magazine", count = 1}})
  magazine.stack.ammo = 3
  check(call("collect", {item = "firearm-magazine", count = 1, x = 15.5, y = 0.5}).ok
    and pocket.find_item_stack("firearm-magazine").ammo == 3, "ground-transfer-preserves-ammo")
  local under_chest = create("item-on-ground", 0.5, 0.5, {force = "neutral",
    stack = {name = "iron-plate", count = 3}})
  check(call("collect", {item = "iron-plate", count = 1, x = 0.5, y = 0.5, ground = true}).ok
    and under_chest.stack.count == 2 and chest.get_item_count("iron-plate") == 10,
    "explicit-ground-selection-under-building")
  pocket.clear()
  for i = 1, #pocket do pocket[i].set_stack {name = "stone", count = 50} end
  check(not call("collect", {item = "iron-plate", count = 1, x = 0.5, y = 0.5, ground = true}).ok
    and under_chest.stack.count == 2, "full-pocket-preserves-ground-stack")
  pocket.clear()

  game.forces.player.recipes["underground-belt"].enabled = true
  game.forces.player.recipes["stone-furnace"].enabled = true
  local input = call("place", {name = "underground-belt", x = 15.5, y = 5.5, direction = "east"})
  local output = call("place", {name = "underground-belt", x = 19.5, y = 5.5,
    direction = "east", type = "output"})
  check(input.ok and input.entity.belt_to_ground_type == "input", "underground-default-input")
  check(output.ok and output.entity.belt_to_ground_type == "output", "underground-explicit-output")
  local a = surface.find_entity("underground-belt", {15.5, 5.5})
  local b = surface.find_entity("underground-belt", {19.5, 5.5})
  check(a.neighbours == b, "underground-pair-connects")
  check(stock.get_item_count("underground-belt") == 2, "underground-pair-debits-two-real-items")
  local bad = call("place", {name = "pipe-to-ground", x = 24.5, y = 5.5, type = "output"})
  check(not bad.ok and bad.error == "invalid-belt-type"
    and stock.get_item_count("pipe-to-ground") == 2, "pipe-rejects-belt-type-without-debit")
  local probe = call("place", {name = "stone-furnace", x = 15, y = 12, dry_run = true})
  check(probe.ok and probe.can_place and not probe.would_build and probe.have == 0,
    "dry-run-geometry-independent-of-stock")
  helpers.write_file("bridge-check.json", helpers.table_to_json({ok = true, checks = checks}), false)
end
