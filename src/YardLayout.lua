-- YardLayout
-- Pure geometry for laying a yard out in rows (no engine calls, so it is unit
-- tested outside the game: tests/test_yardLayout.lua).
--
-- A yard's polygon is sliced into strips along a row direction (angle):
--
--   row (facing +v) | aisle | row (facing -v) | back gap | row (facing +v) | aisle | ...
--
-- Every row faces an aisle with its vehicles' fronts on the aisle edge, so
-- short and long machines in a row line up at the front. Each row has its own
-- depth, chosen from the lengths of the models the yard can spawn
-- (chooseBands): a trailers-only yard gets deep rows, a tractor yard shallow
-- ones, a mixed yard a mix in proportion to what it spawns.
--
-- Frames: u runs along the rows, v across them.
--   u axis = (cos a, sin a), v axis = (-sin a, cos a) in world (x, z).
-- Yaw follows the game's convention: forward = (sin yaw, cos yaw), and the
-- vehicle's local x axis = (cos yaw, -sin yaw).
--
-- A plan = {
--   angle, vStart, rowDepths   -- the spec: enough to rebuild the same rows
--   rows = { { index, depth, facing (1|-1), v1, v2, frontV, intervals = { {a, b} } } }
--   bands = { { depth, share } }  -- distinct depths and the demand share they serve
--   excluded = { [modelIndex] = true }  -- models no row can hold
--   score                        -- total usable row length (m)
-- }
-- Occupancy is a list of { row, u1, u2 } (footprint extents along the row, no gap).

YardLayout = {}

YardLayout.DEFAULTS = {
    aisleWidth = 8,         -- room to drive a vehicle out / hitch a trailer
    backGap = 1.0,          -- between rows parked back to back
    lotGap = 1.5,           -- between neighbouring vehicles in a row
    edgeInset = 1.0,        -- kept clear of the polygon edge along a row
    lengthMargin = 0.5,     -- added to a vehicle's length to pick its row depth
    minInterval = 2.0,      -- shorter usable stretches of a row are dropped
    maxBands = 3,           -- most distinct row depths in one yard
    bandImprovement = 0.2,  -- an extra depth must cut wasted depth by this share...
    bandMinGain = 0.05,     -- ...and by this share of the total demanded area
    minBandStep = 3.0,      -- distinct row depths differ by at least this (m)
    depthRound = 0.5,       -- row depths are multiples of this
    rowTolerance = 0.3,     -- matching a parked vehicle to a row (m)
    yawTolerance = math.rad(10),
    slideStep = 1.0,        -- when a spot is blocked, slide along the row by this
    angleDedupe = math.rad(2),
    preferTolerance = 0.03, -- angles scoring within this share of the best count as equal
    angleHysteresis = math.rad(1),
    depthHysteresis = 1.0,  -- saved row depths are kept while within this of the ideal
}

local EPS = 1e-6

local function merge(options)
    local o = {}
    for k, v in pairs(YardLayout.DEFAULTS) do
        o[k] = v
    end
    for k, v in pairs(options or {}) do
        o[k] = v
    end
    return o
end
YardLayout.options = merge

-- ---------------------------------------------------------------------------
-- Frames
-- ---------------------------------------------------------------------------

function YardLayout.toLocal(angle, x, z)
    local c, s = math.cos(angle), math.sin(angle)
    return x * c + z * s, -x * s + z * c
end

function YardLayout.toWorld(angle, u, v)
    local c, s = math.cos(angle), math.sin(angle)
    return u * c - v * s, u * s + v * c
end

--- The yaw of a vehicle facing a row's aisle.
function YardLayout.facingYaw(angle, facing)
    -- v axis in world, times facing.
    local dx, dz = -math.sin(angle) * facing, math.cos(angle) * facing
    return math.atan2(dx, dz)
end

