-- PriceTagRenderer
-- Places a physical sign model on the ground in front of each yard vehicle
-- and renders the price text on it using renderText3D.
-- Client-side only — hooks into FSBaseMission.draw each frame.
--
-- The sign i3d (i3d/priceSign.i3d) is loaded once, then cloned per vehicle.
-- Each clone is positioned on the terrain in front of the vehicle, facing
-- outward so it's readable as you approach.

PriceTagRenderer = {}

-- Path to the sign i3d relative to the mod directory.
PriceTagRenderer.SIGN_I3D = "i3d/priceSign.i3d"

-- How far in front of the vehicle to place the sign (metres).
PriceTagRenderer.SIGN_FORWARD_OFFSET = 3.0

-- Display configuration (matches XtraSmallDisplay layout).
-- The displayStartPoint is at the top-left of the display area.
PriceTagRenderer.TEXT_SIZE  = 0.09
PriceTagRenderer.TEXT_COLOR = { 1, 1, 0, 1 }     -- yellow
PriceTagRenderer.DISPLAY_WIDTH  = 1.89            -- from the i3d
PriceTagRenderer.DISPLAY_HEIGHT = 0.31            -- from the i3d

-- Distance culling.
PriceTagRenderer.MAX_DISTANCE    = 30
PriceTagRenderer.MAX_DISTANCE_SQ = PriceTagRenderer.MAX_DISTANCE * PriceTagRenderer.MAX_DISTANCE

-- State.
PriceTagRenderer.tags = {}
PriceTagRenderer.signTemplateNode = nil      -- loaded i3d root (hidden)
PriceTagRenderer.sharedLoadRequestId = nil

-- ---------------------------------------------------------------------------
-- I3D loading
-- ---------------------------------------------------------------------------

--- Load the sign i3d once. Called from main.lua on loadMap.
function PriceTagRenderer.load()
    local filename = UsedEquipmentYards.dir .. PriceTagRenderer.SIGN_I3D
    local rootNode, sharedLoadRequestId = g_i3DManager:loadSharedI3DFile(filename, false, false)
    if rootNode == nil or rootNode == 0 then
        Logging.warning("[UsedEquipmentYards] Failed to load price sign i3d.")
        return
    end
    PriceTagRenderer.sharedLoadRequestId = sharedLoadRequestId
    -- Hide the template; we'll clone it per vehicle.
    setVisibility(rootNode, false)
    PriceTagRenderer.signTemplateNode = rootNode
end

--- Clean up on mod unload.
function PriceTagRenderer.delete()
    PriceTagRenderer.removeAllTags()
    if PriceTagRenderer.signTemplateNode ~= nil then
        delete(PriceTagRenderer.signTemplateNode)
        PriceTagRenderer.signTemplateNode = nil
    end
    if PriceTagRenderer.sharedLoadRequestId ~= nil then
        g_i3DManager:releaseSharedI3DFile(PriceTagRenderer.sharedLoadRequestId)
        PriceTagRenderer.sharedLoadRequestId = nil
    end
end

-- ---------------------------------------------------------------------------
-- Node search helper
-- ---------------------------------------------------------------------------

function PriceTagRenderer.findNodeByName(rootNode, name)
    local numChildren = getNumOfChildren(rootNode)
    for i = 0, numChildren - 1 do
        local child = getChildAt(rootNode, i)
        if getName(child) == name then
            return child
        end
        local found = PriceTagRenderer.findNodeByName(child, name)
        if found ~= nil then
            return found
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Tag registration
-- ---------------------------------------------------------------------------

