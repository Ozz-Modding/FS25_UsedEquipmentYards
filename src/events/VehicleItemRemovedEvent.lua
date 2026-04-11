-- VehicleItemRemovedEvent
-- Server → Clients: notify that a yard vehicle has been removed (TTL expiry,
-- yard reset, etc.). Clients clean up their local item registry and activatables.

VehicleItemRemovedEvent = {}
local VehicleItemRemovedEvent_mt = Class(VehicleItemRemovedEvent, Event)

InitEventClass(VehicleItemRemovedEvent, "VehicleItemRemovedEvent")

function VehicleItemRemovedEvent.emptyNew()
    return Event.new(VehicleItemRemovedEvent_mt)
end

function VehicleItemRemovedEvent.new(yardId, itemIndex)
    local self = VehicleItemRemovedEvent.emptyNew()
    self.yardId    = yardId
    self.itemIndex = itemIndex
    return self
end

function VehicleItemRemovedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.yardId)
    streamWriteInt32(streamId, self.itemIndex)
end

function VehicleItemRemovedEvent:readStream(streamId, connection)
    self.yardId    = streamReadInt32(streamId)
    self.itemIndex = streamReadInt32(streamId)
    self:run(connection)
end

function VehicleItemRemovedEvent:run(connection)
    -- CLIENT only: clean up local item state.
    UsedEquipmentYards.removeClientItem(self.yardId, self.itemIndex)
end
