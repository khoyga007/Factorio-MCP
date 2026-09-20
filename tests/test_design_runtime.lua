-- Engine test: agent-authored design (build_design path) through the generic executor.
return function(handlers,state,blueprint,contract_json)
  local result={ok=false,checks={}}
  local function check(v,name) assert(v,name) result.checks[#result.checks+1]=name end
  local contract=helpers.json_to_table(contract_json)
  local job,surface,done,started
  local function call(action,body) return handlers[action]("design-test-"..game.tick..":"..#result.checks,body) end
  script.on_event(defines.events.on_tick,function()
    if done then return end
    local ok,err=pcall(function()
      if not started then
        started=game.tick
        local player=game.get_player(1) local stock=player.get_main_inventory()
        surface=game.create_surface("design-test",{autoplace_settings={entity={treat_missing_as_default=false,settings={}},decorative={treat_missing_as_default=false,settings={}}}})
        surface.request_to_generate_chunks({0,0},2) surface.force_generate_chunk_requests()
        for _,e in pairs(surface.find_entities()) do e.destroy() end
        local tiles={} for x=-40,40 do for y=-40,40 do tiles[#tiles+1]={name="grass-1",position={x,y}} end end surface.set_tiles(tiles)
        for x=-12,12 do for y=-12,12 do surface.create_entity{name="coal",position={x+0.5,y+0.5},amount=1000} end end
        player.teleport({30,30},surface)
        state().treasury_entity=nil state().treasury_unit_number=nil state().autofuel_enabled=false
        stock.clear()
        stock.insert{name="burner-mining-drill",count=2} stock.insert{name="wooden-chest",count=2} stock.insert{name="coal",count=6}
        job=call("blueprint_run",{blueprint=blueprint,pattern_id="design-test",surface=surface.name,x=0,y=0,radius=48,contract=contract})
        check(job.ok and job.state=="preparing","design-job-started:"..helpers.table_to_json(job))
        return
      end
      local status=call("blueprint_job",{job_id=job.job_id})
      if status.state=="preparing" or status.state=="building" or status.state=="settling" or status.state=="auditing" then
        if game.tick-started>40000 then error("test-timeout:"..helpers.table_to_json(status)) end
        return
      end
      result.status=status
      check(status.state=="verified" and status.audit.status=="passed","holdout-passed:"..helpers.table_to_json(status))
      -- force="player" also counts the player's own character when the save has one, so
      -- name what the job built instead of counting everything standing on the surface.
      local built=surface.count_entities_filtered{force="player",
        name={"burner-mining-drill","wooden-chest"}}
      check(built==4,"four-entities:"..tostring(built))
      result.ok,done=true,true
    end)
    if not ok then result.error,done=tostring(err),true end
    if done then helpers.write_file("design-check.json",helpers.table_to_json(result),false) end
  end)
end
