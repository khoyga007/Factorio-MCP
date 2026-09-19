-- Field actions for live play: find offshore-pump spots, recall own entities into the bag.
local M={}

local ACTIVE={preparing=true,building=true,settling=true,auditing=true}
local UNIT={[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}
local MAX_CANDIDATES=50
local MAX_CHECKS=40000
local MAX_RECALL=200

local function finite(v) return type(v)=="number" and v==v and v~=math.huge and v~=-math.huge end
local function dist2(a,b) local dx,dy=a.x-b.x,a.y-b.y return dx*dx+dy*dy end

function M.attach(ctx)
  local reply=ctx.response

  -- Tile the pump's output pipe must occupy, from the prototype (no hardcoded geometry).
  local function pump_output(name,pos,dir)
    local ok,out=pcall(function()
      local box=prototypes.entity[name].fluidbox_prototypes[1]
      for _,c in pairs(box.pipe_connections) do
        if c.flow_direction~="input" and c.connection_type~="underground" then
          local k=dir/4+1
          local p=c.positions and c.positions[k]
          local u=UNIT[c.direction and (c.direction+dir)%16 or dir]
          if p and u then return {x=pos.x+p.x+u[1],y=pos.y+p.y+u[2]} end
        end
      end
    end)
    return ok and out or nil
  end

  -- Nearest pumpable shore first. Candidate = can_place_entity(manual) true.
  -- blocked = placeable as ghost but not by hand: trees/rocks in the way, listed.
  function M.water(nonce,r)
    local surface=game.get_surface(r.surface or "nauvis")
    local force=game.forces[r.force or "player"]
    if not surface or not force then return reply(nonce,false,{error="surface-or-force-not-found"}) end
    local pump=r.pump or "offshore-pump"
    if not prototypes.entity[pump] then return reply(nonce,false,{error="unknown-pump"}) end
    local center
    if r.x==nil and r.y==nil then
      local player=game.get_player(1)
      if not player then return reply(nonce,false,{error="position-required"}) end
      center={x=player.position.x,y=player.position.y}
    elseif finite(r.x) and finite(r.y) then center={x=r.x,y=r.y}
    else return reply(nonce,false,{error="invalid-position"}) end
    local radius=tonumber(r.radius) or 512
    if not finite(radius) or radius<8 or radius>2048 then return reply(nonce,false,{error="invalid-radius"}) end
    local offset=math.max(0,math.floor(tonumber(r.offset) or 0))
    local limit=math.min(20,math.max(1,math.floor(tonumber(r.limit) or 12)))
    local want=math.min(MAX_CANDIDATES,offset+limit)
    local names=ctx.fluid_tiles()
    local proto=prototypes.entity[pump]
    -- Snap a raw point to a legal center for this footprint (odd side .5, even side integer).
    local function snap(v,size) if size%2==1 then return math.floor(v)+0.5 end return math.floor(v+0.5) end
    local bins={}
    -- Every generated chunk in radius (not the capped survey index: small near ponds matter).
    for chunk in surface.get_chunks() do
      local c={x=chunk.x*32+16,y=chunk.y*32+16}
      if dist2(c,center)<=(radius+23)^2 then
        local n=surface.count_tiles_filtered{area=chunk.area,name=names}
        if n>0 then bins[#bins+1]={x=chunk.x*32,y=chunk.y*32,tiles=n,d=dist2(c,center)} end
      end
    end
    table.sort(bins,function(a,b) return a.d<b.d end)
    local found,blocked,seen,checks={}, {}, {}, 0
    local clusters={}
    for _,b in ipairs(bins) do
      if #found>=want or checks>=MAX_CHECKS then break end
      local area={{b.x,b.y},{b.x+32,b.y+32}}
      local water=surface.find_tiles_filtered{area=area,name=names}
      local kinds={}
      for _,t in pairs(water) do kinds[t.name]=(kinds[t.name] or 0)+1 end
      if #clusters<12 then clusters[#clusters+1]={x=b.x,y=b.y,tiles=b.tiles,types=kinds,distance=math.floor(math.sqrt(b.d))} end
      -- Shore = land tile touching water; try pump centers on and around it.
      local spots={}
      for _,t in pairs(water) do
        local tx,ty=t.position.x,t.position.y
        for _,n in ipairs{{1,0},{-1,0},{0,1},{0,-1}} do
          local lx,ly=tx+n[1],ty+n[2]
          local key=lx..":"..ly
          if not seen[key] then
            seen[key]=true
            local tile=surface.get_tile(lx,ly)
            if tile.valid and not tile.prototype.fluid then
              spots[#spots+1]={x=lx,y=ly,d=dist2({x=lx+0.5,y=ly+0.5},center)}
            end
          end
        end
      end
      table.sort(spots,function(a,b) return a.d<b.d end)
      for _,s in ipairs(spots) do
        if #found>=want or checks>=MAX_CHECKS then break end
        for _,dir in ipairs{0,4,8,12} do
          for _,p in ipairs{{s.x+0.5,s.y+0.5},{s.x+0.5,s.y},{s.x+0.5,s.y+1},{s.x,s.y+0.5},{s.x+1,s.y+0.5}} do
            local w,h=proto.tile_width,proto.tile_height
            if dir==4 or dir==12 then w,h=h,w end
            local pos={x=snap(p[1],w),y=snap(p[2],h)}
            local key=pos.x..":"..pos.y..":"..dir
            if not seen[key] then
              seen[key]=true
              checks=checks+1
              local spec={name=pump,position=pos,direction=dir,force=force,build_check_type=defines.build_check_type.manual}
              if surface.can_place_entity(spec) then
                found[#found+1]={x=pos.x,y=pos.y,direction=dir,output=pump_output(pump,pos,dir),
                  distance=math.floor(math.sqrt(dist2(pos,center)))}
                if #found>=want then break end
              elseif #blocked<12 then
                spec.build_check_type=defines.build_check_type.blueprint_ghost
                spec.forced=true
                if surface.can_place_entity(spec) then
                  local obs={}
                  for _,e in pairs(surface.find_entities_filtered{position=pos,radius=1.6,type={"tree","simple-entity","cliff"}}) do
                    obs[#obs+1]={name=e.name,x=e.position.x,y=e.position.y}
                  end
                  if #obs>0 then blocked[#blocked+1]={x=pos.x,y=pos.y,direction=dir,obstacles=obs} end
                end
              end
            end
          end
          if #found>=want then break end
        end
      end
    end
    local page={}
    for i=offset+1,math.min(#found,offset+limit) do page[#page+1]=found[i] end
    return reply(nonce,true,{action="water_sites",center=center,candidates=page,
      next_offset=(#found>offset+limit) and offset+limit or nil,
      blocked=blocked,clusters=clusters,checks=checks,
      truncated=checks>=MAX_CHECKS or nil})
  end

  -- Own-force entities -> player bag, contents included. Never trees/rocks/enemies.
  function M.recall(nonce,r)
    local surface=game.get_surface(r.surface or "nauvis")
    local force=game.forces[r.force or "player"]
    if not surface or not force then return reply(nonce,false,{error="surface-or-force-not-found"}) end
    local stock,owner,kind=ctx.inventory()
    if not stock or kind~="player" then return reply(nonce,false,{error="treasury-not-player"}) end
    local targets,seen={}, {}
    local function add(e)
      if e.valid and e.force==force and e.type~="character" and e.unit_number and not seen[e.unit_number]
        and e.prototype.mineable_properties.minable then
        seen[e.unit_number]=true targets[#targets+1]=e
      end
    end
    if type(r.entities)=="table" and #r.entities>0 then
      for i,row in ipairs(r.entities) do
        if type(row)~="table" or type(row.name)~="string" or not finite(row.x) or not finite(row.y) then
          return reply(nonce,false,{error="invalid-entity:"..i})
        end
        local e=surface.find_entities_filtered{name=row.name,position={row.x,row.y},radius=0.1,force=force}[1]
        if not e then return reply(nonce,false,{error="entity-not-found:"..i}) end
        add(e)
      end
    elseif finite(r.x1) and finite(r.y1) and finite(r.x2) and finite(r.y2) then
      if r.x1>=r.x2 or r.y1>=r.y2 or r.x2-r.x1>64 or r.y2-r.y1>64 then
        return reply(nonce,false,{error="invalid-area"})
      end
      for _,e in pairs(surface.find_entities_filtered{area={{r.x1,r.y1},{r.x2,r.y2}},force=force}) do add(e) end
    else
      return reply(nonce,false,{error="area-or-entities-required"})
    end
    if #targets==0 then return reply(nonce,false,{error="nothing-to-recall"}) end
    if #targets>MAX_RECALL then return reply(nonce,false,{error="too-many-entities",count=#targets}) end
    -- Refuse to pull entities out from under a live executor job.
    if not r.force_active then
      for _,j in pairs(ctx.state().executor_jobs or {}) do
        if ACTIVE[j.state] and j.surface==surface.name then
          for _,l in ipairs(j.layout or {}) do
            for _,e in ipairs(targets) do
              if e.name==l.name and math.abs(e.position.x-l.x)<0.01 and math.abs(e.position.y-l.y)<0.01 then
                return reply(nonce,false,{error="active-job:"..j.id,name=e.name,x=e.position.x,y=e.position.y})
              end
            end
          end
        end
      end
    end
    table.sort(targets,function(a,b) return a.unit_number<b.unit_number end)
    local rows={}
    for _,e in ipairs(targets) do rows[#rows+1]={name=e.name,x=e.position.x,y=e.position.y} end
    if r.dry_run then
      return reply(nonce,true,{action="recall",state="planned",entities=rows,count=#rows})
    end
    local before={}
    for _,s in pairs(stock.get_contents()) do before[s.name]=(before[s.name] or 0)+s.count end
    local receipts,spilled={}, {}
    for _,e in ipairs(targets) do
      if e.valid then
        local row={name=e.name,x=e.position.x,y=e.position.y}
        local buffer=game.create_inventory(400)
        local pos=e.position
        if e.mine{inventory=buffer,force=false,raise_destroyed=true} then
          row.items={}
          for _,s in pairs(buffer.get_contents()) do
            row.items[s.name]=(row.items[s.name] or 0)+s.count
            local n=stock.insert{name=s.name,count=s.count,quality=s.quality}
            if n<s.count then
              surface.spill_item_stack{position=pos,stack={name=s.name,count=s.count-n,quality=s.quality},
                enable_looted=true,force=force}
              spilled[s.name]=(spilled[s.name] or 0)+s.count-n
            end
          end
        else
          row.error="mine-failed"
        end
        buffer.destroy()
        receipts[#receipts+1]=row
      end
    end
    local delta={}
    local after={}
    for _,s in pairs(stock.get_contents()) do after[s.name]=(after[s.name] or 0)+s.count end
    for name,n in pairs(after) do if n~=(before[name] or 0) then delta[name]=n-(before[name] or 0) end end
    for name,n in pairs(before) do if not after[name] then delta[name]=-n end end
    return reply(nonce,true,{action="recall",state="done",count=#receipts,receipts=receipts,
      delta=delta,spilled=next(spilled) and spilled or nil})
  end

  return M
end

return M
