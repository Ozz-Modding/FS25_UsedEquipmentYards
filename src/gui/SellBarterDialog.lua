-- SellBarterDialog
-- Presents three offers when selling a vehicle to a yard.
-- Uses a MultiTextOption to cycle between offers (gamepad-friendly).
--   1. Cash offer  (3-5% below base value)
--   2. Credit offer (0-5% above base value, paid as yard credit)
--   3. Hybrid offer (~2% above base value, 80-90% cash / 10-20% credit)

SellBarterDialog = {}

local SellBarterDialog_mt = Class(SellBarterDialog, MessageDialog)

--- Format a price with the currency symbol before the number.
--- Uses g_i18n:formatMoney with prefixCurrencySymbol=true (4th param).
local function formatPrice(amount)
    return g_i18n:formatMoney(math.floor(amount), 0, true, true)
end

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------

function SellBarterDialog.register()
    local dialog = SellBarterDialog.new()
    g_gui:loadGui(UsedEquipmentYards.dir .. "gui/SellBarterDialog.xml", "SellBarterDialog", dialog)
end

-- Offer cache: keyed by vehicle uniqueId, stores { offers, day, hour }.
-- Expires after OFFER_TTL_HOURS in-game hours.
SellBarterDialog.OFFER_TTL_HOURS = 12
SellBarterDialog.offerCache = {}
-- Pending offer cache entries waiting for vehicle network objects to resolve.
-- { { objectId, offers, day, hour }, ... }
SellBarterDialog.pendingOfferCache = {}

function SellBarterDialog.new()
    local self = MessageDialog.new(nil, SellBarterDialog_mt, g_messageCenter, g_i18n, g_inputBinding)
    self.yard = nil
    self.vehicle = nil
    self.offers = nil       -- ordered list of { label, cash, credit }
    self.selectedOffer = 1
    return self
end

-- ---------------------------------------------------------------------------
-- Show / close
-- ---------------------------------------------------------------------------

function SellBarterDialog.show(yard, vehicle)
    local farmId = g_currentMission:getFarmId()
    if farmId == nil or farmId == FarmManager.SPECTATOR_FARM_ID then
        InfoDialog.show(g_i18n:getText("uey_sell_noFarm"))
        return
    end

    local dialog = g_gui.guis["SellBarterDialog"]
    if dialog == nil then return end
    local ctrl = dialog.target
    ctrl.yard = yard
    ctrl.vehicle = vehicle
    ctrl.offers = SellBarterDialog.getCachedOffers(ctrl, vehicle)
    ctrl.selectedOffer = 1
    g_gui:showDialog("SellBarterDialog")
end

function SellBarterDialog:onOpen()
    SellBarterDialog:superClass().onOpen(self)
    self:populateDialog()
end

function SellBarterDialog:onClose()
    SellBarterDialog:superClass().onClose(self)
    self.yard = nil
    self.vehicle = nil
    self.offers = nil
end

function SellBarterDialog:onCreate()
end

-- ---------------------------------------------------------------------------
-- Offer calculation
-- ---------------------------------------------------------------------------

--- Calculate the base sell value of a live vehicle using its actual
--- configured price, condition, and the game's sell price formula.
function SellBarterDialog.getBaseValue(vehicle)
    local storeItem = g_storeManager:getItemByXMLFilename(vehicle.configFileName)
    if storeItem == nil then return 0 end

    return Vehicle.calculateSellPrice(
        storeItem,
        vehicle.age,
        vehicle.operatingTime,
        vehicle:getPrice(),
        vehicle:getRepairPrice(),
        vehicle:getRepaintPrice()
    )
end

