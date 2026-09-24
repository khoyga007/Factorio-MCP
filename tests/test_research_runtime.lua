-- Engine test, 24/09 Celine gaps: trigger techs listed apart from `available`;
-- backlog queues a red tech while the only lab is empty (red already used by a finished tech).
return function(handlers,state)
  local result={ok=false,checks={}}
  local function check(v,name) assert(v,name) result.checks[#result.checks+1]=name end
  local function call(action,body) return handlers[action]("research-"..game.tick..":"..#result.checks,body) end
  local done
  script.on_event(defines.events.on_tick,function()
    if done then return end
    local ok,err=pcall(function()
      local force=game.create_force("research-test")
      local r=call("research",{force="research-test",available=true})
      local listed={} for _,t in ipairs(r.trigger or {}) do listed[t.name]=t end
      local avail={} for _,n in ipairs(r.available or {}) do avail[n]=true end
      check(r.ok and next(listed)~=nil,"trigger-listed:"..helpers.table_to_json(r.trigger or {}))
      for n in pairs(listed) do check(not avail[n],"trigger-not-available:"..n) end
      force.technologies["automation-science-pack"].researched=true
      force.technologies["automation"].researched=true  -- used red: red is fed somehow
      local q=call("research",{force="research-test",backlog={"electric-mining-drill"}})
      check(q.ok and q.queue[1]=="electric-mining-drill","backlog-queues-with-empty-lab:"..helpers.table_to_json(q))
      result.ok=true
    end)
    if not ok then result.error=tostring(err) end
    done=true
    helpers.write_file("research-check.json",helpers.table_to_json(result),false)
  end)
end
