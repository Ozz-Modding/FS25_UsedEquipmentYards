-- SaleZoneDialog
-- Dialog showing vehicles currently in the sale zone as a selectable list.
-- Player picks a vehicle from the list to see its details.

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
    return self
end

-- ---------------------------------------------------------------------------
-- Show / close
-- ---------------------------------------------------------------------------

function SaleZoneDialog.show(vehicles)
    if vehicles == nil or #vehicles == 0 then return end

    local dialog = g_gui.guis["SaleZoneDialog"]
    if dialog == nil then return end
    local ctrl = dialog.target
    ctrl.vehicles = vehicles
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

    -- For now, just log the selection. Sell logic will be added later.
    Logging.info("[UsedEquipmentYards] Selected vehicle: %s", vehicle:getFullName())
    self:close()
end

function SaleZoneDialog:onClickClose()
    self:close()
end

function SaleZoneDialog:onClose()
    SaleZoneDialog:superClass().onClose(self)
    self.vehicles = {}
end
