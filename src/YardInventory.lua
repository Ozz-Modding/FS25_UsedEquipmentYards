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
YardInventory.ABSOLUTE_MAX_ITEMS       = 50

-- Spawn mode constants.
YardInventory.SPAWN_FILL               = 1 -- fill yard to capacity (used on reset/dev)
YardInventory.SPAWN_SINGLE             = 2 -- spawn one vehicle then stop (used on hourly tick)

-- Set to true to fill the yard immediately on creation (dev/testing).
-- Set to false for production: inventory builds up organically via hourly ticks.
YardInventory.FILL_ON_CREATE           = true

-- ---------------------------------------------------------------------------
-- Quality presets — control hours, damage, and wear ranges
-- ---------------------------------------------------------------------------
-- Hours are engine hours (what you see on the dashboard). Age in months is
-- derived from hours for Vehicle.calculateSellPrice (~800 hours/year average).
YardInventory.HOURS_PER_YEAR           = 800

YardInventory.QUALITY                  = {
    LOW = {
        hoursMin = 60,
        hoursMax = 120,
        damageMin = 0.35,
        damageMax = 0.7,
        wearMin = 0.5,
        wearMax = 1.0,
    },
    MEDIUM = {
        hoursMin = 25,
        hoursMax = 60,
        damageMin = 0.15,
        damageMax = 0.45,
        wearMin = 0.2,
        wearMax = 0.65,
    },
    HIGH = {
        hoursMin = 5,
        hoursMax = 25,
        damageMin = 0.05,
        damageMax = 0.2,
        wearMin = 0.05,
        wearMax = 0.25,
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
}

-- Dirt jitter range applied ± around the dirtiness base
YardInventory.DIRT_RANGE               = 0.20

-- Minimum vehicle new price to be included (filters out tiny items).
YardInventory.MIN_VEHICLE_PRICE        = 10000
-- Maximum used price — vehicles priced above this after jitter are re-rolled.
YardInventory.MAX_VEHICLE_PRICE        = 999999

-- Inset from fence boundary to avoid spawning outside non-rectangular areas (metres).
YardInventory.BOUNDS_INSET             = 3

-- ---------------------------------------------------------------------------
-- Scatter placement constants
-- ---------------------------------------------------------------------------
-- Buffer distance (metres) added around each vehicle's bounding radius.
-- Ensures vehicles have enough clearance to be driven out.
YardInventory.VEHICLE_CLEARANCE_BUFFER = 2.0
-- Maximum random positions to try before giving up on one vehicle.
YardInventory.MAX_PLACEMENT_ATTEMPTS   = 50
-- After this many consecutive vehicles fail to find a position, declare
-- the yard full and stop spawning.
YardInventory.MAX_CONSECUTIVE_FAILURES = 8
-- Yaw jitter range (radians). Vehicles face toward the yard entrance
-- (anchor point) then add uniform noise within this range. ≈ ±15°.
YardInventory.YAW_JITTER               = math.rad(15)
-- Terrain offset (metres) when calling setPosition — lifts the vehicle
-- slightly above the ground to avoid clipping.
YardInventory.TERRAIN_OFFSET           = 0.5

-- Price jitter — adds variety around the base sell-price formula.
-- PRICE_NORMAL_CHANCE: probability of the narrow band (0–1).
-- PRICE_NORMAL_SPREAD: ± multiplier for the narrow band (e.g. 0.10 = ±10%).
-- PRICE_WIDE_SPREAD: ± multiplier for the remaining wide band (e.g. 0.25 = ±25%).
YardInventory.PRICE_NORMAL_CHANCE      = 0.85
YardInventory.PRICE_NORMAL_SPREAD      = 0.10
YardInventory.PRICE_WIDE_SPREAD        = 0.25

-- ---------------------------------------------------------------------------
-- TTL (time to live) — how long a spawned vehicle stays before expiring.
-- ---------------------------------------------------------------------------
-- Range in in-game hours; each vehicle gets a random value in [min, max].
YardInventory.TTL_MIN_HOURS            = 24
YardInventory.TTL_MAX_HOURS            = 144
-- Probability each in-game hour that a new vehicle is spawned (if space allows).
YardInventory.HOURLY_SPAWN_CHANCE      = 0.20

--- Deep-copy a config table so edits don't affect the original.
function YardInventory.copyConfig(cfg)
    local copy = {
        quality    = cfg.quality,
        dirtiness  = cfg.dirtiness,
        categories = {},
        brands     = {},
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
    self.placedPositions     = {}  -- { x, z, radius } for clearance checks
    self.consecutiveFailures = 0
    self.filling             = false -- true while the fill loop is running
    self.spawnMode           = YardInventory.SPAWN_FILL
    return self
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
    -- Skip vehicles currently on test drive (don't expire them).
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
            local overdue = (env.currentMonotonicDay > td.returnByDay)
                or (env.currentMonotonicDay == td.returnByDay and env.currentHour >= td.returnByHour)
            if overdue then
                local fine = math.max(TestDriveEvent.FINE_MINIMUM,
                    math.floor(item.price * TestDriveEvent.FINE_PER_HOUR))
                g_currentMission:addMoneyChange(-fine, td.farmId, MoneyType.OTHER, true)
                print(("[UsedEquipmentYards] Test drive overdue — fined farm %d: %s"):format(
                    td.farmId, g_i18n:formatMoney(fine)))
            end
        end
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
    if YardInventory.FILL_ON_CREATE then
        self.spawnMode = YardInventory.SPAWN_FILL
        self.filling = true
        self.consecutiveFailures = 0
        self.placedPositions = {}
        self:spawnNext()
    end
end

--- Attempt to spawn a single vehicle (hourly tick).
function YardInventory:trySpawnOne()
    self.spawnMode = YardInventory.SPAWN_SINGLE
    self.filling = true
    self.consecutiveFailures = 0
    self:rebuildPlacedPositions()
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

    self.placedPositions = {}
end

--- Full reset — despawns everything and fills from scratch.
--- Always fills regardless of FILL_ON_CREATE (explicit dev action).
function YardInventory:reset()
    self:despawnAll()
    self.items = {}
    self.storePool = nil
    self.placedPositions = {}
    self.spawnMode = YardInventory.SPAWN_FILL
    self.filling = true
    self.consecutiveFailures = 0
    self:spawnNext()
end

--- Apply a new config. Does NOT respawn — inventory updates organically via TTL.
function YardInventory:applyConfig(newConfig)
    self.config = YardInventory.copyConfig(newConfig)
    self.storePool = nil -- force rebuild with new categories on next spawn
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

    -- Use the game's own pricing: sell-price based on age, hours, repair & repaint.
    local defaultPrice  = StoreItemUtil.getDefaultPrice(storeItem, {})
    local repairPrice   = 0
    local repaintPrice  = 0
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
    local spread = roll < YardInventory.PRICE_NORMAL_CHANCE and YardInventory.PRICE_NORMAL_SPREAD or
    YardInventory.PRICE_WIDE_SPREAD
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
        price            = finalPrice,
        minPrice         = minAcceptablePrice,
        numOwners        = numOwners,
        age              = age,
        damage           = damage,
        wear             = wear,
        operatingTime    = operatingTime,
        ttlHours         = math.random(YardInventory.TTL_MIN_HOURS, YardInventory.TTL_MAX_HOURS),
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

    local pool = {}        -- { storeItem, weight }
    local totalWeight = 0

    for _, si in pairs(g_storeManager:getItems()) do
        if si.showInStore and si.extraContentId == nil
            and si.price >= YardInventory.MIN_VEHICLE_PRICE
            and StoreItemUtil.getIsVehicle(si) then

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
-- Scatter placement — random positions within the fence polygon
-- ---------------------------------------------------------------------------

--- Find a random (x, z, yaw) within the yard polygon that has sufficient
--- clearance from all existing vehicles.
---@param candidateRadius number  half the diagonal of the vehicle's footprint
---@return number|nil x
---@return number|nil z
---@return number|nil yaw
function YardInventory:findSpawnPosition(candidateRadius)
    local b = self.yard.bounds
    local inset = YardInventory.BOUNDS_INSET

    -- Inset AABB for random sampling
    local halfW = b.sizeX * 0.5 - inset
    local halfD = b.sizeZ * 0.5 - inset
    if halfW < 2 or halfD < 2 then
        return nil, nil, nil
    end

    local minX = b.cx - halfW
    local minZ = b.cz - halfD
    local rangeX = halfW * 2
    local rangeZ = halfD * 2
    local buffer = YardInventory.VEHICLE_CLEARANCE_BUFFER

    for _ = 1, YardInventory.MAX_PLACEMENT_ATTEMPTS do
        local x = minX + math.random() * rangeX
        local z = minZ + math.random() * rangeZ

        if self.yard:containsPoint(x, z)
            and not self:isPositionTooClose(x, z, candidateRadius + buffer) then
            local yaw = self:parkingYaw(x, z)
            return x, z, yaw
        end
    end

    return nil, nil, nil
end

--- Returns true if (x, z) is too close to any existing vehicle.
--- Checks both the pre-spawn position cache and live vehicles.
---@param x number
---@param z number
---@param requiredDist number  minimum distance from candidate centre to any vehicle's edge
---@return boolean
function YardInventory:isPositionTooClose(x, z, requiredDist)
    -- Check against cached placed positions (includes the existing vehicle's radius).
    for _, placed in ipairs(self.placedPositions) do
        local dx = x - placed.x
        local dz = z - placed.z
        local minDist = requiredDist + placed.radius
        if dx * dx + dz * dz < minDist * minDist then
            return true
        end
    end

    -- Fallback: check live vehicles not yet in the cache (e.g. loaded from save
    -- before the cache was rebuilt).
    for _, v in ipairs(self.vehicles) do
        local ex, _, ez = getWorldTranslation(v.rootNode)
        local dx = x - ex
        local dz = z - ez
        local minDist = requiredDist + 3.0 -- conservative default radius
        if dx * dx + dz * dz < minDist * minDist then
            return true
        end
    end

    return false
end

--- Compute yaw so the vehicle faces toward the yard entrance (anchor point),
--- with ± YAW_JITTER for a natural look.
---@param x number  vehicle world X
---@param z number  vehicle world Z
---@return number yaw in radians
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

--- Record a vehicle's placement for future clearance checks.
function YardInventory:recordPlacedPosition(x, z, radius)
    self.placedPositions[#self.placedPositions + 1] = { x = x, z = z, radius = radius }
end

--- Remove the most recently recorded position (used when a post-spawn
--- safety check rejects the vehicle).
function YardInventory:removeLastPlacedPosition()
    if #self.placedPositions > 0 then
        self.placedPositions[#self.placedPositions] = nil
    end
end

--- Rebuild the placedPositions cache from live vehicles and reserved
--- test-drive return positions (so new spawns don't occupy those spots).
function YardInventory:rebuildPlacedPositions()
    self.placedPositions = {}
    for _, v in ipairs(self.vehicles) do
        local vx, _, vz = getWorldTranslation(v.rootNode)
        self.placedPositions[#self.placedPositions + 1] = { x = vx, z = vz, radius = 3.0 }
    end
    -- Reserve original positions for vehicles currently on test drive.
    for _, item in ipairs(self.items) do
        local td = item.testDrive
        if td ~= nil then
            self.placedPositions[#self.placedPositions + 1] = { x = td.origX, z = td.origZ, radius = 3.0 }
        end
    end
end

-- ---------------------------------------------------------------------------
-- Vehicle spawning (sequential — one at a time via random scatter placement)
-- ---------------------------------------------------------------------------

--- Generate one item, find a random position, and load the vehicle. The
--- callback will call spawnNext again in FILL mode.
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
        self:removeItemByRef(item)
        self:spawnNext()
        return
    end

    -- Get vehicle dimensions for clearance calculation.
    local config = YardInventory.randomConfiguration(storeItem)
    local rotation = storeItem.rotation or 0
    local sizeValues = StoreItemUtil.getSizeValues(storeItem.xmlFilename, "vehicle", rotation, config)
    local radius = math.max(sizeValues.width, sizeValues.length) * 0.5

    -- Find a valid scatter position.
    local x, z, yaw = self:findSpawnPosition(radius)
    if x == nil then
        -- Can't place this vehicle — remove and track failure.
        self:removeItemByRef(item)
        self.consecutiveFailures = self.consecutiveFailures + 1

        if self.consecutiveFailures >= YardInventory.MAX_CONSECUTIVE_FAILURES then
            self.filling = false
            print(("[UsedEquipmentYards] Yard '%s' full — placed %d vehicles (%d consecutive failures)."):format(
                self.yard.name, #self.vehicles, self.consecutiveFailures))
            return
        end

        -- Try again with a different (potentially smaller) vehicle.
        self:spawnNext()
        return
    end

    self.consecutiveFailures = 0

    -- Record position BEFORE async load so the next spawn sees it.
    self:recordPlacedPosition(x, z, radius)

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
        self:removeItemByRef(item)
        self:removeLastPlacedPosition()
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

            -- If this vehicle has an active test drive (loaded from save),
            -- keep it unlocked for the borrowing farm. Otherwise lock it.
            if item.testDrive ~= nil then
                vehicle:setOwnerFarmId(item.testDrive.farmId)
                EquipmentPurchasedEvent.clearVehicleRestrictions(vehicle)
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
        self:removeItemByRef(item)
        self:removeLastPlacedPosition()
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
    setXMLString(xmlFile, key .. ".config#quality", self.config.quality or "MEDIUM")
    setXMLFloat(xmlFile, key .. ".config#dirtiness", self.config.dirtiness or 0.20)

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
        setXMLInt(xmlFile, iKey .. "#ttlHours", item.ttlHours or YardInventory.TTL_MIN_HOURS)
        setXMLInt(xmlFile, iKey .. "#numOwners", item.numOwners or 1)
        setXMLInt(xmlFile, iKey .. "#minPrice", item.minPrice or item.price)

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
            dirtiness  = getXMLFloat(xmlFile, key .. ".config#dirtiness") or 0.20,
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
            ttlHours      = getXMLInt(xmlFile, iKey .. "#ttlHours") or YardInventory.TTL_MIN_HOURS,
            numOwners     = getXMLInt(xmlFile, iKey .. "#numOwners") or 1,
            minPrice      = getXMLInt(xmlFile, iKey .. "#minPrice"),
            vehicle       = nil,
        }
        -- Legacy saves: default minPrice to asking price (no discount).
        if item.minPrice == nil then
            item.minPrice = item.price
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
        i = i + 1
    end
end
