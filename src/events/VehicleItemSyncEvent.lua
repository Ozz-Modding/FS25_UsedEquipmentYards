-- VehicleItemSyncEvent
-- Server → Clients: sync a yard vehicle's item data so clients can show
-- the barter dialog, test drive state, etc.
-- Sends the vehicle's network object ID (not the object itself) because
-- during initial client state the vehicle may not be resolved yet.
-- The client stores items as pending and resolves them in the update loop.

VehicleItemSyncEvent = {}
local VehicleItemSyncEvent_mt = Class(VehicleItemSyncEvent, Event)

InitEventClass(VehicleItemSyncEvent, "VehicleItemSyncEvent")

function VehicleItemSyncEvent.emptyNew()
    return Event.new(VehicleItemSyncEvent_mt)
end

function VehicleItemSyncEvent.new(yardId, itemIndex, item)
    local self = VehicleItemSyncEvent.emptyNew()
    self.yardId    = yardId
    self.itemIndex = itemIndex
    self.item      = item
    return self
end

function VehicleItemSyncEvent:writeStream(streamId, connection)
    local item = self.item
    streamWriteInt32(streamId, self.yardId)
    streamWriteInt32(streamId, self.itemIndex)

    -- Vehicle network object ID (resolved by client later).
    local objectId = item.vehicle ~= nil and NetworkUtil.getObjectId(item.vehicle) or 0
    streamWriteInt32(streamId, objectId)

    -- Item data needed by clients.
    streamWriteString(streamId, item.xmlFilename or "")
    streamWriteInt32(streamId, item.price or 0)
    streamWriteInt32(streamId, item.minPrice or item.price)
    streamWriteInt32(streamId, item.numOwners or 1)
    streamWriteInt32(streamId, math.floor((item.damage or 0) * 100))
    streamWriteInt32(streamId, math.floor((item.wear or 0) * 100))
    streamWriteInt32(streamId, math.floor((item.operatingTime or 0) / 1000))

    -- Test drive state.
    local td = item.testDrive
    streamWriteBool(streamId, td ~= nil)
    if td ~= nil then
        streamWriteInt32(streamId, td.farmId)
        streamWriteInt32(streamId, td.returnByDay)
        streamWriteInt32(streamId, td.returnByHour)
        streamWriteFloat32(streamId, td.origX)
        streamWriteFloat32(streamId, td.origY)
        streamWriteFloat32(streamId, td.origZ)
        streamWriteFloat32(streamId, td.origRx)
        streamWriteFloat32(streamId, td.origRy)
        streamWriteFloat32(streamId, td.origRz)
    end

    -- Test driven history.
    local tdf = item.testDrivenByFarms or {}
    local farms = {}
    for farmId, _ in pairs(tdf) do farms[#farms + 1] = farmId end
    streamWriteInt32(streamId, #farms)
    for _, farmId in ipairs(farms) do
        streamWriteInt32(streamId, farmId)
    end
end

function VehicleItemSyncEvent:readStream(streamId, connection)
    local yardId    = streamReadInt32(streamId)
    local itemIndex = streamReadInt32(streamId)
    local vehicleObjectId = streamReadInt32(streamId)

    local clientItem = {
        xmlFilename   = streamReadString(streamId),
        price         = streamReadInt32(streamId),
        minPrice      = streamReadInt32(streamId),
        numOwners     = streamReadInt32(streamId),
        damage        = streamReadInt32(streamId) / 100,
        wear          = streamReadInt32(streamId) / 100,
        operatingTime = streamReadInt32(streamId) * 1000,
        vehicle       = nil,  -- resolved later
    }

    -- Test drive state.
    if streamReadBool(streamId) then
        clientItem.testDrive = {
            farmId       = streamReadInt32(streamId),
            returnByDay  = streamReadInt32(streamId),
            returnByHour = streamReadInt32(streamId),
            origX  = streamReadFloat32(streamId),
            origY  = streamReadFloat32(streamId),
            origZ  = streamReadFloat32(streamId),
            origRx = streamReadFloat32(streamId),
            origRy = streamReadFloat32(streamId),
            origRz = streamReadFloat32(streamId),
        }
    end

    -- Test driven history.
    local numFarms = streamReadInt32(streamId)
    if numFarms > 0 then
        clientItem.testDrivenByFarms = {}
        for _ = 1, numFarms do
            clientItem.testDrivenByFarms[streamReadInt32(streamId)] = true
        end
    end

    -- Try to resolve the vehicle immediately.
    local vehicle = NetworkUtil.getObject(vehicleObjectId)
    if vehicle ~= nil then
        clientItem.vehicle = vehicle
        UsedEquipmentYards.registerClientItem(yardId, itemIndex, clientItem)
    else
        -- Vehicle not available yet — add to pending list for update-loop resolution.
        UsedEquipmentYards.addPendingClientItem(yardId, itemIndex, vehicleObjectId, clientItem)
    end
end
