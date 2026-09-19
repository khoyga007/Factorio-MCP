-- Loaded only by verify_starter_runtime.py in an isolated copy of the mod.
return function(handlers, bridge_state)
  local report = {ok = false, checks = {}}
  local function check(value, name)
    assert(value, name)
    report.checks[#report.checks + 1] = name
  end
  local function save()
    helpers.write_file("starter-check.json", helpers.table_to_json(report), false)
  end
  local pocket, surface, first, started, phase, second_started, call, resources_before
  local finished = false
  local function setup()
  local player = assert(game.get_player(1))
  pocket = assert(player.get_main_inventory())
  surface = game.create_surface("ai-starter-test", {
    autoplace_settings = {entity = {treat_missing_as_default = false, settings = {}},
      decorative = {treat_missing_as_default = false, settings = {}}},
  })
  surface.request_to_generate_chunks({0, 0}, 2)
  surface.force_generate_chunk_requests()
  for _, entity in pairs(surface.find_entities()) do entity.destroy() end
  local tiles = {}
  for x = -32, 32 do for y = -32, 32 do
    tiles[#tiles + 1] = {name = "grass-1", position = {x, y}}
  end end
  surface.set_tiles(tiles)
  for x = -19, -14 do for y = -2, 3 do
    assert(surface.create_entity {name = "coal", position = {x + 0.5, y + 0.5}, amount = 1000})
  end end
  for x = 12, 17 do for y = -2, 3 do
    assert(surface.create_entity {name = "iron-ore", position = {x + 0.5, y + 0.5}, amount = 1000})
  end end
  for x = 12, 17 do for y = 17, 22 do
    assert(surface.create_entity {name = "copper-ore", position = {x + 0.5, y + 0.5}, amount = 1000})
  end end
  for _, name in ipairs {"burner-mining-drill", "stone-furnace", "iron-plate", "copper-plate"} do
    game.forces.player.recipes[name].enabled = true
  end
  local state = bridge_state()
  state.treasury_entity, state.treasury_unit_number = nil, nil
  state.autofuel_enabled = false
  pocket.clear()
  for name, count in pairs({["burner-mining-drill"] = 1, ["stone-furnace"] = 1, wood = 1}) do
    pocket.insert {name = name, count = count}
  end
  local nonce = 0
  call = function(name, body)
    nonce = nonce + 1
    body = body or {}
    body.surface = surface.name
    return handlers[name]("starter-test-" .. nonce, body)
  end
  resources_before = 36 * 1000
  local dry = call("starter_smelt", {product = "iron-plate", x = 0, y = 0,
    radius = 24, dry_run = true})
  check(dry.ok and dry.state == "planned" and dry.coal_site and dry.iron_or_copper_site,
    "dry-run-selects-coal-and-iron")
  check(not dry.job_id, "dry-run-has-no-unqueryable-job")
  check(surface.count_entities_filtered {force = "player"} == 0
    and pocket.get_item_count("wood") == 1, "dry-run-no-build-no-debit")
  pocket.remove {name = "stone-furnace", count = 1}
  local shortage = call("starter_smelt", {product = "iron-plate", x = 0, y = 0, radius = 24})
  check(shortage.ok and shortage.state == "blocked"
    and surface.count_entities_filtered {force = "player"} == 0,
    "shortage-does-not-build")
  check(not shortage.job_id and shortage.missing[1] == "stone-furnace",
    "shortage-names-missing-real-item")
  pocket.insert {name = "stone-furnace", count = 1}
  pocket.remove {name = "wood", count = 1}
  local no_fuel = call("starter_smelt", {product = "iron-plate", x = 0, y = 0, radius = 24})
  check(no_fuel.ok and no_fuel.state == "blocked"
    and surface.count_entities_filtered {force = "player"} == 0,
    "no-free-fuel")
  pocket.insert {name = "wood", count = 1}
  first = call("starter_smelt", {product = "iron-plate", x = 0, y = 0, radius = 24})
  check(first.ok and first.state == "gathering-coal", "one-call-wood-to-coal-bootstrap")
  check(pocket.get_item_count("wood") == 0 and pocket.get_item_count("burner-mining-drill") == 0,
    "bootstrap-debits-real-wood-and-drill")
  report.first_start_bytes = #helpers.table_to_json(first)
  started, phase, second_started = game.tick, 1, nil
  end
  script.on_event(defines.events.on_tick, function()
    if finished then return end
    local ok, err = pcall(function()
      if not started then setup() end
      if phase == 1 and game.tick - started >= 2400 then
        local status = call("starter_status", {job_id = first.job_id})
        check(status.ok and status.state == "verified", "iron-plate-audit:" .. tostring(status.error))
        check(not status.blueprint_error, "iron-blueprint-export:" .. tostring(status.blueprint_error))
        check(status.audit.status == "passed" and status.audit.products > 0,
          "direct-drop-produced-iron-plate")
        local furnace = surface.find_entity("stone-furnace",
          {status.iron_or_copper_site.output.x, status.iron_or_copper_site.output.y})
        check(furnace and furnace.get_output_inventory().get_item_count("iron-plate") > 0,
          "physical-iron-output-in-furnace")
        local remaining = 0
        for _, e in pairs(surface.find_entities_filtered {type = "resource", name = "coal"}) do
          remaining = remaining + e.amount
        end
        check(remaining < resources_before, "coal-came-from-real-resource")
        report.iron = {state = status.state, audit = status.audit,
          calls = 2, reply_bytes = report.first_start_bytes + #helpers.table_to_json(status),
          artifact = status.artifact}
        local built = surface.count_entities_filtered {force = "player"}
        bridge_state().starter_jobs = {}
        local reused = call("starter_smelt", {product = "iron-plate", x = 0, y = 0, radius = 24})
        check(reused.ok and reused.existing and reused.state == "blocked"
          and reused.missing[1] == "coal:" .. reused.fuel_needed,
          "recognize-existing-pair-needing-fuel")
        check(surface.count_entities_filtered {force = "player"} == built,
          "reuse-never-builds-duplicate")
        pocket.insert {name = "coal", count = reused.fuel_needed}
        local resumed = call("starter_smelt", {product = "iron-plate", x = 0, y = 0, radius = 24})
        check(resumed.ok and resumed.existing and resumed.state == "auditing",
          "one-call-refuel-existing-pair:" .. tostring(resumed.error))
        check(surface.count_entities_filtered {force = "player"} == built,
          "refuel-does-not-build-duplicate")
        pocket.clear()
        for name, count in pairs({["burner-mining-drill"] = 1, ["stone-furnace"] = 1, coal = 2}) do
          pocket.insert {name = name, count = count}
        end
        local second = call("starter_smelt", {product = "copper-plate", x = 0, y = 20, radius = 24})
        check(second.ok and second.state == "auditing" and not second.coal_site,
          "existing-coal-skips-bootstrap")
        report.second_id = second.job_id
        report.second_start_bytes = #helpers.table_to_json(second)
        second_started, phase = game.tick, 2
      elseif phase == 2 and game.tick - second_started >= 1860 then
        local status = call("starter_status", {job_id = report.second_id})
        check(status.ok and status.state == "verified" and status.audit.products > 0,
          "copper-direct-drop-audit:" .. tostring(status.error))
        check(not status.blueprint_error, "copper-blueprint-export:" .. tostring(status.blueprint_error))
        report.copper = {state = status.state, audit = status.audit,
          calls = 2, reply_bytes = report.second_start_bytes + #helpers.table_to_json(status),
          artifact = status.artifact}
        report.ok, finished = true, true
        save()
        log("STARTER_TEST_PASS")
      end
      if game.tick - started > 5000 and not finished then
        error("starter-runtime-timeout")
      end
    end)
    if not ok then
      report.error, finished = tostring(err), true
      save()
      log("STARTER_TEST_FAIL " .. tostring(err))
    end
  end)
end
