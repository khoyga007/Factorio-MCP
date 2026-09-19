-- Engine test: water_sites (offshore-pump spots) and recall (own entities -> bag).
return function(handlers,state)
  local result={ok=false,checks={}}
  local function check(v,name) assert(v,name) result.checks[#result.checks+1]=name end
  local function call(action,body) return handlers[action]("field-"..game.tick..":"..#result.checks,body) end
  local done
  script.on_event(defines.events.on_tick,function()
    if done then return end
    local ok,err=pcall(function()
      local player=game.get_player(1) local bag=player.get_main_inventory()
      local surface=game.create_surface("field-test",{autoplace_settings={entity={treat_missing_as_default=false,settings={}},decorative={treat_missing_as_default=false,settings={}}}})
      surface.request_to_generate_chunks({0,0},3) surface.force_generate_chunk_requests()
      for _,e in pairs(surface.find_entities()) do e.destroy() end
      local tiles={}
      for x=-60,60 do for y=-60,60 do
        tiles[#tiles+1]={name=(x>=10 and x<20 and y>=-5 and y<5) and "water" or "grass-1",position={x,y}}
      end end
      surface.set_tiles(tiles)
      -- Trees along the west shore (nearest to 0,0): those spots must come back blocked.
      for y=-6,5 do surface.create_entity{name="tree-01",position={9.5,y+0.5}} end
      player.teleport({0,0},surface)
      state().treasury_entity=nil state().treasury_unit_number=nil
      bag.clear()

      local w=call("water_sites",{surface=surface.name,x=0,y=0,radius=64})
      check(w.ok and #w.candidates>0,"water-candidates:"..helpers.table_to_json(w))
      check(w.clusters[1] and w.clusters[1].types.water>0,"water-cluster-types")
      for _,c in ipairs(w.candidates) do check(c.x<9 or c.x>=10,"candidate-not-under-tree") end
      check(#w.blocked>0 and #w.blocked[1].obstacles>0,"blocked-lists-trees:"..helpers.table_to_json(w.blocked))
      local c=w.candidates[1]
      check(c.output,"candidate-has-output")
      local pump=surface.create_entity{name="offshore-pump",position={c.x,c.y},direction=c.direction,force="player"}
      check(pump,"pump-placeable-at-candidate")
      local pipe=surface.create_entity{name="pipe",position={c.output.x,c.output.y},force="player"}
      check(pipe,"pipe-at-output")
      local linked=false
      for _,other in pairs(pump.fluidbox.get_connections(1)) do if other.owner==pipe then linked=true end end
      check(linked,"output-tile-connects-pump:"..helpers.table_to_json(c))
      local page2=call("water_sites",{surface=surface.name,x=0,y=0,radius=64,offset=1})
      check(page2.ok and page2.candidates[1] and (page2.candidates[1].x~=c.x or page2.candidates[1].y~=c.y or page2.candidates[1].direction~=c.direction),"water-offset-pages")

      -- Recall: chest with plates, belt with items, furnace with ore, inserter.
      local chest=surface.create_entity{name="wooden-chest",position={-20.5,-20.5},force="player"}
      chest.insert{name="iron-plate",count=10}
      local belt=surface.create_entity{name="transport-belt",position={-18.5,-20.5},direction=defines.direction.east,force="player"}
      belt.get_transport_line(1).insert_at_back{name="coal",count=1}
      local furnace=surface.create_entity{name="stone-furnace",position={-15,-20},force="player"}
      furnace.insert{name="iron-ore",count=7}
      surface.create_entity{name="burner-inserter",position={-19.5,-20.5},direction=defines.direction.west,force="player"}
      local tree=surface.create_entity{name="tree-01",position={-17.5,-17.5}}
      local area={surface=surface.name,x1=-22,y1=-22,x2=-12,y2=-16}
      local dry=call("recall",{surface=surface.name,x1=-22,y1=-22,x2=-12,y2=-16,dry_run=true})
      check(dry.ok and dry.count==4 and chest.valid,"recall-dry-run-lists-4:"..helpers.table_to_json(dry))
      state().executor_jobs={["exec-9"]={id="exec-9",state="auditing",surface=surface.name,
        layout={{name="stone-furnace",x=-15,y=-20}}}}
      local refused=call("recall",area)
      check(not refused.ok and refused.error=="active-job:exec-9" and furnace.valid,"recall-refuses-active-job")
      area.force_active=true
      local r=call("recall",area)
      check(r.ok and r.count==4,"recall-done:"..helpers.table_to_json(r))
      check(r.delta["wooden-chest"]==1 and r.delta["iron-plate"]==10 and r.delta["iron-ore"]==7
        and r.delta["stone-furnace"]==1 and r.delta["burner-inserter"]==1 and r.delta["transport-belt"]==1,
        "recall-delta-entities-and-contents:"..helpers.table_to_json(r.delta))
      check((r.delta["coal"] or 0)==1,"belt-items-returned:"..helpers.table_to_json(r.delta))
      check(tree.valid and not chest.valid,"tree-untouched")
      state().executor_jobs={}
      check(not call("recall",{surface=surface.name,x1=0,y1=0,x2=100,y2=1}).ok,"area-cap-64")
      result.ok=true
    end)
    if not ok then result.error=tostring(err) end
    done=true
    helpers.write_file("field-check.json",helpers.table_to_json(result),false)
  end)
end
