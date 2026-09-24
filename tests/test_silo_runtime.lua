-- Engine test: insert into a rocket-silo (parts ingredients -> input, satellite -> rocket cargo).
return function(handlers,state)
  local result={ok=false,checks={}}
  local function check(v,name) assert(v,name) result.checks[#result.checks+1]=name end
  local function call(action,body) return handlers[action]("silo-"..game.tick..":"..#result.checks,body) end
  local done
  script.on_event(defines.events.on_tick,function()
    if done then return end
    local ok,err=pcall(function()
      local player=game.get_player(1) local bag=player.get_main_inventory()
      local surface=game.create_surface("silo-test",{autoplace_settings={entity={treat_missing_as_default=false,settings={}},decorative={treat_missing_as_default=false,settings={}}}})
      surface.request_to_generate_chunks({0,0},2) surface.force_generate_chunk_requests()
      for _,e in pairs(surface.find_entities()) do e.destroy() end
      player.teleport({20,20},surface)
      state().treasury_entity=nil state().treasury_unit_number=nil
      bag.clear()
      for _,s in ipairs{{"low-density-structure",10},{"rocket-fuel",10},{"processing-unit",10},{"iron-plate",5}} do
        bag.insert{name=s[1],count=s[2]}
      end
      local silo=surface.create_entity{name="rocket-silo",position={0.5,0.5},force="player"}
      check(silo,"silo-created")
      local function put(item,count)
        return call("insert",{surface=surface.name,x=silo.position.x,y=silo.position.y,item=item,count=count})
      end
      local input=silo.get_inventory(defines.inventory.rocket_silo_input)
      for _,item in ipairs{"low-density-structure","rocket-fuel","processing-unit"} do
        local r=put(item,10)
        check(r.ok and r.slot=="input" and input.get_item_count(item)==10 and bag.get_item_count(item)==0,
          "input:"..item..":"..helpers.table_to_json(r))
      end
      -- Not a part ingredient: rocket cargo (base 2.0 has no satellite; the cargo slots
      -- exist before any rocket is built, 20 of them measured 24/09).
      local r=put("iron-plate",5)
      local rocket=silo.get_inventory(defines.inventory.rocket_silo_rocket)
      check(r.ok and r.slot=="rocket" and rocket.get_item_count("iron-plate")==5
        and input.get_item_count("iron-plate")==0 and bag.get_item_count("iron-plate")==0,
        "cargo:"..helpers.table_to_json(r))
      result.ok=true
    end)
    if not ok then result.error=tostring(err) end
    done=true
    helpers.write_file("silo-check.json",helpers.table_to_json(result),false)
  end)
end
