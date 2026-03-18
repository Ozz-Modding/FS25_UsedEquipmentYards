-- UsedEquipmentYard
-- Data class for a single yard. Holds its bounds, identity, and inventory.
--
-- bounds = {
--   cx, cy, cz   -- world-space centre point
--   sizeX, sizeZ -- full width/depth of the yard rectangle
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
-- Spatial query
-- ---------------------------------------------------------------------------

-- Returns true if world position (x, z) falls inside this yard's rectangle.
function UsedEquipmentYard:containsPoint(x, z)
    local halfX = self.bounds.sizeX * 0.5
    local halfZ = self.bounds.sizeZ * 0.5
    return math.abs(x - self.bounds.cx) <= halfX
       and math.abs(z - self.bounds.cz) <= halfZ
end

-- Returns a random world position (x, y, z) somewhere inside the yard bounds.
function UsedEquipmentYard:randomSpawnPosition()
    local halfX = self.bounds.sizeX * 0.5
    local halfZ = self.bounds.sizeZ * 0.5
    local x = self.bounds.cx + math.random() * self.bounds.sizeX - halfX
    local z = self.bounds.cz + math.random() * self.bounds.sizeZ - halfZ
    local y = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
    return x, y, z
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

    local yard = UsedEquipmentYard.new(id, name, bounds)
    yard.inventory:loadFromXML(xmlFile, key .. ".inventory")
    return yard
end
