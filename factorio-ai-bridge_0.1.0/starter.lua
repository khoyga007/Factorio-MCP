-- One starter goal: a burner drill feeds a stone furnace directly.
local M = {}
local STEP = {[0] = {0, -1}, [4] = {1, 0}, [8] = {0, 1}, [12] = {-1, 0}}

local function finite(n)
  return type(n) == "number" and n == n and math.abs(n) < 1000000
end

local function distance2(a, x, y)
  return (a.x - x)^2 + (a.y - y)^2
end

local function site(surface, force, resource_name, center, radius, furnace)
  local resources = surface.find_entities_filtered {
    position = center, radius = radius, type = "resource", name = resource_name,
  }
  table.sort(resources, function(a, b)
    return distance2(a.position, center.x, center.y) < distance2(b.position, center.x, center.y)
  end)
  local best, seen
  seen = {}
  for _, resource in ipairs(resources) do
    local x, y = math.floor(resource.position.x), math.floor(resource.position.y)
    local key = x .. ":" .. y
    if not seen[key] then
      seen[key] = true
      for direction, step in pairs(STEP) do
        local drill = {x = x, y = y, direction = direction}
        local output = {x = x + step[1] * 2, y = y + step[2] * 2}
        if surface.count_entities_filtered {
          position = {x, y}, radius = 12, force = "enemy",
        } == 0 and surface.can_place_entity {
          name = "burner-mining-drill", position = {x, y},
          direction = direction, force = force,
        } then
          local clear = furnace and surface.can_place_entity {
            name = "stone-furnace", position = {output.x, output.y}, force = force,
          } or surface.count_entities_filtered {
            position = {x + step[1] * 1.5, y + step[2] * 1.5}, radius = 0.6,
            type = {"tree", "simple-entity", "cliff", "item-entity", "container", "furnace"},
          } == 0
          if clear then
            local blocked_ore = furnace and surface.count_entities_filtered {
              area = {{output.x - 1, output.y - 1}, {output.x + 1, output.y + 1}},
              type = "resource",
            } or 0
            local score = distance2(drill, center.x, center.y) + blocked_ore * 500
            if not best or score < best.score then
              best = {drill = drill, output = output, score = score,
                ore_under_furnace = blocked_ore}
            end
          end
        end
      end
    end
  end
  if best then best.score = nil end
  return best
end

local function existing_pair(surface, force, ore_name, center, radius)
  local nearest, distance
  for _, drill in pairs(surface.find_entities_filtered {
    position = center, radius = radius, type = "mining-drill",
    name = "burner-mining-drill", force = force,
  }) do
    local step = STEP[drill.direction]
    if step and surface.count_entities_filtered {
      area = drill.mining_area, type = "resource", name = ore_name,
    } > 0 then
      local f = {x = drill.position.x + step[1] * 2,
        y = drill.position.y + step[2] * 2}
      local furnace = surface.find_entity("stone-furnace", f)
      local d = distance2(drill.position, center.x, center.y)
      if furnace and furnace.valid and furnace.force == force
        and (not nearest or d < distance) then
        nearest, distance = {drill = drill, furnace = furnace,
          site = {drill = {x = drill.position.x, y = drill.position.y,
            direction = drill.direction}, output = f}}, d
      end
    end
  end
  return nearest
end

