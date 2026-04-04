-- PlaceableUsedEquipmentYard
-- Custom specialization that turns a simplePlaceable with husbandryFence into
-- a used equipment yard.
--
-- Placement flow:
--   1. Player selects "Used Equipment Yard" from construction menu (sheds)
--   2. Player positions the building — a default 10 m fence square is shown
--   3. After placing, the husbandry brush asks "Customize fence?"
--   4. Player can draw a custom yard boundary or accept the default
--   5. Once the fence flow completes, the yard is created and vehicles spawn
--
-- Timing: onPostFinalizePlacement fires BEFORE the "Customize?" dialog, so we
-- must not create the yard there. Instead we use two triggers:
--   - finishFenceCustomization override  → "Yes" path (player drew custom fence)
--   - onUpdate + raiseActive()           → "No" path  (fires next frame)

PlaceableUsedEquipmentYard = {}

PlaceableUsedEquipmentYard.KEY = "ueyData"
PlaceableUsedEquipmentYard.DEFAULT_HALF_SIZE = 5 -- 10 m default yard

function PlaceableUsedEquipmentYard.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(PlaceableHusbandryFence, specializations)
end

function PlaceableUsedEquipmentYard.registerFunctions(placeableType)
    SpecializationUtil.registerFunction(placeableType, "deleteNavigationMeshPlacementCollision",
        PlaceableUsedEquipmentYard.noOp)
    SpecializationUtil.registerFunction(placeableType, "createNavigationMeshPlacementCollision",
        PlaceableUsedEquipmentYard.noOp)
    SpecializationUtil.registerFunction(placeableType, "createNavigationMeshFromContour",
        PlaceableUsedEquipmentYard.noOpTrue)
    -- Called by ConstructionBrushHusbandry after BOTH "Yes" and "No" paths complete.
    -- We use it as the trigger to create the yard at exactly the right moment.
    SpecializationUtil.registerFunction(placeableType, "getCanCreateMeadow",
        PlaceableUsedEquipmentYard.getCanCreateMeadow)
end

function PlaceableUsedEquipmentYard.registerOverwrittenFunctions(placeableType)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "canBeSold",
        PlaceableUsedEquipmentYard.canBeSold)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "getIsOnOwnedFarmland",
        PlaceableUsedEquipmentYard.getIsOnOwnedFarmland)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "getIsOnFarmland",
        PlaceableUsedEquipmentYard.getIsOnFarmland)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "getOwnerFarmId",
        PlaceableUsedEquipmentYard.getOwnerFarmId)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "setOwnerFarmId",
        PlaceableUsedEquipmentYard.setOwnerFarmId)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "tryFinalizeFence",
        PlaceableUsedEquipmentYard.tryFinalizeFence)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "createDefaultFence",
        PlaceableUsedEquipmentYard.createDefaultFence)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "updateHusbandryFence",
        PlaceableUsedEquipmentYard.updateHusbandryFence)
end

function PlaceableUsedEquipmentYard.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad", PlaceableUsedEquipmentYard)
    SpecializationUtil.registerEventListener(placeableType, "onDelete", PlaceableUsedEquipmentYard)
end

-- ---------------------------------------------------------------------------
-- Stubs & placement overrides
-- ---------------------------------------------------------------------------

function PlaceableUsedEquipmentYard.noOp() end

function PlaceableUsedEquipmentYard.noOpTrue() return true end

--- Block yard demolition if any sale zones are still linked to this yard.
function PlaceableUsedEquipmentYard:canBeSold(superFunc)
    local data = self[PlaceableUsedEquipmentYard.KEY]
    if data ~= nil and data.yardId ~= nil then
        local count = PlaceableUsedEquipmentYard.getConnectedSaleZoneCount(data.yardId)
        if count > 0 then
            return false
        end
    end
    return superFunc(self)
end

