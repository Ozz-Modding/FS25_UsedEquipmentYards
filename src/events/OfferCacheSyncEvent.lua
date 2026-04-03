-- OfferCacheSyncEvent
-- Broadcasts cached sell offers to all clients so farm members see the same
-- offers within the TTL window. Sent when a player generates new offers.
-- Uses objectId on the wire; each client resolves to uniqueId for local caching.

OfferCacheSyncEvent = {}
local OfferCacheSyncEvent_mt = Class(OfferCacheSyncEvent, Event)

InitEventClass(OfferCacheSyncEvent, "OfferCacheSyncEvent")

function OfferCacheSyncEvent.emptyNew()
    return Event.new(OfferCacheSyncEvent_mt)
end

function OfferCacheSyncEvent.new(vehicleObjectId, offers, day, hour)
    local self = OfferCacheSyncEvent.emptyNew()
    self.vehicleObjectId = vehicleObjectId
    self.offers          = offers -- { {cash,credit}, {cash,credit}, {cash,credit} }
    self.day             = day
    self.hour            = hour
    return self
end

function OfferCacheSyncEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.vehicleObjectId)
    streamWriteInt32(streamId, self.day)
    streamWriteInt32(streamId, self.hour)
    streamWriteInt32(streamId, #self.offers)
    for _, offer in ipairs(self.offers) do
        streamWriteInt32(streamId, offer.cash)
        streamWriteInt32(streamId, offer.credit)
    end
end

function OfferCacheSyncEvent:readStream(streamId, connection)
    self.vehicleObjectId = streamReadInt32(streamId)
    self.day             = streamReadInt32(streamId)
    self.hour            = streamReadInt32(streamId)
    local count          = streamReadInt32(streamId)
    self.offers = {}
    for _ = 1, count do
        self.offers[#self.offers + 1] = {
            cash   = streamReadInt32(streamId),
            credit = streamReadInt32(streamId),
        }
    end
    self:run(connection)
end

function OfferCacheSyncEvent:run(connection)
    if not connection:getIsServer() then
        -- SERVER receiving from client: broadcast to all clients.
        g_server:broadcastEvent(OfferCacheSyncEvent.new(
            self.vehicleObjectId, self.offers, self.day, self.hour))
        return
    end

    -- CLIENT receiving broadcast: resolve objectId → vehicle → uniqueId → cache.
    SellBarterDialog.cacheFromNetwork(self.vehicleObjectId, self.offers, self.day, self.hour)
end
