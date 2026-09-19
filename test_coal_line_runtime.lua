-- Isolated blueprint fixture: two coal drills feed a belt, burner inserter, chest.
return function(handlers, bridge_state)
  local report = {ok = false, checks = {}}
  local function check(value, name)
    assert(value, name)
    report.checks[#report.checks + 1] = name
  end
  local done, started, surface, chest = false, nil, nil, nil
  script.on_event(defines.events.on_tick, function()
    if done then return end
    local ok, err = pcall(function()
      if not started then
        surface = game.create_surface("ai-coal-line-test", {
          autoplace_settings = {entity = {treat_missing_as_default = false, settings = {}},
            decorative = {treat_missing_as_default = false, settings = {}}},
        })
        surface.request_to_generate_chunks({0, 0}, 2)
        surface.force_generate_chunk_requests()
        for _, entity in pairs(surface.find_entities()) do entity.destroy() end
        local tiles = {}
        for x = -16, 16 do for y = -16, 16 do
          tiles[#tiles + 1] = {name = "grass-1", position = {x, y}}
        end end
        surface.set_tiles(tiles)
        for x = -2, 5 do for y = -1, 1 do
          surface.create_entity {name = "coal", position = {x + 0.5, y + 0.5}, amount = 1000}
        end end
        local entities = {}
        for _, x in ipairs {0, 3} do
          entities[#entities + 1] = assert(surface.create_entity {
            name = "burner-mining-drill", position = {x, 0}, direction = 0, force = "player"})
        end
        for x = -0.5, 4.5, 1 do
          entities[#entities + 1] = assert(surface.create_entity {
            name = "transport-belt", position = {x, -1.5}, direction = 4, force = "player"})
        end
        local inserter = assert(surface.create_entity {name = "burner-inserter",
          position = {5.5, -1.5}, direction = 12, force = "player"})
        entities[#entities + 1] = inserter
        chest = assert(surface.create_entity {name = "wooden-chest",
          position = {6.5, -1.5}, force = "player"})
        entities[#entities + 1] = chest
        check(#entities == 10, "two-drills-six-belts-inserter-chest")
        for _, e in ipairs(entities) do
          if e.name == "burner-mining-drill" or e.name == "burner-inserter" then
            check(e.get_fuel_inventory().insert {name = "coal", count = 1} == 1,
              "seed-fuel-" .. e.name .. "-" .. e.position.x)
          end
        end
        local exported = handlers.blueprint_export("line-export", {
          surface = surface.name, x1 = -2, y1 = -4, x2 = 9, y2 = 3})
        check(exported.ok and exported.entities == 10, "native-blueprint-export")
        helpers.write_file("coal-line-v1.blueprint.txt", exported.blueprint .. "\n", false)
        local stock = assert(game.get_player(1).get_main_inventory())
        bridge_state().treasury_entity, bridge_state().treasury_unit_number = nil, nil
        stock.clear()
        for name, count in pairs { ["burner-mining-drill"] = 2,
          ["transport-belt"] = 6, ["burner-inserter"] = 1,
          ["wooden-chest"] = 1 } do
          stock.insert {name = name, count = count}
          game.forces.player.recipes[name].enabled = true
        end
        local target = game.create_surface("ai-coal-line-import", {
          autoplace_settings = {entity = {treat_missing_as_default = false, settings = {}},
            decorative = {treat_missing_as_default = false, settings = {}}},
        })
        target.request_to_generate_chunks({0, 0}, 2)
        target.force_generate_chunk_requests()
        for _, entity in pairs(target.find_entities()) do entity.destroy() end
        target.set_tiles(tiles)
        for x = -8, 8 do for y = -8, 8 do
          target.create_entity {name = "coal", position = {x + 0.5, y + 0.5}, amount = 1000}
        end end
        local imported = handlers.blueprint_import("line-import", {
          surface = target.name, force = "player", x = 0, y = 0,
          blueprint = exported.blueprint, mode = "direct"})
        check(imported.ok and imported.placed == 10,
          "native-blueprint-import-real-kit:" .. helpers.table_to_json(imported))
        check(stock.get_item_count("burner-mining-drill") == 0
          and stock.get_item_count("transport-belt") == 0
          and stock.get_item_count("burner-inserter") == 0
          and stock.get_item_count("wooden-chest") == 0,
          "blueprint-debits-entire-kit")
        bridge_state().autofuel_enabled = true
        started = game.tick
      elseif game.tick - started >= 2400 then
        local count = chest.get_inventory(defines.inventory.chest).get_item_count("coal")
        check(count > 0, "belt-and-burner-inserter-deliver-coal")
        report.coal = count
        report.ok, done = true, true
      end
    end)
    if not ok then report.error, done = tostring(err), true end
    if done then helpers.write_file("coal-line-check.json", helpers.table_to_json(report), false) end
  end)
end
