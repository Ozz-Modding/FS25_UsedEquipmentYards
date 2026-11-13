-- YardLayout: rows of vehicles inside a yard's polygon, row depths from the
-- models a yard spawns, and slots within the rows.

local function setup()
    local world = stubs.install()
    world:load("src/YardLayout.lua")
    return world
end

local function rect(x1, z1, x2, z2)
    return { { x = x1, z = z1 }, { x = x2, z = z1 }, { x = x2, z = z2 }, { x = x1, z = z2 } }
end

-- An L: a 80 x 30 strip along x with a 30 x 80 leg up from its left end.
local function lShape()
    return {
        { x = 0, z = 0 }, { x = 80, z = 0 }, { x = 80, z = 30 }, { x = 30, z = 30 },
        { x = 30, z = 80 }, { x = 0, z = 80 },
    }
end

local function rotated(polygon, angle)
    local c, s = math.cos(angle), math.sin(angle)
    local result = {}
    for i, p in ipairs(polygon) do
        result[i] = { x = p.x * c - p.z * s, z = p.x * s + p.z * c }
    end
    return result
end

local function inside(polygon, x, z)
    local result = false
    local j = #polygon
    for i = 1, #polygon do
        local a, b = polygon[i], polygon[j]
        if (a.z > z) ~= (b.z > z) and x < (b.x - a.x) * (z - a.z) / (b.z - a.z) + a.x then
            result = not result
        end
        j = i
    end
    return result
end

