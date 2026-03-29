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
    streamWriteFloat32(streamId, self.bounds.cx)
    streamWriteFloat32(streamId, self.bounds.cy)
    streamWriteFloat32(streamId, self.bounds.cz)
    streamWriteFloat32(streamId, self.bounds.sizeX)
    streamWriteFloat32(streamId, self.bounds.sizeZ)

    -- Stream polygon vertices for accurate containsPoint on clients.
    local poly = self.bounds.polygon
    local vertCount = (poly ~= nil) and #poly or 0
    streamWriteInt32(streamId, vertCount)
    if poly ~= nil then
        for _, pt in ipairs(poly) do
            streamWriteFloat32(streamId, pt.x)
            streamWriteFloat32(streamId, pt.z)
        end
    end
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
    local vertCount = streamReadInt32(streamId)
    if vertCount >= 3 then
        local poly = {}
        for i = 1, vertCount do
            poly[i] = {
                x = streamReadFloat32(streamId),
                z = streamReadFloat32(streamId),
            }
        end
        self.bounds.polygon = poly
    end
    self:run(connection)
end

-- Called on remote clients when the server broadcasts a new yard.
-- In SP this is never invoked (no remote clients to broadcast to).
function YardCreatedEvent:run(connection)
    UsedEquipmentYards.registerClientYard(self.yardId, self.yardName, self.bounds)
end
