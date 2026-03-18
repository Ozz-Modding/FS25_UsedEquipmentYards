-- YardInventory
-- Manages the list of vehicles available at a single UsedEquipmentYard.
-- Handles spawning vehicles, monthly refresh, save/load, and purchase removal.
--
-- Each item = {
--   xmlFilename  string   -- store XML path for this vehicle
--   price        number   -- discounted "used" price
--   age          number   -- cosmetic age in years (drives wear/hours)
--   vehicle      table    -- FS25 Vehicle object (nil when despawned)
-- }
--
-- Inventory refreshes once per in-game period (≈ month). The last-refreshed
-- period and year are persisted so a reload mid-period does not re-roll.

YardInventory = {}
YardInventory._mt = Class(YardInventory)

-- Safety cap to prevent runaway spawning (e.g. if collision checks fail).
YardInventory.ABSOLUTE_MAX_ITEMS = 50

-- Store categories to draw from when populating a yard.
YardInventory.CATEGORIES = {
    "TRACTORSS", "TRACTORSM", "TRACTORSL",
    "TELELOADERS", "WHEELLOADERSM", "WHEELLOADERSL",
    "SKIDSTEERS",
}

-- Price multiplier range for "used" discount (e.g. 0.3–0.7 of new price).
YardInventory.PRICE_MIN_FACTOR = 0.3
YardInventory.PRICE_MAX_FACTOR = 0.7

-- Row depth for spawn place lines (metres).
YardInventory.ROW_DEPTH = 8
-- Inset from fence boundary to avoid spawning outside non-rectangular areas (metres).
YardInventory.BOUNDS_INSET = 3
-- Max random steering angle applied to parked vehicles (radians, ≈ ±15°).
YardInventory.MAX_YAW_JITTER = math.rad(15)

function YardInventory.new(yard)
    local self = setmetatable({}, YardInventory._mt)
    self.yard              = yard
    self.items             = {}
    self.vehicles          = {}          -- spawned Vehicle objects
    self.pendingLoads      = {}          -- in-flight VehicleLoadingData
    self.spawnPlaces       = nil         -- built on first spawn
    self.usedPlaces        = nil         -- tracks consumed width per row
    self.filling           = false       -- true while the fill loop is running
    self.lastRefreshPeriod = -1
    self.lastRefreshYear   = -1
    return self
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

--- Called by YardManager when MessageType.PERIOD_CHANGED fires.
function YardInventory:onPeriodChanged()
    local env = g_currentMission.environment
    if env == nil then return end
    local period = env.currentPeriod
    local year   = env.currentYear
    if period ~= self.lastRefreshPeriod or year ~= self.lastRefreshYear then
        self:refresh()
    end
end

--- Start filling the yard. Generates one vehicle at a time, attempts to place
--- it, and repeats until the yard is full or the safety cap is reached.
function YardInventory:spawn()
    self:buildSpawnPlaces()
    self.filling = true
    self:spawnNext()
end

function YardInventory:despawnAll()
    self.filling = false

    for _, loadingData in ipairs(self.pendingLoads) do
        loadingData:cancelLoading()
    end
    self.pendingLoads = {}

    for _, vehicle in ipairs(self.vehicles) do
        vehicle:delete()
    end
    self.vehicles = {}

    for _, item in ipairs(self.items) do
        item.vehicle = nil
    end

    -- Reset spawn place usage so the next spawn cycle has a clean slate.
    if self.usedPlaces ~= nil then
        for place, _ in pairs(self.usedPlaces) do
            self.usedPlaces[place] = 0
        end
    end
end

function YardInventory:reset()
    self:despawnAll()
    self.items = {}
    self.storePool = nil
    self:spawn()
    local env = g_currentMission.environment
    if env ~= nil then
        self.lastRefreshPeriod = env.currentPeriod
        self.lastRefreshYear   = env.currentYear
    end
end

function YardInventory:refresh()
    self:reset()
end

-- ---------------------------------------------------------------------------
-- Item generation
-- ---------------------------------------------------------------------------

