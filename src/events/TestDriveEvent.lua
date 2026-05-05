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
    if item.testDrive ~= nil then return end
    if item.testDrivenByFarms ~= nil and item.testDrivenByFarms[self.farmId] then return end

    -- Assign to farm so the player can enter.
    item.vehicle:setOwnerFarmId(self.farmId)

    -- Shared: set testDrive data, remove tag, unlock.
    self:clientStartTestDrive(item)
end

-- ---------------------------------------------------------------------------
-- Server: return test drive
-- ---------------------------------------------------------------------------

function TestDriveEvent:serverReturnTestDrive(item, yard)
    local vehicle = item.vehicle
    local td = item.testDrive
    if td == nil then return end
    if td.farmId ~= self.farmId then return end

    -- Kick out any player currently in the vehicle.
    if vehicle.getIsEntered ~= nil and vehicle:getIsEntered() then
        vehicle:leaveVehicle()
    end

    -- Detach from parent vehicle (e.g. trailer attached to a tractor).
    if vehicle.spec_attachable ~= nil and vehicle.spec_attachable.attacherVehicle ~= nil then
        vehicle.spec_attachable.attacherVehicle:detachImplementByObject(vehicle)
    end

    -- Detach any implements attached to this vehicle.
    if vehicle.spec_attacherJoints ~= nil then
        local implements = vehicle:getAttachedImplements()
        for i = #implements, 1, -1 do
            vehicle:detachImplement(i)
        end
    end

    -- Stop engine and turn off lights before teleporting back.
    if vehicle.stopMotor ~= nil then
        vehicle:stopMotor()
    end
    if vehicle.deactivateLights ~= nil then
        vehicle:deactivateLights()
    end

    -- Remove from physics, teleport, re-add (ensures clean repositioning).
    vehicle:removeFromPhysics()
    vehicle:setAbsolutePosition(td.origX, td.origY, td.origZ, td.origRx, td.origRy, td.origRz)
    vehicle:addToPhysics()

    -- Top up fuel to minimum so Motorized:onPostLoad won't charge farmId 0 on reload.
    -- addFillUnitFillLevel does not charge money — farmId is only used for access checks
    -- on negative deltas, so passing self.farmId here has no financial effect.
    if vehicle.getConsumerFillUnitIndex ~= nil then
        local minFrac = YardInventory.FUEL_MIN
        local fuelTypes = { FillType.DIESEL, FillType.ELECTRICCHARGE, FillType.METHANE }
        for _, fillType in ipairs(fuelTypes) do
            local fillUnitIndex = vehicle:getConsumerFillUnitIndex(fillType)
            if fillUnitIndex ~= nil then
                local capacity = vehicle:getFillUnitCapacity(fillUnitIndex)
                local minLevel = capacity * minFrac
                local current = vehicle:getFillUnitFillLevel(fillUnitIndex)
                if current < minLevel then
                    vehicle:addFillUnitFillLevel(self.farmId, fillUnitIndex, minLevel - current, fillType, ToolType.UNDEFINED, nil)
                end
            end
        end
    end

    -- Restore yard ownership.
    vehicle:setOwnerFarmId(0)

    -- Shared: update item state, re-add tag, re-lock.
    self:clientReturnTestDrive(item)
end

-- ---------------------------------------------------------------------------
-- Shared: item state, price tags, and vehicle restrictions.
-- Called from both server and client paths.
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

    PriceTagRenderer.removeTag(vehicle)
    UsedEquipmentYards.clearVehicleRestrictions(vehicle)
    UsedEquipmentYards.setADSExcluded(vehicle, true)
end

function TestDriveEvent:clientReturnTestDrive(item)
    local vehicle = item.vehicle

    if item.testDrivenByFarms == nil then item.testDrivenByFarms = {} end
    item.testDrivenByFarms[self.farmId] = true
    item.testDrive = nil

    PriceTagRenderer.addTag(vehicle, item)
    if vehicle.setIsTabbable ~= nil then vehicle:setIsTabbable(false) end
    if vehicle.registerPlayerVehicleControlAllowedFunction ~= nil then
        vehicle:registerPlayerVehicleControlAllowedFunction(vehicle, function() return false, nil end)
    end
end
