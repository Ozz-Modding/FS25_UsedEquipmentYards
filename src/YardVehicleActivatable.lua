-- YardVehicleActivatable
-- One instance per spawned yard vehicle. Registered with the
-- activatableObjectsSystem so the player gets a "Buy" prompt when nearby.
-- run() shows a YesNo confirmation dialog; on confirm, sends a purchase event.

YardVehicleActivatable = {}
local YardVehicleActivatable_mt = Class(YardVehicleActivatable)

-- How close (metres) the player needs to be before the prompt appears.
YardVehicleActivatable.ACTIVATION_DISTANCE = 6

function YardVehicleActivatable.new(yard, item)
    local self = setmetatable({}, YardVehicleActivatable_mt)
    self.yard = yard
    self.item = item
    self.isUeyActivatable = true

    local name = (item.vehicle ~= nil) and item.vehicle:getFullName() or "?"
    self.activateText = g_i18n:getText("uey_action_buyVehicle")
        .. " " .. name .. "  —  " .. g_i18n:formatMoney(item.price)

    return self
end

function YardVehicleActivatable:getIsActivatable()
    if self.item == nil or self.item.vehicle == nil then return false end
    if g_localPlayer == nil or g_localPlayer.rootNode == nil then return false end
    if g_localPlayer:getCurrentVehicle() ~= nil then return false end

    -- Distance gate — activatableObjectsSystem also distance-sorts, but this
    -- keeps prompts from showing across the entire yard.
    local px, py, pz = getWorldTranslation(g_localPlayer.rootNode)
    return self:getDistance(px, py, pz) <= YardVehicleActivatable.ACTIVATION_DISTANCE
end

function YardVehicleActivatable:getDistance(x, y, z)
    if self.item == nil or self.item.vehicle == nil then return math.huge end
    local vx, vy, vz = getWorldTranslation(self.item.vehicle.rootNode)
    return MathUtil.vector3Length(x - vx, y - vy, z - vz)
end

function YardVehicleActivatable:run()
    if self.item == nil or self.item.vehicle == nil then return end

    local farmId = g_currentMission:getFarmId()
    if farmId == FarmManager.SPECTATOR_FARM_ID then return end

    -- Client-side fund check (server validates authoritatively too).
    local farm = g_farmManager:getFarmById(farmId)
    if farm == nil or farm:getBalance() < self.item.price then
        InfoDialog.show(g_i18n:getText("uey_purchase_insufficient_funds"))
        return
    end

    local text = string.format(
        g_i18n:getText("uey_purchase_confirm"),
        self.item.vehicle:getFullName(),
        g_i18n:formatMoney(self.item.price)
    )

    YesNoDialog.show(YardVehicleActivatable.onPurchaseAnswer, self, text,
        g_i18n:getText("uey_purchase_title"))
end

function YardVehicleActivatable:onPurchaseAnswer(confirmed)
    if not confirmed then return end
    if self.item == nil or self.item.vehicle == nil then return end

    -- Find item index so the server can locate it.
    local itemIndex = nil
    for i, itm in ipairs(self.yard.inventory.items) do
        if itm == self.item then
            itemIndex = i
            break
        end
    end
    if itemIndex == nil then return end

    local farmId = g_currentMission:getFarmId()
    g_client:getServerConnection():sendEvent(
        EquipmentPurchasedEvent.new(self.yard.id, itemIndex, farmId)
    )
end

function YardVehicleActivatable:activate()
end

function YardVehicleActivatable:deactivate()
end
