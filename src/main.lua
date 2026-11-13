-- FS25_UsedEquipmentYards
-- Author: Ozz
-- Entry point: registered as a mod event listener

UsedEquipmentYards         = {}
UsedEquipmentYards.dir     = g_currentModDirectory
UsedEquipmentYards.modName = g_currentModName

function UsedEquipmentYards.getHirePurchaseEnv()
    if g_currentMission.LeasingOptions == nil then return nil end
    return getfenv(g_currentMission.LeasingOptions.registerLeaseDeal)
end

-- Activatables registered with the activatable system (one per yard).
UsedEquipmentYards.activatables = {}

-- Client-side yard registry: populated via YardCreatedEvent on remote MP clients
-- and via PlaceableUsedEquipmentYard:onReadStream for clients joining mid-game.
-- The server uses yardManager instead; this table is only non-empty on remote clients.
UsedEquipmentYards.clientYards = {}

--- Look up a yard by ID, works on both server and client.
function UsedEquipmentYards.getYard(yardId)
    if UsedEquipmentYards.yardManager ~= nil then
        local yard = UsedEquipmentYards.yardManager.yards[yardId]
        if yard ~= nil then return yard end
    end
    return UsedEquipmentYards.clientYards[yardId]
end

--- Every yard this machine knows: the server's own, or the client registry.
function UsedEquipmentYards.getAllYards()
    if UsedEquipmentYards.yardManager ~= nil then
        return UsedEquipmentYards.yardManager.yards
    end
    return UsedEquipmentYards.clientYards
end

--- In multiplayer, only the server host or an admin (master user) may
--- create, edit, remove or configure yards. In single player, always allowed.
function UsedEquipmentYards.isAdminInMP()
    if not g_currentMission.missionDynamicInfo.isMultiplayer then
        return true
    end
    return g_currentMission:getIsServer() or g_currentMission.isMasterUser
end

--- Server: did this connection come from the host or an admin?
--- (UserManager:getIsConnectionMasterUser never returns its result, so the
--- user is looked up directly.)
function UsedEquipmentYards.isConnectionAdmin(connection)
    if connection == nil or connection:getIsLocal() then
        return true
    end
    local userManager = g_currentMission.userManager
    local user = userManager ~= nil and userManager:getUserByConnection(connection) or nil
    return user ~= nil and user:getIsMasterUser()
end

--- How many placed sale zones are linked to a yard (works on clients too:
--- sale zones stream their yardId).
function UsedEquipmentYards.getConnectedSaleZoneCount(yardId)
    local count = 0
    if g_currentMission ~= nil and g_currentMission.placeableSystem ~= nil then
        for _, placeable in pairs(g_currentMission.placeableSystem.placeables) do
            local szData = placeable[PlaceableSaleZone.KEY]
            if szData ~= nil and szData.yardId == yardId then
                count = count + 1
            end
        end
    end
    return count
end

