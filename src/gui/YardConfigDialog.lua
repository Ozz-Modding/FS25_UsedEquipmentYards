-- YardConfigDialog
-- Dialog for configuring a yard's quality, dirtiness, and category weights.
-- Two-column layout: core settings (left), category weights (right).
-- Each setting uses a MultiTextOption for left/right value selection.

YardConfigDialog = {}

local YardConfigDialog_mt = Class(YardConfigDialog, MessageDialog)

YardConfigDialog.QUALITY_OPTIONS = { "LOW", "MEDIUM", "HIGH" }
YardConfigDialog.DIRTINESS_STEP  = 0.05    -- 5% increments
YardConfigDialog.MAX_WEIGHT      = 10

-- Ordered list of categories shown in the dialog.
-- Each entry must have a matching id="weight<KEY>" MultiTextOption in the XML.
YardConfigDialog.CATEGORIES = {
    "TRACTORSS",
    "TRACTORSM",
    "TRACTORSL",
    "TELELOADERS",
    "WHEELLOADERSM",
    "WHEELLOADERSL",
    "SKIDSTEERS",
    "COMBINECUTTERS",
    "HARVESTERS",
    "FORAGEHARVESTERS",
    "SPRAYERS",
    "FERTILIZERSPREAD",
    "SOWINGMACHINES",
    "PLOWS",
    "CULTIVATORS",
    "MOWERS",
    "TEDDERS",
    "WINDROWERS",
    "BALERS",
    "TRAILERS",
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
    self.config = nil
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
    self:populateOptions()
end

function YardConfigDialog:onClose()
    YardConfigDialog:superClass().onClose(self)
    self.yard = nil
    self.config = nil
end

function YardConfigDialog:onCreate()
end

-- ---------------------------------------------------------------------------
-- Populate all MultiTextOption elements with texts and current state
-- ---------------------------------------------------------------------------

function YardConfigDialog:populateOptions()
    -- Quality
    local qualityTexts = {}
    for _, q in ipairs(YardConfigDialog.QUALITY_OPTIONS) do
        qualityTexts[#qualityTexts + 1] = g_i18n:getText("uey_config_quality_" .. q)
    end
    self.qualityOption:setTexts(qualityTexts)
    local qualityState = 1
    for i, v in ipairs(YardConfigDialog.QUALITY_OPTIONS) do
        if v == self.config.quality then qualityState = i; break end
    end
    self.qualityOption:setState(qualityState)

    -- Dirtiness (0%, 5%, 10%, ... 100%)
    local dirtTexts = {}
    for pct = 0, 100, 5 do
        dirtTexts[#dirtTexts + 1] = ("%d %%"):format(pct)
    end
    self.dirtinessOption:setTexts(dirtTexts)
    local dirtState = math.floor((self.config.dirtiness or 0.20) / YardConfigDialog.DIRTINESS_STEP + 0.5) + 1
    self.dirtinessOption:setState(math.max(1, math.min(#dirtTexts, dirtState)))

    -- Category weights (0 .. MAX_WEIGHT)
    local weightTexts = {}
    for w = 0, YardConfigDialog.MAX_WEIGHT do
        weightTexts[#weightTexts + 1] = tostring(w)
    end

    for _, catName in ipairs(YardConfigDialog.CATEGORIES) do
        local option = self["weight" .. catName]
        if option ~= nil then
            option:setTexts(weightTexts)
            local w = (self.config.categories[catName] or 0) + 1
            option:setState(math.max(1, math.min(#weightTexts, w)))
            option.ueyCategory = catName
        end
    end
end

-- ---------------------------------------------------------------------------
-- Callbacks — one per core setting, one shared for all weight options
-- ---------------------------------------------------------------------------

function YardConfigDialog:onQualityChanged(state, element)
    self.config.quality = YardConfigDialog.QUALITY_OPTIONS[state]
end

function YardConfigDialog:onDirtinessChanged(state, element)
    self.config.dirtiness = (state - 1) * YardConfigDialog.DIRTINESS_STEP
end

function YardConfigDialog:onWeightChanged(state, element)
    local catName = element.ueyCategory
    if catName ~= nil then
        self.config.categories[catName] = state - 1
    end
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
