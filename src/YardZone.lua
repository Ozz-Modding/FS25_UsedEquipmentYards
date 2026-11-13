-- YardZone
-- Pure polygon logic for drawing and editing a yard's outline (no engine
-- calls, so it is unit tested outside the game: tests/test_yardZone.lua).
--
-- A polygon is a list of { x = , z = } corners, closed implicitly (the last
-- corner joins the first). The build-menu tool (UeyYardZoneBrush) feeds
-- cursor positions into a YardZone.Editor and draws what it holds; the
-- server re-validates every outline with YardZone.validate before using it.

YardZone = {}

YardZone.LIMITS = {
    minVertices = 3,
    maxVertices = 64,
    minEdgeLength = 1.0,    -- corners closer than this are refused (m)
    minArea = 50,           -- smallest yard (m²)
    vertexPickRadius = 1.5, -- how close the cursor must be to grab a corner (m)
    edgePickRadius = 1.2,   -- ...or to insert a corner on an edge (m)
    closeRadius = 1.5,      -- clicking this close to the first corner closes the outline (m)
    maxHistory = 50,        -- undo steps kept
}

YardZone.ERROR = {
    TOO_FEW_POINTS = "tooFewPoints",
    TOO_MANY_POINTS = "tooManyPoints",
    EDGE_TOO_SHORT = "edgeTooShort",
    SELF_INTERSECTING = "selfIntersecting",
    TOO_SMALL = "tooSmall",
    OVERLAPS_YARD = "overlapsYard",
}

local EPS = 1e-9

local function limitsOf(limits)
    local l = {}
    for k, v in pairs(YardZone.LIMITS) do
        l[k] = v
    end
    for k, v in pairs(limits or {}) do
        l[k] = v
    end
    return l
end

-- ---------------------------------------------------------------------------
-- Geometry
-- ---------------------------------------------------------------------------

function YardZone.copy(polygon)
    local result = {}
    for i, p in ipairs(polygon or {}) do
        result[i] = { x = p.x, z = p.z }
    end
    return result
end

