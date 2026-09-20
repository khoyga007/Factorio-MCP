-- Engine test: power pre-check must reach a LIVE grid, footprint occupancy is per entity
-- (not the design's bounding box), and a built job that needs attention can be resumed.
return function(handlers,state,bp)
  local result={ok=false,checks={}}
  local function check(v,name) assert(v,name) result.checks[#result.checks+1]=name end
  local function call(action,body) return handlers[action]("power-"..game.tick..":"..#result.checks,body) end
  local surface,job,phase,started,done,player,chest
  local function run(blueprint,x,y,contract,dry)
    return call("blueprint_run",{blueprint=blueprint,surface=surface.name,x=x,y=y,
      contract=contract,dry_run=dry})
  end
  local function busy(id)
    local s=call("blueprint_job",{job_id=id})
    return s.state=="preparing" or s.state=="building",s
  end
  local POWER={site={mode="exact"},connect={{entity="lab",power=true}}}
  local EXACT={site={mode="exact"}}
  script.on_event(defines.events.on_tick,function()
    if done then return end
    local ok,err=pcall(function()
      if not started then
        started=game.tick
        player=game.get_player(1)
        local bag=player.get_main_inventory()
        surface=game.create_surface("power-test",{autoplace_settings={entity={treat_missing_as_default=false,settings={}},decorative={treat_missing_as_default=false,settings={}}}})
        surface.request_to_generate_chunks({32,0},3) surface.force_generate_chunk_requests()
        for _,e in pairs(surface.find_entities()) do e.destroy() end
        local tiles={} for x=-10,90 do for y=-20,20 do tiles[#tiles+1]={name="grass-1",position={x,y}} end end
        surface.set_tiles(tiles)
        player.teleport({30.5,16.5},surface)
        surface.create_entity{name="character",position={30.5,16.5},force="player"}
        state().treasury_entity=nil state().treasury_unit_number=nil state().autofuel_enabled=false
        bag.clear()
        bag.insert{name="lab",count=2} bag.insert{name="small-electric-pole",count=6}
        bag.insert{name="wooden-chest",count=4} bag.insert{name="coal",count=5}

        -- Design: lab, a pole beside it, and a pole 7 tiles further out. The far pole makes
        -- the bounding box 11 tiles wide while the entities themselves occupy 5 tiles.
        -- A chest parked in the empty middle of that box must NOT read as occupied.
        chest=surface.create_entity{name="wooden-chest",position={8.5,0.5},force="player"}
        local a=run(bp.main,0,0,EXACT,true)
        check(a.state=="planned" and not (a.rejects or {}).occupied,
          "far-pole-not-occupied:"..helpers.table_to_json(a))
        -- Something on an entity's own tiles still blocks.
        local hit=surface.create_entity{name="wooden-chest",position={1.5,1.5},force="player"}
        local d=run(bp.main,0,0,EXACT,true)
        check(d.state=="blocked" and (d.rejects or {}).occupied,"real-overlap-occupied:"..helpers.table_to_json(d))
        hit.destroy()

        -- A live grid, far away from this site.
        surface.create_entity{name="solar-panel",position={50.5,0.5},force="player"}
        surface.create_entity{name="small-electric-pole",position={52.5,0.5},force="player"}

        -- No pole of this layout can wire back to that grid, so the lab would never run.
        -- The pre-check has to say so; before the fix a pole in the layout was enough and
        -- the job only failed after the machines were already on the ground.
        local b=run(bp.main,0,0,POWER,true)
        check(b.state=="blocked" and (b.rejects or {})["no-power"] and b.rejects["no-power"]>0,
          "no-power-prebuild:"..helpers.table_to_json(b))
        -- Same design where the far pole is in wire reach of the grid: fed through the
        -- layout's own run, lab covered by the near pole.
        local c=run(bp.main,44,0,POWER,true)
        check(c.state=="planned","power-reach-ok:"..helpers.table_to_json(c))

        local miss=call("blueprint_job",{job_id="exec-nope",resume=true})
        check(not miss.ok and miss.error=="executor-job-not-found","resume-unknown-job")

        job=run(bp.chest,70,0,{site={mode="exact"},
          primer={{entity="wooden-chest",item="coal",count=1}}},false)
        check(job.ok and job.job_id,"job-started:"..helpers.table_to_json(job))
        phase="build"
        return
      end
      if game.tick-started>10000 then error("timeout in "..phase) end
      if phase=="build" then
        local b,s=busy(job.job_id)
        if b then return end
        check(s.state=="verified","job-verified:"..helpers.table_to_json(s))
        local box=surface.find_entity("wooden-chest",{70.5,0.5})
        check(box and box.get_inventory(defines.inventory.chest).get_item_count("coal")==1,
          "primer-ran")
        local no=call("blueprint_job",{job_id=job.job_id,resume=true})
        check(not no.ok and no.error=="job-not-resumable","resume-not-attention:"..helpers.table_to_json(no))
        -- Stand in for a post-build blocker (infra-missing, a primer with no room, a failed
        -- audit): the machines are on the ground and the job is parked.
        local j=state().executor_jobs[job.job_id]
        j.state,j.error="needs-attention","infra-missing:power:test"
        local r=call("blueprint_job",{job_id=job.job_id,resume=true})
        check(r.ok and r.state=="building" and not r.error,"resume-restarts:"..helpers.table_to_json(r))
        phase="resumed"
        return
      end
      if phase=="resumed" then
        local b,s=busy(job.job_id)
        if b then return end
        check(s.state=="verified","resumed-verified:"..helpers.table_to_json(s))
        check(#surface.find_entities_filtered{name="wooden-chest",area={{69,-1},{73,3}}}==1,
          "resume-no-double-build")
        local box=surface.find_entity("wooden-chest",{70.5,0.5})
        check(box.get_inventory(defines.inventory.chest).get_item_count("coal")==1,
          "resume-no-double-primer")
        check(state().executor_jobs[job.job_id].primed==1,"primer-progress-kept")
        result.ok,done=true,true
        return
      end
    end)
    if not ok then result.error,done=tostring(err),true end
    if done then helpers.write_file("power-check.json",helpers.table_to_json(result),false) end
  end)
end
