-- YardUpdatedEvent
-- Server → Clients: a yard's outline changed (redrawn with the yard tool).
-- In SP / on the host the server's own yard object is already updated, and
-- broadcastEvent doesn't loop back, so only remote clients run this.

YardUpdatedEvent = {}
local YardUpdatedEvent_mt = Class(YardUpdatedEvent, Event)

InitEventClass(YardUpdatedEvent, "YardUpdatedEvent")

function YardUpdatedEvent.emptyNew()
    return Event.new(YardUpdatedEvent_mt)
end

function YardUpdatedEvent.new(yard)
    local self = YardUpdatedEvent.emptyNew()
    self.yardId = yard.id
    self.bounds = yard.bounds
    return self
end

function YardUpdatedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.yardId)
    UsedEquipmentYard.writeBoundsStream(streamId, self.bounds)
end

function YardUpdatedEvent:readStream(streamId, connection)
    self.yardId = streamReadInt32(streamId)
    self.bounds = UsedEquipmentYard.readBoundsStream(streamId)
    self:run(connection)
end

function YardUpdatedEvent:run(connection)
    UsedEquipmentYards.updateClientYardBounds(self.yardId, self.bounds)
end
