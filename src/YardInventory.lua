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

YardInventory                          = {}
YardInventory._mt                      = Class(YardInventory)

-- Safety cap to prevent runaway spawning (e.g. if collision checks fail).
YardInventory.MAX_PLACEMENT_FAILURES   = 5  -- consecutive placement failures before giving up

-- Spawn mode constants.
YardInventory.SPAWN_FILL               = 1 -- fill yard to capacity (used on reset)
YardInventory.SPAWN_SINGLE             = 2 -- spawn one vehicle then stop (used on hourly tick)

-- ---------------------------------------------------------------------------
-- Quality presets — control hours, damage, and wear ranges
-- ---------------------------------------------------------------------------
-- Hours are engine hours (what you see on the dashboard). Age in months is
-- derived from hours for Vehicle.calculateSellPrice (~800 hours/year average).
YardInventory.HOURS_PER_YEAR           = 800

YardInventory.QUALITY                  = {
    LOW = {
        hoursMin = 30,
        hoursMax = 60,
        damageMin = 0.35,
        damageMax = 0.7,
        wearMin = 0.5,
        wearMax = 1.0,
    },
    MEDIUM = {
        hoursMin = 17,
        hoursMax = 28,
        damageMin = 0.15,
        damageMax = 0.45,
        wearMin = 0.2,
        wearMax = 0.65,
    },
    HIGH = {
        hoursMin = 5,
        hoursMax = 15,
        damageMin = 0.05,
        damageMax = 0.2,
        wearMin = 0.05,
        wearMax = 0.25,
    },
    EX_DEMO = {
        hoursMin = 1,
        hoursMax = 4,
        damageMin = 0.0,
        damageMax = 0.05,
        wearMin = 0.0,
        wearMax = 0.10,
    },
    NEW = {
        hoursMin = 0.2,
        hoursMax = 1,
        damageMin = 0.0,
        damageMax = 0.0,
        wearMin = 0.0,
        wearMax = 0.0,
    },
}

-- ---------------------------------------------------------------------------
-- Default yard configuration — quality tier, category weights, dirtiness, brands
-- ---------------------------------------------------------------------------
-- Categories is a map of { CATEGORY_NAME = weight }. Weight 0 = excluded.
-- Brands is a map of { BRAND_NAME = weight }. Empty table = all brands allowed (weight 1).
YardInventory.DEFAULT_CONFIG           = {
    quality = "MEDIUM",
    dirtiness = 0.50, -- base dirt level (0–1)
    categories = {
        TRACTORSS           = 10,
        TRACTORSM           = 5,
        TRACTORSL           = 1,
        TELELOADERVEHICLES  = 4,
        WHEELLOADERVEHICLES = 2,
        SKIDSTEERVEHICLES   = 2,
    },
    brands = {},  -- empty = all brands with weight 1
    minWorkingWidth = 0,   -- 0 = no minimum
    maxWorkingWidth = 0,   -- 0 = no maximum
    maxPrice        = 0,   -- 0 = no maximum (hard cap MAX_VEHICLE_PRICE still applies)
    avgStockHours   = 96,  -- average hours a vehicle stays before TTL expiry
    gridSpacing     = 8,   -- metres between spawn grid points
}

-- Dirt jitter range applied ± around the dirtiness base
YardInventory.DIRT_RANGE               = 0.20
YardInventory.FUEL_BASE                = 0.15  -- target fuel level
YardInventory.FUEL_RANGE               = 0.04  -- ± random variation
YardInventory.FUEL_MIN                 = 0.11  -- floor: Motorized:onPostLoad charges farmId on < 10%

-- Minimum vehicle new price to be included (filters out tiny items).
YardInventory.MIN_VEHICLE_PRICE        = 2000
-- Maximum used price — vehicles priced above this after jitter are re-rolled.
YardInventory.MAX_VEHICLE_PRICE        = 999999

-- Inset from fence boundary to avoid spawning outside non-rectangular areas (metres).
YardInventory.BOUNDS_INSET             = 3

-- ---------------------------------------------------------------------------
-- Grid placement constants
-- ---------------------------------------------------------------------------
-- Spacing (metres) between spawn grid points within the yard polygon.
YardInventory.GRID_SPACING             = 8
-- Buffer distance (metres) added around each vehicle's footprint when
-- checking grid occupancy. Ensures clearance to drive out.
YardInventory.VEHICLE_CLEARANCE_BUFFER = 1.0
-- Yaw jitter range (radians). Vehicles face toward the yard entrance
-- (anchor point) then add uniform noise within this range. ≈ ±15°.
YardInventory.YAW_JITTER               = math.rad(15)
-- Terrain offset (metres) when calling setPosition — lifts the vehicle
-- slightly above the ground to avoid clipping.
YardInventory.TERRAIN_OFFSET           = 0.5
-- Collision mask for overlapBox spawn checks. Detects vehicles and
-- static objects (buildings, fences) but not triggers or terrain.
-- DEFAULT(0x1) | DYNAMIC_OBJECT(0x20) | BUILDING(0x40) | VEHICLE(0x10000)
YardInventory.OVERLAP_COLLISION_MASK   = 0x10061

-- Price jitter — adds variety around the base sell-price formula.
-- Spread scales inversely with price (sqrt curve). At the reference price (100k):
--   normal band ≈ ±2.5%, wide band ≈ ±3.5%.
-- Cheaper items get wider variance; expensive items tighten up.
YardInventory.PRICE_NORMAL_CHANCE      = 0.85
YardInventory.PRICE_REFERENCE          = 100000
YardInventory.PRICE_NORMAL_BASE        = 0.025   -- ±2.5% at reference price
YardInventory.PRICE_WIDE_BASE          = 0.035   -- ±3.5% at reference price
YardInventory.PRICE_SPREAD_MAX         = 0.12    -- cap for very cheap items

function YardInventory.getPriceSpread(price, isWide)
    local base = isWide and YardInventory.PRICE_WIDE_BASE or YardInventory.PRICE_NORMAL_BASE
    local scale = math.sqrt(YardInventory.PRICE_REFERENCE / math.max(1, price))
    return math.min(base * scale, YardInventory.PRICE_SPREAD_MAX)
end

-- ---------------------------------------------------------------------------
-- TTL (time to live) — how long a spawned vehicle stays before expiring.
-- ---------------------------------------------------------------------------
-- Derived from config.avgStockHours: uniform random in [avg*0.5, avg*1.5].
YardInventory.DEFAULT_AVG_STOCK_HOURS  = 96
-- Probability each in-game hour that a new vehicle is spawned (if space allows).
YardInventory.HOURLY_SPAWN_CHANCE      = 0.35

--- Deep-copy a config table so edits don't affect the original.
function YardInventory.copyConfig(cfg)
    local copy = {
        quality         = cfg.quality,
        dirtiness       = cfg.dirtiness,
        categories      = {},
        brands          = {},
        minWorkingWidth = cfg.minWorkingWidth or 0,
        maxWorkingWidth = cfg.maxWorkingWidth or 0,
        maxPrice        = cfg.maxPrice or 0,
        avgStockHours   = cfg.avgStockHours or 96,
        gridSpacing     = cfg.gridSpacing or 8,
    }
    for k, v in pairs(cfg.categories) do
        copy.categories[k] = v
    end
    for k, v in pairs(cfg.brands or {}) do
        copy.brands[k] = v
    end
    return copy
end

