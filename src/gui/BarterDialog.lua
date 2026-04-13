-- BarterDialog
-- Dialog for bartering the price of a yard vehicle before purchase.
-- Barter logic runs client-side (comparing offer vs item.minPrice).
-- On acceptance, sends EquipmentPurchasedEvent to complete the purchase.

BarterDialog = {}

local BarterDialog_mt = Class(BarterDialog, MessageDialog)

BarterDialog.OFFER_STEPS = { 30, 25, 20, 15, 10, 5, 0 }  -- % below asking (left=biggest discount, right=full price)

-- Only these store categories are eligible for test drives.
BarterDialog.TEST_DRIVE_CATEGORIES = {
    ["TRACTORSS"]           = true,
    ["TRACTORSM"]           = true,
    ["TRACTORSL"]           = true,
    ["TELELOADERVEHICLES"]  = true,
    ["WHEELLOADERVEHICLES"] = true,
    ["SKIDSTEERVEHICLES"]   = true,
    ["BEETHARVESTERS"]      = true,
    ["CARS"]                = true,
    ["FORAGEHARVESTERS"]    = true,
    ["FORESTRYHARVESTERS"]  = true,
    ["HARVESTERS"]          = true,
    ["PEAHARVESTERS"]       = true,
    ["POTATOHARVESTING"]    = true,
    ["RICEHARVESTERS"]      = true,
    ["SPINACHHARVESTERS"]   = true,
    ["SUGARCANEHARVESTERS"] = true,
    ["VEGETABLEHARVESTERS"] = true,
}

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------

function BarterDialog.register()
    local dialog = BarterDialog.new()
    g_gui:loadGui(UsedEquipmentYards.dir .. "gui/BarterDialog.xml", "BarterDialog", dialog)
end

function BarterDialog.new()
    local self = MessageDialog.new(nil, BarterDialog_mt, g_messageCenter, g_i18n, g_inputBinding)
    self.yard = nil
    self.item = nil
    self.itemIndex = nil
    self.currentOffer = 0
    self.attrElements = {}
    return self
end

-- ---------------------------------------------------------------------------
-- Show / close
-- ---------------------------------------------------------------------------

function BarterDialog.getLocalFarmId()
    local farmId = g_currentMission:getFarmId()
    if farmId == nil or farmId == FarmManager.SPECTATOR_FARM_ID then
        return nil
    end
    return farmId
end

function BarterDialog.show(yard, item)
    local farmId = BarterDialog.getLocalFarmId()
    if farmId == nil then
        InfoDialog.show(g_i18n:getText("uey_barter_noFarm"))
        return
    end

    -- DEV: hot-reload XML on every open for faster iteration.
    -- BarterDialog.register()

    local itemIndex = item.itemIndex
    if itemIndex == nil then
        for i, itm in pairs(yard.inventory.items) do
            if itm == item then
                itemIndex = i
                break
            end
        end
    end
    if itemIndex == nil then return end

    local dialog = g_gui.guis["BarterDialog"]
    if dialog == nil then return end
    local ctrl = dialog.target
    ctrl:setItem(yard, item, itemIndex)
    g_gui:showDialog("BarterDialog")
end

function BarterDialog:setItem(yard, item, itemIndex)
    self.yard = yard
    self.item = item
    self.itemIndex = itemIndex
    self.currentOffer = item.price
end

function BarterDialog:onOpen()
    BarterDialog:superClass().onOpen(self)
    self:populateDialog()
end

function BarterDialog:onClose()
    BarterDialog:superClass().onClose(self)
    self.yard = nil
    self.item = nil
    self.itemIndex = nil
end

function BarterDialog:onCreate()
end

-- ---------------------------------------------------------------------------
-- Populate
-- ---------------------------------------------------------------------------

