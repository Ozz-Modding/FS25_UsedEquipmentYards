-- YardConfigDialog
-- Dialog for configuring a yard's quality, dirtiness, and category weights.
-- Two-column layout: core settings (left), category weights (right).
-- Category weights are built dynamically from g_storeManager.categoryByName.

YardConfigDialog                 = {}

local YardConfigDialog_mt        = Class(YardConfigDialog, MessageDialog)

YardConfigDialog.QUALITY_OPTIONS = { "LOW", "MEDIUM", "HIGH" }
YardConfigDialog.DIRTINESS_STEP  = 0.05 -- 5% increments
YardConfigDialog.MAX_WEIGHT      = 10

-- Category types to exclude from the weight list.
YardConfigDialog.SKIP_TYPES      = {
    ["OBJECTS"]   = true,
    ["PLACEABLE"] = true,
    ["HANDTOOLS"] = true,
    ["MISC"]      = true,
}

-- Specific category names to exclude.
YardConfigDialog.SKIP_NAMES      = {
    ["WHEELLOADERTOOLS"]              = true,
    ["FRONTLOADERTOOLS"]              = true,
    ["FORESTRYEXCAVATORTOOLS"]        = true,
    ["TELELOADERTOOLS"]               = true,
    ["SKIDSTEERTOOLS"]                = true,
    ["CUTTERS"]                       = true,
    ["FORAGEHARVESTERCUTTERS"]        = true,
    ["LEVELER"]                       = true,
    ["CUTTERTRAILERS"]                = true,
    ["FORAGEHARVESTERCUTTERTRAILERS"] = true,
    ["BALINGMISC"] = true,
    ["MISCDRIVABLES"] = true,
    ["FORESTRYMISC"] = true,
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
    self.weightRows = {} -- { catName, option } created dynamically
    self.categoriesBuilt = false
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
    self:buildCategoryRows()
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
-- Build category weight rows dynamically from g_storeManager
-- ---------------------------------------------------------------------------

--- Return an ordered list of { name, title } for all store categories that
--- are not in SKIP_TYPES, sorted by orderId.
function YardConfigDialog.getKnownCategories()
    local cats = {}
    for name, info in pairs(g_storeManager.categoryByName) do
        if not YardConfigDialog.SKIP_TYPES[info.type]
            and not YardConfigDialog.SKIP_NAMES[name]
            and not name:find("PALLET")
            and not name:find("HEADER") then
            cats[#cats + 1] = { name = name, title = info.title, type = info.type }
            print(("[UEY] Category: %s — %s (type: %s)"):format(name, info.title, info.type))
        end
    end

    -- Detect duplicate titles and disambiguate with type in brackets.
    local titleCount = {}
    for _, cat in ipairs(cats) do
        titleCount[cat.title] = (titleCount[cat.title] or 0) + 1
    end
    for _, cat in ipairs(cats) do
        if titleCount[cat.title] > 1 then
            cat.title = cat.title .. " (" .. cat.type .. ")"
        end
    end

    table.sort(cats, function(a, b) return a.title < b.title end)
    return cats
end

--- Clone the hidden template row for each store category and add to the
--- ScrollingLayout. Only runs once; subsequent opens reuse the rows.
function YardConfigDialog:buildCategoryRows()
    if self.categoriesBuilt then return end
    self.categoriesBuilt = true

    local layout         = self.weightScrollLayout
    local template       = self.weightRowTemplate
    if layout == nil or template == nil then return end

    local categories = YardConfigDialog.getKnownCategories()

    for _, cat in ipairs(categories) do
        local row = template:clone()
        row:setVisible(true)

        -- Children by index: [1] = label, [2] = option.
        local label  = row.elements[1]
        local option = row.elements[2]

        if label ~= nil then
            label:setText(cat.title)
        end
        if option ~= nil then
            option.ueyCategory = cat.name
        end

        layout:addElement(row)
        self.weightRows[#self.weightRows + 1] = { catName = cat.name, option = option }
    end

    layout:invalidateLayout()
end

-- ---------------------------------------------------------------------------
-- Populate all options with texts and current state
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
        if v == self.config.quality then
            qualityState = i; break
        end
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

    for _, row in ipairs(self.weightRows) do
        row.option:setTexts(weightTexts)
        local w = (self.config.categories[row.catName] or 0) + 1
        row.option:setState(math.max(1, math.min(#weightTexts, w)))
    end
end

-- ---------------------------------------------------------------------------
-- Callbacks
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
