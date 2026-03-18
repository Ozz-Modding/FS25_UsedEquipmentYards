-- FS25_UsedEquipmentYards
-- Author: Ozz
-- Entry point: registered as a mod event listener

UsedEquipmentYards = {}
UsedEquipmentYards.dir     = g_currentModDirectory
UsedEquipmentYards.modName = g_currentModName

function UsedEquipmentYards:loadMap(filename)
    if g_currentMission:getIsServer() then
        self.yardManager = YardManager.new(self)
        self.yardManager:load()
    end

    if g_addCheatCommands then
        self:registerConsoleCommands()
    end
end

function UsedEquipmentYards:delete()
    self:unregisterConsoleCommands()
    if self.yardManager ~= nil then
        self.yardManager:delete()
        self.yardManager = nil
    end
end

-- ---------------------------------------------------------------------------
-- Console commands (dev/debug only)
-- ---------------------------------------------------------------------------

function UsedEquipmentYards:registerConsoleCommands()
    addConsoleCommand("ueyListYards",      "List all defined yards",                       "consoleListYards",      self)
    addConsoleCommand("ueyRemoveYard",     "Remove a yard by ID: ueyRemoveYard <id>",      "consoleRemoveYard",     self)
    addConsoleCommand("ueyResetInventory", "Reset inventory: ueyResetInventory [id|all]",  "consoleResetInventory", self)
end

function UsedEquipmentYards:unregisterConsoleCommands()
    removeConsoleCommand("ueyListYards")
    removeConsoleCommand("ueyRemoveYard")
    removeConsoleCommand("ueyResetInventory")
end

function UsedEquipmentYards:consoleListYards()
    if self.yardManager == nil then return "YardManager not active (server only)." end
    return self.yardManager:getYardListString()
end

function UsedEquipmentYards:consoleRemoveYard(id)
    if self.yardManager == nil then return "YardManager not active (server only)." end
    if id == nil then return "Usage: ueyRemoveYard <id>" end
    return self.yardManager:removeYard(tonumber(id))
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

-- Patch fence construction brushes so yard fence posts can be placed on any land.
-- Two checks need bypassing:
--   1. ConstructionBrush:verifyAccess — checks canFarmAccessLand (runs every frame + on click)
--   2. ConstructionBrushNewFence:validateCurrentSegment — checks getIsOwnedByFarmAlongLine
-- Both hardcode farmland ownership checks that our placeable overrides cannot reach.

local function isYardFenceBrush(brush)
    return brush.fenceParentObject ~= nil
       and brush.fenceParentObject[PlaceableUsedEquipmentYard.KEY] ~= nil
end

if ConstructionBrush ~= nil then
    ConstructionBrush.verifyAccess = Utils.overwrittenFunction(
        ConstructionBrush.verifyAccess,
        function(self, superFunc, x, y, z)
            if isYardFenceBrush(self) then
                return nil -- nil = no error, access granted
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

-- ---------------------------------------------------------------------------
-- Vehicle → yard item lookup (populated by YardInventory on spawn)
-- ---------------------------------------------------------------------------

UsedEquipmentYards.vehicleToItem = {}

function UsedEquipmentYards.findItemForVehicle(vehicle)
    return UsedEquipmentYards.vehicleToItem[vehicle]
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

        local damagePercent = math.floor((item.damage or 0) * 100)
        local wearPercent   = math.floor((item.wear   or 0) * 100)
        local hours         = math.floor((item.operatingTime or 0) / 3600000)

        box:addLine(g_i18n:getText("uey_hud_damage"), ("%d %%"):format(damagePercent))
        box:addLine(g_i18n:getText("uey_hud_wear"),   ("%d %%"):format(wearPercent))
        box:addLine(g_i18n:getText("uey_hud_hours"),   tostring(hours))
        box:showNextFrame()
    end)
end

addModEventListener(UsedEquipmentYards)
