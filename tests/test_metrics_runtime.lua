-- Engine test: products_finished + research_units metrics, research queue via action.
return function(handlers,state,furnace_bp,furnace_c,lab_bp,lab_c)
  local result={ok=false,checks={}}
  local function check(v,name) assert(v,name) result.checks[#result.checks+1]=name end
  local function call(action,body) return handlers[action]("metrics-"..game.tick..":"..#result.checks,body) end
  local surface,job,phase,started,done
  script.on_event(defines.events.on_tick,function()
    if done then return end
    local ok,err=pcall(function()
      if not started then
        started=game.tick
        local player=game.get_player(1) local bag=player.get_main_inventory()
        surface=game.create_surface("metrics-test",{autoplace_settings={entity={treat_missing_as_default=false,settings={}},decorative={treat_missing_as_default=false,settings={}}}})
        surface.request_to_generate_chunks({0,0},2) surface.force_generate_chunk_requests()
        for _,e in pairs(surface.find_entities()) do e.destroy() end
        local tiles={} for x=-40,40 do for y=-40,40 do tiles[#tiles+1]={name="grass-1",position={x,y}} end end surface.set_tiles(tiles)
        for x=-10,10 do for y=-10,10 do surface.create_entity{name="iron-ore",position={x+0.5,y+0.5},amount=1000} end end
        player.teleport({30,30},surface)
        state().treasury_entity=nil state().treasury_unit_number=nil state().autofuel_enabled=false
        bag.clear()
        for name,n in pairs{["burner-mining-drill"]=1,["stone-furnace"]=1,coal=8,lab=2,["small-electric-pole"]=4,["automation-science-pack"]=80} do bag.insert{name=name,count=n} end
        -- Test-only power source west of the lab site.
        local eei=surface.create_entity{name="electric-energy-interface",position={-24,-20},force="player"}
        eei.power_production=10000000 eei.electric_buffer_size=10000000
        surface.create_entity{name="small-electric-pole",position={-21.5,-20.5},force="player"}
        local force=game.forces.player
        for _,n in ipairs{"automation","logistics","automation-2"} do force.technologies[n].researched=false end
        force.technologies["automation-science-pack"].researched=true force.research_queue={}
        force.cancel_current_research()
        local r1=call("research",{name="automation",start=true,surface=surface.name})
        local r2=call("research",{name="logistics",start=true,surface=surface.name})
        check(r1.ok and r1.current=="automation","research-started:"..helpers.table_to_json(r1))
        check(r2.ok and #r2.queue==2 and r2.queue[2]=="logistics","research-queued-while-busy:"..helpers.table_to_json(r2))
        local r3=call("research",{name="no-such-tech",start=true,surface=surface.name})
        check(not r3.ok,"unknown-tech-refused:"..helpers.table_to_json(r3))
        local view=call("research",{surface=surface.name,available=true})
        check(view.ok and #view.available>0,"available-list")
        phase="furnace"
        job=call("blueprint_run",{blueprint=furnace_bp,pattern_id="t-furnace",surface=surface.name,x=0,y=0,radius=30,
          contract=helpers.json_to_table(furnace_c)})
        check(job.ok and job.job_id,"furnace-job:"..helpers.table_to_json(job))
        return
      end
      local status=call("blueprint_job",{job_id=job.job_id})
      if status.state=="preparing" or status.state=="building" or status.state=="settling" or status.state=="auditing" then
        if game.tick-started>30000 then error("timeout:"..helpers.table_to_json(status)) end
        return
      end
      if phase=="furnace" then
        result.furnace=status
        local last=status.audit and status.audit.last
        check(status.state=="verified" and last.values.plates>=3,"products-finished-passed:"..helpers.table_to_json(status))
        phase="lab"
        job=call("blueprint_run",{blueprint=lab_bp,pattern_id="t-lab",surface=surface.name,x=-15,y=-22,
          contract=helpers.json_to_table(lab_c)})
        check(job.ok and job.job_id,"lab-job:"..helpers.table_to_json(job))
        return
      end
      if phase=="island" then
        result.island=status
        check(status.state~="verified" and tostring(status.error):find("infra%-missing:power:lab"),"island-lab-refused:"..helpers.table_to_json(status))
        result.ok,done=true,true
        return
      end
      result.lab=status
      local poles=surface.find_entities_filtered{name="small-electric-pole",area={{-16,-22},{-7,-19}}}
      check(#poles==2 and poles[1].electric_network_id==poles[2].electric_network_id,"layout-poles-wired")
      local last=status.audit and status.audit.last
      local cap=1800*(1+game.forces.player.laboratory_speed_modifier)/600*1.05
      result.cap=cap
      check(status.state=="verified" and last.values.units>=1.5 and last.values.units<=cap,"research-units-passed-own-labs-only:"..helpers.table_to_json(status))
      phase="island"
      job=call("blueprint_run",{blueprint=lab_bp,pattern_id="t-island",surface=surface.name,x=20,y=20,
        contract=helpers.json_to_table(lab_c)})
      check(job.ok and job.job_id,"island-job:"..helpers.table_to_json(job))
    end)
    if not ok then result.error,done=tostring(err),true end
    if done then helpers.write_file("metrics-check.json",helpers.table_to_json(result),false) end
  end)
end
