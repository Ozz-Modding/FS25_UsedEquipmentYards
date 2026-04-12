EquipmentPurchasedEvent = {}
local EquipmentPurchasedEvent_mt = Class(EquipmentPurchasedEvent, Event)

InitEventClass(EquipmentPurchasedEvent, "EquipmentPurchasedEvent")

function EquipmentPurchasedEvent.emptyNew()
    return Event.new(EquipmentPurchasedEvent_mt)
end

function EquipmentPurchasedEvent.new(yardId, itemIndex, farmId, creditUsed, vehicleUniqueId, purchasePrice)
    local self = EquipmentPurchasedEvent.emptyNew()
    self.yardId          = yardId
    self.itemIndex       = itemIndex
    self.farmId          = farmId
    self.creditUsed      = creditUsed or 0
    self.vehicleUniqueId = vehicleUniqueId or ""
    self.purchasePrice   = purchasePrice or 0
    return self
end

function EquipmentPurchasedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.yardId)
    streamWriteInt32(streamId, self.itemIndex)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.creditUsed)
    streamWriteString(streamId, self.vehicleUniqueId)
    streamWriteInt32(streamId, self.purchasePrice)
end

function EquipmentPurchasedEvent:readStream(streamId, connection)
    self.yardId          = streamReadInt32(streamId)
    self.itemIndex       = streamReadInt32(streamId)
    self.farmId          = streamReadInt32(streamId)
    self.creditUsed      = streamReadInt32(streamId)
    self.vehicleUniqueId = streamReadString(streamId)
    self.purchasePrice   = streamReadInt32(streamId)
    self:run(connection)
end

function EquipmentPurchasedEvent:run(connection)
    if not connection:getIsServer() then
        -- -----------------------------------------------------------------
        -- SERVER: validate, deduct, transfer ownership, apply local cleanup,
        -- then broadcast to any remote clients.
        -- Doing cleanup here (not in the client branch) avoids relying on
        -- the broadcast looping back synchronously in SP.
        -- -----------------------------------------------------------------
        local manager = UsedEquipmentYards.yardManager
        if manager == nil then return end

        local yard = manager.yards[self.yardId]
        if yard == nil then return end

        local item = yard.inventory.items[self.itemIndex]
        if item == nil then return end

        local farm = g_farmManager:getFarmById(self.farmId)
        local creditAvailable = YardCredit.getBalance(self.farmId, self.yardId)
        if farm == nil or (farm:getBalance() + creditAvailable) < item.price then
            return
        end

        -- Deduct credit first, remainder from cash.
        local creditUsed = YardCredit.deductCredit(self.farmId, self.yardId, item.price)
        local cashCost = item.price - creditUsed
        if cashCost > 0 then
            g_currentMission:addMoneyChange(-cashCost, self.farmId, MoneyType.SHOP_VEHICLE_BUY, true)
        end

        local vehicle = item.vehicle
        local vehicleUniqueId = (vehicle ~= nil) and vehicle.uniqueId or ""
        local purchasePrice = item.price

        if vehicle ~= nil then
            vehicle:setOwnerFarmId(self.farmId)
            PriceTagRenderer.removeTag(vehicle)
            EquipmentPurchasedEvent.restoreLicensePlate(vehicle)
            EquipmentPurchasedEvent.clearVehicleRestrictions(vehicle)
        end

        -- Record this sale so resale offers are capped below purchase price.
        UsedEquipmentYards.addRecentSale(vehicleUniqueId, purchasePrice)

        -- Remove from inventory tracking; keepVehicle=true — vehicle stays.
        yard.inventory:removeItem(item, true)

        -- Broadcast so remote multiplayer clients also clean up their state.
        g_server:broadcastEvent(EquipmentPurchasedEvent.new(self.yardId, self.itemIndex, self.farmId, creditUsed, vehicleUniqueId, purchasePrice))
        return
    end

    -- -----------------------------------------------------------------
    -- CLIENT: remote client receiving the broadcast — clean up local state.
    -- -----------------------------------------------------------------

    -- Try server-side inventory first (for SP / listen server).
    local manager = UsedEquipmentYards.yardManager
    if manager ~= nil then
        local yard = manager.yards[self.yardId]
        if yard ~= nil then
            local item = yard.inventory.items[self.itemIndex]
            if item ~= nil then
                local vehicle = item.vehicle
                if vehicle ~= nil then
                    PriceTagRenderer.removeTag(vehicle)
                    EquipmentPurchasedEvent.restoreLicensePlate(vehicle)
                    EquipmentPurchasedEvent.clearVehicleRestrictions(vehicle)
                end
                yard.inventory:removeItem(item, true)
            end
        end
    end

    -- Sync credit deduction on this client.
    if self.creditUsed > 0 then
        YardCredit.deductCredit(self.farmId, self.yardId, self.creditUsed)
    end

    -- Record this sale so resale offers are capped below purchase price.
    if self.vehicleUniqueId ~= "" and self.purchasePrice > 0 then
        UsedEquipmentYards.addRecentSale(self.vehicleUniqueId, self.purchasePrice)
    end

    -- Clean up client-side item registry (remote MP clients).
    UsedEquipmentYards.removeClientItem(self.yardId, self.itemIndex)
end

--- Assign a fresh random license plate. Vehicles spawn with ownerFarmId=0 so
--- spec.licensePlateData is nil at spawn time; there is no original to restore.
--- Mirrors the shop's approach: get random data, then override placementIndex
--- with the vehicle's own preferred placement (getLicensePlateDialogSettings),
--- because the map-level default placement can be NONE on some maps.
function EquipmentPurchasedEvent.restoreLicensePlate(vehicle)
    if vehicle.spec_licensePlates == nil then return end
    if vehicle.setLicensePlatesData == nil then return end
    if not (vehicle.getHasLicensePlates ~= nil and vehicle:getHasLicensePlates()) then return end
    if g_licensePlateManager == nil then return end

    local plateData = g_licensePlateManager:getRandomLicensePlateData()

    -- The map-level default placement can be NONE on some maps, which would
    -- hide all plates. Use the vehicle's own preferred placement instead,
    -- falling back to BOTH if the vehicle XML doesn't specify one.
    local vehiclePlacement = nil
    if vehicle.getLicensePlateDialogSettings ~= nil then
        vehiclePlacement = vehicle:getLicensePlateDialogSettings()
    end
    plateData.placementIndex = vehiclePlacement or LicensePlateManager.PLACEMENT_OPTION.BOTH

    vehicle:setLicensePlatesData(plateData)
end

--- Re-enable driving and Tab cycling on a vehicle previously blocked for yard display.
function EquipmentPurchasedEvent.clearVehicleRestrictions(vehicle)
    -- Driving is blocked via spec_drivable.playerControlAllowedFunctions.
    -- Clear the whole table so no functions can return false.
    if vehicle.spec_drivable ~= nil then
        vehicle.spec_drivable.playerControlAllowedFunctions = {}
        vehicle.spec_drivable.hasPlayerControlAllowedFunctions = false
    end

    if vehicle.setIsTabbable ~= nil then
        vehicle:setIsTabbable(true)
    end
end
