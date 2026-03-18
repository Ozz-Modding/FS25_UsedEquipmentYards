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
        print("[UsedEquipmentYards] No save file found, starting fresh.")
        return
    end

    local xmlFile = loadXMLFile("UsedEquipmentYards", filePath)
    if xmlFile == nil then
        print("[UsedEquipmentYards] ERROR: Failed to open save file.")
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

    delete(xmlFile)

    local count = 0
    for _ in pairs(self.yards) do count = count + 1 end
    print(("[UsedEquipmentYards] Loaded %d yard(s)."):format(count))

    for _, yard in pairs(self.yards) do
        yard.inventory:spawn()
    end

    g_messageCenter:subscribe(MessageType.PERIOD_CHANGED, self.onPeriodChanged, self)
end

function YardManager:save()
    local savePath = self:getSavePath()
    if savePath == nil then return end

    local xmlFile = createXMLFile("UsedEquipmentYards", savePath .. YardManager.SAVE_FILENAME, "UsedEquipmentYards")
    if xmlFile == nil then
        print("[UsedEquipmentYards] ERROR: Failed to create save file.")
        return
    end

    local i = 0
    for _, yard in pairs(self.yards) do
        local key = ("UsedEquipmentYards.yards.yard(%d)"):format(i)
        yard:saveToXML(xmlFile, key)
        i = i + 1
    end

    saveXMLFile(xmlFile)
    delete(xmlFile)
end

function YardManager:onPeriodChanged()
    for _, yard in pairs(self.yards) do
        yard.inventory:onPeriodChanged()
    end
end

function YardManager:delete()
    g_messageCenter:unsubscribe(MessageType.PERIOD_CHANGED, self)
    for _, yard in pairs(self.yards) do
        yard:delete()
    end
    self.yards = {}
end

-- ---------------------------------------------------------------------------
-- Yard management
-- ---------------------------------------------------------------------------

function YardManager:createYard(name, bounds)
    local id = self.nextYardId
    self.nextYardId = self.nextYardId + 1
    local yard = UsedEquipmentYard.new(id, name, bounds)
    self.yards[id] = yard
    yard.inventory:spawn()
    print(("[UsedEquipmentYards] Created yard '%s' (id=%d)."):format(name, id))
    return yard
end

function YardManager:removeYard(id)
    local yard = self.yards[id]
    if yard == nil then
        return ("No yard with id %d found."):format(id)
    end
    yard:delete()
    self.yards[id] = nil
    return ("Yard '%s' (id=%d) removed."):format(yard.name, id)
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
        lines[#lines + 1] = ("[%d] %s  center:(%.1f, %.1f, %.1f)  size:%.1fx%.1f  items:%d"):format(
            id, yard.name,
            yard.bounds.cx, yard.bounds.cy, yard.bounds.cz,
            yard.bounds.sizeX, yard.bounds.sizeZ,
            yard.inventory:getItemCount()
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
