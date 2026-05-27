HirePurchaseDialog = {}
local HirePurchaseDialog_mt = Class(HirePurchaseDialog, MessageDialog)

HirePurchaseDialog.MAX_DURATION_YEARS = 10

function HirePurchaseDialog.register()
    local dialog = HirePurchaseDialog.new()
    g_gui:loadGui(UsedEquipmentYards.dir .. "gui/HirePurchaseDialog.xml", "HirePurchaseDialog", dialog)
end

function HirePurchaseDialog.new()
    local self = MessageDialog.new(nil, HirePurchaseDialog_mt, g_messageCenter, g_i18n, g_inputBinding)
    self.yard = nil
    self.item = nil
    self.itemIndex = nil
    self.financeAmount = 0
    self.creditUsed = 0
    self.depositOptions = nil
    self.depositIndex = 1
    self.durationMonths = 12
    self.offerings = nil
    self.offeringIndex = 1
    return self
end

function HirePurchaseDialog.show(yard, item, itemIndex, financeAmount, creditUsed)
    local dialog = g_gui.guis["HirePurchaseDialog"]
    if dialog == nil then return end
    local ctrl = dialog.target
    ctrl:setData(yard, item, itemIndex, financeAmount, creditUsed)
    g_gui:showDialog("HirePurchaseDialog")
end

function HirePurchaseDialog:setData(yard, item, itemIndex, financeAmount, creditUsed)
    self.yard = yard
    self.item = item
    self.itemIndex = itemIndex
    self.financeAmount = financeAmount
    self.creditUsed = creditUsed or 0

    local farm = g_farmManager:getFarmByUserId(g_currentMission.playerUserId)
    if farm == nil then return end

    local potentialDepositOptions = {
        financeAmount * 0.05,
        financeAmount * 0.1,
        financeAmount * 0.2,
        financeAmount * 0.3,
        financeAmount * 0.4,
        financeAmount * 0.5,
    }
    self.depositOptions = {}
    for _, amount in ipairs(potentialDepositOptions) do
        if amount <= farm.money then
            self.depositOptions[#self.depositOptions + 1] = amount
        end
    end

    if #self.depositOptions == 0 then
        InfoDialog.show(string.format(g_i18n:getText("uey_hp_notEnoughDeposit"),
            g_i18n:formatMoney(potentialDepositOptions[1], 0, true, true)))
        self:close()
        return
    end

    self.depositIndex = 1
    self.durationMonths = 12
    self.offeringIndex = 1
end

function HirePurchaseDialog:onOpen()
    HirePurchaseDialog:superClass().onOpen(self)
    self:populateDialog()
end

function HirePurchaseDialog:onClose()
    HirePurchaseDialog:superClass().onClose(self)
    self.yard = nil
    self.item = nil
    self.itemIndex = nil
    self.offerings = nil
end

function HirePurchaseDialog:onCreate()
end

function HirePurchaseDialog:populateDialog()
    if self.item == nil or self.depositOptions == nil then return end

    if self.vehiclePriceText ~= nil then
        self.vehiclePriceText:setText(g_i18n:formatMoney(self.item.price))
    end
    if self.creditAppliedText ~= nil then
        self.creditAppliedText:setText(self.creditUsed > 0
            and g_i18n:formatMoney(self.creditUsed) or g_i18n:getText("uey_credit_none"))
    end
    if self.financeAmountText ~= nil then
        self.financeAmountText:setText(g_i18n:formatMoney(self.financeAmount))
    end

    -- Deposit options
    local depositTexts = {}
    for _, deposit in ipairs(self.depositOptions) do
        local pct = math.floor(deposit / self.financeAmount * 100)
        depositTexts[#depositTexts + 1] = string.format("%s [%d%%]",
            g_i18n:formatMoney(deposit, 0, true, true), pct)
    end
    self.depositOption:setTexts(depositTexts)
    self.depositOption:setState(1)

    -- Duration options (years)
    local durationTexts = {}
    for years = 1, HirePurchaseDialog.MAX_DURATION_YEARS do
        durationTexts[#durationTexts + 1] = tostring(years) .. (years == 1
            and (" " .. g_i18n:getText("uey_hp_year"))
            or (" " .. g_i18n:getText("uey_hp_years")))
    end
    self.durationOption:setTexts(durationTexts)
    self.durationOption:setState(1)

    -- Offer selection
    self.offerOption:setTexts({"1", "2", "3", "4"})
    self.offerOption:setState(1)

    self:updateView()
end

HirePurchaseDialog.OFFER_ELEMENTS = {
    { interest = "offer1Interest", monthly = "offer1Monthly", final = "offer1Final", total = "offer1Total" },
    { interest = "offer2Interest", monthly = "offer2Monthly", final = "offer2Final", total = "offer2Total" },
    { interest = "offer3Interest", monthly = "offer3Monthly", final = "offer3Final", total = "offer3Total" },
    { interest = "offer4Interest", monthly = "offer4Monthly", final = "offer4Final", total = "offer4Total" },
}

function HirePurchaseDialog:updateView()
    self:refreshOfferings()
    if self.offerings == nil then return end

    for i, keys in ipairs(HirePurchaseDialog.OFFER_ELEMENTS) do
        local offer = self.offerings[i]
        if offer ~= nil then
            local interestEl = self[keys.interest]
            local monthlyEl  = self[keys.monthly]
            local finalEl    = self[keys.final]
            local totalEl    = self[keys.total]
            if interestEl then interestEl:setText(string.format("%.2f%%", offer:getInterestRate() * 100)) end
            if monthlyEl then monthlyEl:setText(g_i18n:formatMoney(offer:getMonthlyPayment(), 0, true, true)) end
            if finalEl then finalEl:setText(g_i18n:formatMoney(offer.finalFee, 0, true, true)) end
            if totalEl then totalEl:setText(g_i18n:formatMoney(offer:getTotalCost(), 0, true, true)) end
        end
    end
end

function HirePurchaseDialog:refreshOfferings()
    local deposit = self.depositOptions[self.depositIndex]
    if deposit == nil then return end

    local env = UsedEquipmentYards.getHirePurchaseEnv()
    if env == nil then return end

    local remainingValueOptions = { 0, 0.1, 0.2, 0.3 }
    self.offerings = {}
    for _, remainingPct in ipairs(remainingValueOptions) do
        self.offerings[#self.offerings + 1] = env.LeaseDeal.new(
            env.LeaseDeal.TYPE.HIRE_PURCHASE,
            self.financeAmount,
            deposit,
            self.durationMonths,
            self.financeAmount * remainingPct,
            0
        )
    end
end

function HirePurchaseDialog:onClickDepositLevel(index)
    self.depositIndex = index
    self:updateView()
end

function HirePurchaseDialog:onClickDuration(index)
    self.durationMonths = index * 12
    self:updateView()
end

function HirePurchaseDialog:onClickOfferSelection(index)
    self.offeringIndex = index
end

function HirePurchaseDialog:onClickConfirm()
    if self.item == nil or self.yard == nil or self.offerings == nil then return end

    local farmId = BarterDialog.getLocalFarmId()
    if farmId == nil then return end

    local leaseDeal = self.offerings[self.offeringIndex]
    if leaseDeal == nil then return end

    leaseDeal.farmId = farmId

    g_client:getServerConnection():sendEvent(
        HirePurchaseYardEvent.new(self.yard.id, self.itemIndex, farmId, leaseDeal))

    HirePurchaseDialog:superClass().close(self)
end

function HirePurchaseDialog:onClickClose()
    HirePurchaseDialog:superClass().close(self)
end
