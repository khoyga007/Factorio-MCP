-- Executor contract parsing: block intent + job contract (site, primer, feed, verify).
local site = require("site")
local MAX_CHECKS, MAX_WINDOWS, METRICS, MIN_WINDOWS = site.MAX_CHECKS, site.MAX_WINDOWS, site.METRICS, site.MIN_WINDOWS
local ROTATIONS, finite, list = site.ROTATIONS, site.finite, site.list

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
  -- absolute (23/09): the design rows ARE world positions; the anchor is derived from
  -- site.ref (the first row's own position) instead of hand floor(min corner) math.
  c.absolute=site.mode=="absolute"
  if c.absolute and (type(site.ref)~="table" or not finite(site.ref.x) or not finite(site.ref.y)) then
    return nil,"absolute-site-needs-ref"
  end
  c.ref=c.absolute and {x=site.ref.x,y=site.ref.y} or nil
  c.exact=site.mode=="exact" or c.absolute
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
  -- Supply chests (20/09): a job that waits for materials pulls from THESE chests and
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


return {
  parse_block = parse_block,
  parse_contract = parse_contract,
}
