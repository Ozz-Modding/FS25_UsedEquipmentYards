-- YardInventory
-- Manages the list of vehicles available at a single UsedEquipmentYard.
-- Handles spawning vehicles, monthly refresh, save/load, and purchase removal.
--
-- Each item = {
--   xmlFilename    string   -- store XML path for this vehicle
--   price          number   -- used price (from Vehicle.calculateSellPrice)
--   age            number   -- age in months
--   damage         number   -- 0..1 damage amount
--   wear           number   -- 0..1 wear amount
--   operatingTime  number   -- operating time in ms
--   vehicle        table    -- FS25 Vehicle object (nil when despawned)
-- }
--
-- Inventory refreshes once per in-game period (≈ month). The last-refreshed
-- period and year are persisted so a reload mid-period does not re-roll.

YardInventory = {}
YardInventory._mt = Class(YardInventory)

-- Safety cap to prevent runaway spawning (e.g. if collision checks fail).
YardInventory.ABSOLUTE_MAX_ITEMS = 50

-- Spawn mode constants.
YardInventory.SPAWN_FILL   = 1   -- fill yard to capacity (used on reset/dev)
YardInventory.SPAWN_SINGLE = 2   -- spawn one vehicle then stop (used on hourly tick)

-- Set to true to fill the yard immediately on creation (dev/testing).
-- Set to false for production: inventory builds up organically via hourly ticks.
YardInventory.FILL_ON_CREATE = true

-- ---------------------------------------------------------------------------
-- Quality presets — control hours, damage, and wear ranges
-- ---------------------------------------------------------------------------
-- Hours are engine hours (what you see on the dashboard). Age in months is
-- derived from hours for Vehicle.calculateSellPrice (~800 hours/year average).
YardInventory.HOURS_PER_YEAR = 800

YardInventory.QUALITY = {
    LOW = {
        hoursMin = 60, hoursMax = 120,
        damageMin = 0.35, damageMax = 0.7,
        wearMin = 0.5,  wearMax = 1.0,
    },
    MEDIUM = {
        hoursMin = 25, hoursMax = 60,
        damageMin = 0.15, damageMax = 0.45,
        wearMin = 0.2, wearMax = 0.65,
    },
    HIGH = {
        hoursMin = 5, hoursMax = 25,
        damageMin = 0.05, damageMax = 0.2,
        wearMin = 0.05, wearMax = 0.25,
    },
}

-- ---------------------------------------------------------------------------
-- Default yard configuration — quality tier, category weights, dirtiness
-- ---------------------------------------------------------------------------
-- Categories is a map of { CATEGORY_NAME = weight }. Weight 0 = excluded.
YardInventory.DEFAULT_CONFIG = {
    quality = "MEDIUM",
    dirtiness = 0.50,          -- base dirt level (0–1)
    categories = {
        TRACTORSS      = 10,
        TRACTORSM      = 5,
        TRACTORSL      = 1,
        TELELOADERS    = 4,
        WHEELLOADERSM  = 3,
        WHEELLOADERSL  = 2,
        SKIDSTEERS     = 3,
    },
}

-- Dirt jitter range applied ± around the dirtiness base
YardInventory.DIRT_RANGE = 0.20

-- Minimum vehicle new price to be included (filters out tiny items).
YardInventory.MIN_VEHICLE_PRICE = 10000
-- Maximum used price — vehicles priced above this after jitter are re-rolled.
YardInventory.MAX_VEHICLE_PRICE = 999999

-- Parking slot depth — how far a vehicle extends nose-in from the edge (metres).
YardInventory.SLOT_DEPTH = 6
-- Aisle width between perimeter parking and centre island (metres).
YardInventory.AISLE_WIDTH = 4
-- Inset from fence boundary to avoid spawning outside non-rectangular areas (metres).
YardInventory.BOUNDS_INSET = 3
-- Max random yaw offset so parked vehicles look organic (radians, ≈ ±10°).
YardInventory.MAX_YAW_JITTER = math.rad(10)

