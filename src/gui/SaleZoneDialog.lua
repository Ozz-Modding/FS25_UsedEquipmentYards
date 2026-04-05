-- SaleZoneDialog
-- Dialog showing vehicles currently in the sale zone as a selectable list.
-- Player picks a vehicle, then eligibility is checked against the linked yard.

SaleZoneDialog = {}

local SaleZoneDialog_mt = Class(SaleZoneDialog, MessageDialog)

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------

function SaleZoneDialog.register()
    local dialog = SaleZoneDialog.new()
    g_gui:loadGui(UsedEquipmentYards.dir .. "gui/SaleZoneDialog.xml", "SaleZoneDialog", dialog)
end

function SaleZoneDialog.new()
    local self = MessageDialog.new(nil, SaleZoneDialog_mt, g_messageCenter, g_i18n, g_inputBinding)
    self.vehicles = {}
    self.yardId = nil
    return self
end

-- ---------------------------------------------------------------------------
-- Show / close
-- ---------------------------------------------------------------------------

function SaleZoneDialog.show(vehicles, yardId)
    if vehicles == nil or #vehicles == 0 then return end

    local dialog = g_gui.guis["SaleZoneDialog"]
    if dialog == nil then return end
    local ctrl = dialog.target
    ctrl.vehicles = vehicles
    ctrl.yardId = yardId
    g_gui:showDialog("SaleZoneDialog")
end

function SaleZoneDialog:onOpen()
    SaleZoneDialog:superClass().onOpen(self)
    self:populateDialog()
end

function SaleZoneDialog:populateDialog()
    if self.dialogTitleElement ~= nil then
        self.dialogTitleElement:setText(g_i18n:getText("uey_saleZone_dialogTitle"))
    end

    if self.vehicleList ~= nil then
        self.vehicleList:reloadData()
    end
end

-- ---------------------------------------------------------------------------
-- SmoothList data source callbacks
-- ---------------------------------------------------------------------------

function SaleZoneDialog:getNumberOfItemsInSection(list, section)
    return #self.vehicles
end

function SaleZoneDialog:populateCellForItemInSection(list, section, index, cell)
    local vehicle = self.vehicles[index]
    if vehicle == nil then return end
    cell:getAttribute("vehicleName"):setText(vehicle:getFullName())
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

function SaleZoneDialog:onClickSelect()
    if self.vehicleList == nil then return end

    local index = self.vehicleList.selectedIndex
    if index == nil or index < 1 or index > #self.vehicles then return end

    local vehicle = self.vehicles[index]
    if vehicle == nil then return end

    -- Resolve the linked yard.
    local yard = nil
    if UsedEquipmentYards.yardManager ~= nil then
        yard = UsedEquipmentYards.yardManager.yards[self.yardId]
    end

    if yard == nil then
        self:close()
        return
    end

    -- Eligibility check: does this yard want this vehicle?
    if yard.inventory:wouldBuyVehicle(vehicle) then
        self:close()
        SellBarterDialog.show(yard, vehicle)
        return
    end

    -- This yard won't buy it — check other yards.
    local otherYard = YardInventory.wouldAnyYardBuy(vehicle, self.yardId)
    self:close()

    if otherYard ~= nil then
        InfoDialog.show(string.format(
            g_i18n:getText("uey_sell_tryOtherYard"), otherYard.name))
    else
        InfoDialog.show(g_i18n:getText("uey_sell_nobodyInterested"))
    end
end

function SaleZoneDialog:onClickClose()
    self:close()
end

function SaleZoneDialog:onClose()
    SaleZoneDialog:superClass().onClose(self)
    self.vehicles = {}
    self.yardId = nil
end
