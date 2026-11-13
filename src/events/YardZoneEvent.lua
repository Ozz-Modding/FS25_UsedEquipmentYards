-- YardZoneEvent
-- Client → Server: the yard tool (UeyYardZoneBrush) asks to create a yard
-- from an outline, change a yard's outline, or remove a yard.
--
-- Also used in single player and on the host: the brush always sends through
-- the server connection, and run() does the work when it arrives on the
-- server side. The server re-checks permission and re-validates the outline
-- (YardManager:applyZoneRequest); results reach clients through
-- YardCreatedEvent / YardUpdatedEvent / YardRemovedEvent.

YardZoneEvent = {}
local YardZoneEvent_mt = Class(YardZoneEvent, Event)

InitEventClass(YardZoneEvent, "YardZoneEvent")

YardZoneEvent.OP = { CREATE = 1, UPDATE = 2, DELETE = 3 }

function YardZoneEvent.emptyNew()
    return Event.new(YardZoneEvent_mt)
end

--- op: YardZoneEvent.OP; yardId: target (UPDATE/DELETE); polygon: { {x, z} } (CREATE/UPDATE).
function YardZoneEvent.new(op, yardId, polygon)
    local self = YardZoneEvent.emptyNew()
    self.op = op
    self.yardId = yardId or 0
    self.polygon = polygon or {}
    return self
end

function YardZoneEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId, self.op)
    streamWriteInt32(streamId, self.yardId)
    streamWriteUInt16(streamId, #self.polygon)
    for _, p in ipairs(self.polygon) do
        streamWriteFloat32(streamId, p.x)
        streamWriteFloat32(streamId, p.z)
    end
end

function YardZoneEvent:readStream(streamId, connection)
    self.op = streamReadUInt8(streamId)
    self.yardId = streamReadInt32(streamId)
    local count = streamReadUInt16(streamId)
    self.polygon = {}
    for i = 1, count do
        self.polygon[i] = { x = streamReadFloat32(streamId), z = streamReadFloat32(streamId) }
    end
    self:run(connection)
end

function YardZoneEvent:run(connection)
    if connection:getIsServer() then
        return -- only ever sent to the server
    end
    local manager = UsedEquipmentYards.yardManager
    if manager == nil then
        return
    end
    if not UsedEquipmentYards.isConnectionAdmin(connection) then
        Logging.warning("[UsedEquipmentYards] yard change refused: sender is not an admin")
        return
    end
    local ok, err = manager:applyZoneRequest(self.op, self.yardId, self.polygon)
    if not ok then
        Logging.warning("[UsedEquipmentYards] yard change refused: %s", tostring(err))
    end
end
