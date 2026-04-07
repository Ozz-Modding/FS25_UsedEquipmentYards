-- FS25_UsedEquipmentYards
-- Author: Ozz
-- Entry point: registered as a mod event listener

UsedEquipmentYards = {}
UsedEquipmentYards.dir     = g_currentModDirectory
UsedEquipmentYards.modName = g_currentModName

-- Activatables registered with the activatable system (one per yard).
UsedEquipmentYards.activatables = {}

-- Client-side yard registry: populated via YardCreatedEvent on remote MP clients
-- and via PlaceableUsedEquipmentYard:onReadStream for clients joining mid-game.
-- The server uses yardManager instead; this table is only non-empty on remote clients.
UsedEquipmentYards.clientYards = {}

-- Recent sales memory: ring buffer of { uniqueId, price } for vehicles sold to
-- players. Used to prevent profit from immediately selling a vehicle back.
-- Synced to all clients and persisted to savegame.
UsedEquipmentYards.MAX_RECENT_SALES = 10
UsedEquipmentYards.recentSales = {}

function UsedEquipmentYards.addRecentSale(uniqueId, price)
    if uniqueId == nil or price == nil then return end
    -- Update existing entry if present.
    for i, entry in ipairs(UsedEquipmentYards.recentSales) do
        if entry.uniqueId == uniqueId then
            entry.price = price
            return
        end
    end
    -- Evict oldest if at capacity.
    if #UsedEquipmentYards.recentSales >= UsedEquipmentYards.MAX_RECENT_SALES then
        table.remove(UsedEquipmentYards.recentSales, 1)
    end
    UsedEquipmentYards.recentSales[#UsedEquipmentYards.recentSales + 1] = {
        uniqueId = uniqueId,
        price    = price,
    }
end

function UsedEquipmentYards.getRecentSalePrice(uniqueId)
    if uniqueId == nil then return nil end
    for _, entry in ipairs(UsedEquipmentYards.recentSales) do
        if entry.uniqueId == uniqueId then
            return entry.price
        end
    end
    return nil
end

function UsedEquipmentYards:loadMap(filename)
    PriceTagRenderer.load()
    YardConfigDialog.register()
    BarterDialog.register()
    SaleZoneDialog.register()
    SellBarterDialog.register()
    BarterState.init()
    YardCredit.init()

    if g_currentMission:getIsServer() then
        self.yardManager = YardManager.new(self)
        self.yardManager:load()

        -- Create activatables for already-loaded yards.
        for _, yard in pairs(self.yardManager.yards) do
            UsedEquipmentYards.addActivatable(yard)
        end
    end

    if g_addCheatCommands then
        self:registerConsoleCommands()
    end
end

function UsedEquipmentYards:delete()
    self:unregisterConsoleCommands()
    UsedEquipmentYards.removeAllActivatables()
    -- Clean up client vehicle activatables.
    for vehicle, activatable in pairs(UsedEquipmentYards.clientVehicleActivatables) do
        g_currentMission.activatableObjectsSystem:removeActivatable(activatable)
    end
    UsedEquipmentYards.clientVehicleActivatables = {}
    UsedEquipmentYards.clientItems = {}
    UsedEquipmentYards.pendingClientItems = {}
    UsedEquipmentYards.vehicleToItem = {}
    UsedEquipmentYards.clientYards = {}
    UsedEquipmentYards.recentSales = {}
    BarterState.delete()
    YardCredit.delete()
    PriceTagRenderer.delete()
    if self.yardManager ~= nil then
        self.yardManager:delete()
        self.yardManager = nil
    end
end

-- ---------------------------------------------------------------------------
-- Console commands (dev/debug only)
-- ---------------------------------------------------------------------------

function UsedEquipmentYards:registerConsoleCommands()
    addConsoleCommand("ueyResetInventory", "Reset inventory: ueyResetInventory [id|all]",  "consoleResetInventory", self)
end

function UsedEquipmentYards:unregisterConsoleCommands()
    removeConsoleCommand("ueyResetInventory")
end

