-- Engine test: base ledger (job blocks, hand blocks, edges, notes, live attention) + character reject.
return function(handlers,state,bp)
  local result={ok=false,checks={}}
  local function check(v,name) assert(v,name) result.checks[#result.checks+1]=name end
  local function call(action,body) return handlers[action]("ledger-"..game.tick..":"..#result.checks,body) end
  local function find(led,id) for _,b in ipairs(led.blocks) do if b.id==id then return b end end end
  local surface,a,b,phase,started,done,player,flow_started,hand,pair
  local function run(x,block) return call("blueprint_run",{blueprint=bp,surface=surface.name,x=x,y=0,
    contract={site={mode="exact"},block=block}}) end
  local function busy(job)
    local s=call("blueprint_job",{job_id=job})
    return s.state=="preparing" or s.state=="building",s
  end
  script.on_event(defines.events.on_tick,function()
    if done then return end
    local ok,err=pcall(function()
      if not started then
        started=game.tick
        player=game.get_player(1)
        local bag=player.get_main_inventory()
        surface=game.create_surface("ledger-test",{autoplace_settings={entity={treat_missing_as_default=false,settings={}},decorative={treat_missing_as_default=false,settings={}}}})
        surface.request_to_generate_chunks({0,0},2) surface.force_generate_chunk_requests()
        for _,e in pairs(surface.find_entities()) do e.destroy() end
        local tiles={} for x=-40,40 do for y=-40,40 do tiles[#tiles+1]={name="grass-1",position={x,y}} end end surface.set_tiles(tiles)
        player.teleport({30.5,30.5},surface)
        -- Benchmark saves carry no character; stand one in the site (as maintainer's would be).
        surface.create_entity{name="character",position={30.5,30.5},force="player"}
        state().treasury_entity=nil state().treasury_unit_number=nil state().autofuel_enabled=false
        bag.clear()
        bag.insert{name="wooden-chest",count=4} bag.insert{name="stone-furnace",count=2}
        local bad=run(0,{name="x",feeds={{}}})
        check(not bad.ok and bad.error=="invalid-block-feeds","bad-block-rejected:"..helpers.table_to_json(bad))
        local badrate=run(0,{name="x",feeds={{item="iron-plate",per_minute=-3}}})
        check(not badrate.ok and badrate.error=="invalid-block-feeds","bad-rate-rejected:"..helpers.table_to_json(badrate))
        -- Own character standing in the site is named, not reported as a generic collision.
        local named
        for x=27,33 do for y=27,33 do
          local r=call("blueprint_run",{blueprint=bp,surface=surface.name,x=x,y=y,contract={site={mode="exact"}},dry_run=true})
          if r.state=="blocked" and r.rejects and r.rejects.character then named=true end
        end end
        check(named,"character-named")
        a=run(0,{name="smelter-a",role="iron plates"})
        check(a.ok and a.job_id,"job-a:"..helpers.table_to_json(a))
        phase="a"
        return
      end
      if game.tick-started>10000 then error("timeout in "..phase) end
      if phase=="a" then
        if busy(a.job_id) then return end
        b=run(10,{name="consumer-b",eats={{item="iron-plate",block=a.job_id,via="inserter",per_minute=30}}})
        check(b.ok and b.job_id,"job-b:"..helpers.table_to_json(b))
        phase="b"
        return
      end
      if phase=="flow" then
        local led1=call("ledger",{detail="rows"})
        local la2=find(led1,a.job_id)
        local f=la2 and la2.flow
        local got=(f and f.made and f.made["iron-plate"]) or 0
        if got<=0 and game.tick-flow_started<3000 then return end
        -- window length is a reply-level number now, not a per-block one
        check(led1.flow_ticks>=300 and f and f.samples>0,"flow-window:"..helpers.table_to_json(f))
        check((f.made["iron-plate"] or 0)>0,"flow-measured-plates:"..helpers.table_to_json(f.made))
        check((f.active["stone-furnace"] or 0)>0,"flow-active-furnace:"..helpers.table_to_json(f.active))
        local edge2
        for _,e in ipairs(call("ledger",{detail="rows"}).edges) do
          if e.from==a.job_id and e.to==b.job_id then edge2=e end
        end
        check(edge2 and edge2.declared==30 and (edge2.measured or 0)>0,
          "edge-measured:"..helpers.table_to_json(edge2))
        check((f.counted or 0)>0,"flow-counted:"..helpers.table_to_json(f))
        phase="hands"
        return
      end
      if phase=="hands" then
        -- Hand blocks start their first window later than the job blocks, so wait for it.
        local led2=call("ledger",{detail="rows"})
        local lh,lp=find(led2,hand),find(led2,pair)
        if not (lh and lh.flow and lp and lp.flow) then return end
        -- A chest-only block cannot measure anything: products_finished exists on no
        -- entity in it. `measured 0` there reads as a producer that made nothing.
        local he
        for _,e in ipairs(led2.edges) do if e.from==hand then he=e end end
        check(he and he.uncounted and he.measured==nil,"chest-block-uncounted:"..helpers.table_to_json(he))
        check(lh.flow.counted==0,"chest-block-counted-zero:"..helpers.table_to_json(lh.flow))
        local pa=lp.flow.active and lp.flow.active["stone-furnace"]
        check(pa and pa>0 and pa<=100,"active-mean-per-machine:"..helpers.table_to_json(lp.flow))
        -- Block a wiped off the ground (as `recall` does). It must leave the ledger, and
        -- b's declared link to it must read as a missing block, not as a starved producer.
        for _,e in pairs(surface.find_entities_filtered{area={{-2,-2},{9,9}}}) do
          if e.type~="character" then e.destroy() end
        end
        phase="gone"
        return
      end
      if phase=="gone" then
        local led3=call("ledger",{detail="rows"})
        check(not find(led3,a.job_id),"dead-block-dropped")
        local e3
        for _,e in ipairs(led3.edges) do if e.from==a.job_id then e3=e end end
        check(e3 and e3.missing_block,"dead-edge-flagged:"..helpers.table_to_json(e3))
        check(find(led3,b.job_id),"live-block-kept")
        -- Macro zoom. The roll must account for every live block without carrying one row:
        -- cluster membership is a partition, so the per-cluster counts have to add back up.
        local roll=call("ledger",{})
        check(roll.detail=="roll" and roll.blocks==#led3.blocks and not roll.blocks_rows,
          "roll-counts:"..tostring(roll.blocks).."/"..tostring(#led3.blocks))
        local sum,named=0,true
        for _,c in ipairs(roll.clusters) do
          sum=sum+c.blocks
          if not (c.id and c.box and c.machines) then named=false end
        end
        check(sum==roll.blocks and named,"clusters-partition:"..helpers.table_to_json(roll.clusters))
        local tally=0
        for _,c in pairs(roll.by_status) do tally=tally+c end
        check(tally==roll.blocks,"status-tally:"..helpers.table_to_json(roll.by_status or {}))
        check(roll.edges.total>0,"roll-edge-total:"..helpers.table_to_json(roll.edges))
        -- Drill-down: one filter, one block, and the links that touch it.
        local one=call("ledger",{detail="one",only={id=b.job_id}})
        check(one.block and one.block.id==b.job_id and one.edges,"one-block:"..helpers.table_to_json(one.block))
        local miss1=call("ledger",{detail="one",only={id="exec-nope"}})
        check(not miss1.ok and miss1.error=="block-not-found","one-unknown-rejected")
        local filtered=call("ledger",{detail="rows",only={cluster=roll.clusters[1].id}})
        check(filtered.total>0 and filtered.total<=roll.blocks,
          "cluster-filter:"..tostring(filtered.total))
        result.ok,done=true,true
        return
      end
      if busy(b.job_id) then return end
      local led=call("ledger",{detail="rows"})
      local la,lb=find(led,a.job_id),find(led,b.job_id)
      check(la and la.name=="smelter-a" and la.role=="iron plates","a-intent:"..helpers.table_to_json(la))
      check(la.status=="verified" or la.status=="unverified","a-status:"..tostring(la.status))
      check(la.n["wooden-chest"]==1 and la.n["stone-furnace"]==1 and la.box,"a-live-counts")
      local edge
      for _,e in ipairs(led.edges) do
        if e.from==a.job_id and e.to==b.job_id and e.item=="iron-plate" then edge=e end
      end
      check(lb and edge,"edge-a-to-b:"..helpers.table_to_json(led.edges))
      check(edge.declared==30,"edge-declared:"..helpers.table_to_json(edge))
      local n=call("ledger_note",{block={id=a.job_id,notes="feeds consumer-b"}})
      check(n.ok,"note-job:"..helpers.table_to_json(n))
      check(find(call("ledger",{detail="rows"}),a.job_id).notes=="feeds consumer-b","note-persisted")
      check(find(call("ledger",{detail="rows"}),a.job_id).role=="iron plates","note-keeps-other-intent")
      local miss=call("ledger_note",{block={id="exec-nope",notes="x"}})
      check(not miss.ok and miss.error=="block-not-found","unknown-id-rejected")
      local noarea=call("ledger_note",{block={name="loose"}})
      check(not noarea.ok and noarea.error=="block-id-or-area-required","area-required")
      surface.create_entity{name="wooden-chest",position={20.5,0.5},force="player"}
      local h=call("ledger_note",{block={name="hand-chest",feeds={{block=b.job_id,item="coal"}}},surface=surface.name,force="player",x1=19,y1=-1,x2=22,y2=2})
      check(h.ok and h.id and h.id:sub(1,5)=="hand-","hand-registered:"..helpers.table_to_json(h))
      hand=h.id
      -- A second hand block of TWO working furnaces: `active` must read as a mean per
      -- machine, not a sum. The old code added 1 per working entity per sample and
      -- divided by samples alone, so two furnaces read back as 200.
      for _,x in ipairs{24.5,26.5} do
        local fz=surface.create_entity{name="stone-furnace",position={x,0.5},force="player"}
        fz.insert{name="coal",count=5} fz.insert{name="iron-ore",count=25}
      end
      local hp=call("ledger_note",{block={name="hand-furnaces"},surface=surface.name,force="player",x1=23,y1=-1,x2=28,y2=2})
      check(hp.ok and hp.id,"hand-pair-registered:"..helpers.table_to_json(hp))
      pair=hp.id
      led=call("ledger",{detail="rows"})
      local lh=find(led,h.id)
      check(lh.status=="declared" and lh.n["wooden-chest"]==1,"hand-live:"..helpers.table_to_json(lh))
      edge=nil
      for _,e in ipairs(led.edges) do if e.from==h.id and e.to==b.job_id then edge=true end end
      check(edge,"hand-edge")
      -- Destroying part of block a turns it to attention with a missing count.
      local chest=surface.find_entities_filtered{name="wooden-chest",area={{-1,-1},{2,2}}}[1]
      chest.destroy()
      la=find(call("ledger",{detail="rows"}),a.job_id)
      check(la.status=="attention" and la.missing==1,"a-attention:"..helpers.table_to_json(la))
      local rep=call("blueprint_job",{job_id=b.job_id})
      check(rep.block and rep.block.name=="consumer-b","report-carries-block")
      -- Throughput: give block a's furnace real ore and fuel, then read what the
      -- closed window measured. Short window so one benchmark run covers it.
      state().ledger_flow_window=300
      local furnace=surface.find_entities_filtered{name="stone-furnace",area={{-2,-2},{9,9}}}[1]
      check(furnace and furnace.valid,"furnace-found")
      furnace.insert{name="coal",count=5}
      furnace.insert{name="iron-ore",count=25}
      flow_started,phase=game.tick,"flow"
      return
    end)
    if not ok then result.error,done=tostring(err),true end
    if done then helpers.write_file("ledger-check.json",helpers.table_to_json(result),false) end
  end)
end
