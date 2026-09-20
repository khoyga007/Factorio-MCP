-- Engine test: the facts a ghost-first executor would stand on.
-- Measures, in one run: default ghost lifetime, what build_blueprint does when part of
-- the footprint is occupied, whether revive is free (so the debit must stay ours), and
-- whether a ghost carries its recipe across revive.
return function(handlers,state,bp)
  local result={ok=false,checks={},facts={}}
  local function check(v,name) assert(v,name) result.checks[#result.checks+1]=name end
  local surface,force,phase,start_tick,kept,done=nil,nil,0,0,nil,false
  script.on_event(defines.events.on_tick,function()
    if done then return end
    local ok,err=pcall(function()
      if phase==0 then
        phase=1
        local player=game.get_player(1) local bag=player.get_main_inventory()
        force=game.forces.player
        surface=game.create_surface("ghost-test",{autoplace_settings={entity={treat_missing_as_default=false,settings={}},decorative={treat_missing_as_default=false,settings={}}}})
        surface.request_to_generate_chunks({0,0},2) surface.force_generate_chunk_requests()
        for _,e in pairs(surface.find_entities()) do e.destroy() end
        local tiles={} for x=-40,40 do for y=-40,40 do tiles[#tiles+1]={name="grass-1",position={x,y}} end end
        surface.set_tiles(tiles)
        player.teleport({30.5,30.5},surface)
        state().treasury_entity=nil state().treasury_unit_number=nil state().autofuel_enabled=false
        bag.clear()

        -- FACT 1: how long an unbuilt ghost lives. 0 in the API means forever.
        -- 2.0 moved the setting: LuaForce has no ghost_time_to_live. Probe the
        -- candidates so the answer is a reading, not a guess.
        for _,probe in pairs{
          {"map_settings.ghost_time_to_live",function() return game.map_settings.ghost_time_to_live end},
          {"force.ghost_time_to_live",function() return force.ghost_time_to_live end},
          {"surface.ghost_time_to_live",function() return surface.ghost_time_to_live end},
        } do
          local okp,v=pcall(probe[2])
          result.facts[probe[1]]=okp and tostring(v) or "no-such-field"
        end

        -- FACT 2, three readings at the SAME position, because "partial paste" can mean
        -- two different things and the first version of this test confused them:
        --   clean    - nothing in the way
        --   same     - an identical entity already sits on one planned tile
        --   foreign  - a DIFFERENT entity overlaps one planned tile
        local function paste(tag)
          local inv2=game.create_inventory(1) local st=inv2[1] st.import_stack(bp.trio)
          local g=st.build_blueprint{surface=surface,force=force,position={20,20},
            direction=defines.direction.north,build_mode=defines.build_mode.normal,raise_built=false}
          result.facts["paste_"..tag]=#g
          for _,x in pairs(g) do if x.valid then x.destroy() end end
          inv2.destroy()
        end
        paste("clean")
        local same=surface.create_entity{name="wooden-chest",position={23.5,20.5},force=force}
        paste("same_entity_present")
        same.destroy()
        local foreign=surface.create_entity{name="stone-furnace",position={23.5,20.5},force=force}
        paste("foreign_entity_overlaps")
        foreign.destroy()

        surface.create_entity{name="wooden-chest",position={3.5,0.5},force=force}
        local inv=game.create_inventory(1) local stack=inv[1]
        stack.import_stack(bp.trio)
        local planned=#(stack.get_blueprint_entities() or {})
        local ghosts=stack.build_blueprint{surface=surface,force=force,position={0,0},
          direction=defines.direction.north,build_mode=defines.build_mode.normal,raise_built=true}
        inv.destroy()
        local names={} for _,g in pairs(ghosts) do names[#names+1]=g.ghost_name..":"..g.position.x..","..g.position.y end
        result.facts.planned=planned
        result.facts.ghosts=#ghosts
        result.facts.ghost_names=names
        check(planned==3,"blueprint-has-3:"..planned)
        -- The question that decides the design: does the engine drop ONLY the blocked
        -- entity, or refuse the whole paste?
        check(#ghosts>0,"partial-paste-keeps-ghosts:"..#ghosts)

        -- FACT 3: a ghost of an assembler remembers its recipe before anything is built.
        for _,g in pairs(ghosts) do
          if g.ghost_name=="assembling-machine-1" then
            local r=g.get_recipe and g.get_recipe() or nil
            result.facts.ghost_recipe=r and r.name or "none"
            for _,probe in pairs{
              {"ghost.time_to_live",function() return g.time_to_live end},
              {"ghost.time_until_removed",function() return g.time_until_removed end},
              {"ghost.tags",function() return g.force.ghost_time_to_live end},
            } do
              local okp,v=pcall(probe[2])
              result.facts[probe[1]]=okp and tostring(v) or "no-such-field"
            end
            kept=g
          end
        end
        start_tick=game.tick
      elseif phase==1 and game.tick-start_tick>=2400 then
        phase=2
        -- FACT 1b: the ghost is still there 10 seconds later, unattended.
        check(kept and kept.valid,"ghost-alive-after-2400-ticks")
        local before={} local bag=game.get_player(1).get_main_inventory()
        bag.clear()
        result.facts.items_before=bag.get_item_count("assembling-machine-1")
        -- FACT 4: revive with an EMPTY bag. If this works, revive is free and the
        -- stock debit has to stay on our side of the call, exactly as blueprint_import
        -- already does it.
        local ok_revive,_,entity=pcall(function() return kept.revive{raise_revive=false} end)
        result.facts.revive_with_empty_bag=ok_revive and entity~=nil
        check(ok_revive,"revive-call-ok")
        if entity then
          local r=entity.get_recipe and entity.get_recipe() or nil
          result.facts.recipe_after_revive=r and r.name or "none"
          check(r and r.name=="iron-gear-wheel","recipe-survives-revive:"..tostring(r and r.name))
        end
        check(result.facts.revive_with_empty_bag,"revive-is-free-so-we-must-debit")
        result.ok=true
        done=true
      end
    end)
    if not ok then result.error,done=tostring(err),true end
    if done then helpers.write_file("ghost-check.json",helpers.table_to_json(result),false) end
  end)
end