function UsedEquipmentYards:consoleResetInventory(id)
    if self.yardManager == nil then return "YardManager not active (server only)." end
    if id == nil or id == "all" then
        self.yardManager:resetAllInventories()
        return "All yard inventories reset."
    end
    return self.yardManager:resetInventory(tonumber(id))
end

-- ---------------------------------------------------------------------------
-- Save hook
-- ---------------------------------------------------------------------------

FSBaseMission.saveSavegame = Utils.appendedFunction(FSBaseMission.saveSavegame, function()
    if UsedEquipmentYards.yardManager ~= nil then
        UsedEquipmentYards.yardManager:save()
    end
end)

-- After mission start: start fence patch timer and spawn vehicles.
FSBaseMission.onStartMission = Utils.appendedFunction(FSBaseMission.onStartMission, function()
    UsedEquipmentYards.fencePatchTimer = UsedEquipmentYards.fencePatchDelay
    if UsedEquipmentYards.yardManager ~= nil then
        UsedEquipmentYards.yardManager:spawnAllYards()
    end
end)

FSBaseMission.sendInitialClientState = Utils.appendedFunction(FSBaseMission.sendInitialClientState,
    function(self, connection, user, farm)
        connection:sendEvent(InitialClientStateEvent.new())
    end)

-- Block attaching to/from yard vehicles that are not on a test drive.
-- A yard vehicle is any vehicle in UsedEquipmentYards.vehicleToItem.
if Attachable ~= nil then
    Attachable.isAttachAllowed = Utils.overwrittenFunction(
        Attachable.isAttachAllowed,
        function(self, superFunc, farmId, attacherVehicle)
            -- Check if the attachable (implement) is a yard vehicle not on test drive.
            local item = UsedEquipmentYards.findItemForVehicle(self)
            if item ~= nil and item.testDrive == nil then
                return false
            end

            -- Check if the attacher (tractor) is a yard vehicle not on test drive.
            local attacherItem = UsedEquipmentYards.findItemForVehicle(attacherVehicle)
            if attacherItem ~= nil and attacherItem.testDrive == nil then
                return false
            end

            return superFunc(self, farmId, attacherVehicle)
        end
    )
end

-- Patch fence construction brushes so yard fence posts can be placed on any land.
-- Two checks need bypassing:
--   1. ConstructionBrush:verifyAccess — checks canFarmAccessLand (runs every frame + on click)
--   2. ConstructionBrushNewFence:validateCurrentSegment — checks getIsOwnedByFarmAlongLine
-- Both hardcode farmland ownership checks that our placeable overrides cannot reach.

local function isYardFenceBrush(brush)
    return brush.fenceParentObject ~= nil
       and brush.fenceParentObject[PlaceableUsedEquipmentYard.KEY] ~= nil
end

--- Install fence construction patches. Called with a delay so we wrap
--- whatever version exists AFTER all other mods have had time to patch.
UsedEquipmentYards.fencePatchDelay = 5000  -- ms
UsedEquipmentYards.fencePatchTimer = nil

function UsedEquipmentYards.installFencePatches()
    if UsedEquipmentYards.fencePatchesInstalled then return end
    UsedEquipmentYards.fencePatchesInstalled = true

    if ConstructionBrush ~= nil then
        ConstructionBrush.verifyAccess = Utils.overwrittenFunction(
            ConstructionBrush.verifyAccess,
            function(self, superFunc, x, y, z)
                if isYardFenceBrush(self) then
                    return nil
                end
                local screen = g_constructionScreen
                if screen ~= nil and screen.brush ~= nil and isYardFenceBrush(screen.brush) then
                    return nil
                end
                return superFunc(self, x, y, z)
            end
        )
    end

    -- Also patch verifyAccess directly on NewFence in case a mod map's
    -- subclass overrides it and our ConstructionBrush patch doesn't reach it.
    if ConstructionBrushNewFence ~= nil and ConstructionBrushNewFence.verifyAccess ~= nil then
        ConstructionBrushNewFence.verifyAccess = Utils.overwrittenFunction(
            ConstructionBrushNewFence.verifyAccess,
            function(self, superFunc, x, y, z)
                if isYardFenceBrush(self) then
                    return nil
                end
                return superFunc(self, x, y, z)
            end
        )
    end

    if ConstructionBrushNewFence ~= nil then
        ConstructionBrushNewFence.validateCurrentSegment = Utils.overwrittenFunction(
            ConstructionBrushNewFence.validateCurrentSegment,
            function(self, superFunc, x, z)
                if isYardFenceBrush(self) then
                    if self.currentSegment == nil then return false end
                    local sx, _, sz = self.currentSegment:getStartPos()
                    if sx == nil then return false end
                    local price = self.currentSegment:getPrice()
                    if g_currentMission:getMoney(g_localPlayer.farmId) < price then
                        self.cursor:setErrorMessage(g_i18n:getText(ConstructionBrushNewFence.ERROR_MESSAGES[ConstructionBrushNewFence.ERROR.NOT_ENOUGH_MONEY]))
                        return false
                    end
                    if price > 0 then
                        self.cursor:setMessage(g_i18n:formatMoney(price))
                    end
                    return true
                end
                return superFunc(self, x, z)
            end
        )
    end
