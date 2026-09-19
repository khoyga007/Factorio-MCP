-- Engine test: holdout FAIL path on the 2-drill coal pattern.
-- Feed is dropped and drill primer cut to 1 coal, so both drills stall mid-window:
-- active_drills < 2 and coal_gained < 20 in the last window -> needs-attention
-- with error holdout-last-window-failed.
return function(handlers,state,blueprint,contract_json)
  local result={ok=false,checks={}}
  local function check(v,name) assert(v,name) result.checks[#result.checks+1]=name end
  local fail_contract=helpers.json_to_table(contract_json)
  fail_contract.feeds={}
  for _,p in ipairs(fail_contract.primer) do
    if p.entity=="burner-mining-drill" then p.count=1 end
  end
  local job,surface,stock,baseline,done,started
  local function call(action,body) return handlers[action]("exec-fail-"..game.tick..":"..#result.checks,body) end
  script.on_event(defines.events.on_tick,function()
    if done then return end
    local ok,err=pcall(function()
      if not started then
        started=game.tick
        local player=game.get_player(1) stock=player.get_main_inventory()
        surface=game.create_surface("executor-fail",{autoplace_settings={entity={treat_missing_as_default=false,settings={}},decorative={treat_missing_as_default=false,settings={}}}})
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
        stock.insert{name="coal",count=3} -- primer: 1 coal x 2 drills + 1 coal x 1 inserter
        baseline=surface.count_entities_filtered{force="player"}
        job=call("blueprint_run",{blueprint=blueprint,pattern_id="bp-f30d8a84af3098ee",surface=surface.name,x=0,y=0,radius=48,contract=fail_contract})
        check(job.ok and job.state=="preparing" and job.job_id,"one-call-start:"..helpers.table_to_json(job))
        return
      end
      local status=call("blueprint_job",{job_id=job.job_id})
      if status.state=="preparing" or status.state=="building" or status.state=="settling" or status.state=="auditing" then
        if game.tick-started>40000 then error("test-timeout:"..helpers.table_to_json(status)) end
        return
      end
      result.status=status
      local windows=status.audit and status.audit.windows or {}
      check(status.state=="needs-attention" and status.error=="holdout-last-window-failed",
        "holdout-failed:"..helpers.table_to_json(status))
      check(status.audit.status=="failed","audit-failed")
      check(#windows>=2 and not windows[#windows].passed,"last-window-failed")
      check(windows[#windows].values.active_drills<2,"last-window-drills-stalled")
      check(windows[#windows].values.coal_gained<20,"last-window-coal-below-min")
      check(surface.count_entities_filtered{force="player"}==baseline+10,"ten-entities-built")
      result.ok,done=true,true
    end)
    if not ok then result.error,done=tostring(err),true end
    if done then helpers.write_file("executor-fail-check.json",helpers.table_to_json(result),false) end
  end)
end
