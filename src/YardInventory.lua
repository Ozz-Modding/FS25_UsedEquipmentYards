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
YardInventory.MAX_PLACEMENT_FAILURES = 5 -- consecutive placement failures before giving up

-- Spawn mode constants.
YardInventory.SPAWN_FILL = 1 -- fill yard to capacity (used on reset)
YardInventory.SPAWN_SINGLE = 2 -- spawn one vehicle then stop (used on hourly tick)

-- ---------------------------------------------------------------------------
-- Quality presets — control hours, damage, and wear ranges
-- ---------------------------------------------------------------------------
-- Hours are engine hours (what you see on the dashboard). Age in months is
-- derived from hours for Vehicle.calculateSellPrice (~800 hours/year average).
YardInventory.HOURS_PER_YEAR = 800

YardInventory.QUALITY = {
    LOW = {
        hoursMin = 30,
        hoursMax = 60,
        damageMin = 0.35,
        damageMax = 0.7,
        wearMin = 0.5,
        wearMax = 1.0
    },
    MEDIUM = {
        hoursMin = 17,
        hoursMax = 28,
        damageMin = 0.15,
        damageMax = 0.45,
        wearMin = 0.2,
        wearMax = 0.65
    },
    HIGH = {
        hoursMin = 5,
        hoursMax = 15,
        damageMin = 0.05,
        damageMax = 0.2,
        wearMin = 0.05,
        wearMax = 0.25
    },
    EX_DEMO = {
        hoursMin = 1,
        hoursMax = 4,
        damageMin = 0.0,
        damageMax = 0.05,
        wearMin = 0.0,
        wearMax = 0.10
    },
    NEW = {
        hoursMin = 0.2,
        hoursMax = 1,
        damageMin = 0.0,
        damageMax = 0.0,
        wearMin = 0.0,
        wearMax = 0.0
    }
}

-- ---------------------------------------------------------------------------
-- Default yard configuration — quality tier, category weights, dirtiness, brands
-- ---------------------------------------------------------------------------
-- Categories is a map of { CATEGORY_NAME = weight }. Weight 0 = excluded.
-- Brands is a map of { BRAND_NAME = weight }. Empty table = all brands allowed (weight 1).
YardInventory.DEFAULT_CONFIG = {
    quality = "MEDIUM",
    dirtiness = 0.50, -- base dirt level (0–1)
    categories = {
        TRACTORSS = 10,
        TRACTORSM = 5,
        TRACTORSL = 1,
        TELELOADERVEHICLES = 4,
        WHEELLOADERVEHICLES = 2,
        SKIDSTEERVEHICLES = 2
    },
    brands = {}, -- empty = all brands with weight 1
    minWorkingWidth = 0, -- 0 = no minimum
    maxWorkingWidth = 0, -- 0 = no maximum
    maxPrice = 0, -- 0 = no maximum (hard cap MAX_VEHICLE_PRICE still applies)
    avgStockHours = 96, -- average hours a vehicle stays before TTL expiry
    aisleWidth = 8, -- metres of driving room between facing rows
    maxDuplicates = 2 -- max same vehicle (by xmlFilename) on yard; 0 = unlimited
}

-- Dirt jitter range applied ± around the dirtiness base
YardInventory.DIRT_RANGE = 0.20
YardInventory.FUEL_BASE = 0.15 -- target fuel level
YardInventory.FUEL_RANGE = 0.04 -- ± random variation
YardInventory.FUEL_MIN = 0.11 -- floor: Motorized:onPostLoad charges farmId on < 10%

-- Minimum vehicle new price to be included (filters out tiny items).
YardInventory.MIN_VEHICLE_PRICE = 2000
-- Maximum used price — vehicles priced above this after jitter are re-rolled.
YardInventory.MAX_VEHICLE_PRICE = 999999

-- ---------------------------------------------------------------------------
-- Placement constants (row layout: see YardLayout and the Row layout section)
-- ---------------------------------------------------------------------------
-- Terrain offset (metres) when calling setPosition — lifts the vehicle
-- slightly above the ground to avoid clipping.
YardInventory.TERRAIN_OFFSET = 0.5
-- Collision mask for overlapBox spawn checks. Detects vehicles and
-- static objects (buildings, fences) but not triggers or terrain.
-- DEFAULT(0x1) | DYNAMIC_OBJECT(0x20) | BUILDING(0x40) | VEHICLE(0x10000)
YardInventory.OVERLAP_COLLISION_MASK = 0x10061

-- Price jitter — adds variety around the base sell-price formula.
-- Spread scales inversely with price (sqrt curve). At the reference price (100k):
--   normal band ≈ ±2.5%, wide band ≈ ±3.5%.
-- Cheaper items get wider variance; expensive items tighten up.
YardInventory.PRICE_NORMAL_CHANCE = 0.85
YardInventory.PRICE_REFERENCE = 100000
YardInventory.PRICE_NORMAL_BASE = 0.025 -- ±2.5% at reference price
YardInventory.PRICE_WIDE_BASE = 0.035 -- ±3.5% at reference price
YardInventory.PRICE_SPREAD_MAX = 0.12 -- cap for very cheap items

function YardInventory.getPriceSpread(price, isWide)
    local base = isWide and YardInventory.PRICE_WIDE_BASE or YardInventory.PRICE_NORMAL_BASE
    local scale = math.sqrt(YardInventory.PRICE_REFERENCE / math.max(1, price))
    return math.min(base * scale, YardInventory.PRICE_SPREAD_MAX)
end

-- ---------------------------------------------------------------------------
-- TTL (time to live) — how long a spawned vehicle stays before expiring.
-- ---------------------------------------------------------------------------
-- Derived from config.avgStockHours: uniform random in [avg*0.5, avg*1.5].
YardInventory.DEFAULT_AVG_STOCK_HOURS = 96
-- Probability each in-game hour that a new vehicle is spawned (if space allows).
YardInventory.HOURLY_SPAWN_CHANCE = 0.35