--- Place a sign in front of the vehicle and register it for text rendering.
function PriceTagRenderer.addTag(vehicle, item)
    if PriceTagRenderer.signTemplateNode == nil then return end

    -- Clone the sign model.
    local signNode = clone(PriceTagRenderer.signTemplateNode, true)
    setVisibility(signNode, true)

    -- Position: in front of the vehicle, on the terrain.
    local vx, _, vz = getWorldTranslation(vehicle.rootNode)
    local _, vry, _ = getWorldRotation(vehicle.rootNode)

    -- Vehicle forward direction (local +Z in GIANTS).
    local fwdX, _, fwdZ = localDirectionToWorld(vehicle.rootNode, 0, 0, 1)
    local fLen = math.sqrt(fwdX * fwdX + fwdZ * fwdZ)
    if fLen > 0.001 then
        fwdX, fwdZ = fwdX / fLen, fwdZ / fLen
    end

    local offset = PriceTagRenderer.SIGN_FORWARD_OFFSET
    local sx = vx + fwdX * offset
    local sz = vz + fwdZ * offset
    local sy = getTerrainHeightAtWorldPos(g_terrainNode, sx, 0, sz)

    -- Link to scene root so it persists.
    link(getRootNode(), signNode)

    -- Position the sign and rotate it to face toward the vehicle's front
    -- (same yaw as the vehicle, so the text faces the approaching player).
    setTranslation(signNode, sx, sy, sz)
    setRotation(signNode, 0, vry, 0)

    -- Find the displayStartPoint inside the cloned sign.
    local displayNode = PriceTagRenderer.findNodeByName(signNode, "displayStartPoint")

    -- Pre-compute text position (single centered line).
    local textX, textY, textZ, textRx, textRy, textRz
    if displayNode ~= nil then
        -- Center of the display area: half width right, half height down from upper-left.
        textX, textY, textZ = localToWorld(displayNode,
            PriceTagRenderer.DISPLAY_WIDTH * 0.5,
            -PriceTagRenderer.DISPLAY_HEIGHT * 0.5,
            0)
        textRx, textRy, textRz = getWorldRotation(displayNode)
    end

    local tag = {
        vehicle     = vehicle,
        item        = item,
        signNode    = signNode,
        displayNode = displayNode,
        textX       = textX,
        textY       = textY,
        textZ       = textZ,
        textRx      = textRx,
        textRy      = textRy,
        textRz      = textRz,
    }

    PriceTagRenderer.tags[vehicle] = tag
end

--- Remove a vehicle's sign and price tag.
function PriceTagRenderer.removeTag(vehicle)
    local tag = PriceTagRenderer.tags[vehicle]
    if tag ~= nil then
        if tag.signNode ~= nil then
            delete(tag.signNode)
        end
        PriceTagRenderer.tags[vehicle] = nil
    end
end

--- Remove all signs and tags.
function PriceTagRenderer.removeAllTags()
    for vehicle, tag in pairs(PriceTagRenderer.tags) do
        if tag.signNode ~= nil then
            delete(tag.signNode)
        end
    end
    PriceTagRenderer.tags = {}
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

--- Called each frame from FSBaseMission.draw. Renders price text on all signs.
function PriceTagRenderer.draw()
    local tags = PriceTagRenderer.tags
    if next(tags) == nil then return end

    local player = g_localPlayer
    if player == nil or player.rootNode == nil or player.rootNode == 0 then return end
    local px, _, pz = getWorldTranslation(player.rootNode)

    local textSize  = PriceTagRenderer.TEXT_SIZE
    local color     = PriceTagRenderer.TEXT_COLOR
    local maxDistSq = PriceTagRenderer.MAX_DISTANCE_SQ

    for _, tag in pairs(tags) do
        if tag.displayNode ~= nil then
            local dx, dz = tag.textX - px, tag.textZ - pz
            if dx * dx + dz * dz <= maxDistSq then
                local priceText = g_i18n:formatMoney(tag.item.price, 0, true, true)
                setTextColor(color[1], color[2], color[3], color[4])
                setTextAlignment(RenderText.ALIGN_CENTER)
                setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_MIDDLE)
                renderText3D(tag.textX, tag.textY, tag.textZ,
                             tag.textRx, tag.textRy, tag.textRz,
                             textSize, priceText)
            end
        end
    end
end