--- Generate the three offers (randomised each time the dialog opens).
--- Returns an ordered list so the MultiTextOption indices line up.
function SellBarterDialog:calculateOffers(vehicle)
    local baseValue = SellBarterDialog.getBaseValue(vehicle)
    if baseValue <= 0 then baseValue = 1 end

    -- Offer 1: Cash — 3-6% below base value (quick money, worst deal).
    local cashMultiplier = 0.94 + math.random() * 0.03
    local cashTotal = math.floor(baseValue * cashMultiplier)

    -- Offer 2: Credit — 3-5% above base value (best deal, all credit).
    local creditMultiplier = 1.03 + math.random() * 0.02
    local creditTotal = math.floor(baseValue * creditMultiplier)

    -- Offer 3: Hybrid — -2% to +2% of base value, 70-80% cash / 20-30% credit.
    local hybridMultiplier = 0.98 + math.random() * 0.04
    local hybridTotal = math.floor(baseValue * hybridMultiplier)
    local cashPortion = 0.70 + math.random() * 0.10
    local hybridCash = math.floor(hybridTotal * cashPortion)
    local hybridCredit = hybridTotal - hybridCash

    return {
        {
            label  = g_i18n:getText("uey_sell_cashOffer"),
            detail = formatPrice(cashTotal),
            cash   = cashTotal,
            credit = 0,
        },
        {
            label  = g_i18n:getText("uey_sell_creditOffer"),
            detail = formatPrice(creditTotal),
            cash   = 0,
            credit = creditTotal,
        },
        {
            label  = g_i18n:getText("uey_sell_hybridOffer"),
            detail = formatPrice(hybridCash) .. " + " .. formatPrice(hybridCredit),
            cash   = hybridCash,
            credit = hybridCredit,
        },
    }
end

-- ---------------------------------------------------------------------------
-- Offer cache — per vehicle (keyed by uniqueId), expires after
-- OFFER_TTL_HOURS in-game hours. Persisted across sessions.
-- ---------------------------------------------------------------------------

--- Return cached offers for a vehicle, or generate fresh ones.
function SellBarterDialog.getCachedOffers(ctrl, vehicle)
    local uid = vehicle.uniqueId
    if uid == nil then
        return ctrl:calculateOffers(vehicle)
    end

    local env = g_currentMission.environment
    local cached = SellBarterDialog.offerCache[uid]

    if cached ~= nil then
        local elapsed = (env.currentMonotonicDay - cached.day) * 24 + (env.currentHour - cached.hour)
        if elapsed < SellBarterDialog.OFFER_TTL_HOURS then
            return cached.offers
        end
    end

    -- Generate fresh and cache.
    local offers = ctrl:calculateOffers(vehicle)
    local day  = env.currentMonotonicDay
    local hour = env.currentHour
    SellBarterDialog.offerCache[uid] = {
        offers = offers,
        day    = day,
        hour   = hour,
    }

    -- Broadcast to other clients so farm members see the same offers.
    local objectId = NetworkUtil.getObjectId(vehicle)
    if objectId ~= nil then
        g_client:getServerConnection():sendEvent(
            OfferCacheSyncEvent.new(objectId, offers, day, hour))
    end

    return offers
end

--- Clear cached offers for a vehicle (e.g. after a sale).
function SellBarterDialog.clearCache(vehicle)
    if vehicle ~= nil and vehicle.uniqueId ~= nil then
        SellBarterDialog.offerCache[vehicle.uniqueId] = nil
    end
end

--- Receive offers from the network. Resolves objectId → uniqueId, or queues
--- for deferred resolution if the vehicle isn't available yet.
function SellBarterDialog.cacheFromNetwork(objectId, rawOffers, day, hour)
    local vehicle = NetworkUtil.getObject(objectId)
    if vehicle ~= nil and vehicle.uniqueId ~= nil then
        SellBarterDialog.rebuildOfferLabels(rawOffers)
        SellBarterDialog.offerCache[vehicle.uniqueId] = {
            offers = rawOffers,
            day    = day,
            hour   = hour,
        }
    else
        -- Vehicle not resolved yet — queue for later.
        SellBarterDialog.pendingOfferCache[#SellBarterDialog.pendingOfferCache + 1] = {
            objectId = objectId,
            offers   = rawOffers,
            day      = day,
            hour     = hour,
        }
    end
end