--- Deep-copy a config table so edits don't affect the original.
function YardInventory.copyConfig(cfg)
    local copy = {
        quality = cfg.quality,
        dirtiness = cfg.dirtiness,
        categories = {},
        brands = {},
        minWorkingWidth = cfg.minWorkingWidth or 0,
        maxWorkingWidth = cfg.maxWorkingWidth or 0,
        maxPrice = cfg.maxPrice or 0,
        avgStockHours = cfg.avgStockHours or 96,
        aisleWidth = cfg.aisleWidth or 8,
        maxDuplicates = cfg.maxDuplicates or 2,
        minYear = cfg.minYear or 0,
        maxYear = cfg.maxYear or 0,
        includeNoYear = cfg.includeNoYear ~= false,
        allowHirePurchase = cfg.allowHirePurchase ~= false
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
    local self = setmetatable({}, YardInventory._mt)
    self.yard = yard
    self.config = YardInventory.copyConfig(YardInventory.DEFAULT_CONFIG)
    self.items = {}
    self.vehicles = {} -- spawned Vehicle objects
    self.pendingLoads = {} -- in-flight VehicleLoadingData
    self.plan = nil -- YardLayout plan (server only, built by ensureLayout)
    self.layoutSpec = nil -- { angle, vStart, rowDepths, aisleWidth }: saved so rows stay put across loads
    self.layoutDirty = true -- rebuild the plan before the next placement
    self.filling = false -- true while the fill loop is running
    self.placementFailures = 0 -- consecutive placement failures
    self.spawnMode = YardInventory.SPAWN_FILL
    self.fillDelayMs = nil -- ms to wait before starting fill (physics cleanup)
    -- Data-only items from player sales waiting for yard space. The sold vehicle
    -- is deleted and re-spawned from this data when a spot opens. These items are
    -- NOT in self.items and have no vehicle.
    self.pendingSoldItems = {}
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
    -- Skip vehicles on test drive.
    local i = #self.items
    while i >= 1 do
        local item = self.items[i]
        if item.testDrive == nil and item.ttlHours ~= nil then
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
            local overdue = (env.currentMonotonicDay > td.returnByDay) or
                                (env.currentMonotonicDay == td.returnByDay and env.currentHour >= td.returnByHour)
            if overdue then
                local fine =
                    math.max(TestDriveEvent.FINE_MINIMUM, math.floor(item.price * TestDriveEvent.FINE_PER_HOUR))
                g_currentMission:addMoneyChange(-fine, td.farmId, MoneyType.OTHER, true)
                g_farmManager:getFarmById(td.farmId):changeBalance(-fine, MoneyType.OTHER)
            end
        end
    end

    -- Pending sold items take priority over new random stock.
    if #self.pendingSoldItems > 0 then
        self:schedulePendingSoldSpawn()
        return -- block new stock while pending items exist
    end

    -- Roll for a new spawn if not already in a spawn loop and under the cap.
    -- Skip if we're still restoring saved items.
    if not self.filling and self.fillDelayMs == nil and math.random() < YardInventory.HOURLY_SPAWN_CHANCE then
        self:trySpawnOne()
    end
end

--- Called after mission start. Re-associates saved items with game-restored
--- vehicles by uniqueId. New yards start empty — inventory builds via hourly ticks.
function YardInventory:spawn()
    -- Legacy saves: pending sold items used to keep their real vehicle hidden
    -- (server-side only, which left it visible to MP clients). Delete those
    -- vehicles — the pending item re-spawns from data when space opens.
    for _, pItem in ipairs(self.pendingSoldItems) do
        if pItem.legacyVehicleUniqueId ~= nil then
            local legacyVehicle = g_currentMission.vehicleSystem:getVehicleByUniqueId(pItem.legacyVehicleUniqueId)
            if legacyVehicle ~= nil then
                legacyVehicle:delete()
            end
            pItem.legacyVehicleUniqueId = nil
        end
    end

    if #self.items == 0 then
        if #self.pendingSoldItems > 0 then
            self.fillDelayMs = 500 -- let deleted legacy vehicles leave physics first
        end
        return
    end

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
            item.vehicleUniqueId = nil -- no longer needed
            UsedEquipmentYards.vehicleToItem[vehicle] = item

            self.vehicles[#self.vehicles + 1] = vehicle

            -- Re-apply yard vehicle state.
            if item.testDrive ~= nil then
                UsedEquipmentYards.clearVehicleRestrictions(vehicle)
            else
                -- Lock the vehicle and add price tag.
                if vehicle.setIsTabbable ~= nil then
                    vehicle:setIsTabbable(false)
                end
                if vehicle.registerPlayerVehicleControlAllowedFunction ~= nil then
                    vehicle:registerPlayerVehicleControlAllowedFunction(vehicle, function()
                        return false, nil
                    end)
                end
                UsedEquipmentYards.setADSExcluded(vehicle, true)
                PriceTagRenderer.addTag(vehicle, item)
            end

            -- Register activatable.
            local activatable = YardVehicleActivatable.new(self.yard, item)
            item.activatable = activatable
            g_currentMission.activatableObjectsSystem:addActivatable(activatable)

            -- Sync to remote MP clients.
            g_server:broadcastEvent(VehicleItemSyncEvent.new(self.yard.id, item))

            associated = associated + 1
        else
            -- Vehicle not found — remove orphaned item.
            table.remove(self.items, i)
            orphaned = orphaned + 1
        end
        i = i - 1
    end

    -- Build the row plan and fit the loaded vehicles to it: vehicles still in
    -- a row position stay, the rest (older saves, a changed model list) are
    -- moved or evicted.
    self.layoutDirty = true
    self:ensureLayout()

    -- Place any pending sold items that were queued before the save. Delayed
    -- so deleted legacy hidden vehicles have left physics before overlapBox runs.
    if #self.pendingSoldItems > 0 and self.fillDelayMs == nil then
        self.fillDelayMs = 500
    end
end

--- Attempt to spawn a single vehicle (hourly tick).
function YardInventory:trySpawnOne()
    self.spawnMode = YardInventory.SPAWN_SINGLE
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
        item.slot = nil
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
    self.layoutDirty = true
    self.spawnMode = YardInventory.SPAWN_FILL
    self.filling = true
    self.fillDelayMs = 500 -- wait for physics engine to clean up deleted vehicles
end

--- Tick down the fill delay and start spawning when ready.
--- Called from the main update loop via YardManager.
function YardInventory:update(dt)
    -- Config changed since the plan was built: rebuild now (only yards that
    -- already have a plan — new ones build it on first placement).
    if self.layoutDirty and self.plan ~= nil and not self.filling and #self.pendingLoads == 0 then
        self:ensureLayout()
    end

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
--- The yard's rows are rebuilt for the new model list (server: on the next
--- update tick; vehicles that no longer fit are evicted as if sold).
function YardInventory:applyConfig(newConfig)
    self.config = YardInventory.copyConfig(newConfig)
    self.storePool = nil -- force rebuild with new categories on next spawn
    self.layoutDirty = true
end

-- ---------------------------------------------------------------------------
-- Item generation
-- ---------------------------------------------------------------------------

--- Generate a single random item using the yard's config and quality preset.
--- Uses the same pricing formula as the base game's VehicleSaleSystem.
--- Re-rolls (up to MAX_REROLLS times) if the final price exceeds MAX_VEHICLE_PRICE.
local MAX_REROLLS = 5

--- filter(storeItem) -> bool, optional: only models it accepts are rolled.
function YardInventory:generateOneItem(filter)
    if self.storePool == nil then
        self.storePool = self:buildStorePool()
    end
    if #self.storePool == 0 then
        return nil
    end

    for _ = 1, MAX_REROLLS do
        local item = self:rollItem(filter)
        if item ~= nil and item.price <= YardInventory.MAX_VEHICLE_PRICE and
            not self:isDuplicateLimitReached(item.xmlFilename) then
            self.items[#self.items + 1] = item
            return item
        end
    end

    return nil
end

--- Roll a single candidate item (not yet added to self.items).
function YardInventory:rollItem(filter)
    -- Weighted random selection from the pool.
    local storeItem = self:pickWeightedItem(filter)
    if storeItem == nil then
        return nil
    end

    -- Roll hours, damage, wear from the quality preset.
    local q = YardInventory.QUALITY[self.config.quality] or YardInventory.QUALITY.MEDIUM
    local hours = q.hoursMin + math.random() * (q.hoursMax - q.hoursMin)
    local damage = q.damageMin + math.random() * (q.damageMax - q.damageMin)
    local wear = q.wearMin + math.random() * (q.wearMax - q.wearMin)
    local operatingTime = hours * 60 * 60 * 1000 -- hours → ms
    -- Derive age in months from hours for the price formula.
    local age = math.max(1, math.floor(hours / YardInventory.HOURS_PER_YEAR * 12))

    -- Pick a random configuration set (like VehicleSaleSystem does).
    local configs = YardInventory.randomConfiguration(storeItem)

    -- Use the game's own pricing with the chosen configuration's price.
    local configuredPrice = StoreItemUtil.getDefaultPrice(storeItem, configs)
    local repairPrice = 0
    local repaintPrice = 0
    if Wearable ~= nil then
        repairPrice = Wearable.calculateRepairPrice(configuredPrice, damage)
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
        maxDiscount = 0.05 + math.random() * 0.05 -- 5–10% off
    elseif discountRoll < 0.90 then
        maxDiscount = 0.10 + math.random() * 0.05 -- 10–15% off
    elseif discountRoll < 0.97 then
        maxDiscount = 0.15 + math.random() * 0.05 -- 15–20% off
    else
        maxDiscount = 0.20 + math.random() * 0.10 -- 20–30% off (rare)
    end
    local minAcceptablePrice = math.max(1, math.floor(finalPrice * (1 - maxDiscount)))

    return {
        xmlFilename = storeItem.xmlFilename,
        configurations = configs,
        price = finalPrice,
        minPrice = minAcceptablePrice,
        numOwners = numOwners,
        age = age,
        damage = damage,
        wear = wear,
        operatingTime = operatingTime,
        ttlHours = self:randomTTL(),
        vehicle = nil
    }
end

--- Check if the yard already has the maximum allowed duplicates of a given vehicle.
---@param xmlFilename string
---@return boolean
function YardInventory:isDuplicateLimitReached(xmlFilename)
    local maxDups = self.config.maxDuplicates or 2
    if maxDups == 0 then
        return false
    end -- unlimited

    local count = 0
    for _, existingItem in ipairs(self.items) do
        if existingItem.xmlFilename == xmlFilename then
            count = count + 1
            if count >= maxDups then
                return true
            end
        end
    end
    return false
end

--- Build a weighted pool of { storeItem, weight } entries from the config.
--- Weight = category weight * brand weight. Brand weight defaults to 1 if
--- the brands table is empty (no brand filter configured).
--- Returns the pool and its total weight.
function YardInventory.buildStorePoolForConfig(config)
    local cats = config.categories -- map: CATEGORY_NAME = weight
    local brands = config.brands -- map: BRAND_NAME = weight (empty = all)
    local hasBrandFilter = next(brands) ~= nil
    local minWW = config.minWorkingWidth or 0
    local maxWW = config.maxWorkingWidth or 0

    local pool = {} -- { storeItem, weight }
    local totalWeight = 0

    local cfgMaxPrice = config.maxPrice or 0
    local effectiveMaxPrice = cfgMaxPrice > 0 and math.min(cfgMaxPrice, YardInventory.MAX_VEHICLE_PRICE) or
                                  YardInventory.MAX_VEHICLE_PRICE

    local minYear = config.minYear or 0
    local maxYear = config.maxYear or 0
    local includeNoYear = config.includeNoYear ~= false
    local hasYearFilter = minYear > 0 or maxYear > 0

    for _, si in pairs(g_storeManager:getItems()) do
        if si.showInStore and si.extraContentId == nil and si.bundleInfo == nil and si.price >=
            YardInventory.MIN_VEHICLE_PRICE and si.price <= effectiveMaxPrice and StoreItemUtil.getIsVehicle(si) then
            -- Working width filter: only applies to items that HAVE a working width spec.
            local passesWW = true
            UeyUtils.loadStoreItemSpecs(si)
            if si.specs ~= nil and si.specs.workingWidth ~= nil then
                local ww = si.specs.workingWidth.width or 0
                if minWW > 0 and ww < minWW then
                    passesWW = false
                end
                if maxWW > 0 and ww > maxWW then
                    passesWW = false
                end
            end

            -- Year filter (Vehicle Years mod integration).
            local passesYear = true
            if hasYearFilter then
                local year = si.specs ~= nil and tonumber(si.specs.year) or nil
                if year == nil then
                    passesYear = includeNoYear
                else
                    if minYear > 0 and year < minYear then
                        passesYear = false
                    end
                    if maxYear > 0 and year > maxYear then
                        passesYear = false
                    end
                end
            end

            if passesWW and passesYear then
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
                            pool[#pool + 1] = {
                                storeItem = si,
                                weight = w
                            }
                            totalWeight = totalWeight + w
                            break
                        end
                    end
                end
            end
        end
    end

    return pool, totalWeight
end

--- This yard's store pool (also sets self.poolTotalWeight).
function YardInventory:buildStorePool()
    local pool, totalWeight = YardInventory.buildStorePoolForConfig(self.config)
    self.poolTotalWeight = totalWeight
    return pool
end

--- Weighted random pick from the store pool, among entries filter accepts
--- (all when filter is nil).
function YardInventory:pickWeightedItem(filter)
    if #self.storePool == 0 or self.poolTotalWeight <= 0 then
        return nil
    end

    local candidates, total = self.storePool, self.poolTotalWeight
    if filter ~= nil then
        candidates, total = {}, 0
        for _, entry in ipairs(self.storePool) do
            if filter(entry.storeItem) then
                candidates[#candidates + 1] = entry
                total = total + entry.weight
            end
        end
        if #candidates == 0 or total <= 0 then
            return nil
        end
    end

    local roll = math.random() * total
    local acc = 0
    for _, entry in ipairs(candidates) do
        acc = acc + entry.weight
        if roll <= acc then
            return entry.storeItem
        end
    end
    -- Fallback (rounding edge case).
    return candidates[#candidates].storeItem
end

-- ---------------------------------------------------------------------------
-- Row layout — vehicles parked in rows facing aisles (see YardLayout)
-- ---------------------------------------------------------------------------
--
-- The plan (rows and their depths) is built from the yard polygon and the
-- sizes of the models the yard's config can spawn, so a trailers-only yard
-- gets deep rows and a tractor yard shallow ones. It is rebuilt when the
-- config changes, the yard is reset, or the game loads; a saved spec keeps
-- the same rows across loads unless the ideal depths have moved by more than
-- YardLayout.DEFAULTS.depthHysteresis (e.g. a mod with long trailers added).
--
-- Each placed item records where its footprint is (footX/footZ/spawnYaw +
-- spawnWidth/Length) and its occupancy in the plan (item.slot = {row, u1, u2}).
-- After a rebuild, reconcileLayout keeps vehicles that still sit in a row
-- position, moves the rest into free positions, and evicts any that don't
-- fit (removed at the next hourly tick, as if sold).

-- Clearance added around a footprint for the overlapBox spawn check (m).
YardInventory.SLOT_CHECK_BUFFER = 0.3
-- Fallback model when the store pool is empty (keeps existing stock placeable).
YardInventory.FALLBACK_MODEL = { length = 6, width = 3, weight = 1 }

-- Size values per store item xmlFilename (default configuration), for the
-- whole session — getSizeValues loads the vehicle XML.
YardInventory.sizeCache = {}

--- Size of a model: { width, length, widthOffset, lengthOffset }. With
--- configurations it's measured for those (not cached), else cached.
function YardInventory.getModelSize(storeItem, configurations)
    local key = storeItem.xmlFilename
    if configurations == nil and YardInventory.sizeCache[key] ~= nil then
        return YardInventory.sizeCache[key]
    end
    local size = StoreItemUtil.getSizeValues(storeItem.xmlFilename, "vehicle", storeItem.rotation or 0,
        configurations or {})
    local result = {
        width = UeyUtils.toNumber(size.width, 3),
        length = UeyUtils.toNumber(size.length, 6),
        widthOffset = UeyUtils.toNumber(size.widthOffset, 0),
        lengthOffset = UeyUtils.toNumber(size.lengthOffset, 0)
    }
    if configurations == nil then
        YardInventory.sizeCache[key] = result
    end
    return result
end

--- Copy a measured size onto an item.
local function setItemSize(item, size)
    item.spawnWidth = size.width
    item.spawnLength = size.length
    item.spawnWidthOffset = size.widthOffset
    item.spawnLengthOffset = size.lengthOffset
end

--- Make sure an item knows its size and offsets (legacy saves lack offsets).
function YardInventory:ensureItemSize(item)
    if (item.spawnWidth or 0) > 0 and (item.spawnLength or 0) > 0 and item.spawnWidthOffset ~= nil and
        item.spawnLengthOffset ~= nil then
        return
    end
    local storeItem = g_storeManager:getItemByXMLFilename(item.xmlFilename)
    if storeItem ~= nil then
        setItemSize(item, YardInventory.getModelSize(storeItem, item.configurations))
    else
        setItemSize(item, {
            width = (item.spawnWidth or 0) > 0 and item.spawnWidth or 3,
            length = (item.spawnLength or 0) > 0 and item.spawnLength or 6,
            widthOffset = 0,
            lengthOffset = 0
        })
    end
end

function YardInventory:getLayoutOptions()
    return {
        aisleWidth = self.config.aisleWidth or YardInventory.DEFAULT_CONFIG.aisleWidth
    }
end

--- The yard polygon, or its AABB as a polygon for legacy yards without one.
function YardInventory:getLayoutPolygon()
    local b = self.yard.bounds
    if b.polygon ~= nil and #b.polygon >= 3 then
        return b.polygon
    end
    local hx, hz = (b.sizeX or 10) * 0.5, (b.sizeZ or 10) * 0.5
    return {
        { x = b.cx - hx, z = b.cz - hz }, { x = b.cx + hx, z = b.cz - hz },
        { x = b.cx + hx, z = b.cz + hz }, { x = b.cx - hx, z = b.cz + hz }
    }
end

--- The models the yard can spawn, with their sizes and spawn weights.
function YardInventory:getLayoutModels()
    if self.storePool == nil then
        self.storePool = self:buildStorePool()
    end
    return YardInventory.layoutModelsOfPool(self.storePool)
end

--- Layout models for any config (the yard tool's preview, on any machine).
function YardInventory.getLayoutModelsForConfig(config)
    return YardInventory.layoutModelsOfPool((YardInventory.buildStorePoolForConfig(config)))
end

--- { length, width, weight, xmlFilename } per pool entry (a fallback model
--- when the pool is empty, so existing stock can still be placed).
function YardInventory.layoutModelsOfPool(pool)
    local models = {}
    for _, entry in ipairs(pool) do
        local size = YardInventory.getModelSize(entry.storeItem)
        models[#models + 1] = {
            length = size.length,
            width = size.width,
            weight = entry.weight,
            xmlFilename = entry.storeItem.xmlFilename
        }
    end
    if #models == 0 then
        models[1] = YardInventory.FALLBACK_MODEL
    end
    return models
end

--- Build (or rebuild, when dirty) the row plan and fit existing stock to it.
--- Server only. Returns the plan (nil for a degenerate yard).
function YardInventory:ensureLayout()
    if self.plan ~= nil and not self.layoutDirty then
        return self.plan
    end
    self.layoutDirty = false

    local polygon = self:getLayoutPolygon()
    local models = self:getLayoutModels()
    local options = self:getLayoutOptions()
    local plan = YardLayout.plan(polygon, models, options)

    local spec = self.layoutSpec
    if plan ~= nil and spec ~= nil and spec.aisleWidth == options.aisleWidth and
        YardLayout.isSpecCompatible(spec, plan, options) then
        plan = YardLayout.buildFromSpec(polygon, spec, models, options)
    end

    -- A plan with no rows would evict everything; keep the old one instead.
    if (plan == nil or #plan.rows == 0) and self.plan ~= nil then
        Logging.warning("[UsedEquipmentYards] yard '%s': no rows fit the new layout — keeping the current one",
            tostring(self.yard.name))
        return self.plan
    end

    self.plan = plan
    self.layoutModels = models
    if plan == nil then
        return nil
    end
    self.layoutSpec = {
        angle = plan.angle,
        vStart = plan.vStart,
        rowDepths = plan.rowDepths,
        aisleWidth = options.aisleWidth
    }

    local excludedCount = 0
    for _ in pairs(plan.excluded) do
        excludedCount = excludedCount + 1
    end
    Logging.info("[UsedEquipmentYards] yard '%s': %d row(s) (%s), ~%d vehicles, %d model(s) too large",
        tostring(self.yard.name), #plan.rows, self:describeRows(), YardLayout.estimateCapacity(plan, models, options),
        excludedCount)

    self:reconcileLayout()
    return plan
end

--- The yard's outline changed: lay it out afresh (the old rows and saved
--- spec no longer apply, even if no rows fit any more) and fit the stock to it.
function YardInventory:onBoundsChanged()
    self.plan = nil
    self.layoutSpec = nil
    self.layoutDirty = true
    self:ensureLayout()
    if self.plan == nil or #self.plan.rows == 0 then
        -- Nothing fits: every vehicle goes, as if sold.
        for _, item in ipairs(self.items) do
            if item.testDrive == nil then
                item.slot = nil
                item.evicting = true
                item.ttlHours = math.min(item.ttlHours or 1, 1)
            end
        end
    end
end

--- "2 x 6.5 m, 1 x 14.5 m" for logs and the yard list.
function YardInventory:describeRows()
    if self.plan == nil then
        return "none"
    end
    local counts, depths = {}, {}
    for _, row in ipairs(self.plan.rows) do
        if counts[row.depth] == nil then
            depths[#depths + 1] = row.depth
        end
        counts[row.depth] = (counts[row.depth] or 0) + 1
    end
    table.sort(depths)
    local parts = {}
    for _, depth in ipairs(depths) do
        parts[#parts + 1] = ("%d x %.1f m"):format(counts[depth], depth)
    end
    return table.concat(parts, ", ")
end

--- Occupancy of the current plan: every item holding a slot.
function YardInventory:getOccupied()
    local occupied = {}
    for _, item in ipairs(self.items) do
        if item.slot ~= nil then
            occupied[#occupied + 1] = item.slot
        end
    end
    return occupied
end

--- Record that an item is placed in a slot.
function YardInventory:assignSlot(item, slot)
    item.slot = { row = slot.row, u1 = slot.u1, u2 = slot.u2 }
    item.footX, item.footZ, item.spawnYaw = slot.x, slot.z, slot.yaw
    item.evicting = nil
end

--- Where an item's vehicle root goes for its footprint to sit in its slot.
function YardInventory:getRootPose(item)
    local rx, rz = YardLayout.rootFromCenter(item.footX, item.footZ, item.spawnYaw, item.spawnWidthOffset,
        item.spawnLengthOffset)
    return rx, rz, item.spawnYaw
end

--- Find a free slot for a footprint. `ignore` = { [vehicle] = true } for
--- vehicles the collision check should not count (they're about to move).
function YardInventory:findSlotFor(width, length, occupied, ignore)
    local plan = self:ensureLayout()
    if plan == nil then
        return nil
    end
    self.overlapIgnore = ignore
    local slot = YardLayout.findSlot(plan, occupied or self:getOccupied(), width, length, function(candidate)
        return self:isSlotClear(candidate)
    end, self:getLayoutOptions())
    self.overlapIgnore = nil
    return slot
end

--- Fit existing stock to the current plan: keep what sits in a row position,
--- move the rest into free positions, evict what doesn't fit.
function YardInventory:reconcileLayout()
    local plan = self.plan
    if plan == nil then
        return
    end
    local options = self:getLayoutOptions()

    local occupied = {}
    local toPlace = {}
    for _, item in ipairs(self.items) do
        item.slot = nil
        self:ensureItemSize(item)
        local occ = nil
        if item.footX ~= nil and item.footZ ~= nil then
            occ = YardLayout.matchFootprint(plan, occupied, item.footX, item.footZ, item.spawnYaw or 0,
                item.spawnWidth, item.spawnLength, options)
        end
        if occ ~= nil then
            item.slot = occ
            item.evicting = nil
            occupied[#occupied + 1] = occ
        elseif item.vehicle ~= nil or item.testDrive ~= nil then
            toPlace[#toPlace + 1] = item
        end
    end
    if #toPlace == 0 then
        return
    end

    -- Biggest first, so the deep rows go to what needs them.
    table.sort(toPlace, function(a, b)
        return a.spawnLength * a.spawnWidth > b.spawnLength * b.spawnWidth
    end)

    -- The collision check ignores the vehicles being moved: they're leaving
    -- their old spots.
    local ignore = {}
    for _, item in ipairs(toPlace) do
        if item.vehicle ~= nil then
            ignore[item.vehicle] = true
        end
    end

    local moves, evicted = {}, {}
    for _, item in ipairs(toPlace) do
        local slot = self:findSlotFor(item.spawnWidth, item.spawnLength, occupied, ignore)
        if slot ~= nil then
            occupied[#occupied + 1] = { row = slot.row, u1 = slot.u1, u2 = slot.u2 }
            moves[#moves + 1] = { item = item, slot = slot }
        else
            evicted[#evicted + 1] = item
        end
    end

    -- Evicted vehicles stay put until the next hourly tick removes them —
    -- unless one stands where a moved vehicle is going, then it goes now.
    for _, item in ipairs(evicted) do
        if item.testDrive == nil and item.vehicle ~= nil then
            local vx, _, vz = getWorldTranslation(item.vehicle.rootNode)
            local radius = math.sqrt(item.spawnWidth ^ 2 + item.spawnLength ^ 2) * 0.5
            local blocking = false
            for _, move in ipairs(moves) do
                local slotRadius = math.sqrt(move.slot.width ^ 2 + move.slot.length ^ 2) * 0.5
                local dx, dz = vx - move.slot.x, vz - move.slot.z
                if dx * dx + dz * dz < (radius + slotRadius) ^ 2 then
                    blocking = true
                    break
                end
            end
            if blocking then
                self:removeItem(item)
            else
                item.evicting = true
                item.ttlHours = math.min(item.ttlHours or 1, 1)
            end
        end
    end

    -- Move: all out of physics first so none collide mid-shuffle.
    for _, move in ipairs(moves) do
        if move.item.testDrive == nil and move.item.vehicle ~= nil then
            move.item.vehicle:removeFromPhysics()
        end
    end
    for _, move in ipairs(moves) do
        local item = move.item
        self:assignSlot(item, move.slot)
        local rx, rz, yaw = self:getRootPose(item)
        local y = getTerrainHeightAtWorldPos(g_terrainNode, rx, 0, rz) + YardInventory.TERRAIN_OFFSET
        if item.testDrive ~= nil then
            -- Out on a test drive: it comes back to its new spot.
            local td = item.testDrive
            td.origX, td.origY, td.origZ = rx, y, rz
            td.origRx, td.origRy, td.origRz = 0, yaw, 0
            if item.vehicle ~= nil then
                g_server:broadcastEvent(VehicleItemSyncEvent.new(self.yard.id, item))
            end
        elseif item.vehicle ~= nil then
            item.vehicle:setAbsolutePosition(rx, y, rz, 0, yaw, 0)
        end
    end
    for _, move in ipairs(moves) do
        if move.item.testDrive == nil and move.item.vehicle ~= nil then
            move.item.vehicle:addToPhysics()
        end
    end

    Logging.info("[UsedEquipmentYards] yard '%s': rearranged %d vehicle(s), %d no longer fit",
        tostring(self.yard.name), #moves, #evicted)
end

-- ---------------------------------------------------------------------------
-- Collision check — overlapBox at the candidate position
-- ---------------------------------------------------------------------------

--- True if a slot's footprint is free of vehicles and static objects.
function YardInventory:isSlotClear(slot)
    local y = getTerrainHeightAtWorldPos(g_terrainNode, slot.x, 0, slot.z) + 2.0
    local buf = YardInventory.SLOT_CHECK_BUFFER
    self._overlapFound = false
    -- Height of 3m catches tall equipment (combines, loaders with raised arms).
    overlapBox(slot.x, y, slot.z, 0, slot.yaw, 0, slot.width * 0.5 + buf, 3.0, slot.length * 0.5 + buf,
        "onSpawnOverlapCallback", self, YardInventory.OVERLAP_COLLISION_MASK, true, true, true, true)
    return not self._overlapFound
end

--- overlapBox callback — any hit means the position is blocked, except
--- vehicles in self.overlapIgnore.
function YardInventory:onSpawnOverlapCallback(hitObjectId)
    if self.overlapIgnore ~= nil then
        local object = g_currentMission:getNodeObject(hitObjectId)
        if object ~= nil and self.overlapIgnore[object] then
            return true -- keep searching
        end
    end
    self._overlapFound = true
    return false -- stop searching
end

-- ---------------------------------------------------------------------------
-- Vehicle spawning (sequential — one at a time into row slots)
-- ---------------------------------------------------------------------------

--- Generate one item, find a slot, and load the vehicle. The callback will
--- call spawnNext again in FILL mode. Only models that fit a free slot right
--- now are rolled, so a nearly full yard fills its gaps with smaller stock.
function YardInventory:spawnNext()
    if not self.filling then
        return
    end
    local plan = self:ensureLayout()
    if plan == nil then
        self.filling = false
        return
    end
    local options = self:getLayoutOptions()
    local free = YardLayout.freeSpace(plan, self:getOccupied(), options)
    local item = self:generateOneItem(function(storeItem)
        local size = YardInventory.getModelSize(storeItem)
        return YardLayout.fitsFreeSpace(free, size.width, size.length, options)
    end)
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

    -- Use the configuration chosen during rollItem (or a fresh one if missing).
    local config = item.configurations or YardInventory.randomConfiguration(storeItem)
    setItemSize(item, YardInventory.getModelSize(storeItem, config))

    local slot = self:findSlotFor(item.spawnWidth, item.spawnLength)
    if slot == nil then
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

    -- Claim the slot BEFORE the async load so the next spawn sees it.
    self:assignSlot(item, slot)
    self:loadItemVehicle(item, storeItem, config, false)
end

--- Start the async load of an item's vehicle at its slot (assignSlot first).
--- isPendingSold = true for items re-spawned from a player sale (not part of
--- the fill loop — the callback must not chain spawnNext).
function YardInventory:loadItemVehicle(item, storeItem, config, isPendingSold)
    local x, z, yaw = self:getRootPose(item)

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
    data:load(self.onVehicleLoaded, self, {
        item = item,
        loadingData = data,
        isPendingSold = isPendingSold
    })
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
        item.slot = nil
        self:removeItemByRef(item)
        if args.isPendingSold then
            Logging.warning("[UsedEquipmentYards] Failed to re-spawn sold vehicle '%s' in yard '%s'",
                tostring(item.xmlFilename), tostring(self.yard.name))
            self:schedulePendingSoldSpawn()
        else
            self:spawnNext()
        end
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
                local fuelTypes = {FillType.DIESEL, FillType.ELECTRICCHARGE, FillType.METHANE}
                for _, fillType in ipairs(fuelTypes) do
                    local fillUnitIndex = vehicle:getConsumerFillUnitIndex(fillType)
                    if fillUnitIndex ~= nil then
                        local capacity = vehicle:getFillUnitCapacity(fillUnitIndex)
                        if capacity > 0 then
                            local target = YardInventory.FUEL_BASE + (math.random() * 2 - 1) * YardInventory.FUEL_RANGE
                            target = math.max(YardInventory.FUEL_MIN, math.min(0.35, target))
                            local desired = capacity * target
                            local current = vehicle:getFillUnitFillLevel(fillUnitIndex)
                            local delta = desired - current
                            vehicle:addFillUnitFillLevel(vehicle:getOwnerFarmId(), fillUnitIndex, delta, fillType,
                                ToolType.UNDEFINED, nil)
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
                UsedEquipmentYards.clearVehicleRestrictions(vehicle)
            else
                PriceTagRenderer.addTag(vehicle, item)
            end

            -- Register purchase activatable so the player can barter this vehicle.
            local activatable = YardVehicleActivatable.new(self.yard, item)
            item.activatable = activatable
            g_currentMission.activatableObjectsSystem:addActivatable(activatable)

            -- Sync item data to remote MP clients so they can interact too.
            g_server:broadcastEvent(VehicleItemSyncEvent.new(self.yard.id, item))
        end
    end

    if args.isPendingSold then
        -- Re-spawned sold vehicle — not part of the fill loop. Queue the next one.
        if not vehicleAccepted then
            item.slot = nil
            self:removeItemByRef(item)
        end
        self:schedulePendingSoldSpawn()
    elseif not vehicleAccepted then
        -- Post-spawn safety check rejected the vehicle — clean up.
        item.slot = nil
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
    UeyUtils.loadStoreItemSpecs(storeItem)

    if storeItem.defaultConfigurationIds ~= nil then
        for k, v in pairs(storeItem.defaultConfigurationIds) do
            result[k] = v
        end
    end

    local neverRandomize = {
        color = true,
        rimColor = true,
        baseColor = true,
        designColor = true,
        designColor2 = true,
        designColor3 = true,
        designColor4 = true,
        designColor5 = true,
        designColor6 = true
    }

    -- Start from a random configuration set if available.
    if storeItem.configurations ~= nil and storeItem.configurationSets ~= nil then
        local numSets = #storeItem.configurationSets
        if numSets > 0 then
            local chosen = math.random(1, numSets)
            local setConfigs = storeItem.configurationSets[chosen].configurations
            if setConfigs ~= nil then
                for k, v in pairs(setConfigs) do
                    if not neverRandomize[k] then
                        result[k] = v
                    end
                end
            end
        end
    end
    -- Configs that should only rarely differ from default (25% chance).
    local conservativeConfigs = {
        wheel = true
    }

    -- Randomly pick any selectable option for configs not covered by a set.
    if storeItem.configurations ~= nil then
        local configSets = storeItem.configurationSets or {}
        for cfgName, cfgItems in pairs(storeItem.configurations) do
            if #cfgItems > 1 and not neverRandomize[cfgName] then
                local coveredBySet = false
                for _, set in ipairs(configSets) do
                    if set.configurations[cfgName] ~= nil then
                        coveredBySet = true
                        break
                    end
                end
                if not coveredBySet then
                    local shouldRandomize = true
                    if conservativeConfigs[cfgName] then
                        shouldRandomize = math.random() < 0.25
                    end
                    if shouldRandomize then
                        local selectable = {}
                        for i = 1, #cfgItems do
                            if cfgItems[i].isSelectable then
                                selectable[#selectable + 1] = i
                            end
                        end
                        if #selectable > 0 then
                            result[cfgName] = selectable[math.random(1, #selectable)]
                        end
                    end
                end
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
        return false
    end
    if not si.showInStore or si.extraContentId ~= nil then
        return false
    end
    if si.bundleInfo ~= nil then
        return false
    end
    -- Note: MIN_VEHICLE_PRICE is only used for the spawn pool, not for
    -- accepting sold vehicles. A yard should buy any vehicle that matches
    -- its category/brand/width config regardless of price.
    if not StoreItemUtil.getIsVehicle(si) then
        return false
    end

    -- Price check with 15% allowance above maxPrice.
    local cfgMaxPrice = self.config.maxPrice or 0
    if cfgMaxPrice > 0 then
        local allowedMax = cfgMaxPrice * 1.15
        if si.price > allowedMax then
            return false
        end
    end

    -- Working width filter.
    local minWW = self.config.minWorkingWidth or 0
    local maxWW = self.config.maxWorkingWidth or 0
    if minWW > 0 or maxWW > 0 then
        UeyUtils.loadStoreItemSpecs(si)
        if si.specs ~= nil and si.specs.workingWidth ~= nil then
            local ww = si.specs.workingWidth.width or 0
            if minWW > 0 and ww < minWW then
                return false
            end
            if maxWW > 0 and ww > maxWW then
                return false
            end
        end
    end

    -- Year filter (Vehicle Years mod integration).
    local minYear = self.config.minYear or 0
    local maxYear = self.config.maxYear or 0
    if minYear > 0 or maxYear > 0 then
        UeyUtils.loadStoreItemSpecs(si)
        local year = si.specs ~= nil and tonumber(si.specs.year) or nil
        if year == nil then
            if not (self.config.includeNoYear ~= false) then
                return false
            end
        else
            if minYear > 0 and year < minYear then
                return false
            end
            if maxYear > 0 and year > maxYear then
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
    if storeItem == nil then
        return nil
    end

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
        basePrice =
            Vehicle.calculateSellPrice(storeItem, age, operatingTime, configuredPrice, repairPrice, repaintPrice)
    end

    -- Apply the yard's standard price jitter.
    local roll = math.random()
    local isWide = roll >= YardInventory.PRICE_NORMAL_CHANCE
    local spread = YardInventory.getPriceSpread(basePrice, isWide)
    local jitter = 1 + (math.random() * 2 - 1) * spread
    local finalPrice = math.max(1, math.floor(basePrice * jitter))

    -- Ensure the yard lists it for at least 1-2% above what it paid the player.
    if purchasePrice ~= nil and purchasePrice > 0 then
        local minMarkup = 1.01 + math.random() * 0.01 -- 1-2% above purchase price
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

    -- Vehicle dimensions for slot placement.
    local size = YardInventory.getModelSize(storeItem, vehicle.configurations or {})

    return {
        xmlFilename = storeItem.xmlFilename,
        configurations = vehicle.configurations or {},
        price = finalPrice,
        minPrice = minPrice,
        numOwners = numOwners,
        age = age,
        damage = damage,
        wear = wear,
        operatingTime = operatingTime,
        ttlHours = self:randomTTL(),
        vehicle = nil,
        spawnWidth = size.width,
        spawnLength = size.length,
        spawnWidthOffset = size.widthOffset,
        spawnLengthOffset = size.lengthOffset,
        spawnYaw = 0
    }
end

--- Accept a vehicle sold by a player. Tries to place it in the yard immediately.
--- If no room, the vehicle is deleted and its data queued in pendingSoldItems;
--- a fresh vehicle is spawned from that data once space opens. (Hiding the real
--- vehicle instead doesn't work in MP — visibility/physics aren't synced.)
--- purchasePrice = total the yard paid (cash + credit), used as a price floor.
--- Returns the created item (or nil on failure).
function YardInventory:acceptSoldVehicle(vehicle, purchasePrice)
    local item = self:createItemFromVehicle(vehicle, purchasePrice)
    if item == nil then
        return nil
    end

    YardInventory.detachVehicle(vehicle)

    -- The sold vehicle itself may be standing in the yard: don't let it block its own slot.
    local slot = self:findSlotFor(item.spawnWidth, item.spawnLength, nil, { [vehicle] = true })
    if slot == nil then
        -- No room — delete the vehicle (synced to clients by the engine) and
        -- queue its data for re-spawn when space opens.
        vehicle:delete()
        self.pendingSoldItems[#self.pendingSoldItems + 1] = item
        return item
    end

    -- Space available — lock the vehicle, then teleport and display it.
    vehicle:setOwnerFarmId(0)
    if vehicle.setIsTabbable ~= nil then
        vehicle:setIsTabbable(false)
    end
    if vehicle.registerPlayerVehicleControlAllowedFunction ~= nil then
        vehicle:registerPlayerVehicleControlAllowedFunction(vehicle, function()
            return false, nil
        end)
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

    self:assignSlot(item, slot)
    self:placeVehicleInYard(item)
    return item
end

--- Detach a vehicle from its parent and detach all implements from it.
--- Mirrors AttacherJoints:onPreDelete — skips additional attachments.
function YardInventory.detachVehicle(vehicle)
    if vehicle.spec_attachable ~= nil and vehicle.spec_attachable.attacherVehicle ~= nil then
        vehicle.spec_attachable.attacherVehicle:detachImplementByObject(vehicle, true)
    end
    if vehicle.spec_attacherJoints ~= nil and vehicle.spec_attacherJoints.attachedImplements ~= nil then
        local attachedImplements = vehicle.spec_attacherJoints.attachedImplements
        for i = #attachedImplements, 1, -1 do
            local implement = attachedImplements[i]
            if not implement.object:getIsAdditionalAttachment() then
                vehicle:detachImplementByObject(implement.object, true)
            end
        end
    end
end

--- Teleport a just-sold vehicle to its slot (assignSlot first) and register it as stock.
function YardInventory:placeVehicleInYard(item)
    local vehicle = item.vehicle
    if vehicle == nil then
        return
    end

    local x, z, yaw = self:getRootPose(item)

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

    g_server:broadcastEvent(VehicleItemSyncEvent.new(self.yard.id, item))
end

--- Schedule a pending sold item spawn attempt after a short delay (lets
--- deleted vehicles leave physics before overlapBox runs).
function YardInventory:schedulePendingSoldSpawn()
    if #self.pendingSoldItems > 0 and not self.filling and self.fillDelayMs == nil then
        self.fillDelayMs = 500
    end
end

--- Try to spawn the next pending sold item. Called after a delay when space
--- frees up. Pending items are data-only — a fresh vehicle is loaded from the
--- stored xmlFilename/configurations and the item's condition is re-applied.
function YardInventory:trySpawnPendingSoldItem()
    if #self.pendingSoldItems == 0 then
        return
    end
    if self.filling then
        return
    end

    local i = 1
    while i <= #self.pendingSoldItems do
        local item = self.pendingSoldItems[i]
        local storeItem = g_storeManager:getItemByXMLFilename(item.xmlFilename)

        if storeItem == nil then
            -- Store item no longer available (mod removed) — discard.
            table.remove(self.pendingSoldItems, i)
        else
            self:ensureItemSize(item)

            local slot = self:findSlotFor(item.spawnWidth, item.spawnLength)
            if slot ~= nil then
                table.remove(self.pendingSoldItems, i)
                -- TTL starts when the vehicle actually appears in the yard.
                item.ttlHours = self:randomTTL()
                self:assignSlot(item, slot)
                self.items[#self.items + 1] = item
                self:loadItemVehicle(item, storeItem, item.configurations or {}, true)
                return -- one at a time; the load callback schedules the next
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

    -- Free the slot so the space can be reused.
    item.slot = nil

    local itemIndex = nil
    for i, v in ipairs(self.items) do
        if v == item then
            itemIndex = i
            break
        end
    end

    local vehicleObjectId = nil
    if item.vehicle ~= nil then
        -- Capture the network id before the vehicle is deleted — clients key items by it.
        vehicleObjectId = NetworkUtil.getObjectId(item.vehicle)

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
    if not keepVehicle and vehicleObjectId ~= nil and g_server ~= nil then
        g_server:broadcastEvent(VehicleItemRemovedEvent.new(self.yard.id, vehicleObjectId))
    end

    -- Space freed up — schedule pending sold items after a delay so the
    -- deleted vehicle's physics has time to clean up before overlapBox runs.
    self:schedulePendingSoldSpawn()
end

function YardInventory:getItemCount()
    return #self.items
end

-- ---------------------------------------------------------------------------
-- XML persistence
-- ---------------------------------------------------------------------------

-- Numeric testDrive fields that must all be present for a test drive to be saved.
YardInventory.TEST_DRIVE_SAVE_FIELDS = { "farmId", "returnByDay", "returnByHour",
    "origX", "origY", "origZ", "origRx", "origRy", "origRz" }

--- Check an item up front so a bad one is skipped whole rather than leaving a
--- partially written entry. Returns false plus a reason when it can't be saved.
function YardInventory.validateItemForSave(item)
    if type(item) ~= "table" then
        return false, "item is not a table"
    end
    if not UeyUtils.isNonEmptyString(item.xmlFilename) then
        return false, "missing xmlFilename"
    end
    local td = item.testDrive
    if td ~= nil then
        if type(td) ~= "table" then
            return false, "testDrive is not a table"
        end
        for _, field in ipairs(YardInventory.TEST_DRIVE_SAVE_FIELDS) do
            if not UeyUtils.isNumber(td[field]) then
                return false, ("testDrive.%s is not a number"):format(field)
            end
        end
    end
    return true
end

--- Write a name -> weight map, skipping entries that aren't a string name with a positive weight.
local function saveWeightMap(xmlFile, baseKey, map)
    if type(map) ~= "table" then return end
    local idx = 0
    for name, weight in pairs(map) do
        if type(name) == "string" and UeyUtils.isNumber(weight) and weight > 0 then
            local wKey = ("%s(%d)"):format(baseKey, idx)
            setXMLString(xmlFile, wKey .. "#name", name)
            setXMLInt(xmlFile, wKey .. "#weight", weight)
            idx = idx + 1
        end
    end
end

function YardInventory:saveToXML(xmlFile, key)
    local toNumber = UeyUtils.toNumber
    local config = self.config or {}

    -- Save config.
    local quality = UeyUtils.isNonEmptyString(config.quality) and config.quality or "MEDIUM"
    setXMLString(xmlFile, key .. ".config#quality", quality)
    setXMLFloat(xmlFile, key .. ".config#dirtiness", toNumber(config.dirtiness, 0.20))
    setXMLInt(xmlFile, key .. ".config#minWorkingWidth", toNumber(config.minWorkingWidth, 0))
    setXMLInt(xmlFile, key .. ".config#maxWorkingWidth", toNumber(config.maxWorkingWidth, 0))
    setXMLInt(xmlFile, key .. ".config#maxPrice", toNumber(config.maxPrice, 0))
    setXMLInt(xmlFile, key .. ".config#avgStockHours",
        toNumber(config.avgStockHours, YardInventory.DEFAULT_AVG_STOCK_HOURS))
    setXMLInt(xmlFile, key .. ".config#aisleWidth", toNumber(config.aisleWidth, 8))
    setXMLInt(xmlFile, key .. ".config#maxDuplicates", toNumber(config.maxDuplicates, 2))
    setXMLInt(xmlFile, key .. ".config#minYear", toNumber(config.minYear, 0))
    setXMLInt(xmlFile, key .. ".config#maxYear", toNumber(config.maxYear, 0))
    setXMLBool(xmlFile, key .. ".config#includeNoYear", config.includeNoYear ~= false)
    setXMLBool(xmlFile, key .. ".config#allowHirePurchase", config.allowHirePurchase ~= false)

    saveWeightMap(xmlFile, key .. ".config.category", config.categories)
    saveWeightMap(xmlFile, key .. ".config.brand", config.brands)

    -- Row layout spec, so the same rows are rebuilt on load.
    local spec = self.layoutSpec
    if type(spec) == "table" and UeyUtils.isNumber(spec.angle) and UeyUtils.isNumber(spec.vStart) and
        UeyUtils.isNumber(spec.aisleWidth) and type(spec.rowDepths) == "table" then
        setXMLFloat(xmlFile, key .. ".layout#angle", spec.angle)
        setXMLFloat(xmlFile, key .. ".layout#vStart", spec.vStart)
        setXMLFloat(xmlFile, key .. ".layout#aisleWidth", spec.aisleWidth)
        local rowIdx = 0
        for _, depth in ipairs(spec.rowDepths) do
            if UeyUtils.isNumber(depth) then
                setXMLFloat(xmlFile, ("%s.layout.row(%d)#depth"):format(key, rowIdx), depth)
                rowIdx = rowIdx + 1
            end
        end
    end

    -- Save live items followed by pending sold items (data-only, flagged #pending).
    local itemsToSave = {}
    local pendingItems = {}
    for _, item in ipairs(self.items or {}) do
        itemsToSave[#itemsToSave + 1] = item
    end
    for _, pItem in ipairs(self.pendingSoldItems or {}) do
        itemsToSave[#itemsToSave + 1] = pItem
        pendingItems[pItem] = true
    end

    -- Use a separate write index so a skipped item never creates a gap in
    -- the sequence (the load loop stops at the first missing index).
    local writeIdx = 0
    for _, item in ipairs(itemsToSave) do
        local valid, reason = YardInventory.validateItemForSave(item)
        if not valid then
            Logging.warning("[UsedEquipmentYards] saveToXML: skipping item '%s': %s",
                type(item) == "table" and tostring(item.xmlFilename) or "?", reason)
        else
            local iKey = ("%s.item(%d)"):format(key, writeIdx)
            local price = toNumber(item.price, 0)
            setXMLString(xmlFile, iKey .. "#xmlFilename", item.xmlFilename)
            setXMLInt(xmlFile, iKey .. "#price", price)
            setXMLInt(xmlFile, iKey .. "#age", toNumber(item.age, 0))
            setXMLFloat(xmlFile, iKey .. "#damage", toNumber(item.damage, 0))
            setXMLFloat(xmlFile, iKey .. "#wear", toNumber(item.wear, 0))
            setXMLFloat(xmlFile, iKey .. "#operatingTime", toNumber(item.operatingTime, 0) / 1000)
            setXMLInt(xmlFile, iKey .. "#ttlHours", toNumber(item.ttlHours, YardInventory.DEFAULT_AVG_STOCK_HOURS))
            setXMLInt(xmlFile, iKey .. "#numOwners", toNumber(item.numOwners, 1))
            setXMLInt(xmlFile, iKey .. "#minPrice", toNumber(item.minPrice, price))
            setXMLFloat(xmlFile, iKey .. "#spawnWidth", toNumber(item.spawnWidth, 0))
            setXMLFloat(xmlFile, iKey .. "#spawnLength", toNumber(item.spawnLength, 0))
            setXMLFloat(xmlFile, iKey .. "#spawnYaw", toNumber(item.spawnYaw, 0))
            if UeyUtils.isNumber(item.spawnWidthOffset) and UeyUtils.isNumber(item.spawnLengthOffset) then
                setXMLFloat(xmlFile, iKey .. "#spawnWidthOffset", item.spawnWidthOffset)
                setXMLFloat(xmlFile, iKey .. "#spawnLengthOffset", item.spawnLengthOffset)
            end
            -- Footprint centre in the row layout (absent = place it again on load).
            if UeyUtils.isNumber(item.footX) and UeyUtils.isNumber(item.footZ) and not item.evicting then
                setXMLFloat(xmlFile, iKey .. "#footX", item.footX)
                setXMLFloat(xmlFile, iKey .. "#footZ", item.footZ)
            end

            if pendingItems[item] then
                setXMLBool(xmlFile, iKey .. "#pending", true)
            end

            -- Save vehicle configurations so the correct config is used if re-spawned.
            if type(item.configurations) == "table" then
                local cfgIdx = 0
                for cfgName, cfgValue in pairs(item.configurations) do
                    if type(cfgName) == "string" then
                        local cfgKey = ("%s.vehicleConfig(%d)"):format(iKey, cfgIdx)
                        setXMLString(xmlFile, cfgKey .. "#name", cfgName)
                        setXMLInt(xmlFile, cfgKey .. "#value", toNumber(cfgValue, 0))
                        cfgIdx = cfgIdx + 1
                    end
                end
            end

            -- Save vehicle uniqueId so we can re-associate on load.
            if item.vehicle ~= nil and UeyUtils.isNonEmptyString(item.vehicle.uniqueId) then
                setXMLString(xmlFile, iKey .. "#vehicleUniqueId", item.vehicle.uniqueId)
            end

            -- Test driven history (which farms have already test-driven this item).
            if type(item.testDrivenByFarms) == "table" then
                local fi = 0
                for farmId, _ in pairs(item.testDrivenByFarms) do
                    local id = toNumber(farmId, nil)
                    if id ~= nil then
                        setXMLInt(xmlFile, ("%s.testDrivenByFarm(%d)#farmId"):format(iKey, fi), id)
                        fi = fi + 1
                    end
                end
            end

            -- Test drive state (fields already validated as numbers).
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

            writeIdx = writeIdx + 1
        end
    end
end

function YardInventory:loadFromXML(xmlFile, key)
    -- Load config (fall back to defaults if not present).
    if hasXMLProperty(xmlFile, key .. ".config") then
        self.config = {
            quality = getXMLString(xmlFile, key .. ".config#quality") or "MEDIUM",
            dirtiness = getXMLFloat(xmlFile, key .. ".config#dirtiness") or 0.20,
            minWorkingWidth = getXMLInt(xmlFile, key .. ".config#minWorkingWidth") or 0,
            maxWorkingWidth = getXMLInt(xmlFile, key .. ".config#maxWorkingWidth") or 0,
            maxPrice = getXMLInt(xmlFile, key .. ".config#maxPrice") or 0,
            avgStockHours = getXMLInt(xmlFile, key .. ".config#avgStockHours") or YardInventory.DEFAULT_AVG_STOCK_HOURS,
            aisleWidth = getXMLInt(xmlFile, key .. ".config#aisleWidth") or 8,
            maxDuplicates = getXMLInt(xmlFile, key .. ".config#maxDuplicates") or 2,
            minYear = getXMLInt(xmlFile, key .. ".config#minYear") or 0,
            maxYear = getXMLInt(xmlFile, key .. ".config#maxYear") or 0,
            includeNoYear = getXMLBool(xmlFile, key .. ".config#includeNoYear") ~= false,
            allowHirePurchase = getXMLBool(xmlFile, key .. ".config#allowHirePurchase") ~= false,
            categories = {},
            brands = {}
        }
        local ci = 0
        while true do
            local cKey = ("%s.config.category(%d)"):format(key, ci)
            if not hasXMLProperty(xmlFile, cKey) then
                break
            end
            local catName = getXMLString(xmlFile, cKey .. "#name")
            local weight = getXMLInt(xmlFile, cKey .. "#weight") or 0
            if catName ~= nil then
                self.config.categories[catName] = weight
            end
            ci = ci + 1
        end
        local bi = 0
        while true do
            local bKey = ("%s.config.brand(%d)"):format(key, bi)
            if not hasXMLProperty(xmlFile, bKey) then
                break
            end
            local brandName = getXMLString(xmlFile, bKey .. "#name")
            local weight = getXMLInt(xmlFile, bKey .. "#weight") or 0
            if brandName ~= nil then
                self.config.brands[brandName] = weight
            end
            bi = bi + 1
        end
    end

    -- Row layout spec.
    if hasXMLProperty(xmlFile, key .. ".layout") then
        local spec = {
            angle = getXMLFloat(xmlFile, key .. ".layout#angle"),
            vStart = getXMLFloat(xmlFile, key .. ".layout#vStart"),
            aisleWidth = getXMLFloat(xmlFile, key .. ".layout#aisleWidth"),
            rowDepths = {}
        }
        local ri = 0
        while true do
            local depth = getXMLFloat(xmlFile, ("%s.layout.row(%d)#depth"):format(key, ri))
            if depth == nil then
                break
            end
            spec.rowDepths[#spec.rowDepths + 1] = depth
            ri = ri + 1
        end
        if spec.angle ~= nil and spec.vStart ~= nil and spec.aisleWidth ~= nil and #spec.rowDepths > 0 then
            self.layoutSpec = spec
        end
    end

    -- Load items.
    self.pendingSoldItems = {}
    local i = 0
    while true do
        local iKey = ("%s.item(%d)"):format(key, i)
        if not hasXMLProperty(xmlFile, iKey) then
            break
        end
        local item = {
            xmlFilename = getXMLString(xmlFile, iKey .. "#xmlFilename") or "",
            price = getXMLInt(xmlFile, iKey .. "#price") or 0,
            age = getXMLInt(xmlFile, iKey .. "#age") or 0,
            damage = getXMLFloat(xmlFile, iKey .. "#damage") or 0,
            wear = getXMLFloat(xmlFile, iKey .. "#wear") or 0,
            operatingTime = (getXMLFloat(xmlFile, iKey .. "#operatingTime") or 0) * 1000,
            ttlHours = getXMLInt(xmlFile, iKey .. "#ttlHours") or self:randomTTL(),
            numOwners = getXMLInt(xmlFile, iKey .. "#numOwners") or 1,
            minPrice = getXMLInt(xmlFile, iKey .. "#minPrice"),
            vehicleUniqueId = getXMLString(xmlFile, iKey .. "#vehicleUniqueId"),
            spawnWidth = getXMLFloat(xmlFile, iKey .. "#spawnWidth") or 0,
            spawnLength = getXMLFloat(xmlFile, iKey .. "#spawnLength") or 0,
            spawnYaw = getXMLFloat(xmlFile, iKey .. "#spawnYaw") or 0,
            spawnWidthOffset = getXMLFloat(xmlFile, iKey .. "#spawnWidthOffset"),
            spawnLengthOffset = getXMLFloat(xmlFile, iKey .. "#spawnLengthOffset"),
            footX = getXMLFloat(xmlFile, iKey .. "#footX"),
            footZ = getXMLFloat(xmlFile, iKey .. "#footZ"),
            vehicle = nil
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
            if not hasXMLProperty(xmlFile, cfgKey) then
                break
            end
            local cfgName = getXMLString(xmlFile, cfgKey .. "#name")
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
            if not hasXMLProperty(xmlFile, fKey) then
                break
            end
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
                farmId = getXMLInt(xmlFile, tdKey .. "#farmId") or 0,
                returnByDay = getXMLInt(xmlFile, tdKey .. "#returnByDay") or 0,
                returnByHour = getXMLInt(xmlFile, tdKey .. "#returnByHour") or 0,
                origX = getXMLFloat(xmlFile, tdKey .. "#origX") or 0,
                origY = getXMLFloat(xmlFile, tdKey .. "#origY") or 0,
                origZ = getXMLFloat(xmlFile, tdKey .. "#origZ") or 0,
                origRx = getXMLFloat(xmlFile, tdKey .. "#origRx") or 0,
                origRy = getXMLFloat(xmlFile, tdKey .. "#origRy") or 0,
                origRz = getXMLFloat(xmlFile, tdKey .. "#origRz") or 0
            }
        end

        if getXMLBool(xmlFile, iKey .. "#pending") then
            -- Data-only pending sold item — re-spawned when space opens.
            item.vehicleUniqueId = nil
            self.pendingSoldItems[#self.pendingSoldItems + 1] = item
        elseif getXMLBool(xmlFile, iKey .. "#hidden") then
            -- Legacy save: pending sold item with a real hidden vehicle. spawn()
            -- deletes that vehicle; the item re-spawns from data like #pending.
            item.legacyVehicleUniqueId = item.vehicleUniqueId
            item.vehicleUniqueId = nil
            self.pendingSoldItems[#self.pendingSoldItems + 1] = item
        else
            self.items[#self.items + 1] = item
        end

        i = i + 1
    end
end
