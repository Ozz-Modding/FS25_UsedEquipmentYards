-- YardConfigDialog
-- Dialog for configuring a yard's quality, dirtiness, category weights, and brands.
-- Three-column layout: core settings (left), category weights (middle), brands (right).
-- Category weights and brands are built dynamically from g_storeManager / g_brandManager.

YardConfigDialog                 = {}

local YardConfigDialog_mt        = Class(YardConfigDialog, MessageDialog)

YardConfigDialog.QUALITY_OPTIONS = { "LOW", "MEDIUM", "HIGH" }
YardConfigDialog.DIRTINESS_STEP  = 0.05 -- 5% increments
YardConfigDialog.MAX_WEIGHT      = 10
YardConfigDialog.MAX_BRAND_WEIGHT = 3

-- Working width options (metres). 0 = no limit.
YardConfigDialog.MIN_WW_OPTIONS  = { 0, 5, 10, 15, 20 }   -- "No minimum", 5m, 10m, ...
YardConfigDialog.MAX_WW_OPTIONS  = { 5, 10, 15, 20, 0 }   -- 5m, 10m, ..., "No maximum"
YardConfigDialog.MAX_PRICE_OPTIONS = { 50000, 100000, 150000, 200000, 250000, 0 }  -- 0 = "No maximum"

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

