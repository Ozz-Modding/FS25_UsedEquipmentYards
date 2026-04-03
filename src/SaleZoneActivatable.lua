-- SaleZoneActivatable
-- Activatable shown when a player is on foot inside a sale zone
-- and at least one vehicle is also in the zone.

SaleZoneActivatable = {}
local SaleZoneActivatable_mt = Class(SaleZoneActivatable)

function SaleZoneActivatable.new(saleZone)
    local self = setmetatable({}, SaleZoneActivatable_mt)
    self.saleZone = saleZone
    self.activateText = g_i18n:getText("uey_saleZone_action")
    return self
end

function SaleZoneActivatable:getIsActivatable()
    if g_localPlayer == nil then return false end
    if g_localPlayer:getIsInVehicle() then return false end

    local vehicles = self.saleZone:determineCurrentVehicles()
    if #vehicles == 0 then return false end

    -- Update text with first vehicle name.
    self.activateText = g_i18n:getText("uey_saleZone_action") .. " " .. vehicles[1]:getFullName()
    return true
end

function SaleZoneActivatable:run()
    local vehicles = self.saleZone:determineCurrentVehicles()
    if #vehicles == 0 then return end
    SaleZoneDialog.show(vehicles)
end

function SaleZoneActivatable:getDistance(x, y, z)
    local data = self.saleZone[PlaceableSaleZone.KEY]
    if data == nil or data.playerTriggerNode == nil then return math.huge end
    local tx, _, tz = getWorldTranslation(data.playerTriggerNode)
    return MathUtil.getPointPointDistance(tx, tz, x, z)
end
