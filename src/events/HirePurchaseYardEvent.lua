HirePurchaseYardEvent = {}
local HirePurchaseYardEvent_mt = Class(HirePurchaseYardEvent, Event)

InitEventClass(HirePurchaseYardEvent, "HirePurchaseYardEvent")

function HirePurchaseYardEvent.emptyNew()
    return Event.new(HirePurchaseYardEvent_mt)
end

function HirePurchaseYardEvent.new(yardId, itemIndex, farmId, leaseDeal)
    local self = HirePurchaseYardEvent.emptyNew()
    self.yardId    = yardId
    self.itemIndex = itemIndex
    self.farmId    = farmId
    self.leaseDeal = leaseDeal
    return self
end

function HirePurchaseYardEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.yardId)
    streamWriteInt32(streamId, self.itemIndex)
    streamWriteInt32(streamId, self.farmId)
    self.leaseDeal:writeStream(streamId, connection)
end

function HirePurchaseYardEvent:readStream(streamId, connection)
    self.yardId    = streamReadInt32(streamId)
    self.itemIndex = streamReadInt32(streamId)
    self.farmId    = streamReadInt32(streamId)
    local env = UsedEquipmentYards.getHirePurchaseEnv()
    self.leaseDeal = env.LeaseDeal.new()
    self.leaseDeal:readStream(streamId, connection)
    self:run(connection)
end

function HirePurchaseYardEvent:run(connection)
    if not connection:getIsServer() then
        -- SERVER: validate, deduct deposit, transfer ownership, register lease deal.
        local manager = UsedEquipmentYards.yardManager
        if manager == nil then return end

        local yard = manager.yards[self.yardId]
        if yard == nil then return end

        local item = yard.inventory.items[self.itemIndex]
        if item == nil then return end

        local farm = g_farmManager:getFarmById(self.farmId)
        if farm == nil then return end

        -- Deduct store credit first.
        local creditAvailable = YardCredit.getBalance(self.farmId, self.yardId)
        local creditUsed = YardCredit.deductCredit(self.farmId, self.yardId, item.price)
        local remainder = item.price - creditUsed

        -- The deposit comes from cash.
        local deposit = self.leaseDeal.deposit
        if farm:getBalance() < deposit then return end

        g_currentMission:addMoneyChange(-deposit, self.farmId, MoneyType.SHOP_VEHICLE_BUY, true)
        farm:changeBalance(-deposit, MoneyType.SHOP_VEHICLE_BUY)

        -- Transfer vehicle ownership.
        local vehicle = item.vehicle
        local vehicleUniqueId = (vehicle ~= nil) and vehicle.uniqueId or ""

        if vehicle ~= nil then
            vehicle:setOwnerFarmId(self.farmId)
            PriceTagRenderer.removeTag(vehicle)
            UsedEquipmentYards.restoreLicensePlate(vehicle)
            UsedEquipmentYards.clearVehicleRestrictions(vehicle)
        end

        -- Register the lease deal with FS25_HirePurchasing.
        self.leaseDeal.farmId = self.farmId
        if vehicle ~= nil then
            self.leaseDeal.objectId = NetworkUtil.getObjectId(vehicle)
            self.leaseDeal.vehicle = vehicle.uniqueId
        end

        g_currentMission.LeasingOptions:registerLeaseDeal(self.leaseDeal)

        -- Record sale.
        UsedEquipmentYards.addRecentSale(vehicleUniqueId, item.price)

        -- Remove from yard inventory (keep vehicle spawned).
        yard.inventory:removeItem(item, true)

        -- Broadcast to all clients.
        g_server:broadcastEvent(HirePurchaseYardEvent.new(
            self.yardId, self.itemIndex, self.farmId, self.leaseDeal))

        -- Also broadcast the lease deal to HirePurchasing clients.
        local env = UsedEquipmentYards.getHirePurchaseEnv()
        if env ~= nil then
            g_server:broadcastEvent(env.NewLeaseDealEvent.new(self.leaseDeal))
        end
        return
    end

    -- CLIENT: clean up local state.
    local manager = UsedEquipmentYards.yardManager
    if manager ~= nil then
        local yard = manager.yards[self.yardId]
        if yard ~= nil then
            local item = yard.inventory.items[self.itemIndex]
            if item ~= nil then
                local vehicle = item.vehicle
                if vehicle ~= nil then
                    PriceTagRenderer.removeTag(vehicle)
                    UsedEquipmentYards.restoreLicensePlate(vehicle)
                    UsedEquipmentYards.clearVehicleRestrictions(vehicle)
                end
                yard.inventory:removeItem(item, true)
            end
        end
    end

    -- Sync deposit deduction on client.
    local deposit = self.leaseDeal.deposit
    if deposit > 0 then
        g_farmManager:getFarmById(self.farmId):changeBalance(-deposit, MoneyType.SHOP_VEHICLE_BUY)
    end

    -- Clean up client item registry.
    UsedEquipmentYards.removeClientItem(self.yardId, self.itemIndex)
end
