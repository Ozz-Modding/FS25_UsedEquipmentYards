-- UsedEquipmentYard
-- Data class for a single yard. Holds its bounds, identity, and inventory.
--
-- bounds = {
--   cx, cy, cz       -- world-space centre of the AABB
--   sizeX, sizeZ     -- full width/depth of the AABB
--   polygon          -- ordered list of { x, z } fence vertices (may be nil for legacy saves)
-- }

UsedEquipmentYard = {}
UsedEquipmentYard._mt = Class(UsedEquipmentYard)

function UsedEquipmentYard.new(id, name, bounds)
    local self = setmetatable({}, UsedEquipmentYard._mt)
    self.id        = id
    self.name      = name
    self.bounds    = bounds
    self.inventory = YardInventory.new(self)
    return self
end

function UsedEquipmentYard:delete()
    self.inventory:despawnAll()
end

-- ---------------------------------------------------------------------------
-- Spatial query — point-in-polygon (ray casting algorithm)
-- ---------------------------------------------------------------------------

--- Returns true if (px, pz) is inside the fence polygon.
--- Falls back to AABB check if no polygon is stored (legacy saves).
function UsedEquipmentYard:containsPoint(px, pz)
    local poly = self.bounds.polygon
    if poly == nil or #poly < 3 then
        -- Fallback: AABB check
        local halfX = self.bounds.sizeX * 0.5
        local halfZ = self.bounds.sizeZ * 0.5
        return math.abs(px - self.bounds.cx) <= halfX
           and math.abs(pz - self.bounds.cz) <= halfZ
    end

    -- Ray casting: shoot a ray in +X from the test point and count edge crossings.
    local inside = false
    local n = #poly
    local j = n
    for i = 1, n do
        local ix, iz = poly[i].x, poly[i].z
        local jx, jz = poly[j].x, poly[j].z
        if (iz > pz) ~= (jz > pz) then
            local intersectX = jx + (pz - jz) / (iz - jz) * (ix - jx)
            if px < intersectX then
                inside = not inside
            end
        end
        j = i
    end
    return inside
end

-- ---------------------------------------------------------------------------
-- XML persistence
-- ---------------------------------------------------------------------------

function UsedEquipmentYard:saveToXML(xmlFile, key)
    setXMLInt(xmlFile,    key .. "#id",          self.id)
    setXMLString(xmlFile, key .. "#name",        self.name)
    setXMLFloat(xmlFile,  key .. ".bounds#cx",   self.bounds.cx)
    setXMLFloat(xmlFile,  key .. ".bounds#cy",   self.bounds.cy)
    setXMLFloat(xmlFile,  key .. ".bounds#cz",   self.bounds.cz)
    setXMLFloat(xmlFile,  key .. ".bounds#sizeX", self.bounds.sizeX)
    setXMLFloat(xmlFile,  key .. ".bounds#sizeZ", self.bounds.sizeZ)

    -- Persist fence polygon so containsPoint works after load.
    local poly = self.bounds.polygon
    if poly ~= nil then
        for i, pt in ipairs(poly) do
            local pKey = ("%s.bounds.vertex(%d)"):format(key, i - 1)
            setXMLFloat(xmlFile, pKey .. "#x", pt.x)
            setXMLFloat(xmlFile, pKey .. "#z", pt.z)
        end
    end

    self.inventory:saveToXML(xmlFile, key .. ".inventory")
end

function UsedEquipmentYard.loadFromXML(xmlFile, key)
    local id   = getXMLInt(xmlFile,    key .. "#id")
    local name = getXMLString(xmlFile, key .. "#name")
    if id == nil or name == nil then return nil end

    local bounds = {
        cx    = getXMLFloat(xmlFile, key .. ".bounds#cx")    or 0,
        cy    = getXMLFloat(xmlFile, key .. ".bounds#cy")    or 0,
        cz    = getXMLFloat(xmlFile, key .. ".bounds#cz")    or 0,
        sizeX = getXMLFloat(xmlFile, key .. ".bounds#sizeX") or 10,
        sizeZ = getXMLFloat(xmlFile, key .. ".bounds#sizeZ") or 10,
    }

    -- Restore fence polygon.
    local polygon = {}
    local i = 0
    while true do
        local pKey = ("%s.bounds.vertex(%d)"):format(key, i)
        if not hasXMLProperty(xmlFile, pKey) then break end
        polygon[#polygon + 1] = {
            x = getXMLFloat(xmlFile, pKey .. "#x") or 0,
            z = getXMLFloat(xmlFile, pKey .. "#z") or 0,
        }
        i = i + 1
    end
    if #polygon >= 3 then
        bounds.polygon = polygon
    end

    local yard = UsedEquipmentYard.new(id, name, bounds)
    yard.inventory:loadFromXML(xmlFile, key .. ".inventory")
    return yard
end