function M.attach(ctx)
  local function jobs()
    local s = ctx.state()
    s.starter_jobs = s.starter_jobs or {}
    return s.starter_jobs
  end
  local function reply(nonce, ok, value) return ctx.response(nonce, ok, value) end
  local function summary(job)
    return {action = "starter_smelt", job_id = job.artifact and job.id or nil, state = job.state,
      product = job.product, iron_or_copper_site = job.ore_site,
      coal_site = job.coal_site, materials = job.materials,
      missing = job.missing, error = job.error, placed = job.placed,
      audit = job.audit, artifact = job.artifact, blueprint_error = job.blueprint_error,
      existing = job.existing or nil,
      output = job.furnace and job.furnace.valid
        and job.furnace.get_output_inventory().get_item_count(job.product) or nil}
  end
  local function save(job)
    if job.artifact then
      helpers.write_file(job.artifact .. ".receipt.json", helpers.table_to_json {
        job = summary(job), receipts = job.receipts,
      }, false)
    end
  end
  local function step(job, action, request)
    local handler = ctx[action]
    local ok, result = pcall(handler, job.id .. ":" .. action .. ":" .. (#job.receipts + 1), request)
    if not ok then result = {ok = false, error = "internal-step-error", detail = tostring(result)} end
    job.receipts[#job.receipts + 1] = result
    if not result.ok then job.error, job.state = result.error, "partial" end
    return result.ok
  end
  local function export_pair(job)
    local a, b = job.drill.bounding_box, job.furnace.bounding_box
    local ok, exported = pcall(ctx.export, job.id .. ":blueprint", {
      surface = job.surface, force = job.force,
      x1 = math.min(a.left_top.x, b.left_top.x) + 0.01,
      y1 = math.min(a.left_top.y, b.left_top.y) + 0.01,
      x2 = math.max(a.right_bottom.x, b.right_bottom.x) - 0.01,
      y2 = math.max(a.right_bottom.y, b.right_bottom.y) - 0.01,
    })
    if ok and exported.ok and exported.entities == 2 then
      helpers.write_file(job.artifact .. ".blueprint.txt", exported.blueprint .. "\n", false)
    else job.blueprint_error = ok and (exported.error or "blueprint-count-mismatch")
      or tostring(exported) end
  end
  local function register(product, surface, force, ore_site, coal_site, materials, missing, owner)
    local state = ctx.state()
    state.starter_seq = (state.starter_seq or 0) + 1
    local job = {id = "starter-" .. state.starter_seq, tick = game.tick,
      state = "planned", product = product, surface = surface.name, force = force.name,
      ore_site = ore_site, coal_site = coal_site, materials = materials,
      missing = missing, placed = 0, receipts = {}, player_index = owner and owner.index or nil}
    job.artifact = "starter/" .. job.id
    jobs()[job.id] = job
    return job
  end
  local function build_iron_or_copper(job)
    local surface, force = game.get_surface(job.surface), game.forces[job.force]
    local d, f = job.ore_site.drill, job.ore_site.output
    if not surface.can_place_entity {name = "burner-mining-drill", position = {d.x, d.y},
      direction = d.direction, force = force}
      or not surface.can_place_entity {name = "stone-furnace", position = {f.x, f.y},
        force = force} then
      job.error, job.state = "site-changed-replan", "blocked"
      return
    end
    if not force.recipes[job.product] or not force.recipes[job.product].enabled then
      job.error, job.state = "product-technology-locked", "blocked"
      return
    end
    local stock, owner, kind = ctx.inventory()
    if not stock or kind ~= "player" or not owner or owner.index ~= job.player_index then
      job.error, job.state = "treasury-changed", "blocked"
      return
    end
    if stock.get_item_count("burner-mining-drill") < 1
      or stock.get_item_count("stone-furnace") < 1 or stock.get_item_count("coal") < 2 then
      job.error, job.state = "materials-changed", "blocked"
      return
    end
    job.state = "building"
    local base = {surface = job.surface, force = job.force}
    if not step(job, "place", {name = "burner-mining-drill", x = d.x, y = d.y,
      direction = d.direction, surface = base.surface, force = base.force}) then return end
    job.placed = job.placed + 1
    if not step(job, "place", {name = "stone-furnace", x = f.x, y = f.y,
      surface = base.surface, force = base.force}) then return end
    job.placed = job.placed + 1
    if not step(job, "insert", {item = "coal", count = 1, x = f.x, y = f.y,
      surface = base.surface, force = base.force}) then return end
    if not step(job, "insert", {item = "coal", count = 1, x = d.x, y = d.y,
      surface = base.surface, force = base.force}) then return end
    job.drill = surface.find_entity("burner-mining-drill", {d.x, d.y})
    job.furnace = surface.find_entity("stone-furnace", {f.x, f.y})
    export_pair(job)
    job.baseline = job.furnace.products_finished
    job.deadline, job.state = game.tick + 1800, "auditing"
  end

  function M.start(nonce, request)
    local product = request.product or "iron-plate"
    if product ~= "iron-plate" and product ~= "copper-plate" then
      return reply(nonce, false, {error = "unsupported-starter-product"})
    end
    local surface = game.get_surface(request.surface or "nauvis")
    local force = game.forces[request.force or "player"]
    if not surface or not force then return reply(nonce, false, {error = "surface-or-force-not-found"}) end
    local center
    if request.x == nil and request.y == nil then
      local player = game.get_player(1)
      if not player then return reply(nonce, false, {error = "position-required"}) end
      center = player.position
    elseif finite(request.x) and finite(request.y) then
      center = {x = request.x, y = request.y}
    else return reply(nonce, false, {error = "invalid-position"}) end
    local radius = request.radius or 192
    if not finite(radius) or radius < 4 or radius > 256 then
      return reply(nonce, false, {error = "invalid-radius"})
    end
    for _, name in ipairs {"burner-mining-drill", "stone-furnace"} do
      local proto = prototypes.entity[name]
      if not proto or proto.tile_width ~= 2 or proto.tile_height ~= 2
        or not proto.items_to_place_this or proto.items_to_place_this[1].name ~= name then
        return reply(nonce, false, {error = "starter-prototype-mismatch:" .. name})
      end
    end
    local recipe = force.recipes[product]
    if not recipe or not recipe.enabled then
      return reply(nonce, false, {error = "product-technology-locked", product = product})
    end
    local ore_name = product == "iron-plate" and "iron-ore" or "copper-ore"
    local pair = existing_pair(surface, force, ore_name, center, radius)
    if pair then
      local stock, owner = ctx.inventory()
      local needs = {}
      for _, entity in ipairs {pair.drill, pair.furnace} do
        local fuel = entity.get_fuel_inventory()
        if not entity.burner or entity.burner.remaining_burning_fuel <= 0
          and (not fuel or fuel.is_empty()) then
          needs[#needs + 1] = entity
        end
      end
      local available = stock and stock.get_item_count("coal") or 0
      local missing = {}
      if available < #needs then missing[#missing + 1] = "coal:" .. (#needs - available) end
      if request.dry_run or #missing > 0 then
        return reply(nonce, true, {action = "starter_smelt", state = #missing > 0 and "blocked" or "existing",
          product = product, existing = true, iron_or_copper_site = pair.site,
          missing = missing, fuel_needed = #needs,
          output = pair.furnace.get_output_inventory().get_item_count(product)})
      end
      if #needs == 0 then
        for _, prior in pairs(jobs()) do
          if prior.furnace == pair.furnace and prior.product == product
            and (prior.state == "auditing" or prior.state == "verified") then
            return reply(nonce, true, summary(prior))
          end
        end
      end
      local job = register(product, surface, force, pair.site, nil,
        {"existing-drill", "existing-furnace", "coal:" .. #needs}, {}, owner)
      job.existing, job.drill, job.furnace = true, pair.drill, pair.furnace
      for _, entity in ipairs(needs) do
        if not step(job, "insert", {item = "coal", count = 1,
          x = entity.position.x, y = entity.position.y,
          surface = surface.name, force = force.name}) then
          save(job)
          return reply(nonce, false, summary(job))
        end
      end
      export_pair(job)
      job.baseline = pair.furnace.products_finished
      job.deadline, job.state = game.tick + 1800, "auditing"
      save(job)
      return reply(nonce, true, summary(job))
    end
    local ore_site = site(surface, force, ore_name, center, radius, true)
    if not ore_site then return reply(nonce, false, {error = "no-fitting-ore-site", ore = ore_name}) end
    local stock, owner, kind = ctx.inventory()
    local coal = stock and stock.get_item_count("coal") or 0
    local materials = {"burner-mining-drill", "stone-furnace", coal >= 2 and "coal:2" or "wood:1+coal-deposit"}
    local missing = {}
    for _, name in ipairs {"burner-mining-drill", "stone-furnace"} do
      if not stock or stock.get_item_count(name) < 1 then missing[#missing + 1] = name end
      local tech = force.recipes[name]
      if tech and not tech.enabled then missing[#missing + 1] = "technology:" .. name end
    end
    local coal_site
    if coal < 2 then
      if not stock or stock.get_item_count("wood") < 1 then missing[#missing + 1] = "wood:1" end
      coal_site = site(surface, force, "coal", center, radius, false)
      if not coal_site then missing[#missing + 1] = "reachable-coal-deposit" end
    end
    if kind ~= "player" then missing[#missing + 1] = "player-inventory-as-treasury" end
    local state = ctx.state()
    state.starter_seq = (state.starter_seq or 0) + 1
    local job = {id = "starter-" .. state.starter_seq, tick = game.tick,
      state = "planned", product = product, surface = surface.name, force = force.name,
      ore_site = ore_site, coal_site = coal_site, materials = materials,
      missing = missing, placed = 0, receipts = {}, player_index = owner and owner.index or nil}
    if request.dry_run or #missing > 0 then
      job.state = #missing > 0 and "blocked" or "planned"
      return reply(nonce, true, summary(job))
    end
    job.artifact = "starter/" .. job.id
    jobs()[job.id] = job
    if coal >= 2 then build_iron_or_copper(job)
    else
      local d = coal_site.drill
      job.state = "gathering-coal"
      if step(job, "place", {name = "burner-mining-drill", x = d.x, y = d.y,
        direction = d.direction, surface = job.surface, force = job.force}) then
        job.placed = 1
        if step(job, "insert", {item = "wood", count = 1, x = d.x, y = d.y,
          surface = job.surface, force = job.force}) then
          job.coal_drill = surface.find_entity("burner-mining-drill", {d.x, d.y})
          job.coal_deadline = game.tick + 3600
        end
      end
    end
    save(job)
    return reply(nonce, job.state ~= "partial" and job.state ~= "blocked", summary(job))
  end

  function M.tick()
    for _, job in pairs(jobs()) do
      if job.state == "gathering-coal" then
        local stock, owner, kind = ctx.inventory()
        if not stock or kind ~= "player" or not owner or owner.index ~= job.player_index then
          job.error, job.state = "treasury-changed", "needs-attention"
          save(job)
        elseif not job.coal_drill or not job.coal_drill.valid then
          job.error, job.state = "coal-drill-lost", "needs-attention"
        else
          local surface = game.get_surface(job.surface)
          local d = job.coal_site.drill
          for _, drop in pairs(surface.find_entities_filtered {
            position = job.coal_drill.drop_position, radius = 0.85, type = "item-entity",
          }) do
            if drop.stack.valid_for_read and drop.stack.name == "coal"
              and stock.get_insertable_count("coal") >= 1 then
              local n = stock.insert {name = "coal", count = 1}
              if n == 1 then
                local source_position = {x = drop.position.x, y = drop.position.y}
                local remaining = drop.stack.count - 1
                if remaining == 0 then drop.destroy() else drop.stack.count = remaining end
                job.receipts[#job.receipts + 1] = {action = "collected", item = "coal", count = 1,
                  source = source_position, target = "player"}
              end
            end
          end
          if stock.get_item_count("coal") >= 2 then
            if step(job, "mine", {name = "burner-mining-drill", x = d.x, y = d.y,
              surface = job.surface}) then
              job.placed = 0
              build_iron_or_copper(job)
              save(job)
            end
          elseif game.tick >= job.coal_deadline then
            job.error, job.state = "coal-bootstrap-stalled", "needs-attention"
            save(job)
          end
        end
      elseif job.state == "auditing" and game.tick >= job.deadline then
        if job.drill and job.drill.valid and job.furnace and job.furnace.valid then
          local count = job.furnace.products_finished - job.baseline
          local recipe = job.furnace.get_recipe()
          local pass = count > 0 and recipe and recipe.name == job.product
          job.audit = {status = pass and "passed" or "failed", products = count,
            window_ticks = 1800}
          job.state = pass and "verified" or "needs-attention"
          if not pass then job.error = "no-measured-output" end
        else job.error, job.state = "starter-entity-lost", "needs-attention" end
        save(job)
        helpers.write_file(job.artifact .. ".audit.json", helpers.table_to_json(job.audit or {
          status = "failed", error = job.error,
        }), false)
      end
    end
  end

  function M.status(nonce, request)
    local job = jobs()[request.job_id]
    if not job then return reply(nonce, false, {error = "starter-job-not-found"}) end
    return reply(nonce, true, summary(job))
  end
  return M
end

return M