--- Where a vehicle's root goes so its footprint is centred on (cx, cz).
--- widthOffset is along the vehicle's local x, lengthOffset along its front.
function YardLayout.rootFromCenter(cx, cz, yaw, widthOffset, lengthOffset)
    local wo, lo = widthOffset or 0, lengthOffset or 0
    local xx, xz = math.cos(yaw), -math.sin(yaw)
    local fx, fz = math.sin(yaw), math.cos(yaw)
    return cx - xx * wo - fx * lo, cz - xz * wo - fz * lo
end

--- The inverse of rootFromCenter.
function YardLayout.centerFromRoot(rx, rz, yaw, widthOffset, lengthOffset)
    local wo, lo = widthOffset or 0, lengthOffset or 0
    local xx, xz = math.cos(yaw), -math.sin(yaw)
    local fx, fz = math.sin(yaw), math.cos(yaw)
    return rx + xx * wo + fx * lo, rz + xz * wo + fz * lo
end

local function localPolygon(polygon, angle)
    local pts = {}
    local vMin, vMax = math.huge, -math.huge
    for i, p in ipairs(polygon) do
        local u, v = YardLayout.toLocal(angle, p.x, p.z)
        pts[i] = { u = u, v = v }
        vMin, vMax = math.min(vMin, v), math.max(vMax, v)
    end
    return pts, vMin, vMax
end

-- ---------------------------------------------------------------------------
-- Intervals
-- ---------------------------------------------------------------------------

