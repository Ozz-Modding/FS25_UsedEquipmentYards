-- BarterState
-- Tracks barter attempts per farm per yard per in-game day.
-- Runs on ALL clients (server + remote) so the UI can gate attempts locally.
-- Authoritative validation happens on the server in BarterAttemptEvent.

BarterState = {}

BarterState.MAX_CHANCES_PER_DAY = 3

-- { ["farmId_yardId"] = { day = N, used = N, acceptedItems = { [itemIndex] = true } } }
BarterState.data = {}

function BarterState.init()
    BarterState.data = {}
    g_messageCenter:subscribe(MessageType.DAY_CHANGED, BarterState.onDayChanged)
end

function BarterState.delete()
    g_messageCenter:unsubscribe(MessageType.DAY_CHANGED, BarterState)
    BarterState.data = {}
end

function BarterState.onDayChanged()
    -- Reset all daily counts. Keep acceptedItems (persistent until vehicle leaves).
    for _, state in pairs(BarterState.data) do
        state.used = 0
        state.day = g_currentMission.environment.currentDay
    end
end

--- Get or create the state entry for a farm + yard combo.
function BarterState.getEntry(farmId, yardId)
    local key = tostring(farmId) .. "_" .. tostring(yardId)
    local currentDay = g_currentMission.environment.currentDay
    local entry = BarterState.data[key]

    if entry == nil or entry.day ~= currentDay then
        entry = { day = currentDay, used = 0, acceptedItems = entry and entry.acceptedItems or {} }
        BarterState.data[key] = entry
    end
    return entry
end

--- How many barter chances remain today for this farm at this yard.
function BarterState.getRemainingChances(farmId, yardId)
    local entry = BarterState.getEntry(farmId, yardId)
    return math.max(0, BarterState.MAX_CHANCES_PER_DAY - entry.used)
end

--- Record that an attempt was made (called on all clients via broadcast).
function BarterState.recordAttempt(farmId, yardId)
    local entry = BarterState.getEntry(farmId, yardId)
    entry.used = entry.used + 1
end

--- Record that an item was accepted (no more bartering on this item for this farm).
function BarterState.recordAccepted(farmId, yardId, itemIndex)
    local entry = BarterState.getEntry(farmId, yardId)
    entry.acceptedItems[itemIndex] = true
end

--- Has this farm already had a barter accepted on this item?
function BarterState.isItemAccepted(farmId, yardId, itemIndex)
    local entry = BarterState.getEntry(farmId, yardId)
    return entry.acceptedItems[itemIndex] == true
end

-- ---------------------------------------------------------------------------
-- XML persistence (called from YardManager save/load)
-- ---------------------------------------------------------------------------

function BarterState.saveToXML(xmlFile, rootKey)
    local i = 0
    for key, entry in pairs(BarterState.data) do
        local eKey = ("%s.barterState.entry(%d)"):format(rootKey, i)
        setXMLString(xmlFile, eKey .. "#key", key)
        setXMLInt(xmlFile, eKey .. "#day", entry.day or 0)
        setXMLInt(xmlFile, eKey .. "#used", entry.used or 0)

        local ai = 0
        for itemIndex, _ in pairs(entry.acceptedItems or {}) do
            setXMLInt(xmlFile, ("%s.accepted(%d)#itemIndex"):format(eKey, ai), itemIndex)
            ai = ai + 1
        end
        i = i + 1
    end
end

function BarterState.loadFromXML(xmlFile, rootKey)
    BarterState.data = {}
    local i = 0
    while true do
        local eKey = ("%s.barterState.entry(%d)"):format(rootKey, i)
        if not hasXMLProperty(xmlFile, eKey) then break end

        local key  = getXMLString(xmlFile, eKey .. "#key")
        local day  = getXMLInt(xmlFile, eKey .. "#day") or 0
        local used = getXMLInt(xmlFile, eKey .. "#used") or 0

        local acceptedItems = {}
        local ai = 0
        while true do
            local aKey = ("%s.accepted(%d)"):format(eKey, ai)
            if not hasXMLProperty(xmlFile, aKey) then break end
            local itemIndex = getXMLInt(xmlFile, aKey .. "#itemIndex")
            if itemIndex ~= nil then
                acceptedItems[itemIndex] = true
            end
            ai = ai + 1
        end

        if key ~= nil then
            BarterState.data[key] = { day = day, used = used, acceptedItems = acceptedItems }
        end
        i = i + 1
    end
end

-- ---------------------------------------------------------------------------
-- Network streaming (for InitialClientStateEvent)
-- ---------------------------------------------------------------------------

function BarterState.writeStream(streamId)
    local entries = {}
    for key, entry in pairs(BarterState.data) do
        entries[#entries + 1] = { key = key, entry = entry }
    end

    streamWriteInt32(streamId, #entries)
    for _, e in ipairs(entries) do
        streamWriteString(streamId, e.key)
        streamWriteInt32(streamId, e.entry.day or 0)
        streamWriteInt32(streamId, e.entry.used or 0)

        local accepted = {}
        for itemIndex, _ in pairs(e.entry.acceptedItems or {}) do
            accepted[#accepted + 1] = itemIndex
        end
        streamWriteInt32(streamId, #accepted)
        for _, idx in ipairs(accepted) do
            streamWriteInt32(streamId, idx)
        end
    end
end

function BarterState.readStream(streamId)
    BarterState.data = {}
    local count = streamReadInt32(streamId)
    for _ = 1, count do
        local key  = streamReadString(streamId)
        local day  = streamReadInt32(streamId)
        local used = streamReadInt32(streamId)

        local acceptedItems = {}
        local numAccepted = streamReadInt32(streamId)
        for _ = 1, numAccepted do
            acceptedItems[streamReadInt32(streamId)] = true
        end

        BarterState.data[key] = { day = day, used = used, acceptedItems = acceptedItems }
    end
end