--- A copy without corners closer than minEdgeLength to the one before them
--- (wrapping round, so a closing corner repeating the first goes too). Old
--- fence-built yards repeat their first corner at the end, an edge of 0 m that
--- would fail validation on every edit. Returns the polygon unchanged (copied)
--- if cleaning would leave fewer than minVertices corners.
function YardZone.cleanPolygon(polygon, limits)
    local l = limitsOf(limits)
    local result = {}
    for _, p in ipairs(polygon or {}) do
        local last = result[#result]
        if last == nil or math.sqrt((p.x - last.x) ^ 2 + (p.z - last.z) ^ 2) >= l.minEdgeLength then
            result[#result + 1] = { x = p.x, z = p.z }
        end
    end
    while #result > 1 do
        local first, last = result[1], result[#result]
        if math.sqrt((first.x - last.x) ^ 2 + (first.z - last.z) ^ 2) >= l.minEdgeLength then
            break
        end
        table.remove(result)
    end
    if #result < l.minVertices then
        return YardZone.copy(polygon)
    end
    return result
end

--- Positive for counter-clockwise (x right, z up).
function YardZone.signedArea(polygon)
    local n = #polygon
    local sum = 0
    for i = 1, n do
        local a, b = polygon[i], polygon[i % n + 1]
        sum = sum + a.x * b.z - b.x * a.z
    end
    return sum * 0.5
end

function YardZone.area(polygon)
    return math.abs(YardZone.signedArea(polygon))
end

function YardZone.pointInPolygon(polygon, x, z)
    local inside = false
    local n = #polygon
    local j = n
    for i = 1, n do
        local a, b = polygon[i], polygon[j]
        if (a.z > z) ~= (b.z > z) and x < (b.x - a.x) * (z - a.z) / (b.z - a.z) + a.x then
            inside = not inside
        end
        j = i
    end
    return inside
end

local function orient(ax, az, bx, bz, cx, cz)
    local value = (bx - ax) * (cz - az) - (bz - az) * (cx - ax)
    if value > EPS then
        return 1
    elseif value < -EPS then
        return -1
    end
    return 0
end

local function onSegment(ax, az, bx, bz, px, pz)
    return math.min(ax, bx) - EPS <= px and px <= math.max(ax, bx) + EPS and
        math.min(az, bz) - EPS <= pz and pz <= math.max(az, bz) + EPS
end

--- Do segments a-b and c-d touch or cross?
function YardZone.segmentsIntersect(ax, az, bx, bz, cx, cz, dx, dz)
    local o1 = orient(ax, az, bx, bz, cx, cz)
    local o2 = orient(ax, az, bx, bz, dx, dz)
    local o3 = orient(cx, cz, dx, dz, ax, az)
    local o4 = orient(cx, cz, dx, dz, bx, bz)
    if o1 ~= o2 and o3 ~= o4 then
        return true
    end
    if o1 == 0 and onSegment(ax, az, bx, bz, cx, cz) then return true end
    if o2 == 0 and onSegment(ax, az, bx, bz, dx, dz) then return true end
    if o3 == 0 and onSegment(cx, cz, dx, dz, ax, az) then return true end
    if o4 == 0 and onSegment(cx, cz, dx, dz, bx, bz) then return true end
    return false
end

--- Does any edge of a closed (or open, closed = false) outline cross another
--- that isn't its neighbour?
function YardZone.isSelfIntersecting(polygon, closed)
    if closed == nil then
        closed = true
    end
    local n = #polygon
    local edges = closed and n or n - 1
    for i = 1, edges do
        local a, b = polygon[i], polygon[i % n + 1]
        for j = i + 1, edges do
            local neighbours = j == i + 1 or (closed and i == 1 and j == n)
            if not neighbours then
                local c, d = polygon[j], polygon[j % n + 1]
                if YardZone.segmentsIntersect(a.x, a.z, b.x, b.z, c.x, c.z, d.x, d.z) then
                    return true
                end
            end
        end
    end
    -- Neighbouring edges folding back onto each other (a spike).
    for i = 1, edges - 1 + (closed and 1 or 0) do
        local a, b, c = polygon[i], polygon[i % n + 1], polygon[(i + 1) % n + 1]
        if orient(a.x, a.z, b.x, b.z, c.x, c.z) == 0 then
            local dot = (b.x - a.x) * (c.x - b.x) + (b.z - a.z) * (c.z - b.z)
            if dot < 0 then
                return true
            end
        end
    end
    return false
end

--- Do two closed polygons overlap (cross, touch, or one inside the other)?
function YardZone.polygonsOverlap(a, b)
    local na, nb = #a, #b
    if na < 3 or nb < 3 then
        return false
    end
    for i = 1, na do
        local p, q = a[i], a[i % na + 1]
        for j = 1, nb do
            local r, s = b[j], b[j % nb + 1]
            if YardZone.segmentsIntersect(p.x, p.z, q.x, q.z, r.x, r.z, s.x, s.z) then
                return true
            end
        end
    end
    return YardZone.pointInPolygon(b, a[1].x, a[1].z) or YardZone.pointInPolygon(a, b[1].x, b[1].z)
end

--- The corner nearest (x, z) within maxDistance: index, distance.
function YardZone.nearestVertex(polygon, x, z, maxDistance)
    local best, bestDistance = nil, maxDistance or math.huge
    for i, p in ipairs(polygon) do
        local d = math.sqrt((p.x - x) ^ 2 + (p.z - z) ^ 2)
        if d <= bestDistance then
            best, bestDistance = i, d
        end
    end
    return best, best ~= nil and bestDistance or nil
end

--- The edge nearest (x, z) within maxDistance: index i (the edge from corner
--- i to the next), the closest point on it, distance. Open outlines (closed =
--- false) have no closing edge.
function YardZone.nearestEdge(polygon, x, z, maxDistance, closed)
    if closed == nil then
        closed = true
    end
    local n = #polygon
    local edges = closed and n or n - 1
    local bestIndex, bestX, bestZ, bestDistance = nil, nil, nil, maxDistance or math.huge
    for i = 1, edges do
        local a, b = polygon[i], polygon[i % n + 1]
        local dx, dz = b.x - a.x, b.z - a.z
        local lengthSq = dx * dx + dz * dz
        local t = lengthSq > 0 and math.max(0, math.min(1, ((x - a.x) * dx + (z - a.z) * dz) / lengthSq)) or 0
        local px, pz = a.x + dx * t, a.z + dz * t
        local d = math.sqrt((x - px) ^ 2 + (z - pz) ^ 2)
        if d <= bestDistance then
            bestIndex, bestX, bestZ, bestDistance = i, px, pz, d
        end
    end
    return bestIndex, bestX, bestZ, bestIndex ~= nil and bestDistance or nil
end

--- Can this outline be a yard? others: polygons of the other yards.
--- Returns true, or false and a YardZone.ERROR value.
function YardZone.validate(polygon, others, limits)
    local l = limitsOf(limits)
    local n = polygon ~= nil and #polygon or 0
    if n < l.minVertices then
        return false, YardZone.ERROR.TOO_FEW_POINTS
    end
    if n > l.maxVertices then
        return false, YardZone.ERROR.TOO_MANY_POINTS
    end
    for i = 1, n do
        local a, b = polygon[i], polygon[i % n + 1]
        if math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2) < l.minEdgeLength then
            return false, YardZone.ERROR.EDGE_TOO_SHORT
        end
    end
    if YardZone.isSelfIntersecting(polygon, true) then
        return false, YardZone.ERROR.SELF_INTERSECTING
    end
    if YardZone.area(polygon) < l.minArea then
        return false, YardZone.ERROR.TOO_SMALL
    end
    for _, other in ipairs(others or {}) do
        if YardZone.polygonsOverlap(polygon, other) then
            return false, YardZone.ERROR.OVERLAPS_YARD
        end
    end
    return true
end

--- Yard bounds from an outline (cy is left to the caller: terrain height).
function YardZone.boundsFromPolygon(polygon)
    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    for _, p in ipairs(polygon) do
        minX, maxX = math.min(minX, p.x), math.max(maxX, p.x)
        minZ, maxZ = math.min(minZ, p.z), math.max(maxZ, p.z)
    end
    return {
        cx = (minX + maxX) * 0.5,
        cy = 0,
        cz = (minZ + maxZ) * 0.5,
        sizeX = maxX - minX,
        sizeZ = maxZ - minZ,
        polygon = YardZone.copy(polygon),
        anchorX = polygon[1].x,
        anchorZ = polygon[1].z,
    }
end

--- A yard's outline: its polygon, or its AABB for legacy yards without one.
function YardZone.polygonOfBounds(bounds)
    if bounds.polygon ~= nil and #bounds.polygon >= 3 then
        return bounds.polygon
    end
    local hx, hz = (bounds.sizeX or 10) * 0.5, (bounds.sizeZ or 10) * 0.5
    return {
        { x = bounds.cx - hx, z = bounds.cz - hz }, { x = bounds.cx + hx, z = bounds.cz - hz },
        { x = bounds.cx + hx, z = bounds.cz + hz }, { x = bounds.cx - hx, z = bounds.cz + hz },
    }
end

function YardZone.samePolygon(a, b, tolerance)
    tolerance = tolerance or 1e-3
    if #a ~= #b then
        return false
    end
    for i = 1, #a do
        if math.abs(a[i].x - b[i].x) > tolerance or math.abs(a[i].z - b[i].z) > tolerance then
            return false
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Editor: the drawing / editing state behind the build-menu tool
-- ---------------------------------------------------------------------------
--
-- States:
--   idle     nothing in hand
--   drawing  placing corners of a new outline (open chain)
--   editing  a closed outline: a new one not yet created, or a copy of an
--            existing yard's (yardId set) — moved, split and trimmed freely,
--            applied or cancelled as a whole

YardZone.Editor = {}
local Editor_mt = { __index = YardZone.Editor }

YardZone.STATE = { IDLE = "idle", DRAWING = "drawing", EDITING = "editing" }

function YardZone.Editor.new(limits)
    local self = setmetatable({}, Editor_mt)
    self.limits = limitsOf(limits)
    self:reset()
    return self
end

function YardZone.Editor:reset()
    self.state = YardZone.STATE.IDLE
    self.points = {}
    self.yardId = nil
    self.original = nil
    self.history = {}
    self.dragIndex = nil
    self.dragMoved = false
    self.dragInserted = false
    self.version = (self.version or 0) + 1
end

function YardZone.Editor:changed()
    self.version = self.version + 1
end

function YardZone.Editor:pushHistory()
    table.insert(self.history, { state = self.state, points = YardZone.copy(self.points) })
    if #self.history > self.limits.maxHistory then
        table.remove(self.history, 1)
    end
end

function YardZone.Editor:getPolygon()
    return self.points
end

function YardZone.Editor:isClosed()
    return self.state == YardZone.STATE.EDITING
end

--- Start a new outline with its first corner.
function YardZone.Editor:startNew(x, z)
    self:reset()
    self.state = YardZone.STATE.DRAWING
    self.points = { { x = x, z = z } }
    self:changed()
end

--- Take a copy of an existing yard's outline to edit.
function YardZone.Editor:loadExisting(yardId, polygon)
    self:reset()
    self.state = YardZone.STATE.EDITING
    self.yardId = yardId
    self.points = YardZone.cleanPolygon(polygon, self.limits)
    self.original = YardZone.copy(polygon)
    self:changed()
end

--- Is (x, z) close enough to the first corner to close the outline?
function YardZone.Editor:isNearFirst(x, z)
    local first = self.points[1]
    return first ~= nil and math.sqrt((first.x - x) ^ 2 + (first.z - z) ^ 2) <= self.limits.closeRadius
end

function YardZone.Editor:canClose()
    return self.state == YardZone.STATE.DRAWING and #self.points >= self.limits.minVertices
end

--- Add a corner while drawing. Returns "closed" when the click closed the
--- outline, "added", or nil when refused (too close to the last corner, or
--- it would cross the outline drawn so far).
function YardZone.Editor:addPoint(x, z)
    if self.state ~= YardZone.STATE.DRAWING then
        return nil
    end
    if self:canClose() and self:isNearFirst(x, z) then
        self:close()
        return "closed"
    end
    if #self.points >= self.limits.maxVertices then
        return nil
    end
    local last = self.points[#self.points]
    if math.sqrt((last.x - x) ^ 2 + (last.z - z) ^ 2) < self.limits.minEdgeLength then
        return nil
    end
    -- Too close to the first corner to be its own corner (it would leave a
    -- sliver of an edge when the outline closes).
    local first = self.points[1]
    if math.sqrt((first.x - x) ^ 2 + (first.z - z) ^ 2) < self.limits.minEdgeLength then
        return nil
    end
    if not self:canExtendTo(x, z) then
        return nil
    end
    self:pushHistory()
    table.insert(self.points, { x = x, z = z })
    self:changed()
    return "added"
end

--- Would a new edge from the last corner to (x, z) cross the outline so far?
function YardZone.Editor:canExtendTo(x, z)
    local n = #self.points
    if n < 2 then
        return true
    end
    local last = self.points[n]
    for i = 1, n - 2 do
        local a, b = self.points[i], self.points[i + 1]
        if YardZone.segmentsIntersect(a.x, a.z, b.x, b.z, last.x, last.z, x, z) then
            return false
        end
    end
    return true
end

function YardZone.Editor:close()
    if not self:canClose() then
        return false
    end
    self:pushHistory()
    self.state = YardZone.STATE.EDITING
    self:changed()
    return true
end

--- While drawing: take back the last corner. Removing the only corner
--- abandons the outline.
function YardZone.Editor:removeLastPoint()
    if self.state ~= YardZone.STATE.DRAWING then
        return false
    end
    if #self.points <= 1 then
        self:reset()
        return true
    end
    self:pushHistory()
    table.remove(self.points)
    self:changed()
    return true
end

function YardZone.Editor:pickVertex(x, z)
    return YardZone.nearestVertex(self.points, x, z, self.limits.vertexPickRadius)
end

function YardZone.Editor:pickEdge(x, z)
    if #self.points < 2 then
        return nil
    end
    return YardZone.nearestEdge(self.points, x, z, self.limits.edgePickRadius, self:isClosed())
end

--- Grab a corner to drag. The undo step is only kept if it actually moves.
function YardZone.Editor:beginDrag(index)
    if self.points[index] == nil then
        return false
    end
    self:pushHistory()
    self.dragIndex = index
    self.dragMoved = false
    self.dragInserted = false
    return true
end

function YardZone.Editor:dragTo(x, z)
    local p = self.dragIndex ~= nil and self.points[self.dragIndex] or nil
    if p == nil then
        return
    end
    if p.x ~= x or p.z ~= z then
        p.x, p.z = x, z
        self.dragMoved = true
        self:changed()
    end
end

--- Let go of the dragged corner. A corner added by a click on an edge that
--- never moved is dropped again (a stray click shouldn't add a corner), and a
--- corner let go within minEdgeLength of a neighbour merges into it.
function YardZone.Editor:endDrag()
    if self.dragIndex == nil then
        return
    end
    if self.dragInserted and not self.dragMoved then
        local snapshot = table.remove(self.history)
        if snapshot ~= nil then
            self.points = snapshot.points
            self.state = snapshot.state
        end
        self:changed()
    elseif not self.dragMoved then
        table.remove(self.history)
    else
        self:mergeIntoNeighbour(self.dragIndex)
    end
    self.dragIndex = nil
    self.dragMoved = false
    self.dragInserted = false
end

--- Remove corner `index` if it sits on top of a neighbour (closed outlines,
--- never below minVertices). Part of the drag's undo step.
function YardZone.Editor:mergeIntoNeighbour(index)
    local n = #self.points
    if not self:isClosed() or n <= self.limits.minVertices then
        return false
    end
    local p = self.points[index]
    local prev = self.points[(index - 2) % n + 1]
    local nextP = self.points[index % n + 1]
    local minLength = self.limits.minEdgeLength
    if math.sqrt((p.x - prev.x) ^ 2 + (p.z - prev.z) ^ 2) < minLength
        or math.sqrt((p.x - nextP.x) ^ 2 + (p.z - nextP.z) ^ 2) < minLength then
        table.remove(self.points, index)
        self:changed()
        return true
    end
    return false
end

--- Put the dragged corner back where it was.
function YardZone.Editor:cancelDrag()
    if self.dragIndex == nil then
        return
    end
    local snapshot = table.remove(self.history)
    if snapshot ~= nil then
        self.points = snapshot.points
        self.state = snapshot.state
    end
    self.dragIndex = nil
    self.dragMoved = false
    self.dragInserted = false
    self:changed()
end

--- Add a corner on edge `edgeIndex` at (x, z). Returns its index.
function YardZone.Editor:insertVertex(edgeIndex, x, z)
    if #self.points >= self.limits.maxVertices then
        return nil
    end
    self:pushHistory()
    table.insert(self.points, edgeIndex + 1, { x = x, z = z })
    self:changed()
    return edgeIndex + 1
end

--- Add a corner on an edge and start dragging it, as one undo step.
function YardZone.Editor:insertAndDrag(edgeIndex, x, z)
    local index = self:insertVertex(edgeIndex, x, z)
    if index == nil then
        return nil
    end
    self.dragIndex = index
    self.dragMoved = false
    self.dragInserted = true
    return index
end

--- Remove a corner of a closed outline (never below minVertices).
function YardZone.Editor:deleteVertex(index)
    if not self:isClosed() or self.points[index] == nil or #self.points <= self.limits.minVertices then
        return false
    end
    self:pushHistory()
    table.remove(self.points, index)
    self:changed()
    return true
end

function YardZone.Editor:canUndo()
    return #self.history > 0
end

function YardZone.Editor:undo()
    local snapshot = table.remove(self.history)
    if snapshot == nil then
        return false
    end
    self.points = snapshot.points
    self.state = snapshot.state
    self.dragIndex = nil
    self.dragMoved = false
    self.dragInserted = false
    self:changed()
    return true
end

--- Has anything been drawn or changed that applying would save?
function YardZone.Editor:isDirty()
    if self.state == YardZone.STATE.IDLE then
        return false
    end
    if self.yardId == nil then
        return #self.points > 0
    end
    return not YardZone.samePolygon(self.points, self.original)
end

--- Validate the outline in hand against other yards' outlines.
function YardZone.Editor:validate(others)
    if not self:isClosed() then
        return false, YardZone.ERROR.TOO_FEW_POINTS
    end
    return YardZone.validate(self.points, others, self.limits)
end