end

-- ---------------------------------------------------------------------------
-- Activatable management — one per yard, added/removed with yard lifecycle
-- ---------------------------------------------------------------------------

function UsedEquipmentYards.addActivatable(yard)
    if UsedEquipmentYards.activatables[yard.id] ~= nil then return end
    local activatable = YardConfigActivatable.new(yard)
    UsedEquipmentYards.activatables[yard.id] = activatable
    g_currentMission.activatableObjectsSystem:addActivatable(activatable)
end

function UsedEquipmentYards.removeActivatable(yardId)
    local activatable = UsedEquipmentYards.activatables[yardId]
    if activatable == nil then return end
    g_currentMission.activatableObjectsSystem:removeActivatable(activatable)
    UsedEquipmentYards.activatables[yardId] = nil
end

function UsedEquipmentYards.removeAllActivatables()
    for id, activatable in pairs(UsedEquipmentYards.activatables) do
        g_currentMission.activatableObjectsSystem:removeActivatable(activatable)
    end
    UsedEquipmentYards.activatables = {}
end

-- ---------------------------------------------------------------------------
-- Client-side yard registry helpers (called from events and onReadStream)
-- ---------------------------------------------------------------------------

--- Register a yard received from the server. Creates a lightweight UsedEquipmentYard
--- (no server-side spawning) and adds a YardConfigActivatable for the local player.
function UsedEquipmentYards.registerClientYard(yardId, yardName, bounds)
    if UsedEquipmentYards.clientYards[yardId] ~= nil then return end
    local yard = UsedEquipmentYard.new(yardId, yardName, bounds)
    UsedEquipmentYards.clientYards[yardId] = yard
    UsedEquipmentYards.addActivatable(yard)
end

--- Remove a client-side yard and its activatable.
function UsedEquipmentYards.unregisterClientYard(yardId)
    if UsedEquipmentYards.clientYards[yardId] == nil then return end
    UsedEquipmentYards.clientYards[yardId] = nil
    UsedEquipmentYards.removeActivatable(yardId)
end

-- ---------------------------------------------------------------------------
-- Vehicle → yard item lookup (populated by YardInventory on spawn,
-- and by VehicleItemSyncEvent on remote clients)
-- ---------------------------------------------------------------------------

UsedEquipmentYards.vehicleToItem = {}

-- Client-side item registry: { [yardId] = { [itemIndex] = item } }
-- On the server, items live in YardInventory. On remote clients, this
-- table holds lightweight copies synced via VehicleItemSyncEvent.
UsedEquipmentYards.clientItems = {}

-- Vehicle activatables created for client-side items (keyed by vehicle).
UsedEquipmentYards.clientVehicleActivatables = {}

-- Pending items waiting for vehicle network objects to resolve.
-- { { yardId, itemIndex, vehicleObjectId, item }, ... }
UsedEquipmentYards.pendingClientItems = {}

function UsedEquipmentYards.findItemForVehicle(vehicle)
    return UsedEquipmentYards.vehicleToItem[vehicle]
end