--- Resolve pending offer cache entries. Called from the main update loop.
function SellBarterDialog.resolvePendingOfferCache()
    local pending = SellBarterDialog.pendingOfferCache
    local i = #pending
    while i >= 1 do
        local entry = pending[i]
        local vehicle = NetworkUtil.getObject(entry.objectId)
        if vehicle ~= nil and vehicle.uniqueId ~= nil then
            SellBarterDialog.rebuildOfferLabels(entry.offers)
            SellBarterDialog.offerCache[vehicle.uniqueId] = {
                offers = entry.offers,
                day    = entry.day,
                hour   = entry.hour,
            }
            table.remove(pending, i)
        end
        i = i - 1
    end
end

--- Rebuild display labels on raw offers (after load or network receive).
function SellBarterDialog.rebuildOfferLabels(offers)
    if #offers < 3 then return end
    offers[1].label  = g_i18n:getText("uey_sell_cashOffer")
    offers[1].detail = formatPrice(offers[1].cash)
    offers[2].label  = g_i18n:getText("uey_sell_creditOffer")
    offers[2].detail = formatPrice(offers[2].credit)
    offers[3].label  = g_i18n:getText("uey_sell_hybridOffer")
    offers[3].detail = formatPrice(offers[3].cash) .. " + " .. formatPrice(offers[3].credit)
end

-- ---------------------------------------------------------------------------
-- Network streaming (for InitialClientStateEvent)
-- ---------------------------------------------------------------------------

