-- Bounded automation for the tested two-drill coal blueprint.
local M = {}
local COST = {["burner-mining-drill"]=2, ["transport-belt"]=6,
  ["burner-inserter"]=1, ["wooden-chest"]=1, coal=3}
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<1000000 end
local function sorted_keys(t)
  local keys={} for k in pairs(t) do keys[#keys+1]=k end table.sort(keys) return keys
end
local function decode(value)
  local inv=game.create_inventory(1)
  local ok,result=pcall(function()
    local stack=inv[1]
    if stack.import_stack(value)~=0 or stack.name~="blueprint" then return nil end
    local es=stack.get_blueprint_entities()
    if not es or #es~=10 or stack.get_blueprint_tiles() then return nil end
    local drills={}
    for _,e in ipairs(es) do if e.name=="burner-mining-drill" then drills[#drills+1]=e end end
    if #drills~=2 then return nil end
    table.sort(drills,function(a,b) return a.position.x<b.position.x end)
    local ax,ay=drills[1].position.x,drills[1].position.y
    local expected={}
    local function key(name,x,y,d) return name..":"..x..":"..y..":"..d end
    local function add(name,x,y,d) expected[key(name,x,y,d)]=true end
    add("burner-mining-drill",0,0,0) add("burner-mining-drill",3,0,0)
    for i=0,5 do add("transport-belt",i-0.5,-1.5,4) end
    add("burner-inserter",5.5,-1.5,12) add("wooden-chest",6.5,-1.5,0)
    for _,e in ipairs(es) do
      local k=key(e.name,e.position.x-ax,e.position.y-ay,e.direction or 0)
      if not expected[k] then return nil end expected[k]=nil
    end
    return not next(expected)
  end)
  inv.destroy()
  return ok and result
end
local function layout(x,y)
  local es={{name="burner-mining-drill",x=x,y=y,direction=0},
    {name="burner-mining-drill",x=x+3,y=y,direction=0}}
  for i=0,5 do es[#es+1]={name="transport-belt",x=x+i-0.5,y=y-1.5,direction=4} end
  es[#es+1]={name="burner-inserter",x=x+5.5,y=y-1.5,direction=12}
  es[#es+1]={name="wooden-chest",x=x+6.5,y=y-1.5,direction=0}
  return es
end
local function ore_amount(surface,x,y)
  local n=0
  for _,e in pairs(surface.find_entities_filtered{area={{x-0.98,y-0.98},{x+0.98,y+0.98}},name="coal"}) do n=n+e.amount end
  return n
end
local function clear(surface,force,x,y)
  if surface.count_entities_filtered{position={x,y},radius=16,force="enemy"}>0 then return false end
  -- Leave a tile between this cell and existing player infrastructure.
  if surface.count_entities_filtered{area={{x-2,y-3},{x+8,y+2}},force=force}>0 then return false end
  for _,e in ipairs(layout(x,y)) do
    if not surface.can_place_entity{name=e.name,position={e.x,e.y},direction=e.direction,force=force} then return false end
    if e.name=="burner-mining-drill" then
      local ores=surface.find_entities_filtered{area={{e.x-0.98,e.y-0.98},{e.x+0.98,e.y+0.98}},type="resource"}
      if #ores==0 then return false end
      for _,ore in ipairs(ores) do if ore.name~="coal" then return false end end
    end
  end
  return true
end

function M.attach(ctx)
  local function jobs()
    local s=ctx.state() s.replica_jobs=s.replica_jobs or {} return s.replica_jobs
  end
  local function summary(j)
    return {job_id=j.id,state=j.state,pattern_id=j.pattern_id,site=j.site,
      step=j.step,steps=#(j.steps or {}),placed=j.placed,audit=j.audit,
      error=j.error,artifact=j.artifact,missing=j.missing,materials=COST}
  end
  local function save(j)
    helpers.write_file(j.artifact..".receipt.json",helpers.table_to_json{
      job=summary(j),receipts=j.receipts},false)
  end
  local function perform(j,action,body)
    body.surface,body.force=j.surface,j.force
    local ok,r=pcall(ctx[action],j.id..":"..(#j.receipts+1),body)
    if not ok then r={ok=false,error="step-runtime-error",detail=tostring(r)} end
    j.receipts[#j.receipts+1]=r
    if not r.ok then j.state,j.error="needs-attention",r.error end
    return r
  end
  local function prepare(surface,force,center,radius,stock)
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
      local allowed={ ["stone-furnace"]=true,["iron-gear-wheel"]=true,
        ["burner-mining-drill"]=true,["transport-belt"]=true,
        ["burner-inserter"]=true,["wooden-chest"]=true }
      if depth>4 or not allowed[item] or not recipe or not recipe.enabled then
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
      steps[#steps+1]={action="craft",body={recipe=item,count=crafts},item=item,target=have+crafts*yield}
      available[item]=have+crafts*yield
      return true
    end
    for _,item in ipairs(sorted_keys(COST)) do
      if not ensure(item,COST[item],0) then break end
    end
    return steps,missing
  end
  function M.start(nonce,r)
    if type(r.blueprint)~="string" or #r.blueprint>24000 or not decode(r.blueprint) then
      return ctx.response(nonce,false,{error="unsupported-autonomous-blueprint"})
    end
    local surface,force=game.get_surface(r.surface or "nauvis"),game.forces[r.force or "player"]
    local stock,owner,kind=ctx.inventory()
    if not surface or not force or not stock or kind~="player" or owner.force~=force or owner.surface~=surface then
      return ctx.response(nonce,false,{error="player-treasury-on-target-surface-required"})
    end
    local center={x=r.x or owner.position.x,y=r.y or owner.position.y}
    local radius=r.radius or 192
    if not finite(center.x) or not finite(center.y) or not finite(radius) or radius<4 or radius>256 then
      return ctx.response(nonce,false,{error="invalid-search"})
    end
    for _,name in ipairs(sorted_keys(COST)) do
      if name~="coal" and (not force.recipes[name] or not force.recipes[name].enabled) then
        return ctx.response(nonce,true,{state="blocked",error="technology-locked",missing={name}})
      end
    end
    for _,j in pairs(jobs()) do
      if j.state=="preparing" or j.state=="building" or j.state=="auditing" then
        return ctx.response(nonce,true,summary(j))
      end
    end
    local ores=surface.find_entities_filtered{position=center,radius=radius,name="coal",type="resource"}
    table.sort(ores,function(a,b)
      local da=(a.position.x-center.x)^2+(a.position.y-center.y)^2
      local db=(b.position.x-center.x)^2+(b.position.y-center.y)^2
      if da~=db then return da<db end
      if a.position.x~=b.position.x then return a.position.x<b.position.x end return a.position.y<b.position.y
    end)
    local site,seen=nil,{}
    for _,ore in ipairs(ores) do
      local x,y=math.floor(ore.position.x),math.floor(ore.position.y)
      local key=x..":"..y
      if not seen[key] then
        seen[key]=true
        if clear(surface,force,x,y) then site={x=x,y=y} break end
      end
    end
    if not site then return ctx.response(nonce,true,{state="blocked",error="no-fitting-coal-site"}) end
    local steps,missing=prepare(surface,force,center,radius,stock)
    if r.dry_run or next(missing) then
      return ctx.response(nonce,true,{state=next(missing) and "blocked" or "planned",
        site=site,site_validated=true,materials=COST,missing=missing,steps=#steps})
    end
    local state=ctx.state() state.replica_seq=(state.replica_seq or 0)+1
    local id="replica-"..state.replica_seq
    local j={id=id,pattern_id=r.pattern_id,blueprint=r.blueprint,surface=surface.name,force=force.name,
      player=owner.index,site=site,steps=steps,step=1,receipts={},state="preparing",
      artifact="replica/"..id,deadline=game.tick+18000}
    jobs()[id]=j save(j)
    return ctx.response(nonce,true,summary(j))
  end
  function M.tick()
    for _,j in pairs(jobs()) do
      if j.state=="preparing" or j.state=="building" or j.state=="auditing" then
        local ok,err=pcall(function()
          local surface,force=game.get_surface(j.surface),game.forces[j.force]
          local stock,owner,kind=ctx.inventory()
          if kind~="player" or owner.index~=j.player or owner.surface~=surface then error("treasury-changed") end
          if game.tick>j.deadline then error("job-timeout") end
          if j.state=="preparing" then
            if owner.crafting_queue_size>0 then return end
            local s=j.steps[j.step]
            if s then
              local result=perform(j,s.action,s.body)
              if result.ok then j.step=j.step+1 end
              save(j) return
            end
            j.state="building"
          end
          if j.state=="building" then
            if not clear(surface,force,j.site.x,j.site.y) then error("site-changed-replan") end
            for name,n in pairs(COST) do if stock.get_item_count{name=name,quality="normal"}<n then error("materials-changed:"..name) end end
            -- Native import centers this tested layout at first drill + (3,-1).
            local result=perform(j,"import",{blueprint=j.blueprint,x=j.site.x+3,y=j.site.y-1,mode="direct"})
            j.placed=result.placed
            if not result.ok then save(j) return end
            j.machines={}
            j.ore_baseline={ore_amount(surface,j.site.x,j.site.y),ore_amount(surface,j.site.x+3,j.site.y)}
            for _,e in ipairs(layout(j.site.x,j.site.y)) do
              local entity=surface.find_entity(e.name,{e.x,e.y})
              if not entity then error("import-geometry-mismatch") end
              if e.name=="burner-mining-drill" or e.name=="burner-inserter" then
                j.machines[#j.machines+1]=entity
                if not perform(j,"insert",{item="coal",count=1,x=e.x,y=e.y}).ok then save(j) return end
              elseif e.name=="wooden-chest" then j.chest=entity end
            end
            j.baseline=j.chest.get_inventory(defines.inventory.chest).get_item_count("coal")
            j.audit_tick=game.tick+1800 j.state="auditing"
            helpers.write_file(j.artifact..".blueprint.txt",j.blueprint.."\n",false)
            save(j)
          elseif j.state=="auditing" then
            if not j.chest.valid then error("output-chest-lost") end
            local source=j.chest.get_inventory(defines.inventory.chest)
            for _,e in ipairs(j.machines) do
              if not e.valid then error("machine-lost") end
              local fuel=e.get_fuel_inventory()
              if fuel.is_empty() and e.burner.remaining_burning_fuel<=0 and source.get_item_count("coal")>0 then
                local n=source.remove{name="coal",count=1}
                if fuel.insert{name="coal",count=n}~=n then source.insert{name="coal",count=n} else
                  j.receipts[#j.receipts+1]={action="local-refuel",item="coal",count=n,target=e.unit_number}
                end
              end
            end
            if game.tick>=j.audit_tick then
              local gain=source.get_item_count("coal")-j.baseline
              local active=0
              for i=1,2 do if ore_amount(surface,j.site.x+(i-1)*3,j.site.y)<j.ore_baseline[i] then active=active+1 end end
              local intact=true
              for _,e in ipairs(layout(j.site.x,j.site.y)) do
                local current=surface.find_entity(e.name,{e.x,e.y})
                if not current or current.direction~=e.direction then intact=false end
              end
              local passed=gain>0 and active==2 and intact
              j.audit={status=passed and "passed" or "failed",coal_gained=gain,active_drills=active,
                layout_intact=intact,window_ticks=1800}
              j.state=passed and "verified" or "needs-attention"
              if not passed then j.error="production-audit-failed" end
              helpers.write_file(j.artifact..".audit.json",helpers.table_to_json(j.audit),false) save(j)
            end
          end
        end)
        if not ok then j.state,j.error="needs-attention",tostring(err) save(j) end
      end
    end
  end
  function M.status(nonce,r)
    local j=jobs()[r.job_id]
    if not j then return ctx.response(nonce,false,{error="replica-job-not-found"}) end
    return ctx.response(nonce,true,summary(j))
  end
  return M
end
return M
