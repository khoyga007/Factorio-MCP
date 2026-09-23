-- Base ledger (attached by executor): blocks, edges, flow sampling, clusters, ledger/note actions.
-- Returns flow_tick for executor's M.tick.
local site = require("site")
local finite, list, sorted_keys = site.finite, site.list, site.sorted_keys
local contract = require("contract")
local parse_block = contract.parse_block

return function(ctx, M, jobs)
  -- Base ledger: what each block is, where, what it feeds/eats. Lives in the save (storage),
  -- so it travels with the map and survives restarts/handoffs. Executor jobs are blocks
  -- automatically; hand-built areas can be registered via note. Live state is recomputed
  -- on every read, only agent intent (name/role/links/notes) is stored.
  M.parse_block=parse_block
  local function hands() local s=ctx.state() s.ledger_hand=s.ledger_hand or {} return s.ledger_hand end
  local function r1(v) return math.floor(v*10+0.5)/10 end
  local function box_of(layout)
    local x1,y1,x2,y2=math.huge,math.huge,-math.huge,-math.huge
    for _,e in ipairs(layout) do
      x1=math.min(x1,e.x-e.w/2) y1=math.min(y1,e.y-e.h/2) x2=math.max(x2,e.x+e.w/2) y2=math.max(y2,e.y+e.h/2)
    end
    return {r1(x1),r1(y1),r1(x2),r1(y2)}
  end
  local INTENT={"name","role","feeds","eats","notes"}
  local function entry(id,b,extra)
    local out=extra
    out.id=id
    for _,k in ipairs(INTENT) do out[k]=b and b[k] end
    return out
  end

  -- Edge throughput. Numbers come from the engine's own counters, never from
  -- prototype arithmetic: `made` is the delta of products_finished over one closed
  -- window, `active` is how often each machine was actually `working` when sampled.
  -- A drill has no per-entity counter, so it reports activity only -- never a rate.
  -- Caveats worth knowing before trusting a number: a machine added or removed
  -- mid-window carries its own lifetime count in or out (negative deltas are dropped,
  -- so a removal reads as a quiet window, not a negative rate), and a furnace whose
  -- recipe changed mid-window attributes the whole window to the recipe it ends on.
  local FLOW_WINDOW=3600        -- one game minute per closed window
  local FLOW_ENTITY_BUDGET=600  -- entities examined per sampling tick, across all blocks
  local function flow() local s=ctx.state() s.ledger_flow=s.ledger_flow or {} return s.ledger_flow end
  local function flow_window() return ctx.state().ledger_flow_window or FLOW_WINDOW end

  -- A job's own entities, plus how many of its planned entities are gone. The tile finds a
  -- candidate, the stamped unit_number proves it is OURS: a recalled job whose cell was
  -- rebuilt would otherwise see the NEW machines at its old coordinates, report itself
  -- intact, and have its flow counted twice.
  -- game.get_entity_by_unit_number is NOT usable for this: measured 20/09, it returns nil
  -- for an entity we hold, valid, in the same tick we read its own unit_number.
  -- Belts, pipes and rails have no unit_number, so those rows are still tile-only and a
  -- rebuild on the same tiles can still fool a job made purely of them.
  local function own_entities(j)
    local surface=game.get_surface(j.surface)
    local out,miss={},0
    for _,e in ipairs(j.layout) do
      local found=surface and surface.find_entity(e.name,{e.x,e.y})
      if found and found.valid and (not e.unit or found.unit_number==e.unit) then out[#out+1]=found
      else miss=miss+1 end
    end
    return out,miss
  end

  -- A built job with nothing left on the ground is not a block any more: it was recalled or
  -- destroyed. It leaves the ledger so its declared links stop reading as starved edges.
  local function gone(j)
    if not j.placed then return false end
    local _,miss=own_entities(j)
    return miss>=#j.layout
  end

  -- Every block that occupies ground right now, job or hand, as {id, surface, force, box}.
  local function block_sites()
    local out={}
    for _,id in ipairs(sorted_keys(jobs())) do
      local j=jobs()[id]
      if j.placed or j.state=="building" or j.state=="settling" or j.state=="auditing" then
        if not gone(j) then
          out[#out+1]={id=id,surface=j.surface,force=j.force,box=box_of(j.layout),job=j}
        end
      end
    end
    for _,id in ipairs(sorted_keys(hands())) do
      local h=hands()[id]
      out[#out+1]={id=id,surface=h.surface,force=h.force,box=h.box}
    end
    return out
  end

  local function site_entities(site)
    if site.job then return (own_entities(site.job)) end
    local surface=game.get_surface(site.surface)
    if not surface then return {} end
    return surface.find_entities_filtered{force=site.force,
      area={{site.box[1],site.box[2]},{site.box[3],site.box[4]}}}
  end

  -- products_finished is a per-machine lifetime count of completed crafts; turn it into
  -- item totals through the recipe each machine is running.
  -- Reading products_finished off anything else is a hard error ("Entity is not
  -- crafting-machine"), not nil, so the type gate comes first.
  local CRAFTERS={["assembling-machine"]=true,furnace=true,["rocket-silo"]=true}
  local function made_totals(es)
    local t={}
    for _,e in pairs(es) do
      local n=e.valid and CRAFTERS[e.type] and e.products_finished
      if n and n>0 then
        local ok,recipe=pcall(function() return e.get_recipe() end)
        for _,p in pairs(ok and recipe and recipe.products or {}) do
          if p.type=="item" then
            local amount=p.amount or ((p.amount_min or 0)+(p.amount_max or 0))/2
            t[p.name]=(t[p.name] or 0)+n*amount*(p.probability or 1)
          end
        end
      end
    end
    return t
  end

  local function flow_step(site,es)
    local fl,now=flow(),made_totals(es)
    local f=fl[site.id]
    if not f then f={start=game.tick,base=now,samples=0,active={},present={}} fl[site.id]=f end
    f.samples,f.present=f.samples+1,f.present or {}
    local counters=0
    for _,e in pairs(es) do
      if e.valid then
        -- Denominator per name, not per sample: 8 furnaces each working in every sample
        -- used to add 8 per sample and read back as active 800.
        f.present[e.name]=(f.present[e.name] or 0)+1
        if CRAFTERS[e.type] then counters=counters+1 end
        if e.status==defines.entity_status.working then
          f.active[e.name]=(f.active[e.name] or 0)+1
        end
      end
    end
    f.counters=counters
    local ticks=game.tick-f.start
    if ticks>=flow_window() then
      local made,active={}, {}
      for item,total in pairs(now) do
        local d=total-(f.base[item] or 0)
        if d>0 then made[item]=r1(d*3600/ticks) end
      end
      -- Whole percent, not a fraction: a double like 0.83 serialises to 17 digits and
      -- every one of them costs the agent context for no extra truth.
      for name,n in pairs(f.active) do
        active[name]=math.floor(n*100/math.max(f.present[name] or f.samples,1)+0.5)
      end
      -- `counted` = machines in this block whose output products_finished can count.
      -- Zero means `made` is empty because NOTHING here counts (drills, belts, chests),
      -- not because the block produced nothing.
      f.last={ticks=ticks,samples=f.samples,made=made,active=active,counted=counters}
      f.start,f.base,f.samples,f.active,f.present=game.tick,now,0,{},{}
    end
  end

  -- Sample every block per call, resuming where the budget ran out last time so a
  -- big base cannot starve the blocks at the end of the list.
  local function flow_tick()
    local sites,s=block_sites(),ctx.state()
    if #sites==0 then s.ledger_flow=nil return end
    local start,budget=(s.ledger_flow_cursor or 0)%#sites,FLOW_ENTITY_BUDGET
    local seen,covered={}, 0
    for i=0,#sites-1 do
      local site=sites[(start+i)%#sites+1]
      if budget<=0 then s.ledger_flow_cursor=(start+i)%#sites break end
      local es=site_entities(site)
      budget=budget-math.max(#es,1)
      flow_step(site,es)
      seen[site.id],covered=true,covered+1
    end
    if covered==#sites then
      s.ledger_flow_cursor=0
      for id in pairs(flow()) do if not seen[id] then flow()[id]=nil end end
    end
  end

  -- What one block measurably produced, for the block row and for its outgoing edges.
  local function flow_of(id)
    local f=flow()[id]
    return f and f.last or nil
  end

  -- Macro layer. One read used to mean every block at full detail: fine at 14 blocks
  -- (~390 B each), unreadable at 150 (~58 kB against a ~64 kB datagram ceiling). So the read
  -- zooms. "roll" is fixed-size however big the base gets, "rows" pages filtered blocks,
  -- "one" opens a single block whole. Filtering lives here, not in the caller, because the
  -- packet is the thing being protected.
  local CLUSTER_GAP=8   -- tiles of slack between two boxes that still counts as one cluster
  local ROWS_PAGE=12
  local function keep(t) return next(t) and t or nil end
  local function near_box(a,b)
    return a[1]-CLUSTER_GAP<=b[3] and b[1]-CLUSTER_GAP<=a[3]
       and a[2]-CLUSTER_GAP<=b[4] and b[2]-CLUSTER_GAP<=a[4]
  end
  -- A block made of nothing but belts, pipes and poles is connective tissue, not a site.
  -- Measured 21/09: clustering on geometry alone put 13 of 14 blocks in ONE cluster,
  -- because a 160-tile belt spine touches everything it serves. So carriers never merge
  -- two clusters; they attach to the nearest one and are counted apart.
  local CARRIER={["transport-belt"]=true,["underground-belt"]=true,["splitter"]=true,
    ["electric-pole"]=true,["pipe"]=true,["pipe-to-ground"]=true,["rail"]=true,
    ["straight-rail"]=true,["curved-rail"]=true,["rail-ramp"]=true,["rail-support"]=true}
  -- Dominance, not purity: measured 21/09, a 194-belt spine carrying TWO burner inserters
  -- read as a site and stretched its cluster box across 160 tiles. Two machines do not
  -- make a factory; nine in ten entities being carrier decides what the block is.
  local CARRIER_SHARE=0.9
  local function is_carrier(b)
    local carry,total=0,0
    for name,c in pairs(b.n or {}) do
      local proto=prototypes.entity[name]
      if proto and CARRIER[proto.type] then carry=carry+c end
      total=total+c
    end
    return total>0 and carry/total>=CARRIER_SHARE
  end
  local function box_gap(a,b)
    local dx=math.max(a[1]-b[3],b[1]-a[3],0)
    local dy=math.max(a[2]-b[4],b[2]-a[4],0)
    return dx+dy
  end
  -- Union-find over the SITE blocks only: a cluster is where machines stand, so the agent
  -- never has to declare one. A declared block name inside the group names the group.
  local function clusters_of(out)
    local sites,carriers={},{}
    for _,b in ipairs(out) do
      if is_carrier(b) then carriers[#carriers+1]=b else sites[#sites+1]=b end
    end
    local parent={}
    local function find(i) while parent[i]~=i do parent[i]=parent[parent[i]] i=parent[i] end return i end
    for i=1,#sites do parent[i]=i end
    for i=1,#sites do for k=i+1,#sites do
      if near_box(sites[i].box,sites[k].box) then
        local a,b=find(i),find(k)
        if a~=b then parent[b]=a end
      end
    end end
    local by,list={},{}
    local function group(b,root)
      local g=by[root]
      if not g then
        g={box={b.box[1],b.box[2],b.box[3],b.box[4]},blocks=0,attention=0,makes={},n={},members={}}
        by[root]=g list[#list+1]=g
      end
      return g
    end
    local function absorb(g,b,widen)
      g.blocks=g.blocks+1
      if b.status=="attention" then g.attention=g.attention+1 end
      if b.name and not g.name then g.name=b.name end
      if widen then
        g.box[1]=math.min(g.box[1],b.box[1]) g.box[2]=math.min(g.box[2],b.box[2])
        g.box[3]=math.max(g.box[3],b.box[3]) g.box[4]=math.max(g.box[4],b.box[4])
        for name,c in pairs(b.n or {}) do g.n[name]=(g.n[name] or 0)+c end
      end
      local f=b.flow
      if f and (f.counted or 0)>0 then
        for item,c in pairs(f.made or {}) do g.makes[item]=(g.makes[item] or 0)+c end
      end
      g.members[#g.members+1]=b
    end
    for i=1,#sites do absorb(group(sites[i],find(i)),sites[i],true) end
    -- Carriers attach to the nearest site cluster. Their box does NOT widen the cluster:
    -- a spine that crosses the base would otherwise make every cluster box the whole map.
    for _,b in ipairs(carriers) do
      local best,gap=nil,math.huge
      for _,g in ipairs(list) do
        local d=box_gap(b.box,g.box)
        if d<gap then best,gap=g,d end
      end
      if best then
        absorb(best,b,false)
        best.carriers=(best.carriers or 0)+1
      else
        absorb(group(b,"carrier-"..b.id),b,true)
      end
    end
    for _,g in ipairs(list) do
      g.id="c@"..g.box[1]..","..g.box[2]
      for _,b in ipairs(g.members) do b.cluster=g.id end
    end
    return list
  end
  local function has_item(b,item)
    for _,k in ipairs{"feeds","eats"} do
      for _,l in ipairs(b[k] or {}) do if l.item==item then return true end end
    end
    local f=b.flow
    if f and (f.made or {})[item] then return true end
    return (b.n or {})[item]~=nil
  end
  -- Trim the boilerplate, not the meaning: `counted` stays even at 0, because 0 counted is
  -- "this block has no machine that can count", which is not the same fact as no flow at
  -- all. Window length is one number for the whole reply, never one per block.
  local function thin(b)
    local f=b.flow
    if f then
      b.flow={made=keep(f.made or {}),active=keep(f.active or {}),
              counted=f.counted,samples=f.samples}
    end
    return b
  end
  function M.ledger(nonce,r)
    local out,edges,seen={}, {}, {}
    for _,id in ipairs(sorted_keys(jobs())) do
      local j=jobs()[id]
      if (j.placed or j.state=="building" or j.state=="settling" or j.state=="auditing")
          and not gone(j) then
        local n={}
        for _,e in ipairs(j.layout) do n[e.name]=(n[e.name] or 0)+1 end
        local _,miss=own_entities(j)
        local st=j.state
        if st=="needs-attention" or miss>0 then st="attention"
        elseif st=="verified" then st=j.audit and j.audit.status=="passed" and "verified" or "unverified" end
        out[#out+1]=entry(id,j.block,{status=st,box=box_of(j.layout),n=n,missing=miss>0 and miss or nil,
          error=j.error,pattern_id=j.pattern_id,tick=j.last_mutation,flow=flow_of(id)})
      end
    end
    for _,id in ipairs(sorted_keys(hands())) do
      local h=hands()[id]
      local surface=game.get_surface(h.surface)
      local n={}
      for _,e in pairs(surface and surface.find_entities_filtered{area={{h.box[1],h.box[2]},{h.box[3],h.box[4]}},
        force=h.force} or {}) do
        if e.type~="character" then n[e.name]=(n[e.name] or 0)+1 end
      end
      out[#out+1]=entry(id,h,{status="declared",box=h.box,n=n,tick=h.tick,flow=flow_of(id)})
    end
    -- Directed edges producer -> consumer from both sides' declarations. `declared` is the
    -- agent's own per_minute on the link; `measured` is what the producer block actually
    -- finished in its last closed window, so the two can disagree and that is the point.
    for _,b in ipairs(out) do
      for _,k in ipairs{"feeds","eats"} do
        for _,l in ipairs(b[k] or {}) do
          if l.block then
            local a,c=b.id,l.block
            if k=="eats" then a,c=c,a end
            local key=a..">"..c..">"..(l.item or "")
            local e=seen[key]
            if not e then
              e={from=a,to=c,item=l.item}
              seen[key]=e edges[#edges+1]=e
            end
            e.declared=e.declared or l.per_minute
          end
        end
      end
    end
    -- An endpoint that is not a live block is a typo or a block that has since gone. Say so,
    -- or a declared link to nothing reads exactly like a producer that made nothing.
    local live={}
    for _,b in ipairs(out) do live[b.id]=true end
    for _,e in ipairs(edges) do
      if not (live[e.from] and live[e.to]) then e.missing_block=true end
      local f=flow_of(e.from)
      if f and e.item then
        -- Only a block that HAS a counting machine can measure 0. A drill or belt block
        -- carries no products_finished, so 0 there is "not measurable", and printing it
        -- next to `declared` reads exactly like a producer that made nothing.
        if (f.counted or 0)>0 then e.measured=f.made[e.item] or 0
        else e.uncounted=true end
      end
    end
    local groups=clusters_of(out)
    local detail=r.detail or "roll"
    local only=r.only or {}
    if detail=="roll" then
      local by_status,bad,cl,eprob={},{},{},{}
      for _,b in ipairs(out) do
        by_status[b.status]=(by_status[b.status] or 0)+1
        if b.status=="attention" then
          bad[#bad+1]={id=b.id,cluster=b.cluster,error=b.error,missing=b.missing}
        end
      end
      for _,g in ipairs(groups) do
        cl[#cl+1]={id=g.id,name=g.name,box=g.box,blocks=g.blocks,
          attention=g.attention>0 and g.attention or nil,
          carriers=g.carriers,makes=keep(g.makes),machines=keep(g.n)}
      end
      for _,e in ipairs(edges) do
        if e.missing_block or e.uncounted
            or (e.declared and e.measured and e.measured<e.declared*0.5) then
          eprob[#eprob+1]=e
        end
      end
      return ctx.response(nonce,true,{detail="roll",blocks=#out,by_status=by_status,
        clusters=cl,attention=bad,edges={total=#edges,problems=keep(eprob)},
        flow_ticks=flow_window()})
    end
    local pick={}
    for _,b in ipairs(out) do
      if (not only.id or b.id==only.id)
          and (not only.status or b.status==only.status)
          and (not only.cluster or b.cluster==only.cluster)
          and (not only.item or has_item(b,only.item)) then pick[#pick+1]=b end
    end
    if detail=="one" then
      local b=pick[1]
      if not b then return ctx.response(nonce,false,{error="block-not-found"}) end
      local mine={}
      for _,e in ipairs(edges) do if e.from==b.id or e.to==b.id then mine[#mine+1]=e end end
      return ctx.response(nonce,true,{detail="one",block=b,edges=mine,flow_ticks=flow_window()})
    end
    local off=math.max(0,math.floor(tonumber(r.offset) or 0))
    local page,on={},{}
    for i=off+1,math.min(off+ROWS_PAGE,#pick) do
      page[#page+1]=thin(pick[i]) on[pick[i].id]=true
    end
    -- Only the links that touch this page: a filtered read must not drag the whole graph.
    local mine={}
    for _,e in ipairs(edges) do if on[e.from] or on[e.to] then mine[#mine+1]=e end end
    return ctx.response(nonce,true,{detail="rows",total=#pick,blocks=page,edges=keep(mine),
      next_offset=(off+#page<#pick) and (off+#page) or nil,flow_ticks=flow_window()})
  end

  -- Update intent of a block (job or hand), or register a hand-built area as a new block.
  function M.note(nonce,r)
    local b,err=parse_block(r.block)
    if not b then return ctx.response(nonce,false,{error=err or "block-required"}) end
    local target=b.id and (jobs()[b.id] and jobs()[b.id].block or hands()[b.id])
    if b.id and not target then
      if not jobs()[b.id] then return ctx.response(nonce,false,{error="block-not-found"}) end
      target={} jobs()[b.id].block=target
    end
    if not target then
      if not (finite(r.x1) and finite(r.y1) and finite(r.x2) and finite(r.y2)) then
        return ctx.response(nonce,false,{error="block-id-or-area-required"})
      end
      local s=ctx.state() s.ledger_seq=(s.ledger_seq or 0)+1
      b.id="hand-"..s.ledger_seq
      target={surface=r.surface or "nauvis",force=r.force or "player",tick=game.tick,
        box={math.min(r.x1,r.x2),math.min(r.y1,r.y2),math.max(r.x1,r.x2),math.max(r.y1,r.y2)}}
      hands()[b.id]=target
    end
    for _,k in ipairs(INTENT) do if b[k]~=nil then target[k]=b[k] end end
    return ctx.response(nonce,true,{id=b.id,block=target})
  end

  return flow_tick
end
