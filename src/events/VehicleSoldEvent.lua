-- VehicleSoldEvent
-- Sent by the client when a player sells a vehicle to a yard.
-- Server validates, pays cash, adds credit, deletes vehicle, broadcasts.

VehicleSoldEvent = {}
local VehicleSoldEvent_mt = Class(VehicleSoldEvent, Event)

InitEventClass(VehicleSoldEvent, "VehicleSoldEvent")

function VehicleSoldEvent.emptyNew()
    return Event.new(VehicleSoldEvent_mt)
end

function VehicleSoldEvent.new(yardId, farmId, vehicleId, cashAmount, creditAmount)
    local self = VehicleSoldEvent.emptyNew()
    self.yardId       = yardId
    self.farmId       = farmId
    self.vehicleId    = vehicleId
    self.cashAmount   = cashAmount
    self.creditAmount = creditAmount
    return self
end

function VehicleSoldEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.yardId)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.vehicleId)
    streamWriteInt32(streamId, self.cashAmount)
    streamWriteInt32(streamId, self.creditAmount)
end

function VehicleSoldEvent:readStream(streamId, connection)
    self.yardId       = streamReadInt32(streamId)
    self.farmId       = streamReadInt32(streamId)
    self.vehicleId    = streamReadInt32(streamId)
    self.cashAmount   = streamReadInt32(streamId)
    self.creditAmount = streamReadInt32(streamId)
    self:run(connection)
end

function VehicleSoldEvent:run(connection)
    if not connection:getIsServer() then
        -- -----------------------------------------------------------------
        -- SERVER: validate, pay, delete vehicle, broadcast.
        -- -----------------------------------------------------------------
        local vehicle = NetworkUtil.getObject(self.vehicleId)
        if vehicle == nil then
            return
        end

        -- Validate ownership.
        if vehicle:getOwnerFarmId() ~= self.farmId then
            return
        end

        -- Validate yard exists and would buy this vehicle.
        local manager = UsedEquipmentYards.yardManager
        if manager == nil then return end
        local yard = manager.yards[self.yardId]
        if yard == nil then return end

        if not yard.inventory:wouldBuyVehicle(vehicle) then
            return
        end

        -- Validate amounts are reasonable (within 10% of expected base value).
        local storeItem = g_storeManager:getItemByXMLFilename(vehicle.configFileName)
        if storeItem ~= nil then
            local baseValue = Vehicle.calculateSellPrice(
                storeItem, vehicle.age, vehicle.operatingTime,
                vehicle:getPrice(), vehicle:getRepairPrice(), vehicle:getRepaintPrice())
            local totalOffered = self.cashAmount + self.creditAmount
            if totalOffered > baseValue * 1.10 then
                return
            end
        end

        -- Pay cash (server: stat tracking + balance).
        if self.cashAmount > 0 then
            g_currentMission:addMoneyChange(self.cashAmount, self.farmId, MoneyType.SHOP_VEHICLE_SELL, true)
            g_farmManager:getFarmById(self.farmId):changeBalance(self.cashAmount, MoneyType.SHOP_VEHICLE_SELL)
        end

        -- Add credit.
        if self.creditAmount > 0 then
            YardCredit.addCredit(self.farmId, self.yardId, self.creditAmount)
        end

        -- Transfer vehicle to yard inventory (or queue if no room).
        local purchasePrice = self.cashAmount + self.creditAmount
        yard.inventory:acceptSoldVehicle(vehicle, purchasePrice)

        -- Broadcast to remote clients.
        g_server:broadcastEvent(VehicleSoldEvent.new(
            self.yardId, self.farmId, self.vehicleId, self.cashAmount, self.creditAmount))
        return
    end

    -- -----------------------------------------------------------------
    -- CLIENT: remote client receiving broadcast — sync balance and credit.
    -- Vehicle transfer/deletion is handled by the server + broadcastEvent.
    -- -----------------------------------------------------------------
    if self.cashAmount > 0 then
        g_farmManager:getFarmById(self.farmId):changeBalance(self.cashAmount, MoneyType.SHOP_VEHICLE_SELL)
    end
    if self.creditAmount > 0 then
        YardCredit.addCredit(self.farmId, self.yardId, self.creditAmount)
    end
end