--- Generate a single random item from the store pool.
function YardInventory:generateOneItem()
    if self.storePool == nil then
        self.storePool = YardInventory.buildStorePool()
    end
    if #self.storePool == 0 then return nil end

    local storeItem = self.storePool[math.random(1, #self.storePool)]
    local age   = math.random(1, 8)
    local price = math.floor(storeItem.price * YardInventory.usedPriceFactor(age))

    local item = {
        xmlFilename = storeItem.xmlFilename,
        price       = price,
        age         = age,
        vehicle     = nil,
    }
    self.items[#self.items + 1] = item
    return item
end

--- Build a flat list of store items matching our category pool.
function YardInventory.buildStorePool()
    local wantedSet = {}
    for _, cat in ipairs(YardInventory.CATEGORIES) do
        wantedSet[cat] = true
    end

    local pool = {}
    for _, item in pairs(g_storeManager:getItems()) do
        -- Skip DLC items to avoid missing-content errors
        if not string.find(item.xmlFilename, "/pdlc/") then
            for _, catName in ipairs(item.categoryNames or {}) do
                if wantedSet[catName] then
                    pool[#pool + 1] = item
                    break
                end
            end
        end
    end
    return pool
end

--- Return a price multiplier for a given age (older = cheaper).
function YardInventory.usedPriceFactor(age)
    local t = math.min(age / 10, 1) -- 0..1 over 10 years
    local lo = YardInventory.PRICE_MIN_FACTOR
    local hi = YardInventory.PRICE_MAX_FACTOR
    return hi - t * (hi - lo) + (math.random() * 0.05)
end

-- ---------------------------------------------------------------------------
-- Spawn places — rows within the yard that the engine fills intelligently
-- ---------------------------------------------------------------------------

--- Build spawn place rows across the yard. Each row spans the full width
--- of the yard (sizeX) and is ROW_DEPTH metres deep. The engine's
--- PlacementUtil.getPlace uses vehicle dimensions to find a free spot.
function YardInventory:buildSpawnPlaces()
    local b = self.yard.bounds
    local inset = YardInventory.BOUNDS_INSET
    local rowDepth = YardInventory.ROW_DEPTH

    -- Shrink the usable area inward to avoid spawning outside irregular fences.
    local usableW = math.max(0, b.sizeX - inset * 2)
    local usableD = math.max(0, b.sizeZ - inset * 2)
    local rows = math.max(1, math.floor(usableD / rowDepth))

    self.spawnPlaces = {}
    self.usedPlaces  = {}

    local startZ = b.cz - usableD * 0.5 + rowDepth * 0.5
    local startX = b.cx - usableW * 0.5

    for r = 0, rows - 1 do
        local z = startZ + r * rowDepth
        local y = getTerrainHeightAtWorldPos(g_terrainNode, b.cx, 0, z)

        local place = {
            startX   = startX,
            startY   = y,
            startZ   = z,
            width    = usableW,    -- inset row width
            length   = rowDepth,   -- depth available
            yOffset  = 1,
            rotX     = 0,
            rotY     = 0,
            rotZ     = 0,
            dirX     = 1,          -- row runs along +X
            dirY     = 0,
            dirZ     = 0,
            dirPerpX = 0,          -- perpendicular is +Z (into the row)
            dirPerpY = 0,
            dirPerpZ = 1,
            maxWidth  = math.huge,
            maxLength = math.huge,
            maxHeight = math.huge,
            palletRotationOffset = 0,
        }

        self.spawnPlaces[#self.spawnPlaces + 1] = place
        self.usedPlaces[place] = 0
    end
end

-- ---------------------------------------------------------------------------
-- Vehicle spawning (sequential — one at a time, size-aware via setLoadingPlace)
-- ---------------------------------------------------------------------------

--- Generate one item, try to place it. If it fits, load it; the callback
--- will call spawnNext again. If it doesn't fit, the yard is full — stop.
function YardInventory:spawnNext()
    if not self.filling then return end
    if #self.items >= YardInventory.ABSOLUTE_MAX_ITEMS then
        self.filling = false
        return
    end

    local item = self:generateOneItem()
    if item == nil then
        self.filling = false
        return
    end

    local storeItem = g_storeManager:getItemByXMLFilename(item.xmlFilename)
    if storeItem == nil then
        -- Bad item — try another.
        self:spawnNext()
        return
    end

    local data = VehicleLoadingData.new()
    data:setStoreItem(storeItem)

    local config = YardInventory.randomConfiguration(storeItem)
    data:setConfigurations(config)

    if not data:setLoadingPlace(self.spawnPlaces, self.usedPlaces) then
        -- No room left — yard is full. Remove the item we just added.
        table.remove(self.items)
        self.filling = false
        print(("[UsedEquipmentYards] Yard '%s' full — placed %d vehicles."):format(
            self.yard.name, #self.vehicles))
        return
    end

    data:setPropertyState(VehiclePropertyState.OWNED)
    data:setOwnerFarmId(0)

    self.pendingLoads[#self.pendingLoads + 1] = data
    data:load(self.onVehicleLoaded, self, { item = item, loadingData = data })
end

--- Callback when a vehicle finishes loading. Applies "used" look, then
--- tries to fill the next slot.
function YardInventory:onVehicleLoaded(loadedVehicles, loadState, args)
    for i, d in ipairs(self.pendingLoads) do
        if d == args.loadingData then
            table.remove(self.pendingLoads, i)
            break
        end
    end

    local item = args.item

    if loadState ~= VehicleLoadingState.OK then
        for _, v in ipairs(loadedVehicles) do
            v:delete()
        end
        self:spawnNext()
        return
    end

    for _, vehicle in ipairs(loadedVehicles) do
        vehicle:addWearAmount(math.random() * 0.3 + 0.1)
        vehicle:setOperatingTime(3600000 * (math.random() * 40 + 30))

        -- Apply a slight random yaw so vehicles don't look rigidly parked.
        local jitter = YardInventory.MAX_YAW_JITTER
        local rx, ry, rz = getRotation(vehicle.rootNode)
        setRotation(vehicle.rootNode, rx, ry + (math.random() * 2 - 1) * jitter, rz)

        item.vehicle = vehicle
        self.vehicles[#self.vehicles + 1] = vehicle
    end

    -- Try to fit another vehicle.
    self:spawnNext()
end

--- Pick random vehicle configurations (colour sets, etc.).
function YardInventory.randomConfiguration(storeItem)
    local result = {}
    StoreItemUtil.loadSpecsFromXML(storeItem)

    if storeItem.defaultConfigurationIds ~= nil then
        for k, v in pairs(storeItem.defaultConfigurationIds) do
            result[k] = v
        end
    end

    if storeItem.configurations ~= nil and storeItem.configurationSets ~= nil then
        local numSets = #storeItem.configurationSets
        if numSets > 0 then
            local chosen = math.random(1, numSets)
            for k, v in pairs(storeItem.configurationSets[chosen]) do
                result[k] = v
            end
        end
    end

    return result
end

-- ---------------------------------------------------------------------------
-- Purchase
-- ---------------------------------------------------------------------------

function YardInventory:removeItem(item)
    if item.vehicle ~= nil then
        for i, v in ipairs(self.vehicles) do
            if v == item.vehicle then
                table.remove(self.vehicles, i)
                break
            end
        end
        item.vehicle:delete()
        item.vehicle = nil
    end
    for i, v in ipairs(self.items) do
        if v == item then
            table.remove(self.items, i)
            return
        end
    end
end

function YardInventory:getItemCount()
    return #self.items
end

-- ---------------------------------------------------------------------------
-- XML persistence
-- ---------------------------------------------------------------------------

function YardInventory:saveToXML(xmlFile, key)
    setXMLInt(xmlFile, key .. "#lastRefreshPeriod", self.lastRefreshPeriod)
    setXMLInt(xmlFile, key .. "#lastRefreshYear",   self.lastRefreshYear)
    for i, item in ipairs(self.items) do
        local iKey = ("%s.item(%d)"):format(key, i - 1)
        setXMLString(xmlFile, iKey .. "#xmlFilename", item.xmlFilename or "")
        setXMLInt(xmlFile,    iKey .. "#price",       item.price or 0)
        setXMLInt(xmlFile,    iKey .. "#age",         item.age   or 0)
    end
end

function YardInventory:loadFromXML(xmlFile, key)
    self.lastRefreshPeriod = getXMLInt(xmlFile, key .. "#lastRefreshPeriod") or -1
    self.lastRefreshYear   = getXMLInt(xmlFile, key .. "#lastRefreshYear")  or -1

    local i = 0
    while true do
        local iKey = ("%s.item(%d)"):format(key, i)
        if not hasXMLProperty(xmlFile, iKey) then break end
        local item = {
            xmlFilename = getXMLString(xmlFile, iKey .. "#xmlFilename") or "",
            price       = getXMLInt(xmlFile,    iKey .. "#price")       or 0,
            age         = getXMLInt(xmlFile,    iKey .. "#age")         or 0,
            vehicle     = nil,
        }
        self.items[#self.items + 1] = item
        i = i + 1
    end
end
