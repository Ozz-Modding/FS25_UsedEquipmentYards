-- BarterAttemptEvent
-- Client → Server → Broadcast: sync barter attempt usage so all clients
-- on the same farm see an accurate remaining-chances count.

BarterAttemptEvent = {}
local BarterAttemptEvent_mt = Class(BarterAttemptEvent, Event)

InitEventClass(BarterAttemptEvent, "BarterAttemptEvent")

function BarterAttemptEvent.emptyNew()
    return Event.new(BarterAttemptEvent_mt)
end

function BarterAttemptEvent.new(farmId, yardId)
    local self = BarterAttemptEvent.emptyNew()
    self.farmId = farmId
    self.yardId = yardId
    return self
end

function BarterAttemptEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.yardId)
end

function BarterAttemptEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.yardId = streamReadInt32(streamId)
    self:run(connection)
end

function BarterAttemptEvent:run(connection)
    if not connection:getIsServer() then
        -- SERVER: record attempt and broadcast to all clients.
        BarterState.recordAttempt(self.farmId, self.yardId)
        g_server:broadcastEvent(BarterAttemptEvent.new(self.farmId, self.yardId))
        return
    end

    -- CLIENT: apply the attempt locally.
    BarterState.recordAttempt(self.farmId, self.yardId)
end
