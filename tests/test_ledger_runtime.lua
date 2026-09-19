-- Engine test: base ledger (job blocks, hand blocks, edges, notes, live attention) + character reject.
return function(handlers,state,bp)
  local result={ok=false,checks={}}
  local function check(v,name) assert(v,name) result.checks[#result.checks+1]=name end
  local function call(action,body) return handlers[action]("ledger-"..game.tick..":"..#result.checks,body) end
  local function find(led,id) for _,b in ipairs(led.blocks) do if b.id==id then return b end end end
  local surface,a,b,phase,started,done,player
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
      if game.tick-started>6000 then error("timeout in "..phase) end
      if phase=="a" then
        if busy(a.job_id) then return end
        b=run(10,{name="consumer-b",eats={{item="iron-plate",block=a.job_id,via="inserter"}}})
        check(b.ok and b.job_id,"job-b:"..helpers.table_to_json(b))
        phase="b"
        return
      end
      if busy(b.job_id) then return end
      local led=call("ledger",{})
      local la,lb=find(led,a.job_id),find(led,b.job_id)
      check(la and la.name=="smelter-a" and la.role=="iron plates","a-intent:"..helpers.table_to_json(la))
      check(la.status=="verified" or la.status=="unverified","a-status:"..tostring(la.status))
      check(la.n["wooden-chest"]==1 and la.n["stone-furnace"]==1 and la.box,"a-live-counts")
      local edge
      for _,e in ipairs(led.edges) do if e[1]==a.job_id and e[2]==b.job_id and e[3]=="iron-plate" then edge=true end end
      check(lb and edge,"edge-a-to-b:"..helpers.table_to_json(led.edges))
      local n=call("ledger_note",{block={id=a.job_id,notes="feeds consumer-b"}})
      check(n.ok,"note-job:"..helpers.table_to_json(n))
      check(find(call("ledger",{}),a.job_id).notes=="feeds consumer-b","note-persisted")
      check(find(call("ledger",{}),a.job_id).role=="iron plates","note-keeps-other-intent")
      local miss=call("ledger_note",{block={id="exec-nope",notes="x"}})
      check(not miss.ok and miss.error=="block-not-found","unknown-id-rejected")
      local noarea=call("ledger_note",{block={name="loose"}})
      check(not noarea.ok and noarea.error=="block-id-or-area-required","area-required")
      surface.create_entity{name="wooden-chest",position={20.5,0.5},force="player"}
      local h=call("ledger_note",{block={name="hand-chest",feeds={{block=b.job_id,item="coal"}}},surface=surface.name,force="player",x1=19,y1=-1,x2=22,y2=2})
      check(h.ok and h.id and h.id:sub(1,5)=="hand-","hand-registered:"..helpers.table_to_json(h))
      led=call("ledger",{})
      local lh=find(led,h.id)
      check(lh.status=="declared" and lh.n["wooden-chest"]==1,"hand-live:"..helpers.table_to_json(lh))
      edge=nil
      for _,e in ipairs(led.edges) do if e[1]==h.id and e[2]==b.job_id then edge=true end end
      check(edge,"hand-edge")
      -- Destroying part of block a turns it to attention with a missing count.
      local chest=surface.find_entities_filtered{name="wooden-chest",area={{-1,-1},{2,2}}}[1]
      chest.destroy()
      la=find(call("ledger",{}),a.job_id)
      check(la.status=="attention" and la.missing==1,"a-attention:"..helpers.table_to_json(la))
      local rep=call("blueprint_job",{job_id=b.job_id})
      check(rep.block and rep.block.name=="consumer-b","report-carries-block")
      result.ok,done=true,true
    end)
    if not ok then result.error,done=tostring(err),true end
    if done then helpers.write_file("ledger-check.json",helpers.table_to_json(result),false) end
  end)
end
