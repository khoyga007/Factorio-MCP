-- Generic blueprint executor. The agent declares a contract (site, resource,
-- primer, feed, verify); this module only checks, gathers, builds and audits.
-- Site search and holdout rules: reference/PORTING.md sections 1 and 5.
local M = {}
local site = require("site")
local MIN_WINDOWS, NATURAL, affordable, apply_settings = site.MIN_WINDOWS, site.NATURAL, site.affordable, site.apply_settings
local check_site, decode, fed_poles, find_site = site.check_site, site.decode, site.fed_poles, site.find_site
local finite, in_footprint, inserter_gaps, lane_joins = site.finite, site.in_footprint, site.inserter_gaps, site.lane_joins
local layout_digest, orient, pipe_gaps, place_list = site.layout_digest, site.orient, site.pipe_gaps, site.place_list
local placed_at, pole_covers, sorted_keys, tile_keys = site.placed_at, site.pole_covers, site.sorted_keys, site.tile_keys
local water_keys = site.water_keys
local contract = require("contract")
local parse_block, parse_contract = contract.parse_block, contract.parse_contract

function M.attach(ctx)
  local function jobs()
    local s=ctx.state() s.executor_jobs=s.executor_jobs or {} return s.executor_jobs
  end
  local function summary(j,detail)
    return {job_id=j.id,state=j.state,pattern_id=j.pattern_id,site=j.site,
      step=math.min(j.step,#(j.steps or {})),steps=#(j.steps or {}),placed=j.placed,materials=j.materials,
      missing=j.missing,audit=j.audit,feed=j.feed,error=j.error,artifact=j.artifact,cleared=j.cleared,block=j.block,
      pending=j.pending,waiting=j.waiting,blocked=j.blocked,standing=j.standing,
      -- placed = tiles that hold the right entity now; built = the ones THIS job revived
      -- and paid for; existing = the ones that were already standing.
      built=j.built,existing=j.existing,replaced=j.replaced,replaced_at=j.replaced_at,
      skipped=j.skipped,skipped_locked=j.skipped_locked,bots=j.bots,uncovered=j.uncovered,unpowered=j.unpowered,lane_joins=j.lane_joins,restocked=j.restocked,drift=j.drift,
      blasted=(j.blasted or 0)>0 and j.blasted or nil,filled=(j.filled or 0)>0 and j.filled or nil,
      ground=j.ground,
      plan=layout_digest(j.layout),
      placed_at=detail and j.layout and placed_at(j.layout) or nil}
  end
  local function save(j)
    helpers.write_file(j.artifact..".receipt.json",helpers.table_to_json{
      -- The receipt on disk is the archive: it keeps every row, whatever the reply trimmed.
      job=summary(j,true),contract=j.contract_raw,receipts=j.receipts},false)
  end
  local function perform(j,action,body)
    body.surface,body.force=j.surface,j.force
    local ok,r=pcall(ctx[action],j.id..":"..(#j.receipts+1),body)
    if not ok then r={ok=false,error="step-runtime-error",detail=tostring(r)} end
    j.receipts[#j.receipts+1]=r
    if not r.ok then j.state,j.error="needs-attention",r.error end
    return r
  end

  -- Plan real-item steps: stock -> nearby chests/machine output -> trees/rocks -> hand craft.
  local function prepare(surface,force,center,radius,stock,cost,supply)
    local available,steps,missing={}, {}, {}
    for _,s in pairs(stock.get_contents()) do
      if s.quality=="normal" then available[s.name]=(available[s.name] or 0)+s.count end
    end
    local sources
    if supply and #supply>0 then
      -- Declared supply chests only: the job reads what it was given, not the whole base.
      sources={}
      for _,p in ipairs(supply) do
        for _,e in ipairs(surface.find_entities_filtered{position={p.x,p.y},radius=1.5,
          force=force,type={"container","logistic-container"}}) do sources[#sources+1]=e end
      end
    else
      sources=surface.find_entities_filtered{position=center,radius=radius,force=force,
        type={"container","logistic-container","furnace","assembling-machine"}}
    end
    table.sort(sources,function(a,b) return (a.unit_number or 0)<(b.unit_number or 0) end)
    local reserved={}
    local function ensure(item,count,depth)
      local have=available[item] or 0
      if have>=count then return true end
      for _,e in ipairs(sources) do
        local inv=(e.type=="container" or e.type=="logistic-container")
          and e.get_inventory(defines.inventory.chest) or e.get_output_inventory()
        local key=(e.unit_number or 0)..":"..item
        local n=inv and math.min(count-have,inv.get_item_count{name=item,quality="normal"}-(reserved[key] or 0)) or 0
        if n>0 then
          steps[#steps+1]={action="collect",body={item=item,count=n,x=e.position.x,y=e.position.y}}
          reserved[key]=(reserved[key] or 0)+n have=have+n available[item]=have
        end
        if have>=count then return true end
      end
      if item=="wood" or item=="stone" then
        for _,e in pairs(surface.find_entities_filtered{position=center,radius=radius,
          type=item=="wood" and "tree" or "simple-entity"}) do
          local key="natural:"..e.position.x..":"..e.position.y
          if not reserved[key] then
            local mp=e.prototype.mineable_properties
            for _,p in pairs(mp and mp.products or {}) do
              if p.name==item and (p.probability or 1)==1 then
                local n=p.amount or p.amount_min or 0
                if n>0 then
                  steps[#steps+1]={action="mine",body={name=e.name,x=e.position.x,y=e.position.y}}
                  reserved[key]=true have=have+n available[item]=have break
                end
              end
            end
          end
          if have>=count then return true end
        end
      end
      local recipe=force.recipes[item]
      local hand=prototypes.entity["character"]
      local categories=hand and hand.crafting_categories or {crafting=true}
      if depth>6 or not recipe or not recipe.enabled or not categories[recipe.category] then
        missing[item]=count-have return false
      end
      local yield=0
      for _,p in pairs(recipe.products) do
        if p.name==item and p.amount and (p.probability or 1)==1 then yield=p.amount end
      end
      if yield<=0 then missing[item]=count-have return false end
      local crafts=math.ceil((count-have)/yield)
      for _,ingredient in ipairs(recipe.ingredients) do
        if ingredient.type~="item" or not ensure(ingredient.name,ingredient.amount*crafts,depth+1) then return false end
        available[ingredient.name]=available[ingredient.name]-ingredient.amount*crafts
      end
      steps[#steps+1]={action="craft",body={recipe=item,count=crafts}}
      available[item]=have+crafts*yield
      return true
    end
    for _,item in ipairs(sorted_keys(cost)) do
      -- One item the base cannot make yet used to end the planning loop, so everything
      -- sorted after it got no collect step at all. Plan each item on its own; `missing`
      -- names whichever ones came up short.
      ensure(item,cost[item],0)
      -- Claim it: a later craft must not eat what this item already counted (23/09 the
      -- steam-engine craft took the design's own pipes -> materials-changed:pipe).
      available[item]=math.max(0,(available[item] or 0)-cost[item])
    end
    return steps,missing
  end

  -- The paste landed where it was planned, or it did not. Two refinements over a bare
  -- index (20/09, exec-10 came back `import-geometry-mismatch:1` and the index alone said
  -- nothing about what was wrong):
  --  * the reason carries the numbers -- name, tile, planned dir, what stands there;
  --  * an entity whose prototype does not support direction (electric poles) is compared
  --    on presence only. The engine drops the direction such a prototype cannot hold, so
  --    a rotated layout plans dir 4 and the ground honestly reports 0. Position, name and
  --    every directional entity stay strict: this is the guard against a bad paste.
  local function built_entities(j)
    local surface=game.get_surface(j.surface)
    local out={}
    for i,e in ipairs(j.layout) do
      local found=surface.find_entity(e.name,{e.x,e.y})
      if not found or not found.valid then
        return nil,i,string.format("%s@%s,%s missing",e.name,e.x,e.y)
      end
      local directional=found.prototype.supports_direction
      if directional and found.direction~=e.dir then
        return nil,i,string.format("%s@%s,%s dir %s built %s",e.name,e.x,e.y,e.dir,found.direction)
      end
      out[i]=found
    end
    return out
  end

  -- power: entity sits on an electric network. fluid: a box for that fluid links to an entity outside the job.
  local function connected(es,e,rule)
    if rule.power then
      -- A network id alone can be an island of poles: require a live source on the same network.
      local id=e.electric_network_id
      if not id then return false end
      for _,g in pairs(e.surface.find_entities_filtered{force=e.force,
        type={"generator","burner-generator","solar-panel","electric-energy-interface","fusion-generator","accumulator"}}) do
        if g.electric_network_id==id and (g.type~="accumulator" or g.energy>0) then return true end
      end
      return false
    end
    local own={}
    for _,x in ipairs(es) do if x.unit_number then own[x.unit_number]=true end end
    for k=1,#e.fluidbox do
      local filter=e.fluidbox.get_filter(k)
      local proto=e.fluidbox.get_prototype(k)
      if proto and not proto.object_name and proto[1] then proto=proto[1] end
      local name=(filter and filter.name) or (proto and proto.filter and proto.filter.name)
      if name==rule.fluid then
        for _,other in pairs(e.fluidbox.get_connections(k)) do
          if other.owner and not own[other.owner.unit_number] then return true end
        end
      end
    end
    return false
  end

  local function sample(j,es)
    local w=j.window
    w.samples=w.samples+1
    for _,m in ipairs(j.metrics) do
      local acc=w.acc[m.key]
      if m.kind=="working_count" then
        for i,e in ipairs(es) do
          if e.name==m.entity then
            acc[i]=(acc[i] or 0)+(e.status==defines.entity_status.working and 1 or 0)
          end
        end
      elseif m.kind=="electric_output_mw" then
        for _,e in ipairs(es) do
          if e.name==m.entity then acc.sum=(acc.sum or 0)+e.energy_generated_last_tick*60/1000000 end
        end
      elseif m.kind=="fluid_temperature" then
        local best=0
        for _,e in ipairs(es) do
          if e.name==m.entity then
            for k=1,#e.fluidbox do
              local f=e.fluidbox[k]
              if f and f.name==(m.fluid or "steam") then best=math.max(best,f.temperature or 0) end
            end
          end
        end
        acc.min=math.min(acc.min or math.huge,best)
      elseif m.kind=="research_units" then
        -- Units these labs researched: working ticks x lab speed / unit energy. Force progress would
        -- also count labs outside the job.
        local tick=game.tick
        if acc.t then
          local dt=tick-acc.t
          for _,e in ipairs(es) do
            if e.name==m.entity and e.status==defines.entity_status.working then
              local cur=e.force.current_research
              local energy=cur and cur.research_unit_energy
              if energy and energy>0 then
                local speed=(e.prototype.get_researching_speed and e.prototype.get_researching_speed(e.quality)
                  or e.prototype.researching_speed or 1)*(1+e.force.laboratory_speed_modifier)
                local ok,fx=pcall(function() return e.effects end)
                if ok and fx and fx.speed then speed=speed*(1+fx.speed) end
                acc.sum=(acc.sum or 0)+dt*speed/energy
              end
            end
          end
        end
        acc.t=tick
      elseif m.kind=="fuel_min" then
        for _,e in ipairs(es) do
          if e.name==m.entity then
            local fuel=e.get_fuel_inventory()
            local n=(fuel and #fuel>0 and fuel.get_item_count() or 0)
              +((e.burner and e.burner.remaining_burning_fuel>0) and 1 or 0)
            acc.min=math.min(acc.min or math.huge,n)
          end
        end
      end
    end
  end

  local function container_count(es,m)
    local n=0
    for _,e in ipairs(es) do
      if e.name==m.entity then
        local inv=e.get_inventory(defines.inventory.chest)
        n=n+(inv and inv.get_item_count(m.item) or 0)
      end
    end
    return n
  end

  local function finished(es,m)
    local n=0
    for _,e in ipairs(es) do if e.name==m.entity then n=n+(e.products_finished or 0) end end
    return n
  end

  local function open_window(j,es)
    j.window={start=game.tick,samples=0,acc={},base={}}
    for _,m in ipairs(j.metrics) do
      j.window.acc[m.key]={}
      if m.kind=="container_gain" then j.window.base[m.key]=container_count(es,m) end
      if m.kind=="products_finished" then j.window.base[m.key]=finished(es,m) end
      if m.kind=="research_units" then j.window.acc[m.key].t=game.tick end
    end
  end

  local function close_window(j,es)
    local w,values,pass=j.window,{},true
    for _,m in ipairs(j.metrics) do
      local acc,v=w.acc[m.key],0
      if m.kind=="container_gain" then v=container_count(es,m)-w.base[m.key]
      elseif m.kind=="products_finished" then v=finished(es,m)-w.base[m.key]
      elseif m.kind=="research_units" then v=acc.sum or 0
      elseif m.kind=="working_count" then
        for _,n in pairs(acc) do if n>=(m.fraction or 0.8)*w.samples then v=v+1 end end
      elseif m.kind=="electric_output_mw" then v=(acc.sum or 0)/math.max(w.samples,1)
      else v=acc.min or 0 end
      values[m.key]=v
      if v<m.min then pass=false end
    end
    local rows=j.audit.windows
    rows[#rows+1]={index=#rows+1,start_tick=w.start,end_tick=game.tick,samples=w.samples,
      values=values,passed=pass,feed_moved=j.feed_window}
    j.feed_window=0
    local primary=j.metrics[1] and j.metrics[1].key
    local done=#rows>=j.max_windows or (#rows>=MIN_WINDOWS and primary
      and rows[#rows].values[primary]<=rows[#rows-1].values[primary])
    if done then
      j.audit.status=pass and "passed" or "failed"
      j.audit.last=rows[#rows]
      j.state=pass and "verified" or "needs-attention"
      if not pass then j.error="holdout-last-window-failed" end
      helpers.write_file(j.artifact..".audit.json",helpers.table_to_json(j.audit),false)
      helpers.write_file(j.artifact..".blueprint.txt",j.blueprint.."\n",false)
    else
      open_window(j,es)
    end
  end

  -- Declared local feeds only: move real items between this job's own entities.
  local function run_feeds(j,es)
    for _,f in ipairs(j.feeds) do
      local src
      for _,e in ipairs(es) do if e.name==f.from then src=e.get_inventory(defines.inventory.chest) break end end
      if src then
        for _,e in ipairs(es) do
          if e.name==f.to then
            local fuel=e.get_fuel_inventory()
            local have=fuel and fuel.get_item_count(f.item) or 0
            local want=math.min(f.keep-have,src.get_item_count(f.item))
            if fuel and want>0 then
              local n=src.remove{name=f.item,count=want}
              local put=fuel.insert{name=f.item,count=n}
              if put<n then src.insert{name=f.item,count=n-put} end
              j.feed[f.item]=(j.feed[f.item] or 0)+put
              j.feed_window=(j.feed_window or 0)+put
            end
          end
        end
      end
    end
  end

  -- How many jobs may be alive at once. Each parked job walks its own layout on its scan
  -- tick, so this bounds the per-tick cost and the size of the saved state.
  local MAX_LIVE_JOBS=8
  -- A job that built nothing last pass is waiting on materials, not on CPU: re-scan it
  -- once a second instead of every tick. This also stops 8 parked jobs from writing 8
  -- receipt files 60 times a second.
  local SCAN_TICKS=60

  function M.start(nonce,r)
    local base,err=decode(r.blueprint)
    if not base then return ctx.response(nonce,false,{error=err}) end
    local surface,force=game.get_surface(r.surface or "nauvis"),game.forces[r.force or "player"]
    local stock,owner,kind=ctx.inventory()
    if not surface or not force or not stock or kind~="player" or owner.force~=force or owner.surface~=surface then
      return ctx.response(nonce,false,{error="player-treasury-on-target-surface-required"})
    end
    r.x=r.x or owner.position.x r.y=r.y or owner.position.y
    if not finite(r.x) or not finite(r.y) or (r.radius and (not finite(r.radius) or r.radius<4 or r.radius>256)) then
      return ctx.response(nonce,false,{error="invalid-search"})
    end
    local c,cerr=parse_contract(r.contract,r)
    if not c then return ctx.response(nonce,false,{error=cerr}) end
    if c.absolute then
      local shape=orient(base,c.rotations[1])
      r.x=c.ref.x-shape[1].x r.y=c.ref.y-shape[1].y
      c.center={x=r.x,y=r.y}
    end
    local block,berr=parse_block(type(r.contract)=="table" and r.contract.block or nil)
    if berr then return ctx.response(nonce,false,{error=berr}) end
    local cost={}
    for _,e in ipairs(base) do cost[e.item]=(cost[e.item] or 0)+e.count end
    local locked={}
    for name in pairs(cost) do
      local recipe=force.recipes[name]
      if recipe and not recipe.enabled then locked[#locked+1]=name end
    end
    local skipped_locked=nil
    if c.skip_locked and #locked>0 then
      local drop={} for _,name in ipairs(locked) do drop[name]=true end
      local kept,first={},nil
      for i,e in ipairs(base) do
        if drop[e.item] then
          skipped_locked=skipped_locked or {}
          skipped_locked[e.name]=(skipped_locked[e.name] or 0)+1
        else
          kept[#kept+1]=e first=first or i
        end
      end
      if #kept==0 then
        table.sort(locked)
        return ctx.response(nonce,true,{state="blocked",error="nothing-unlocked",locked=locked,
          skipped_locked=skipped_locked})
      end
      -- orient() shifts the min corner to (0,0), so dropping the entities that set that
      -- corner moves every kept row. An exact anchor is the FULL plan's corner: move it by
      -- the same shift so each kept row still lands on its own tile.
      if c.exact then
        local full=orient(base,c.rotations[1])
        local part=orient(kept,c.rotations[1])
        r.x=r.x+full[first].x-part[1].x r.y=r.y+full[first].y-part[1].y
        c.center={x=r.x,y=r.y}
      end
      base,locked,cost=kept,{},{}
      for _,e in ipairs(base) do cost[e.item]=(cost[e.item] or 0)+e.count end
    end
    for _,p in ipairs(c.primer) do
      local n=0 for _,e in ipairs(base) do if e.name==p.entity then n=n+1 end end
      if n==0 then return ctx.response(nonce,false,{error="primer-entity-not-in-blueprint",entity=p.entity}) end
      cost[p.item]=(cost[p.item] or 0)+p.count*n
    end
    -- Parked plans are the point of ghost mode (20/09), so a live job no longer
    -- swallows the call: several plans wait at once. Two guards replace the old one --
    -- a cap on how many run, and tiles another live job already claims are not a site.
    local live,reserved,ids=0,{},{}
    for _,j in pairs(jobs()) do
      if j.state=="preparing" or j.state=="building" or j.state=="settling" or j.state=="auditing" then
        -- The same plan asked for at the same spot is the SAME job, not a second one:
        -- an agent polling blueprint_run must not quietly stack duplicates. A different
        -- anchor is a different build and gets its own job.
        if j.blueprint==r.blueprint and j.surface==surface.name
          and j.request and j.request.x==r.x and j.request.y==r.y then
          return ctx.response(nonce,true,summary(j,r.detail))
        end
        live=live+1 ids[#ids+1]=j.id
        for _,e in ipairs(j.layout or {}) do
          if j.surface==surface.name then tile_keys(e,reserved) end
        end
      end
    end
    if live>=MAX_LIVE_JOBS then
      table.sort(ids)
      return ctx.response(nonce,true,{state="blocked",error="too-many-live-jobs",jobs=ids,
        max=MAX_LIVE_JOBS,materials=cost})
    end
    c.can_blast=affordable(force,stock,"cliff-explosives")
    c.can_fill=affordable(force,stock,"landfill")
    c.reserved=reserved
    local site,rejects,checks,why=find_site(surface,force,c,base)
    -- Never stored on the job: it is a snapshot of OTHER jobs at this moment, and
    -- check_site runs again from tick() with the job's own saved contract.
    c.reserved=nil
    if not site then
      return ctx.response(nonce,true,{state="blocked",error=why,rejects=rejects,checks=checks,materials=cost})
    end
    local site_out={x=site.x,y=site.y,rotation=site.rotation,checks=checks}
    local placed=place_list(site.shape,site.x,site.y)
    local clear,cliffs,flood=0,{},{}
    for _,e in ipairs(placed) do
      clear=clear+#in_footprint(surface,e,NATURAL)
      -- One cliff can sit under two footprints; pay for it once.
      for _,o in ipairs(in_footprint(surface,e,"cliff")) do cliffs[o.position.x..":"..o.position.y]=true end
      water_keys(surface,e,flood)
    end
    local blast,fill=0,0
    for _ in pairs(cliffs) do blast=blast+1 end
    for _ in pairs(flood) do fill=fill+1 end
    if clear>0 then site_out.clear=clear end
    -- Explosives and landfill are part of the bill, not a surprise at build time: with the
    -- counts in `cost`, prepare() collects and crafts them alongside the entities.
    if blast>0 then cost["cliff-explosives"]=(cost["cliff-explosives"] or 0)+blast site_out.blast=blast end
    if fill>0 then cost["landfill"]=(cost["landfill"] or 0)+fill site_out.fill=fill end
    local steps,missing
    if c.bots then steps,missing={},{} else
      steps,missing=prepare(surface,force,c.center,c.radius,stock,cost,c.supply)
    end
    -- Bots only reach ghosts inside a roboport's construction area. Uncovered rows are a
    -- warning, not a refusal: a roboport may be about to go down.
    local uncovered=nil
    if c.bots then
      local cells={}
      for _,port in pairs(surface.find_entities_filtered{type="roboport",force=force}) do
        local okc,rad=pcall(function() return port.logistic_cell.construction_radius end)
        if okc and rad and rad>0 then cells[#cells+1]={x=port.position.x,y=port.position.y,r=rad} end
      end
      for _,e in ipairs(placed) do
        local hit=false
        for _,cell in ipairs(cells) do
          if math.abs(e.x-cell.x)<=cell.r and math.abs(e.y-cell.y)<=cell.r then hit=true break end
        end
        if not hit then uncovered=(uncovered or 0)+1 end
      end
    end
    -- Warning like `uncovered`: 23/09 two inserters went down `no_power` because nothing
    -- said so before the build. Poles planned in the same design count.
    local unpowered=nil
    do
      local fed
      for _,e in ipairs(placed) do
        local p=prototypes.entity[e.name]
        if p.type~="electric-pole" and p.electric_energy_source_prototype then
          fed=fed or fed_poles(surface,force,placed)
          if not pole_covers(fed,e) then
            unpowered=unpowered or {}
            if #unpowered<12 then unpowered[#unpowered+1]={e.name,e.x,e.y} end
          end
        end
      end
    end
    local joins=lane_joins(surface,force,placed)
    local gaps=inserter_gaps(surface,force,placed,site.rotation)
    if #gaps>0 then
      return ctx.response(nonce,true,{state="blocked",error="inserter-unconnected",unconnected=gaps,skipped_locked=skipped_locked,
        site=site_out,plan=layout_digest(placed),
        placed_at=r.detail and placed_at(placed) or nil,materials=cost})
    end
    local pgaps=pipe_gaps(surface,force,placed)
    if #pgaps>0 then
      return ctx.response(nonce,true,{state="blocked",error="pipe-unconnected",unconnected=pgaps,skipped_locked=skipped_locked,
        site=site_out,plan=layout_digest(placed),
        placed_at=r.detail and placed_at(placed) or nil,materials=cost})
    end
    if #locked>0 then table.sort(locked) end
    -- A short bag stops a direct build, but it is the normal opening state of a ghost
    -- build: the plan goes down and waits. Locked technology still stops both - no amount
    -- of waiting researches it.
    local short=next(missing)~=nil and not c.ghost
    if r.dry_run or short or #locked>0 then
      return ctx.response(nonce,true,{state=(short or #locked>0) and "blocked" or "planned",
        site=site_out,site_validated=true,materials=cost,missing=missing,
        plan=layout_digest(placed),placed_at=r.detail and placed_at(placed) or nil,
        locked=#locked>0 and locked or nil,skipped_locked=skipped_locked,steps=#steps,rejects=rejects,
        bots=c.bots or nil,uncovered=uncovered,unpowered=unpowered,lane_joins=joins})
    end
    local state=ctx.state() state.executor_seq=(state.executor_seq or 0)+1
    local id="exec-"..state.executor_seq
    local j={id=id,pattern_id=r.pattern_id,blueprint=r.blueprint,contract_raw=r.contract,
      request={x=r.x,y=r.y},
      surface=surface.name,force=force.name,player=owner.index,site=site_out,
      layout=place_list(site.shape,site.x,site.y),contract=c,metrics=c.metrics,
      feeds=c.feeds,max_windows=c.max_windows,materials=cost,steps=steps,step=1,
      receipts={},feed={},state="preparing",block=block,skipped_locked=skipped_locked,
      bots=c.bots or nil,uncovered=uncovered,unpowered=unpowered,lane_joins=joins,artifact="executor/"..id,deadline=game.tick+18000}
    jobs()[id]=j save(j)
    return ctx.response(nonce,true,summary(j,r.detail))
  end

  -- Ghosts show where build_blueprint really lands; return the corrected position.
  local GHOST_PER_TICK=12

  -- A parked ghost plan restocks itself: every RESTOCK_TICKS it asks its declared supply
  -- chests for exactly what drain() said it was waiting for. No supply chests = takes
  -- nothing, which is the safe default (20/09, option A). A collect that comes up
  -- short is not a job failure here -- waiting IS the state -- so this never calls
  -- perform(), which would mark the job needs-attention.
  local RESTOCK_TICKS=600
  local function restock(j,surface,force)
    local supply=j.contract.supply
    if not supply or #supply==0 or not j.waiting then return end
    if j.restock_at and game.tick<j.restock_at then return end
    j.restock_at=game.tick+RESTOCK_TICKS
    -- Resolve the declared points to real chests once: `collect` matches at radius 0.1,
    -- so it needs the chest's own position, not the corner the agent typed.
    local chests={}
    for _,p in ipairs(supply) do
      local e=surface.find_entities_filtered{position={p.x,p.y},radius=1.5,force=force,
        type={"container","logistic-container","linked-container"}}[1]
      if e and e.valid then chests[#chests+1]=e end
    end
    for item,count in pairs(j.waiting) do
      local short=count
      for _,e in ipairs(chests) do
        if short<=0 then break end
        local inv=e.get_inventory(defines.inventory.chest)
        -- collect() refuses the whole pull when the chest is short, so ask for what is
        -- actually in there: half a delivery still lets drain() build half the plan.
        local n=inv and math.min(short,inv.get_item_count{name=item,quality="normal"}) or 0
        if n>0 then
          local ok,r=pcall(ctx.collect,j.id..":restock-"..((j.restocks or 0)+1),
            {item=item,count=n,x=e.position.x,y=e.position.y,surface=j.surface,force=j.force})
          if ok and type(r)=="table" and r.ok then
            local got=tonumber(r.count) or 0
            short=short-got
            j.restocks=(j.restocks or 0)+1
            j.restocked=j.restocked or {}
            j.restocked[item]=(j.restocked[item] or 0)+got
            -- One receipt per successful pull, capped: a plan parked for an hour would
            -- otherwise write a receipt file that never stops growing.
            if #j.receipts<200 then j.receipts[#j.receipts+1]=r end
          end
        end
      end
    end
  end

  -- Ghost mode's engine room. Walks the job's own layout, not a stored ghost list, so a
  -- ghost that vanished unbuilt is noticed and re-placed: this API build exposes no
  -- ghost-expiry field, so its lifetime is not something to rely on.
  -- Returns true while work is left (job stays in `building`).
  -- Returns (work_left, built_this_pass).
  local function drain(j,surface,force,stock)
    local waiting,blocked,done,pending={},{},0,0
    local built_now=0
    local standing={}  -- tiles a character is parked on: waiting, not blocked
    local budget=GHOST_PER_TICK
    local function one(e)
      local live=surface.find_entity(e.name,{e.x,e.y})
      -- `done` is not `built`: a tile the blueprint wants may already hold the right
      -- entity from an earlier session. Mark which is which so the report cannot pass
      -- off a base that was already standing as work this job paid for.
      if live and live.valid then
        -- Bots mode: a tile that held this job's ghost and now holds the entity was built
        -- by the robots for this job, not found standing.
        if e.ghosted and not e.ours then e.ours,e.ghosted=true,nil end
        if not e.ours then e.pre=true end
        return "done"
      end
      local g=surface.find_entity("entity-ghost",{e.x,e.y})
      if not (g and g.valid and g.ghost_name==e.name) then
        -- Drift alarm. A ghost of this very name one tile away, that this job did not put
        -- there, means the layout is anchored off by that much: the job is about to lay a
        -- SECOND ghost set beside a human's and revive the wrong one. Measured 21/09 on
        -- exec-24, where every row landed +1 x. Name it on the job instead of letting the
        -- two sets look like one crowded site.
        for _,near in pairs(surface.find_entities_filtered{type="entity-ghost",force=force,
          area={{e.x-1.5,e.y-1.5},{e.x+1.5,e.y+1.5}}}) do
          -- A neighbour this same layout wants (a belt run) is not drift: 23/09 every
          -- row belt raised the alarm against the next tile of its own run.
          if not j.wanted then
            j.wanted={}
            for _,w in ipairs(j.layout) do j.wanted[w.name.."@"..w.x..","..w.y]=true end
          end
          if near.valid and near.ghost_name==e.name
              and (math.abs(near.position.x-e.x)>0.01 or math.abs(near.position.y-e.y)>0.01)
              and not j.wanted[e.name.."@"..near.position.x..","..near.position.y] then
            j.drift=j.drift or {}
            if #j.drift<8 then
              j.drift[#j.drift+1]={name=e.name,x=e.x,y=e.y,
                found_x=near.position.x,found_y=near.position.y}
            end
            break
          end
        end
        local function ghost_at(recipe)
          local okg,made=pcall(function()
            return surface.create_entity{name="entity-ghost",inner_name=e.name,
              position={e.x,e.y},direction=e.dir,force=force,recipe=recipe,
              type=e.set and e.set.ug or nil}
          end)
          return okg and made or nil
        end
        -- `recipe` on a ghost is not accepted for every prototype; losing the recipe is
        -- better than losing the entity, and drain() sets it again after revive.
        local made=ghost_at(e.recipe) or (e.recipe and ghost_at(nil))
        apply_settings(made,e.set)
        if not made then return "blocked" end
        -- Named, not just counted: "replaced: 3" says nothing about WHICH tile lost its
        -- ghost. This is a re-placement of a missing ghost, never an upgrade in place.
        j.replaced=(j.replaced or 0)+1
        -- Ownership by unit_number: a job's ghost and a human's ghost look identical on the
        -- ground, and removing "the job's ghosts" by position alone also removes a human's
        -- wherever the two sets coincide (a belt run shifted along its own axis coincides
        -- everywhere but its ends).
        if made.unit_number then
          j.ghost_units=j.ghost_units or {}
          j.ghost_units[tostring(made.unit_number)]=true
        end
        j.replaced_at=j.replaced_at or {}
        if #j.replaced_at<8 then j.replaced_at[#j.replaced_at+1]={e.name,e.x,e.y} end
        if j.contract.bots then e.ghosted=true end
        return "pending"
      end
      -- A ghost may be SET over an occupied tile - ghosts do not collide - but it can
      -- never be revived there. Without this the job would wait on that tile forever and
      -- call it "pending": a silent stall instead of a named blocker.
      if not surface.can_place_entity{name=e.name,position={e.x,e.y},direction=e.dir,
        force=force,build_check_type=defines.build_check_type.manual} then
        -- Except when the only thing on the tile is a character: it moves, so naming it
        -- a blocker would fail a job that is about to succeed on its own.
        local only_character=#in_footprint(surface,e,"character")>0
        local by,seen={},{}
        for _,o in pairs(in_footprint(surface,e,nil)) do
          if o.type~="character" and o.name~="entity-ghost" then
            only_character=false
            -- WHAT is on the tile, not just that something is: a count alone made the
            -- caller list ghosts by hand to find out (21/09, exec-24).
            if not seen[o.name] then seen[o.name]=true by[#by+1]=o.name end
          end
        end
        if not only_character then return "blocked",table.concat(by,"+") end
        -- Named on the receipt anyway: a player who parks there forever would otherwise
        -- leave the job "pending" with nothing saying why.
        if #standing<8 then standing[#standing+1]={e.name,e.x,e.y} end
        return "pending"
      end
      if j.contract.bots then e.ghosted=true return "pending" end
      if budget<=0 then return "pending" end
      local item=prototypes.entity[e.name].items_to_place_this[1]
      if stock.get_item_count{name=item.name,quality="normal"}<item.count then
        waiting[item.name]=(waiting[item.name] or 0)+item.count
        return "pending"
      end
      budget=budget-1
      -- Debit first. revive() builds for free, so the order here IS the no-free-items rule.
      local removed=stock.remove{name=item.name,count=item.count}
      if removed~=item.count then
        if removed>0 then stock.insert{name=item.name,count=removed} end
        return "pending"
      end
      local okr,_,built=pcall(function() return g.revive{raise_revive=true} end)
      if not (okr and built) then
        stock.insert{name=item.name,count=item.count}
        return "pending"
      end
      local recipe_lost
      if e.recipe and built.type=="assembling-machine" and not built.get_recipe() then
        -- A re-placed ghost can lose the recipe the blueprint carried; put it back, and
        -- say so on the receipt when it cannot go back (locked technology).
        local okr2=pcall(function() built.set_recipe(e.recipe) end)
        recipe_lost=(not okr2) and e.recipe or nil
      end
      apply_settings(built,e.set)
      e.ours,e.pre=true,nil
      built_now=built_now+1
      j.receipts[#j.receipts+1]={ok=true,action="revive",name=e.name,x=e.x,y=e.y,
        item=item.name,count=item.count,recipe_lost=recipe_lost,
        wires=built.type=="electric-pole" and ctx.wire and ctx.wire(built) or nil}
      return "done"
    end
    for _,e in ipairs(j.layout) do
      local verdict,why=one(e)
      if verdict=="done" then done=done+1
      elseif verdict=="pending" then pending=pending+1
      else blocked[#blocked+1]={name=e.name,x=e.x,y=e.y,by=why~="" and why or nil} end
    end
    local built_here,already=0,0
    for _,e in ipairs(j.layout) do
      if e.ours then built_here=built_here+1 elseif e.pre then already=already+1 end
    end
    j.built,j.existing=built_here,already
    j.placed,j.pending=done,pending
    j.waiting=next(waiting) and waiting or nil
    j.blocked=#blocked>0 and blocked or nil
    j.standing=#standing>0 and standing or nil
    return pending>0,built_now
  end

  local function aim(j,surface,force)
    local inv=game.create_inventory(1)
    local stack=inv[1] stack.import_stack(j.blueprint)
    local W,H=0,0
    for _,e in ipairs(j.layout) do
      W=math.max(W,e.x+e.w/2-j.site.x) H=math.max(H,e.y+e.h/2-j.site.y)
    end
    local guess={x=j.site.x+W/2,y=j.site.y+H/2}
    -- The probe position must be on the alignment the entities want (odd sizes sit on
    -- half tiles, even sizes on whole ones). A guess that is half a tile out places
    -- NOTHING and reads exactly like a fully blocked site, so try the four offsets.
    -- The probe position must match the alignment the entities want (odd sizes sit on
    -- half tiles, even ones on whole tiles). Half a tile out places NOTHING and reads
    -- exactly like a blocked site, so try the four offsets before believing that.
    local ghosts={}
    for _,off in ipairs{{0,0},{0.5,0},{0,0.5},{0.5,0.5}} do
      if #ghosts==0 then
        local try={x=guess.x+off[1],y=guess.y+off[2]}
        local okbp,out=pcall(function() return stack.build_blueprint{surface=surface,force=force,
          position=try,direction=j.site.rotation,build_mode=defines.build_mode.normal,raise_built=false} end)
        if okbp and out and #out>0 then ghosts=out guess=try end
      end
    end
    inv.destroy()
    -- The probe itself can come back short over a live base (the engine drops the entities
    -- whose tiles are taken), so the offset is read from whatever DID land: any delta that
    -- explains every returned ghost is the right one. Requiring a full probe would refuse
    -- the paste for the very reason ghost mode exists.
    local delta
    for _,g in ipairs(ghosts) do
      if g.valid and not delta then
        for _,e in ipairs(j.layout) do
          if e.name==g.ghost_name and not delta then
            local dx,dy=e.x-g.position.x,e.y-g.position.y
            local all=true
            for _,h in ipairs(ghosts) do
              local hit=false
              for _,f in ipairs(j.layout) do
                if f.name==h.ghost_name and math.abs(f.x-h.position.x-dx)<0.01 and math.abs(f.y-h.position.y-dy)<0.01 then hit=true break end
              end
              if not hit then all=false break end
            end
            if all then delta={dx,dy} end
          end
        end
      end
    end
    local n=#ghosts
    for _,g in ipairs(ghosts) do if g.valid then g.destroy() end end
    -- Direct mode still demands a complete probe: it spends the whole bill in one call.
    if not delta or n==0 or (not j.contract.ghost and n~=#j.layout) then error("blueprint-aim-failed:"..n.."/"..#j.layout) end
    return guess.x+delta[1],guess.y+delta[2]
  end

  -- Cliffs blasted and water filled in one pass, debit BEFORE the ground changes -- the
  -- same order as a ghost revive, and for the same reason: destroy() and set_tiles() are
  -- free, so the debit is the no-free-items rule. Returns false when the bag is short, so
  -- a ghost plan parks on it instead of failing.
  local function clear_ground(j,surface,stock)
    local cliffs,seen={},{}
    for _,e in ipairs(j.layout) do
      for _,o in ipairs(in_footprint(surface,e,"cliff")) do
        local k=o.position.x..":"..o.position.y
        if not seen[k] then seen[k]=true cliffs[#cliffs+1]=o end
      end
    end
    local flood={}
    for _,e in ipairs(j.layout) do water_keys(surface,e,flood) end
    local tiles={}
    for k in pairs(flood) do
      local x,y=k:match("^(-?%d+):(-?%d+)$")
      tiles[#tiles+1]={name="landfill",position={tonumber(x),tonumber(y)}}
    end
    local short
    if #cliffs>0 and stock.get_item_count{name="cliff-explosives",quality="normal"}<#cliffs then
      short={["cliff-explosives"]=#cliffs}
    elseif #tiles>0 and stock.get_item_count{name="landfill",quality="normal"}<#tiles then
      short={landfill=#tiles}
    end
    if short then j.ground=short return false end
    j.ground=nil
    for _,o in ipairs(cliffs) do
      if o.valid then
        local x,y=o.position.x,o.position.y
        if stock.remove{name="cliff-explosives",count=1}~=1 then return false end
        o.destroy{do_cliff_correction=true,raise_destroy=true}
        j.receipts[#j.receipts+1]={ok=true,action="blast",name="cliff",x=x,y=y,
          item="cliff-explosives",count=1}
      end
    end
    j.blasted=(j.blasted or 0)+#cliffs
    if #tiles==0 then j.filled=j.filled or 0 return true end
    local removed=stock.remove{name="landfill",count=#tiles}
    if removed<#tiles then
      if removed>0 then stock.insert{name="landfill",count=removed} end
      return false
    end
    surface.set_tiles(tiles,true)
    -- Read the ground back. A tile the engine refused to change bought nothing, so the
    -- landfill goes back in the bag; a fill that moved NOTHING is not a wait, it is a
    -- surface that cannot take landfill at all, and waiting on it would never end.
    local left=0
    for _,t in ipairs(tiles) do
      local g=surface.get_tile(t.position[1],t.position[2])
      if g.valid and g.prototype.fluid then left=left+1 end
    end
    if left>0 then stock.insert{name="landfill",count=left} end
    j.receipts[#j.receipts+1]={ok=left==0,action="landfill",count=#tiles-left,
      item="landfill",refunded=left>0 and left or nil}
    j.filled=(j.filled or 0)+(#tiles-left)
    if left>=#tiles then error("landfill-refused:"..left) end
    return left==0
  end

  local flow_tick

  function M.tick()
    flow_tick()
    for _,j in pairs(jobs()) do
      if j.state=="preparing" or j.state=="building" or j.state=="settling" or j.state=="auditing" then
        local ok,err=pcall(function()
          local surface,force=game.get_surface(j.surface),game.forces[j.force]
          local stock,owner,kind=ctx.inventory()
          if kind~="player" or owner.index~=j.player or owner.surface~=surface then error("treasury-changed") end
          -- Main inventory is nil while the player has no character body (23/09, mid-build
          -- after a restart): wait a tick instead of killing the job with a nil index.
          if not stock then return end
          if j.state=="preparing" then
            if game.tick>j.deadline then error("job-timeout") end
            if owner.crafting_queue_size>0 then return end
            local s=j.steps[j.step]
            if s then
              local r=perform(j,s.action,s.body)
              if r.ok then j.step=j.step+1
              elseif j.contract.ghost then
                -- Ghost mode gathers best-effort. A collect/craft step that cannot run
                -- (an ingredient the base does not make yet) must not kill the paste:
                -- perform() already marked the job, so undo that, skip the step, and let
                -- the ghosts go down. drain() names whatever is still short in `waiting`.
                j.state,j.error="preparing",nil
                j.skipped=j.skipped or {}
                if #j.skipped<8 then
                  j.skipped[#j.skipped+1]={s.action,s.body.recipe or s.body.item or s.body.name,r.error}
                end
                j.step=j.step+1
              end
              save(j) return
            end
            j.state="building"
          end
          if j.state=="building" then
            -- Everything up to and including the import is skipped once it has happened:
            -- a resumed job must not re-clear, re-spend or re-import what is on the ground.
            -- The flag is set only on a SUCCESSFUL import; j.placed can be a count of 0,
            -- which Lua reads as true.
            if not j.imported then
            local rejects={}
            j.contract.can_blast=affordable(force,stock,"cliff-explosives")
            j.contract.can_fill=affordable(force,stock,"landfill")
            if not check_site(surface,force,j.contract,j.layout,rejects) then
              j.rejects=rejects error("site-changed-replan")
            end
            if not j.cleared then
              local seen,n={},0
              for _,e in ipairs(j.layout) do
                for _,o in ipairs(in_footprint(surface,e,NATURAL)) do
                  local k=o.name..":"..o.position.x..":"..o.position.y
                  if not seen[k] then
                    seen[k]=true n=n+1
                    if not perform(j,"mine",{name=o.name,x=o.position.x,y=o.position.y}).ok then save(j) return end
                  end
                end
              end
              j.cleared=n
            end
            -- Cliffs and water: the other two natural blockers (20/09). Both are
            -- cleared here, after the trees, because both spend items the preparing steps
            -- just collected. A ghost plan that cannot pay yet parks and retries.
            if j.blasted==nil or j.filled==nil then
              if not clear_ground(j,surface,stock) then
                if not j.contract.ghost then error("ground-not-clear") end
                j.scan_at=game.tick+SCAN_TICKS save(j) return
              end
            end
            if j.contract.ghost then
              -- No native paste here. MEASURED (tests/verify_ghost_runtime.py): a
              -- build_blueprint whose entities overlap a FOREIGN entity on even one tile
              -- returns ZERO ghosts - the engine refuses the whole paste, it does not drop
              -- the offending entity (`paste_foreign_entity_overlaps` = 0 against
              -- `paste_clean` = 3; an IDENTICAL entity already there is the one case it
              -- skips quietly, `paste_same_entity_present` = 2). So ghost mode sets one
              -- ghost per entity in drain(): a taken tile costs that tile, not the plan,
              -- and aim() is not needed because the layout is already absolute.
              j.placed=0
            else
              -- Direct mode still pays the whole bill up front, in one call.
              for name,n in pairs(j.materials) do
                if stock.get_item_count{name=name,quality="normal"}<n then
                  -- Another job (or a hand craft) spent from the same bag since this plan
                  -- was made (23/09 materials-changed:wood). Plan again from the bag as it
                  -- is now and go back to preparing; give up after 3 rounds.
                  j.replans=(j.replans or 0)+1
                  local c=j.contract
                  local steps,missing=prepare(surface,force,c.center,c.radius,stock,j.materials,c.supply)
                  if j.replans>3 or next(missing) then error("materials-changed:"..name) end
                  j.steps,j.step,j.state,j.deadline=steps,1,"preparing",game.tick+18000
                  save(j) return
                end
              end
              local x,y=aim(j,surface,force)
              local result=perform(j,"import",{blueprint=j.blueprint,x=x,y=y,mode="direct",
                direction=j.site.rotation})
              j.placed=result.placed or 0
              if not result.ok then save(j) return end
            end
            j.imported=true
            end
            -- Stays in `building` while ghosts remain: no new state, so every guard,
            -- ledger row and report path that already knows `building` keeps working.
            if j.contract.ghost then
              -- A plan parked on materials is re-read once a second, not 60 times: with
              -- several jobs alive that is the difference between a background wait and a
              -- per-tick walk of every layout plus a receipt file each.
              if j.scan_at and game.tick<j.scan_at then return end
              if not j.contract.bots then restock(j,surface,force) end
              local left,built_now=drain(j,surface,force,stock)
              if left then
                j.scan_at=built_now>0 and nil or game.tick+SCAN_TICKS
                save(j) return
              end
              j.scan_at=nil
              -- Nothing left waiting, but tiles the engine refused are still refused: name
              -- them and stop. Free the tile, then report(resume=true) picks up from here.
              if j.blocked then error("blueprint-blocked:"..#j.blocked) end
            end
            local es,bad,why=built_entities(j)
            if not es then error("import-geometry-mismatch:"..bad..":"..(why or "")) end
            -- Stamp identity while we still know which entities are ours. Belts, pipes and
            -- rails carry no unit_number; those rows keep the coordinate fallback.
            for i,e in ipairs(es) do j.layout[i].unit=e.unit_number end
            -- Declared infrastructure must be connected BEFORE primer spends fuel.
            for _,rule in ipairs(j.contract.connect) do
              for i,e in ipairs(es) do
                if e.name==rule.entity and not connected(es,e,rule) then
                  error("infra-missing:"..(rule.fluid or "power")..":"..e.name.."@"..j.layout[i].x..","..j.layout[i].y)
                end
              end
            end
            -- Primer inserts are counted, so a resume does not fuel the same machine twice.
            local primed=0
            for _,p in ipairs(j.contract.primer) do
              for _,e in ipairs(j.layout) do
                if e.name==p.entity then
                  primed=primed+1
                  if primed>(j.primed or 0) then
                    if not perform(j,"insert",{item=p.item,count=p.count,x=e.x,y=e.y}).ok then save(j) return end
                    j.primed=primed
                  end
                end
              end
            end
            -- Last executor mutation: holdout clock starts here.
            j.last_mutation=game.tick
            j.audit={windows={},rule="last-window-must-pass",window_ticks=j.contract.window_ticks,
              settle_ticks=j.contract.settle_ticks}
            j.state=#j.metrics>0 and "settling" or "verified"
            j.settle_until=game.tick+j.contract.settle_ticks
            if j.state=="verified" then
              j.audit.status="not-requested"
              helpers.write_file(j.artifact..".blueprint.txt",j.blueprint.."\n",false)
            end
            save(j) return
          end
          local es,bad,why=built_entities(j)
          if not es then error("layout-broken:"..bad..":"..(why or "")) end
          run_feeds(j,es)
          if j.state=="settling" then
            if game.tick<j.settle_until then return end
            j.state="auditing" j.feed_window=0 open_window(j,es)
          end
          sample(j,es)
          if game.tick-j.window.start>=j.contract.window_ticks then close_window(j,es) save(j) end
        end)
        if not ok then j.state,j.error="needs-attention",(tostring(err):gsub("^__[^:]+:%d+: ","")) save(j) end
      end
    end
  end

  flow_tick = require("ledger")(ctx, M, jobs)

  function M.status(nonce,r)
    local j=jobs()[r.job_id]
    if not j then return ctx.response(nonce,false,{error="executor-job-not-found"}) end
    -- A job that fails AFTER the import (infra not connected, a primer insert with no room,
    -- a failed audit) leaves real machines standing. Once the agent has fixed the cause,
    -- resume picks the job up where it stopped: the import and the primer inserts already
    -- done are not repeated, and the holdout clock restarts. Recall + rebuild is the only
    -- other way out, and it pays for the block twice.
    if r.resume then
      if j.dropped then
        return ctx.response(nonce,false,{error="job-ghosts-dropped",state=j.state})
      end
      if j.state~="needs-attention" then
        return ctx.response(nonce,false,{error="job-not-resumable",state=j.state})
      end
      if not j.imported then
        return ctx.response(nonce,false,{error="job-not-built",state=j.state})
      end
      j.state,j.error,j.rejects="building",nil,nil
      j.deadline=game.tick+18000
      save(j)
    end
    return ctx.response(nonce,true,summary(j,r.detail))
  end

  -- Remove the ghosts THIS job laid, leave everyone else's. Built entities are untouched:
  -- that is recall's job, and recall pays the items back. Ghosts cost nothing, so there is
  -- nothing to refund here.
  -- Ownership, in order of trust:
  --   ghost_units -- unit_numbers recorded as the job laid each ghost (jobs from
  --                  build 2026-09-21-drop-ghosts on).
  --   legacy floor -- older jobs recorded only the first 8 positions they laid (replaced_at).
  --                  unit_numbers are handed out in creation order, so the lowest unit still
  --                  standing on one of those positions is a floor: a ghost on a layout row
  --                  at or above it was laid by this job, one below it was already there.
  --                  Measured 21/09 exec-24: human ghosts 2739..2813, job ghosts 6165+.
  -- Either way only a ghost on one of the job's own layout rows is ever a candidate.
  function M.drop_ghosts(nonce,r)
    local j=jobs()[r.job_id]
    if not j then return ctx.response(nonce,false,{error="executor-job-not-found"}) end
    -- A plan parked on materials sits in `building` forever, and cancelling one is half of
    -- what this is for. Mid-gather and mid-audit are refused: those are doing work.
    if j.state=="preparing" or j.state=="settling" or j.state=="auditing" then
      return ctx.response(nonce,false,{error="job-still-live",state=j.state})
    end
    local surface=game.get_surface(j.surface)
    if not surface then return ctx.response(nonce,false,{error="surface-not-found"}) end
    local function ghost_on(name,x,y)
      local g=surface.find_entity("entity-ghost",{x,y})
      return g and g.valid and g.ghost_name==name and g or nil
    end
    local owned,floor=j.ghost_units,nil
    if (j.replaced or 0)==0 then
      return ctx.response(nonce,true,{job_id=j.id,removed=0,kept_foreign=0,
        detail="this job laid no ghosts of its own"})
    end
    if not owned then
      for _,at in ipairs(j.replaced_at or {}) do
        local g=ghost_on(at[1],at[2],at[3])
        if g and g.unit_number and (not floor or g.unit_number<floor) then floor=g.unit_number end
      end
      if not floor then
        return ctx.response(nonce,false,{error="ghost-ownership-unknown",
          detail="no recorded units and none of replaced_at still stands"})
      end
    end
    local removed,kept,byname={},0,{}
    for _,e in ipairs(j.layout or {}) do
      local g=ghost_on(e.name,e.x,e.y)
      if g then
        local mine
        if owned then mine=owned[tostring(g.unit_number)]
        else mine=g.unit_number and g.unit_number>=floor end
        if mine then
          if not r.dry_run then g.destroy() end
          removed[#removed+1]={e.name,e.x,e.y}
          byname[e.name]=(byname[e.name] or 0)+1
        else kept=kept+1 end
      end
    end
    if not r.dry_run then
      -- Resuming would lay the same rows again, so the job is closed, not just emptied.
      j.dropped=true
      j.state,j.error="needs-attention","ghosts-dropped"
      save(j)
    end
    return ctx.response(nonce,true,{job_id=j.id,dry_run=r.dry_run or nil,
      removed=#removed,removed_by_name=byname,removed_at=#removed<=40 and removed or nil,
      kept_foreign=kept,ownership=owned and "recorded" or "legacy-floor",floor=floor})
  end
  return M
end
return M

