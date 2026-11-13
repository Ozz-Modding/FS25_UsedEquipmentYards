YardCreatedEvent = {}
local YardCreatedEvent_mt = Class(YardCreatedEvent, Event)

InitEventClass(YardCreatedEvent, "YardCreatedEvent")

function YardCreatedEvent.emptyNew()
    return Event.new(YardCreatedEvent_mt)
end

function YardCreatedEvent.new(yard)
    local self = YardCreatedEvent.emptyNew()
    self.yardId   = yard.id
    self.yardName = yard.name
    self.bounds   = yard.bounds
    return self
end

function YardCreatedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId,   self.yardId)
    streamWriteString(streamId,  self.yardName)
    UsedEquipmentYard.writeBoundsStream(streamId, self.bounds)
end

function YardCreatedEvent:readStream(streamId, connection)
    self.yardId   = streamReadInt32(streamId)
    self.yardName = streamReadString(streamId)
    self.bounds   = UsedEquipmentYard.readBoundsStream(streamId)
    self:run(connection)
end

-- Called on remote clients when the server broadcasts a new yard.
-- In SP this is never invoked (no remote clients to broadcast to).
function YardCreatedEvent:run(connection)
    UsedEquipmentYards.registerClientYard(self.yardId, self.yardName, self.bounds)
end