--- The stretches of the line v = const inside the polygon (local points),
--- sorted: { {a, b}, ... }.
function YardLayout.lineIntervals(pts, v)
    local crossings = {}
    local n = #pts
    local j = n
    for i = 1, n do
        local a, b = pts[i], pts[j]
        if (a.v > v) ~= (b.v > v) then
            crossings[#crossings + 1] = a.u + (v - a.v) * (b.u - a.u) / (b.v - a.v)
        end
        j = i
    end
    table.sort(crossings)
    local intervals = {}
    for k = 1, #crossings - 1, 2 do
        intervals[#intervals + 1] = { crossings[k], crossings[k + 1] }
    end
    return intervals
end

local function intersectIntervals(a, b)
    local result = {}
    local i, j = 1, 1
    while i <= #a and j <= #b do
        local lo = math.max(a[i][1], b[j][1])
        local hi = math.min(a[i][2], b[j][2])
        if hi > lo then
            result[#result + 1] = { lo, hi }
        end
        if a[i][2] < b[j][2] then
            i = i + 1
        else
            j = j + 1
        end
    end
    return result
end

--- The stretches along u where the whole strip v1..v2 is inside the polygon,
--- shrunk by edgeInset at each end and with short ones dropped.
---
--- Exact for a simple polygon: between vertex heights the edges are straight,
--- so the strip's tightest cross-sections are at v1, v2 and the vertex
--- heights in between.
function YardLayout.stripIntervals(pts, v1, v2, o)
    local samples = { v1 + EPS, v2 - EPS }
    for _, p in ipairs(pts) do
        if p.v > v1 and p.v < v2 then
            samples[#samples + 1] = p.v - EPS
            samples[#samples + 1] = p.v + EPS
        end
    end
    local result = nil
    for _, v in ipairs(samples) do
        local line = YardLayout.lineIntervals(pts, v)
        result = result == nil and line or intersectIntervals(result, line)
        if #result == 0 then
            return result
        end
    end
    local shrunk = {}
    for _, interval in ipairs(result) do
        local a, b = interval[1] + o.edgeInset, interval[2] - o.edgeInset
        if b - a >= o.minInterval then
            shrunk[#shrunk + 1] = { a, b }
        end
    end
    return shrunk
end

local function intervalsLength(intervals)
    local total = 0
    for _, interval in ipairs(intervals) do
        total = total + interval[2] - interval[1]
    end
    return total
end

-- ---------------------------------------------------------------------------
-- Row depths from the models a yard spawns
-- ---------------------------------------------------------------------------

local function roundUp(value, step)
    return math.ceil(value / step - EPS) * step
end

--- Pick 1..maxBands row depths for a set of models.
--- models: { { length, width, weight } }. maxDepth: deepest row the yard can
--- hold (nil: no limit). Returns bands { { depth, share } } ascending by depth
--- (share = the part of the demand, weight x width, each depth serves) and
--- excluded { [index] = true } for models longer than maxDepth.
---
--- The depths minimise wasted depth (row depth - vehicle length), weighted by
--- how often each model spawns and how much row it takes. A second or third
--- depth is only added when it cuts that waste noticeably.
function YardLayout.chooseBands(models, maxDepth, options)
    local o = merge(options)
    local excluded = {}
    local items = {}
    for index, model in ipairs(models) do
        local need = (model.length or 0) + o.lengthMargin
        local demand = (model.weight or 0) * ((model.width or 0) + o.lotGap)
        if maxDepth ~= nil and need > maxDepth + EPS then
            excluded[index] = true
        elseif demand > 0 then
            items[#items + 1] = { need = need, depth = roundUp(need, o.depthRound), demand = demand }
        end
    end
    if #items == 0 then
        return {}, excluded
    end

    -- Candidate depths and, per candidate, the demand (A) and demand x need (B)
    -- of the items that round up to it.
    local byDepth = {}
    for _, item in ipairs(items) do
        local entry = byDepth[item.depth]
        if entry == nil then
            entry = { depth = item.depth, a = 0, b = 0 }
            byDepth[item.depth] = entry
        end
        entry.a = entry.a + item.demand
        entry.b = entry.b + item.demand * item.need
    end
    local candidates = {}
    for _, entry in pairs(byDepth) do
        candidates[#candidates + 1] = entry
    end
    table.sort(candidates, function(x, y)
        return x.depth < y.depth
    end)
    local n = #candidates
    local prefixA, prefixB = { [0] = 0 }, { [0] = 0 }
    for i = 1, n do
        prefixA[i] = prefixA[i - 1] + candidates[i].a
        prefixB[i] = prefixB[i - 1] + candidates[i].b
    end
    -- Waste of one band covering candidates i+1..j at depth candidates[j].
    local function cost(i, j)
        return candidates[j].depth * (prefixA[j] - prefixA[i]) - (prefixB[j] - prefixB[i])
    end

    local maxK = math.min(o.maxBands, n)
    local best, from = {}, {}
    best[1], from[1] = {}, {}
    for j = 1, n do
        best[1][j] = cost(0, j)
    end
    for k = 2, maxK do
        best[k], from[k] = {}, {}
        for j = 1, k - 1 do
            best[k][j] = math.huge
        end
        for j = k, n do
            local bestCost, bestI = math.huge, nil
            for i = k - 1, j - 1 do
                local c = best[k - 1][i] + cost(i, j)
                if c < bestCost and candidates[j].depth - candidates[i].depth >= o.minBandStep - EPS then
                    bestCost, bestI = c, i
                end
            end
            best[k][j], from[k][j] = bestCost, bestI
        end
    end

    local totalArea = prefixB[n]
    local chosenK = 1
    for k = 2, maxK do
        local current, candidate = best[chosenK][n], best[k][n]
        local gain = current - candidate
        if gain >= current * o.bandImprovement and gain >= totalArea * o.bandMinGain then
            chosenK = k
        end
    end

    -- Walk back to the band boundaries.
    local ends = {}
    local j = n
    for k = chosenK, 1, -1 do
        table.insert(ends, 1, j)
        if k > 1 then
            j = from[k][j]
        end
    end
    local bands = {}
    local previous = 0
    for _, e in ipairs(ends) do
        bands[#bands + 1] = {
            depth = candidates[e].depth,
            share = (prefixA[e] - prefixA[previous]) / prefixA[n],
        }
        previous = e
    end
    return bands, excluded
end

-- ---------------------------------------------------------------------------
-- Rows
-- ---------------------------------------------------------------------------

local function makeRow(pts, index, depth, facing, v1, o)
    local v2 = v1 + depth
    return {
        index = index,
        depth = depth,
        facing = facing,
        v1 = v1,
        v2 = v2,
        frontV = facing == 1 and v2 or v1,
        intervals = YardLayout.stripIntervals(pts, v1, v2, o),
    }
end

-- How far the pattern reaches once a row of this depth is added at cursor,
-- and where the next row starts.
local function rowExtent(rowNumber, depth, cursor, o)
    if rowNumber % 2 == 1 then
        local reach = cursor + depth + o.aisleWidth
        return reach, reach
    end
    return cursor + depth, cursor + depth + o.backGap
end

--- Build rows from a depth sequence, starting at vStart and never reaching
--- past vLimit. Returns rows and how far across they reach.
local function buildRows(pts, vStart, vLimit, depths, o)
    local rows = {}
    local cursor, reach = vStart, vStart
    for i, depth in ipairs(depths) do
        local rowReach, nextCursor = rowExtent(i, depth, cursor, o)
        if rowReach > vLimit + EPS then
            break
        end
        rows[#rows + 1] = makeRow(pts, #rows + 1, depth, i % 2 == 1 and 1 or -1, cursor, o)
        reach, cursor = rowReach, nextCursor
    end
    return rows, reach
end

--- Choose each row's depth in turn, giving the next row to the depth whose
--- share of row length is furthest below its share of demand. Falls back to
--- shallower depths when the preferred one doesn't fit the space left.
local function generateDepths(pts, vStart, vLimit, bands, o)
    local depths = {}
    local allocated = {}
    for b = 1, #bands do
        allocated[b] = 0
    end
    local total = 0
    local cursor = vStart
    while true do
        local rowNumber = #depths + 1
        local order = {}
        for b = 1, #bands do
            order[b] = b
        end
        table.sort(order, function(x, y)
            local dx = bands[x].share - (total > 0 and allocated[x] / total or 0)
            local dy = bands[y].share - (total > 0 and allocated[y] / total or 0)
            if math.abs(dx - dy) > EPS then
                return dx > dy
            end
            return bands[x].depth > bands[y].depth
        end)
        local chosen, chosenLength, chosenNext = nil, 0, nil
        for _, b in ipairs(order) do
            local depth = bands[b].depth
            local rowReach, nextCursor = rowExtent(rowNumber, depth, cursor, o)
            if rowReach <= vLimit + EPS then
                local facing = rowNumber % 2 == 1 and 1 or -1
                chosen = b
                chosenLength = intervalsLength(makeRow(pts, rowNumber, depth, facing, cursor, o).intervals)
                chosenNext = nextCursor
                break
            end
        end
        if chosen == nil then
            break
        end
        depths[rowNumber] = bands[chosen].depth
        allocated[chosen] = allocated[chosen] + chosenLength
        total = total + chosenLength
        cursor = chosenNext
    end
    return depths
end

local function scoreRows(rows)
    local total = 0
    for _, row in ipairs(rows) do
        total = total + intervalsLength(row.intervals)
    end
    return total
end

--- Models the plan can't hold: too long for every row with usable space, or
--- too wide for every stretch.
local function findExcluded(rows, models, excluded, o)
    local result = {}
    for index in pairs(excluded) do
        result[index] = true
    end
    for index, model in ipairs(models) do
        if not result[index] then
            local need = (model.length or 0) + o.lengthMargin
            local fits = false
            for _, row in ipairs(rows) do
                if row.depth + EPS >= need then
                    for _, interval in ipairs(row.intervals) do
                        if interval[2] - interval[1] + EPS >= (model.width or 0) then
                            fits = true
                            break
                        end
                    end
                end
                if fits then
                    break
                end
            end
            if not fits then
                result[index] = true
            end
        end
    end
    return result
end

--- Candidate row directions: each edge's direction and its perpendicular,
--- longest edge first, duplicates dropped.
function YardLayout.candidateAngles(polygon, options)
    local o = merge(options)
    local edges = {}
    local n = #polygon
    for i = 1, n do
        local a, b = polygon[i], polygon[i % n + 1]
        local dx, dz = b.x - a.x, b.z - a.z
        local length = math.sqrt(dx * dx + dz * dz)
        if length > EPS then
            edges[#edges + 1] = { angle = math.atan2(dz, dx), length = length }
        end
    end
    table.sort(edges, function(x, y)
        return x.length > y.length
    end)
    local angles = {}
    local function normalise(angle)
        angle = angle % math.pi
        if angle < 0 then
            angle = angle + math.pi
        end
        return angle
    end
    local function add(angle)
        angle = normalise(angle)
        for _, existing in ipairs(angles) do
            local diff = math.abs(existing - angle)
            diff = math.min(diff, math.pi - diff)
            if diff < o.angleDedupe then
                return
            end
        end
        angles[#angles + 1] = angle
    end
    for _, edge in ipairs(edges) do
        add(edge.angle)
        add(edge.angle + math.pi / 2)
    end
    if #angles == 0 then
        angles[1] = 0
    end
    return angles
end

--- Build the rows for a saved spec { angle, vStart, rowDepths }.
function YardLayout.buildFromSpec(polygon, spec, models, options)
    local o = merge(options)
    local pts, _, vMax = localPolygon(polygon, spec.angle)
    local rows = buildRows(pts, spec.vStart, vMax - o.edgeInset, spec.rowDepths, o)
    local plan = {
        angle = spec.angle,
        vStart = spec.vStart,
        rowDepths = {},
        rows = rows,
        score = scoreRows(rows),
    }
    for i, row in ipairs(rows) do
        plan.rowDepths[i] = row.depth
    end
    plan.bands = YardLayout.bandsOfRows(rows)
    plan.excluded = findExcluded(rows, models or {}, {}, o)
    return plan
end

--- The distinct depths of a plan's rows: { { depth, share } } where share is
--- the depth's part of the total row length.
function YardLayout.bandsOfRows(rows)
    local byDepth, total = {}, 0
    for _, row in ipairs(rows) do
        local length = intervalsLength(row.intervals)
        byDepth[row.depth] = (byDepth[row.depth] or 0) + length
        total = total + length
    end
    local bands = {}
    for depth, length in pairs(byDepth) do
        bands[#bands + 1] = { depth = depth, share = total > 0 and length / total or 0 }
    end
    table.sort(bands, function(x, y)
        return x.depth < y.depth
    end)
    return bands
end

--- Lay a yard out for a set of models. polygon: { {x, z} } (3+ points).
--- models: { { length, width, weight } }. options.angle fixes the row
--- direction; otherwise every candidate direction is tried and the one with
--- the most usable row length wins (the longest edge's on near-ties).
--- Returns a plan (see the top of this file), or nil for a degenerate polygon.
function YardLayout.plan(polygon, models, options)
    local o = merge(options)
    if polygon == nil or #polygon < 3 then
        return nil
    end
    local angles = o.angle ~= nil and { o.angle } or YardLayout.candidateAngles(polygon, o)
    local best = nil
    for _, angle in ipairs(angles) do
        local pts, vMin, vMax = localPolygon(polygon, angle)
        local vLow, vHigh = vMin + o.edgeInset, vMax - o.edgeInset
        local maxDepth = (vHigh - vLow) - o.aisleWidth
        local bands, excluded = YardLayout.chooseBands(models, maxDepth, o)
        local rows, depths, vStart = {}, {}, vLow
        if #bands > 0 then
            depths = generateDepths(pts, vLow, vHigh, bands, o)
            local _, reach = buildRows(pts, vLow, vHigh, depths, o)
            vStart = vLow + math.max(0, vHigh - reach) * 0.5
            rows = buildRows(pts, vStart, vHigh, depths, o)
        end
        local score = scoreRows(rows)
        if best == nil or score > best.score * (1 + o.preferTolerance) then
            best = {
                angle = angle,
                vStart = vStart,
                rowDepths = depths,
                rows = rows,
                score = score,
                models = models,
                preExcluded = excluded,
            }
        end
    end
    best.bands = YardLayout.bandsOfRows(best.rows)
    best.excluded = findExcluded(best.rows, models, best.preExcluded, o)
    best.models, best.preExcluded = nil, nil
    return best
end

--- Can a saved spec stand in for a freshly computed plan? True when the row
--- direction is the same and the distinct depths are within depthHysteresis
--- of the new ones, so small changes to the model list (a mod added or
--- removed) don't reshuffle a yard.
function YardLayout.isSpecCompatible(spec, plan, options)
    local o = merge(options)
    if spec == nil or plan == nil or type(spec.rowDepths) ~= "table" or #spec.rowDepths == 0 then
        return false
    end
    local diff = math.abs((spec.angle - plan.angle) % math.pi)
    diff = math.min(diff, math.pi - diff)
    if diff > o.angleHysteresis then
        return false
    end
    local function distinct(depths)
        local set, list = {}, {}
        for _, depth in ipairs(depths) do
            if not set[depth] then
                set[depth] = true
                list[#list + 1] = depth
            end
        end
        table.sort(list)
        return list
    end
    local old, new = distinct(spec.rowDepths), distinct(plan.rowDepths)
    if #old ~= #new then
        return false
    end
    for i = 1, #old do
        if math.abs(old[i] - new[i]) > o.depthHysteresis + EPS then
            return false
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Slots
-- ---------------------------------------------------------------------------

local function conflicts(occupied, rowIndex, u1, u2, gap)
    for _, occ in ipairs(occupied) do
        if occ.row == rowIndex and u1 < occ.u2 + gap - EPS and u2 + gap > occ.u1 + EPS then
            return occ
        end
    end
    return nil
end

--- The pose of a slot: footprint centre, yaw.
function YardLayout.slotPose(plan, row, u1, width, length)
    local cu = u1 + width * 0.5
    local cv = row.frontV - row.facing * length * 0.5
    local cx, cz = YardLayout.toWorld(plan.angle, cu, cv)
    return cx, cz, YardLayout.facingYaw(plan.angle, row.facing)
end

local function rowsByDepth(plan)
    local rows = {}
    for _, row in ipairs(plan.rows) do
        rows[#rows + 1] = row
    end
    table.sort(rows, function(x, y)
        if x.depth ~= y.depth then
            return x.depth < y.depth
        end
        return x.index < y.index
    end)
    return rows
end

--- Find a place for a vehicle: the shallowest row it fits, first free stretch
--- along it. isClear(slot), when given, can veto a spot (a collision test);
--- the search then slides along the row. Returns
--- { row, u1, u2, width, length, x, z, yaw } (x, z: footprint centre) or nil.
function YardLayout.findSlot(plan, occupied, width, length, isClear, options)
    local o = merge(options)
    if plan == nil then
        return nil
    end
    local need = length + o.lengthMargin
    for _, row in ipairs(rowsByDepth(plan)) do
        if row.depth + EPS >= need then
            for _, interval in ipairs(row.intervals) do
                local p = interval[1]
                while p + width <= interval[2] + EPS do
                    local occ = conflicts(occupied, row.index, p, p + width, o.lotGap)
                    if occ ~= nil then
                        p = occ.u2 + o.lotGap
                    else
                        local x, z, yaw = YardLayout.slotPose(plan, row, p, width, length)
                        local slot = { row = row.index, u1 = p, u2 = p + width, width = width, length = length,
                            x = x, z = z, yaw = yaw }
                        if isClear == nil or isClear(slot) then
                            return slot
                        end
                        p = p + o.slideStep
                    end
                end
            end
        end
    end
    return nil
end

--- Free stretch lengths per row, for quick "would this fit?" checks:
--- { { depth, maxGap } }.
function YardLayout.freeSpace(plan, occupied, options)
    local o = merge(options)
    local result = {}
    if plan == nil then
        return result
    end
    for _, row in ipairs(plan.rows) do
        local mine = {}
        for _, occ in ipairs(occupied) do
            if occ.row == row.index then
                mine[#mine + 1] = occ
            end
        end
        table.sort(mine, function(x, y)
            return x.u1 < y.u1
        end)
        local maxGap = 0
        for _, interval in ipairs(row.intervals) do
            local start = interval[1]
            for _, occ in ipairs(mine) do
                if occ.u2 > interval[1] and occ.u1 < interval[2] then
                    maxGap = math.max(maxGap, occ.u1 - o.lotGap - start)
                    start = math.max(start, occ.u2 + o.lotGap)
                end
            end
            maxGap = math.max(maxGap, interval[2] - start)
        end
        result[#result + 1] = { depth = row.depth, maxGap = maxGap }
    end
    return result
end

--- Would a vehicle of this size fit somewhere, given freeSpace's result?
function YardLayout.fitsFreeSpace(free, width, length, options)
    local o = merge(options)
    local need = length + o.lengthMargin
    for _, entry in ipairs(free) do
        if entry.depth + EPS >= need and entry.maxGap + EPS >= width then
            return true
        end
    end
    return false
end

--- Does a parked footprint (centre cx, cz, yaw, size) sit in one of the plan's
--- row positions without clashing with `occupied`? Returns its occupancy
--- { row, u1, u2 } or nil.
function YardLayout.matchFootprint(plan, occupied, cx, cz, yaw, width, length, options)
    local o = merge(options)
    if plan == nil then
        return nil
    end
    local u, v = YardLayout.toLocal(plan.angle, cx, cz)
    local u1, u2 = u - width * 0.5, u + width * 0.5
    local need = length + o.lengthMargin
    for _, row in ipairs(plan.rows) do
        local expectedV = row.frontV - row.facing * length * 0.5
        local yawDiff = math.abs((yaw - YardLayout.facingYaw(plan.angle, row.facing)) % (2 * math.pi))
        yawDiff = math.min(yawDiff, 2 * math.pi - yawDiff)
        if row.depth + EPS >= need and math.abs(v - expectedV) <= o.rowTolerance and yawDiff <= o.yawTolerance then
            for _, interval in ipairs(row.intervals) do
                if u1 >= interval[1] - 0.05 and u2 <= interval[2] + 0.05 then
                    -- A little slack on the gap: these were placed by findSlot.
                    if conflicts(occupied, row.index, u1, u2, o.lotGap - 0.1) == nil then
                        return { row = row.index, u1 = u1, u2 = u2 }
                    end
                    return nil
                end
            end
        end
    end
    return nil
end

--- About how many vehicles a plan holds, for display: each row's stretches
--- divided by the typical width (demand-weighted) of the models that row
--- depth would take.
function YardLayout.estimateCapacity(plan, models, options)
    local o = merge(options)
    if plan == nil or #plan.rows == 0 then
        return 0
    end
    local depths = {}
    for _, band in ipairs(plan.bands or {}) do
        depths[#depths + 1] = band.depth
    end
    local function bandOf(need)
        for _, depth in ipairs(depths) do
            if depth + EPS >= need then
                return depth
            end
        end
        return nil
    end
    local widthSum, weightSum = {}, {}
    local allWidth, allWeight = 0, 0
    for index, model in ipairs(models or {}) do
        if not (plan.excluded or {})[index] then
            local depth = bandOf((model.length or 0) + o.lengthMargin)
            local weight = model.weight or 0
            if depth ~= nil and weight > 0 then
                widthSum[depth] = (widthSum[depth] or 0) + (model.width or 0) * weight
                weightSum[depth] = (weightSum[depth] or 0) + weight
                allWidth, allWeight = allWidth + (model.width or 0) * weight, allWeight + weight
            end
        end
    end
    local fallback = allWeight > 0 and allWidth / allWeight or 3
    local count = 0
    for _, row in ipairs(plan.rows) do
        local width = weightSum[row.depth] ~= nil and widthSum[row.depth] / weightSum[row.depth] or fallback
        for _, interval in ipairs(row.intervals) do
            count = count + math.floor((interval[2] - interval[1] + o.lotGap) / (width + o.lotGap) + EPS)
        end
    end
    return count
end
