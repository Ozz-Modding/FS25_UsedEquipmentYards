-- SaleZoneDialog
-- Simple dialog showing vehicles currently in the sale zone.
-- For now, displays vehicle titles. Will be expanded with sell logic later.

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

    -- Populate vehicle list.
    if self.vehicleListLayout ~= nil and self.vehicleTemplate ~= nil then
        -- Clear existing clones.
        if self.clonedRows ~= nil then
            for _, row in ipairs(self.clonedRows) do
                row:delete()
            end
        end
        self.clonedRows = {}

        for _, vehicle in ipairs(self.vehicles) do
            local row = self.vehicleTemplate:clone(self.vehicleListLayout)
            row:setVisible(true)
            -- Row has a text child for the vehicle name.
            local nameElement = row.elements[1]
            if nameElement ~= nil then
                nameElement:setText(vehicle:getFullName())
            end
            table.insert(self.clonedRows, row)
        end
        self.vehicleListLayout:invalidateLayout()
    end
end

function SaleZoneDialog:onClickClose()
    self:close()
end

function SaleZoneDialog:onClose()
    SaleZoneDialog:superClass().onClose(self)
    -- Clean up cloned rows.
    if self.clonedRows ~= nil then
        for _, row in ipairs(self.clonedRows) do
            row:delete()
        end
        self.clonedRows = nil
    end
    self.vehicles = {}
end
