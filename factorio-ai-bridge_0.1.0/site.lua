-- Executor geometry: layout decode/orient, power + pipe + inserter gap checks, site search.
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

-- Blueprint settings a re-placed ghost would lose (23/09: drain() re-placed a whole
-- 243-row job by name only; every underground came back "input", filters vanished).
local function settings_of(e)
  local s={ug=e.type,filters=e.filters,use_filters=e.use_filters,sfilter=e.filter,
    oprio=e.output_priority,iprio=e.input_priority}
  return next(s) and s or nil
end
local function apply_settings(ent,s)
  if not (s and ent and ent.valid) then return end
  if s.filters then pcall(function()
    ent.use_filters=true
    for _,f in ipairs(s.filters) do ent.set_filter(f.index,f.name) end
  end) end
  if s.sfilter then pcall(function() ent.splitter_filter=s.sfilter end) end
  if s.oprio then pcall(function() ent.splitter_output_priority=s.oprio end) end
  if s.iprio then pcall(function() ent.splitter_input_priority=s.iprio end) end
end

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
  -- The 64 was this module's own limit, not the engine's: control.lua guards the import
  -- at the same 1000. Ghost mode places one ghost per entity at 12 per tick, so a whole
  -- starter base is one paste instead of a hand-cut pile of jobs.
  if not ok or not es or #es==0 or #es>1000 then return nil,"unsupported-blueprint" end
  local out={}
  for _,e in ipairs(es) do
    local p=prototypes.entity[e.name]
    local item=p and p.items_to_place_this and p.items_to_place_this[1]
    if not item then return nil,"entity-has-no-place-item:"..tostring(e.name) end
    out[#out+1]={name=e.name,x=e.position.x,y=e.position.y,dir=e.direction or 0,
      w=p.tile_width,h=p.tile_height,item=item.name,count=item.count,
      recipe=type(e.recipe)=="string" and e.recipe or nil,set=settings_of(e)}
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
    out[i]={name=e.name,x=x,y=y,dir=dir,w=w,h=h,item=e.item,count=e.count,recipe=e.recipe,set=e.set}
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
  for i,e in ipairs(shape) do out[i]={name=e.name,x=ax+e.x,y=ay+e.y,dir=e.dir,w=e.w,h=e.h,recipe=e.recipe,set=e.set} end
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
-- One request = one snapshot. The tick key alone went stale 23/09: a dry run's `unpowered`
-- warning cached an empty set, then a grid built in the same tick read as dead.
local function reset_live() live_cache={} end
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
local NATURAL={"tree","simple-entity"}
local function in_footprint(surface,e,types)
  local d=0.01
  return surface.find_entities_filtered{area={{e.x-e.w/2+d,e.y-e.h/2+d},{e.x+e.w/2-d,e.y+e.h/2-d}},type=types}
end

-- Cliffs and water block a build the way a tree does; the difference is that clearing them
-- costs items. One cliff-explosives per cliff -- the real capsule clears several at once,
-- so a job paying per cliff can never underpay -- and one landfill per water tile. Neither
-- is an option until the recipe is unlocked or the item is already in the bag, and that
-- gate is what keeps an early plan off a lake instead of parking on one forever.
local function affordable(force,stock,item)
  if stock and stock.get_item_count{name=item,quality="normal"}>0 then return true end
  local r=force.recipes[item]
  return (r and r.enabled) and true or false
end

-- Fluid tiles under an entity's footprint, as "x:y" keys. `prototype.fluid` is how the
-- rest of the bridge reads water (control.lua fluid_tile_names, field.lua:84).
local function water_keys(surface,e,into)
  local t=into or {}
  for x=math.floor(e.x-e.w/2),math.ceil(e.x+e.w/2)-1 do
    for y=math.floor(e.y-e.h/2),math.ceil(e.y+e.h/2)-1 do
      local tile=surface.get_tile(x,y)
      if tile.valid and tile.prototype.fluid then t[x..":"..y]=true end
    end
  end
  return t
end

-- Inserter ends: pickup and drop tiles must hold something that takes/gives items,
-- planned in this layout or already built (own force).
local RECEIVERS={"transport-belt","underground-belt","splitter","loader","loader-1x1","linked-belt",
  "container","logistic-container","infinity-container","furnace","assembling-machine","lab",
  "mining-drill","boiler","burner-generator","reactor","rocket-silo","ammo-turret","artillery-turret",
  "car","cargo-wagon","locomotive","artillery-wagon","spider-vehicle","agricultural-tower",
  "roboport"}
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
        -- A standing ghost of a receiver counts: it WILL exist. skip_locked (peer 21/09) keeps
        -- exactly those ghosts, e.g. every assembling-machine-2 a feed layer's inserters face.
        if not hit and surface.count_entities_filtered{position={px,py},force=force,type=RECEIVERS,limit=1}==0
          and surface.count_entities_filtered{position={px,py},force=force,ghost_type=RECEIVERS,limit=1}==0 then
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

