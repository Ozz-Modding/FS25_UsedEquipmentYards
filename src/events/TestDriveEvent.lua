-- TestDriveEvent
-- Client → Server → Broadcast: start or return a test drive.
-- Server validates and performs the action, then broadcasts so all clients
-- update their state (vehicle controls, price tags, activatable text).

TestDriveEvent = {}
local TestDriveEvent_mt = Class(TestDriveEvent, Event)

InitEventClass(TestDriveEvent, "TestDriveEvent")

TestDriveEvent.ACTION_START  = 1
TestDriveEvent.ACTION_RETURN = 2

TestDriveEvent.DURATION_HOURS = 2      -- base loan duration
TestDriveEvent.FINE_PER_HOUR  = 0.01   -- 1% of price per overdue hour
TestDriveEvent.FINE_MINIMUM   = 50     -- minimum fine per hour

function TestDriveEvent.emptyNew()
    return Event.new(TestDriveEvent_mt)
end

function TestDriveEvent.new(yardId, itemIndex, farmId, action)
    local self = TestDriveEvent.emptyNew()
    self.yardId    = yardId
    self.itemIndex = itemIndex
    self.farmId    = farmId
    self.action    = action
    return self
end

function TestDriveEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.yardId)
    streamWriteInt32(streamId, self.itemIndex)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.action)
end

function TestDriveEvent:readStream(streamId, connection)
    self.yardId    = streamReadInt32(streamId)
    self.itemIndex = streamReadInt32(streamId)
    self.farmId    = streamReadInt32(streamId)
    self.action    = streamReadInt32(streamId)
    self:run(connection)
end

function TestDriveEvent:run(connection)
    if not connection:getIsServer() then
        -- SERVER
        local manager = UsedEquipmentYards.yardManager
        if manager == nil then return end
        local yard = manager.yards[self.yardId]
        if yard == nil then return end
        local item = yard.inventory.items[self.itemIndex]
        if item == nil or item.vehicle == nil then return end

        if self.action == TestDriveEvent.ACTION_START then
            self:serverStartTestDrive(item, yard)
        elseif self.action == TestDriveEvent.ACTION_RETURN then
            self:serverReturnTestDrive(item, yard)
        end

        g_server:broadcastEvent(TestDriveEvent.new(self.yardId, self.itemIndex, self.farmId, self.action))
        return
    end

    -- CLIENT: update local state to match.
    -- Try server-side inventory first (SP / listen server), then client items.
    local item = nil
    local manager = UsedEquipmentYards.yardManager
    if manager ~= nil then
        local yard = manager.yards[self.yardId]
        if yard ~= nil then
            item = yard.inventory.items[self.itemIndex]
        end
    end
    if item == nil then
        local clientItems = UsedEquipmentYards.clientItems[self.yardId]
        if clientItems ~= nil then
            item = clientItems[self.itemIndex]
        end
    end
    if item == nil or item.vehicle == nil then return end

    if self.action == TestDriveEvent.ACTION_START then
        self:clientStartTestDrive(item)
    elseif self.action == TestDriveEvent.ACTION_RETURN then
        self:clientReturnTestDrive(item)
    end
end

-- ---------------------------------------------------------------------------
-- Server: start test drive
-- ---------------------------------------------------------------------------

function TestDriveEvent:serverStartTestDrive(item, yard)
    local vehicle = item.vehicle
    if item.testDrive ~= nil then return end  -- already on test drive

    -- Check if this farm has already test-driven this vehicle.
    if item.testDrivenByFarms ~= nil and item.testDrivenByFarms[self.farmId] then return end

    -- Save original position.
    local ox, oy, oz = getWorldTranslation(vehicle.rootNode)
    local rx, ry, rz = getRotation(vehicle.rootNode)

    -- Calculate return deadline: current hour + DURATION, rounded up to next whole hour.
    local env = g_currentMission.environment
    local returnByHour = env.currentHour + TestDriveEvent.DURATION_HOURS + 1
    local returnByDay  = env.currentMonotonicDay
    if returnByHour >= 24 then
        returnByHour = returnByHour - 24
        returnByDay  = returnByDay + 1
    end

    item.testDrive = {
        farmId      = self.farmId,
        returnByDay = returnByDay,
        returnByHour = returnByHour,
        origX = ox, origY = oy, origZ = oz,
        origRx = rx, origRy = ry, origRz = rz,
    }

    -- Temporarily assign to farm and unlock.
    vehicle:setOwnerFarmId(self.farmId)
    PriceTagRenderer.removeTag(vehicle)
    EquipmentPurchasedEvent.clearVehicleRestrictions(vehicle)
end

-- ---------------------------------------------------------------------------
-- Server: return test drive
-- ---------------------------------------------------------------------------

function TestDriveEvent:serverReturnTestDrive(item, yard)
    local vehicle = item.vehicle
    local td = item.testDrive
    if td == nil then return end
    if td.farmId ~= self.farmId then return end  -- not your test drive

    -- Kick out any player currently in the vehicle.
    if vehicle.getIsEntered ~= nil and vehicle:getIsEntered() then
        vehicle:leaveVehicle()
    end

    -- Remove from physics, teleport, re-add (ensures clean repositioning).
    vehicle:removeFromPhysics()
    vehicle:setAbsolutePosition(td.origX, td.origY, td.origZ, td.origRx, td.origRy, td.origRz)
    vehicle:addToPhysics()

    -- Re-lock and restore yard ownership.
    vehicle:setOwnerFarmId(0)
    PriceTagRenderer.addTag(vehicle, item)
    if vehicle.setIsTabbable ~= nil then
        vehicle:setIsTabbable(false)
    end
    if vehicle.registerPlayerVehicleControlAllowedFunction ~= nil then
        vehicle:registerPlayerVehicleControlAllowedFunction(vehicle, function()
            return false, nil
        end)
    end

    -- Record that this farm has used their test drive for this vehicle.
    if item.testDrivenByFarms == nil then item.testDrivenByFarms = {} end
    item.testDrivenByFarms[self.farmId] = true

    item.testDrive = nil
end

-- ---------------------------------------------------------------------------
-- Client: mirror state changes (vehicle ownership/controls already synced
-- via the vehicle system, but we update item.testDrive for UI)
-- ---------------------------------------------------------------------------

function TestDriveEvent:clientStartTestDrive(item)
    local env = g_currentMission.environment
    local returnByHour = env.currentHour + TestDriveEvent.DURATION_HOURS + 1
    local returnByDay  = env.currentMonotonicDay
    if returnByHour >= 24 then
        returnByHour = returnByHour - 24
        returnByDay  = returnByDay + 1
    end

    local vehicle = item.vehicle
    local ox, oy, oz = getWorldTranslation(vehicle.rootNode)
    local rx, ry, rz = getRotation(vehicle.rootNode)

    item.testDrive = {
        farmId       = self.farmId,
        returnByDay  = returnByDay,
        returnByHour = returnByHour,
        origX = ox, origY = oy, origZ = oz,
        origRx = rx, origRy = ry, origRz = rz,
    }
end

function TestDriveEvent:clientReturnTestDrive(item)
    if item.testDrivenByFarms == nil then item.testDrivenByFarms = {} end
    item.testDrivenByFarms[self.farmId] = true
    item.testDrive = nil
end
