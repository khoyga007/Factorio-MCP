-- Injected only into the isolated benchmark mod, never installed in the live game.
return function(handlers, bridge_state, test_bridge_runtime)
  local surface, stock, feeds, plans, started
  local report = {ok = false, checks = {}, calls = {}, response_bytes = {}}
  local function save()
    helpers.write_file("smelting-check.json", helpers.table_to_json(report), false)
  end
  local function check(value, name)
    assert(value, name)
    report.checks[#report.checks + 1] = name
  end
  local seq = 0
  local function call(action, body)
    seq = seq + 1
    local result = handlers[action]("test-" .. seq, body or {})
    report.calls[#report.calls + 1] = {action = action, ok = result.ok, error = result.error}
    report.response_bytes[#report.response_bytes + 1] = #helpers.table_to_json(result)
    return result
  end
  local function create(name, x, y, direction)
    return assert(surface.create_entity {name = name, position = {x, y},
      force = "player", direction = direction or 0}, name)
  end
  local function feed_and_power(x)
    for i = -9, -5 do create("transport-belt", x + i + 0.5, -2.5, 4) end
    local generator = create("electric-energy-interface", x - 9, -5)
    generator.power_production = 10000000
    generator.electric_buffer_size = 100000000
    generator.energy = 100000000
    create("small-electric-pole", x - 8.5, -2.5)
    create("small-electric-pole", x - 2.5, -0.5)
    return surface.find_entity("transport-belt", {x - 8.5, -2.5})
  end
  local function setup()
    started = game.tick
    if test_bridge_runtime then test_bridge_runtime(handlers, bridge_state) end
    surface = game.create_surface("ai-smelting-test", {
      autoplace_settings = {entity = {treat_missing_as_default = false, settings = {}},
        decorative = {treat_missing_as_default = false, settings = {}}},
    })
    surface.request_to_generate_chunks({48, 0}, 5)
    surface.force_generate_chunk_requests()
    for _, e in pairs(surface.find_entities()) do e.destroy() end
    local tiles = {}
    for x = -64, 150 do for y = -64, 150 do
      tiles[#tiles + 1] = {name = "grass-1", position = {x, y}}
    end end
    surface.set_tiles(tiles)
    for name in pairs({["stone-furnace"] = true, inserter = true, ["transport-belt"] = true,
      ["small-electric-pole"] = true, ["wooden-chest"] = true, ["iron-plate"] = true}) do
      game.forces.player.recipes[name].enabled = true
    end
    game.forces.player.inserter_stack_size_bonus = 0
    bridge_state().autofuel_enabled = false
    report.inserter = {pickup = prototypes.entity.inserter.inserter_pickup_position,
      drop = prototypes.entity.inserter.inserter_drop_position,
      energy = prototypes.entity.inserter.energy_usage}
    local chest = create("steel-chest", -40.5, -40.5)
    stock = chest.get_inventory(defines.inventory.chest)
    for name, count in pairs({["stone-furnace"] = 50, inserter = 100,
      ["transport-belt"] = 500, ["small-electric-pole"] = 100, ["wooden-chest"] = 20}) do
      stock.insert {name = name, count = count}
    end
    call("set_treasury", {surface = surface.name, x = -40.5, y = -40.5})
    feeds = {feed_and_power(0), feed_and_power(80)}
    local water = {}
    for x = -28, 28 do for y = 52, 125 do
      water[#water + 1] = {name = "water", position = {x, y}}
    end end
    surface.set_tiles(water)
    local strip = {}
    for x = -3, 2 do for y = 80, 98 do
      strip[#strip + 1] = {name = "grass-1", position = {x, y}}
    end end
    for y = 70, 79 do strip[#strip + 1] = {name = "grass-1", position = {2, y}} end
    for x = 4, 8 do for y = 75, 85 do
      strip[#strip + 1] = {name = "grass-1", position = {x, y}}
    end end
    surface.set_tiles(strip)
    for y = 71, 75 do create("transport-belt", 2.5, y + 0.5, 8) end
    local generator = create("electric-energy-interface", 6, 78)
    generator.power_production, generator.electric_buffer_size, generator.energy = 10000000, 100000000, 100000000
    create("small-electric-pole", 5.5, 82.5)
    create("small-electric-pole", 5.5, 78.5)
    feeds[3] = surface.find_entity("transport-belt", {2.5, 71.5})
    for _, feed in ipairs(feeds) do
      feed.get_transport_line(1).insert_at_back {name = "iron-ore", count = 1}
      feed.get_transport_line(2).insert_at_back {name = "coal", count = 1}
    end
    plans = {}
    local plan_sizes = {}
    local terminal = surface.find_entity("transport-belt", {-4.5, -2.5})
    terminal.get_transport_line(1).insert_at_back {name = "iron-ore", count = 1}
    terminal.get_transport_line(2).insert_at_back {name = "coal", count = 1}
    for i, fixture in ipairs({{x = 0, y = 0, rate = 30, n = 2, ix = -4.5, iy = -2.5},
      {x = 80, y = 0, rate = 110, n = 6, ix = 75.5, iy = -2.5},
      {x = 0, y = 80, rate = 50, n = 3, ix = 2.5, iy = 75.5}}) do
      local p = call("smelt_plan", {surface = surface.name, x = fixture.x, y = fixture.y, rate = fixture.rate,
        input_x = i ~= 1 and fixture.ix or nil, input_y = i ~= 1 and fixture.iy or nil})
      check(p.ok, "plan-" .. i .. ":" .. tostring(p.error))
      plans[i] = p.plan_id
      plan_sizes[i] = #helpers.table_to_json(p)
      check(p.furnaces == fixture.n, "sizing-" .. i)
      check(p.connections.input == "planned-connection", "route-" .. i)
      if i == 3 then check(p.origin.turn == 1 or p.origin.turn == 3, "rotated-to-fit-shore") end
      if i == 1 then check(p.connections.supply_observed, "auto-find-mixed-feed") end
    end
    local before = surface.count_entities_filtered {force = "player"}
    local available = stock.get_item_count("transport-belt")
    stock.remove {name = "transport-belt", count = available}
    local insufficient = call("smelt_build", {plan_id = plans[1]})
    check(not insufficient.ok and insufficient.error == "insufficient-items", "reject-shortage")
    check(before == surface.count_entities_filtered {force = "player"}, "shortage-no-build")
    stock.insert {name = "transport-belt", count = available}
    game.forces.player.recipes["stone-furnace"].enabled = false
    local locked = call("smelt_build", {plan_id = plans[1]})
    check(not locked.ok and locked.error == "technology-locked", "reject-locked-technology")
    check(before == surface.count_entities_filtered {force = "player"}, "locked-no-build")
    game.forces.player.recipes["stone-furnace"].enabled = true
    local e = bridge_state().smelting_plans[plans[1]].entities[1]
    local obstacle = create("wooden-chest", e.x, e.y)
    local stale = call("smelt_build", {plan_id = plans[1]})
    check(not stale.ok and stale.error == "site-changed-replan", "reject-stale-plan")
    check(stock.get_item_count("transport-belt") == available, "stale-no-debit")
    obstacle.destroy()
    local side_belt = create("transport-belt", e.x, e.y - 1, 8)
    local adjacent = call("smelt_build", {plan_id = plans[1]})
    check(not adjacent.ok and adjacent.error == "site-changed-replan", "reject-accidental-belt-connection")
    check(stock.get_item_count("transport-belt") == available, "adjacent-no-debit")
    side_belt.destroy()
    report.rows = {}
    for i, id in ipairs(plans) do
      local before_stock = stock.get_contents()
      local built = call("smelt_build", {plan_id = id})
      check(built.ok and built.state == "auditing", "build-" .. i .. ":" .. tostring(built.error))
      local p = bridge_state().smelting_plans[id]
      check(not p.blueprint_error, "export-" .. i .. ":" .. tostring(p.blueprint_error))
      for _, stack in pairs(before_stock) do
        local spent = built.materials[stack.name] or 0
        check(stock.get_item_count(stack.name) == stack.count - spent, "debit-" .. i .. "-" .. stack.name)
      end
      local after = stock.get_contents()
      local repeated = call("smelt_build", {plan_id = id})
      check(repeated.ok and repeated.placed == built.placed, "idempotent-result-" .. i)
      for _, stack in pairs(after) do
        check(stock.get_item_count(stack.name) == stack.count, "idempotent-stock-" .. i .. "-" .. stack.name)
      end
      local verbose_bytes = 0
      for _, receipt in ipairs(p.receipts) do verbose_bytes = verbose_bytes + #helpers.table_to_json(receipt) end
      report.rows[i] = {plan = id, furnaces = built.furnaces, entities = built.entities, origin = built.origin,
        individual_place_receipt_bytes = verbose_bytes,
        workflow_reply_bytes = {plan_sizes[i], #helpers.table_to_json(built)}}
    end
    local bounds = bridge_state().smelting_plans[plans[2]].bounds
    local exported = call("blueprint_export", {surface = surface.name,
      x1 = bounds[1][1] + 0.01, y1 = bounds[1][2] + 0.01,
      x2 = bounds[2][1] - 0.01, y2 = bounds[2][2] - 0.01})
    check(exported.ok, "native-blueprint-export")
    local duplicated = call("blueprint_import", {surface = surface.name, blueprint = exported.blueprint,
      x = 120, y = 80, mode = "direct"})
    check(duplicated.ok and duplicated.placed == 48, "native-blueprint-import-without-robots:" .. tostring(duplicated.error))
    save()
  end
  local finished = false
  script.on_event(defines.events.on_tick, function()
    if finished then return end
    local ok, err = pcall(function()
      if not started then setup() end
      for _, feed in ipairs(feeds) do
        feed.get_transport_line(1).insert_at_back {name = "iron-ore", count = 1}
        feed.get_transport_line(2).insert_at_back {name = "coal", count = 1}
      end
      if game.tick - started >= 5550 then
        for i, id in ipairs(plans) do
          local result = call("smelt_status", {plan_id = id})
          report.rows[i].result = result
          local sizes = report.rows[i].workflow_reply_bytes
          sizes[#sizes + 1] = #helpers.table_to_json(result)
          report.rows[i].workflow_calls = #sizes
          check(result.ok and result.state == "verified", "throughput-" .. i)
          local p = bridge_state().smelting_plans[id]
          for _, entry in ipairs(p.entities) do
            if entry.name == "wooden-chest" then
              local chest = surface.find_entity(entry.name, {entry.x, entry.y})
              check(chest.get_inventory(defines.inventory.chest).get_item_count("iron-plate") >= 15,
                "physical-output-" .. i)
            end
          end
        end
        report.ok, finished = true, true
        save()
        log("SMELTING_TEST_PASS")
      end
    end)
    if not ok then
      report.error, finished = tostring(err), true
      save()
      log("SMELTING_TEST_FAIL " .. tostring(err))
    end
  end)
end
