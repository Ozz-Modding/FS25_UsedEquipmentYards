-- YardVehicleActivatable
-- One instance per spawned yard vehicle. Registered with the
-- activatableObjectsSystem so the player gets a "Barter" prompt when nearby.
-- run() opens the BarterDialog for that vehicle.

YardVehicleActivatable = {}
local YardVehicleActivatable_mt = Class(YardVehicleActivatable)

-- How close (metres) the player needs to be before the prompt appears.
YardVehicleActivatable.ACTIVATION_DISTANCE = 4

function YardVehicleActivatable.new(yard, item)
    local self = setmetatable({}, YardVehicleActivatable_mt)
    self.yard = yard
    self.item = item
    self.isUeyActivatable = true

    local name = (item.vehicle ~= nil) and item.vehicle:getFullName() or "?"
    self.activateText = g_i18n:getText("uey_action_barter") .. " " .. name

    return self
end

function YardVehicleActivatable:getIsActivatable()
    if self.item == nil or self.item.vehicle == nil or self.item.vehicle.rootNode == nil then return false end
    if g_localPlayer == nil then return false end
    if g_localPlayer:getCurrentVehicle() ~= nil then return false end

    local px, _, pz = getWorldTranslation(g_localPlayer.rootNode)
    local vx, _, vz = getWorldTranslation(self.item.vehicle.rootNode)
    return MathUtil.vector2Length(px - vx, pz - vz) <= YardVehicleActivatable.ACTIVATION_DISTANCE
end

function YardVehicleActivatable:getDistance(x, y, z)
    if self.item == nil or self.item.vehicle == nil or self.item.vehicle.rootNode == nil then return math.huge end
    local vx, _, vz = getWorldTranslation(self.item.vehicle.rootNode)
    return MathUtil.vector2Length(x - vx, z - vz)
end

function YardVehicleActivatable:run()
    if self.item == nil or self.item.vehicle == nil then return end
    BarterDialog.show(self.yard, self.item)
end

function YardVehicleActivatable:activate()
end

function YardVehicleActivatable:deactivate()
end
