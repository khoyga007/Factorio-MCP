-- Loaded only by verify_coal_runtime.py in an isolated benchmark mod.
return function(handlers, bridge_state)
  local report = {ok = false, checks = {}}
  local function check(value, name)
    assert(value, name)
    report.checks[#report.checks + 1] = name
  end
  local function save()
    helpers.write_file("coal-check.json", helpers.table_to_json(report), false)
  end
  local started, job, done, drill, chest = nil, nil, false, nil, nil
  local function setup()
    local player = assert(game.get_player(1))
    local pocket = assert(player.get_main_inventory())
    local surface = game.create_surface("ai-coal-test", {
      autoplace_settings = {entity = {treat_missing_as_default = false, settings = {}},
        decorative = {treat_missing_as_default = false, settings = {}}},
    })
    surface.request_to_generate_chunks({0, 0}, 2)
    surface.force_generate_chunk_requests()
    for _, entity in pairs(surface.find_entities()) do entity.destroy() end
    local tiles = {}
    for x = -24, 24 do for y = -24, 24 do
      tiles[#tiles + 1] = {name = "grass-1", position = {x, y}}
    end end
    surface.set_tiles(tiles)
    local offsets = {[0] = {-0.5, -1.5}, [4] = {1.5, -0.5},
      [8] = {0.5, 1.5}, [12] = {-1.5, 0.5}}
    for direction, offset in pairs(offsets) do
      local px, py = 12, direction * 2 - 12
      local probe = assert(surface.create_entity {name = "burner-mining-drill",
        position = {px, py}, direction = direction, force = "player"})
      local cx, cy = px + offset[1], py + offset[2]
      local box = {left_top = {x = cx - 0.5, y = cy - 0.5},
        right_bottom = {x = cx + 0.5, y = cy + 0.5}}
      check(probe.drop_position.x >= box.left_top.x
        and probe.drop_position.x <= box.right_bottom.x
        and probe.drop_position.y >= box.left_top.y
        and probe.drop_position.y <= box.right_bottom.y,
        "drop-cell-direction-" .. direction .. ":" .. helpers.table_to_json {
          drop = probe.drop_position, box = box})
      probe.destroy()
    end
    for x = -4, 4 do for y = -4, 4 do
      assert(surface.create_entity {name = "coal", position = {x + 0.5, y + 0.5}, amount = 1000})
    end end
    local state = bridge_state()
    state.treasury_entity, state.treasury_unit_number = nil, nil
    state.autofuel_enabled = false
    game.forces.player.recipes["burner-mining-drill"].enabled = true
    game.forces.player.recipes["wooden-chest"].enabled = true
    pocket.clear()
    pocket.insert {name = "burner-mining-drill", count = 1}
    pocket.insert {name = "wooden-chest", count = 1}
    local function call(name, body)
      body.surface = surface.name
      return handlers[name]("coal-test-" .. name .. "-" .. game.tick, body)
    end
    local body = {x = 0, y = 0, radius = 16, dry_run = true}
    local blocked = call("coal_stockpile", body)
    check(blocked.ok and blocked.state == "blocked" and blocked.missing[1] == "coal-or-wood:1",
      "no-free-fuel")
    check(surface.count_entities_filtered {force = "player"} == 0,
      "blocked-no-build")
    pocket.insert {name = "wood", count = 1}
    local planned = call("coal_stockpile", body)
    check(planned.ok and planned.state == "planned" and planned.site,
      "dry-run-site")
    check(surface.count_entities_filtered {force = "player"} == 0
      and pocket.get_item_count("wood") == 1, "dry-run-no-debit")
    body.dry_run = false
    job = call("coal_stockpile", body)
    check(job.ok and job.state == "auditing" and job.job_id, "cell-build:" .. tostring(job.error))
    check(pocket.get_item_count("wood") == 0 and pocket.get_item_count("wooden-chest") == 0
      and pocket.get_item_count("burner-mining-drill") == 0, "real-kit-debited")
    drill = assert(surface.find_entity("burner-mining-drill",
      {job.site.drill.x, job.site.drill.y}))
    chest = assert(surface.find_entity("wooden-chest",
      {job.site.chest.x, job.site.chest.y}))
    check(drill.drop_position.x >= chest.bounding_box.left_top.x
      and drill.drop_position.x <= chest.bounding_box.right_bottom.x
      and drill.drop_position.y >= chest.bounding_box.left_top.y
      and drill.drop_position.y <= chest.bounding_box.right_bottom.y,
      "drill-drop-hits-chest")
    started = game.tick
    report.job_id = job.job_id
  end
  script.on_event(defines.events.on_tick, function()
    if done then return end
    local ok, err = pcall(function()
      if not started then setup() end
      if game.tick - started >= 1900 then
        local status = handlers.coal_status("coal-status-" .. game.tick,
          {job_id = report.job_id})
        check(status.ok and status.state == "verified" and status.audit.coal_gained > 0,
          "measured-real-coal:" .. tostring(status.error))
        local surface = game.get_surface("ai-coal-test")
        local ore_left = 0
        for _, e in pairs(surface.find_entities_filtered {type = "resource", name = "coal"}) do
          ore_left = ore_left + e.amount
        end
        check(ore_left < 81000, "resource-depleted")
        local reuse = handlers.coal_stockpile("coal-reuse-" .. game.tick,
          {surface = surface.name, x = 0, y = 0, radius = 16, dry_run = true})
        check(reuse.ok and reuse.existing and reuse.state == "planned",
          "recognizes-existing-cell-and-local-coal")
        local count_before = surface.count_entities_filtered {force = "player"}
        local resumed = handlers.coal_stockpile("coal-resume-" .. game.tick,
          {surface = surface.name, x = 0, y = 0, radius = 16})
        check(resumed.ok and resumed.existing and resumed.state == "auditing",
          "reuses-and-refuels-cell:" .. tostring(resumed.error))
        check(surface.count_entities_filtered {force = "player"} == count_before,
          "reuse-no-duplicate")
        report.audit, report.reply_bytes = status.audit,
          #helpers.table_to_json(job) + #helpers.table_to_json(status)
        report.ok, done = true, true
        save()
      end
    end)
    if not ok then
      report.error, done = tostring(err), true
      save()
    end
  end)
end