-- Brand names to exclude.
YardConfigDialog.SKIP_BRANDS     = {
    ["NONE"] = true,
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
    self.weightRows = {}   -- { catName, option }
    self.brandRows  = {}   -- { brandName, option }
    self.rowsBuilt  = false
    return self
end

-- ---------------------------------------------------------------------------
-- Show / close
-- ---------------------------------------------------------------------------

function YardConfigDialog.show(yard)
    -- DEV: hot-reload XML on every open for faster iteration.
    -- YardConfigDialog.register()

    local dialog = g_gui.guis["YardConfigDialog"]
    if dialog == nil then return end
    local ctrl = dialog.target
    ctrl:setYard(yard)
    g_gui:showDialog("YardConfigDialog")
end

function YardConfigDialog:setYard(yard)
    self.yard = yard
    self.config = YardInventory.copyConfig(yard.inventory.config)
    self.yardName = yard.name or ""
end

function YardConfigDialog:onOpen()
    YardConfigDialog:superClass().onOpen(self)
    self:buildRows()
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
-- Build dynamic rows (categories + brands) — runs once
-- ---------------------------------------------------------------------------

--- Return an ordered list of { name, title } for filtered store categories.
function YardConfigDialog.getKnownCategories()
    local cats = {}
    for name, info in pairs(g_storeManager.categoryByName) do
        if not YardConfigDialog.SKIP_TYPES[info.type]
            and not YardConfigDialog.SKIP_NAMES[name]
            and not name:find("PALLET")
            and not name:find("HEADER") then
            cats[#cats + 1] = { name = name, title = info.title, type = info.type }
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

--- Return an ordered list of { name, title } for all brands.
function YardConfigDialog.getKnownBrands()
    local brands = {}
    for i = 1, g_brandManager.numOfBrands do
        local brand = g_brandManager.indexToBrand[i]
        if brand ~= nil and not YardConfigDialog.SKIP_BRANDS[brand.name] then
            brands[#brands + 1] = { name = brand.name, title = brand.title }
        end
    end
    table.sort(brands, function(a, b) return a.title < b.title end)
    return brands
end

--- Clone template rows into the ScrollingLayouts. Only runs once.
function YardConfigDialog:buildRows()
    if self.rowsBuilt then return end
    self.rowsBuilt = true

    -- Category weights
    self:buildListRows(
        self.weightScrollLayout, self.weightRowTemplate,
        YardConfigDialog.getKnownCategories(), self.weightRows, "ueyCategory"
    )

    -- Brands
    self:buildListRows(
        self.brandScrollLayout, self.brandRowTemplate,
        YardConfigDialog.getKnownBrands(), self.brandRows, "ueyBrand"
    )
end

--- Generic: clone a template row per entry into a ScrollingLayout.
function YardConfigDialog:buildListRows(layout, template, entries, rowTable, tagKey)
    if layout == nil or template == nil then return end

    for _, entry in ipairs(entries) do
        local row = template:clone()
        row:setVisible(true)

        local label  = row.elements[1]
        local option = row.elements[2]

        if label ~= nil then
            label:setText(entry.title)
        end
        if option ~= nil then
            option[tagKey] = entry.name
        end

        layout:addElement(row)
        rowTable[#rowTable + 1] = { name = entry.name, option = option }
    end

    layout:invalidateLayout()
end

-- ---------------------------------------------------------------------------
-- Populate all options with texts and current state
-- ---------------------------------------------------------------------------

function YardConfigDialog:populateOptions()
    -- Yard name
    if self.yardNameInput ~= nil then
        self.yardNameInput:setText(self.yardName)
    end

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
        local w = (self.config.categories[row.name] or 0) + 1
        row.option:setState(math.max(1, math.min(#weightTexts, w)))
    end

    -- Brand weights (0 .. MAX_BRAND_WEIGHT)
    -- Empty brands config = all brands at weight 1.
    local hasBrandConfig = next(self.config.brands) ~= nil
    local brandTexts = {}
    for w = 0, YardConfigDialog.MAX_BRAND_WEIGHT do
        brandTexts[#brandTexts + 1] = tostring(w)
    end
    for _, row in ipairs(self.brandRows) do
        row.option:setTexts(brandTexts)
        local w = hasBrandConfig and (self.config.brands[row.name] or 0) or 1
        row.option:setState(math.max(1, math.min(#brandTexts, w + 1)))
    end

    -- Min working width
    local minWWTexts = {}
    for _, v in ipairs(YardConfigDialog.MIN_WW_OPTIONS) do
        minWWTexts[#minWWTexts + 1] = v == 0 and g_i18n:getText("uey_config_noMinimum") or (tostring(v) .. " m")
    end
    self.minWorkingWidthOption:setTexts(minWWTexts)
    local minWWState = 1
    for i, v in ipairs(YardConfigDialog.MIN_WW_OPTIONS) do
        if v == (self.config.minWorkingWidth or 0) then minWWState = i; break end
    end
    self.minWorkingWidthOption:setState(minWWState)

    -- Max working width
    local maxWWTexts = {}
    for _, v in ipairs(YardConfigDialog.MAX_WW_OPTIONS) do
        maxWWTexts[#maxWWTexts + 1] = v == 0 and g_i18n:getText("uey_config_noMaximum") or (tostring(v) .. " m")
    end
    self.maxWorkingWidthOption:setTexts(maxWWTexts)
    local maxWWState = #YardConfigDialog.MAX_WW_OPTIONS  -- default: last = "No maximum"
    for i, v in ipairs(YardConfigDialog.MAX_WW_OPTIONS) do
        if v == (self.config.maxWorkingWidth or 0) then maxWWState = i; break end
    end
    self.maxWorkingWidthOption:setState(maxWWState)

    -- Max price
    local maxPriceTexts = {}
    for _, v in ipairs(YardConfigDialog.MAX_PRICE_OPTIONS) do
        maxPriceTexts[#maxPriceTexts + 1] = v == 0 and g_i18n:getText("uey_config_noMaximum") or g_i18n:formatMoney(v)
    end
    self.maxPriceOption:setTexts(maxPriceTexts)
    local maxPriceState = #YardConfigDialog.MAX_PRICE_OPTIONS  -- default: last = "No maximum"
    for i, v in ipairs(YardConfigDialog.MAX_PRICE_OPTIONS) do
        if v == (self.config.maxPrice or 0) then maxPriceState = i; break end
    end
    self.maxPriceOption:setState(maxPriceState)
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

function YardConfigDialog:onMinWorkingWidthChanged(state, element)
    self.config.minWorkingWidth = YardConfigDialog.MIN_WW_OPTIONS[state] or 0
end

function YardConfigDialog:onMaxWorkingWidthChanged(state, element)
    self.config.maxWorkingWidth = YardConfigDialog.MAX_WW_OPTIONS[state] or 0
end

function YardConfigDialog:onMaxPriceChanged(state, element)
    self.config.maxPrice = YardConfigDialog.MAX_PRICE_OPTIONS[state] or 0
end

function YardConfigDialog:onWeightChanged(state, element)
    local catName = element.ueyCategory
    if catName ~= nil then
        self.config.categories[catName] = state - 1
    end
end

function YardConfigDialog:onBrandChanged(state, element)
    local brandName = element.ueyBrand
    if brandName ~= nil then
        self.config.brands[brandName] = state - 1
    end
end

-- ---------------------------------------------------------------------------
-- Buttons
-- ---------------------------------------------------------------------------

function YardConfigDialog:onClickClearWeights()
    for _, row in ipairs(self.weightRows) do
        row.option:setState(1)
        self.config.categories[row.name] = 0
    end
end

function YardConfigDialog:onClickAllBrands()
    for _, row in ipairs(self.brandRows) do
        row.option:setState(2)  -- state 2 = weight 1
        self.config.brands[row.name] = 1
    end
end

function YardConfigDialog:onClickClearBrands()
    for _, row in ipairs(self.brandRows) do
        row.option:setState(1)  -- state 1 = weight 0
        self.config.brands[row.name] = 0
    end
end

function YardConfigDialog:onNameEnterPressed()
    -- Accept the current text — nothing extra needed.
end

function YardConfigDialog:onNameEscPressed()
    -- Revert to original name.
    if self.yardNameInput ~= nil then
        self.yardNameInput:setText(self.yardName)
    end
end

function YardConfigDialog:onClickApply()
    if self.yard ~= nil and self.config ~= nil then
        self.yard.inventory:applyConfig(self.config)
    end

    -- Apply name change.
    if self.yard ~= nil and self.yardNameInput ~= nil then
        local newName = self.yardNameInput:getText()
        if newName ~= nil and newName ~= "" and newName ~= self.yard.name then
            YardNameGenerator.rename(self.yard.name, newName)
            self.yard.name = newName
        end
    end

    YardConfigDialog:superClass().close(self)
end

function YardConfigDialog:onClickClose()
    YardConfigDialog:superClass().close(self)
end
