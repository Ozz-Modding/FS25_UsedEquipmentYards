-- YardRemovedEvent
-- Broadcast from server to all clients when a yard is deleted.

YardRemovedEvent    = {}
YardRemovedEvent_mt = Class(YardRemovedEvent, Event)
InitEventClass(YardRemovedEvent, "YardRemovedEvent")

function YardRemovedEvent.emptyNew()
    return Event.new(setmetatable({}, YardRemovedEvent_mt))
end

function YardRemovedEvent.new(yardId)
    local self  = YardRemovedEvent.emptyNew()
    self.yardId = yardId
    return self
end

function YardRemovedEvent:readStream(streamId, connection)
    self.yardId = streamReadInt32(streamId)
    self:run(connection)
end

function YardRemovedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.yardId)
end

function YardRemovedEvent:run(connection)
    -- TODO: remove yard from client-side registry
    if not connection:getIsServer() then
        g_server:broadcastEvent(self)
    end
end