--- Count how many placed sale zones are linked to the given yard id.
function PlaceableUsedEquipmentYard.getConnectedSaleZoneCount(yardId)
    local count = 0
    if g_currentMission ~= nil and g_currentMission.placeableSystem ~= nil then
        for _, placeable in pairs(g_currentMission.placeableSystem.placeables) do
            local szData = placeable[PlaceableSaleZone.KEY]
            if szData ~= nil and szData.yardId == yardId then
                count = count + 1
            end
        end
    end
    return count
end

function PlaceableUsedEquipmentYard:getIsOnOwnedFarmland(superFunc, x, y, z, rotY)
    return true
end

function PlaceableUsedEquipmentYard:getIsOnFarmland(superFunc, farmlandId)
    return false
end

function PlaceableUsedEquipmentYard:getOwnerFarmId(superFunc)
    return superFunc(self)
end

function PlaceableUsedEquipmentYard:setOwnerFarmId(superFunc, farmId)
    superFunc(self, farmId)
end

function PlaceableUsedEquipmentYard:tryFinalizeFence(superFunc)
    return true
end

-- ---------------------------------------------------------------------------
-- Default fence: 10 m square in front of placement point
-- ---------------------------------------------------------------------------

function PlaceableUsedEquipmentYard.getYardCorners(rootNode)
    local h = PlaceableUsedEquipmentYard.DEFAULT_HALF_SIZE
    local offsets = {
        { -h, 0 },   -- near-left
        { h, 0 },    -- near-right
        { h, 2 * h }, -- far-right
        { -h, 2 * h }, -- far-left
    }
    local corners = {}
    for _, o in ipairs(offsets) do
        local wx, _, wz = localToWorld(rootNode, o[1], 0, o[2])
        local wy = getTerrainHeightAtWorldPos(g_terrainNode, wx, 0, wz)
        corners[#corners + 1] = { wx, wy, wz }
    end
    return corners
end

function PlaceableUsedEquipmentYard:createDefaultFence(superFunc)
    local spec = self.spec_husbandryFence
    if spec == nil or spec.fence == nil then return end

    spec.previewSegments = {}
    local corners = PlaceableUsedEquipmentYard.getYardCorners(self.rootNode)

    for i = 1, 4 do
        local ni = (i % 4) + 1
        local seg = spec.fence:createNewSegment("SEGMENT")
        seg:setStartPos(corners[i][1], corners[i][2], corners[i][3])
        seg:setEndPos(corners[ni][1], corners[ni][2], corners[ni][3])
        seg:updateMeshes(true, false)
        seg.husbandryFenceIsDefaultSegment = true
        seg.husbandryFenceIsCustomizable = true
        table.insert(spec.previewSegments, seg)
    end

    spec.fenceOrientation = 1
end

function PlaceableUsedEquipmentYard:updateHusbandryFence(superFunc)
    local spec = self.spec_husbandryFence
    if spec == nil or spec.previewSegments == nil or #spec.previewSegments == 0 then
        return true
    end

    local corners = PlaceableUsedEquipmentYard.getYardCorners(self.rootNode)

    for i, seg in ipairs(spec.previewSegments) do
        local ni = (i % 4) + 1
        seg:setStartPos(corners[i][1], corners[i][2], corners[i][3])
        seg:setEndPos(corners[ni][1], corners[ni][2], corners[ni][3])
        if not seg:updateMeshes() then
            return false
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function PlaceableUsedEquipmentYard:onLoad(savegame)
    self[PlaceableUsedEquipmentYard.KEY] = { yardId = nil }

    if savegame ~= nil then
        local key = savegame.key .. ".usedEquipmentYard"
        self[PlaceableUsedEquipmentYard.KEY].yardId = savegame.xmlFile:getInt(key .. "#yardId")
    end
end

--- Called by ConstructionBrushHusbandry:onCustomizableFenceFinished after the
--- fence flow is fully complete — both the "Yes" path (after customization
--- finishes) and the "No" path (player accepted the default fence).
--- We return false (no meadow) but use this as the trigger to create the yard.
function PlaceableUsedEquipmentYard:getCanCreateMeadow()
    if self.isServer then
        PlaceableUsedEquipmentYard.createYardFromCurrentFence(self)
    end
    return false
end

function PlaceableUsedEquipmentYard:onDelete()
    if not self.isServer then return end

    local data = self[PlaceableUsedEquipmentYard.KEY]
    if data == nil or data.yardId == nil then return end

    local manager = UsedEquipmentYards.yardManager
    if manager ~= nil then
        manager:removeYard(data.yardId)
    end
    data.yardId = nil
end

-- ---------------------------------------------------------------------------
-- Yard creation (called once fence flow is complete)
-- ---------------------------------------------------------------------------

function PlaceableUsedEquipmentYard.createYardFromCurrentFence(placeable)
    local data = placeable[PlaceableUsedEquipmentYard.KEY]
    if data.yardId ~= nil then return end -- already created
    data.pendingCreate = false

    local bounds = PlaceableUsedEquipmentYard.calculateBoundsFromFence(placeable)
    if bounds == nil then
        print("[UsedEquipmentYards] WARNING: fence has no segments, cannot create yard.")
        return
    end

    local manager = UsedEquipmentYards.yardManager
    if manager == nil then return end

    local yard = manager:createYard("Yard", bounds)
    data.yardId = yard.id
end

-- ---------------------------------------------------------------------------
-- Savegame persistence
-- ---------------------------------------------------------------------------

function PlaceableUsedEquipmentYard.registerSavegameXMLPaths(schema, basePath)
    schema:register(XMLValueType.INT, basePath .. ".usedEquipmentYard#yardId", "Linked yard id")
end

function PlaceableUsedEquipmentYard:saveToXMLFile(xmlFile, key, usedModNames)
    local data = self[PlaceableUsedEquipmentYard.KEY]
    if data ~= nil and data.yardId ~= nil then
        xmlFile:setInt(key .. ".usedEquipmentYard#yardId", data.yardId)
    end
end

function PlaceableUsedEquipmentYard:loadFromXMLFile(xmlFile, key)
    local data = self[PlaceableUsedEquipmentYard.KEY]
    if data ~= nil then
        data.yardId = xmlFile:getInt(key .. ".usedEquipmentYard#yardId")
    end
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

function PlaceableUsedEquipmentYard.calculateBoundsFromFence(placeable)
    local fence = placeable:getFence()
    if fence == nil then return nil end

    local segments = fence:getSegments()
    if segments == nil or #segments == 0 then return nil end

    -- Build an ordered polygon from fence segment endpoints.
    -- Each segment has a start and end; consecutive segments share endpoints.
    local polygon = {}
    local minX, maxX = math.huge, -math.huge
    local minZ, maxZ = math.huge, -math.huge

    for _, seg in ipairs(segments) do
        local sx, _, sz = seg:getStartPos()
        local ex, _, ez = seg:getEndPos()
        if sx ~= nil and ex ~= nil then
            -- Add start point (avoid near-duplicates with previous end)
            if #polygon == 0 or
                math.abs(polygon[#polygon].x - sx) > 0.01 or
                math.abs(polygon[#polygon].z - sz) > 0.01 then
                polygon[#polygon + 1] = { x = sx, z = sz }
            end
            polygon[#polygon + 1] = { x = ex, z = ez }

            minX = math.min(minX, sx, ex)
            maxX = math.max(maxX, sx, ex)
            minZ = math.min(minZ, sz, ez)
            maxZ = math.max(maxZ, sz, ez)
        end
    end

    if minX == math.huge or #polygon < 3 then return nil end

    local cx = (minX + maxX) * 0.5
    local cz = (minZ + maxZ) * 0.5
    local cy = getTerrainHeightAtWorldPos(g_terrainNode, cx, 0, cz)

    return {
        cx = cx,
        cy = cy,
        cz = cz,
        sizeX = maxX - minX,
        sizeZ = maxZ - minZ,
        polygon = polygon,
        -- First fence click point — used as the "entrance" so spawned vehicles
        -- face toward it.
        anchorX = polygon[1].x,
        anchorZ = polygon[1].z,
    }
end
