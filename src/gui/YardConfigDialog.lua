-- YardConfigDialog
-- Dialog for configuring a yard's quality, dirtiness, and category weights.
-- Uses a SmoothList with left/right click cycling through option values.
--
-- Row layout:
--   [0] Quality      — cycles LOW / MEDIUM / HIGH
--   [1] Dirtiness    — cycles 0%, 5%, 10%, ... 100%
--   [2+] Categories  — cycles weight 0..10 for each known vehicle category

YardConfigDialog = {}

local YardConfigDialog_mt = Class(YardConfigDialog, MessageDialog)

YardConfigDialog.QUALITY_OPTIONS = { "LOW", "MEDIUM", "HIGH" }
YardConfigDialog.DIRTINESS_STEP  = 0.05    -- 5% increments
YardConfigDialog.MAX_WEIGHT      = 10

-- Ordered list of categories shown in the dialog.
-- Add/remove entries here to control what players can configure.
YardConfigDialog.CATEGORIES = {
    "TRACTORSS",        -- Small tractors
    "TRACTORSM",        -- Medium tractors
    "TRACTORSL",        -- Large tractors
    "TELELOADERS",      -- Telescopic loaders
    "WHEELLOADERSM",    -- Medium wheel loaders
    "WHEELLOADERSL",    -- Large wheel loaders
    "SKIDSTEERS",       -- Skid steers
    "COMBINECUTTERS",   -- Combine headers/cutters
    "HARVESTERS",       -- Combines / harvesters
    "FORAGEHARVESTERS", -- Forage harvesters
    "SPRAYERS",         -- Sprayers
    "FERTILIZERSPREAD", -- Fertiliser spreaders
    "SOWINGMACHINES",   -- Seeders / drills
    "PLOWS",            -- Ploughs
    "CULTIVATORS",      -- Cultivators / tillers
    "MOWERS",           -- Mowers
    "TEDDERS",          -- Tedders
    "WINDROWERS",       -- Windrowers / rakes
    "BALERS",           -- Balers
    "TRAILERS",         -- Trailers
}

-- ---------------------------------------------------------------------------
-- Registration (called once at mod load)
-- ---------------------------------------------------------------------------

function YardConfigDialog.register()
    g_gui:loadProfiles(UsedEquipmentYards.dir .. "gui/guiProfiles.xml")
    local dialog = YardConfigDialog.new()
    g_gui:loadGui(UsedEquipmentYards.dir .. "gui/YardConfigDialog.xml", "YardConfigDialog", dialog)
end

function YardConfigDialog.new()
    local self = MessageDialog.new(nil, YardConfigDialog_mt, g_messageCenter, g_i18n, g_inputBinding)
    self.yard = nil
    self.config = nil       -- working copy of yard config
    self.entries = {}       -- ordered list of { type, key, ... }
    return self
end

-- ---------------------------------------------------------------------------
-- Show / close
-- ---------------------------------------------------------------------------

function YardConfigDialog.show(yard)
    local dialog = g_gui.guis["YardConfigDialog"]
    if dialog == nil then return end
    local ctrl = dialog.target
    ctrl:setYard(yard)
    g_gui:showDialog("YardConfigDialog")
end

function YardConfigDialog:setYard(yard)
    self.yard = yard
    self.config = YardInventory.copyConfig(yard.inventory.config)
end

function YardConfigDialog:onOpen()
    YardConfigDialog:superClass().onOpen(self)
    self:buildEntries()
    self.settingsList:reloadData()
end

function YardConfigDialog:onClose()
    YardConfigDialog:superClass().onClose(self)
    self.yard = nil
    self.config = nil
end

function YardConfigDialog:onCreate()
end

-- ---------------------------------------------------------------------------
-- Entries
-- ---------------------------------------------------------------------------

