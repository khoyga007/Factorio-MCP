-- Engine test: build_design refuses inserters whose pickup/drop tile is empty, with a move hint.
return function(handlers,state,buggy,fixed,feeder)
  local result={ok=false,checks={}}
  local function check(v,name) assert(v,name) result.checks[#result.checks+1]=name end
  local function call(action,body) return handlers[action]("ins-"..game.tick..":"..#result.checks,body) end
  local surface,job,started,done
  script.on_event(defines.events.on_tick,function()
    if done then return end
    local ok,err=pcall(function()
      if not started then
        started=game.tick
        local player=game.get_player(1) local bag=player.get_main_inventory()
        surface=game.create_surface("ins-test",{autoplace_settings={entity={treat_missing_as_default=false,settings={}},decorative={treat_missing_as_default=false,settings={}}}})
        surface.request_to_generate_chunks({0,0},2) surface.force_generate_chunk_requests()
        for _,e in pairs(surface.find_entities()) do e.destroy() end
        local tiles={} for x=-40,40 do for y=-40,40 do tiles[#tiles+1]={name="grass-1",position={x,y}} end end surface.set_tiles(tiles)
        player.teleport({30,30},surface)
        state().treasury_entity=nil state().treasury_unit_number=nil state().autofuel_enabled=false
        bag.clear()
        for name,n in pairs{["wooden-chest"]=4,inserter=4,lab=2} do bag.insert{name=name,count=n} end
        local function run(bp,x,y,rot)
          return call("blueprint_run",{blueprint=bp,surface=surface.name,x=x,y=y,dry_run=true,
            contract={site={mode="exact",rotations={rot or 0}}}})
        end
        local r=run(buggy,0,0)
        local g=r.unconnected and r.unconnected[1]
        check(r.state=="blocked" and r.error=="inserter-unconnected" and #r.unconnected==1 and g.side=="drop"
          and g.hint and g.hint.entity=="lab" and g.hint.design_shift[1]==-1 and g.hint.design_shift[2]==0,
          "lab-off-by-one-refused-with-hint:"..helpers.table_to_json(r))
        r=run(buggy,0,-10,4)
        g=r.unconnected and r.unconnected[1]
        check(r.state=="blocked" and g and g.hint and g.hint.design_shift[1]==-1 and g.hint.design_shift[2]==0
          and g.hint.to[2]-g.hint.from[2]==-1,"rotated-hint-in-design-frame:"..helpers.table_to_json(r))
        r=run(fixed,0,0)
        check(r.state=="planned" and r.plan.count==3,"fixed-layout-planned:"..helpers.table_to_json(r))
        r=run(feeder,10,10)
        check(r.state=="blocked" and r.unconnected[1].side=="pickup" and not r.unconnected[1].hint,
          "no-source-refused:"..helpers.table_to_json(r))
        -- An existing belt outside the job counts as the source.
        surface.create_entity{name="transport-belt",position={10.5,9.5},direction=defines.direction.south,force="player"}
        job=call("blueprint_run",{blueprint=feeder,pattern_id="t-feeder",surface=surface.name,x=10,y=10,
          contract={site={mode="exact"}}})
        check(job.ok and job.job_id,"feeder-job:"..helpers.table_to_json(job))
        return
      end
      local status=call("blueprint_job",{job_id=job.job_id})
      if status.state=="preparing" or status.state=="building" then
        if game.tick-started>3000 then error("timeout:"..helpers.table_to_json(status)) end
        return
      end
      check(status.state=="verified" and status.plan.count==2,"feeder-built:"..helpers.table_to_json(status))
      local ins=surface.find_entities_filtered{name="inserter"}[1]
      local chest=surface.find_entities_filtered{name="wooden-chest"}[1]
      local p,d=ins.pickup_position,ins.drop_position
      check(math.floor(p.x)==10 and math.floor(p.y)==9,"engine-pickup-matches:"..p.x..","..p.y)
      check(math.floor(d.x)==math.floor(chest.position.x) and math.floor(d.y)==math.floor(chest.position.y),
        "engine-drop-matches:"..d.x..","..d.y)
      result.ok,done=true,true
    end)
    if not ok then result.error,done=tostring(err),true end
    if done then helpers.write_file("inserter-check.json",helpers.table_to_json(result),false) end
  end)
end