function YardInventory.new(yard)
    local self               = setmetatable({}, YardInventory._mt)
    self.yard                = yard
    self.config              = YardInventory.copyConfig(YardInventory.DEFAULT_CONFIG)
    self.items               = {}
    self.vehicles            = {}  -- spawned Vehicle objects
    self.pendingLoads        = {}  -- in-flight VehicleLoadingData
    self.spawnGrid           = {}  -- grid points: { x, z, occupied }
    self.filling             = false -- true while the fill loop is running
    self.placementFailures   = 0     -- consecutive placement failures
    self.spawnMode           = YardInventory.SPAWN_FILL
    self.fillDelayMs         = nil   -- ms to wait before starting fill (physics cleanup)
    self.pendingSoldItems    = {}  -- items from player sales waiting for yard space
    return self
end

--- Return a random TTL based on the yard's avgStockHours config.
--- Uniform random in [avg*0.5, avg*1.5] so the mean equals avg.
function YardInventory:randomTTL()
    local avg = self.config.avgStockHours or YardInventory.DEFAULT_AVG_STOCK_HOURS
    local minH = math.max(1, math.floor(avg * 0.5))
    local maxH = math.ceil(avg * 1.5)
    return math.random(minH, maxH)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

--- Called by YardManager each in-game hour (MessageType.HOUR_CHANGED).
--- Ticks down TTL on all live vehicles, checks overdue test drives, and
--- rolls for a new spawn.
function YardInventory:onHourChanged()
    local env = g_currentMission.environment

    -- Decrement TTL and expire vehicles whose time is up.
    -- Skip vehicles on test drive or hidden (waiting for yard space).
    local i = #self.items
    while i >= 1 do
        local item = self.items[i]
        if item.testDrive == nil and item.ttlHours ~= nil and not self:isItemHidden(item) then
            item.ttlHours = item.ttlHours - 1
            if item.ttlHours <= 0 then
                self:removeItem(item)
            end
        end
        i = i - 1
    end

    -- Fine overdue test drives (1% of price per hour, minimum 50).
    for _, item in ipairs(self.items) do
        local td = item.testDrive
        if td ~= nil then
            local overdue = (env.currentMonotonicDay > td.returnByDay)
                or (env.currentMonotonicDay == td.returnByDay and env.currentHour >= td.returnByHour)
            if overdue then
                local fine = math.max(TestDriveEvent.FINE_MINIMUM,
                    math.floor(item.price * TestDriveEvent.FINE_PER_HOUR))
                g_currentMission:addMoneyChange(-fine, td.farmId, MoneyType.OTHER, true)
                g_farmManager:getFarmById(td.farmId):changeBalance(-fine, MoneyType.OTHER)
            end
        end
    end

    -- Pending sold items take priority over new random stock.
    if #self.pendingSoldItems > 0 then
        if not self.filling and self.fillDelayMs == nil then
            self.fillDelayMs = 500
        end
        return -- block new stock while pending items exist
    end

    -- Roll for a new spawn if not already in a spawn loop and under the cap.
    -- Skip if we're still restoring saved items.
    if not self.filling
        and self.fillDelayMs == nil
        and math.random() < YardInventory.HOURLY_SPAWN_CHANCE then
        self:trySpawnOne()
    end
end

