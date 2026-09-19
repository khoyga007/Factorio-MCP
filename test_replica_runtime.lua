return function(handlers,state,blueprint)
  local result={ok=false,checks={}}
  local function check(v,name) assert(v,name) result.checks[#result.checks+1]=name end
  local started,job,surface,stock,source,baseline,done
  local function call(body) return handlers.blueprint_import("replica-test-"..game.tick,body) end
  script.on_event(defines.events.on_tick,function()
    if done then return end
    local ok,err=pcall(function()
      if not started then
        local player=game.get_player(1) stock=player.get_main_inventory()
        surface=game.create_surface("replica-test",{autoplace_settings={entity={treat_missing_as_default=false,settings={}},decorative={treat_missing_as_default=false,settings={}}}})
        surface.request_to_generate_chunks({0,0},2) surface.force_generate_chunk_requests()
        for _,e in pairs(surface.find_entities()) do e.destroy() end
        local tiles={} for x=-32,32 do for y=-32,32 do tiles[#tiles+1]={name="grass-1",position={x,y}} end end surface.set_tiles(tiles)
        for x=-12,12 do for y=-12,12 do surface.create_entity{name="coal",position={x+0.5,y+0.5},amount=1000} end end
        player.teleport({20,20},surface) player.cheat_mode=true
        state().treasury_entity=nil state().treasury_unit_number=nil state().autofuel_enabled=false
        stock.clear()
        for name,n in pairs{["burner-mining-drill"]=2,["transport-belt"]=6,["burner-inserter"]=1,["wooden-chest"]=1} do
          game.forces.player.recipes[name].enabled=true stock.insert{name=name,count=n}
        end
        for _,name in ipairs{"iron-gear-wheel","stone-furnace"} do game.forces.player.recipes[name].enabled=true end
        local original=call{blueprint=blueprint,surface=surface.name,x=0,y=0}
        check(original.ok and original.placed==10,"original-line-imported")
        source=surface.create_entity{name="steel-chest",position={18.5,18.5},force="player"}.get_inventory(defines.inventory.chest)
        source.insert{name="iron-plate",count=100} source.insert{name="stone",count=20} source.insert{name="coal",count=20}
        local body={automate=true,blueprint=blueprint,pattern_id="bp-f30d8a84af3098ee",surface=surface.name,x=0,y=0,radius=32,dry_run=true}
        local blocked=call(body)
        check(blocked.ok and blocked.state=="blocked" and blocked.missing.wood,"missing-wood-blocks-before-debit:"..helpers.table_to_json(blocked))
        check(source.get_item_count("iron-plate")==100 and stock.is_empty(),"blocked-no-debit")
        source.insert{name="wood",count=4}
        local dry=call(body)
        check(dry.ok and dry.state=="planned" and dry.site_validated,"dry-run-real-site:"..helpers.table_to_json(dry))
        check(source.get_item_count("iron-plate")==100 and stock.is_empty(),"dry-run-no-debit")
        baseline=surface.count_entities_filtered{force="player"}
        body.dry_run=false job=call(body)
        check(job.ok and job.state=="preparing" and job.job_id,"one-call-start:"..helpers.table_to_json(job))
        local duplicate=call(body)
        check(duplicate.job_id==job.job_id,"active-job-is-reused")
        started=game.tick
      elseif game.tick-started>=4200 then
        local status=handlers.coal_status("replica-report",{job_id=job.job_id})
        result.status=status
        check(status.state=="verified" and status.audit.coal_gained>0,"output-audit:"..helpers.table_to_json(status))
        check(surface.count_entities_filtered{force="player"}==baseline+10,"exactly-ten-new-entities")
        check(source.get_item_count("iron-plate")==70,"real-crafting-consumed-30-plates")
        check(source.get_item_count("stone")==10 and source.get_item_count("wood")==2,"real-stone-and-wood")
        check(game.get_player(1).cheat_mode,"cheat-setting-preserved")
        result.ok,done=true,true
      end
    end)
    if not ok then result.error,done=tostring(err),true end
    if done then helpers.write_file("replica-check.json",helpers.table_to_json(result),false) end
  end)
end
