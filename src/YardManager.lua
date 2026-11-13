-- YardManager
-- Central manager for all UsedEquipmentYard instances.
-- Server-only: created in UsedEquipmentYards:loadMap when getIsServer() is true.

YardManager = {}
YardManager._mt = Class(YardManager)

YardManager.SAVE_FILENAME = "UsedEquipmentYards.xml"

function YardManager.new(mod)
    local self = setmetatable({}, YardManager._mt)
    self.mod        = mod
    self.yards      = {}   -- [id] = UsedEquipmentYard
    self.nextYardId = 1
    return self
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function YardManager:load()
    local savePath = self:getSavePath()
    if savePath == nil then return end

    local filePath = savePath .. YardManager.SAVE_FILENAME
    if not fileExists(filePath) then
        return
    end

    local xmlFile = loadXMLFile("UsedEquipmentYards", filePath)
    if xmlFile == nil then
        return
    end

    local i = 0
    while true do
        local key = ("UsedEquipmentYards.yards.yard(%d)"):format(i)
        if not hasXMLProperty(xmlFile, key) then break end
        local yard = UsedEquipmentYard.loadFromXML(xmlFile, key)
        if yard ~= nil then
            self.yards[yard.id] = yard
            if yard.id >= self.nextYardId then
                self.nextYardId = yard.id + 1
            end
        end
        i = i + 1
    end

    BarterState.loadFromXML(xmlFile, "UsedEquipmentYards")
    YardCredit.loadFromXML(xmlFile, "UsedEquipmentYards")
    SellBarterDialog.loadOffersFromXML(xmlFile, "UsedEquipmentYards")
    UsedEquipmentYards.loadRecentSalesFromXML(xmlFile, "UsedEquipmentYards")

    delete(xmlFile)

    -- Initialise the name generator with loaded yard names so they are reserved.
    YardNameGenerator.init(self.yards)

    -- Assign names to any yards that were saved without one (legacy saves).
    for _, yard in pairs(self.yards) do
        if yard.name == nil or yard.name == "" or yard.name == "Yard" then
            yard.name = YardNameGenerator.generateName()
        end
    end

    Logging.info("[UsedEquipmentYards] load: loaded %d yard(s)", i)
    self.loaded = true

    -- Don't spawn vehicles here — g_terrainNode may not be ready yet.
    -- Spawning is deferred to spawnAllYards(), called from onMissionStarted.
end

--- Called after the mission is fully loaded (terrain, map, etc. are ready).
--- Also subscribes to HOUR_CHANGED here (not in load) so it works even
--- when no save file existed.
function YardManager:spawnAllYards()
    if not self.loaded then
        local filePath = (self:getSavePath() or "") .. YardManager.SAVE_FILENAME
        if fileExists(filePath) then
            Logging.warning("[UsedEquipmentYards] spawnAllYards: load had not completed — retrying")
            self:load()
        end
    end
    g_messageCenter:subscribe(MessageType.HOUR_CHANGED, self.onHourChanged, self)
    for _, yard in pairs(self.yards) do
        yard.inventory:spawn()
    end
end

function YardManager:save()
    local savePath = self:getSavePath()
    if savePath == nil then
        Logging.warning("[UsedEquipmentYards] save: could not determine save path")
        return
    end

    local xmlFile = createXMLFile("UsedEquipmentYards", savePath .. YardManager.SAVE_FILENAME, "UsedEquipmentYards")
    if xmlFile == nil then
        Logging.warning("[UsedEquipmentYards] save: createXMLFile failed")
        return
    end

    local i = 0
    for _, yard in pairs(self.yards) do
        local key = ("UsedEquipmentYards.yards.yard(%d)"):format(i)
        local valid, reason = yard:validateForSave()
        if valid then
            yard:saveToXML(xmlFile, key)
            i = i + 1
        else
            Logging.warning("[UsedEquipmentYards] save: skipping yard %s ('%s'): %s",
                tostring(yard.id), tostring(yard.name), reason)
        end
    end

    BarterState.saveToXML(xmlFile, "UsedEquipmentYards")
    YardCredit.saveToXML(xmlFile, "UsedEquipmentYards")
    SellBarterDialog.saveOffersToXML(xmlFile, "UsedEquipmentYards")
    UsedEquipmentYards.saveRecentSalesToXML(xmlFile, "UsedEquipmentYards")

    Logging.info("[UsedEquipmentYards] save: writing %d yard(s)", i)
    local saved = saveXMLFile(xmlFile)
    if not saved then
        Logging.warning("[UsedEquipmentYards] save: saveXMLFile returned false")
    else
        Logging.info("[UsedEquipmentYards] save: complete")
    end
    delete(xmlFile)
end

function YardManager:onHourChanged()
    for _, yard in pairs(self.yards) do
        yard.inventory:onHourChanged()
    end
end

function YardManager:delete()
    g_messageCenter:unsubscribe(MessageType.HOUR_CHANGED, self)
    for _, yard in pairs(self.yards) do
        yard:delete()
    end
    self.yards = {}
