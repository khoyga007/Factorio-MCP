-- Engine test: executor mines trees/rocks off build tiles into the bag; a cliff refuses the
-- site only while the base cannot pay to blast it.
return function(handlers,state,bp)
  local result={ok=false,checks={}}
  local function check(v,name) assert(v,name) result.checks[#result.checks+1]=name end
  local function call(action,body) return handlers[action]("clear-"..game.tick..":"..#result.checks,body) end
  local surface,job,started,done,bag
  script.on_event(defines.events.on_tick,function()
    if done then return end
    local ok,err=pcall(function()
      if not started then
        started=game.tick
        local player=game.get_player(1) bag=player.get_main_inventory()
        surface=game.create_surface("clear-test",{autoplace_settings={entity={treat_missing_as_default=false,settings={}},decorative={treat_missing_as_default=false,settings={}}}})
        surface.request_to_generate_chunks({0,0},2) surface.force_generate_chunk_requests()
        for _,e in pairs(surface.find_entities()) do e.destroy() end
        local tiles={} for x=-40,40 do for y=-40,40 do tiles[#tiles+1]={name="grass-1",position={x,y}} end end surface.set_tiles(tiles)
        player.teleport({30,30},surface)
        state().treasury_entity=nil state().treasury_unit_number=nil state().autofuel_enabled=false
        bag.clear()
        bag.insert{name="wooden-chest",count=2} bag.insert{name="stone-furnace",count=2}
        -- Forest over the whole site plus a margin; a rock under the furnace.
        for x=-3,8 do for y=-3,6 do surface.create_entity{name="tree-01",position={x+0.5,y+0.5}} end end
        surface.create_entity{name="big-rock",position={3,1}}
        local contract={site={mode="exact"}}
        local dry=call("blueprint_run",{blueprint=bp,surface=surface.name,x=0,y=0,contract=contract,dry_run=true})
        check(dry.ok and dry.state=="planned" and (dry.site.clear or 0)>0,"dry-run-counts-clearable:"..helpers.table_to_json(dry))
        job=call("blueprint_run",{blueprint=bp,pattern_id="t-clear",surface=surface.name,x=0,y=0,contract=contract})
        check(job.ok and job.job_id,"clear-job:"..helpers.table_to_json(job))
        return
      end
      local status=call("blueprint_job",{job_id=job.job_id})
      if status.state=="preparing" or status.state=="building" then
        if game.tick-started>3000 then error("timeout:"..helpers.table_to_json(status)) end
        return
      end
      check(status.state=="verified" and (status.cleared or 0)>0,"built-through-forest:"..helpers.table_to_json(status))
      local built=surface.find_entities_filtered{force="player",name={"wooden-chest","stone-furnace"}}
      check(#built==2,"both-built")
      for _,e in ipairs(built) do
        check(surface.count_entities_filtered{area=e.bounding_box,type={"tree","simple-entity"}}==0,"footprint-clear:"..e.name)
      end
      check(surface.count_entities_filtered{position={7.5,5.5},radius=0.2,type="tree"}==1,"outside-footprint-kept")
      check(bag.get_item_count("wood")>0 and bag.get_item_count("stone")>0,"products-in-bag")
      -- Cliff under the site: refused while the base cannot pay for explosives, quoted as
      -- part of the bill once it can. The blast itself is covered by the ghostbuild test.
      local cliff=surface.create_entity{name="cliff",position={20,20},cliff_orientation="west-to-east"}
      check(cliff and cliff.valid,"cliff-created")
      local box=cliff.bounding_box
      local function sweep()
        local hit,quoted
        for x=math.floor(box.left_top.x)-1,math.ceil(box.right_bottom.x) do
          for y=math.floor(box.left_top.y)-1,math.ceil(box.right_bottom.y) do
            local r=call("blueprint_run",{blueprint=bp,surface=surface.name,x=x,y=y,contract={site={mode="exact"}},dry_run=true})
            if r.state=="blocked" and r.rejects and r.rejects.cliff then hit=r end
            if r.site and r.site.blast then quoted=r end
          end
        end
        return hit,quoted
      end
      local had=bag.get_item_count("cliff-explosives")
      if had>0 then bag.remove{name="cliff-explosives",count=had} end
      game.forces.player.recipes["cliff-explosives"].enabled=false
      local refused=sweep()
      check(refused,"cliff-refused-with-no-explosives")
      check(cliff.valid,"cliff-not-cleared-by-a-dry-run")
      bag.insert{name="cliff-explosives",count=4}
      local _,quoted=sweep()
      check(quoted and quoted.materials and quoted.materials["cliff-explosives"],
        "cliff-is-on-the-bill-once-affordable:"..helpers.table_to_json(quoted and quoted.materials or {}))
      check(cliff.valid,"cliff-still-standing-after-dry-runs")
      result.ok,done=true,true
    end)
    if not ok then result.error,done=tostring(err),true end
    if done then helpers.write_file("clear-check.json",helpers.table_to_json(result),false) end
  end)
end