function SellBarterDialog.writeOfferCacheStream(streamId)
    -- Collect entries that can be resolved to objectIds.
    local entries = {}
    for uid, cached in pairs(SellBarterDialog.offerCache) do
        local vehicle = g_currentMission.vehicleSystem:getVehicleByUniqueId(uid)
        if vehicle ~= nil then
            local objectId = NetworkUtil.getObjectId(vehicle)
            if objectId ~= nil then
                entries[#entries + 1] = { objectId = objectId, cached = cached }
            end
        end
    end

    streamWriteInt32(streamId, #entries)
    for _, e in ipairs(entries) do
        streamWriteInt32(streamId, e.objectId)
        streamWriteInt32(streamId, e.cached.day)
        streamWriteInt32(streamId, e.cached.hour)
        for _, offer in ipairs(e.cached.offers) do
            streamWriteInt32(streamId, offer.cash)
            streamWriteInt32(streamId, offer.credit)
        end
    end
end

function SellBarterDialog.readOfferCacheStream(streamId)
    SellBarterDialog.offerCache = {}
    SellBarterDialog.pendingOfferCache = {}
    local count = streamReadInt32(streamId)
    for _ = 1, count do
        local objectId = streamReadInt32(streamId)
        local day      = streamReadInt32(streamId)
        local hour     = streamReadInt32(streamId)
        local offers   = {}
        for _ = 1, 3 do
            offers[#offers + 1] = {
                cash   = streamReadInt32(streamId),
                credit = streamReadInt32(streamId),
            }
        end
        SellBarterDialog.cacheFromNetwork(objectId, offers, day, hour)
    end
end

-- ---------------------------------------------------------------------------
-- Offer cache persistence
-- ---------------------------------------------------------------------------

function SellBarterDialog.saveOffersToXML(xmlFile, rootKey)
    local i = 0
    for uid, cached in pairs(SellBarterDialog.offerCache) do
        local cKey = ("%s.offerCache.entry(%d)"):format(rootKey, i)
        setXMLString(xmlFile, cKey .. "#vehicleUniqueId", uid)
        setXMLInt(xmlFile, cKey .. "#day", cached.day)
        setXMLInt(xmlFile, cKey .. "#hour", cached.hour)

        for j, offer in ipairs(cached.offers) do
            local oKey = ("%s.offer(%d)"):format(cKey, j - 1)
            setXMLInt(xmlFile, oKey .. "#cash", offer.cash)
            setXMLInt(xmlFile, oKey .. "#credit", offer.credit)
        end
        i = i + 1
    end
end

function SellBarterDialog.loadOffersFromXML(xmlFile, rootKey)
    SellBarterDialog.offerCache = {}
    local i = 0
    while true do
        local cKey = ("%s.offerCache.entry(%d)"):format(rootKey, i)
        if not hasXMLProperty(xmlFile, cKey) then break end

        local uid  = getXMLString(xmlFile, cKey .. "#vehicleUniqueId")
        local day  = getXMLInt(xmlFile, cKey .. "#day") or 0
        local hour = getXMLInt(xmlFile, cKey .. "#hour") or 0

        local offers = {}
        local j = 0
        while true do
            local oKey = ("%s.offer(%d)"):format(cKey, j)
            if not hasXMLProperty(xmlFile, oKey) then break end
            local cash   = getXMLInt(xmlFile, oKey .. "#cash") or 0
            local credit = getXMLInt(xmlFile, oKey .. "#credit") or 0
            offers[#offers + 1] = {
                cash   = cash,
                credit = credit,
            }
            j = j + 1
        end

        if uid ~= nil and #offers == 3 then
            SellBarterDialog.rebuildOfferLabels(offers)
            SellBarterDialog.offerCache[uid] = { offers = offers, day = day, hour = hour }
        end
        i = i + 1
    end
end

-- ---------------------------------------------------------------------------
-- Populate
-- ---------------------------------------------------------------------------

function SellBarterDialog:populateDialog()
    if self.vehicle == nil or self.offers == nil then return end

    self.dialogTitleElement:setText(self.vehicle:getFullName())

    -- Vehicle info.
    local storeItem = g_storeManager:getItemByXMLFilename(self.vehicle.configFileName)
    local brand = storeItem ~= nil and g_brandManager:getBrandByIndex(storeItem.brandIndex) or nil
    self.brandText:setText(brand ~= nil and brand.title or "—")

    local hours = math.floor(self.vehicle.operatingTime / 3600000)
    self.hoursText:setText(tostring(hours))

    local damage = self.vehicle.getDamageAmount ~= nil and self.vehicle:getDamageAmount() or 0
    local wear = self.vehicle.getWearTotalAmount ~= nil and self.vehicle:getWearTotalAmount() or 0
    self.damageText:setText(("%d %%"):format(math.floor(damage * 100)))
    self.wearText:setText(("%d %%"):format(math.floor(wear * 100)))

    -- Offer selector.
    local texts = {}
    for _, offer in ipairs(self.offers) do
        texts[#texts + 1] = offer.label .. ": " .. offer.detail
    end
    self.offerSelector:setTexts(texts)
    self.offerSelector:setState(1)
    self.selectedOffer = 1
    self:updateOfferDetail()
end

-- ---------------------------------------------------------------------------
-- Offer detail display
-- ---------------------------------------------------------------------------

function SellBarterDialog:updateOfferDetail()
    local offer = self.offers[self.selectedOffer]
    if offer == nil then return end

    self.detailCashText:setText(formatPrice(offer.cash))
    self.detailCreditText:setText(formatPrice(offer.credit))
    self.detailTotalText:setText(formatPrice(offer.cash + offer.credit))
end

function SellBarterDialog:onOfferChanged(state)
    self.selectedOffer = state
    self:updateOfferDetail()
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

function SellBarterDialog:onClickAccept()
    local offer = self.offers[self.selectedOffer]
    if offer == nil or self.vehicle == nil or self.yard == nil then return end

    local farmId = g_currentMission:getFarmId()
    if farmId == nil or farmId == FarmManager.SPECTATOR_FARM_ID then return end

    local vehicleName = self.vehicle:getFullName()
    local vehicleId = NetworkUtil.getObjectId(self.vehicle)

    SellBarterDialog.clearCache(self.vehicle)

    g_client:getServerConnection():sendEvent(
        VehicleSoldEvent.new(self.yard.id, farmId, vehicleId, offer.cash, offer.credit))

    self:close()

    local cashStr = formatPrice(offer.cash)
    local creditStr = formatPrice(offer.credit)
    InfoDialog.show(string.format(g_i18n:getText("uey_sell_success"), vehicleName, cashStr, creditStr))
end

function SellBarterDialog:onClickClose()
    self:close()
end
