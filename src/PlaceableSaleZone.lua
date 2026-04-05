-- PlaceableSaleZone
-- Custom specialization for a vehicle sale zone that must be placed near
-- an existing Used Equipment Yard. Players drive vehicles into the zone,
-- walk up, and interact via an activatable to open a sell dialog.
--
-- Follows the VehicleSellingPoint trigger pattern:
--   - playerTrigger  (PLAYER collision mask)  → add/remove activatable
--   - vehicleTrigger (VEHICLE collision mask)  → track vehicles in range

PlaceableSaleZone = {}

PlaceableSaleZone.KEY = "saleZoneData"
PlaceableSaleZone.DEFAULT_NEAR_YARD_RADIUS = 50

function PlaceableSaleZone.prerequisitesPresent(specializations)
    return true
end

function PlaceableSaleZone.registerXMLPaths(schema, basePath)
    schema:register(XMLValueType.NODE_INDEX, basePath .. ".saleZone#playerTriggerNode", "Player trigger node")
    schema:register(XMLValueType.NODE_INDEX, basePath .. ".saleZone#vehicleTriggerNode", "Vehicle trigger node")
    schema:register(XMLValueType.FLOAT, basePath .. ".saleZone#nearYardRadius", "Max distance to a used equipment yard", PlaceableSaleZone.DEFAULT_NEAR_YARD_RADIUS)
end

function PlaceableSaleZone.registerFunctions(placeableType)
    SpecializationUtil.registerFunction(placeableType, "saleZonePlayerTriggerCallback",
        PlaceableSaleZone.saleZonePlayerTriggerCallback)
    SpecializationUtil.registerFunction(placeableType, "saleZoneVehicleTriggerCallback",
        PlaceableSaleZone.saleZoneVehicleTriggerCallback)
    SpecializationUtil.registerFunction(placeableType, "determineCurrentVehicles",
        PlaceableSaleZone.determineCurrentVehicles)
end

function PlaceableSaleZone.registerOverwrittenFunctions(placeableType)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "getCanBePlacedAt",
        PlaceableSaleZone.getCanBePlacedAt)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "getIsOnOwnedFarmland",
        PlaceableSaleZone.getIsOnOwnedFarmland)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "getIsOnFarmland",
        PlaceableSaleZone.getIsOnFarmland)
end

function PlaceableSaleZone.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad", PlaceableSaleZone)
    SpecializationUtil.registerEventListener(placeableType, "onPostFinalizePlacement", PlaceableSaleZone)
    SpecializationUtil.registerEventListener(placeableType, "onDelete", PlaceableSaleZone)
end

-- ---------------------------------------------------------------------------
-- Placement constraint: must be near a yard
-- ---------------------------------------------------------------------------

function PlaceableSaleZone:getCanBePlacedAt(superFunc, x, y, z, farmId)
    local canBePlaced, errorMessage = superFunc(self, x, y, z, farmId)
    if not canBePlaced then
        return false, errorMessage
    end

    local nearestYard, nearestDist = PlaceableSaleZone.findNearestYard(x, z)
    local data = self[PlaceableSaleZone.KEY]
    local radius = data and data.nearYardRadius or PlaceableSaleZone.DEFAULT_NEAR_YARD_RADIUS

    if nearestYard == nil or nearestDist > radius then
        return false, g_i18n:getText("uey_saleZone_notNearYard")
    end

    return true
end

function PlaceableSaleZone:getIsOnOwnedFarmland(superFunc)
    return true
end

function PlaceableSaleZone:getIsOnFarmland(superFunc, farmlandId)
    return false
end

-- ---------------------------------------------------------------------------
-- Find nearest yard (works on both server and client)
-- ---------------------------------------------------------------------------

function PlaceableSaleZone.findNearestYard(x, z)
    local nearestYard = nil
    local nearestDist = math.huge

    -- Server: use YardManager.
    if UsedEquipmentYards.yardManager ~= nil then
        for _, yard in pairs(UsedEquipmentYards.yardManager.yards) do
            local dx = yard.bounds.cx - x
            local dz = yard.bounds.cz - z
            local dist = math.sqrt(dx * dx + dz * dz)
            if dist < nearestDist then
                nearestDist = dist
                nearestYard = yard
            end
        end
    end

    -- Client: use clientYards.
    for _, yard in pairs(UsedEquipmentYards.clientYards) do
        local dx = yard.bounds.cx - x
        local dz = yard.bounds.cz - z
        local dist = math.sqrt(dx * dx + dz * dz)
        if dist < nearestDist then
            nearestDist = dist
            nearestYard = yard
        end
    end

    return nearestYard, nearestDist
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function PlaceableSaleZone:onLoad(savegame)
    local xmlFile = self.xmlFile
    local data = {}
    data.yardId = nil
    data.nearYardRadius = xmlFile:getValue("placeable.saleZone#nearYardRadius", PlaceableSaleZone.DEFAULT_NEAR_YARD_RADIUS)

    -- Resolve trigger nodes from i3d mappings.
    data.playerTriggerNode = xmlFile:getValue("placeable.saleZone#playerTriggerNode", nil, self.components, self.i3dMappings)
    data.vehicleTriggerNode = xmlFile:getValue("placeable.saleZone#vehicleTriggerNode", nil, self.components, self.i3dMappings)

    data.vehicleShapesInRange = {}
    data.activatable = nil

    self[PlaceableSaleZone.KEY] = data

    -- Set up triggers.
    if data.playerTriggerNode ~= nil then
        addTrigger(data.playerTriggerNode, "saleZonePlayerTriggerCallback", self)
    end
    if data.vehicleTriggerNode ~= nil then
        addTrigger(data.vehicleTriggerNode, "saleZoneVehicleTriggerCallback", self)
    end

    -- Create activatable (added/removed dynamically via player trigger).
    data.activatable = SaleZoneActivatable.new(self)

    if savegame ~= nil then
        local key = savegame.key .. ".saleZone"
        data.yardId = savegame.xmlFile:getInt(key .. "#yardId")
    end
