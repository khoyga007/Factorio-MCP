-- Engine test: generic executor on the 2-drill coal pattern with its catalog contract.
return function(handlers,state,blueprint,contract_json)
  local result={ok=false,checks={}}
  local function check(v,name) assert(v,name) result.checks[#result.checks+1]=name end
  local contract=helpers.json_to_table(contract_json)
  local job,surface,stock,source,baseline,done,started
  local function call(action,body) return handlers[action]("exec-test-"..game.tick..":"..#result.checks,body) end
  script.on_event(defines.events.on_tick,function()
    if done then return end
    local ok,err=pcall(function()
      if not started then
        started=game.tick
        local player=game.get_player(1) stock=player.get_main_inventory()
        surface=game.create_surface("executor-test",{autoplace_settings={entity={treat_missing_as_default=false,settings={}},decorative={treat_missing_as_default=false,settings={}}}})
        surface.request_to_generate_chunks({0,0},2) surface.force_generate_chunk_requests()
        for _,e in pairs(surface.find_entities()) do e.destroy() end
        local tiles={} for x=-40,40 do for y=-40,40 do tiles[#tiles+1]={name="grass-1",position={x,y}} end end surface.set_tiles(tiles)
        for x=-12,12 do for y=-12,12 do surface.create_entity{name="coal",position={x+0.5,y+0.5},amount=1000} end end
        player.teleport({30,30},surface) player.cheat_mode=true
        state().treasury_entity=nil state().treasury_unit_number=nil state().autofuel_enabled=false
        stock.clear()
        for name,n in pairs{["burner-mining-drill"]=2,["transport-belt"]=6,["burner-inserter"]=1,["wooden-chest"]=1} do
          game.forces.player.recipes[name].enabled=true stock.insert{name=name,count=n}
        end
        for _,name in ipairs{"iron-gear-wheel","stone-furnace"} do game.forces.player.recipes[name].enabled=true end
        local original=call("blueprint_import",{blueprint=blueprint,surface=surface.name,x=0,y=0})
        check(original.ok and original.placed==10,"plain-import-still-works")
        source=surface.create_entity{name="steel-chest",position={28.5,28.5},force="player"}.get_inventory(defines.inventory.chest)
        source.insert{name="iron-plate",count=100} source.insert{name="stone",count=20}
        source.insert{name="coal",count=20} source.insert{name="wood",count=4}
        local base={blueprint=blueprint,pattern_id="bp-f30d8a84af3098ee",surface=surface.name,x=0,y=0,radius=48,contract=contract}

        local greedy=helpers.json_to_table(contract_json)
        greedy.resources[1].min_total=10000000
        local none=call("blueprint_run",{blueprint=blueprint,surface=surface.name,x=0,y=0,radius=48,contract=greedy,dry_run=true})
        check(none.ok and none.state=="blocked" and none.error=="no-site"
          and (none.rejects["resource-reserve"] or 0)>0,"no-site-with-reject-counts:"..helpers.table_to_json(none))

        local bad=helpers.json_to_table(contract_json) bad.site.rotations={3}
        check(not call("blueprint_run",{blueprint=blueprint,surface=surface.name,contract=bad}).ok,"bad-contract-refused")
        local noitem=helpers.json_to_table(contract_json) noitem.verify.metrics[1].item=nil
        local r=call("blueprint_run",{blueprint=blueprint,surface=surface.name,contract=noitem})
        check(not r.ok and r.error=="invalid-metric-item:coal_gained","metric-without-item-refused")

        base.dry_run=true
        local dry=call("blueprint_run",base)
        check(dry.ok and dry.state=="planned" and dry.site_validated,"dry-run-finds-site:"..helpers.table_to_json(dry))
        check(source.get_item_count("iron-plate")==100 and stock.is_empty(),"dry-run-no-debit")
        baseline=surface.count_entities_filtered{force="player"}
        base.dry_run=nil
        job=call("blueprint_run",base)
        check(job.ok and job.state=="preparing" and job.job_id,"one-call-start:"..helpers.table_to_json(job))
        check(call("blueprint_run",base).job_id==job.job_id,"active-job-is-reused")
        return
      end
      local status=call("blueprint_job",{job_id=job.job_id})
      if status.state=="preparing" or status.state=="building" or status.state=="settling" or status.state=="auditing" then
        if game.tick-started>40000 then error("test-timeout:"..helpers.table_to_json(status)) end
        return
      end
      result.status=status
      local windows=status.audit and status.audit.windows or {}
      check(status.state=="verified" and status.audit.status=="passed","holdout-passed:"..helpers.table_to_json(status))
      check(#windows>=2 and windows[#windows].passed,"last-window-passed")
      check(windows[#windows].values.coal_gained>=20,"last-window-coal>=20")
      check(surface.count_entities_filtered{force="player"}==baseline+10,"exactly-ten-new-entities")
      check(source.get_item_count("iron-plate")==70,"real-crafting-consumed-30-plates")
      check(source.get_item_count("coal")==20-11,"primer-coal-from-real-stock")
      check(game.get_player(1).cheat_mode,"cheat-setting-preserved")
      result.ok,done=true,true
    end)
    if not ok then result.error,done=tostring(err),true end
    if done then helpers.write_file("executor-check.json",helpers.table_to_json(result),false) end
  end)
end
