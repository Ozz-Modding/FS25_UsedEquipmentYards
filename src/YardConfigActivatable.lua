-- YardConfigActivatable
-- Registers with the activatableObjectsSystem so the game's standard
-- "Activate" prompt appears when the player walks inside a yard boundary.
-- run() is called by the system when the player presses the activate key.

YardConfigActivatable = {}
local YardConfigActivatable_mt = Class(YardConfigActivatable)

function YardConfigActivatable.new(yard)
    local self = setmetatable({}, YardConfigActivatable_mt)
    self.yard = yard
    self.activateText = g_i18n:getText("uey_action_configureYard")
    self.isUeyActivatable = true
    return self
end

function YardConfigActivatable:getIsActivatable()
    if self.yard == nil then return false end

    -- Must be on foot.
    if g_localPlayer == nil or g_localPlayer.rootNode == nil then return false end
    if g_localPlayer:getCurrentVehicle() ~= nil then return false end

    -- Must be inside the yard bounds.
    local px, _, pz = getWorldTranslation(g_localPlayer.rootNode)
    if not self.yard:containsPoint(px, pz) then return false end

    -- Yield to other non-UEY activatables (fuel stations, animal triggers, etc.)
    local system = g_currentMission and g_currentMission.activatableObjectsSystem
    if system ~= nil then
        for _, other in pairs(system.objects) do
            if other ~= self and not other.isUeyActivatable then
                local otherActive = other.getIsActivatable == nil or
                    other:getIsActivatable(system.dirX, system.dirY, system.dirZ)
                if otherActive then
                    return false
                end
            end
        end
    end

    return true
end

function YardConfigActivatable:getDistance(x, y, z)
    if self.yard == nil then return math.huge end
    local b = self.yard.bounds
    return MathUtil.vector3Length(x - b.cx, y - (b.cy or 0), z - b.cz) + 0.5
end

function YardConfigActivatable:run()
    if self.yard == nil then return end
    YardConfigDialog.show(self.yard)
end

function YardConfigActivatable:activate()
end

function YardConfigActivatable:deactivate()
end