end

function PlaceableSaleZone:onPostFinalizePlacement()
    if not self.isServer then return end
    local data = self[PlaceableSaleZone.KEY]
    if data.yardId ~= nil then return end

    -- Link to nearest yard.
    local x, _, z = getWorldTranslation(self.rootNode)
    local nearestYard = PlaceableSaleZone.findNearestYard(x, z)
    if nearestYard ~= nil then
        data.yardId = nearestYard.id
    end
end

function PlaceableSaleZone:onDelete()
    local data = self[PlaceableSaleZone.KEY]
    if data == nil then return end

    if data.playerTriggerNode ~= nil then
        removeTrigger(data.playerTriggerNode)
        data.playerTriggerNode = nil
    end
    if data.vehicleTriggerNode ~= nil then
        removeTrigger(data.vehicleTriggerNode)
        data.vehicleTriggerNode = nil
    end
    if data.activatable ~= nil then
        g_currentMission.activatableObjectsSystem:removeActivatable(data.activatable)
        data.activatable = nil
    end
end

-- ---------------------------------------------------------------------------
-- Trigger callbacks (VehicleSellingPoint pattern)
-- ---------------------------------------------------------------------------

function PlaceableSaleZone:saleZonePlayerTriggerCallback(triggerId, otherId, onEnter, onLeave, onStay)
    if not (onEnter or onLeave) then return end
    if g_localPlayer == nil or otherId ~= g_localPlayer.rootNode then return end

    local data = self[PlaceableSaleZone.KEY]
    if data == nil or data.activatable == nil then return end

    if onEnter then
        g_currentMission.activatableObjectsSystem:addActivatable(data.activatable)
    elseif onLeave then
        g_currentMission.activatableObjectsSystem:removeActivatable(data.activatable)
    end
end

function PlaceableSaleZone:saleZoneVehicleTriggerCallback(triggerId, otherId, onEnter, onLeave, onStay, otherShapeId)
    if otherShapeId == nil or not (onEnter or onLeave) then return end
    local data = self[PlaceableSaleZone.KEY]
    if data == nil then return end

    if onEnter then
        data.vehicleShapesInRange[otherShapeId] = true
    elseif onLeave then
        data.vehicleShapesInRange[otherShapeId] = nil
    end
end

-- ---------------------------------------------------------------------------
-- Determine current vehicles in the zone
-- ---------------------------------------------------------------------------

function PlaceableSaleZone:determineCurrentVehicles()
    local data = self[PlaceableSaleZone.KEY]
    if data == nil then return {} end

    local vehicles = {}
    local playerFarmId = g_currentMission:getFarmId()
    if playerFarmId == FarmManager.SPECTATOR_FARM_ID then return vehicles end

    for shapeId, inRange in pairs(data.vehicleShapesInRange) do
        if not inRange or not entityExists(shapeId) then
            data.vehicleShapesInRange[shapeId] = nil
        else
            local vehicle = g_currentMission.nodeToObject[shapeId]
            if vehicle ~= nil and vehicle:isa(Vehicle) then
                local rootVehicle = vehicle.rootVehicle
                local subVehicles = rootVehicle:getChildVehicles()
                for _, subVehicle in ipairs(subVehicles) do
                    if subVehicle:getOwnerFarmId() == playerFarmId then
                        table.addElement(vehicles, subVehicle)
                    end
                end
            end
        end
    end

    return vehicles
end

-- ---------------------------------------------------------------------------
-- Public accessors (used by SaleZoneActivatable)
-- ---------------------------------------------------------------------------

function PlaceableSaleZone.getLinkedYardId(placeable)
    local data = placeable[PlaceableSaleZone.KEY]
    return data and data.yardId
end

-- ---------------------------------------------------------------------------
-- Savegame persistence
-- ---------------------------------------------------------------------------

function PlaceableSaleZone.registerSavegameXMLPaths(schema, basePath)
    schema:register(XMLValueType.INT, basePath .. ".saleZone#yardId", "Linked yard id")
end

function PlaceableSaleZone:saveToXMLFile(xmlFile, key, usedModNames)
    local data = self[PlaceableSaleZone.KEY]
    if data ~= nil and data.yardId ~= nil then
        xmlFile:setInt(key .. ".saleZone#yardId", data.yardId)
    end
end

function PlaceableSaleZone:loadFromXMLFile(xmlFile, key)
    local data = self[PlaceableSaleZone.KEY]
    if data ~= nil then
        data.yardId = xmlFile:getInt(key .. ".saleZone#yardId")
    end
end