local function corners(slot)
    local fx, fz = math.sin(slot.yaw), math.cos(slot.yaw)
    local rx, rz = math.cos(slot.yaw), -math.sin(slot.yaw)
    local hw, hl = slot.width * 0.5, slot.length * 0.5
    local list = {}
    for _, c in ipairs({ { -hw, -hl }, { hw, -hl }, { hw, hl }, { -hw, hl } }) do
        list[#list + 1] = { x = slot.x + rx * c[1] + fx * c[2], z = slot.z + rz * c[1] + fz * c[2] }
    end
    return list
end

local TRACTORS = {
    { length = 4.5, width = 2.4, weight = 10 },
    { length = 5.5, width = 2.6, weight = 5 },
    { length = 6.0, width = 2.8, weight = 1 },
}

local TRAILERS = {
    { length = 8.0, width = 2.5, weight = 3 },
    { length = 11.0, width = 2.55, weight = 4 },
    { length = 14.0, width = 2.55, weight = 3 },
}

local function concat(a, b)
    local result = {}
    for _, v in ipairs(a) do
        result[#result + 1] = v
    end
    for _, v in ipairs(b) do
        result[#result + 1] = v
    end
    return result
end

-- Fill a plan with copies of one model until nothing more fits.
local function fill(plan, width, length, isClear)
    local occupied, slots = {}, {}
    while true do
        local slot = YardLayout.findSlot(plan, occupied, width, length, isClear)
        if slot == nil then
            break
        end
        occupied[#occupied + 1] = { row = slot.row, u1 = slot.u1, u2 = slot.u2 }
        slots[#slots + 1] = slot
        assertTrue(#slots < 1000, "runaway fill")
    end
    return slots, occupied
end

-- Frames -----------------------------------------------------------------------------------

test("local and world frames are inverses", function()
    setup()
    for _, angle in ipairs({ 0, 0.3, math.pi / 2, 2.5 }) do
        local u, v = YardLayout.toLocal(angle, 12.5, -7)
        local x, z = YardLayout.toWorld(angle, u, v)
        assertNear(x, 12.5, 1e-9)
        assertNear(z, -7, 1e-9)
    end
end)

test("root and footprint centre convert both ways", function()
    setup()
    local rx, rz = YardLayout.rootFromCenter(10, 20, 0.7, 0.4, -1.2)
    local cx, cz = YardLayout.centerFromRoot(rx, rz, 0.7, 0.4, -1.2)
    assertNear(cx, 10, 1e-9)
    assertNear(cz, 20, 1e-9)
end)

test("lengthOffset moves the root back along the vehicle's front", function()
    setup()
    -- Facing +z (yaw 0): a footprint centred 1 m ahead of the root.
    local rx, rz = YardLayout.rootFromCenter(0, 0, 0, 0, 1)
    assertNear(rx, 0, 1e-9)
    assertNear(rz, -1, 1e-9)
end)

test("a row facing +v faces along the v axis", function()
    setup()
    -- Angle 0: v is world +z, yaw 0 faces +z.
    assertNear(YardLayout.facingYaw(0, 1), 0, 1e-9)
    assertNear(math.abs(YardLayout.facingYaw(0, -1)), math.pi, 1e-9)
end)

-- Intervals --------------------------------------------------------------------------------

test("a line across a U shape has two inside stretches", function()
    setup()
    local u = {
        { u = 0, v = 0 }, { u = 30, v = 0 }, { u = 30, v = 20 }, { u = 20, v = 20 },
        { u = 20, v = 5 }, { u = 10, v = 5 }, { u = 10, v = 20 }, { u = 0, v = 20 },
    }
    local intervals = YardLayout.lineIntervals(u, 10)
    assertEquals(#intervals, 2)
    assertNear(intervals[1][1], 0, 1e-9)
    assertNear(intervals[1][2], 10, 1e-9)
    assertNear(intervals[2][1], 20, 1e-9)
    assertNear(intervals[2][2], 30, 1e-9)
end)

test("a strip under a slanted edge is as narrow as its tightest line", function()
    setup()
    -- A triangle: the strip v 0..10 is cut by the slanted edge at v = 10.
    local tri = { { u = 0, v = 0 }, { u = 40, v = 0 }, { u = 0, v = 40 } }
    local o = YardLayout.options({ edgeInset = 0 })
    local intervals = YardLayout.stripIntervals(tri, 0, 10, o)
    assertEquals(#intervals, 1)
    assertNear(intervals[1][2], 30, 1e-4, "the top of the strip decides")
end)

test("the edge inset is taken off both ends and short stretches dropped", function()
    setup()
    local square = { { u = 0, v = 0 }, { u = 10, v = 0 }, { u = 10, v = 10 }, { u = 0, v = 10 } }
    local intervals = YardLayout.stripIntervals(square, 0, 5, YardLayout.options({ edgeInset = 1 }))
    assertNear(intervals[1][1], 1, 1e-6)
    assertNear(intervals[1][2], 9, 1e-6)
    local none = YardLayout.stripIntervals(square, 0, 5, YardLayout.options({ edgeInset = 4.5 }))
    assertEquals(#none, 0)
end)

-- Row depths -------------------------------------------------------------------------------

test("a tractor yard gets one shallow depth", function()
    setup()
    local bands = YardLayout.chooseBands(TRACTORS, nil)
    assertEquals(#bands, 1)
    assertNear(bands[1].depth, 6.5, 1e-9, "the longest tractor plus the margin")
    assertNear(bands[1].share, 1, 1e-9)
end)

test("a trailer yard gets depths that hold its longest trailer", function()
    setup()
    local bands = YardLayout.chooseBands(TRAILERS, nil)
    assertTrue(#bands >= 1)
    assertTrue(bands[#bands].depth >= 14.5, "deepest row holds a 14 m trailer")
    assertTrue(bands[1].depth >= 8.5, "no row too shallow for any trailer")
end)

test("a mixed yard splits into shallow and deep rows", function()
    setup()
    local bands = YardLayout.chooseBands(concat(TRACTORS, TRAILERS), nil)
    assertTrue(#bands >= 2)
    assertTrue(bands[1].depth <= 6.5, "tractors keep a shallow depth of their own")
    assertTrue(bands[#bands].depth >= 14.5)
    local total = 0
    for _, band in ipairs(bands) do
        total = total + band.share
    end
    assertNear(total, 1, 1e-9, "shares add up")
end)

test("near-identical lengths don't earn a depth of their own", function()
    setup()
    local models = {
        { length = 5.0, width = 2.5, weight = 1 },
        { length = 5.4, width = 2.5, weight = 1 },
    }
    assertEquals(#YardLayout.chooseBands(models, nil), 1)
end)

test("models longer than the yard can hold are excluded", function()
    setup()
    local bands, excluded = YardLayout.chooseBands(TRAILERS, 12)
    assertTrue(excluded[3], "the 14 m trailer")
    assertTrue(not excluded[1] and not excluded[2])
    assertTrue(bands[#bands].depth <= 12)
end)

test("no models, no bands", function()
    setup()
    local bands = YardLayout.chooseBands({}, nil)
    assertEquals(#bands, 0)
end)

-- Plans ------------------------------------------------------------------------------------

test("a rectangle is laid out in rows along one of its sides", function()
    setup()
    -- Whichever way holds the most row length; here that's across the short
    -- side (8 rows of ~58 m beat 4 of ~98 m).
    local polygon = rect(0, 0, 100, 60)
    local plan = YardLayout.plan(polygon, TRACTORS)
    assertTrue(plan ~= nil)
    assertNear(math.abs(math.sin(plan.angle) * math.cos(plan.angle)), 0, 1e-6, "rows follow an edge")
    assertTrue(#plan.rows >= 4, "several rows: " .. #plan.rows)
    for i, row in ipairs(plan.rows) do
        assertEquals(row.facing, i % 2 == 1 and 1 or -1, "rows alternate to face their aisle")
        assertEquals(#row.intervals, 1)
    end
end)

test("rows facing each other leave an aisle, rows back to back a gap", function()
    setup()
    local o = YardLayout.options()
    local plan = YardLayout.plan(rect(0, 0, 80, 60), TRACTORS)
    local rows = plan.rows
    assertTrue(#rows >= 3)
    assertNear(rows[2].v1 - rows[1].v2, o.aisleWidth, 1e-6)
    assertNear(rows[3].v1 - rows[2].v2, o.backGap, 1e-6)
end)

test("a trailers-only yard isn't left empty: its rows are deep enough", function()
    setup()
    local plan = YardLayout.plan(rect(0, 0, 60, 40), TRAILERS)
    assertTrue(#plan.rows >= 2)
    assertEquals(next(plan.excluded), nil, "every trailer has a row")
    local slots = fill(plan, 2.55, 14.0)
    assertTrue(#slots >= 10, "14 m trailers placed: " .. #slots)
end)

test("a mixed yard gives most of its row length to what it spawns most", function()
    setup()
    local models = {
        { length = 5, width = 2.5, weight = 9 },
        { length = 14, width = 2.5, weight = 1 },
    }
    local plan = YardLayout.plan(rect(0, 0, 80, 80), models)
    local shallow, deep = 0, 0
    for _, row in ipairs(plan.rows) do
        local length = 0
        for _, interval in ipairs(row.intervals) do
            length = length + interval[2] - interval[1]
        end
        if row.depth < 10 then
            shallow = shallow + length
        else
            deep = deep + length
        end
    end
    assertTrue(deep > 0, "the long model still gets a row")
    assertTrue(shallow > deep, "the common model gets more")
end)

test("a yard too narrow for a long model excludes it", function()
    setup()
    -- 20 x 18: at most 10 m of row depth either way once the aisle is taken.
    local plan = YardLayout.plan(rect(0, 0, 20, 18), concat(TRACTORS, TRAILERS))
    assertTrue(plan.excluded[6], "the 14 m trailer")
    assertTrue(plan.excluded[5], "the 11 m trailer")
    assertTrue(not plan.excluded[1], "tractors still fit")
end)

test("a rotated yard's rows follow its edges", function()
    setup()
    local angle = math.rad(30)
    local plan = YardLayout.plan(rotated(rect(0, 0, 80, 40), angle), TRACTORS)
    local diff = math.abs((plan.angle - angle) % math.pi)
    diff = math.min(diff, math.pi - diff)
    assertNear(diff, 0, 1e-6)
end)

test("a fixed angle is respected", function()
    setup()
    local plan = YardLayout.plan(rect(0, 0, 80, 40), TRACTORS, { angle = math.pi / 2 })
    assertNear(plan.angle, math.pi / 2, 1e-9)
end)

test("a degenerate polygon has no plan", function()
    setup()
    assertEquals(YardLayout.plan({ { x = 0, z = 0 }, { x = 1, z = 1 } }, TRACTORS), nil)
end)

test("a spec rebuilds the same rows", function()
    setup()
    local polygon = lShape()
    local plan = YardLayout.plan(polygon, concat(TRACTORS, TRAILERS))
    local again = YardLayout.buildFromSpec(polygon,
        { angle = plan.angle, vStart = plan.vStart, rowDepths = plan.rowDepths }, concat(TRACTORS, TRAILERS))
    assertEquals(#again.rows, #plan.rows)
    for i, row in ipairs(plan.rows) do
        assertNear(again.rows[i].v1, row.v1, 1e-9)
        assertEquals(again.rows[i].depth, row.depth)
        assertEquals(#again.rows[i].intervals, #row.intervals)
    end
end)

test("a saved spec is kept through small changes to the models", function()
    setup()
    local polygon = rect(0, 0, 80, 40)
    local plan = YardLayout.plan(polygon, TRACTORS)
    local spec = { angle = plan.angle, vStart = plan.vStart, rowDepths = plan.rowDepths }
    local slightly = { { length = 4.5, width = 2.4, weight = 10 }, { length = 6.4, width = 2.8, weight = 1 } }
    assertTrue(YardLayout.isSpecCompatible(spec, YardLayout.plan(polygon, slightly)))
    assertTrue(not YardLayout.isSpecCompatible(spec, YardLayout.plan(polygon, TRAILERS)),
        "trailers need other rows")
    assertTrue(not YardLayout.isSpecCompatible(nil, plan))
end)

-- Slots ------------------------------------------------------------------------------------

test("vehicles fill a row from its start, a gap apart, fronts on the aisle", function()
    setup()
    local o = YardLayout.options()
    local plan = YardLayout.plan(rect(0, 0, 80, 40), TRACTORS)
    local occupied = {}
    local first = YardLayout.findSlot(plan, occupied, 2.5, 4.5)
    occupied[1] = { row = first.row, u1 = first.u1, u2 = first.u2 }
    local second = YardLayout.findSlot(plan, occupied, 2.5, 4.5)
    assertEquals(second.row, first.row)
    assertNear(second.u1 - first.u2, o.lotGap, 1e-9)
    local row = plan.rows[first.row]
    local _, v = YardLayout.toLocal(plan.angle, first.x, first.z)
    assertNear(v + row.facing * 4.5 * 0.5, row.frontV, 1e-9, "front on the aisle edge")
end)

test("every placed footprint lies inside the yard, L shape included", function()
    setup()
    local polygon = lShape()
    local plan = YardLayout.plan(polygon, TRACTORS)
    local slots = fill(plan, 2.6, 5.5)
    assertTrue(#slots >= 20, "slots: " .. #slots)
    for _, slot in ipairs(slots) do
        for _, corner in ipairs(corners(slot)) do
            assertTrue(inside(polygon, corner.x, corner.z), "corner outside the yard")
        end
    end
end)

test("both arms of an L are used", function()
    setup()
    local plan = YardLayout.plan(lShape(), TRACTORS)
    local slots = fill(plan, 2.6, 5.5)
    local inLeg, inStrip = 0, 0
    for _, slot in ipairs(slots) do
        if slot.z > 31 then
            inLeg = inLeg + 1
        elseif slot.x > 31 then
            inStrip = inStrip + 1
        end
    end
    assertTrue(inLeg > 0 and inStrip > 0, ("leg %d, strip %d"):format(inLeg, inStrip))
end)

test("no two placed footprints overlap", function()
    setup()
    local plan = YardLayout.plan(rect(0, 0, 60, 50), concat(TRACTORS, TRAILERS))
    local occupied = {}
    local sizes = { { 2.5, 4.5 }, { 2.55, 14 }, { 2.8, 6 }, { 2.5, 11 } }
    local placed = {}
    for i = 1, 200 do
        local size = sizes[(i - 1) % #sizes + 1]
        local slot = YardLayout.findSlot(plan, occupied, size[1], size[2])
        if slot ~= nil then
            occupied[#occupied + 1] = { row = slot.row, u1 = slot.u1, u2 = slot.u2 }
            placed[#placed + 1] = slot
        end
    end
    for i = 1, #placed do
        for j = i + 1, #placed do
            local a, b = placed[i], placed[j]
            if a.row == b.row then
                assertTrue(a.u2 <= b.u1 or b.u2 <= a.u1, "overlap along a row")
            else
                local ra, rb = plan.rows[a.row], plan.rows[b.row]
                assertTrue(ra.v2 <= rb.v1 or rb.v2 <= ra.v1, "rows overlap")
            end
        end
    end
end)

test("a vehicle goes in the shallowest row that holds it", function()
    setup()
    local plan = YardLayout.plan(rect(0, 0, 80, 60), concat(TRACTORS, TRAILERS))
    local short = YardLayout.findSlot(plan, {}, 2.5, 4.5)
    local long = YardLayout.findSlot(plan, {}, 2.5, 13.5)
    assertTrue(plan.rows[short.row].depth < plan.rows[long.row].depth)
    assertTrue(plan.rows[long.row].depth >= 14)
end)

test("short vehicles spill into deep rows once the shallow ones are full", function()
    setup()
    local plan = YardLayout.plan(rect(0, 0, 80, 60), concat(TRACTORS, TRAILERS))
    local slots = fill(plan, 2.5, 4.5)
    local usedDeep = false
    for _, slot in ipairs(slots) do
        if plan.rows[slot.row].depth >= 10 then
            usedDeep = true
        end
    end
    assertTrue(usedDeep)
end)

test("a vetoed spot slides along the row", function()
    setup()
    local o = YardLayout.options()
    local plan = YardLayout.plan(rect(0, 0, 80, 40), TRACTORS)
    local free = YardLayout.findSlot(plan, {}, 2.5, 4.5)
    local blockedAt = free.u1
    local slot = YardLayout.findSlot(plan, {}, 2.5, 4.5, function(candidate)
        return not (candidate.row == free.row and candidate.u1 < blockedAt + 3)
    end)
    assertEquals(slot.row, free.row)
    assertNear(slot.u1, blockedAt + 3 * o.slideStep, 1e-9)
end)

test("a full yard has no slot", function()
    setup()
    local plan = YardLayout.plan(rect(0, 0, 30, 20), TRACTORS)
    local slots, occupied = fill(plan, 2.5, 4.5)
    assertTrue(#slots > 0)
    assertEquals(YardLayout.findSlot(plan, occupied, 2.5, 4.5), nil)
end)

test("free space agrees with findSlot", function()
    setup()
    local plan = YardLayout.plan(rect(0, 0, 60, 50), concat(TRACTORS, TRAILERS))
    local occupied = {}
    for i = 1, 60 do
        local width, length = (i % 3 == 0) and 2.55 or 2.5, (i % 3 == 0) and 14 or 5
        local free = YardLayout.freeSpace(plan, occupied)
        local fits = YardLayout.fitsFreeSpace(free, width, length)
        local slot = YardLayout.findSlot(plan, occupied, width, length)
        assertEquals(fits, slot ~= nil, "vehicle " .. i)
        if slot ~= nil then
            occupied[#occupied + 1] = { row = slot.row, u1 = slot.u1, u2 = slot.u2 }
        end
    end
end)

test("a vehicle parked in its slot matches it; one off it doesn't", function()
    setup()
    local plan = YardLayout.plan(rect(0, 0, 80, 40), TRACTORS)
    local slot = YardLayout.findSlot(plan, {}, 2.5, 4.5)
    local occ = YardLayout.matchFootprint(plan, {}, slot.x, slot.z, slot.yaw, 2.5, 4.5)
    assertTrue(occ ~= nil)
    assertEquals(occ.row, slot.row)
    assertNear(occ.u1, slot.u1, 1e-6)
    assertEquals(YardLayout.matchFootprint(plan, {}, slot.x, slot.z + 1.5, slot.yaw, 2.5, 4.5), nil,
        "off its row line")
    assertEquals(YardLayout.matchFootprint(plan, {}, slot.x, slot.z, slot.yaw + math.pi / 2, 2.5, 4.5), nil,
        "turned")
    assertEquals(YardLayout.matchFootprint(plan, { occ }, slot.x, slot.z, slot.yaw, 2.5, 4.5), nil,
        "already taken")
end)

test("the capacity estimate is close to what actually fits", function()
    setup()
    local models = { { length = 5, width = 2.5, weight = 1 } }
    local plan = YardLayout.plan(rect(0, 0, 80, 50), models)
    local estimate = YardLayout.estimateCapacity(plan, models)
    local slots = fill(plan, 2.5, 5)
    assertEquals(estimate, #slots)
end)