function BarterDialog:populateDialog()
    if self.item == nil then return end
    local item = self.item
    local vehicle = item.vehicle

    if vehicle ~= nil then
        self.dialogTitleElement:setText(vehicle:getFullName())
    end

    self.askingPriceText:setText(g_i18n:formatMoney(item.price))

    -- Credit balance.
    local farmId = BarterDialog.getLocalFarmId()
    local creditBal = (farmId ~= nil and self.yard ~= nil) and YardCredit.getBalance(farmId, self.yard.id) or 0
    if self.creditBalanceText ~= nil then
        self.creditBalanceText:setText(creditBal > 0 and g_i18n:formatMoney(creditBal) or g_i18n:getText("uey_credit_none"))
    end

    -- Offer spinner
    local offerTexts = {}
    local offerValues = {}
    for _, pct in ipairs(BarterDialog.OFFER_STEPS) do
        local offerPrice = math.floor(item.price * (1 - pct / 100))
        offerValues[#offerValues + 1] = offerPrice
        if pct == 0 then
            offerTexts[#offerTexts + 1] = g_i18n:formatMoney(offerPrice)
        else
            offerTexts[#offerTexts + 1] = g_i18n:formatMoney(offerPrice) .. " (-" .. pct .. "%)"
        end
    end
    self.offerValues = offerValues
    self.offerOption:setTexts(offerTexts)
    self.offerOption:setState(#offerValues)
    self.currentOffer = offerValues[#offerValues]

    self.resultText:setText("")
    self:updateChancesText()

    -- Vehicle info
    local brand = vehicle ~= nil and g_brandManager:getBrandByIndex(
        g_storeManager:getItemByXMLFilename(vehicle.configFileName).brandIndex) or nil
    self.brandText:setText(brand ~= nil and brand.title or "—")
    self.ownersText:setText(tostring(item.numOwners or 1))
    self.damageText:setText(("%d %%"):format(math.floor((item.damage or 0) * 100)))
    self.wearText:setText(("%d %%"):format(math.floor((item.wear or 0) * 100)))

    self:populateAttributes()
    self:updateButtonStates()
end

function BarterDialog:updateChancesText()
    local farmId = BarterDialog.getLocalFarmId()
    if farmId == nil or self.yard == nil then return end
    local remaining = BarterState.getRemainingChances(farmId, self.yard.id)
    self.chancesText:setText(string.format(
        g_i18n:getText("uey_barter_chancesRemaining"), remaining))
end

function BarterDialog:updateButtonStates()
    local farmId = BarterDialog.getLocalFarmId()
    local td = self.item ~= nil and self.item.testDrive or nil
    local isOnTestDrive = td ~= nil
    local isOurTestDrive = isOnTestDrive and td.farmId == farmId
    local isOtherTestDrive = isOnTestDrive and not isOurTestDrive

    -- Barter/buy disabled when on test drive.
    local noChances = farmId == nil or self.yard == nil
        or BarterState.getRemainingChances(farmId, self.yard.id) <= 0
    self.makeOfferButton.disabled = noChances or isOnTestDrive
    self.buyNowButton.disabled = isOnTestDrive

    -- Test drive button: shows "Return" if our test drive, "Test Drive" otherwise.
    -- Only drivable categories (tractors, loaders, skid steers) are eligible.
    local canTestDrive = false
    if self.item ~= nil and self.item.vehicle ~= nil then
        local si = g_storeManager:getItemByXMLFilename(self.item.vehicle.configFileName)
        if si ~= nil and si.categoryNames ~= nil then
            for _, catName in ipairs(si.categoryNames) do
                if BarterDialog.TEST_DRIVE_CATEGORIES[catName] then
                    canTestDrive = true
                    break
                end
            end
        end
    end

    local alreadyDriven = farmId ~= nil
        and self.item.testDrivenByFarms ~= nil
        and self.item.testDrivenByFarms[farmId] == true

    if not canTestDrive then
        self.testDriveButton:setText(g_i18n:getText("uey_barter_testDrive"))
        self.testDriveButton.disabled = true
    elseif isOurTestDrive then
        self.testDriveButton:setText(g_i18n:getText("uey_barter_returnVehicle"))
        self.testDriveButton.disabled = false
    elseif isOtherTestDrive or alreadyDriven then
        self.testDriveButton:setText(g_i18n:getText("uey_barter_testDrive"))
        self.testDriveButton.disabled = true
    else
        self.testDriveButton:setText(g_i18n:getText("uey_barter_testDrive"))
        self.testDriveButton.disabled = false
    end
end

function BarterDialog:updateMakeOfferEnabled()
    local farmId = BarterDialog.getLocalFarmId()
    if farmId == nil or self.yard == nil then
        self.makeOfferButton.disabled = true
        return
    end
    self.makeOfferButton.disabled = BarterState.getRemainingChances(farmId, self.yard.id) <= 0
end

-- ---------------------------------------------------------------------------
-- Vehicle attributes (mirrors GarageMenu pattern)
-- ---------------------------------------------------------------------------

function BarterDialog:populateAttributes()
    for _, elem in ipairs(self.attrElements) do
        elem:delete()
    end
    self.attrElements = {}

    local vehicle = self.item ~= nil and self.item.vehicle or nil
    if vehicle == nil then return end

    local storeItem = g_storeManager:getItemByXMLFilename(vehicle.configFileName)
    if storeItem == nil then return end

    local displayItem = g_shopController:makeDisplayItem(storeItem, vehicle, vehicle.configurations)
    if displayItem == nil then return end

    local template = self.attrTemplate
    local layout = self.attributesLayout
    if template == nil or layout == nil then return end

    for k, profile in ipairs(displayItem.attributeIconProfiles) do
        local element = template:clone(layout)
        self.attrElements[#self.attrElements + 1] = element

        local iconElement = element:getDescendantByName("icon")
        if iconElement ~= nil then
            iconElement:applyProfile(profile)
        end
        local textElement = element:getDescendantByName("text")
        if textElement ~= nil then
            textElement:setText(displayItem.attributeValues[k])
        end
        element:setVisible(true)

        if iconElement ~= nil and textElement ~= nil then
            element:setSize(textElement.size[1] + iconElement.size[1] + 0.0025, textElement.size[2])
        end
    end

    layout:invalidateLayout()
end

-- ---------------------------------------------------------------------------
-- Callbacks
-- ---------------------------------------------------------------------------

function BarterDialog:onOfferChanged(state, element)
    if self.offerValues ~= nil then
        self.currentOffer = self.offerValues[state] or self.item.price
    end
end

function BarterDialog:onClickMakeOffer()
    if self.item == nil or self.yard == nil then return end

    local farmId = BarterDialog.getLocalFarmId()
    if farmId == nil then return end

    if BarterState.getRemainingChances(farmId, self.yard.id) <= 0 then
        self.resultText:setText(g_i18n:getText("uey_barter_noChances"))
        return
    end

    local farm = g_farmManager:getFarmById(farmId)
    local credit = YardCredit.getBalance(farmId, self.yard.id)
    if farm == nil or (farm:getBalance() + credit) < self.currentOffer then
        self.resultText:setText(g_i18n:getText("uey_purchase_insufficient_funds"))
        return
    end

    -- Consume a chance — send to server so all clients on this farm see it.
    g_client:getServerConnection():sendEvent(BarterAttemptEvent.new(farmId, self.yard.id))

    -- Client-side accept/reject.
    if self.currentOffer >= (self.item.minPrice or self.item.price) then
        -- Accepted — set item price to the offer and purchase.
        local vehicleName = self.item.vehicle:getFullName()
        local paidPrice = self.currentOffer
        self.item.price = paidPrice
        g_client:getServerConnection():sendEvent(
            EquipmentPurchasedEvent.new(self.yard.id, self.itemIndex, farmId))
        BarterDialog:superClass().close(self)
        InfoDialog.show(string.format(g_i18n:getText("uey_barter_purchased"), vehicleName, g_i18n:formatMoney(paidPrice)))
    else
        self.resultText:setText(g_i18n:getText("uey_barter_rejected"))
        self:updateChancesText()
        self:updateMakeOfferEnabled()
    end
end

function BarterDialog:onClickBuyNow()
    if self.item == nil or self.yard == nil then return end

    local farmId = BarterDialog.getLocalFarmId()
    if farmId == nil then return end

    local farm = g_farmManager:getFarmById(farmId)
    local credit = YardCredit.getBalance(farmId, self.yard.id)
    if farm == nil or (farm:getBalance() + credit) < self.item.price then
        self.resultText:setText(g_i18n:getText("uey_purchase_insufficient_funds"))
        return
    end

    local text = string.format(
        g_i18n:getText("uey_purchase_confirm"),
        self.item.vehicle:getFullName(),
        g_i18n:formatMoney(self.item.price))
    YesNoDialog.show(BarterDialog.onBuyNowConfirm, self, text,
        g_i18n:getText("uey_purchase_title"))
end

function BarterDialog:onBuyNowConfirm(confirmed)
    if not confirmed or self.item == nil or self.yard == nil then return end

    local farmId = BarterDialog.getLocalFarmId()
    if farmId == nil then return end

    g_client:getServerConnection():sendEvent(
        EquipmentPurchasedEvent.new(self.yard.id, self.itemIndex, farmId))
    BarterDialog:superClass().close(self)
end

function BarterDialog:onClickTestDrive()
    if self.item == nil or self.yard == nil then return end

    local farmId = BarterDialog.getLocalFarmId()
    if farmId == nil then return end

    local td = self.item.testDrive
    if td ~= nil and td.farmId == farmId then
        -- Return the vehicle.
        YesNoDialog.show(BarterDialog.onReturnConfirm, self,
            g_i18n:getText("uey_barter_returnConfirm"),
            g_i18n:getText("uey_barter_returnTitle"))
    else
        -- Start a test drive.
        local env = g_currentMission.environment
        local returnByHour = env.currentHour + TestDriveEvent.DURATION_HOURS + 1
        if returnByHour >= 24 then returnByHour = returnByHour - 24 end
        local text = string.format(
            g_i18n:getText("uey_barter_testDriveConfirm"),
            self.item.vehicle:getFullName(),
            returnByHour)
        YesNoDialog.show(BarterDialog.onTestDriveConfirm, self, text,
            g_i18n:getText("uey_barter_testDriveTitle"))
    end
end

function BarterDialog:onTestDriveConfirm(confirmed)
    if not confirmed or self.item == nil or self.yard == nil then return end

    local farmId = BarterDialog.getLocalFarmId()
    if farmId == nil then return end

    g_client:getServerConnection():sendEvent(
        TestDriveEvent.new(self.yard.id, self.itemIndex, farmId, TestDriveEvent.ACTION_START))
    BarterDialog:superClass().close(self)
end

function BarterDialog:onReturnConfirm(confirmed)
    if not confirmed or self.item == nil or self.yard == nil then return end

    local farmId = BarterDialog.getLocalFarmId()
    if farmId == nil then return end

    g_client:getServerConnection():sendEvent(
        TestDriveEvent.new(self.yard.id, self.itemIndex, farmId, TestDriveEvent.ACTION_RETURN))
    BarterDialog:superClass().close(self)
end

function BarterDialog:onClickClose()
    BarterDialog:superClass().close(self)
end
