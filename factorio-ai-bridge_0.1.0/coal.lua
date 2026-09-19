-- A burner drill drops real coal into an adjacent wooden chest.
local M = {}
local STEP = {[0] = {0, -1}, [4] = {1, 0}, [8] = {0, 1}, [12] = {-1, 0}}

local function finite(n)
  return type(n) == "number" and n == n and math.abs(n) < 1000000
end

local function chest_at(drill, direction)
  local offset = ({[0] = {-0.5, -1.5}, [4] = {1.5, -0.5},
    [8] = {0.5, 1.5}, [12] = {-1.5, 0.5}})[direction]
  return {x = drill.x + offset[1], y = drill.y + offset[2]}
end

function M.attach(ctx)
  local function jobs()
    local state = ctx.state()
    state.coal_jobs = state.coal_jobs or {}
    return state.coal_jobs
  end
  local function reply(nonce, ok, fields) return ctx.response(nonce, ok, fields) end
  local function summary(job)
    local count = job.chest_entity and job.chest_entity.valid
      and job.chest_entity.get_inventory(defines.inventory.chest).get_item_count("coal") or nil
    return {action = "coal_stockpile", job_id = job.id, state = job.state,
      site = job.site, fuel = job.fuel, missing = job.missing,
      existing = job.existing or false, coal = count, refuels = job.refuels or 0,
      audit = job.audit,
      error = job.error, artifact = job.artifact}
  end
  local function save(job)
    if job.artifact then helpers.write_file(job.artifact .. ".receipt.json",
      helpers.table_to_json {job = summary(job), receipts = job.receipts}, false) end
  end
  local function find_site(surface, force, center, radius)
    local resources = surface.find_entities_filtered {
      position = center, radius = radius, type = "resource", name = "coal"}
    table.sort(resources, function(a, b)
      local da = (a.position.x - center.x)^2 + (a.position.y - center.y)^2
      local db = (b.position.x - center.x)^2 + (b.position.y - center.y)^2
      return da < db
    end)
    local seen = {}
    for _, ore in ipairs(resources) do
      local x, y = math.floor(ore.position.x), math.floor(ore.position.y)
      local key = x .. ":" .. y
      if not seen[key] then
        seen[key] = true
        for _, direction in ipairs {0, 4, 8, 12} do
          local drill = {x = x, y = y, direction = direction}
          local chest = chest_at(drill, direction)
          if surface.count_entities_filtered {position = {x, y}, radius = 12,
            force = "enemy"} == 0
            and surface.can_place_entity {name = "burner-mining-drill",
              position = {x, y}, direction = direction, force = force}
            and surface.can_place_entity {name = "wooden-chest",
              position = {chest.x, chest.y}, force = force} then
            return {drill = drill, chest = chest}
          end
        end
      end
    end
  end
  local function existing(surface, force, center, radius)
    for _, drill in pairs(surface.find_entities_filtered {position = center,
      radius = radius, name = "burner-mining-drill", force = force}) do
      if STEP[drill.direction] and surface.count_entities_filtered {
        area = drill.mining_area, type = "resource", name = "coal"} > 0 then
        local at = chest_at(drill.position, drill.direction)
        local chest = surface.find_entity("wooden-chest", {at.x, at.y})
        if chest and chest.valid and chest.force == force then
          return {drill = drill, chest = chest, site = {drill = {
            x = drill.position.x, y = drill.position.y,
            direction = drill.direction}, chest = at}}
        end
      end
    end
  end
  local function step(job, name, request)
    local ok, result = pcall(ctx[name], job.id .. ":" .. name .. ":" .. (#job.receipts + 1), request)
    if not ok then result = {ok = false, error = "internal-step-error", detail = tostring(result)} end
    job.receipts[#job.receipts + 1] = result
    if not result.ok then job.error, job.state = result.error, "partial" end
    return result.ok
  end
  local function refuel(job)
    local drill, chest = job.drill_entity, job.chest_entity
    if not drill or not drill.valid or not chest or not chest.valid then return false end
    local fuel = drill.get_fuel_inventory()
    if not fuel or not fuel.is_empty() or drill.burner.remaining_burning_fuel > 0 then return false end
    local source = chest.get_inventory(defines.inventory.chest)
    if source.get_item_count("coal") < 1 or not fuel.can_insert {name = "coal", count = 1} then
      return false
    end
    if source.remove {name = "coal", count = 1} ~= 1 then return false end
    if fuel.insert {name = "coal", count = 1} ~= 1 then
      source.insert {name = "coal", count = 1}
      return false
    end
    job.receipts[#job.receipts + 1] = {action = "local-refuel", item = "coal", count = 1,
      source = {x = chest.position.x, y = chest.position.y},
      target = {x = drill.position.x, y = drill.position.y}}
    job.refuels = (job.refuels or 0) + 1
    while #job.receipts > 64 do table.remove(job.receipts, 1) end
    save(job)
    return true
  end
  function M.start(nonce, request)
    local surface, force = game.get_surface(request.surface or "nauvis"),
      game.forces[request.force or "player"]
    if not surface or not force then return reply(nonce, false, {error = "surface-or-force-not-found"}) end
    local player = game.get_player(1)
    local x, y = request.x, request.y
    if x == nil and y == nil and player then x, y = player.position.x, player.position.y end
    local radius = request.radius or 192
    if not finite(x) or not finite(y) or not finite(radius) or radius < 4 or radius > 256 then
      return reply(nonce, false, {error = "invalid-search"})
    end
    for _, name in ipairs {"burner-mining-drill", "wooden-chest"} do
      local recipe = force.recipes[name]
      if not recipe or not recipe.enabled then
        return reply(nonce, true, {state = "blocked", missing = {"technology:" .. name}})
      end
    end
    local stock, owner, kind = ctx.inventory()
    local prior = existing(surface, force, {x = x, y = y}, radius)
    local site = prior and prior.site or find_site(surface, force, {x = x, y = y}, radius)
    if not site then return reply(nonce, true, {state = "blocked", missing = {"coal-site"}}) end
    local fuel = stock and stock.get_item_count("coal") > 0 and "coal"
      or stock and stock.get_item_count("wood") > 0 and "wood" or nil
    local missing = {}
    if kind ~= "player" then missing[#missing + 1] = "player-inventory-as-treasury" end
    if not prior then
      for _, name in ipairs {"burner-mining-drill", "wooden-chest"} do
        if not stock or stock.get_item_count(name) < 1 then missing[#missing + 1] = name end
      end
    end
    local burning = prior and prior.drill.burner.remaining_burning_fuel > 0
    local fuel_inventory = prior and prior.drill.get_fuel_inventory()
    local fueled = burning or fuel_inventory and not fuel_inventory.is_empty()
    if not fueled and prior and prior.chest.get_inventory(defines.inventory.chest)
      .get_item_count("coal") > 0 then fuel = "chest-coal" end
    if not fueled and not fuel then missing[#missing + 1] = "coal-or-wood:1" end
    if request.dry_run or #missing > 0 then
      return reply(nonce, true, {action = "coal_stockpile", state = #missing > 0 and "blocked" or "planned",
        site = site, existing = prior ~= nil, fuel = fueled and "in-drill" or fuel,
        missing = missing, coal = prior and prior.chest.get_inventory(defines.inventory.chest)
          .get_item_count("coal") or 0})
    end
    local state = ctx.state()
    state.coal_seq = (state.coal_seq or 0) + 1
    local job = {id = "coal-" .. state.coal_seq, site = site, state = "building",
      surface = surface.name, force = force.name, fuel = fueled and "in-drill" or fuel,
      existing = prior ~= nil, missing = {}, receipts = {},
      artifact = "coal/coal-" .. state.coal_seq}
    jobs()[job.id] = job
    if prior then job.drill_entity, job.chest_entity = prior.drill, prior.chest
    else
      local d, c = site.drill, site.chest
      if not step(job, "place", {name = "burner-mining-drill", x = d.x, y = d.y,
        direction = d.direction, surface = surface.name, force = force.name}) then
        save(job) return reply(nonce, false, summary(job)) end
      if not step(job, "place", {name = "wooden-chest", x = c.x, y = c.y,
        surface = surface.name, force = force.name}) then
        save(job) return reply(nonce, false, summary(job)) end
      job.drill_entity = surface.find_entity("burner-mining-drill", {d.x, d.y})
      job.chest_entity = surface.find_entity("wooden-chest", {c.x, c.y})
    end
    if not job.drill_entity or not job.chest_entity then
      job.error, job.state = "built-entity-not-found", "partial"
      save(job) return reply(nonce, false, summary(job))
    end
    if not fueled then
      if fuel == "chest-coal" then
        if not refuel(job) then
          job.error, job.state = "local-fuel-changed", "partial"
          save(job) return reply(nonce, false, summary(job))
        end
      elseif not step(job, "insert", {item = fuel, count = 1,
        x = site.drill.x, y = site.drill.y, surface = surface.name, force = force.name}) then
        save(job) return reply(nonce, false, summary(job)) end
    end
    local a, b = job.drill_entity.bounding_box, job.chest_entity.bounding_box
    local ok, exported = pcall(ctx.export, job.id .. ":blueprint", {
      surface = job.surface, force = job.force,
      x1 = math.min(a.left_top.x, b.left_top.x) + 0.01,
      y1 = math.min(a.left_top.y, b.left_top.y) + 0.01,
      x2 = math.max(a.right_bottom.x, b.right_bottom.x) - 0.01,
      y2 = math.max(a.right_bottom.y, b.right_bottom.y) - 0.01,
    })
    if ok and exported.ok and exported.entities == 2 then
      helpers.write_file(job.artifact .. ".blueprint.txt", exported.blueprint .. "\n", false)
    end
    job.baseline = job.chest_entity.get_inventory(defines.inventory.chest).get_item_count("coal")
    job.deadline, job.state = game.tick + 1800, "auditing"
    save(job)
    return reply(nonce, true, summary(job))
  end
  function M.tick()
    for _, job in pairs(jobs()) do
      if job.state == "auditing" or job.state == "verified" then refuel(job) end
      if job.state == "auditing" and game.tick >= job.deadline then
        local drill, chest = job.drill_entity, job.chest_entity
        local count = chest and chest.valid and chest.get_inventory(defines.inventory.chest)
          .get_item_count("coal") or 0
        local pass = drill and drill.valid and chest and chest.valid and count > job.baseline
        job.audit = {status = pass and "passed" or "failed", coal_gained = count - job.baseline,
          window_ticks = 1800}
        job.state = pass and "verified" or "needs-attention"
        if not pass then job.error = "no-measured-coal-output" end
        save(job)
        helpers.write_file(job.artifact .. ".audit.json", helpers.table_to_json(job.audit), false)
      end
    end
  end
  function M.status(nonce, request)
    local job = jobs()[request.job_id]
    if not job then return reply(nonce, false, {error = "coal-job-not-found"}) end
    return reply(nonce, true, summary(job))
  end
  return M
end

return M
