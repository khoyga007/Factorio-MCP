-- Generic blueprint executor. The agent declares a contract (site, resource,
-- primer, feed, verify); this module only checks, gathers, builds and audits.
-- Site search and holdout rules: reference/PORTING.md sections 1 and 5.
local M = {}
local MAX_CHECKS, MAX_WINDOWS, MIN_WINDOWS = 20000, 8, 2
local ROTATIONS = {[0]=true,[4]=true,[8]=true,[12]=true}
local METRICS = {container_gain=true, working_count=true, electric_output_mw=true,
  products_finished=true, research_units=true,
  fluid_temperature=true, fuel_min=true}

local function finite(n) return type(n)=="number" and n==n and math.abs(n)<1000000 end
local function sorted_keys(t)
  local keys={} for k in pairs(t) do keys[#keys+1]=k end table.sort(keys) return keys
end
local function list(v) return type(v)=="table" and v or {} end

-- Blueprint -> entities normalised so the footprint's top-left tile corner is (0,0).
local function decode(value)
  if type(value)~="string" or #value>24000 then return nil,"invalid-blueprint" end
  local inv=game.create_inventory(1)
  local ok,es=pcall(function()
    local stack=inv[1]
    if stack.import_stack(value)~=0 or stack.name~="blueprint" then return nil end
    local tiles=stack.get_blueprint_tiles()
    if tiles and #tiles>0 then return nil end
    return stack.get_blueprint_entities()
  end)
  inv.destroy()
  if not ok or not es or #es==0 or #es>64 then return nil,"unsupported-blueprint" end
  local out={}
  for _,e in ipairs(es) do
    local p=prototypes.entity[e.name]
    local item=p and p.items_to_place_this and p.items_to_place_this[1]
    if not item then return nil,"entity-has-no-place-item:"..tostring(e.name) end
    out[#out+1]={name=e.name,x=e.position.x,y=e.position.y,dir=e.direction or 0,
      w=p.tile_width,h=p.tile_height,item=item.name,count=item.count}
  end
  return out
end

-- Rotate clockwise by r (16-way units), then shift so min corner is (0,0).
local function orient(es,r)
  local q=(r/4)%4
  local out,min_x,min_y={},math.huge,math.huge
  for i,e in ipairs(es) do
    local x,y=e.x,e.y
    for _=1,q do x,y=-y,x end
    local dir=(e.dir+r)%16
    local w,h=e.w,e.h
    if dir%8~=0 then w,h=h,w end
    out[i]={name=e.name,x=x,y=y,dir=dir,w=w,h=h,item=e.item,count=e.count}
    min_x=math.min(min_x,x-w/2) min_y=math.min(min_y,y-h/2)
  end
  local max_x,max_y=0,0
  for _,e in ipairs(out) do
    e.x,e.y=e.x-min_x,e.y-min_y
    max_x=math.max(max_x,e.x+e.w/2) max_y=math.max(max_y,e.y+e.h/2)
  end
  return out,max_x,max_y
end

local function place_list(shape,ax,ay)
  local out={}
  for i,e in ipairs(shape) do out[i]={name=e.name,x=ax+e.x,y=ay+e.y,dir=e.dir,w=e.w,h=e.h} end
  return out
end

local function tile_area(cx,cy,r)
  return math.floor(cx-r+0.01),math.floor(cy-r+0.01),math.ceil(cx+r-0.01)-1,math.ceil(cy+r-0.01)-1
end

-- Prototype reach, via the 2.0 getters when they exist.
local function supply_d(proto)
  local ok,d=pcall(function() return proto.get_supply_area_distance() end)
  if not ok then d=proto.supply_area_distance end
  return d or 0
end
local function wire_d(proto)
  local ok,d=pcall(function() return proto.get_max_wire_distance() end)
  if not ok then d=proto.max_wire_distance end
  return d or 0
end
local function covers(px,py,d,e)
  return math.abs(px-e.x)<d+e.w/2 and math.abs(py-e.y)<d+e.h/2
end

-- Electric networks that actually have a live source. A pole on any other network is an
-- island: what it covers will never run. Whole-surface scan, so memoised per tick.
local PRODUCERS={"generator","burner-generator","solar-panel","electric-energy-interface",
  "fusion-generator","accumulator"}
local PRODUCER={} for _,t in ipairs(PRODUCERS) do PRODUCER[t]=true end
local live_cache={}
local function live_networks(surface,force)
  local key=surface.index..":"..force.index
  local c=live_cache[key]
  if c and c.tick==game.tick then return c.set end
  local set={}
  for _,g in pairs(surface.find_entities_filtered{force=force,type=PRODUCERS}) do
    if g.electric_network_id and (g.type~="accumulator" or g.energy>0) then
      set[g.electric_network_id]=true
    end
  end
  live_cache[key]={tick=game.tick,set=set}
  return set
end

-- Which poles can actually carry power to this layout. Nodes are the layout's own poles
-- plus every own-force pole near it; a node is fed when it sits on a network that already
-- has a live source, when its supply area covers a producer THIS layout brings (a steam
-- build powers its own substation), or when wire reach links it to a fed node.
-- The old check accepted ANY pole in the layout, so a design carrying its own pole always
-- passed the pre-check (and dry_run) and only failed AFTER the build, with the machines
-- already on the ground.
local NEAR=32
local function fed_poles(surface,force,planned)
  local live=live_networks(surface,force)
  local x1,y1,x2,y2=math.huge,math.huge,-math.huge,-math.huge
  local nodes={}
  for _,p in ipairs(planned) do
    x1=math.min(x1,p.x) y1=math.min(y1,p.y) x2=math.max(x2,p.x) y2=math.max(y2,p.y)
    local proto=prototypes.entity[p.name]
    if proto.type=="electric-pole" then
      nodes[#nodes+1]={x=p.x,y=p.y,w=wire_d(proto),s=supply_d(proto),fed=false}
    end
  end
  for _,x in pairs(surface.find_entities_filtered{force=force,type="electric-pole",
    area={{x1-NEAR,y1-NEAR},{x2+NEAR,y2+NEAR}}}) do
    nodes[#nodes+1]={x=x.position.x,y=x.position.y,w=wire_d(x.prototype),s=supply_d(x.prototype),
      fed=live[x.electric_network_id] or false}
  end
  for _,q in ipairs(nodes) do
    if not q.fed then
      for _,g in ipairs(planned) do
        if PRODUCER[prototypes.entity[g.name].type] and covers(q.x,q.y,q.s,g) then q.fed=true break end
      end
    end
  end
  -- Spread along wire runs until nothing new is reached.
  local moved=true
  while moved do
    moved=false
    for _,a in ipairs(nodes) do
      if a.fed then
        for _,b in ipairs(nodes) do
          if not b.fed then
            local r=math.min(a.w,b.w)
            if (a.x-b.x)^2+(a.y-b.y)^2<=r*r then b.fed=true moved=true end
          end
        end
      end
    end
  end
  return nodes
end

-- A live pole covers the planned entity (pre-build power check).
local function pole_covers(nodes,e)
  for _,q in ipairs(nodes) do
    if q.fed and covers(q.x,q.y,q.s,e) then return true end
  end
  return false
end

-- One resource rule against one placed entity. Returns reject reason or nil.
local function resource_ok(surface,e,rule)
  local p=prototypes.entity[e.name]
  local r=p.mining_drill_radius or math.max(e.w,e.h)/2
  local x1,y1,x2,y2=tile_area(e.x,e.y,r)
  local found,total={},0
  for _,ore in pairs(surface.find_entities_filtered{area={{x1,y1},{x2+1,y2+1}},type="resource"}) do
    if ore.name~=rule.resource then
      if rule.exclusive~=false then return "foreign-resource" end
    else
      found[math.floor(ore.position.x)..":"..math.floor(ore.position.y)]=ore.amount
      total=total+ore.amount
    end
  end
  if rule.full_cover~=false then
    for tx=x1,x2 do for ty=y1,y2 do
      local n=found[tx..":"..ty]
      if not n or n<(rule.min_per_tile or 1) then return "resource-cover" end
    end end
  elseif total==0 then return "resource-cover" end
  if total<(rule.min_total or 0) then return "resource-reserve" end
end

-- Trees/rocks on an entity's tiles are mined before build (products -> bag, receipts).
-- Cliffs are never cleared: they need cliff explosives.
local NATURAL={"tree","simple-entity"}
local function in_footprint(surface,e,types)
  local d=0.01
  return surface.find_entities_filtered{area={{e.x-e.w/2+d,e.y-e.h/2+d},{e.x+e.w/2-d,e.y+e.h/2-d}},type=types}
end

-- Inserter ends: pickup and drop tiles must hold something that takes/gives items,
-- planned in this layout or already built (own force).
local RECEIVERS={"transport-belt","underground-belt","splitter","loader","loader-1x1","linked-belt",
  "container","logistic-container","infinity-container","furnace","assembling-machine","lab",
  "mining-drill","boiler","burner-generator","reactor","rocket-silo","ammo-turret","artillery-turret",
  "car","cargo-wagon","locomotive","artillery-wagon","spider-vehicle","agricultural-tower"}
local RECEIVER={} for _,t in ipairs(RECEIVERS) do RECEIVER[t]=true end
local function turn(x,y,q) for _=1,q%4 do x,y=-y,x end return x,y end
local function covers(e,px,py) return math.abs(px-e.x)<e.w/2 and math.abs(py-e.y)<e.h/2 end
local function receives(e) return RECEIVER[prototypes.entity[e.name].type] end

local function gaps_of(surface,force,placed)
  local out={}
  for _,ins in ipairs(placed) do
    local proto=prototypes.entity[ins.name]
    if proto.type=="inserter" then
      for side,v in pairs{pickup=proto.inserter_pickup_position,drop=proto.inserter_drop_position} do
        -- Prototype vectors are for direction 0 (north = pickup side); rotate clockwise by dir.
        local vx,vy=turn(v[1] or v.x,v[2] or v.y,ins.dir/4)
        local px,py=math.floor(ins.x+vx)+0.5,math.floor(ins.y+vy)+0.5
        local hit=false
        for _,e in ipairs(placed) do
          if e~=ins and receives(e) and covers(e,px,py) then hit=true break end
        end
        if not hit and surface.count_entities_filtered{position={px,py},force=force,type=RECEIVERS,limit=1}==0 then
          out[#out+1]={ins=ins,side=side,px=px,py=py}
        end
      end
    end
  end
  table.sort(out,function(a,b)
    if a.ins.y~=b.ins.y then return a.ins.y<b.ins.y end
    if a.ins.x~=b.ins.x then return a.ins.x<b.ins.x end return a.side<b.side
  end)
  return out
end

-- Unconnected inserter ends, each with a hint when exactly one planned receiver one tile
-- away would cover the tile AND moving it lowers the total gap count. Never auto-moved.
local function inserter_gaps(surface,force,placed,rotation)
  local raw,out=gaps_of(surface,force,placed),{}
  for _,g in ipairs(raw) do
    local gap={inserter={g.ins.x,g.ins.y},side=g.side,tile={g.px,g.py}}
    local cands={}
    for _,e in ipairs(placed) do
      if e~=g.ins and receives(e) then
        for _,d in ipairs{{1,0},{-1,0},{0,1},{0,-1}} do
          if covers({x=e.x+d[1],y=e.y+d[2],w=e.w,h=e.h},g.px,g.py) then cands[#cands+1]={e=e,d=d} end
        end
      end
    end
    if #cands==1 then
      local c=cands[1]
      local moved={}
      for i,e in ipairs(placed) do
        moved[i]=e==c.e and {name=e.name,x=e.x+c.d[1],y=e.y+c.d[2],dir=e.dir,w=e.w,h=e.h} or e
      end
      local m,clash=moved[1],false
      for i,e in ipairs(placed) do
        if e==c.e then m=moved[i] end
      end
      for _,e in ipairs(placed) do
        if e~=c.e and math.abs(e.x-m.x)<(e.w+m.w)/2 and math.abs(e.y-m.y)<(e.h+m.h)/2 then clash=true break end
      end
      if not clash and #gaps_of(surface,force,moved)<#raw then
        local sx,sy=turn(c.d[1],c.d[2],4-rotation/4)
        gap.hint={entity=c.e.name,from={c.e.x,c.e.y},to={c.e.x+c.d[1],c.e.y+c.d[2]},design_shift={sx==0 and 0 or sx,sy==0 and 0 or sy}}
      end
    end
    out[#out+1]=gap
  end
  return out
end

-- Underground pipe pairs. Measured in the engine 20/09 (tests/verify_pipe_runtime.py):
-- pipe-to-ground's prototype carries a "normal" connection facing its own direction and an
-- "underground" connection 8 (180 degrees) away, `max_underground_distance` 10. Two of them
-- link ONLY when each one's underground side points at the other -- dirB == (dirA+8)%16 --
-- on the same row/column, centres at most 10 apart (d=10 links, d=11 does not).
-- Without this check a run that is one tile too long, or an entrance built with the wrong
-- facing, passes dry_run, gets built, and the water silently never arrives.
local DIRV={[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}
local function under_of(name)
  local proto=prototypes.entity[name]
  if not proto or proto.type~="pipe-to-ground" then return nil end
  for _,fb in pairs(proto.fluidbox_prototypes or {}) do
    for _,c in pairs(fb.pipe_connections or {}) do
      if c.connection_type=="underground" then
        return c.direction or 8,c.max_underground_distance or proto.max_underground_distance or 10
      end
    end
  end
  return 8,proto.max_underground_distance or 10
end

local function pipe_gaps(surface,force,placed)
  local out={}
  for _,e in ipairs(placed) do
    local rel,maxd=under_of(e.name)
    if rel then
      local dir=e.dir or 0
      local v=DIRV[(dir+rel)%16]
      if not v then
        out[#out+1]={pipe={e.x,e.y},reason="diagonal-direction",dir=dir}
      else
        local found
        for d=1,maxd do
          local px,py=e.x+v[1]*d,e.y+v[2]*d
          local other
          for _,o in ipairs(placed) do
            if o~=e and o.name==e.name and math.abs(o.x-px)<0.01 and math.abs(o.y-py)<0.01 then
              other=o.dir or 0
            end
          end
          if not other then
            local hit=surface.find_entities_filtered{name=e.name,position={px,py},radius=0.1,force=force}[1]
            if hit and hit.valid then other=hit.direction end
          end
          if other then found={d=d,dir=other,at={px,py}} break end
        end
        if not found then
          out[#out+1]={pipe={e.x,e.y},dir=dir,reason="no-partner",within=maxd}
        elseif found.dir~=(dir+8)%16 then
          -- The first same-name underground down the ray is not facing back: it steals the
          -- pairing, so saying "no partner" would send the agent looking in the wrong place.
          out[#out+1]={pipe={e.x,e.y},dir=dir,reason="wrong-facing",at=found.at,
            found_dir=found.dir,expected_dir=(dir+8)%16}
        end
      end
    end
  end
  return out
end

local function placed_at(layout)
  local out={}
  for i,e in ipairs(layout) do out[i]={e.name,e.x,e.y,e.dir} end
  return out
end

local function check_site(surface,force,c,placed,rejects)
  local function no(reason) rejects[reason]=(rejects[reason] or 0)+1 return false end
  local fed  -- layout poles that reach a live grid, computed once and only if power matters
  local x1,y1,x2,y2=math.huge,math.huge,-math.huge,-math.huge
  for _,e in ipairs(placed) do
    x1=math.min(x1,e.x-e.w/2) y1=math.min(y1,e.y-e.h/2)
    x2=math.max(x2,e.x+e.w/2) y2=math.max(y2,e.y+e.h/2)
  end
  if c.center and ((x1+x2)/2-c.center.x)^2+((y1+y2)/2-c.center.y)^2>c.radius^2 then
    return no("out-of-area")
  end
  local gap=c.clearance or 0
  local box={{x1-gap,y1-gap},{x2+gap,y2+gap}}
  if surface.count_entities_filtered{area=box,force=force,limit=1}>0 then
    -- The bounding box spans every entity, so a design with one far-flung pole reads the
    -- whole base between it and the machines as occupied. The box is only a fast path:
    -- what has to be clear is each entity's own tiles plus the clearance around them.
    local d,blocked,chars=0.01,false,0
    for _,e in ipairs(placed) do
      for _,o in pairs(surface.find_entities_filtered{force=force,
        area={{e.x-e.w/2-gap+d,e.y-e.h/2-gap+d},{e.x+e.w/2+gap-d,e.y+e.h/2+gap-d}}}) do
        if o.type=="character" then chars=chars+1 else blocked=true end
      end
    end
    -- A player standing in the way blocks too; name it so the agent moves, not the site.
    if blocked then return no("occupied") end
    if chars>0 then return no("character") end
  end
  if surface.count_entities_filtered{position={(x1+x2)/2,(y1+y2)/2},radius=c.enemy_radius or 16,
    force="enemy",limit=1}>0 then return no("enemies") end
  for _,e in ipairs(placed) do
    if not surface.can_place_entity{name=e.name,position={e.x,e.y},direction=e.dir,force=force,
      build_check_type=defines.build_check_type.manual} then
      if #in_footprint(surface,e,"cliff")>0 then return no("cliff") end
      -- Blocked only by clearable nature: a forced ghost check ignores deconstructible trees/rocks.
      if #in_footprint(surface,e,NATURAL)==0 or not surface.can_place_entity{name=e.name,position={e.x,e.y},
        direction=e.dir,force=force,build_check_type=defines.build_check_type.blueprint_ghost,forced=true} then
        return no("collision")
      end
    end
    for _,rule in ipairs(c.resources) do
      if rule.entity==e.name then
        local bad=resource_ok(surface,e,rule)
        if bad then return no(bad) end
      end
    end
    for _,rule in ipairs(c.connect) do
      if rule.entity==e.name and rule.power then
        fed=fed or fed_poles(surface,force,placed)
        if not pole_covers(fed,e) then return no("no-power") end
      end
    end
  end
  return true
end

-- Candidate anchors (top-left tile of footprint), nearest first, capped.
local function find_site(surface,force,c,base)
  local rejects,checks={},0
  for _,r in ipairs(c.rotations) do
    local shape,W,H=orient(base,r)
    local anchors,seen={},{}
    local function add(ax,ay)
      local k=ax..":"..ay
      if not seen[k] then seen[k]=true anchors[#anchors+1]={ax,ay} end
    end
    if c.exact then
      add(math.floor(c.center.x),math.floor(c.center.y))
    else
      local rule=c.resources[1]
      local lead
      if rule then for _,e in ipairs(shape) do if e.name==rule.entity then lead=e break end end end
      if lead then
        -- Every full-cover placement has the lead entity's top-left tile on ore.
        local lx,ly=lead.x-lead.w/2,lead.y-lead.h/2
        for _,ore in pairs(surface.find_entities_filtered{position={c.center.x,c.center.y},
          radius=c.radius,name=rule.resource,type="resource"}) do
          add(math.floor(ore.position.x)-lx,math.floor(ore.position.y)-ly)
        end
      else
        local R=math.min(math.floor(c.radius),64)
        for dx=-R,R do for dy=-R,R do
          add(math.floor(c.center.x-W/2)+dx,math.floor(c.center.y-H/2)+dy)
        end end
      end
      local cx,cy=c.center.x-W/2,c.center.y-H/2
      table.sort(anchors,function(a,b)
        local da,db=(a[1]-cx)^2+(a[2]-cy)^2,(b[1]-cx)^2+(b[2]-cy)^2
        if da~=db then return da<db end
        if a[2]~=b[2] then return a[2]<b[2] end return a[1]<b[1]
      end)
    end
    for _,a in ipairs(anchors) do
      checks=checks+1
      if checks>c.max_checks then return nil,rejects,checks,"search-budget-exhausted" end
      local placed=place_list(shape,a[1],a[2])
      if check_site(surface,force,c,placed,rejects) then
        return {x=a[1],y=a[2],rotation=r,shape=shape},rejects,checks
      end
    end
  end
  return nil,rejects,checks,"no-site"
end

-- Validate the agent's contract into a normalised table, or return an error.
-- Ledger intent attached to a block (contract.block or note).
local function text(v,n) return type(v)=="string" and v~="" and #v<=n and v or nil end
local function rate(v) return type(v)=="number" and v==v and v>0 and v<1000000 and v or nil end
local function parse_block(raw)
  if raw==nil then return nil end
  if type(raw)~="table" then return nil,"invalid-block" end
  local b={id=text(raw.id,40),name=text(raw.name,40),role=text(raw.role,120),notes=text(raw.notes,400)}
  for _,k in ipairs{"feeds","eats"} do
    local l=list(raw[k])
    if #l>12 then return nil,"invalid-block-"..k end
    for i,e in ipairs(l) do
      local x=type(e)=="table" and {item=text(e.item,60),block=text(e.block,40),via=text(e.via,80),
        per_minute=rate(e.per_minute)}
      if not x or not (x.item or x.block or x.via) then return nil,"invalid-block-"..k end
      if e.per_minute~=nil and not x.per_minute then return nil,"invalid-block-"..k end
      b[k]=b[k] or {} b[k][i]=x
    end
  end
  return b
end
local function parse_contract(raw,r)
  raw=type(raw)=="table" and raw or {}
  local c={resources={},primer={},feeds={},rotations={},connect={}}
  local site=type(raw.site)=="table" and raw.site or {}
  c.exact=site.mode=="exact"
  c.clearance=tonumber(site.clearance) or 0
  c.enemy_radius=tonumber(site.enemy_radius) or 16
  c.max_checks=math.min(tonumber(site.max_checks) or MAX_CHECKS,MAX_CHECKS)
  if c.clearance<0 or c.clearance>8 or c.enemy_radius<0 or c.enemy_radius>64 then return nil,"invalid-site" end
  for _,v in ipairs(list(site.rotations)) do
    if not ROTATIONS[v] then return nil,"invalid-rotation" end
    c.rotations[#c.rotations+1]=v
  end
  if #c.rotations==0 then c.rotations={0} end
  -- exact = agent already placed water/pole for ONE orientation; spinning would miss them.
  if c.exact and #c.rotations~=1 then return nil,"exact-site-needs-one-rotation" end
  for _,v in ipairs(list(raw.connect)) do
    if type(v.entity)~="string" or not prototypes.entity[v.entity]
      or (v.power~=true)==(type(v.fluid)~="string")
      or (v.fluid and not prototypes.fluid[v.fluid]) then return nil,"invalid-connect" end
    c.connect[#c.connect+1]=v
  end
  for _,v in ipairs(list(raw.resources)) do
    if type(v.entity)~="string" or type(v.resource)~="string" or not prototypes.entity[v.resource] then
      return nil,"invalid-resource-rule"
    end
    c.resources[#c.resources+1]=v
  end
  for _,v in ipairs(list(raw.primer)) do
    if type(v.entity)~="string" or type(v.item)~="string" or not prototypes.item[v.item]
      or type(v.count)~="number" or v.count<1 or v.count>200 or v.count%1~=0 then
      return nil,"invalid-primer"
    end
    c.primer[#c.primer+1]=v
  end
  for _,v in ipairs(list(raw.feeds)) do
    if type(v.from)~="string" or type(v.to)~="string" or type(v.item)~="string"
      or not prototypes.item[v.item] then return nil,"invalid-feed" end
    v.keep=math.max(1,math.min(tonumber(v.keep) or 1,50))
    c.feeds[#c.feeds+1]=v
  end
  local verify=type(raw.verify)=="table" and raw.verify or {}
  c.window_ticks=tonumber(verify.window_ticks) or 3600
  c.max_windows=math.min(tonumber(verify.max_windows) or 5,MAX_WINDOWS)
  c.settle_ticks=tonumber(verify.settle_ticks) or 0
  if c.window_ticks<600 or c.window_ticks>36000 or c.max_windows<MIN_WINDOWS
    or c.settle_ticks<0 or c.settle_ticks>36000 then return nil,"invalid-verify" end
  c.metrics={}
  local load=raw.declared_load_mw
  if load~=nil and (not finite(load) or load<=0) then return nil,"invalid-declared-load" end
  for _,m in ipairs(list(verify.metrics)) do
    local tag=type(m.key)=="string" and ":"..m.key or ""
    if type(m.key)~="string" or not METRICS[m.kind] or type(m.entity)~="string"
      or not prototypes.entity[m.entity] then return nil,"invalid-metric"..tag end
    if m.kind=="container_gain" and (type(m.item)~="string" or not prototypes.item[m.item]) then
      return nil,"invalid-metric-item"..tag
    end
    local etype=prototypes.entity[m.entity].type
    if m.kind=="products_finished" and etype~="furnace" and etype~="assembling-machine" then
      return nil,"invalid-metric-entity"..tag
    end
    if m.kind=="research_units" and etype~="lab" then return nil,"invalid-metric-entity"..tag end
    if m.kind=="fluid_temperature" and m.fluid~=nil and not prototypes.fluid[m.fluid] then
      return nil,"invalid-metric-fluid"..tag
    end
    if m.kind=="working_count" and m.fraction~=nil and (not finite(m.fraction) or m.fraction<=0 or m.fraction>1) then
      return nil,"invalid-metric-fraction"..tag
    end
    -- Power min derives from the declared load: min = load_fraction*min(load, capacity_mw).
    if m.load_fraction~=nil then
      if m.kind~="electric_output_mw" or m.min~=nil or not finite(m.load_fraction)
        or m.load_fraction<=0 or m.load_fraction>1 or (m.capacity_mw~=nil and not finite(m.capacity_mw)) then
        return nil,"invalid-metric-load-fraction"..tag
      end
      if not load then return nil,"declared-load-required"..tag end
      local copy={} for k,v in pairs(m) do copy[k]=v end
      m=copy m.min=m.load_fraction*math.min(load,m.capacity_mw or math.huge)
    end
    if not finite(m.min) then return nil,"invalid-metric-min"..tag end
    c.metrics[#c.metrics+1]=m
  end
  c.center={x=r.x,y=r.y} c.radius=r.radius or 192
  return c
end

function M.attach(ctx)
  local function jobs()
    local s=ctx.state() s.executor_jobs=s.executor_jobs or {} return s.executor_jobs
  end
  local function summary(j)
    return {job_id=j.id,state=j.state,pattern_id=j.pattern_id,site=j.site,
      step=j.step,steps=#(j.steps or {}),placed=j.placed,materials=j.materials,
      missing=j.missing,audit=j.audit,feed=j.feed,error=j.error,artifact=j.artifact,cleared=j.cleared,block=j.block,
      placed_at=j.layout and placed_at(j.layout)}
  end
  local function save(j)
    helpers.write_file(j.artifact..".receipt.json",helpers.table_to_json{
      job=summary(j),contract=j.contract_raw,receipts=j.receipts},false)
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
  local function prepare(surface,force,center,radius,stock,cost)
    local available,steps,missing={}, {}, {}
    for _,s in pairs(stock.get_contents()) do
      if s.quality=="normal" then available[s.name]=(available[s.name] or 0)+s.count end
    end
    local sources=surface.find_entities_filtered{position=center,radius=radius,force=force,
      type={"container","logistic-container","furnace","assembling-machine"}}
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
      if not ensure(item,cost[item],0) then break end
    end
    return steps,missing
  end

  local function built_entities(j)
    local surface=game.get_surface(j.surface)
    local out={}
    for i,e in ipairs(j.layout) do
      local found=surface.find_entity(e.name,{e.x,e.y})
      if not found or not found.valid or found.direction~=e.dir then return nil,i end
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
    local block,berr=parse_block(type(r.contract)=="table" and r.contract.block or nil)
    if berr then return ctx.response(nonce,false,{error=berr}) end
    local cost={}
    for _,e in ipairs(base) do cost[e.item]=(cost[e.item] or 0)+e.count end
    local locked={}
    for name in pairs(cost) do
      local recipe=force.recipes[name]
      if recipe and not recipe.enabled then locked[#locked+1]=name end
    end
    for _,p in ipairs(c.primer) do
      local n=0 for _,e in ipairs(base) do if e.name==p.entity then n=n+1 end end
      if n==0 then return ctx.response(nonce,false,{error="primer-entity-not-in-blueprint",entity=p.entity}) end
      cost[p.item]=(cost[p.item] or 0)+p.count*n
    end
    for _,j in pairs(jobs()) do
      if j.state=="preparing" or j.state=="building" or j.state=="settling" or j.state=="auditing" then
        return ctx.response(nonce,true,summary(j))
      end
    end
    local site,rejects,checks,why=find_site(surface,force,c,base)
    if not site then
      return ctx.response(nonce,true,{state="blocked",error=why,rejects=rejects,checks=checks,materials=cost})
    end
    local steps,missing=prepare(surface,force,c.center,c.radius,stock,cost)
    local site_out={x=site.x,y=site.y,rotation=site.rotation,checks=checks}
    local placed=place_list(site.shape,site.x,site.y)
    local clear=0
    for _,e in ipairs(placed) do clear=clear+#in_footprint(surface,e,NATURAL) end
    if clear>0 then site_out.clear=clear end
    local gaps=inserter_gaps(surface,force,placed,site.rotation)
    if #gaps>0 then
      return ctx.response(nonce,true,{state="blocked",error="inserter-unconnected",unconnected=gaps,
        site=site_out,placed_at=placed_at(placed),materials=cost})
    end
    local pgaps=pipe_gaps(surface,force,placed)
    if #pgaps>0 then
      return ctx.response(nonce,true,{state="blocked",error="pipe-unconnected",unconnected=pgaps,
        site=site_out,placed_at=placed_at(placed),materials=cost})
    end
    if #locked>0 then table.sort(locked) end
    if r.dry_run or next(missing) or #locked>0 then
      return ctx.response(nonce,true,{state=(next(missing) or #locked>0) and "blocked" or "planned",
        site=site_out,site_validated=true,materials=cost,missing=missing,placed_at=placed_at(placed),
        locked=#locked>0 and locked or nil,steps=#steps,rejects=rejects})
    end
    local state=ctx.state() state.executor_seq=(state.executor_seq or 0)+1
    local id="exec-"..state.executor_seq
    local j={id=id,pattern_id=r.pattern_id,blueprint=r.blueprint,contract_raw=r.contract,
      surface=surface.name,force=force.name,player=owner.index,site=site_out,
      layout=place_list(site.shape,site.x,site.y),contract=c,metrics=c.metrics,
      feeds=c.feeds,max_windows=c.max_windows,materials=cost,steps=steps,step=1,
      receipts={},feed={},state="preparing",block=block,artifact="executor/"..id,deadline=game.tick+18000}
    jobs()[id]=j save(j)
    return ctx.response(nonce,true,summary(j))
  end

  -- Ghosts show where build_blueprint really lands; return the corrected position.
  local function aim(j,surface,force)
    local inv=game.create_inventory(1)
    local stack=inv[1] stack.import_stack(j.blueprint)
    local W,H=0,0
    for _,e in ipairs(j.layout) do
      W=math.max(W,e.x+e.w/2-j.site.x) H=math.max(H,e.y+e.h/2-j.site.y)
    end
    local guess={x=j.site.x+W/2,y=j.site.y+H/2}
    local ghosts=stack.build_blueprint{surface=surface,force=force,position=guess,
      direction=j.site.rotation,build_mode=defines.build_mode.normal,raise_built=false}
    inv.destroy()
    local delta
    local e1=j.layout[1]
    for _,g in ipairs(ghosts) do
      if g.valid and g.ghost_name==e1.name and not delta then
        local dx,dy=e1.x-g.position.x,e1.y-g.position.y
        local all=true
        for _,h in ipairs(ghosts) do
          local hit=false
          for _,e in ipairs(j.layout) do
            if e.name==h.ghost_name and math.abs(e.x-h.position.x-dx)<0.01 and math.abs(e.y-h.position.y-dy)<0.01 then hit=true break end
          end
          if not hit then all=false break end
        end
        if all then delta={dx,dy} end
      end
    end
    local n=#ghosts
    for _,g in ipairs(ghosts) do if g.valid then g.destroy() end end
    if n~=#j.layout or not delta then error("blueprint-aim-failed") end
    return guess.x+delta[1],guess.y+delta[2]
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
          if j.state=="preparing" then
            if game.tick>j.deadline then error("job-timeout") end
            if owner.crafting_queue_size>0 then return end
            local s=j.steps[j.step]
            if s then
              if perform(j,s.action,s.body).ok then j.step=j.step+1 end
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
            for name,n in pairs(j.materials) do
              if stock.get_item_count{name=name,quality="normal"}<n then error("materials-changed:"..name) end
            end
            local x,y=aim(j,surface,force)
            local result=perform(j,"import",{blueprint=j.blueprint,x=x,y=y,mode="direct",direction=j.site.rotation})
            j.placed=result.placed
            if not result.ok then save(j) return end
            j.imported=true
            end
            local es,bad=built_entities(j)
            if not es then error("import-geometry-mismatch:"..bad) end
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
          local es,bad=built_entities(j)
          if not es then error("layout-broken:"..bad) end
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
  function flow_tick()
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
    return ctx.response(nonce,true,{blocks=out,edges=edges})
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

  function M.status(nonce,r)
    local j=jobs()[r.job_id]
    if not j then return ctx.response(nonce,false,{error="executor-job-not-found"}) end
    -- A job that fails AFTER the import (infra not connected, a primer insert with no room,
    -- a failed audit) leaves real machines standing. Once the agent has fixed the cause,
    -- resume picks the job up where it stopped: the import and the primer inserts already
    -- done are not repeated, and the holdout clock restarts. Recall + rebuild is the only
    -- other way out, and it pays for the block twice.
    if r.resume then
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
    return ctx.response(nonce,true,summary(j))
  end
  return M
end
return M