-- ---------------------------------------------------------------------------
-- The yard tool in the build menu (see src/brush/UeyYardZoneBrush.lua)
-- ---------------------------------------------------------------------------
-- Registered while the mod's scripts load, before store items are read. In a
-- mod's environment g_constructionBrushTypeManager prefixes the type and class
-- names with the mod name, so the store XMLs name the brush type
-- "FS25_UsedEquipmentYards.ueyYardZone". The brush file is sourced by
-- addBrushType itself (it is not in modDesc's extraSourceFiles).
UsedEquipmentYards.BRUSH_TYPE = "ueyYardZone"

function UsedEquipmentYards.registerBrushType()
    local manager = g_constructionBrushTypeManager
    if manager == nil or manager.addBrushType == nil then
        Logging.warning("[UsedEquipmentYards] no construction brush manager - the yard tool is unavailable")
        return
    end
    manager:addBrushType(UsedEquipmentYards.BRUSH_TYPE, "UeyYardZoneBrush",
        UsedEquipmentYards.dir .. "src/brush/UeyYardZoneBrush.lua", UsedEquipmentYards.modName)
end

UsedEquipmentYards.registerBrushType()

-- ---------------------------------------------------------------------------
-- Old saves: yards used to be an electrical box with a fence drawn around it.
-- Those placeables are removed once the game is running; the yards themselves
-- (outline, stock, config) live in UsedEquipmentYards.xml and stay.
-- ---------------------------------------------------------------------------
UsedEquipmentYards.LEGACY_REMOVAL_DELAY = 3000 -- ms after mission start

function UsedEquipmentYards.removeLegacyPlaceables()
    if g_currentMission == nil or not g_currentMission:getIsServer() or g_currentMission.placeableSystem == nil then
        return
    end
    local legacy = {}
    for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
        if placeable[PlaceableUsedEquipmentYard.KEY] ~= nil and not placeable.markedForDeletion then
            legacy[#legacy + 1] = placeable
        end
    end
    for _, placeable in ipairs(legacy) do
        placeable[PlaceableUsedEquipmentYard.KEY].keepYard = true
        placeable:delete()
    end
    if #legacy > 0 then
        Logging.info("[UsedEquipmentYards] removed %d old yard building(s) and fence(s); the yards are kept", #legacy)
    end
end

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
    if g_modIsLoaded["FS25_HirePurchasing"] then
        HirePurchaseDialog.register()
    end
    BarterState.init()
    YardCredit.init()
    YardVisibility.loadSettings()
    UeySettings.initialize()

    if g_currentMission:getIsServer() then
        self.yardManager = YardManager.new(self)
        self.yardManager:load()

        -- Create activatables for already-loaded yards.
        for _, yard in pairs(self.yardManager.yards) do
            UsedEquipmentYards.addActivatable(yard)
        end
    end

    self:registerConsoleCommands()
end

function UsedEquipmentYards:delete()
    self:unregisterConsoleCommands()
    UsedEquipmentYards.removeAllActivatables()
    YardVisibility.showAll()
    -- Clean up client vehicle activatables.
    for vehicle, activatable in pairs(UsedEquipmentYards.clientVehicleActivatables) do
        g_currentMission.activatableObjectsSystem:removeActivatable(activatable)
    end
    UsedEquipmentYards.clientVehicleActivatables = {}
    UsedEquipmentYards.clientItems = {}
    UsedEquipmentYards.pendingClientItems = {}
    UsedEquipmentYards.pendingClientRestrictions = {}
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
    addConsoleCommand("ueyResetInventory", "Reset inventory: ueyResetInventory [id|all]", "consoleResetInventory", self)
end

function UsedEquipmentYards:unregisterConsoleCommands()
    removeConsoleCommand("ueyResetInventory")
end

function UsedEquipmentYards:consoleResetInventory(id)
    -- Server: execute directly.
    if self.yardManager ~= nil then
        if id == nil or id == "all" then
            self.yardManager:resetAllInventories()
            return "All yard inventories reset."
        end
        return self.yardManager:resetInventory(tonumber(id))
    end

    -- Client (admin on dedicated server): send event to server.
    if g_client ~= nil and g_currentMission.isMasterUser then
        local yardId = -1
        if id ~= nil and id ~= "all" then
            yardId = tonumber(id) or -1
        end
        g_client:getServerConnection():sendEvent(ResetInventoryEvent.new(yardId))
        if yardId == -1 then
            return "Reset all inventories requested (sent to server)."
        end
        return ("Reset inventory for yard %d requested (sent to server)."):format(yardId)
    end

    return "Only the server host or admin can reset inventories."
end

function UsedEquipmentYards.saveToXmlFile()
    if UsedEquipmentYards.yardManager ~= nil then
        UsedEquipmentYards.yardManager:save()
    end
end

function UsedEquipmentYards.installSaveHook()
    if UsedEquipmentYards.saveHookInstalled then
        return
    end

    -- Mission00.saveSavegame is inherited from FSBaseMission via metatable, so it is
    -- ALWAYS non-nil even when Mission00 has no override of its own. Checking it directly
    -- (without rawget) would make us always shadow Mission00, permanently orphaning any
    -- mod that later hooks FSBaseMission.saveSavegame (the standard convention most mods
    -- use, e.g. inside FSBaseMission.onStartMission). Only target Mission00 if another mod
    -- has already put its own property there — otherwise stay on FSBaseMission so we remain
    -- part of the shared chain.
    local target = FSBaseMission
    if Mission00 ~= nil and rawget(Mission00, "saveSavegame") ~= nil then
        target = Mission00
    end

    target.saveSavegame = Utils.appendedFunction(target.saveSavegame, UsedEquipmentYards.saveToXmlFile)
    UsedEquipmentYards.saveHookInstalled = true
end

UsedEquipmentYards.installSaveHook()

-- After mission start: schedule the old-placeable cleanup and spawn vehicles.
FSBaseMission.onStartMission = Utils.appendedFunction(FSBaseMission.onStartMission, function()
    UsedEquipmentYards.legacyRemovalTimer = UsedEquipmentYards.LEGACY_REMOVAL_DELAY
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
function UsedEquipmentYards.registerClientYard(yardId, yardName, bounds, config)
    if UsedEquipmentYards.clientYards[yardId] ~= nil then return end
    local yard = UsedEquipmentYard.new(yardId, yardName, bounds)
    if config ~= nil then
        yard.inventory:applyConfig(config)
    end
    UsedEquipmentYards.clientYards[yardId] = yard
    UsedEquipmentYards.addActivatable(yard)
end

--- A yard's outline changed on the server (YardUpdatedEvent).
function UsedEquipmentYards.updateClientYardBounds(yardId, bounds)
    local yard = UsedEquipmentYards.clientYards[yardId]
    if yard ~= nil then
        yard.bounds = bounds
    end
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

-- Client-side item registry: { [yardId] = { [vehicleObjectId] = item } }
-- On the server, items live in YardInventory. On remote clients, this
-- table holds lightweight copies synced via VehicleItemSyncEvent.
-- Keyed by the vehicle's network object id, never by the server's array
-- index — that shifts on the server whenever an earlier item is removed.
UsedEquipmentYards.clientItems = {}

-- Vehicle activatables created for client-side items (keyed by vehicle).
UsedEquipmentYards.clientVehicleActivatables = {}

-- Pending items waiting for vehicle network objects to resolve.
-- { { yardId, vehicleObjectId, item }, ... }
UsedEquipmentYards.pendingClientItems = {}

-- Items whose vehicles are resolved but not fully loaded yet (spec_drivable missing).
UsedEquipmentYards.pendingClientRestrictions = {}

--- Apply yard vehicle restrictions on the client. Returns true if successful,
--- false if the vehicle isn't fully loaded yet (retry later).
function UsedEquipmentYards.applyClientRestrictions(vehicle, item)
    -- Drivable:registerPlayerVehicleControlAllowedFunction indexes
    -- spec.playerControlAllowedFunctions (created in Drivable:onLoad) and silently does
    -- nothing if the vehicle has no network object id yet — check both so we retry
    -- instead of believing the restriction is in place.
    local spec = vehicle.spec_drivable
    if spec == nil or spec.playerControlAllowedFunctions == nil then return false end
    if vehicle.registerPlayerVehicleControlAllowedFunction == nil then return false end
    if NetworkUtil.getObjectId(vehicle) == nil then return false end

    vehicle:registerPlayerVehicleControlAllowedFunction(vehicle, function() return false, nil end)

    PriceTagRenderer.addTag(vehicle, item)
    if vehicle.setIsTabbable ~= nil then vehicle:setIsTabbable(false) end
    return true
end

function UsedEquipmentYards.findItemForVehicle(vehicle)
    return UsedEquipmentYards.vehicleToItem[vehicle]
end

--- Server: find the yard item whose vehicle has the given network object id.
--- Returns nil if the vehicle no longer exists or isn't for sale in this yard.
function UsedEquipmentYards.findServerItem(yard, vehicleObjectId)
    local vehicle = NetworkUtil.getObject(vehicleObjectId)
    if vehicle == nil then return nil end
    for _, item in ipairs(yard.inventory.items) do
        if item.vehicle == vehicle then
            return item
        end
    end
    return nil
end

--- Assign a fresh random license plate. Vehicles spawn with ownerFarmId=0 so
--- spec.licensePlateData is nil at spawn time; there is no original to restore.
function UsedEquipmentYards.restoreLicensePlate(vehicle)
    if vehicle.spec_licensePlates == nil then return end
    if vehicle.setLicensePlatesData == nil then return end
    if not (vehicle.getHasLicensePlates ~= nil and vehicle:getHasLicensePlates()) then return end
    if g_licensePlateManager == nil then return end

    local plateData = g_licensePlateManager:getRandomLicensePlateData()
    local vehiclePlacement = nil
    if vehicle.getLicensePlateDialogSettings ~= nil then
        vehiclePlacement = vehicle:getLicensePlateDialogSettings()
    end
    plateData.placementIndex = vehiclePlacement or LicensePlateManager.PLACEMENT_OPTION.BOTH

    vehicle:setLicensePlatesData(plateData)
end

--- Exclude a vehicle from FS25_AdvancedDamageSystem processing so ADS doesn't
--- drain its battery or trigger breakdowns while it sits in the yard.
function UsedEquipmentYards.setADSExcluded(vehicle, excluded)
    local spec = vehicle.spec_AdvancedDamageSystem
    if spec ~= nil then
        spec.isExcludedVehicle = excluded
    end
end

--- Re-enable driving and Tab cycling on a vehicle previously blocked for yard display.
function UsedEquipmentYards.clearVehicleRestrictions(vehicle)
    if vehicle.spec_drivable ~= nil then
        vehicle.spec_drivable.playerControlAllowedFunctions = {}
        vehicle.spec_drivable.hasPlayerControlAllowedFunctions = false
    end
    if vehicle.setIsTabbable ~= nil then
        vehicle:setIsTabbable(true)
    end
    UsedEquipmentYards.setADSExcluded(vehicle, false)
end

--- Called on remote clients when the server syncs a yard vehicle's item data.
--- Creates the vehicle→item mapping and registers a YardVehicleActivatable.
function UsedEquipmentYards.registerClientItem(yardId, vehicleObjectId, item)
    if item.vehicle == nil then return end

    if UsedEquipmentYards.clientItems[yardId] == nil then
        UsedEquipmentYards.clientItems[yardId] = {}
    end

    -- Update existing item data in place so the activatable keeps a valid reference.
    local existingItem = UsedEquipmentYards.clientItems[yardId][vehicleObjectId]
    if existingItem ~= nil then
        existingItem.price             = item.price
        existingItem.minPrice          = item.minPrice
        existingItem.testDrive         = item.testDrive
        existingItem.testDrivenByFarms = item.testDrivenByFarms
        return
    end

    -- Store in client item registry.
    UsedEquipmentYards.clientItems[yardId][vehicleObjectId] = item

    -- Map vehicle → item (for HUD and lookups).
    UsedEquipmentYards.vehicleToItem[item.vehicle] = item

    -- Apply client-side restrictions (server does this in YardInventory).
    -- If the vehicle isn't fully loaded yet, queue for retry.
    if item.testDrive == nil then
        if not UsedEquipmentYards.applyClientRestrictions(item.vehicle, item) then
            UsedEquipmentYards.pendingClientRestrictions[#UsedEquipmentYards.pendingClientRestrictions + 1] = item
        end
    end

    -- Register activatable if not already present.
    if UsedEquipmentYards.clientVehicleActivatables[item.vehicle] == nil then
        local yard = UsedEquipmentYards.getYard(yardId)
        if yard == nil then
            -- Create a minimal yard object if we don't have one yet.
            yard = { id = yardId, inventory = { items = {} } }
        end

        local activatable = YardVehicleActivatable.new(yard, item)
        UsedEquipmentYards.clientVehicleActivatables[item.vehicle] = activatable
        g_currentMission.activatableObjectsSystem:addActivatable(activatable)
    end
end

--- Queue an item for deferred resolution when the vehicle object isn't available yet.
function UsedEquipmentYards.addPendingClientItem(yardId, vehicleObjectId, item)
    UsedEquipmentYards.pendingClientItems[#UsedEquipmentYards.pendingClientItems + 1] = {
        yardId          = yardId,
        vehicleObjectId = vehicleObjectId,
        item            = item,
    }
end

--- Remove a client-side item (e.g. after purchase or TTL expiry).
function UsedEquipmentYards.removeClientItem(yardId, vehicleObjectId)
    -- Drop any still-pending entry so it can't register after removal.
    local pending = UsedEquipmentYards.pendingClientItems
    for i = #pending, 1, -1 do
        if pending[i].yardId == yardId and pending[i].vehicleObjectId == vehicleObjectId then
            table.remove(pending, i)
        end
    end

    local yardItems = UsedEquipmentYards.clientItems[yardId]
    if yardItems == nil then return end
    local item = yardItems[vehicleObjectId]
    if item == nil then return end

    -- Clean up vehicle state. Skip vehicle calls if it was already deleted (TTL expiry).
    if item.vehicle ~= nil then
        local vehicle = item.vehicle
        if not vehicle.isDeleted then
            PriceTagRenderer.removeTag(vehicle)
            UsedEquipmentYards.restoreLicensePlate(vehicle)
            UsedEquipmentYards.clearVehicleRestrictions(vehicle)
        end

        local activatable = UsedEquipmentYards.clientVehicleActivatables[vehicle]
        if activatable ~= nil then
            g_currentMission.activatableObjectsSystem:removeActivatable(activatable)
            UsedEquipmentYards.clientVehicleActivatables[vehicle] = nil
        end
        UsedEquipmentYards.vehicleToItem[vehicle] = nil
    end

    yardItems[vehicleObjectId] = nil
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

        local si = g_storeManager:getItemByXMLFilename(item.xmlFilename)
        if si ~= nil and si.categoryNames ~= nil and si.categoryNames[1] ~= nil then
            local cat = g_storeManager.categoryByName[si.categoryNames[1]]
            if cat ~= nil then
                box:addLine(g_i18n:getText("uey_hud_category"), cat.title)
            end
        end

        local damagePercent = (item.damage or 0) * 100
        local wearPercent   = (item.wear or 0) * 100
        local hours         = (item.operatingTime or 0) / 3600000

        box:addLine(g_i18n:getText("uey_hud_damage"), ("%.2f %%"):format(damagePercent))
        box:addLine(g_i18n:getText("uey_hud_wear"), ("%.2f %%"):format(wearPercent))
        box:addLine(g_i18n:getText("uey_hud_hours"), ("%.2f"):format(hours))
        box:showNextFrame()
    end)
end

-- ---------------------------------------------------------------------------
-- Update loop — resolve pending client items whose vehicles are now available
-- ---------------------------------------------------------------------------

function UsedEquipmentYards:update(dt)
    -- Old yard buildings/fences are removed shortly after the game starts.
    if UsedEquipmentYards.legacyRemovalTimer ~= nil then
        UsedEquipmentYards.legacyRemovalTimer = UsedEquipmentYards.legacyRemovalTimer - dt
        if UsedEquipmentYards.legacyRemovalTimer <= 0 then
            UsedEquipmentYards.legacyRemovalTimer = nil
            UsedEquipmentYards.removeLegacyPlaceables()
        end
    end

    -- Tick yard inventory timers (e.g. delayed fill after reset).
    if UsedEquipmentYards.yardManager ~= nil then
        for _, yard in pairs(UsedEquipmentYards.yardManager.yards) do
            yard.inventory:update(dt)
        end
    end

    -- Distance-based render culling of yard vehicles (local camera only).
    if g_currentMission:getIsClient() then
        YardVisibility.update(dt)
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
            UsedEquipmentYards.registerClientItem(entry.yardId, entry.vehicleObjectId, entry.item)
            table.remove(pending, i)
        end
        i = i - 1
    end

    -- Retry restrictions for vehicles that weren't fully loaded yet (every 200ms).
    local pendingR = UsedEquipmentYards.pendingClientRestrictions
    if #pendingR > 0 then
        UsedEquipmentYards.restrictionRetryTimer = (UsedEquipmentYards.restrictionRetryTimer or 0) - dt
        if UsedEquipmentYards.restrictionRetryTimer <= 0 then
            UsedEquipmentYards.restrictionRetryTimer = 200
            i = #pendingR
            while i >= 1 do
                local item = pendingR[i]
                if item.vehicle ~= nil and UsedEquipmentYards.applyClientRestrictions(item.vehicle, item) then
                    table.remove(pendingR, i)
                end
                i = i - 1
            end
        end
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