function YardConfigDialog:buildEntries()
    self.entries = {}

    -- Quality row.
    self.entries[#self.entries + 1] = { type = "quality" }

    -- Dirtiness row.
    self.entries[#self.entries + 1] = { type = "dirtiness" }

    -- Category rows — gather all known vehicle categories from the store.
    local cats = self:getKnownCategories()
    for _, catName in ipairs(cats) do
        self.entries[#self.entries + 1] = { type = "category", key = catName }
    end
end

--- Returns the curated list of categories shown in the dialog.
function YardConfigDialog:getKnownCategories()
    return YardConfigDialog.CATEGORIES
end

-- ---------------------------------------------------------------------------
-- DataSource for SmoothList
-- ---------------------------------------------------------------------------

function YardConfigDialog:getNumberOfItemsInSection(list, section)
    return #self.entries
end

function YardConfigDialog:populateCellForItemInSection(list, section, index, cell)
    local entry = self.entries[index]
    if entry == nil then return end

    local nameElem  = cell:getAttribute("settingName")
    local valueElem = cell:getAttribute("settingValue")

    if entry.type == "quality" then
        nameElem:setText(g_i18n:getText("uey_config_quality"))
        local key = "uey_config_quality_" .. (self.config.quality or "MEDIUM")
        valueElem:setText(g_i18n:getText(key))

    elseif entry.type == "dirtiness" then
        nameElem:setText(g_i18n:getText("uey_config_dirtiness"))
        local pct = math.floor((self.config.dirtiness or 0.20) * 100 + 0.5)
        valueElem:setText(("%d %%"):format(pct))

    elseif entry.type == "category" then
        nameElem:setText(entry.key)
        local w = self.config.categories[entry.key] or 0
        valueElem:setText(tostring(w))
    end
end

-- ---------------------------------------------------------------------------
-- Click handling — left click cycles forward, right click backward (not
-- supported by SmoothList onClick; we just cycle forward on any click).
-- ---------------------------------------------------------------------------

function YardConfigDialog:onListClick(list, section, index, element)
    local entry = self.entries[index]
    if entry == nil then return end

    if entry.type == "quality" then
        self:cycleQuality(1)
    elseif entry.type == "dirtiness" then
        self:cycleDirtiness(1)
    elseif entry.type == "category" then
        self:cycleCategory(entry.key, 1)
    end

    self.settingsList:reloadData()
end

function YardConfigDialog:cycleQuality(dir)
    local opts = YardConfigDialog.QUALITY_OPTIONS
    local cur = 1
    for i, v in ipairs(opts) do
        if v == self.config.quality then cur = i; break end
    end
    cur = cur + dir
    if cur > #opts then cur = 1 end
    if cur < 1 then cur = #opts end
    self.config.quality = opts[cur]
end

function YardConfigDialog:cycleDirtiness(dir)
    local step = YardConfigDialog.DIRTINESS_STEP
    local val = (self.config.dirtiness or 0.20) + dir * step
    -- Wrap around.
    if val > 1.005 then val = 0 end
    if val < -0.005 then val = 1 end
    self.config.dirtiness = math.max(0, math.min(1, val))
end

function YardConfigDialog:cycleCategory(catName, dir)
    local cur = self.config.categories[catName] or 0
    cur = cur + dir
    if cur > YardConfigDialog.MAX_WEIGHT then cur = 0 end
    if cur < 0 then cur = YardConfigDialog.MAX_WEIGHT end
    self.config.categories[catName] = cur
end

-- ---------------------------------------------------------------------------
-- Keyboard navigation — left/right arrows cycle value on selected row
-- ---------------------------------------------------------------------------

function YardConfigDialog:onMenuInput(actionName, inputValue)
    if actionName == InputAction.MENU_AXIS_LEFT_RIGHT then
        local dir = inputValue > 0 and 1 or -1
        local index = self.settingsList:getSelectedIndex()
        if index ~= nil and index > 0 then
            local entry = self.entries[index]
            if entry ~= nil then
                if entry.type == "quality" then
                    self:cycleQuality(dir)
                elseif entry.type == "dirtiness" then
                    self:cycleDirtiness(dir)
                elseif entry.type == "category" then
                    self:cycleCategory(entry.key, dir)
                end
                self.settingsList:reloadData()
            end
        end
        return
    end

    YardConfigDialog:superClass().onMenuInput(self, actionName, inputValue)
end

-- ---------------------------------------------------------------------------
-- Buttons
-- ---------------------------------------------------------------------------

function YardConfigDialog:onClickApply()
    if self.yard ~= nil and self.config ~= nil then
        self.yard.inventory:applyConfig(self.config)
    end
    YardConfigDialog:superClass().close(self)
end

function YardConfigDialog:onClickClose()
    YardConfigDialog:superClass().close(self)
end
