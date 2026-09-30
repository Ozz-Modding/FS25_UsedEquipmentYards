-- YardVisibility
-- Client-side render culling for yard vehicles. Each machine hides for-sale yard
-- vehicles further than the chosen distance from its own active camera. Visibility
-- is local only: physics, networking and other players' views are unaffected, so
-- in multiplayer every player culls independently based on where they are.
--
-- The preference is per machine (a graphics/performance choice), stored in
-- <userProfile>/modSettings/FS25_UsedEquipmentYards.xml rather than the savegame.

YardVisibility = {}

-- Selectable limits in metres. 0 = off (default).
YardVisibility.DISTANCES      = { 0, 200, 300, 400, 500, 600, 700, 800, 900, 1000 }
YardVisibility.CHECK_INTERVAL = 500 -- ms between distance checks
YardVisibility.HYSTERESIS     = 10  -- metres beyond the limit before hiding, to stop flicker at the edge

YardVisibility.SETTINGS_DIR  = getUserProfileAppPath() .. "modSettings/"
YardVisibility.SETTINGS_FILE = YardVisibility.SETTINGS_DIR .. "FS25_UsedEquipmentYards.xml"

YardVisibility.maxDistance = 0
YardVisibility.timer       = 0
-- Vehicles we hid: { [vehicle] = true }. We only ever show vehicles in this set,
-- so vehicles hidden by anything else (e.g. sold vehicles waiting for yard space,
-- or MP vehicles still loading) are never revealed by us.
YardVisibility.culled      = {}

function YardVisibility.loadSettings()
    local xmlFile = XMLFile.loadIfExists("ueySettings", YardVisibility.SETTINGS_FILE)
    if xmlFile == nil then return end
    YardVisibility.maxDistance = xmlFile:getInt("ueySettings#viewDistance", 0)
    xmlFile:delete()
end

function YardVisibility.saveSettings()
    createFolder(YardVisibility.SETTINGS_DIR)
    local xmlFile = XMLFile.create("ueySettings", YardVisibility.SETTINGS_FILE, "ueySettings")
    if xmlFile == nil then return end
    xmlFile:setInt("ueySettings#viewDistance", YardVisibility.maxDistance)
    xmlFile:save()
    xmlFile:delete()
end

function YardVisibility.setMaxDistance(distance)
    YardVisibility.maxDistance = distance or 0
    YardVisibility.timer = 0 -- apply on the next update
    YardVisibility.saveSettings()
end

function YardVisibility.getStateIndex()
    for i, d in ipairs(YardVisibility.DISTANCES) do
        if d == YardVisibility.maxDistance then return i end
    end
    return 1
end

local function setCulled(vehicle, culled)
    vehicle:setVisibility(not culled)
    YardVisibility.culled[vehicle] = culled or nil
end

--- Reveal everything we hid (setting turned off or mission ending).
function YardVisibility.showAll()
    for vehicle in pairs(YardVisibility.culled) do
        if not vehicle.isDeleted then
            vehicle:setVisibility(true)
        end
    end
    YardVisibility.culled = {}
end

function YardVisibility.update(dt)
    YardVisibility.timer = YardVisibility.timer - dt
    if YardVisibility.timer > 0 then return end
    YardVisibility.timer = YardVisibility.CHECK_INTERVAL

    if YardVisibility.maxDistance <= 0 then
        if next(YardVisibility.culled) ~= nil then
            YardVisibility.showAll()
        end
        return
    end

    local camera = g_cameraManager ~= nil and g_cameraManager:getActiveCamera() or nil
    if camera == nil or camera == 0 then return end
    local camX, _, camZ = getWorldTranslation(camera)

    local showDistSq = YardVisibility.maxDistance * YardVisibility.maxDistance
    local hideDist   = YardVisibility.maxDistance + YardVisibility.HYSTERESIS
    local hideDistSq = hideDist * hideDist

    -- Release vehicles that left the yard (purchased, deleted, TTL expiry).
    for vehicle in pairs(YardVisibility.culled) do
        local item = UsedEquipmentYards.vehicleToItem[vehicle]
        if vehicle.isDeleted then
            YardVisibility.culled[vehicle] = nil
        elseif item == nil or item.testDrive ~= nil then
            setCulled(vehicle, false)
        end
    end

    for vehicle, item in pairs(UsedEquipmentYards.vehicleToItem) do
        if item.testDrive == nil and not vehicle.isDeleted and vehicle.rootNode ~= nil then
            local vx, _, vz = getWorldTranslation(vehicle.rootNode)
            local dx, dz = vx - camX, vz - camZ
            local distSq = dx * dx + dz * dz

            if YardVisibility.culled[vehicle] then
                if distSq <= showDistSq then
                    setCulled(vehicle, false)
                end
            elseif distSq > hideDistSq and getVisibility(vehicle.rootNode) then
                setCulled(vehicle, true)
            end
        end
    end
end
