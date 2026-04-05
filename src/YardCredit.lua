-- YardCredit
-- Tracks per-farm per-yard credit balances.
-- Credit is earned by selling vehicles to a yard and spent when buying.
-- Runs on ALL clients (server + remote) so the UI can display balances locally.

YardCredit = {}

-- { ["farmId_yardId"] = { balance = N } }
YardCredit.data = {}

function YardCredit.init()
    YardCredit.data = {}
end

function YardCredit.delete()
    YardCredit.data = {}
end

--- Get the credit balance for a farm at a specific yard.
function YardCredit.getBalance(farmId, yardId)
    local key = tostring(farmId) .. "_" .. tostring(yardId)
    local entry = YardCredit.data[key]
    if entry == nil then return 0 end
    return entry.balance or 0
end

--- Add credit to a farm's balance at a yard.
function YardCredit.addCredit(farmId, yardId, amount)
    if amount <= 0 then return end
    local key = tostring(farmId) .. "_" .. tostring(yardId)
    local entry = YardCredit.data[key]
    if entry == nil then
        entry = { balance = 0 }
        YardCredit.data[key] = entry
    end
    entry.balance = entry.balance + amount
end

--- Deduct credit from a farm's balance at a yard.
--- Returns the amount actually deducted (clamped to available balance).
function YardCredit.deductCredit(farmId, yardId, amount)
    if amount <= 0 then return 0 end
    local key = tostring(farmId) .. "_" .. tostring(yardId)
    local entry = YardCredit.data[key]
    if entry == nil or entry.balance <= 0 then return 0 end

    local deducted = math.min(entry.balance, amount)
    entry.balance = entry.balance - deducted
    return deducted
end

-- ---------------------------------------------------------------------------
-- XML persistence (called from YardManager save/load)
-- ---------------------------------------------------------------------------

function YardCredit.saveToXML(xmlFile, rootKey)
    local i = 0
    for key, entry in pairs(YardCredit.data) do
        if entry.balance > 0 then
            local eKey = ("%s.yardCredit.entry(%d)"):format(rootKey, i)
            setXMLString(xmlFile, eKey .. "#key", key)
            setXMLInt(xmlFile, eKey .. "#balance", math.floor(entry.balance))
            i = i + 1
        end
    end
end

function YardCredit.loadFromXML(xmlFile, rootKey)
    YardCredit.data = {}
    local i = 0
    while true do
        local eKey = ("%s.yardCredit.entry(%d)"):format(rootKey, i)
        if not hasXMLProperty(xmlFile, eKey) then break end

        local key     = getXMLString(xmlFile, eKey .. "#key")
        local balance = getXMLInt(xmlFile, eKey .. "#balance") or 0

        if key ~= nil and balance > 0 then
            YardCredit.data[key] = { balance = balance }
        end
        i = i + 1
    end
end

-- ---------------------------------------------------------------------------
-- Network streaming (for InitialClientStateEvent)
-- ---------------------------------------------------------------------------

function YardCredit.writeStream(streamId)
    local entries = {}
    for key, entry in pairs(YardCredit.data) do
        if entry.balance > 0 then
            entries[#entries + 1] = { key = key, balance = entry.balance }
        end
    end

    streamWriteInt32(streamId, #entries)
    for _, e in ipairs(entries) do
        streamWriteString(streamId, e.key)
        streamWriteInt32(streamId, math.floor(e.balance))
    end
end

function YardCredit.readStream(streamId)
    YardCredit.data = {}
    local count = streamReadInt32(streamId)
    for _ = 1, count do
        local key     = streamReadString(streamId)
        local balance = streamReadInt32(streamId)
        if key ~= nil and balance > 0 then
            YardCredit.data[key] = { balance = balance }
        end
    end
end
