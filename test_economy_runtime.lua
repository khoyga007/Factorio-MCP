-- Loaded only by verify_economy_runtime.py in an isolated save copy.
return function(handlers, bridge_state)
  local report = {ok = false, checks = {}}
  local function check(value, name)
    assert(value, name)
    report.checks[#report.checks + 1] = name
  end
  local done = false
  script.on_event(defines.events.on_tick, function()
    if done then return end
    local ok, err = pcall(function()
      local player = assert(game.get_player(1))
      local stock = assert(player.get_main_inventory())
      bridge_state().treasury_entity = nil
      bridge_state().treasury_unit_number = nil
      stock.clear()
      player.cheat_mode = true
      stock.insert {name = "wood", count = 4}
      local crafted = handlers.craft("economy-craft", {recipe = "wooden-chest", count = 1})
      check(crafted.ok and stock.get_item_count("wood") == 2,
        "cheat-mode-craft-debits-real-wood:" .. tostring(crafted.error))
      check(player.cheat_mode, "player-cheat-setting-restored")
      stock.clear()
      for name, count in pairs { ["iron-plate"] = 9, stone = 5, wood = 2,
        ["iron-gear-wheel"] = 3, ["stone-furnace"] = 1 } do
        stock.insert {name = name, count = count}
      end
      local denied = handlers.repair_demo_economy("economy-denied", {key = "wrong"})
      check(not denied.ok and stock.get_item_count("iron-plate") == 9,
        "repair-requires-exact-key")
      local repair = handlers.repair_demo_economy("economy-repair", {key = "coal-demo-2026-09-18"})
      check(repair.ok and stock.is_empty(), "repair-debits-exact-ingredients")
      local again = handlers.repair_demo_economy("economy-repeat", {key = "coal-demo-2026-09-18"})
      check(again.ok and again.already_done and stock.is_empty(), "repair-idempotent")
      report.ok, done = true, true
    end)
    if not ok then report.error, done = tostring(err), true end
    helpers.write_file("economy-check.json", helpers.table_to_json(report), false)
  end)
end
