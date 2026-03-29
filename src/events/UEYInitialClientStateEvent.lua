-- UEYInitialClientStateEvent
-- Sent by the server to a client joining mid-game so they receive the full
-- list of existing yards and can register them locally (activatables, etc.).

UEYInitialClientStateEvent = {}
local UEYInitialClientStateEvent_mt = Class(UEYInitialClientStateEvent, Event)

InitEventClass(UEYInitialClientStateEvent, "UEYInitialClientStateEvent")

function UEYInitialClientStateEvent.emptyNew()
    return Event.new(UEYInitialClientStateEvent_mt)
end

function UEYInitialClientStateEvent.new()
    return UEYInitialClientStateEvent.emptyNew()
end

function UEYInitialClientStateEvent:writeStream(streamId, connection)
    local manager = UsedEquipmentYards.yardManager
    local yards   = (manager ~= nil) and manager.yards or {}

    -- Write yard count then each yard's data.
    local count = 0
    for _ in pairs(yards) do count = count + 1 end
    streamWriteInt32(streamId, count)

    for _, yard in pairs(yards) do
        streamWriteInt32(streamId,   yard.id)
        streamWriteString(streamId,  yard.name)
        streamWriteFloat32(streamId, yard.bounds.cx)
        streamWriteFloat32(streamId, yard.bounds.cy)
        streamWriteFloat32(streamId, yard.bounds.cz)
        streamWriteFloat32(streamId, yard.bounds.sizeX)
        streamWriteFloat32(streamId, yard.bounds.sizeZ)

        local poly      = yard.bounds.polygon
        local vertCount = (poly ~= nil) and #poly or 0
        streamWriteInt32(streamId, vertCount)
        if poly ~= nil then
            for _, pt in ipairs(poly) do
                streamWriteFloat32(streamId, pt.x)
                streamWriteFloat32(streamId, pt.z)
            end
        end
    end
end

function UEYInitialClientStateEvent:readStream(streamId, connection)
    local count = streamReadInt32(streamId)

    for _ = 1, count do
        local yardId   = streamReadInt32(streamId)
        local yardName = streamReadString(streamId)
        local bounds   = {
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
            bounds.polygon = poly
        end

        UsedEquipmentYards.registerClientYard(yardId, yardName, bounds)
    end

    self:run(connection)
end

function UEYInitialClientStateEvent:run(connection)
    -- Nothing extra needed after registration.
end
