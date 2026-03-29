YardRemovedEvent = {}
local YardRemovedEvent_mt = Class(YardRemovedEvent, Event)

InitEventClass(YardRemovedEvent, "YardRemovedEvent")

function YardRemovedEvent.emptyNew()
    return Event.new(YardRemovedEvent_mt)
end

function YardRemovedEvent.new(yardId)
    local self = YardRemovedEvent.emptyNew()
    self.yardId = yardId
    return self
end

function YardRemovedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.yardId)
end

function YardRemovedEvent:readStream(streamId, connection)
    self.yardId = streamReadInt32(streamId)
    self:run(connection)
end

-- Called on remote clients when the server broadcasts a yard removal.
-- In SP this is never invoked (no remote clients to broadcast to).
function YardRemovedEvent:run(connection)
    UsedEquipmentYards.unregisterClientYard(self.yardId)
end
