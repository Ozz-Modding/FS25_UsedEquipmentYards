-- EquipmentPurchasedEvent
-- Sent from client -> server to request a purchase, then broadcast to all clients.
--
-- Flow:
--   1. Client sends event to server (connection:getIsServer() == false on server side)
--   2. Server validates funds, removes item, transfers vehicle, then broadcasts to all
--   3. All clients receive the event and remove the item node from their display

EquipmentPurchasedEvent    = {}
EquipmentPurchasedEvent_mt = Class(EquipmentPurchasedEvent, Event)
InitEventClass(EquipmentPurchasedEvent, "EquipmentPurchasedEvent")

function EquipmentPurchasedEvent.emptyNew()
    return Event.new(setmetatable({}, EquipmentPurchasedEvent_mt))
end

-- yardId    - id of the yard
-- itemIndex - 1-based index into yard.inventory.items
-- farmId    - purchasing farm's id (for balance deduction)
function EquipmentPurchasedEvent.new(yardId, itemIndex, farmId)
    local self     = EquipmentPurchasedEvent.emptyNew()
    self.yardId    = yardId
    self.itemIndex = itemIndex
    self.farmId    = farmId
    return self
end

function EquipmentPurchasedEvent:readStream(streamId, connection)
    self.yardId    = streamReadInt32(streamId)
    self.itemIndex = streamReadInt32(streamId)
    self.farmId    = streamReadInt32(streamId)
    self:run(connection)
end

function EquipmentPurchasedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.yardId)
    streamWriteInt32(streamId, self.itemIndex)
    streamWriteInt32(streamId, self.farmId)
end

function EquipmentPurchasedEvent:run(connection)
    local manager = UsedEquipmentYards.yardManager
    if manager == nil then return end

    local yard = manager.yards[self.yardId]
    if yard == nil then return end

    local item = yard.inventory.items[self.itemIndex]
    if item == nil then return end

    if not connection:getIsServer() then
        -- Received on server from a client: validate and authorise
        -- TODO: deduct item.price from the farm and load the vehicle for the buyer.
        --   Money:   g_currentMission:addMoneyChange(-item.price, self.farmId, MoneyType.SHOP_VEHICLE_BUY, true)
        --   Vehicle: VehicleLoadingData.new(), :setFilename(), :setOwnerFarmId(), :load(callback)
        --   See FS25_RedTape/src/instances/Scheme.lua:spawnVehicles() for the full pattern.
        yard.inventory:removeItem(item)
        g_server:broadcastEvent(self)
    else
        -- Received on a client from the server: remove visual node
        yard.inventory:removeItem(item)
    end
end
