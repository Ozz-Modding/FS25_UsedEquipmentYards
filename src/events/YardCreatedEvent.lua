-- YardCreatedEvent
-- Broadcast from server to all clients when a new yard is defined.
-- Clients use this to maintain a local copy for future GUI/proximity work.

YardCreatedEvent    = {}
YardCreatedEvent_mt = Class(YardCreatedEvent, Event)
InitEventClass(YardCreatedEvent, "YardCreatedEvent")

function YardCreatedEvent.emptyNew()
    return Event.new(setmetatable({}, YardCreatedEvent_mt))
end

function YardCreatedEvent.new(yard)
    local self  = YardCreatedEvent.emptyNew()
    self.yardId   = yard.id
    self.yardName = yard.name
    self.bounds   = yard.bounds
    return self
end

function YardCreatedEvent:readStream(streamId, connection)
    self.yardId   = streamReadInt32(streamId)
    self.yardName = streamReadString(streamId)
    self.bounds = {
        cx    = streamReadFloat32(streamId),
        cy    = streamReadFloat32(streamId),
        cz    = streamReadFloat32(streamId),
        sizeX = streamReadFloat32(streamId),
        sizeZ = streamReadFloat32(streamId),
    }
    self:run(connection)
end

function YardCreatedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId,  self.yardId)
    streamWriteString(streamId, self.yardName)
    streamWriteFloat32(streamId, self.bounds.cx)
    streamWriteFloat32(streamId, self.bounds.cy)
    streamWriteFloat32(streamId, self.bounds.cz)
    streamWriteFloat32(streamId, self.bounds.sizeX)
    streamWriteFloat32(streamId, self.bounds.sizeZ)
end

function YardCreatedEvent:run(connection)
    -- TODO: register the yard on the client side for proximity/GUI triggers
    if not connection:getIsServer() then
        g_server:broadcastEvent(self)
    end
end