--- Called after mission start. Re-associates saved items with game-restored
--- vehicles by uniqueId. New yards start empty — inventory builds via hourly ticks.
function YardInventory:spawn()
    if #self.items == 0 then return end

    local associated = 0
    local orphaned = 0
    local i = #self.items
    while i >= 1 do
        local item = self.items[i]
        local vehicle = nil
        if item.vehicleUniqueId ~= nil then
            vehicle = g_currentMission.vehicleSystem:getVehicleByUniqueId(item.vehicleUniqueId)
        end

        if vehicle ~= nil then
            item.vehicle = vehicle
            item.vehicleUniqueId = nil  -- no longer needed
            UsedEquipmentYards.vehicleToItem[vehicle] = item

            if item.hidden then
                -- Hidden vehicle waiting for yard space — keep hidden, add to pending list.
                self:hideVehicle(vehicle)
                self.pendingSoldItems[#self.pendingSoldItems + 1] = item
                item.hidden = nil  -- flag consumed
            else
                self.vehicles[#self.vehicles + 1] = vehicle

                -- Re-apply yard vehicle state.
                if item.testDrive ~= nil then
                    vehicle:setOwnerFarmId(item.testDrive.farmId)
                    UsedEquipmentYards.clearVehicleRestrictions(vehicle)
                else
                    -- Lock the vehicle and add price tag.
                    if vehicle.setIsTabbable ~= nil then vehicle:setIsTabbable(false) end
                    if vehicle.registerPlayerVehicleControlAllowedFunction ~= nil then
                        vehicle:registerPlayerVehicleControlAllowedFunction(vehicle, function() return false, nil end)
                    end
                    UsedEquipmentYards.setADSExcluded(vehicle, true)
                    PriceTagRenderer.addTag(vehicle, item)
                end

                -- Register activatable.
                local activatable = YardVehicleActivatable.new(self.yard, item)
                item.activatable = activatable
                g_currentMission.activatableObjectsSystem:addActivatable(activatable)

                -- Sync to remote MP clients.
                local itemIndex = nil
                for idx, itm in ipairs(self.items) do
                    if itm == item then itemIndex = idx; break end
                end
                if itemIndex ~= nil then
                    g_server:broadcastEvent(VehicleItemSyncEvent.new(self.yard.id, itemIndex, item))
                end
            end

            associated = associated + 1
        else
            -- Vehicle not found — remove orphaned item.
            table.remove(self.items, i)
            orphaned = orphaned + 1
        end
        i = i - 1
    end

    -- Build the spawn grid and mark occupied points from loaded vehicles.
    self:buildSpawnGrid()
    self:rebuildGridOccupancy()

    -- Try to place any pending sold items that were queued before the save.
    self:trySpawnPendingSoldItem()

end

--- Attempt to spawn a single vehicle (hourly tick).
function YardInventory:trySpawnOne()
    self.spawnMode = YardInventory.SPAWN_SINGLE
    self.filling = true
    if #self.spawnGrid == 0 then
        self:buildSpawnGrid()
    end
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
        self:freeGridPoints(item)
        item.vehicle = nil
    end
end

--- Full reset — despawns everything (including pending sold items) and fills
--- from scratch. Spawning starts after a short delay so deleted vehicles'
--- physics are cleaned up before the overlapBox checks run.
function YardInventory:reset()
    self:despawnAll()
    self.items = {}
    self.pendingSoldItems = {}
    self.storePool = nil
    self:buildSpawnGrid()
    self.spawnMode = YardInventory.SPAWN_FILL
    self.filling = true
    self.fillDelayMs = 500  -- wait for physics engine to clean up deleted vehicles
end

--- Tick down the fill delay and start spawning when ready.
--- Called from the main update loop via YardManager.
function YardInventory:update(dt)
    if self.fillDelayMs ~= nil then
        self.fillDelayMs = self.fillDelayMs - dt
        if self.fillDelayMs <= 0 then
            self.fillDelayMs = nil
            if self.filling then
                self:spawnNext()
            elseif #self.pendingSoldItems > 0 then
                self:trySpawnPendingSoldItem()
            end
        end
    end
end

--- Apply a new config. Does NOT respawn — inventory updates organically via TTL.
function YardInventory:applyConfig(newConfig)
    local oldSpacing = self.config.gridSpacing or 8
    self.config = YardInventory.copyConfig(newConfig)
    self.storePool = nil -- force rebuild with new categories on next spawn
    -- Rebuild spawn grid if spacing changed.
    if (self.config.gridSpacing or 8) ~= oldSpacing then
        self:buildSpawnGrid()
        self:rebuildGridOccupancy()
    end
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
    local q             = YardInventory.QUALITY[self.config.quality] or YardInventory.QUALITY.MEDIUM
    local hours         = q.hoursMin + math.random() * (q.hoursMax - q.hoursMin)
    local damage        = q.damageMin + math.random() * (q.damageMax - q.damageMin)
    local wear          = q.wearMin + math.random() * (q.wearMax - q.wearMin)
    local operatingTime = hours * 60 * 60 * 1000 -- hours → ms
    -- Derive age in months from hours for the price formula.
    local age           = math.max(1, math.floor(hours / YardInventory.HOURS_PER_YEAR * 12))

    -- Pick a random configuration set (like VehicleSaleSystem does).
    local configs       = YardInventory.randomConfiguration(storeItem)

    -- Use the game's own pricing with the chosen configuration's price.
    local configuredPrice = StoreItemUtil.getDefaultPrice(storeItem, configs)
    local repairPrice     = 0
    local repaintPrice    = 0
    if Wearable ~= nil then
        repairPrice  = Wearable.calculateRepairPrice(configuredPrice, damage)
        repaintPrice = Wearable.calculateRepaintPrice(configuredPrice, wear)
    end
    local price = configuredPrice
    if Vehicle ~= nil and Vehicle.calculateSellPrice ~= nil then
        price = Vehicle.calculateSellPrice(storeItem, age, operatingTime, configuredPrice, repairPrice, repaintPrice)
    end

    -- Add price variety around the base sell-price formula.
    local roll = math.random()
    local isWide = roll >= YardInventory.PRICE_NORMAL_CHANCE
    local spread = YardInventory.getPriceSpread(price, isWide)
    local jitter = 1 + (math.random() * 2 - 1) * spread
    price = price * jitter

    local finalPrice = math.max(1, math.floor(price))

    -- Number of previous owners: based on hours (1 owner per ~25h), ±1.
    local numOwners = math.max(1, math.floor(hours / 25) + math.random(-1, 1))

    -- Minimum acceptable barter price: heavily weighted within 10% of asking,
    -- with a small chance of accepting a larger discount.
    local discountRoll = math.random()
    local maxDiscount
    if discountRoll < 0.70 then
        maxDiscount = 0.05 + math.random() * 0.05   -- 5–10% off
    elseif discountRoll < 0.90 then
        maxDiscount = 0.10 + math.random() * 0.05   -- 10–15% off
    elseif discountRoll < 0.97 then
        maxDiscount = 0.15 + math.random() * 0.05   -- 15–20% off
    else
        maxDiscount = 0.20 + math.random() * 0.10   -- 20–30% off (rare)
    end
    local minAcceptablePrice = math.max(1, math.floor(finalPrice * (1 - maxDiscount)))

    return {
        xmlFilename      = storeItem.xmlFilename,
        configurations   = configs,
        price            = finalPrice,
        minPrice         = minAcceptablePrice,
        numOwners        = numOwners,
        age              = age,
        damage           = damage,
        wear             = wear,
        operatingTime    = operatingTime,
        ttlHours         = self:randomTTL(),
        vehicle          = nil,
    }
end

--- Build a weighted pool of { storeItem, weight } entries from the config.
--- Weight = category weight * brand weight. Brand weight defaults to 1 if
--- the brands table is empty (no brand filter configured).
function YardInventory:buildStorePool()
    local cats   = self.config.categories  -- map: CATEGORY_NAME = weight
    local brands = self.config.brands      -- map: BRAND_NAME = weight (empty = all)
    local hasBrandFilter = next(brands) ~= nil
    local minWW = self.config.minWorkingWidth or 0
    local maxWW = self.config.maxWorkingWidth or 0

    local pool = {}        -- { storeItem, weight }
    local totalWeight = 0

    local cfgMaxPrice = self.config.maxPrice or 0
    local effectiveMaxPrice = cfgMaxPrice > 0 and math.min(cfgMaxPrice, YardInventory.MAX_VEHICLE_PRICE) or YardInventory.MAX_VEHICLE_PRICE

    for _, si in pairs(g_storeManager:getItems()) do
        if si.showInStore and si.extraContentId == nil
            and si.bundleInfo == nil
            and si.price >= YardInventory.MIN_VEHICLE_PRICE
            and si.price <= effectiveMaxPrice
            and StoreItemUtil.getIsVehicle(si) then

            -- Working width filter: only applies to items that HAVE a working width spec.
            local passesWW = true
            pcall(StoreItemUtil.loadSpecsFromXML, si)
            if si.specs ~= nil and si.specs.workingWidth ~= nil then
                local ww = si.specs.workingWidth.width or 0
                if minWW > 0 and ww < minWW then passesWW = false end
                if maxWW > 0 and ww > maxWW then passesWW = false end
            end

            if passesWW then
                -- Brand weight: if no filter configured, all brands get weight 1.
                local brandWeight = 1
                if hasBrandFilter then
                    local brand = g_brandManager:getBrandByIndex(si.brandIndex)
                    local brandName = brand ~= nil and brand.name or nil
                    brandWeight = brandName ~= nil and (brands[brandName] or 0) or 0
                end

                if brandWeight > 0 then
                    for _, catName in ipairs(si.categoryNames or {}) do
                        local catWeight = cats[catName]
                        if catWeight ~= nil and catWeight > 0 then
                            local w = catWeight * brandWeight
                            pool[#pool + 1] = { storeItem = si, weight = w }
                            totalWeight = totalWeight + w
                            break
                        end
                    end
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
-- Grid-based placement — pre-computed points within the fence polygon
-- ---------------------------------------------------------------------------

--- Build a grid of candidate spawn points within the yard polygon.
--- Called once on yard creation and after reset.
function YardInventory:buildSpawnGrid()
    local b = self.yard.bounds
    local inset = YardInventory.BOUNDS_INSET
    local spacing = self.config.gridSpacing or YardInventory.GRID_SPACING

    local halfW = b.sizeX * 0.5 - inset
    local halfD = b.sizeZ * 0.5 - inset

    self.spawnGrid = {}
    if halfW < 2 or halfD < 2 then return end

    local minX = b.cx - halfW
    local maxX = b.cx + halfW
    local minZ = b.cz - halfD
    local maxZ = b.cz + halfD

    local x = minX
    while x <= maxX do
        local z = minZ
        while z <= maxZ do
            if self.yard:containsPoint(x, z) then
                self.spawnGrid[#self.spawnGrid + 1] = { x = x, z = z, occupied = false }
            end
            z = z + spacing
        end
        x = x + spacing
    end
end

--- Return the indices of all grid points that fall within a rotated
--- rectangle centred at (cx, cz). Pure geometry — no buffer added.
function YardInventory:getGridPointsInRect(cx, cz, halfW, halfL, yaw)
    local cosY = math.cos(-yaw)
    local sinY = math.sin(-yaw)
    local indices = {}

    for i, pt in ipairs(self.spawnGrid) do
        local dx = pt.x - cx
        local dz = pt.z - cz
        local localX = dx * cosY - dz * sinY
        local localZ = dx * sinY + dz * cosY
        if math.abs(localX) <= halfW and math.abs(localZ) <= halfL then
            indices[#indices + 1] = i
        end
    end

    return indices
end

--- Check whether every grid point in a list of indices is unoccupied.
function YardInventory:areGridPointsAvailable(indices)
    for _, idx in ipairs(indices) do
        if self.spawnGrid[idx].occupied then
            return false
        end
    end
    return true
end

--- Mark grid points occupied by a vehicle using its actual dimensions.
--- Any grid point that falls within the vehicle's width × length footprint
--- is invalidated.
function YardInventory:markGridOccupied(item, cx, cz, halfW, halfL, yaw)
    local indices = self:getGridPointsInRect(cx, cz, halfW, halfL, yaw)
    item.gridIndices = indices
    for _, idx in ipairs(indices) do
        self.spawnGrid[idx].occupied = true
    end
end

--- Free the grid points owned by an item.
function YardInventory:freeGridPoints(item)
    if item.gridIndices == nil then return end
    for _, idx in ipairs(item.gridIndices) do
        if self.spawnGrid[idx] ~= nil then
            self.spawnGrid[idx].occupied = false
        end
    end
    item.gridIndices = nil
end

--- Rebuild grid occupancy from live vehicles and test-drive reservations.
--- Called after loading a save or re-associating vehicles.
function YardInventory:rebuildGridOccupancy()
    -- Reset all points.
    for _, pt in ipairs(self.spawnGrid) do
        pt.occupied = false
    end

    for _, item in ipairs(self.items) do
        if not self:isItemHidden(item) then
            local cx, cz, halfW, halfL, yaw

            if item.testDrive ~= nil then
                local td = item.testDrive
                cx, cz = td.origX, td.origZ
                halfW = (item.spawnWidth or 4) * 0.5
                halfL = (item.spawnLength or 4) * 0.5
                yaw   = item.spawnYaw or td.origRy or 0
            elseif item.vehicle ~= nil then
                cx, _, cz = getWorldTranslation(item.vehicle.rootNode)
                halfW = (item.spawnWidth or 4) * 0.5
                halfL = (item.spawnLength or 4) * 0.5
                yaw   = item.spawnYaw or 0
            end

            if cx ~= nil then
                self:markGridOccupied(item, cx, cz, halfW, halfL, yaw)
            end
        end
    end
end

--- Find an available grid point for a vehicle with the given dimensions.
--- Shuffles candidates for variety. Checks grid availability then runs an
--- overlapBox collision test.
---@param width number  vehicle width (metres)
---@param length number vehicle length (metres)
---@return number|nil x
---@return number|nil z
---@return number|nil yaw
function YardInventory:findSpawnPoint(width, length)
    if self.spawnGrid == nil or #self.spawnGrid == 0 then return nil end

    -- Collect available point indices and shuffle.
    local available = {}
    for i, pt in ipairs(self.spawnGrid) do
        if not pt.occupied then
            available[#available + 1] = i
        end
    end
    for i = #available, 2, -1 do
        local j = math.random(1, i)
        available[i], available[j] = available[j], available[i]
    end

    local halfW = width * 0.5
    local halfL = length * 0.5

    for _, idx in ipairs(available) do
        local pt = self.spawnGrid[idx]
        local yaw = self:parkingYaw(pt.x, pt.z)

        if self:isFootprintInsideYard(pt.x, pt.z, halfW, halfL, yaw) then
            -- Check availability using vehicle size + clearance buffer.
            local buf = YardInventory.VEHICLE_CLEARANCE_BUFFER
            local checkIndices = self:getGridPointsInRect(pt.x, pt.z, halfW + buf, halfL + buf, yaw)
            if self:areGridPointsAvailable(checkIndices) then
                if self:isClearOfExistingVehicles(pt.x, pt.z, halfW, halfL)
                    and self:isPositionClear(pt.x, pt.z, halfW, halfL, yaw) then
                    return pt.x, pt.z, yaw
                end
            end
        end
    end

    return nil
end

--- Check that all four corners of the vehicle's rotated footprint are
--- inside the yard polygon.
function YardInventory:isFootprintInsideYard(cx, cz, halfW, halfL, yaw)
    local cosY = math.cos(yaw)
    local sinY = math.sin(yaw)
    local corners = {
        { -halfW, -halfL },
        {  halfW, -halfL },
        {  halfW,  halfL },
        { -halfW,  halfL },
    }
    for _, c in ipairs(corners) do
        local wx = cx + c[1] * cosY - c[2] * sinY
        local wz = cz + c[1] * sinY + c[2] * cosY
        if not self.yard:containsPoint(wx, wz) then
            return false
        end
    end
    return true
end

--- Compute yaw so the vehicle faces toward the yard entrance (anchor point),
--- with ± YAW_JITTER for a natural look.
function YardInventory:parkingYaw(x, z)
    local b = self.yard.bounds
    local ax = b.anchorX or b.cx
    local az = b.anchorZ or b.cz
    local dx = ax - x
    local dz = az - z
    local base = math.atan2(dx, dz) + math.pi
    local jitter = (math.random() * 2 - 1) * YardInventory.YAW_JITTER
    return base + jitter
end

--- Check if an item is in the hidden pending sold list.
function YardInventory:isItemHidden(item)
    for _, pItem in ipairs(self.pendingSoldItems) do
        if pItem == item then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Distance check — Lua-based, independent of physics timing
-- ---------------------------------------------------------------------------

--- Check that the candidate position doesn't overlap with any existing
--- yard vehicle. Uses centre-to-centre distance vs sum of half-diagonals.
--- This is deliberately conservative (treats vehicles as circles) but
--- guarantees no overlaps even when physics hasn't registered a just-loaded
--- vehicle yet.
function YardInventory:isClearOfExistingVehicles(cx, cz, halfW, halfL)
    local buf = YardInventory.VEHICLE_CLEARANCE_BUFFER
    local candidateRadius = math.sqrt(halfW * halfW + halfL * halfL) + buf

    for _, item in ipairs(self.items) do
        if item.vehicle ~= nil and not self:isItemHidden(item) then
            local vx, _, vz = getWorldTranslation(item.vehicle.rootNode)
            local eHalfW = (item.spawnWidth or 4) * 0.5
            local eHalfL = (item.spawnLength or 6) * 0.5
            local existingRadius = math.sqrt(eHalfW * eHalfW + eHalfL * eHalfL)

            local dx = cx - vx
            local dz = cz - vz
            local distSq = dx * dx + dz * dz
            local minDist = candidateRadius + existingRadius
            if distSq < minDist * minDist then
                return false
            end
        end
    end

    return true
end

-- ---------------------------------------------------------------------------
-- Collision check — overlapBox at the candidate position
-- ---------------------------------------------------------------------------

--- Returns true if the footprint area is free of vehicles and static objects.
function YardInventory:isPositionClear(cx, cz, halfW, halfL, yaw)
    local y = getTerrainHeightAtWorldPos(g_terrainNode, cx, 0, cz) + 2.0
    local buf = YardInventory.VEHICLE_CLEARANCE_BUFFER
    self._overlapFound = false
    -- Expand the check box by the clearance buffer on all sides to account
    -- for getSizeValues underreporting actual vehicle extent. Height of 3m
    -- catches tall equipment (combines, loaders with raised arms).
    overlapBox(
        cx, y, cz,
        0, yaw, 0,
        halfW + buf, 3.0, halfL + buf,
        "onSpawnOverlapCallback", self,
        YardInventory.OVERLAP_COLLISION_MASK,
        true, true, true, true
    )
    return not self._overlapFound
end

--- overlapBox callback — any hit means the position is blocked.
function YardInventory:onSpawnOverlapCallback(hitObjectId)
    self._overlapFound = true
    return false -- stop searching
end

-- ---------------------------------------------------------------------------
-- Vehicle spawning (sequential — one at a time via random scatter placement)
-- ---------------------------------------------------------------------------

--- Generate one item, find a grid position, and load the vehicle. The
--- callback will call spawnNext again in FILL mode.
function YardInventory:spawnNext()
    if not self.filling then return end
    local item = self:generateOneItem()
    if item == nil then
        self.filling = false

        return
    end

    local storeItem = g_storeManager:getItemByXMLFilename(item.xmlFilename)
    if storeItem == nil then
        self:removeItemByRef(item)
        self:spawnNext()
        return
    end

    -- Use the configuration chosen during rollItem (or a fresh one for pending sold items).
    local config = item.configurations or YardInventory.randomConfiguration(storeItem)
    local rotation = storeItem.rotation or 0
    local sizeValues = StoreItemUtil.getSizeValues(storeItem.xmlFilename, "vehicle", rotation, config)
    local width  = sizeValues.width  or 3
    local length = sizeValues.length or 6

    -- Find a valid grid position.
    local halfW = width * 0.5
    local halfL = length * 0.5
    local x, z, yaw = self:findSpawnPoint(width, length)
    if x == nil then
        -- No space for this vehicle — remove it and retry with a different item.
        self:removeItemByRef(item)
        self.placementFailures = self.placementFailures + 1
        if self.placementFailures >= YardInventory.MAX_PLACEMENT_FAILURES then
            self.filling = false
            self.placementFailures = 0
            return
        end
        self:spawnNext()
        return
    end

    -- Placed successfully — reset failure counter.
    self.placementFailures = 0

    -- Store dimensions on the item for grid rebuild after load.
    item.spawnWidth  = width
    item.spawnLength = length
    item.spawnYaw    = yaw

    -- Mark grid points occupied BEFORE async load so the next spawn sees them.
    -- Uses the vehicle's actual dimensions to invalidate covered points.
    self:markGridOccupied(item, x, z, halfW, halfL, yaw)

    -- Build VehicleLoadingData with direct position.
    local data = VehicleLoadingData.new()
    data:setStoreItem(storeItem)
    data:setConfigurations(config)
    data:setPosition(x, nil, z, YardInventory.TERRAIN_OFFSET)
    data:setRotation(0, yaw, 0)
    data:setIgnoreShopOffset(true)
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
        self:freeGridPoints(item)
        self:removeItemByRef(item)
        self:spawnNext()
        return
    end

    local vehicleAccepted = false
    for _, vehicle in ipairs(loadedVehicles) do
        -- Safety check: did the vehicle end up inside the fence polygon?
        local vx, _, vz = getWorldTranslation(vehicle.rootNode)
        if not self.yard:containsPoint(vx, vz) then
            vehicle:delete()
        else
            vehicleAccepted = true
            -- Exclude from ADS before applying condition values — ADS blocks
            -- setOperatingTime unless the vehicle is excluded or ADS itself is writing.
            UsedEquipmentYards.setADSExcluded(vehicle, true)

            -- Apply the item's pre-rolled condition values.
            if vehicle.addWearAmount ~= nil then
                vehicle:addWearAmount(item.wear or 0)
            end
            if vehicle.setDamageAmount ~= nil then
                vehicle:setDamageAmount(item.damage or 0)
            end
            -- Clear the wearable dirty flag so the server doesn't send a
            -- delta update to clients whose i3d nodes aren't loaded yet.
            -- Clients receive the correct initial state via onReadStream.
            if vehicle.spec_wearable ~= nil then
                vehicle:clearDirtyFlags(vehicle.spec_wearable.dirtyFlag)
            end
            vehicle:setOperatingTime(item.operatingTime or 0)

            -- Apply dirt based on yard dirtiness config ± DIRT_RANGE.
            -- NEW quality forces zero dirt; EX_DEMO caps dirt at a light dusting.
            if vehicle.setDirtAmount ~= nil then
                local qualityKey = self.config.quality
                local dirt
                if qualityKey == "NEW" or qualityKey == "EX_DEMO" then
                    dirt = 0
                else
                    local base = self.config.dirtiness or 0.20
                    local range = YardInventory.DIRT_RANGE
                    dirt = base + (math.random() * 2 - 1) * range
                end
                vehicle:setDirtAmount(math.max(0, math.min(1, dirt)))
            end

            -- Limit fuel/energy fill units to ~25% so yard stock isn't full-tank.
            if vehicle.getConsumerFillUnitIndex ~= nil then
                local fuelTypes = {
                    FillType.DIESEL,
                    FillType.ELECTRICCHARGE,
                    FillType.METHANE,
                }
                for _, fillType in ipairs(fuelTypes) do
                    local fillUnitIndex = vehicle:getConsumerFillUnitIndex(fillType)
                    if fillUnitIndex ~= nil then
                        local capacity = vehicle:getFillUnitCapacity(fillUnitIndex)
                        if capacity > 0 then
                            local target = YardInventory.FUEL_BASE
                                         + (math.random() * 2 - 1) * YardInventory.FUEL_RANGE
                            target = math.max(YardInventory.FUEL_MIN, math.min(0.35, target))
                            local desired = capacity * target
                            local current = vehicle:getFillUnitFillLevel(fillUnitIndex)
                            local delta   = desired - current
                            vehicle:addFillUnitFillLevel(vehicle:getOwnerFarmId(), fillUnitIndex, delta, fillType, ToolType.UNDEFINED, nil)
                        end
                    end
                end
            end

            -- Exclude from Tab-cycle so the player can't switch into yard vehicles.
            if vehicle.setIsTabbable ~= nil then
                vehicle:setIsTabbable(false)
            end

            -- Block driving inputs. Stored in spec_drivable.playerControlAllowedFunctions
            -- keyed by NetworkUtil.getObjectId(vehicle). Cleared on purchase via
            -- UsedEquipmentYards.clearVehicleRestrictions().
            if vehicle.registerPlayerVehicleControlAllowedFunction ~= nil then
                vehicle:registerPlayerVehicleControlAllowedFunction(vehicle, function()
                    return false, nil
                end)
            end

            item.vehicle = vehicle
            self.vehicles[#self.vehicles + 1] = vehicle
            UsedEquipmentYards.vehicleToItem[vehicle] = item

            -- If this vehicle has an active test drive (loaded from save),
            -- keep it unlocked for the borrowing farm. Otherwise lock it.
            if item.testDrive ~= nil then
                vehicle:setOwnerFarmId(item.testDrive.farmId)
                UsedEquipmentYards.clearVehicleRestrictions(vehicle)
            else
                PriceTagRenderer.addTag(vehicle, item)
            end

            -- Register purchase activatable so the player can barter this vehicle.
            local activatable = YardVehicleActivatable.new(self.yard, item)
            item.activatable = activatable
            g_currentMission.activatableObjectsSystem:addActivatable(activatable)

            -- Sync item data to remote MP clients so they can interact too.
            local itemIndex = nil
            for idx, itm in ipairs(self.items) do
                if itm == item then itemIndex = idx; break end
            end
            if itemIndex ~= nil then
                g_server:broadcastEvent(VehicleItemSyncEvent.new(self.yard.id, itemIndex, item))
            end
        end
    end

    if not vehicleAccepted then
        -- Post-spawn safety check rejected the vehicle — clean up.
        self:freeGridPoints(item)
        self:removeItemByRef(item)
        self:spawnNext()
    elseif self.spawnMode == YardInventory.SPAWN_FILL then
        self:spawnNext()
    else
        -- SPAWN_SINGLE: one vehicle placed successfully — done.
        self.filling = false

    end
end

--- Remove an item from self.items by reference (no vehicle cleanup — caller
--- already deleted or never had a live vehicle for this item).
function YardInventory:removeItemByRef(item)
    for i, v in ipairs(self.items) do
        if v == item then
            table.remove(self.items, i)
            return
        end
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
-- Eligibility — would this yard buy a given vehicle?
-- ---------------------------------------------------------------------------

--- Check if this yard's config would accept a live vehicle for purchase.
--- Mirrors the filtering logic from buildStorePool but for a single vehicle.
---@param vehicle table  FS25 Vehicle object
---@return boolean
function YardInventory:wouldBuyVehicle(vehicle)
    local si = g_storeManager:getItemByXMLFilename(vehicle.configFileName)
    if si == nil then
        Logging.info("[UEY] wouldBuy: storeItem not found for %s", tostring(vehicle.configFileName))
        return false
    end
    if not si.showInStore or si.extraContentId ~= nil then
        Logging.info("[UEY] wouldBuy: %s not shown in store or is extra content", si.xmlFilename)
        return false
    end
    if si.bundleInfo ~= nil then
        Logging.info("[UEY] wouldBuy: %s is a bundle item, skipping", si.xmlFilename)
        return false
    end
    -- Note: MIN_VEHICLE_PRICE is only used for the spawn pool, not for
    -- accepting sold vehicles. A yard should buy any vehicle that matches
    -- its category/brand/width config regardless of price.
    if not StoreItemUtil.getIsVehicle(si) then
        Logging.info("[UEY] wouldBuy: %s is not a vehicle (species=%s)", si.xmlFilename, tostring(si.species))
        return false
    end

    -- Price check with 15% allowance above maxPrice.
    local cfgMaxPrice = self.config.maxPrice or 0
    if cfgMaxPrice > 0 then
        local allowedMax = cfgMaxPrice * 1.15
        if si.price > allowedMax then
            Logging.info("[UEY] wouldBuy: %s price %d > maxPrice allowance %d", si.xmlFilename, si.price, allowedMax)
            return false
        end
    end

    -- Working width filter.
    local minWW = self.config.minWorkingWidth or 0
    local maxWW = self.config.maxWorkingWidth or 0
    if minWW > 0 or maxWW > 0 then
        pcall(StoreItemUtil.loadSpecsFromXML, si)
        if si.specs ~= nil and si.specs.workingWidth ~= nil then
            local ww = si.specs.workingWidth.width or 0
            if minWW > 0 and ww < minWW then
                Logging.info("[UEY] wouldBuy: %s working width %.1f < min %.1f", si.xmlFilename, ww, minWW)
                return false
            end
            if maxWW > 0 and ww > maxWW then
                Logging.info("[UEY] wouldBuy: %s working width %.1f > max %.1f", si.xmlFilename, ww, maxWW)
                return false
            end
        end
    end

    -- Brand filter.
    local hasBrandFilter = next(self.config.brands) ~= nil
    if hasBrandFilter then
        local brand = g_brandManager:getBrandByIndex(si.brandIndex)
        local brandName = brand ~= nil and brand.name or nil
        if brandName == nil or (self.config.brands[brandName] or 0) == 0 then
            Logging.info("[UEY] wouldBuy: %s brand '%s' rejected by filter", si.xmlFilename, tostring(brandName))
            return false
        end
    end

    -- Category filter: at least one category with weight > 0.
    local catNames = {}
    for _, catName in ipairs(si.categoryNames or {}) do
        catNames[#catNames + 1] = catName
        local catWeight = self.config.categories[catName]
        if catWeight ~= nil and catWeight > 0 then
            return true
        end
    end

    Logging.info("[UEY] wouldBuy: %s categories [%s] not matched in yard config", si.xmlFilename, table.concat(catNames, ", "))
    return false
end

--- Check all yards (server or client) and return the first that would buy the vehicle.
--- Excludes the yard with the given excludeId.
---@return table|nil yard
function YardInventory.wouldAnyYardBuy(vehicle, excludeId)
    -- Server: check via YardManager.
    if UsedEquipmentYards.yardManager ~= nil then
        for _, yard in pairs(UsedEquipmentYards.yardManager.yards) do
            if yard.id ~= excludeId and yard.inventory:wouldBuyVehicle(vehicle) then
                return yard
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Accepting sold vehicles from players
-- ---------------------------------------------------------------------------

--- Create an inventory item from a live vehicle's current state.
--- Prices the vehicle using the same formula as rollItem.
--- If purchasePrice is provided, ensures the listing price is at least 1-2% above it.
function YardInventory:createItemFromVehicle(vehicle, purchasePrice)
    local storeItem = g_storeManager:getItemByXMLFilename(vehicle.configFileName)
    if storeItem == nil then return nil end

    local operatingTime = vehicle.operatingTime or 0
    local damage = vehicle.getDamageAmount ~= nil and vehicle:getDamageAmount() or 0
    local wear = vehicle.getWearTotalAmount ~= nil and vehicle:getWearTotalAmount() or 0
    local age = vehicle.age or 1

    -- Price using the vehicle's actual configured price and the game's formula.
    local configuredPrice = vehicle:getPrice()
    local repairPrice = vehicle.getRepairPrice ~= nil and vehicle:getRepairPrice() or 0
    local repaintPrice = vehicle.getRepaintPrice ~= nil and vehicle:getRepaintPrice() or 0
    local basePrice = configuredPrice
    if Vehicle ~= nil and Vehicle.calculateSellPrice ~= nil then
        basePrice = Vehicle.calculateSellPrice(storeItem, age, operatingTime, configuredPrice, repairPrice, repaintPrice)
    end

    -- Apply the yard's standard price jitter.
    local roll = math.random()
    local isWide = roll >= YardInventory.PRICE_NORMAL_CHANCE
    local spread = YardInventory.getPriceSpread(basePrice, isWide)
    local jitter = 1 + (math.random() * 2 - 1) * spread
    local finalPrice = math.max(1, math.floor(basePrice * jitter))

    -- Ensure the yard lists it for at least 1-2% above what it paid the player.
    if purchasePrice ~= nil and purchasePrice > 0 then
        local minMarkup = 1.01 + math.random() * 0.01  -- 1-2% above purchase price
        local priceFloor = math.floor(purchasePrice * minMarkup)
        if finalPrice < priceFloor then
            finalPrice = priceFloor
        end
    end

    -- Min acceptable barter price (same distribution as rollItem).
    local discountRoll = math.random()
    local maxDiscount
    if discountRoll < 0.70 then
        maxDiscount = 0.05 + math.random() * 0.05
    elseif discountRoll < 0.90 then
        maxDiscount = 0.10 + math.random() * 0.05
    elseif discountRoll < 0.97 then
        maxDiscount = 0.15 + math.random() * 0.05
    else
        maxDiscount = 0.20 + math.random() * 0.10
    end
    local minPrice = math.max(1, math.floor(finalPrice * (1 - maxDiscount)))

    local hours = operatingTime / 3600000
    local numOwners = math.max(1, math.floor(hours / 25) + math.random(-1, 1))

    -- Get vehicle dimensions for grid placement.
    local rotation = storeItem.rotation or 0
    local sizeValues = StoreItemUtil.getSizeValues(storeItem.xmlFilename, "vehicle", rotation, vehicle.configurations or {})

    return {
        xmlFilename    = storeItem.xmlFilename,
        configurations = vehicle.configurations or {},
        price          = finalPrice,
        minPrice       = minPrice,
        numOwners      = numOwners,
        age            = age,
        damage         = damage,
        wear           = wear,
        operatingTime  = operatingTime,
        ttlHours       = self:randomTTL(),
        vehicle        = nil,
        spawnWidth     = sizeValues.width or 3,
        spawnLength    = sizeValues.length or 6,
        spawnYaw       = 0,
    }
end

--- Accept a vehicle sold by a player. Tries to place it in the yard immediately.
--- If no room, hides the vehicle (out of physics, invisible) until space opens.
--- The engine still saves the hidden vehicle normally.
--- purchasePrice = total the yard paid (cash + credit), used as a price floor.
--- Returns the created item (or nil on failure).
function YardInventory:acceptSoldVehicle(vehicle, purchasePrice)
    local item = self:createItemFromVehicle(vehicle, purchasePrice)
    if item == nil then return nil end

    -- Lock the vehicle immediately regardless of placement.
    vehicle:setOwnerFarmId(0)
    if vehicle.setIsTabbable ~= nil then vehicle:setIsTabbable(false) end
    if vehicle.registerPlayerVehicleControlAllowedFunction ~= nil then
        vehicle:registerPlayerVehicleControlAllowedFunction(vehicle, function() return false, nil end)
    end
    UsedEquipmentYards.setADSExcluded(vehicle, true)

    if vehicle.stopMotor ~= nil then
        vehicle:stopMotor()
    end
    if vehicle.deactivateLights ~= nil then
        vehicle:deactivateLights()
    end

    item.vehicle = vehicle
    self.items[#self.items + 1] = item
    UsedEquipmentYards.vehicleToItem[vehicle] = item

    if #self.spawnGrid == 0 then
        self:buildSpawnGrid()
    end

    local x, z, yaw = self:findSpawnPoint(item.spawnWidth, item.spawnLength)
    if x ~= nil then
        -- Space available — teleport and display immediately.
        self:placeVehicleInYard(item, x, z, yaw)
        return item
    end

    -- No room — hide the vehicle until space opens.
    self:hideVehicle(vehicle)
    self.pendingSoldItems[#self.pendingSoldItems + 1] = item
    return item
end

--- Hide a vehicle: remove from physics and move far below terrain.
--- Avoids visibility issues with wheels/components that aren't children
--- of rootNode. The engine still tracks and saves the vehicle.
function YardInventory:hideVehicle(vehicle)
    vehicle:removeFromPhysics()
    vehicle:setAbsolutePosition(0, -200, 0, 0, 0, 0)
end

--- Reveal and place a hidden vehicle at a yard position.
function YardInventory:placeVehicleInYard(item, x, z, yaw)
    local vehicle = item.vehicle
    if vehicle == nil then return end

    item.spawnYaw = yaw
    local halfW = item.spawnWidth * 0.5
    local halfL = item.spawnLength * 0.5
    self:markGridOccupied(item, x, z, halfW, halfL, yaw)

    -- Reset TTL — it may have been ticking down while the vehicle was hidden.
    item.ttlHours = self:randomTTL()

    local terrainY = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
    vehicle:removeFromPhysics()
    vehicle:setAbsolutePosition(x, terrainY + YardInventory.TERRAIN_OFFSET, z, 0, yaw, 0)
    vehicle:addToPhysics()

    -- Add price tag, activatable, sync to MP.
    self.vehicles[#self.vehicles + 1] = vehicle
    PriceTagRenderer.addTag(vehicle, item)
    local activatable = YardVehicleActivatable.new(self.yard, item)
    item.activatable = activatable
    g_currentMission.activatableObjectsSystem:addActivatable(activatable)

    local itemIndex = nil
    for idx, itm in ipairs(self.items) do
        if itm == item then itemIndex = idx; break end
    end
    if itemIndex ~= nil then
        g_server:broadcastEvent(VehicleItemSyncEvent.new(self.yard.id, itemIndex, item))
    end
end

--- Try to place the next hidden pending sold vehicle. Called after a delay
--- when space frees up. The vehicle already exists — just needs a position.
function YardInventory:trySpawnPendingSoldItem()
    if #self.pendingSoldItems == 0 then return end
    if self.filling then return end
    if #self.spawnGrid == 0 then self:buildSpawnGrid() end

    local i = 1
    while i <= #self.pendingSoldItems do
        local item = self.pendingSoldItems[i]

        if item.vehicle == nil then
            -- Vehicle was lost (e.g. deleted externally) — discard.
            table.remove(self.pendingSoldItems, i)
        else
            local x, z, yaw = self:findSpawnPoint(item.spawnWidth, item.spawnLength)
            if x ~= nil then
                table.remove(self.pendingSoldItems, i)
                self:placeVehicleInYard(item, x, z, yaw)
                return -- one at a time
            end
            i = i + 1
        end
    end
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

    -- Free grid points so the space can be reused.
    self:freeGridPoints(item)

    -- Find the item index before removing so we can notify clients.
    local itemIndex = nil
    for i, v in ipairs(self.items) do
        if v == item then
            itemIndex = i
            break
        end
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

    if itemIndex ~= nil then
        table.remove(self.items, itemIndex)
    end

    -- Notify remote clients so they clean up stale item data.
    -- Skip when keepVehicle=true (purchases) — EquipmentPurchasedEvent handles that.
    if not keepVehicle and itemIndex ~= nil and g_server ~= nil then
        g_server:broadcastEvent(VehicleItemRemovedEvent.new(self.yard.id, itemIndex))
    end

    -- Space freed up — schedule pending sold items after a delay so the
    -- deleted vehicle's physics has time to clean up before overlapBox runs.
    if #self.pendingSoldItems > 0 and not self.filling and self.fillDelayMs == nil then
        self.fillDelayMs = 500
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
    setXMLString(xmlFile, key .. ".config#quality", self.config.quality or "MEDIUM")
    setXMLFloat(xmlFile, key .. ".config#dirtiness", self.config.dirtiness or 0.20)
    setXMLInt(xmlFile, key .. ".config#minWorkingWidth", self.config.minWorkingWidth or 0)
    setXMLInt(xmlFile, key .. ".config#maxWorkingWidth", self.config.maxWorkingWidth or 0)
    setXMLInt(xmlFile, key .. ".config#maxPrice", self.config.maxPrice or 0)
    setXMLInt(xmlFile, key .. ".config#avgStockHours", self.config.avgStockHours or YardInventory.DEFAULT_AVG_STOCK_HOURS)
    setXMLInt(xmlFile, key .. ".config#gridSpacing", self.config.gridSpacing or 8)

    local ci = 0
    for catName, weight in pairs(self.config.categories) do
        if weight > 0 then
            local cKey = ("%s.config.category(%d)"):format(key, ci)
            setXMLString(xmlFile, cKey .. "#name", catName)
            setXMLInt(xmlFile, cKey .. "#weight", weight)
            ci = ci + 1
        end
    end

    local bi = 0
    for brandName, weight in pairs(self.config.brands or {}) do
        if weight > 0 then
            local bKey = ("%s.config.brand(%d)"):format(key, bi)
            setXMLString(xmlFile, bKey .. "#name", brandName)
            setXMLInt(xmlFile, bKey .. "#weight", weight)
            bi = bi + 1
        end
    end

    -- Save items.
    for i, item in ipairs(self.items) do
        local iKey = ("%s.item(%d)"):format(key, i - 1)
        setXMLString(xmlFile, iKey .. "#xmlFilename", item.xmlFilename or "")
        setXMLInt(xmlFile, iKey .. "#price", item.price or 0)
        setXMLInt(xmlFile, iKey .. "#age", item.age or 0)
        setXMLFloat(xmlFile, iKey .. "#damage", item.damage or 0)
        setXMLFloat(xmlFile, iKey .. "#wear", item.wear or 0)
        setXMLFloat(xmlFile, iKey .. "#operatingTime", (item.operatingTime or 0) / 1000)
        setXMLInt(xmlFile, iKey .. "#ttlHours", item.ttlHours or YardInventory.DEFAULT_AVG_STOCK_HOURS)
        setXMLInt(xmlFile, iKey .. "#numOwners", item.numOwners or 1)
        setXMLInt(xmlFile, iKey .. "#minPrice", item.minPrice or item.price)
        setXMLFloat(xmlFile, iKey .. "#spawnWidth", item.spawnWidth or 0)
        setXMLFloat(xmlFile, iKey .. "#spawnLength", item.spawnLength or 0)
        setXMLFloat(xmlFile, iKey .. "#spawnYaw", item.spawnYaw or 0)

        -- Mark hidden items (pending sold vehicles waiting for yard space).
        local isHidden = false
        for _, pItem in ipairs(self.pendingSoldItems) do
            if pItem == item then isHidden = true; break end
        end
        if isHidden then
            setXMLBool(xmlFile, iKey .. "#hidden", true)
        end

        -- Save vehicle configurations so the correct config is used if re-spawned.
        if item.configurations ~= nil then
            local cfgIdx = 0
            for cfgName, cfgValue in pairs(item.configurations) do
                local cfgKey = ("%s.vehicleConfig(%d)"):format(iKey, cfgIdx)
                setXMLString(xmlFile, cfgKey .. "#name", cfgName)
                setXMLInt(xmlFile, cfgKey .. "#value", tonumber(cfgValue) or 0)
                cfgIdx = cfgIdx + 1
            end
        end

        -- Save vehicle uniqueId so we can re-associate on load.
        if item.vehicle ~= nil and item.vehicle.uniqueId ~= nil then
            setXMLString(xmlFile, iKey .. "#vehicleUniqueId", item.vehicle.uniqueId)
        end

        -- Test driven history (which farms have already test-driven this item).
        local tdf = item.testDrivenByFarms
        if tdf ~= nil then
            local fi = 0
            for farmId, _ in pairs(tdf) do
                setXMLInt(xmlFile, ("%s.testDrivenByFarm(%d)#farmId"):format(iKey, fi), farmId)
                fi = fi + 1
            end
        end

        -- Test drive state.
        local td = item.testDrive
        if td ~= nil then
            setXMLInt(xmlFile, iKey .. ".testDrive#farmId", td.farmId)
            setXMLInt(xmlFile, iKey .. ".testDrive#returnByDay", td.returnByDay)
            setXMLInt(xmlFile, iKey .. ".testDrive#returnByHour", td.returnByHour)
            setXMLFloat(xmlFile, iKey .. ".testDrive#origX", td.origX)
            setXMLFloat(xmlFile, iKey .. ".testDrive#origY", td.origY)
            setXMLFloat(xmlFile, iKey .. ".testDrive#origZ", td.origZ)
            setXMLFloat(xmlFile, iKey .. ".testDrive#origRx", td.origRx)
            setXMLFloat(xmlFile, iKey .. ".testDrive#origRy", td.origRy)
            setXMLFloat(xmlFile, iKey .. ".testDrive#origRz", td.origRz)
        end
    end

end

function YardInventory:loadFromXML(xmlFile, key)
    -- Load config (fall back to defaults if not present).
    if hasXMLProperty(xmlFile, key .. ".config") then
        self.config = {
            quality    = getXMLString(xmlFile, key .. ".config#quality") or "MEDIUM",
            dirtiness       = getXMLFloat(xmlFile, key .. ".config#dirtiness") or 0.20,
            minWorkingWidth = getXMLInt(xmlFile, key .. ".config#minWorkingWidth") or 0,
            maxWorkingWidth = getXMLInt(xmlFile, key .. ".config#maxWorkingWidth") or 0,
            maxPrice        = getXMLInt(xmlFile, key .. ".config#maxPrice") or 0,
            avgStockHours   = getXMLInt(xmlFile, key .. ".config#avgStockHours") or YardInventory.DEFAULT_AVG_STOCK_HOURS,
            gridSpacing     = getXMLInt(xmlFile, key .. ".config#gridSpacing") or 8,
            categories = {},
            brands     = {},
        }
        local ci = 0
        while true do
            local cKey = ("%s.config.category(%d)"):format(key, ci)
            if not hasXMLProperty(xmlFile, cKey) then break end
            local catName = getXMLString(xmlFile, cKey .. "#name")
            local weight  = getXMLInt(xmlFile, cKey .. "#weight") or 0
            if catName ~= nil then
                self.config.categories[catName] = weight
            end
            ci = ci + 1
        end
        local bi = 0
        while true do
            local bKey = ("%s.config.brand(%d)"):format(key, bi)
            if not hasXMLProperty(xmlFile, bKey) then break end
            local brandName = getXMLString(xmlFile, bKey .. "#name")
            local weight    = getXMLInt(xmlFile, bKey .. "#weight") or 0
            if brandName ~= nil then
                self.config.brands[brandName] = weight
            end
            bi = bi + 1
        end
    end

    -- Load items.
    local i = 0
    while true do
        local iKey = ("%s.item(%d)"):format(key, i)
        if not hasXMLProperty(xmlFile, iKey) then break end
        local item = {
            xmlFilename   = getXMLString(xmlFile, iKey .. "#xmlFilename") or "",
            price         = getXMLInt(xmlFile, iKey .. "#price") or 0,
            age           = getXMLInt(xmlFile, iKey .. "#age") or 0,
            damage        = getXMLFloat(xmlFile, iKey .. "#damage") or 0,
            wear          = getXMLFloat(xmlFile, iKey .. "#wear") or 0,
            operatingTime = (getXMLFloat(xmlFile, iKey .. "#operatingTime") or 0) * 1000,
            ttlHours      = getXMLInt(xmlFile, iKey .. "#ttlHours") or self:randomTTL(),
            numOwners     = getXMLInt(xmlFile, iKey .. "#numOwners") or 1,
            minPrice      = getXMLInt(xmlFile, iKey .. "#minPrice"),
            vehicleUniqueId = getXMLString(xmlFile, iKey .. "#vehicleUniqueId"),
            spawnWidth    = getXMLFloat(xmlFile, iKey .. "#spawnWidth") or 0,
            spawnLength   = getXMLFloat(xmlFile, iKey .. "#spawnLength") or 0,
            spawnYaw      = getXMLFloat(xmlFile, iKey .. "#spawnYaw") or 0,
            vehicle       = nil,
        }
        -- Legacy saves: default minPrice to asking price (no discount).
        if item.minPrice == nil then
            item.minPrice = item.price
        end

        -- Restore vehicle configurations.
        local configs = {}
        local cfgIdx = 0
        while true do
            local cfgKey = ("%s.vehicleConfig(%d)"):format(iKey, cfgIdx)
            if not hasXMLProperty(xmlFile, cfgKey) then break end
            local cfgName  = getXMLString(xmlFile, cfgKey .. "#name")
            local cfgValue = getXMLInt(xmlFile, cfgKey .. "#value")
            if cfgName ~= nil and cfgValue ~= nil then
                configs[cfgName] = cfgValue
            end
            cfgIdx = cfgIdx + 1
        end
        if next(configs) ~= nil then
            item.configurations = configs
        end

        -- Restore test driven history.
        local tdf = {}
        local fi = 0
        while true do
            local fKey = ("%s.testDrivenByFarm(%d)"):format(iKey, fi)
            if not hasXMLProperty(xmlFile, fKey) then break end
            local farmId = getXMLInt(xmlFile, fKey .. "#farmId")
            if farmId ~= nil then
                tdf[farmId] = true
            end
            fi = fi + 1
        end
        if next(tdf) ~= nil then
            item.testDrivenByFarms = tdf
        end

        -- Restore test drive state if present.
        local tdKey = iKey .. ".testDrive"
        if hasXMLProperty(xmlFile, tdKey) then
            item.testDrive = {
                farmId       = getXMLInt(xmlFile, tdKey .. "#farmId") or 0,
                returnByDay  = getXMLInt(xmlFile, tdKey .. "#returnByDay") or 0,
                returnByHour = getXMLInt(xmlFile, tdKey .. "#returnByHour") or 0,
                origX  = getXMLFloat(xmlFile, tdKey .. "#origX") or 0,
                origY  = getXMLFloat(xmlFile, tdKey .. "#origY") or 0,
                origZ  = getXMLFloat(xmlFile, tdKey .. "#origZ") or 0,
                origRx = getXMLFloat(xmlFile, tdKey .. "#origRx") or 0,
                origRy = getXMLFloat(xmlFile, tdKey .. "#origRy") or 0,
                origRz = getXMLFloat(xmlFile, tdKey .. "#origRz") or 0,
            }
        end

        self.items[#self.items + 1] = item

        -- Items marked hidden are pending sold vehicles (invisible, no physics).
        -- They'll be re-associated with their vehicle in spawn() and placed when
        -- space opens. The engine saves the hidden vehicle object normally.
        if getXMLBool(xmlFile, iKey .. "#hidden") then
            item.hidden = true
        end

        i = i + 1
    end

    self.pendingSoldItems = {}
end