-- Price jitter — adds variety around the base sell-price formula.
-- PRICE_NORMAL_CHANCE: probability of the narrow band (0–1).
-- PRICE_NORMAL_SPREAD: ± multiplier for the narrow band (e.g. 0.10 = ±10%).
-- PRICE_WIDE_SPREAD: ± multiplier for the remaining wide band (e.g. 0.25 = ±25%).
YardInventory.PRICE_NORMAL_CHANCE = 0.85
YardInventory.PRICE_NORMAL_SPREAD = 0.10
YardInventory.PRICE_WIDE_SPREAD   = 0.25
-- Minimum yard dimension (after inset) for the full perimeter layout.
YardInventory.MIN_PERIMETER_SIZE = 12

-- ---------------------------------------------------------------------------
-- TTL (time to live) — how long a spawned vehicle stays before expiring.
-- ---------------------------------------------------------------------------
-- Range in in-game hours; each vehicle gets a random value in [min, max].
YardInventory.TTL_MIN_HOURS = 24
YardInventory.TTL_MAX_HOURS = 144
-- Probability each in-game hour that a new vehicle is spawned (if space allows).
YardInventory.HOURLY_SPAWN_CHANCE = 0.20

--- Deep-copy a config table so edits don't affect the original.
function YardInventory.copyConfig(cfg)
    local copy = {
        quality   = cfg.quality,
        dirtiness = cfg.dirtiness,
        categories = {},
    }
    for k, v in pairs(cfg.categories) do
        copy.categories[k] = v
    end
    return copy
end

function YardInventory.new(yard)
    local self = setmetatable({}, YardInventory._mt)
    self.yard              = yard
    self.config            = YardInventory.copyConfig(YardInventory.DEFAULT_CONFIG)
    self.items             = {}
    self.vehicles          = {}          -- spawned Vehicle objects
    self.pendingLoads      = {}          -- in-flight VehicleLoadingData
    self.spawnPlaces       = nil         -- built on first spawn
    self.usedPlaces        = nil         -- tracks consumed width per row
    self.filling           = false       -- true while the fill loop is running
    self.spawnMode         = YardInventory.SPAWN_FILL
    return self
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

--- Called by YardManager each in-game hour (MessageType.HOUR_CHANGED).
--- Ticks down TTL on all live vehicles and rolls for a new spawn.
function YardInventory:onHourChanged()
    -- Decrement TTL and expire vehicles whose time is up.
    local i = #self.items
    while i >= 1 do
        local item = self.items[i]
        if item.ttlHours ~= nil then
            item.ttlHours = item.ttlHours - 1
            if item.ttlHours <= 0 then
                self:removeItem(item)
            end
        end
        i = i - 1
    end

    -- Roll for a new spawn if not already in a spawn loop and under the cap.
    if not self.filling
       and #self.items < YardInventory.ABSOLUTE_MAX_ITEMS
       and math.random() < YardInventory.HOURLY_SPAWN_CHANCE then
        self:trySpawnOne()
    end
end

--- Called on yard creation and load. Respects FILL_ON_CREATE.
function YardInventory:spawn()
    self:buildSpawnPlaces()
    if YardInventory.FILL_ON_CREATE then
        self.spawnMode = YardInventory.SPAWN_FILL
        self.filling = true
        self:spawnNext()
    end
end

--- Attempt to spawn a single vehicle (hourly tick).
--- Rebuilds spawn places so freed slots are available after TTL expiries.
function YardInventory:trySpawnOne()
    self.spawnMode = YardInventory.SPAWN_SINGLE
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
        UsedEquipmentYards.vehicleToItem[vehicle] = nil
        PriceTagRenderer.removeTag(vehicle)
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

--- Full reset — despawns everything and fills from scratch.
--- Always fills regardless of FILL_ON_CREATE (explicit dev action).
function YardInventory:reset()
    self:despawnAll()
    self.items = {}
    self.storePool = nil
    self:buildSpawnPlaces()
    self.spawnMode = YardInventory.SPAWN_FILL
    self.filling = true
    self:spawnNext()
end

--- Apply a new config. Does NOT respawn — inventory updates organically via TTL.
function YardInventory:applyConfig(newConfig)
    self.config = YardInventory.copyConfig(newConfig)
    self.storePool = nil   -- force rebuild with new categories on next spawn
end

-- ---------------------------------------------------------------------------
-- Item generation
-- ---------------------------------------------------------------------------

--- Generate a single random item using the yard's config and quality preset.
--- Uses the same pricing formula as the base game's VehicleSaleSystem.
--- Re-rolls (up to MAX_REROLLS times) if the final price exceeds MAX_VEHICLE_PRICE.
local MAX_REROLLS = 5

