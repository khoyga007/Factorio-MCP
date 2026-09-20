-- Engine test: ghost-mode executor. A plan that does not fit and cannot be afforded yet
-- still lands as ghosts, waits on the ground, and finishes itself when stock arrives.
return function(handlers,state,bp)
  local result={ok=false,checks={}}
  local function check(v,name) assert(v,name) result.checks[#result.checks+1]=name end
  local function call(action,body) return handlers[action]("ghostbuild-"..game.tick..":"..#result.checks,body) end
  local surface,stock,job,phase,mark,done,blocker=nil,nil,nil,0,0,false,nil
  local CONTRACT={site={mode="exact",rotations={0}},build={mode="ghost"}}
  script.on_event(defines.events.on_tick,function()
    if done then return end
    local ok,err=pcall(function()
      if phase==0 then
        phase=1
        local player=game.get_player(1) stock=player.get_main_inventory()
        surface=game.create_surface("ghostbuild-test",{autoplace_settings={entity={treat_missing_as_default=false,settings={}},decorative={treat_missing_as_default=false,settings={}}}})
        surface.request_to_generate_chunks({0,0},2) surface.force_generate_chunk_requests()
        for _,e in pairs(surface.find_entities()) do e.destroy() end
        local tiles={} for x=-40,40 do for y=-40,40 do tiles[#tiles+1]={name="grass-1",position={x,y}} end end
        surface.set_tiles(tiles)
        player.teleport({30.5,30.5},surface)
        state().treasury_entity=nil state().treasury_unit_number=nil state().autofuel_enabled=false
        stock.clear()
        for _,name in ipairs{"iron-gear-wheel","wooden-chest","small-electric-pole","assembling-machine-1"} do
          game.forces.player.recipes[name].enabled=true
        end

        -- A blueprint bigger than the old hand-cut limit is now one paste.
        local big=call("blueprint_run",{blueprint=bp.wide,surface=surface.name,x=0,y=20,
          contract=CONTRACT,dry_run=true})
        check(big.ok and big.state=="planned" and #big.placed_at==70,
          "over-64-entities-accepted:"..tostring(big.state)..":"..tostring(big.error))

        -- One planned tile is taken by something else, and the bag holds ONE chest of the
        -- two the plan wants. Both used to refuse the whole build.
        blocker=surface.create_entity{name="stone-furnace",position={4.5,1.5},force="player"}
        stock.insert{name="wooden-chest",count=1}
        local probe=call("blueprint_import",{blueprint=bp.plan,surface=surface.name,x=10,y=10,mode="ghosts"})
        check(probe.ok and probe.ghosts==4,"handler-ghost-paste:"..helpers.table_to_json(probe))
        for _,g in pairs(surface.find_entities_filtered{name="entity-ghost"}) do g.destroy() end
        job=call("blueprint_run",{blueprint=bp.plan,surface=surface.name,x=0,y=0,contract=CONTRACT})
        check(job.ok and job.job_id,"ghost-run-started:"..helpers.table_to_json(job))
        mark=game.tick
      elseif phase==1 and game.tick-mark>=120 then
        phase=2
        local s=call("blueprint_job",{job_id=job.job_id})
        check(s.state=="building","waiting-job-stays-building:"..helpers.table_to_json(s))
        check(s.placed==1,"one-affordable-entity-built:"..tostring(s.placed))
        check(s.pending and s.pending>0,"rest-pending:"..tostring(s.pending))
        check(s.waiting and s.waiting["wooden-chest"],"names-what-it-waits-for:"..helpers.table_to_json(s.waiting))
        check(surface.find_entity("entity-ghost",{1.5,0.5})~=nil,"unaffordable-entity-is-a-ghost")
        -- Stock arrives: nobody re-runs the job, it just finishes.
        stock.insert{name="wooden-chest",count=1}
        stock.insert{name="small-electric-pole",count=1}
        stock.insert{name="assembling-machine-1",count=1}
        mark=game.tick
      elseif phase==2 and game.tick-mark>=120 then
        phase=3
        local s=call("blueprint_job",{job_id=job.job_id})
        check(surface.find_entity("wooden-chest",{1.5,0.5})~=nil,"built-itself-when-stock-arrived")
        check(surface.find_entity("small-electric-pole",{2.5,0.5})~=nil,"pole-built")
        -- The blocked tile is not silently forgotten: it is named, with coordinates.
        check(s.state=="needs-attention" and s.error=="blueprint-blocked:1",
          "blocked-tile-named:"..tostring(s.error))
        check(s.blocked and s.blocked[1] and s.blocked[1].name=="assembling-machine-1"
          and s.blocked[1].x==4.5,"blocked-entry-carries-coords:"..helpers.table_to_json(s.blocked))
        check(stock.get_item_count("assembling-machine-1")==1,"blocked-entity-was-not-charged")
        blocker.destroy()
        local r=call("blueprint_job",{job_id=job.job_id,resume=true})
        check(r.ok,"resume-accepted:"..tostring(r.error))
        mark=game.tick
      elseif phase==3 and game.tick-mark>=120 then
        local s=call("blueprint_job",{job_id=job.job_id})
        local built=surface.find_entity("assembling-machine-1",{4.5,1.5})
        check(built~=nil,"freed-tile-built-on-resume")
        check(built and built.get_recipe() and built.get_recipe().name=="iron-gear-wheel",
          "recipe-survived-the-wait")
        check(s.state=="verified" and not s.blocked,"job-finishes:"..tostring(s.state))
        check(stock.get_item_count("assembling-machine-1")==0,"charged-exactly-once")
        result.ok=true done=true
      end
    end)
    if not ok then result.error,done=tostring(err),true end
    if done then helpers.write_file("ghostbuild-check.json",helpers.table_to_json(result),false) end
  end)
end