-- Side joins of planned belts. 23/09 exec-208 fed a belt head from the side: with nothing
-- behind the target that is a CURVE (both lanes pass), not a sideload, and iron filled the
-- lane the steel output needed. Warning only: lane = compass side the items land on.
local COMPASS={[0]="N",[4]="E",[8]="S",[12]="W"}
local function lane_joins(surface,force,placed)
  local function belt(x,y)
    for _,e in ipairs(placed) do
      if covers(e,x,y) then return prototypes.entity[e.name].type,e.dir or 0 end
    end
    local f=surface.find_entities_filtered{area={{x-0.4,y-0.4},{x+0.4,y+0.4}},
      type={"transport-belt","underground-belt","splitter"},force=force,limit=1}[1]
    if f then return f.type,f.direction end
  end
  local out
  for _,p in ipairs(placed) do
    local v=DIRV[p.dir or 0]
    if v and prototypes.entity[p.name].type=="transport-belt" then
      local tx,ty=p.x+v[1],p.y+v[2]
      local tt,td=belt(tx,ty)
      if tt=="transport-belt" and td~=p.dir and td~=(p.dir+8)%16 then
        local b=DIRV[td]
        local bt,bd=belt(tx-b[1],ty-b[2])
        local side=(p.dir+8)%16
        local kind=(bt and bd==td) and "sideload" or "curve"
        out=out or {}
        if #out<12 then out[#out+1]={from={p.x,p.y},to={tx,ty},kind=kind,
          lane=kind=="curve" and "both" or COMPASS[side]} end
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

-- One row per entity is the right thing to WRITE (the receipt on disk keeps it) and the
-- wrong thing to READ: a 508-entity job spends ~15800 characters repeating the same belt
-- coordinates on every poll, and the reader only ever needs the counts and the footprint.
-- `detail=true` still returns the rows for a caller that wants them.
local function layout_digest(layout)
  if not layout or #layout==0 then return nil end
  local names,x1,y1,x2,y2={},math.huge,math.huge,-math.huge,-math.huge
  for _,e in ipairs(layout) do
    names[e.name]=(names[e.name] or 0)+1
    x1=math.min(x1,e.x) y1=math.min(y1,e.y) x2=math.max(x2,e.x) y2=math.max(y2,e.y)
  end
  return {count=#layout,entities=names,bbox={x1,y1,x2,y2}}
end

-- Every whole tile an entity covers, as "x:y" keys. Used to keep two parked plans off
-- each other: ghosts do not collide, so can_place_entity says nothing about a tile another
-- job has already claimed.
local function tile_keys(e,into)
  local t=into or {}
  for x=math.floor(e.x-e.w/2),math.ceil(e.x+e.w/2)-1 do
    for y=math.floor(e.y-e.h/2),math.ceil(e.y+e.h/2)-1 do t[x..":"..y]=true end
  end
  return t
end

local function check_site(surface,force,c,placed,rejects)
  local function no(reason) rejects[reason]=(rejects[reason] or 0)+1 return false end
  if c.reserved then
    for _,e in ipairs(placed) do
      for k in pairs(tile_keys(e)) do
        if c.reserved[k] then return no("job") end
      end
    end
  end
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
        if o.type=="character" then chars=chars+1 else
          blocked=true
          -- "occupied: 1" without a tile is a treasure hunt; name what is in the way.
          rejects.at=rejects.at or {}
          if #rejects.at<8 then rejects.at[#rejects.at+1]={o.name,o.position.x,o.position.y} end
        end
      end
    end
    -- A player standing in the way blocks too; name it so the agent moves, not the site.
    -- Ghost mode on an agent-chosen site keeps going: the engine drops the entities whose
    -- tiles are taken, drain() lists them, and the rest of the plan still lands.
    if blocked and not (c.ghost and c.exact) then return no("occupied") end
    -- A character is the one blocker that walks away by itself, so in ghost mode it is
    -- news, not a refusal: the ghosts land under it and drain() waits for the tile.
    if chars>0 then
      if not (c.ghost and c.exact) then return no("character") end
      rejects.characters=(rejects.characters or 0)+chars
    end
  end
  if surface.count_entities_filtered{position={(x1+x2)/2,(y1+y2)/2},radius=c.enemy_radius or 16,
    force="enemy",limit=1}>0 then return no("enemies") end
  for _,e in ipairs(placed) do
    if not surface.can_place_entity{name=e.name,position={e.x,e.y},direction=e.dir,force=force,
      build_check_type=defines.build_check_type.manual} then
      -- Cliff and water are rejects only when the base cannot pay to clear them; the job
      -- blasts and fills before it builds. `can_blast`/`can_fill` are stamped on the
      -- contract by the caller, which is the only place a treasury is in reach.
      local cliffed=#in_footprint(surface,e,"cliff")>0
      local flooded=next(water_keys(surface,e))~=nil
      if cliffed and not c.can_blast then return no("cliff") end
      if flooded and not c.can_fill then return no("water") end
      if not (cliffed or flooded) then
        -- Blocked only by clearable nature: a forced ghost check ignores deconstructible trees/rocks.
        if #in_footprint(surface,e,NATURAL)==0 or not surface.can_place_entity{name=e.name,position={e.x,e.y},
          direction=e.dir,force=force,build_check_type=defines.build_check_type.blueprint_ghost,forced=true} then
          if not (c.ghost and c.exact) then return no("collision") end
        end
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

return {
  MAX_CHECKS = MAX_CHECKS,
  MAX_WINDOWS = MAX_WINDOWS,
  METRICS = METRICS,
  MIN_WINDOWS = MIN_WINDOWS,
  NATURAL = NATURAL,
  ROTATIONS = ROTATIONS,
  affordable = affordable,
  apply_settings = apply_settings,
  check_site = check_site,
  decode = decode,
  fed_poles = fed_poles,
  find_site = find_site,
  finite = finite,
  in_footprint = in_footprint,
  inserter_gaps = inserter_gaps,
  lane_joins = lane_joins,
  layout_digest = layout_digest,
  list = list,
  orient = orient,
  pipe_gaps = pipe_gaps,
  place_list = place_list,
  placed_at = placed_at,
  pole_covers = pole_covers,
  reset_live = reset_live,
  sorted_keys = sorted_keys,
  tile_keys = tile_keys,
  water_keys = water_keys,
}
