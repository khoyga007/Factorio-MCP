-- Engine test: underground pipe pairing is checked BEFORE the build.
-- Also pins the measured facts the validator is built on (polarity + range), so a
-- prototype change in a future Factorio version fails here instead of silently in play.
return function(handlers,state,bp)
  local result={ok=false,checks={}}
  local function check(v,name) assert(v,name) result.checks[#result.checks+1]=name end
  local function call(action,body) return handlers[action]("pipe-"..game.tick..":"..#result.checks,body) end
  local surface,done,started
  script.on_event(defines.events.on_tick,function()
    if done then return end
    local ok,err=pcall(function()
      if started then return end
      started,done=true,true
      local player=game.get_player(1) local bag=player.get_main_inventory()
      surface=game.create_surface("pipe-test",{autoplace_settings={entity={treat_missing_as_default=false,settings={}},decorative={treat_missing_as_default=false,settings={}}}})
      surface.request_to_generate_chunks({0,0},2) surface.force_generate_chunk_requests()
      for _,e in pairs(surface.find_entities()) do e.destroy() end
      local tiles={} for x=-40,40 do for y=-40,40 do tiles[#tiles+1]={name="grass-1",position={x,y}} end end
      surface.set_tiles(tiles)
      player.teleport({30.5,30.5},surface)
      state().treasury_entity=nil state().treasury_unit_number=nil state().autofuel_enabled=false
      bag.clear() bag.insert{name="pipe-to-ground",count=10}

      -- The measured ground truth the validator encodes.
      local proto=prototypes.entity["pipe-to-ground"]
      local rel,maxd
      for _,fb in pairs(proto.fluidbox_prototypes or {}) do
        for _,c in pairs(fb.pipe_connections or {}) do
          if c.connection_type=="underground" then rel=c.direction maxd=c.max_underground_distance end
        end
      end
      check(rel==8 and maxd==10,"prototype-underground:"..tostring(rel)..","..tostring(maxd))
      local a=surface.create_entity{name="pipe-to-ground",position={-20.5,-20.5},direction=12,force="player"}
      local b=surface.create_entity{name="pipe-to-ground",position={-10.5,-20.5},direction=4,force="player"}
      local linked=false
      for _,n in pairs(a.neighbours or {}) do for _,x in pairs(n) do if x==b then linked=true end end end
      check(linked,"engine-links-at-10")
      b.destroy()
      local far=surface.create_entity{name="pipe-to-ground",position={-9.5,-20.5},direction=4,force="player"}
      linked=false
      for _,n in pairs(a.neighbours or {}) do for _,x in pairs(n) do if x==far then linked=true end end end
      check(not linked,"engine-breaks-at-11")
      a.destroy() far.destroy()

      local function run(blueprint,x,y)
        return call("blueprint_run",{blueprint=blueprint,surface=surface.name,x=x,y=y,
          contract={site={mode="exact"}},dry_run=true})
      end
      local good=run(bp.good,0,0)
      check(good.state=="planned","paired-run-planned:"..helpers.table_to_json(good))
      local far2=run(bp.far,0,20)
      check(far2.state=="blocked" and far2.error=="pipe-unconnected"
        and far2.unconnected[1].reason=="no-partner","too-long-refused:"..helpers.table_to_json(far2))
      check(#far2.unconnected==2,"both-ends-reported:"..helpers.table_to_json(far2.unconnected))
      local flip=run(bp.flip,0,30)
      check(flip.state=="blocked" and flip.error=="pipe-unconnected"
        and flip.unconnected[1].reason=="wrong-facing","wrong-facing-refused:"..helpers.table_to_json(flip))
      result.ok=true
    end)
    if not ok then result.error,done=tostring(err),true end
    if done then helpers.write_file("pipe-check.json",helpers.table_to_json(result),false) end
  end)
end
