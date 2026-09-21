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
      recipe=type(e.recipe)=="string" and e.recipe or nil}
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
    out[i]={name=e.name,x=x,y=y,dir=dir,w=w,h=h,item=e.item,count=e.count,recipe=e.recipe}
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
  for i,e in ipairs(shape) do out[i]={name=e.name,x=ax+e.x,y=ay+e.y,dir=e.dir,w=e.w,h=e.h,recipe=e.recipe} end
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
  local c={resources={},primer={},feeds={},rotations={},connect={},supply={}}
  local site=type(raw.site)=="table" and raw.site or {}
  c.exact=site.mode=="exact"
  local build=type(raw.build)=="table" and raw.build or {}
  if build.mode~=nil and build.mode~="ghost" and build.mode~="direct" then return nil,"invalid-build-mode" end
  c.ghost=build.mode=="ghost"
  -- Partial unlock (peer 21/09): a pasted base with assembling-machine-2 ghosts interleaved
  -- in the belts that feed them. Locked items leave the plan instead of blocking it; their
  -- ghosts stay standing for after the research.
  c.skip_locked=build.skip_locked==true
  -- Bots mode (peer 21/09): the ghosts are the whole job. No bag gathering, no revive, no
  -- debit: construction robots build them from the logistic network, and the job only
  -- watches its layout fill in. Ghost mode only.
  if build.revive==false then
    if not c.ghost then return nil,"revive-false-needs-ghost-mode" end
    c.bots=true
  end
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
  -- Supply chests, maintainer 20/09: a job that waits for materials pulls from THESE chests and
  -- nowhere else. Without them the restock loop takes nothing: a parked ghost plan must
  -- never quietly drain the coal a running base is eating.
  for _,v in ipairs(list(raw.supply)) do
    if type(v.x)~="number" or type(v.y)~="number" or not finite(v.x) or not finite(v.y) then
      return nil,"invalid-supply"
    end
    if #c.supply>=8 then return nil,"too-many-supply-chests" end
    c.supply[#c.supply+1]={x=v.x,y=v.y}
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
  local function summary(j,detail)
    return {job_id=j.id,state=j.state,pattern_id=j.pattern_id,site=j.site,
      step=math.min(j.step,#(j.steps or {})),steps=#(j.steps or {}),placed=j.placed,materials=j.materials,
      missing=j.missing,audit=j.audit,feed=j.feed,error=j.error,artifact=j.artifact,cleared=j.cleared,block=j.block,
      pending=j.pending,waiting=j.waiting,blocked=j.blocked,standing=j.standing,
      -- placed = tiles that hold the right entity now; built = the ones THIS job revived
      -- and paid for; existing = the ones that were already standing.
      built=j.built,existing=j.existing,replaced=j.replaced,replaced_at=j.replaced_at,
      skipped=j.skipped,skipped_locked=j.skipped_locked,bots=j.bots,uncovered=j.uncovered,restocked=j.restocked,drift=j.drift,
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
    -- Parked plans are the point of ghost mode (maintainer 20/09), so a live job no longer
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
        bots=c.bots or nil,uncovered=uncovered})
    end
    local state=ctx.state() state.executor_seq=(state.executor_seq or 0)+1
    local id="exec-"..state.executor_seq
    local j={id=id,pattern_id=r.pattern_id,blueprint=r.blueprint,contract_raw=r.contract,
      request={x=r.x,y=r.y},
      surface=surface.name,force=force.name,player=owner.index,site=site_out,
      layout=place_list(site.shape,site.x,site.y),contract=c,metrics=c.metrics,
      feeds=c.feeds,max_windows=c.max_windows,materials=cost,steps=steps,step=1,
      receipts={},feed={},state="preparing",block=block,skipped_locked=skipped_locked,
      bots=c.bots or nil,uncovered=uncovered,artifact="executor/"..id,deadline=game.tick+18000}
    jobs()[id]=j save(j)
    return ctx.response(nonce,true,summary(j,r.detail))
  end

  -- Ghosts show where build_blueprint really lands; return the corrected position.
  local GHOST_PER_TICK=12

  -- A parked ghost plan restocks itself: every RESTOCK_TICKS it asks its declared supply
  -- chests for exactly what drain() said it was waiting for. No supply chests = takes
  -- nothing, which is the safe default (maintainer 20/09, option A). A collect that comes up
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
          if near.valid and near.ghost_name==e.name
              and (math.abs(near.position.x-e.x)>0.01 or math.abs(near.position.y-e.y)>0.01) then
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
              position={e.x,e.y},direction=e.dir,force=force,recipe=recipe}
          end)
          return okg and made or nil
        end
        -- `recipe` on a ghost is not accepted for every prototype; losing the recipe is
        -- better than losing the entity, and drain() sets it again after revive.
        local made=ghost_at(e.recipe) or (e.recipe and ghost_at(nil))
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
            -- Cliffs and water: the other two natural blockers (maintainer 20/09). Both are
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
                if stock.get_item_count{name=name,quality="normal"}<n then error("materials-changed:"..name) end
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