--- Called on remote clients when the server syncs a yard vehicle's item data.
--- Creates the vehicle→item mapping and registers a YardVehicleActivatable.
function UsedEquipmentYards.registerClientItem(yardId, itemIndex, item)
    if item.vehicle == nil then return end

    -- Store in client item registry.
    if UsedEquipmentYards.clientItems[yardId] == nil then
        UsedEquipmentYards.clientItems[yardId] = {}
    end
    UsedEquipmentYards.clientItems[yardId][itemIndex] = item

    -- Map vehicle → item (for HUD and lookups).
    UsedEquipmentYards.vehicleToItem[item.vehicle] = item

    -- Register activatable if not already present.
    if UsedEquipmentYards.clientVehicleActivatables[item.vehicle] == nil then
        local yard = UsedEquipmentYards.clientYards[yardId]
        if yard == nil then
            -- Create a minimal yard object if we don't have one yet.
            yard = { id = yardId, inventory = { items = {} } }
        end
        -- Store item in yard inventory items at the right index for BarterDialog.
        yard.inventory.items[itemIndex] = item

        local activatable = YardVehicleActivatable.new(yard, item)
        UsedEquipmentYards.clientVehicleActivatables[item.vehicle] = activatable
        g_currentMission.activatableObjectsSystem:addActivatable(activatable)
    else
        -- Update existing item data (e.g. test drive state change).
        local existingItem = UsedEquipmentYards.clientItems[yardId][itemIndex]
        if existingItem ~= nil then
            existingItem.price            = item.price
            existingItem.minPrice         = item.minPrice
            existingItem.testDrive        = item.testDrive
            existingItem.testDrivenByFarms = item.testDrivenByFarms
        end
    end
end

--- Queue an item for deferred resolution when the vehicle object isn't available yet.
function UsedEquipmentYards.addPendingClientItem(yardId, itemIndex, vehicleObjectId, item)
    UsedEquipmentYards.pendingClientItems[#UsedEquipmentYards.pendingClientItems + 1] = {
        yardId          = yardId,
        itemIndex       = itemIndex,
        vehicleObjectId = vehicleObjectId,
        item            = item,
    }
end

--- Remove a client-side item (e.g. after purchase).
function UsedEquipmentYards.removeClientItem(yardId, itemIndex)
    local yardItems = UsedEquipmentYards.clientItems[yardId]
    if yardItems == nil then return end
    local item = yardItems[itemIndex]
    if item == nil then return end

    -- Remove activatable.
    if item.vehicle ~= nil then
        local activatable = UsedEquipmentYards.clientVehicleActivatables[item.vehicle]
        if activatable ~= nil then
            g_currentMission.activatableObjectsSystem:removeActivatable(activatable)
            UsedEquipmentYards.clientVehicleActivatables[item.vehicle] = nil
        end
        UsedEquipmentYards.vehicleToItem[item.vehicle] = nil
    end

    yardItems[itemIndex] = nil
end

-- ---------------------------------------------------------------------------
-- HUD: show info when looking at a yard vehicle
-- ---------------------------------------------------------------------------
-- The base game's showVehicleInfo skips vehicles with ownerFarmId = 0
-- (SPECTATOR_FARM_ID). We hook into the update loop to display our own
-- info box for yard vehicles: name, price, damage, wear, hours.

if PlayerHUDUpdater ~= nil then
    PlayerHUDUpdater.update = Utils.appendedFunction(PlayerHUDUpdater.update, function(self, dt)
        if not Platform.playerInfo.showVehicleInfo then return end
        if not self.isVehicle or self.object == nil then return end

        local item = UsedEquipmentYards.findItemForVehicle(self.object)
        if item == nil then return end

        local vehicle = self.object
        local box = self.objectBox
        box:clear()
        box:setTitle(vehicle:getFullName())
        box:addLine(g_i18n:getText("uey_hud_forSale"), g_i18n:formatMoney(item.price))

        local damagePercent = (item.damage or 0) * 100
        local wearPercent   = (item.wear   or 0) * 100
        local hours         = (item.operatingTime or 0) / 3600000

        box:addLine(g_i18n:getText("uey_hud_damage"), ("%.2f %%"):format(damagePercent))
        box:addLine(g_i18n:getText("uey_hud_wear"),   ("%.2f %%"):format(wearPercent))
        box:addLine(g_i18n:getText("uey_hud_hours"),   ("%.2f"):format(hours))
        box:showNextFrame()
    end)