end

-- ---------------------------------------------------------------------------
-- Yard management
-- ---------------------------------------------------------------------------

function YardManager:createYard(_, bounds)
    local id = self.nextYardId
    self.nextYardId = self.nextYardId + 1
    local name = YardNameGenerator.generateName()
    local yard = UsedEquipmentYard.new(id, name, bounds)
    self.yards[id] = yard
    yard.inventory:spawn()
    UsedEquipmentYards.addActivatable(yard)
    -- Notify remote MP clients so they can register the yard client-side.
    g_server:broadcastEvent(YardCreatedEvent.new(yard))
    return yard
end

function YardManager:removeYard(id)
    local yard = self.yards[id]
    if yard == nil then
        return ("No yard with id %d found."):format(id)
    end
    -- Notify remote MP clients before removing.
    g_server:broadcastEvent(YardRemovedEvent.new(id))
    UsedEquipmentYards.removeActivatable(id)
    YardNameGenerator.release(yard.name)
    yard:delete()
    self.yards[id] = nil
    return ("Yard '%s' (id=%d) removed."):format(yard.name, id)
end

-- ---------------------------------------------------------------------------
-- Yard outlines (the yard tool: YardZoneEvent)
-- ---------------------------------------------------------------------------

--- Bounds for an outline, with the terrain height at its centre.
function YardManager.boundsForPolygon(polygon)
    local bounds = YardZone.boundsFromPolygon(polygon)
    if g_terrainNode ~= nil then
        bounds.cy = getTerrainHeightAtWorldPos(g_terrainNode, bounds.cx, 0, bounds.cz)
    end
    return bounds
end

--- Validate an outline for a yard (yardId nil = a new one) against the others.
function YardManager:validatePolygon(polygon, yardId)
    local others = {}
    for id, yard in pairs(self.yards) do
        if id ~= yardId then
            others[#others + 1] = YardZone.polygonOfBounds(yard.bounds)
        end
    end
    return YardZone.validate(polygon, others)
end

--- Can this yard be removed? False plus a reason key while sale zones are
--- linked to it (they'd be left pointing at nothing).
function YardManager:canRemoveYard(id)
    if self.yards[id] == nil then
        return false, "noYard"
    end
    if UsedEquipmentYards.getConnectedSaleZoneCount(id) > 0 then
        return false, "hasSaleZones"
    end
    return true
end

--- Give a yard a new outline: clients are told, and its stock is fitted to
--- the new rows (vehicles that no longer fit are cleared out as if sold).
function YardManager:updateYardPolygon(id, polygon)
    local yard = self.yards[id]
    if yard == nil then
        return false, "noYard"
    end
    yard.bounds = YardManager.boundsForPolygon(polygon)
    yard.inventory:onBoundsChanged()
    g_server:broadcastEvent(YardUpdatedEvent.new(yard))
    return true
end

--- Apply a YardZoneEvent request (already permission-checked).
--- Returns true, or false and a reason.
function YardManager:applyZoneRequest(op, yardId, polygon)
    local OP = YardZoneEvent.OP
    if op == OP.DELETE then
        local ok, err = self:canRemoveYard(yardId)
        if not ok then
            return false, err
        end
        self:removeYard(yardId)
        return true
    end

    local isUpdate = op == OP.UPDATE
    if isUpdate and self.yards[yardId] == nil then
        return false, "noYard"
    end
    local ok, err = self:validatePolygon(polygon, isUpdate and yardId or nil)
    if not ok then
        return false, err
    end
    if isUpdate then
        return self:updateYardPolygon(yardId, polygon)
    end
    self:createYard(nil, YardManager.boundsForPolygon(polygon))
    return true
end

function YardManager:resetInventory(id)
    local yard = self.yards[id]
    if yard == nil then
        return ("No yard with id %d found."):format(id)
    end
    yard.inventory:reset()
    return ("Inventory reset for yard '%s' (id=%d)."):format(yard.name, id)
end

function YardManager:resetAllInventories()
    for _, yard in pairs(self.yards) do
        yard.inventory:reset()
    end
end

function YardManager:getYardListString()
    if next(self.yards) == nil then
        return "No yards defined."
    end
    local lines = {}
    for id, yard in pairs(self.yards) do
        lines[#lines + 1] = ("[%d] %s  center:(%.1f, %.1f, %.1f)  size:%.1fx%.1f  items:%d  rows:%s"):format(
            id, yard.name,
            yard.bounds.cx, yard.bounds.cy, yard.bounds.cz,
            yard.bounds.sizeX, yard.bounds.sizeZ,
            yard.inventory:getItemCount(),
            yard.inventory:describeRows()
        )
    end
    return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

function YardManager:getSavePath()
    local info = g_currentMission.missionInfo
    if info == nil then return nil end
    local path = info.savegameDirectory
    if path == nil then
        path = ('%ssavegame%d'):format(getUserProfileAppPath(), info.savegameIndex)
    end
    return path .. "/"
end
