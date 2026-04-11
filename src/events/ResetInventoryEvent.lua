-- ResetInventoryEvent
-- Client → Server: admin requests an inventory reset for one or all yards.
-- Server-only action — no broadcast needed (vehicles are engine-managed,
-- new spawns will broadcast VehicleItemSyncEvent as they load).

ResetInventoryEvent = {}
local ResetInventoryEvent_mt = Class(ResetInventoryEvent, Event)

InitEventClass(ResetInventoryEvent, "ResetInventoryEvent")

function ResetInventoryEvent.emptyNew()
    return Event.new(ResetInventoryEvent_mt)
end

--- yardId = -1 means reset all yards.
function ResetInventoryEvent.new(yardId)
    local self = ResetInventoryEvent.emptyNew()
    self.yardId = yardId
    return self
end

function ResetInventoryEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.yardId)
end

function ResetInventoryEvent:readStream(streamId, connection)
    self.yardId = streamReadInt32(streamId)
    self:run(connection)
end

function ResetInventoryEvent:run(connection)
    if not connection:getIsServer() then
        -- SERVER: validate and execute.
        local manager = UsedEquipmentYards.yardManager
        if manager == nil then return end

        if self.yardId == -1 then
            manager:resetAllInventories()
        else
            manager:resetInventory(self.yardId)
        end
    end
end
