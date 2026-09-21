-- Engine test: ghost-mode executor. A plan that does not fit and cannot be afforded yet
-- still lands as ghosts, waits on the ground, and finishes itself when stock arrives.
return function(handlers,state,bp)
  local result={ok=false,checks={}}
  local function check(v,name) assert(v,name) result.checks[#result.checks+1]=name end
  local function call(action,body) return handlers[action]("ghostbuild-"..game.tick..":"..#result.checks,body) end
  local surface,stock,job,job2,job3,phase,mark,done,blocker,parked=nil,nil,nil,nil,nil,0,0,false,nil,nil
  local job4,feeder,bystander,job5,job6,job7,job8,cliff=nil,nil,nil,nil,nil,nil,nil,nil
  local dropA,dropB=nil,nil
  local CONTRACT={site={mode="exact",rotations={0}},build={mode="ghost"}}
  script.on_event(defines.events.on_tick,function()
    if done then return end
    local ok,err=pcall(function()
      if phase==0 then
        phase=1
        local player=game.get_player(1) stock=player.get_main_inventory()
        surface=game.create_surface("ghostbuild-test",{autoplace_settings={entity={treat_missing_as_default=false,settings={}},decorative={treat_missing_as_default=false,settings={}}}})
        surface.request_to_generate_chunks({0,0},2) surface.force_generate_chunk_requests()
        for _,e in pairs(surface.find_entities()) do e.destroy() end
        local tiles={} for x=-40,40 do for y=-40,40 do tiles[#tiles+1]={name="grass-1",position={x,y}} end end
        surface.set_tiles(tiles)
        player.teleport({30.5,30.5},surface)
        state().treasury_entity=nil state().treasury_unit_number=nil state().autofuel_enabled=false
        stock.clear()
        for _,name in ipairs{"iron-gear-wheel","wooden-chest","small-electric-pole","assembling-machine-1"} do
          game.forces.player.recipes[name].enabled=true
        end

        -- Ghosts a human pasted, of three different footprints: a 3x3 drill centres on
        -- .5, a 2x2 furnace on an integer, a 1x1 pole on .5. Any anchor taken from entity
        -- CENTRES is off by half a footprint for at least one of them, which is how a
        -- rebuilt set landed one tile east of the original (21/09, exec-24). The export's
        -- anchor is the top-left TILE EDGE, the same frame the executor plans in.
        for _,g in ipairs{{"electric-mining-drill",-27.5,-9.5,0},{"stone-furnace",-24,-6,0},
          {"small-electric-pole",-21.5,-9.5,0}} do
          surface.create_entity{name="entity-ghost",inner_name=g[1],position={g[2],g[3]},
            direction=g[4],force="player"}
        end
        local ex=call("blueprint_export",{surface=surface.name,x1=-30,y1=-12,x2=-18,y2=-2})
        check(ex.ok and ex.entities==3,"ghost-export:"..tostring(ex.entities)..":"..tostring(ex.error))
        check(ex.anchor and ex.anchor.x==-29 and ex.anchor.y==-11,
          "export-anchor-is-tile-edge:"..helpers.table_to_json(ex.anchor))
        -- Handing that anchor straight back must reproduce the SOURCE geometry: same
        -- site, same bbox. A drift of one tile shows up here as a bbox one tile off.
        local back=call("blueprint_run",{blueprint=ex.blueprint,surface=surface.name,
          x=ex.anchor.x,y=ex.anchor.y,contract=CONTRACT,dry_run=true})
        check(back.ok and back.site.x==ex.anchor.x and back.site.y==ex.anchor.y,
          "anchor-round-trips:"..helpers.table_to_json(back.site))
        -- plan.bbox is measured in entity CENTRES while the anchor is a tile EDGE: the
        -- two frames differ by half a footprint and reading one as the other is the whole
        -- bug. Centres are what must come back unchanged -- the drill centre, and the pole
        -- centre, exactly where the human's ghosts stand.
        check(back.plan.bbox[1]==-27.5 and back.plan.bbox[2]==-9.5 and back.plan.bbox[3]==-21.5
          and back.plan.bbox[4]==-6,"planned-centres-match-ghosts:"..helpers.table_to_json(back.plan.bbox))
        for _,g in pairs(surface.find_entities_filtered{type="entity-ghost",
          area={{-30,-12},{-18,-2}}}) do g.destroy() end

        -- A blueprint bigger than the old hand-cut limit is now one paste.
        local big=call("blueprint_run",{blueprint=bp.wide,surface=surface.name,x=0,y=20,
          contract=CONTRACT,dry_run=true})
        check(big.ok and big.state=="planned" and big.plan.count==70 and not big.placed_at,
          "over-64-entities-accepted:"..tostring(big.state)..":"..tostring(big.error))

        -- maintainer's own starter base is 508 entities: past the old 500 cap, so a real
        -- blueprint of that size has to plan in one piece, not in hand-cut halves.
        local huge=call("blueprint_run",{blueprint=bp.huge,surface=surface.name,x=0,y=-30,
          contract=CONTRACT,dry_run=true})
        check(huge.ok and huge.state=="planned" and huge.plan.count==520
          and huge.plan.entities["transport-belt"]==520,
          "over-500-entities-accepted:"..tostring(huge.state)..":"..tostring(huge.error))

        -- A character standing on the site used to refuse the whole plan. It is the one
        -- blocker that walks away by itself, so ghost mode plans anyway.
        -- A benchmark player may have no character entity at all, so place one.
        local walker=surface.create_entity{name="character",position={0.5,-29.5},force="player"}
        local onchar=call("blueprint_run",{blueprint=bp.huge,surface=surface.name,x=0,y=-30,
          contract=CONTRACT,dry_run=true})
        check(onchar.ok and onchar.state=="planned",
          "character-does-not-refuse-ghost-site:"..tostring(onchar.state)..":"..tostring(onchar.error))
        local direct=call("blueprint_run",{blueprint=bp.huge,surface=surface.name,x=0,y=-30,
          contract={site={mode="exact",rotations={0}}},dry_run=true})
        check(direct.state=="blocked" and direct.rejects and direct.rejects.character==1,
          "direct-mode-still-refuses-character:"..helpers.table_to_json(direct.rejects))
        walker.destroy()

        -- One planned tile is taken by something else, and the bag holds ONE chest of the
        -- two the plan wants. Both used to refuse the whole build.
        blocker=surface.create_entity{name="stone-furnace",position={4.5,1.5},force="player"}
        stock.insert{name="wooden-chest",count=1}
        local probe=call("blueprint_import",{blueprint=bp.plan,surface=surface.name,x=10,y=10,mode="ghosts"})
        check(probe.ok and probe.ghosts==4,"handler-ghost-paste:"..helpers.table_to_json(probe))
        for _,g in pairs(surface.find_entities_filtered{name="entity-ghost"}) do g.destroy() end
        -- ...and a character parked ON a planned tile is waiting, never a dead blocker.
        parked=surface.create_entity{name="character",position={1.5,0.5},force="player"}
        job=call("blueprint_run",{blueprint=bp.plan,surface=surface.name,x=0,y=0,contract=CONTRACT})
        check(job.ok and job.job_id,"ghost-run-started:"..helpers.table_to_json(job))
        mark=game.tick
      elseif phase==1 and game.tick-mark>=120 then
        phase=2
        local s=call("blueprint_job",{job_id=job.job_id})
        check(s.state=="building","waiting-job-stays-building:"..helpers.table_to_json(s))
        check(s.placed==1,"one-affordable-entity-built:"..tostring(s.placed))
        check(s.pending and s.pending>0,"rest-pending:"..tostring(s.pending))
        check(s.waiting and s.waiting["small-electric-pole"],"names-what-it-waits-for:"..helpers.table_to_json(s.waiting))
        check(s.standing and s.standing[1] and s.standing[1][2]==1.5,
          "character-tile-is-standing-not-blocked:"..helpers.table_to_json(s.standing))
        for _,b in pairs(s.blocked or {}) do assert(b.x~=1.5,"character-tile-not-in-blocked") end
        check(true,"character-tile-not-in-blocked")
        parked.destroy()
        check(surface.find_entity("entity-ghost",{1.5,0.5})~=nil,"unaffordable-entity-is-a-ghost")
        -- Stock arrives: nobody re-runs the job, it just finishes.
        stock.insert{name="wooden-chest",count=1}
        stock.insert{name="small-electric-pole",count=1}
        stock.insert{name="assembling-machine-1",count=1}
        mark=game.tick
      elseif phase==2 and game.tick-mark>=120 then
        phase=3
        local s=call("blueprint_job",{job_id=job.job_id})
        check(surface.find_entity("wooden-chest",{1.5,0.5})~=nil,"built-itself-when-stock-arrived")
        check(surface.find_entity("small-electric-pole",{2.5,0.5})~=nil,"pole-built")
        -- The blocked tile is not silently forgotten: it is named, with coordinates.
        check(s.state=="needs-attention" and s.error=="blueprint-blocked:1",
          "blocked-tile-named:"..tostring(s.error))
        check(s.blocked and s.blocked[1] and s.blocked[1].name=="assembling-machine-1"
          and s.blocked[1].x==4.5,"blocked-entry-carries-coords:"..helpers.table_to_json(s.blocked))
        check(stock.get_item_count("assembling-machine-1")==1,"blocked-entity-was-not-charged")
        blocker.destroy()
        local r=call("blueprint_job",{job_id=job.job_id,resume=true})
        check(r.ok,"resume-accepted:"..tostring(r.error))
        mark=game.tick
      elseif phase==3 and game.tick-mark>=120 then
        local s=call("blueprint_job",{job_id=job.job_id})
        local built=surface.find_entity("assembling-machine-1",{4.5,1.5})
        check(built~=nil,"freed-tile-built-on-resume")
        check(built and built.get_recipe() and built.get_recipe().name=="iron-gear-wheel",
          "recipe-survived-the-wait")
        check(s.state=="verified" and not s.blocked,"job-finishes:"..tostring(s.state))
        check(stock.get_item_count("assembling-machine-1")==0,"charged-exactly-once")
        check(s.built==4 and (s.existing or 0)==0,
          "this-job-built-all-four:"..tostring(s.built)..":"..tostring(s.existing))
        -- A gathering step that fails at run time (the chest it was going to collect from
        -- is empty by then) used to kill the whole paste with insufficient-items while
        -- still in `preparing`. In ghost mode the step is skipped, named, and the build
        -- goes down anyway.
        -- The bag holds the ingredients when the plan is made, so a craft step IS planned;
        -- they are gone by the time it runs.
        stock.clear()
        stock.insert{name="wood",count=1} stock.insert{name="copper-cable",count=2}
        job2=call("blueprint_run",{blueprint=bp.pole,surface=surface.name,x=10,y=10,
          contract=CONTRACT})
        check(job2.ok and job2.job_id,"second-ghost-run-started:"..tostring(job2.error))
        stock.clear()
        mark=game.tick phase=4
      elseif phase==4 and game.tick-mark>=180 then
        local s=call("blueprint_job",{job_id=job2.job_id})
        check(s.state~="needs-attention" or s.error~="insufficient-items",
          "shortfall-does-not-kill-ghost-job:"..tostring(s.state)..":"..tostring(s.error))
        check(s.skipped and s.skipped[1],"skipped-step-is-named:"..helpers.table_to_json(s.skipped))
        check(s.state=="building" or s.state=="settling" or s.state=="auditing"
          or s.state=="verified","ghost-job-reached-the-ground:"..tostring(s.state))
        check(surface.find_entity("entity-ghost",{10.5,10.5})~=nil,"ghosts-are-down")
        -- Let it finish: blueprint_run hands back the live job instead of starting a
        -- second one, so the next measurement needs this one closed.
        stock.insert{name="small-electric-pole",count=1}
        mark=game.tick phase=5
      elseif phase==5 and game.tick-mark>=180 then
        local s2=call("blueprint_job",{job_id=job2.job_id})
        check(s2.state=="verified" and s2.built==1,
          "skipped-job-still-finishes:"..tostring(s2.state)..":"..tostring(s2.built))
        -- The same plan over a site that already holds it: nothing built, nothing charged,
        -- and the report must not pass the standing base off as this job's work.
        job3=call("blueprint_run",{blueprint=bp.plan,surface=surface.name,x=0,y=0,contract=CONTRACT})
        check(job3.job_id~=job2.job_id,"third-run-is-its-own-job:"..tostring(job3.job_id))
        mark=game.tick phase=6
      elseif phase==6 and game.tick-mark>=180 then
        local s3=call("blueprint_job",{job_id=job3.job_id})
        check((s3.built or 0)==0 and s3.existing==4,
          "already-standing-is-not-built:"..tostring(s3.built)..":"..tostring(s3.existing)
          ..":"..tostring(s3.state))
        check(s3.step<=s3.steps,"step-never-past-the-last-one:"..tostring(s3.step).."/"..tostring(s3.steps))
        -- Every poll used to repeat one row per entity. The digest says the same thing,
        -- and the rows are still one flag away.
        check(not s3.placed_at and s3.plan and s3.plan.count==4 and s3.plan.bbox,
          "report-is-a-digest-not-a-row-per-entity:"..helpers.table_to_json(s3.plan or {}))
        local full=call("blueprint_job",{job_id=job3.job_id,detail=true})
        check(full.placed_at and #full.placed_at==4 and full.plan.count==4,
          "detail-still-returns-the-rows:"..tostring(full.placed_at and #full.placed_at))
        -- A parked plan with nothing in the bag: the pole it needs sits in a declared
        -- supply chest, and nobody calls the bridge again. It has to finish by itself.
        -- The chest is EMPTY when the plan is made, so prepare() cannot gather anything:
        -- the only way this job ever finishes is the restock loop, later, on its own.
        feeder=surface.create_entity{name="wooden-chest",position={20.5,20.5},force="player"}
        -- An undeclared chest holding exactly what the job wants. It must stay full: a
        -- parked plan that quietly drains the base's own chests is the failure mode
        -- supply chests exist to prevent.
        bystander=surface.create_entity{name="wooden-chest",position={18.5,20.5},force="player"}
        bystander.get_inventory(defines.inventory.chest).insert{name="small-electric-pole",count=1}
        stock.clear()
        job4=call("blueprint_run",{blueprint=bp.pole,surface=surface.name,x=24,y=24,
          contract={site={mode="exact",rotations={0}},build={mode="ghost"},
                    supply={{x=20.5,y=20.5}}}})
        check(job4.ok and job4.job_id and job4.job_id~=job3.job_id,
          "supply-job-started:"..tostring(job4.job_id)..":"..tostring(job4.error))
        mark=game.tick phase=7
      elseif phase==7 and game.tick-mark>=120 then
        local parked_s=call("blueprint_job",{job_id=job4.job_id})
        check(parked_s.state=="building" and parked_s.waiting
          and parked_s.waiting["small-electric-pole"]==1,
          "parked-plan-waits:"..tostring(parked_s.state)..":"..helpers.table_to_json(parked_s.waiting or {}))
        -- Delivery arrives. Nobody calls the bridge after this line.
        feeder.get_inventory(defines.inventory.chest).insert{name="small-electric-pole",count=1}
        mark=game.tick phase=8
      elseif phase==8 and game.tick-mark>=700 then
        local s4=call("blueprint_job",{job_id=job4.job_id})
        check(s4.restocked and s4.restocked["small-electric-pole"]==1,
          "pulled-from-the-supply-chest:"..helpers.table_to_json(s4.restocked or {}))
        check(surface.find_entity("small-electric-pole",{24.5,24.5})~=nil,
          "parked-plan-built-itself:"..tostring(s4.state))
        check(feeder.get_inventory(defines.inventory.chest).get_item_count("small-electric-pole")==0,
          "supply-chest-was-emptied")
        check(bystander.get_inventory(defines.inventory.chest).get_item_count("small-electric-pole")==1,
          "undeclared-chest-untouched:"
          ..tostring(bystander.get_inventory(defines.inventory.chest).get_item_count("small-electric-pole")))
        -- Several plans parked at once. A live job used to swallow the next call and hand
        -- its own summary back instead of starting anything.
        stock.clear()
        -- Away from (30.5,30.5): the test player stands there, and a tile under a
        -- character is `standing`, which waits forever by design.
        job5=call("blueprint_run",{blueprint=bp.pole,surface=surface.name,x=30,y=34,contract=CONTRACT})
        job6=call("blueprint_run",{blueprint=bp.pole,surface=surface.name,x=34,y=34,contract=CONTRACT})
        check(job5.ok and job6.ok and job6.job_id and job6.job_id~=job5.job_id,
          "second-plan-parks-beside-the-first:"..tostring(job5.job_id)..":"..tostring(job6.job_id))
        -- Ghosts do not collide, so only the reservation keeps a DIFFERENT plan off job5
        -- tiles. (The same plan at the same anchor is the same job, checked elsewhere.)
        -- This one spans 28.5..32.5 x 34.5..35.5, over job5 pole at (30.5,34.5).
        local clash=call("blueprint_run",{blueprint=bp.plan,surface=surface.name,x=28,y=34,
          contract=CONTRACT})
        check(clash.state=="blocked" and clash.rejects and clash.rejects.job==1,
          "tiles-of-a-live-job-are-not-a-site:"..tostring(clash.state)..":"
          ..helpers.table_to_json(clash.rejects or {}))
        stock.insert{name="small-electric-pole",count=2}
        mark=game.tick phase=9
      elseif phase==9 and game.tick-mark>=180 then
        local s5=call("blueprint_job",{job_id=job5.job_id})
        local s6=call("blueprint_job",{job_id=job6.job_id})
        check(s5.state=="verified" and s6.state=="verified",
          "both-parked-plans-finished:"..tostring(s5.state)..":"..tostring(s6.state))
        check(surface.find_entity("small-electric-pole",{30.5,34.5})~=nil
          and surface.find_entity("small-electric-pole",{34.5,34.5})~=nil,
          "both-poles-on-the-ground")
        -- Water. A pond under the plan is a blocker the job can clear -- but only once the
        -- base can pay for landfill. With the recipe locked and an empty bag it is still a
        -- reject, which is what keeps an early plan off a lake.
        stock.clear()
        local pond={} for x=-20,-19 do for y=-20,-19 do pond[#pond+1]={name="water",position={x,y}} end end
        surface.set_tiles(pond)
        game.forces.player.recipes["landfill"].enabled=false
        local dry=call("blueprint_run",{blueprint=bp.pole,surface=surface.name,x=-20,y=-20,
          contract=CONTRACT})
        check(dry.state=="blocked" and dry.rejects and dry.rejects.water==1,
          "water-is-a-reject-with-no-landfill:"..tostring(dry.state)..":"
          ..helpers.table_to_json(dry.rejects or {}))
        game.forces.player.recipes["landfill"].enabled=true
        job7=call("blueprint_run",{blueprint=bp.pole,surface=surface.name,x=-20,y=-20,
          contract=CONTRACT})
        check(job7.ok and job7.job_id and job7.site and job7.site.fill==1,
          "landfill-is-quoted-with-the-site:"..tostring(job7.error)
          ..":"..tostring(job7.site and job7.site.fill))
        check(job7.materials and job7.materials["landfill"]==1,
          "landfill-is-on-the-bill:"..helpers.table_to_json(job7.materials or {}))
        mark=game.tick phase=10
      elseif phase==10 and game.tick-mark>=120 then
        local s7=call("blueprint_job",{job_id=job7.job_id})
        check(s7.state=="building" and s7.ground and s7.ground["landfill"]==1,
          "plan-parks-on-the-water-it-cannot-fill-yet:"..tostring(s7.state)..":"
          ..helpers.table_to_json(s7.ground or {}))
        check(surface.get_tile(-20,-20).prototype.fluid~=nil,"pond-still-wet-while-unpaid")
        stock.insert{name="landfill",count=1}
        stock.insert{name="small-electric-pole",count=1}
        mark=game.tick phase=11
      elseif phase==11 and game.tick-mark>=180 then
        local s7=call("blueprint_job",{job_id=job7.job_id})
        check(s7.filled==1,"water-was-filled:"..tostring(s7.filled)..":"..tostring(s7.state))
        check(surface.get_tile(-20,-20).prototype.fluid==nil,"tile-is-ground-now")
        check(surface.get_tile(-19,-20).prototype.fluid~=nil,
          "only-the-footprint-tile-was-filled")
        check(stock.get_item_count("landfill")==0,"landfill-was-paid-for")
        check(surface.find_entity("small-electric-pole",{-19.5,-19.5})~=nil,
          "built-on-the-filled-tile:"..tostring(s7.state))
        -- Cliffs. Same shape: a reject while cliff-explosives are out of reach, a clearable
        -- blocker once one is in the bag.
        stock.clear()
        cliff=surface.create_entity{name="cliff",position={-32,-32},cliff_orientation="west-to-east"}
        check(cliff and cliff.valid,"test-cliff-exists")
        -- A cliff's box is 4x4 but it only blocks part of it, so the centre tile can be
        -- perfectly buildable. Aim at a tile the cliff actually refuses.
        local bb=cliff.bounding_box
        local cx,cy
        for x=math.floor(bb.left_top.x),math.ceil(bb.right_bottom.x)-1 do
          for y=math.floor(bb.left_top.y),math.ceil(bb.right_bottom.y)-1 do
            if not cx
              and #surface.find_entities_filtered{area={{x+0.01,y+0.01},{x+0.99,y+0.99}},type="cliff"}>0
              and not surface.can_place_entity{name="small-electric-pole",position={x+0.5,y+0.5},
                force="player"} then
              cx,cy=x,y
            end
          end
        end
        check(cx~=nil,"cliff-blocks-a-tile")
        -- This save has the technology, so lock the recipe to get back the early-game
        -- state the reject is actually about: no explosives, no way to make one.
        game.forces.player.recipes["cliff-explosives"].enabled=false
        local nope=call("blueprint_run",{blueprint=bp.pole,surface=surface.name,x=cx,y=cy,
          contract=CONTRACT})
        check(nope.state=="blocked" and nope.rejects and nope.rejects.cliff==1,
          "cliff-is-a-reject-with-no-explosives:"..tostring(nope.state)..":"
          ..helpers.table_to_json(nope.rejects or {}))
        -- Recipe still locked: one explosive already in the bag is reason enough to try.
        stock.insert{name="cliff-explosives",count=1}
        stock.insert{name="small-electric-pole",count=1}
        job8=call("blueprint_run",{blueprint=bp.pole,surface=surface.name,x=cx,y=cy,
          contract=CONTRACT})
        check(job8.ok and job8.job_id and job8.site and job8.site.blast==1,
          "cliff-is-quoted-with-the-site:"..tostring(job8.error)
          ..":"..tostring(job8.site and job8.site.blast))
        mark=game.tick phase=12
      elseif phase==12 and game.tick-mark>=180 then
        local s8=call("blueprint_job",{job_id=job8.job_id})
        check(s8.blasted==1,"cliff-was-blasted:"..tostring(s8.blasted)..":"..tostring(s8.state))
        check(not (cliff and cliff.valid),"cliff-is-gone")
        check(stock.get_item_count("cliff-explosives")==0,"explosives-were-paid-for")
        check(s8.state=="verified","cliff-site-finished:"..tostring(s8.state)..":"..tostring(s8.error))
        -- drop_ghosts. Two rows of three human chest ghosts, each overlaid by a job plan of
        -- the same three chests anchored ONE TILE EAST (the exec-24 drift): two tiles coincide
        -- and get adopted, one is the job's own. Row A keeps the recorded unit_numbers; row
        -- B has them wiped to stand in for a job from before they were recorded.
        game.forces.player.recipes["iron-chest"].enabled=true
        stock.remove{name="iron-chest",count=1000}
        for _,y in ipairs{30.5,33.5} do
          for _,x in ipairs{-37.5,-36.5,-35.5} do
            surface.create_entity{name="entity-ghost",inner_name="iron-chest",position={x,y},force="player"}
          end
        end
        dropA=call("blueprint_run",{blueprint=bp.chests,surface=surface.name,x=-37,y=30,contract=CONTRACT})
        dropB=call("blueprint_run",{blueprint=bp.chests,surface=surface.name,x=-37,y=33,contract=CONTRACT})
        check(dropA.ok and dropA.job_id and dropB.ok and dropB.job_id,
          "drift-plans-parked:"..tostring(dropA.error)..":"..tostring(dropB.error))
        phase,mark=13,game.tick
      elseif phase==13 and game.tick-mark>=180 then
        local function row(y)
          local n=0
          for _,g in pairs(surface.find_entities_filtered{type="entity-ghost",area={{-39,y-0.5},{-30,y+0.5}}}) do
            if g.ghost_name=="iron-chest" then n=n+1 end
          end
          return n
        end
        check(row(30.5)==4 and row(33.5)==4,"two-sets-on-the-ground:"..row(30.5).."/"..row(33.5))
        local sA=call("blueprint_job",{job_id=dropA.job_id})
        check(sA.replaced==1,"job-laid-one-of-its-own:"..tostring(sA.replaced)..":"..tostring(sA.state))
        -- Row B becomes a legacy job: no recorded units, only replaced_at.
        state().executor_jobs[dropB.job_id].ghost_units=nil
        local dryA=call("drop_ghosts",{job_id=dropA.job_id,dry_run=true})
        check(dryA.ok and dryA.removed==1 and dryA.kept_foreign==2 and dryA.ownership=="recorded",
          "dry-run-counts-recorded:"..helpers.table_to_json(dryA))
        check(row(30.5)==4,"dry-run-removes-nothing:"..row(30.5))
        local dA=call("drop_ghosts",{job_id=dropA.job_id})
        local dB=call("drop_ghosts",{job_id=dropB.job_id})
        check(dA.ok and dA.removed==1 and dA.kept_foreign==2,"recorded-drop:"..helpers.table_to_json(dA))
        check(dB.ok and dB.removed==1 and dB.kept_foreign==2 and dB.ownership=="legacy-floor",
          "legacy-floor-drop:"..helpers.table_to_json(dB))
        -- What is left is exactly the human's three, at the human's tiles.
        for _,y in ipairs{30.5,33.5} do
          check(row(y)==3,"human-set-intact:"..y..":"..row(y))
          for _,x in ipairs{-37.5,-36.5,-35.5} do
            local g=surface.find_entity("entity-ghost",{x,y})
            check(g and g.valid and g.ghost_name=="iron-chest","human-ghost-kept:"..x..","..y)
          end
          check(not surface.find_entity("entity-ghost",{-34.5,y}),"job-ghost-gone:"..y)
        end
        local again=call("blueprint_job",{job_id=dropA.job_id,resume=true})
        check(not again.ok and again.error=="job-ghosts-dropped","dropped-job-cannot-resume:"..tostring(again.error))
        result.ok=true done=true
      end
    end)
    if not ok then result.error,done=tostring(err),true end
    if done then helpers.write_file("ghostbuild-check.json",helpers.table_to_json(result),false) end
  end)
end