end

-- ---------------------------------------------------------------------------
-- Update loop — resolve pending client items whose vehicles are now available
-- ---------------------------------------------------------------------------

function UsedEquipmentYards:update(dt)
    -- Delayed fence patch install — ensures we're the last to wrap.
    if UsedEquipmentYards.fencePatchTimer ~= nil then
        UsedEquipmentYards.fencePatchTimer = UsedEquipmentYards.fencePatchTimer - dt
        if UsedEquipmentYards.fencePatchTimer <= 0 then
            UsedEquipmentYards.fencePatchTimer = nil
            UsedEquipmentYards.installFencePatches()
        end
    end

    -- Tick yard inventory timers (e.g. delayed fill after reset).
    if UsedEquipmentYards.yardManager ~= nil then
        for _, yard in pairs(UsedEquipmentYards.yardManager.yards) do
            yard.inventory:update(dt)
        end
    end

    -- Resolve pending offer cache entries from network.
    SellBarterDialog.resolvePendingOfferCache()

    local pending = UsedEquipmentYards.pendingClientItems
    local i = #pending
    while i >= 1 do
        local entry = pending[i]
        local vehicle = NetworkUtil.getObject(entry.vehicleObjectId)
        if vehicle ~= nil then
            entry.item.vehicle = vehicle
            UsedEquipmentYards.registerClientItem(entry.yardId, entry.itemIndex, entry.item)
            table.remove(pending, i)
        end
        i = i - 1
    end
end

-- ---------------------------------------------------------------------------
-- Recent sales persistence (XML)
-- ---------------------------------------------------------------------------

function UsedEquipmentYards.saveRecentSalesToXML(xmlFile, rootKey)
    for i, entry in ipairs(UsedEquipmentYards.recentSales) do
        local eKey = ("%s.recentSales.entry(%d)"):format(rootKey, i - 1)
        setXMLString(xmlFile, eKey .. "#uniqueId", entry.uniqueId)
        setXMLInt(xmlFile, eKey .. "#price", entry.price)
    end
end

function UsedEquipmentYards.loadRecentSalesFromXML(xmlFile, rootKey)
    UsedEquipmentYards.recentSales = {}
    local i = 0
    while true do
        local eKey = ("%s.recentSales.entry(%d)"):format(rootKey, i)
        if not hasXMLProperty(xmlFile, eKey) then break end
        local uid   = getXMLString(xmlFile, eKey .. "#uniqueId")
        local price = getXMLInt(xmlFile, eKey .. "#price") or 0
        if uid ~= nil and price > 0 then
            UsedEquipmentYards.recentSales[#UsedEquipmentYards.recentSales + 1] = {
                uniqueId = uid,
                price    = price,
            }
        end
        i = i + 1
    end
end

-- ---------------------------------------------------------------------------
-- Recent sales network streaming (for InitialClientStateEvent)
-- ---------------------------------------------------------------------------

function UsedEquipmentYards.writeRecentSalesStream(streamId)
    local sales = UsedEquipmentYards.recentSales
    streamWriteInt32(streamId, #sales)
    for _, entry in ipairs(sales) do
        streamWriteString(streamId, entry.uniqueId)
        streamWriteInt32(streamId, entry.price)
    end
end

function UsedEquipmentYards.readRecentSalesStream(streamId)
    UsedEquipmentYards.recentSales = {}
    local count = streamReadInt32(streamId)
    for _ = 1, count do
        local uid   = streamReadString(streamId)
        local price = streamReadInt32(streamId)
        if uid ~= nil and price > 0 then
            UsedEquipmentYards.recentSales[#UsedEquipmentYards.recentSales + 1] = {
                uniqueId = uid,
                price    = price,
            }
        end
    end
end

addModEventListener(UsedEquipmentYards)