function YardInventory:generateOneItem()
    if self.storePool == nil then
        self.storePool = self:buildStorePool()
    end
    if #self.storePool == 0 then return nil end

    for _ = 1, MAX_REROLLS do
        local item = self:rollItem()
        if item ~= nil and item.price <= YardInventory.MAX_VEHICLE_PRICE then
            self.items[#self.items + 1] = item
            return item
        end
    end

    return nil
end

--- Roll a single candidate item (not yet added to self.items).
function YardInventory:rollItem()
    -- Weighted random selection from the pool.
    local storeItem = self:pickWeightedItem()
    if storeItem == nil then return nil end

    -- Roll hours, damage, wear from the quality preset.
    local q = YardInventory.QUALITY[self.config.quality] or YardInventory.QUALITY.MEDIUM
    local hours   = q.hoursMin + math.random() * (q.hoursMax - q.hoursMin)
    local damage  = q.damageMin + math.random() * (q.damageMax - q.damageMin)
    local wear    = q.wearMin   + math.random() * (q.wearMax   - q.wearMin)
    local operatingTime = hours * 60 * 60 * 1000  -- hours → ms
    -- Derive age in months from hours for the price formula.
    local age = math.max(1, math.floor(hours / YardInventory.HOURS_PER_YEAR * 12))

    -- Pick a random configuration set (like VehicleSaleSystem does).
    local configs = YardInventory.randomConfiguration(storeItem)

    -- Use the game's own pricing: sell-price based on age, hours, repair & repaint.
    local defaultPrice = StoreItemUtil.getDefaultPrice(storeItem, {})
    local repairPrice  = 0
    local repaintPrice = 0
    if Wearable ~= nil then
        repairPrice  = Wearable.calculateRepairPrice(defaultPrice, damage)
        repaintPrice = Wearable.calculateRepaintPrice(defaultPrice, wear)
    end
    local price = defaultPrice
    if Vehicle ~= nil and Vehicle.calculateSellPrice ~= nil then
        price = Vehicle.calculateSellPrice(storeItem, age, operatingTime, defaultPrice, repairPrice, repaintPrice)
    end

    -- Add price variety around the base sell-price formula.
    local roll = math.random()
    local spread = roll < YardInventory.PRICE_NORMAL_CHANCE and YardInventory.PRICE_NORMAL_SPREAD or YardInventory.PRICE_WIDE_SPREAD
    local jitter = 1 + (math.random() * 2 - 1) * spread
    price = price * jitter

    return {
        xmlFilename   = storeItem.xmlFilename,
        price         = math.max(1, math.floor(price)),
        age           = age,
        damage        = damage,
        wear          = wear,
        operatingTime = operatingTime,
        ttlHours      = math.random(YardInventory.TTL_MIN_HOURS, YardInventory.TTL_MAX_HOURS),
        vehicle       = nil,
    }
end

--- Build a weighted pool of { storeItem, weight } entries from the config.
function YardInventory:buildStorePool()
    local cats = self.config.categories  -- map: CATEGORY_NAME = weight

    local pool = {}        -- { storeItem, weight }
    local totalWeight = 0

    for _, si in pairs(g_storeManager:getItems()) do
        if si.showInStore and si.extraContentId == nil
           and si.price >= YardInventory.MIN_VEHICLE_PRICE
           and StoreItemUtil.getIsVehicle(si) then
            for _, catName in ipairs(si.categoryNames or {}) do
                local w = cats[catName]
                if w ~= nil and w > 0 then
                    pool[#pool + 1] = { storeItem = si, weight = w }
                    totalWeight = totalWeight + w
                    break
                end
            end
        end
    end

    self.poolTotalWeight = totalWeight
    return pool
end

--- Weighted random pick from the store pool.
function YardInventory:pickWeightedItem()
    if #self.storePool == 0 or self.poolTotalWeight <= 0 then return nil end

    local roll = math.random() * self.poolTotalWeight
    local acc = 0
    for _, entry in ipairs(self.storePool) do
        acc = acc + entry.weight
        if roll <= acc then
            return entry.storeItem
        end
    end
    -- Fallback (rounding edge case).
    return self.storePool[#self.storePool].storeItem
end

-- ---------------------------------------------------------------------------
-- Spawn places — perimeter parking with optional centre island
-- ---------------------------------------------------------------------------
--
-- Layout (viewed from above):
--
--         +--- top row (face south) ---+
--         |                            |
--     left|   [aisle]  centre  [aisle] |right
--     col |   [aisle]  island  [aisle] |col
--         |                            |
--         +-- bottom row (face north) -+
--
-- Vehicles park nose-in around the perimeter. If the yard is wide enough a
-- centre island is added with two back-to-back rows. Aisles between the
-- perimeter and centre keep the fronts of vehicles accessible.

function YardInventory:buildSpawnPlaces()
    local b = self.yard.bounds
    local inset = YardInventory.BOUNDS_INSET
    local slot  = YardInventory.SLOT_DEPTH
    local aisle = YardInventory.AISLE_WIDTH

    self.spawnPlaces = {}
    self.usedPlaces  = {}

    -- Usable rectangle after inset
    local halfW = b.sizeX * 0.5 - inset
    local halfD = b.sizeZ * 0.5 - inset

    if halfW < 3 or halfD < 3 then return end -- yard too small

    local minX = b.cx - halfW
    local maxX = b.cx + halfW
    local minZ = b.cz - halfD
    local maxZ = b.cz + halfD
    local fullW = halfW * 2
    local fullD = halfD * 2

    -- For very small yards fall back to a single row along the longest edge.
    if fullW < YardInventory.MIN_PERIMETER_SIZE or fullD < YardInventory.MIN_PERIMETER_SIZE then
        if fullW >= fullD then
            self:addSpawnPlace(minX, b.cz - slot * 0.5, fullW, slot, 1,0,0, 0,0,1, 0)
        else
            self:addSpawnPlace(b.cx - slot * 0.5, minZ, fullD, slot, 0,0,1, 1,0,0, -math.pi * 0.5)
        end
        return
    end

    -- -----------------------------------------------------------------------
    -- Corner slots (angled 45° so vehicles can drive out into the aisle)
    -- -----------------------------------------------------------------------
    local corner = 5  -- corner square size — fits 1 vehicle

    -- Top-left — faces south-east
    self:addSpawnPlace(minX, minZ, corner, corner,
                       1,0,0,  0,0,1,  math.pi + math.pi * 0.25)
    -- Top-right — faces south-west
    self:addSpawnPlace(maxX - corner, minZ, corner, corner,
                       1,0,0,  0,0,1,  math.pi - math.pi * 0.25)
    -- Bottom-left — faces north-east
    self:addSpawnPlace(minX, maxZ - corner, corner, corner,
                       1,0,0,  0,0,-1,  -math.pi * 0.25)
    -- Bottom-right — faces north-west
    self:addSpawnPlace(maxX - corner, maxZ - corner, corner, corner,
                       1,0,0,  0,0,-1,  math.pi * 0.25)

    -- -----------------------------------------------------------------------
    -- Perimeter rows (shortened to leave room for corner slots)
    -- -----------------------------------------------------------------------
    local edgeW = fullW - corner * 2  -- top/bottom row width after corners
    local edgeD = fullD - corner * 2  -- side column length after corners

    if edgeW > 4 then
        -- Top row — vehicles face south (into the yard, +Z)
        self:addSpawnPlace(minX + corner, minZ, edgeW, slot,
                           1,0,0,  0,0,1,  math.pi)

        -- Bottom row — vehicles face north (into the yard, -Z)
        self:addSpawnPlace(minX + corner, maxZ - slot, edgeW, slot,
                           1,0,0,  0,0,-1,  0)
    end

    if edgeD > 4 then
        -- Left column — vehicles face east (+X)
        self:addSpawnPlace(minX, minZ + corner, edgeD, slot,
                           0,0,1,  1,0,0,  -math.pi * 0.5)

        -- Right column — vehicles face west (-X)
        self:addSpawnPlace(maxX - slot, minZ + corner, edgeD, slot,
                           0,0,1,  -1,0,0,  math.pi * 0.5)
    end

    -- -----------------------------------------------------------------------
    -- Centre island (two back-to-back rows facing outward)
    -- -----------------------------------------------------------------------
    local centreAvail = fullW - 2 * (slot + aisle)
    if centreAvail >= 5 and edgeD > 4 then
        local gap        = 2   -- gap between back-to-back rears
        local rowDepth   = (centreAvail - gap) * 0.5
        local centreX    = b.cx
        local islandZ    = minZ + corner
        local islandLen  = edgeD

        -- West row — vehicles face west (away from centre)
        self:addSpawnPlace(centreX - gap * 0.5, islandZ, islandLen, rowDepth,
                           0,0,1,  -1,0,0,  math.pi * 0.5)

        -- East row — vehicles face east (away from centre)
        self:addSpawnPlace(centreX + gap * 0.5, islandZ, islandLen, rowDepth,
                           0,0,1,  1,0,0,  -math.pi * 0.5)
    end
end

--- Helper: create one spawn-place row and register it.
function YardInventory:addSpawnPlace(sx, sz, width, depth, dx,dy,dz, px,py,pz, rotY)
    local y = getTerrainHeightAtWorldPos(g_terrainNode, sx, 0, sz)
    local place = {
        startX   = sx,
        startY   = y,
        startZ   = sz,
        width    = width,
        length   = depth,
        yOffset  = 1,
        rotX     = 0,
        rotY     = rotY,
        rotZ     = 0,
        dirX     = dx,
        dirY     = dy,
        dirZ     = dz,
        dirPerpX = px,
        dirPerpY = py,
        dirPerpZ = pz,
        maxWidth  = math.huge,
        maxLength = math.huge,
        maxHeight = math.huge,
        palletRotationOffset = 0,
    }
    self.spawnPlaces[#self.spawnPlaces + 1] = place
    self.usedPlaces[place] = 0
end

--- Returns true if (x, z) is within MIN_SPACING of any already-spawned vehicle.
YardInventory.MIN_SPACING = 2.5  -- metres

function YardInventory:isTooCloseToExisting(x, z)
    local minSq = YardInventory.MIN_SPACING * YardInventory.MIN_SPACING
    for _, v in ipairs(self.vehicles) do
        local ex, _, ez = getWorldTranslation(v.rootNode)
        local dx, dz = x - ex, z - ez
        if dx * dx + dz * dz < minSq then
            return true
        end
    end
    return false
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
        -- Check if the vehicle ended up inside the fence polygon.
        local vx, _, vz = getWorldTranslation(vehicle.rootNode)
        if not self.yard:containsPoint(vx, vz) or self:isTooCloseToExisting(vx, vz) then
            vehicle:delete()
        else
            -- Apply the item's pre-rolled condition values.
            if vehicle.addWearAmount ~= nil then
                vehicle:addWearAmount(item.wear or 0)
            end
            if vehicle.setDamageAmount ~= nil then
                vehicle:setDamageAmount(item.damage or 0)
            end
            vehicle:setOperatingTime(item.operatingTime or 0)

            -- Apply dirt based on yard dirtiness config ± DIRT_RANGE.
            if vehicle.setDirtAmount ~= nil then
                local base = self.config.dirtiness or 0.20
                local range = YardInventory.DIRT_RANGE
                local dirt = base + (math.random() * 2 - 1) * range
                vehicle:setDirtAmount(math.max(0, math.min(1, dirt)))
            end

            -- Apply a slight random yaw so vehicles don't look rigidly parked.
            local jitter = YardInventory.MAX_YAW_JITTER
            local rx, ry, rz = getRotation(vehicle.rootNode)
            setRotation(vehicle.rootNode, rx, ry + (math.random() * 2 - 1) * jitter, rz)

            -- Exclude from Tab-cycle so the player can't switch into yard vehicles.
            if vehicle.setIsTabbable ~= nil then
                vehicle:setIsTabbable(false)
            end

            -- Block driving inputs. Stored in spec_drivable.playerControlAllowedFunctions
            -- keyed by NetworkUtil.getObjectId(vehicle). Cleared on purchase via
            -- EquipmentPurchasedEvent.clearVehicleRestrictions().
            if vehicle.registerPlayerVehicleControlAllowedFunction ~= nil then
                vehicle:registerPlayerVehicleControlAllowedFunction(vehicle, function()
                    return false, nil
                end)
            end

            item.vehicle = vehicle
            self.vehicles[#self.vehicles + 1] = vehicle
            UsedEquipmentYards.vehicleToItem[vehicle] = item
            PriceTagRenderer.addTag(vehicle, item)

            -- Register purchase activatable so the player can buy this vehicle.
            local activatable = YardVehicleActivatable.new(self.yard, item)
            item.activatable = activatable
            g_currentMission.activatableObjectsSystem:addActivatable(activatable)
        end
    end

    -- Continue filling if in fill mode, otherwise stop after this one vehicle.
    if self.spawnMode == YardInventory.SPAWN_FILL then
        self:spawnNext()
    else
        self.filling = false
    end
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

--- Remove an item from the yard.
--- keepVehicle=true when the vehicle has been purchased and should stay in the
--- world under new ownership. Default (nil/false) deletes the vehicle (TTL expiry).
function YardInventory:removeItem(item, keepVehicle)
    -- Unregister the purchase activatable.
    if item.activatable ~= nil then
        g_currentMission.activatableObjectsSystem:removeActivatable(item.activatable)
        item.activatable = nil
    end

    if item.vehicle ~= nil then
        for i, v in ipairs(self.vehicles) do
            if v == item.vehicle then
                table.remove(self.vehicles, i)
                break
            end
        end
        UsedEquipmentYards.vehicleToItem[item.vehicle] = nil
        if not keepVehicle then
            PriceTagRenderer.removeTag(item.vehicle)
            item.vehicle:delete()
        end
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
    -- Save config.
    setXMLString(xmlFile, key .. ".config#quality",   self.config.quality or "MEDIUM")
    setXMLFloat(xmlFile,  key .. ".config#dirtiness", self.config.dirtiness or 0.20)

    local ci = 0
    for catName, weight in pairs(self.config.categories) do
        if weight > 0 then
            local cKey = ("%s.config.category(%d)"):format(key, ci)
            setXMLString(xmlFile, cKey .. "#name",   catName)
            setXMLInt(xmlFile,    cKey .. "#weight", weight)
            ci = ci + 1
        end
    end

    -- Save items.
    for i, item in ipairs(self.items) do
        local iKey = ("%s.item(%d)"):format(key, i - 1)
        setXMLString(xmlFile, iKey .. "#xmlFilename",    item.xmlFilename or "")
        setXMLInt(xmlFile,    iKey .. "#price",          item.price or 0)
        setXMLInt(xmlFile,    iKey .. "#age",            item.age   or 0)
        setXMLFloat(xmlFile,  iKey .. "#damage",         item.damage or 0)
        setXMLFloat(xmlFile,  iKey .. "#wear",           item.wear   or 0)
        setXMLFloat(xmlFile,  iKey .. "#operatingTime",  (item.operatingTime or 0) / 1000)
        setXMLInt(xmlFile,    iKey .. "#ttlHours",       item.ttlHours or YardInventory.TTL_MIN_HOURS)
    end
end

function YardInventory:loadFromXML(xmlFile, key)
    -- Load config (fall back to defaults if not present).
    if hasXMLProperty(xmlFile, key .. ".config") then
        self.config = {
            quality   = getXMLString(xmlFile, key .. ".config#quality")  or "MEDIUM",
            dirtiness = getXMLFloat(xmlFile,  key .. ".config#dirtiness") or 0.20,
            categories = {},
        }
        local ci = 0
        while true do
            local cKey = ("%s.config.category(%d)"):format(key, ci)
            if not hasXMLProperty(xmlFile, cKey) then break end
            local catName = getXMLString(xmlFile, cKey .. "#name")
            local weight  = getXMLInt(xmlFile,    cKey .. "#weight") or 0
            if catName ~= nil then
                self.config.categories[catName] = weight
            end
            ci = ci + 1
        end
    end

    -- Load items.
    local i = 0
    while true do
        local iKey = ("%s.item(%d)"):format(key, i)
        if not hasXMLProperty(xmlFile, iKey) then break end
        local item = {
            xmlFilename   = getXMLString(xmlFile, iKey .. "#xmlFilename") or "",
            price         = getXMLInt(xmlFile,    iKey .. "#price")       or 0,
            age           = getXMLInt(xmlFile,    iKey .. "#age")         or 0,
            damage        = getXMLFloat(xmlFile,  iKey .. "#damage")     or 0,
            wear          = getXMLFloat(xmlFile,  iKey .. "#wear")       or 0,
            operatingTime = (getXMLFloat(xmlFile, iKey .. "#operatingTime") or 0) * 1000,
            ttlHours      = getXMLInt(xmlFile,    iKey .. "#ttlHours")   or YardInventory.TTL_MIN_HOURS,
            vehicle       = nil,
        }
        self.items[#self.items + 1] = item
        i = i + 1
    end
end
