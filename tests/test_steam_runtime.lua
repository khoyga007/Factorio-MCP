-- Engine test: generic executor on the 1:2 steam pattern (bp-985eb5fc230538b4).
-- The agent's pre-existing infrastructure is simulated east of the exact footprint:
--   substation (6,7) = electric connection, radar (8,7) = 0.3 MW constant load.
-- Water is injected as 165C steam straight into the boiler output + engine fluidbox
-- every tick: physical water routing is out of executor scope, so the physics stays
-- deterministic. Exact footprint for rotation 0 is x 0..3, y 0..14 (top-left 0,0).
return function(handlers,state,blueprint,contract_json)
  local result={ok=false,checks={}}
  local function check(v,name) assert(v,name) result.checks[#result.checks+1]=name end
  local contract=helpers.json_to_table(contract_json)
  local job,surface,stock,baseline,done,started
  local function call(action,body) return handlers[action]("exec-steam-"..game.tick..":"..#result.checks,body) end
  local function inject_steam(e)
    if not e or not e.valid then return end
    for i=1,#e.fluidbox do
      local proto=e.fluidbox.get_prototype(i)
      if proto and proto.filter and proto.filter.name=="steam" then
        e.fluidbox[i]={name="steam",amount=proto.volume or 200,temperature=165}
      end
    end
  end
  script.on_event(defines.events.on_tick,function()
    if done then return end
    if surface then
      for _,e in ipairs(surface.find_entities_filtered{name={"boiler","steam-engine"},force="player"}) do
        inject_steam(e)
      end
    end
    local ok,err=pcall(function()
      if not started then
        started=game.tick
        local player=game.get_player(1) stock=player.get_main_inventory()
        surface=game.create_surface("executor-steam",{autoplace_settings={entity={treat_missing_as_default=false,settings={}},decorative={treat_missing_as_default=false,settings={}}}})
        surface.request_to_generate_chunks({0,0},2) surface.force_generate_chunk_requests()
        for _,e in pairs(surface.find_entities()) do e.destroy() end
        local tiles={} for x=-40,40 do for y=-40,40 do tiles[#tiles+1]={name="grass-1",position={x,y}} end end surface.set_tiles(tiles)
        player.teleport({30,30},surface) player.cheat_mode=true
        state().treasury_entity=nil state().treasury_unit_number=nil state().autofuel_enabled=false
        stock.clear()
        for name,n in pairs{["boiler"]=1,["steam-engine"]=2,["burner-inserter"]=1,["iron-chest"]=1} do
          game.forces.player.recipes[name].enabled=true stock.insert{name=name,count=n}
        end
        stock.insert{name="coal",count=56}
        -- agent's pre-existing pole + load, east of the exact footprint (x 0..3, y 0..14)
        surface.create_entity{name="substation",position={6,7},force="player"}
        surface.create_entity{name="radar",position={8,7},force="player"}

        -- per-run override: declared load = radar 0.3 MW -> power min = 0.95*min(load,1.8)
        local declared=0.3
        contract.declared_load_mw=declared
        for _,m in ipairs(contract.verify.metrics) do
          if m.key=="actual_power_output_mw" then m.min=0.95*math.min(declared,1.8) end
        end

        local bad=helpers.json_to_table(contract_json) bad.site.rotations={3}
        check(not call("blueprint_run",{blueprint=blueprint,surface=surface.name,contract=bad}).ok,"bad-contract-refused")

        local base={blueprint=blueprint,pattern_id="bp-985eb5fc230538b4",surface=surface.name,x=0,y=0,radius=48,contract=contract}
        base.dry_run=true
        local dry=call("blueprint_run",base)
        check(dry.ok and dry.state=="planned" and dry.site_validated,"dry-run-finds-site:"..helpers.table_to_json(dry))
        check(stock.get_item_count("boiler")==1 and stock.get_item_count("coal")==56,"dry-run-no-debit")
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
      check(windows[#windows].values.actual_power_output_mw>=0.285,"last-window-power>=0.285")
      check(windows[#windows].values.boiler_temperature>=165,"last-window-steam>=165")
      check(windows[#windows].values.boiler_fuel_remaining>=1,"last-window-fuel>=1")
      check(surface.count_entities_filtered{force="player"}==baseline+5,"exactly-five-new-entities")
      check(stock.is_empty(),"all-items-consumed")
      check(game.get_player(1).cheat_mode,"cheat-setting-preserved")
      result.ok,done=true,true
    end)
    if not ok then result.error,done=tostring(err),true end
    if done then helpers.write_file("executor-steam-check.json",helpers.table_to_json(result),false) end
  end)
end
