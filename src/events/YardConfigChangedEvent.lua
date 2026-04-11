-- YardConfigChangedEvent
-- Client → Server → Broadcast: sync yard config and name changes.
-- Server validates, applies the config, then broadcasts to all clients.

YardConfigChangedEvent = {}
local YardConfigChangedEvent_mt = Class(YardConfigChangedEvent, Event)

InitEventClass(YardConfigChangedEvent, "YardConfigChangedEvent")

function YardConfigChangedEvent.emptyNew()
    return Event.new(YardConfigChangedEvent_mt)
end

function YardConfigChangedEvent.new(yardId, yardName, config)
    local self = YardConfigChangedEvent.emptyNew()
    self.yardId   = yardId
    self.yardName = yardName
    self.config   = config
    return self
end

function YardConfigChangedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.yardId)
    streamWriteString(streamId, self.yardName or "")

    local cfg = self.config
    streamWriteString(streamId, cfg.quality or "MEDIUM")
    streamWriteFloat32(streamId, cfg.dirtiness or 0.20)
    streamWriteInt32(streamId, cfg.minWorkingWidth or 0)
    streamWriteInt32(streamId, cfg.maxWorkingWidth or 0)
    streamWriteInt32(streamId, cfg.maxPrice or 0)
    streamWriteInt32(streamId, cfg.avgStockHours or 96)
    streamWriteInt32(streamId, cfg.gridSpacing or 8)

    -- Categories: count then name+weight pairs.
    local cats = {}
    for name, weight in pairs(cfg.categories or {}) do
        cats[#cats + 1] = { name = name, weight = weight }
    end
    streamWriteInt32(streamId, #cats)
    for _, c in ipairs(cats) do
        streamWriteString(streamId, c.name)
        streamWriteInt32(streamId, c.weight)
    end

    -- Brands: count then name+weight pairs.
    local brands = {}
    for name, weight in pairs(cfg.brands or {}) do
        brands[#brands + 1] = { name = name, weight = weight }
    end
    streamWriteInt32(streamId, #brands)
    for _, b in ipairs(brands) do
        streamWriteString(streamId, b.name)
        streamWriteInt32(streamId, b.weight)
    end
end

function YardConfigChangedEvent:readStream(streamId, connection)
    self.yardId   = streamReadInt32(streamId)
    self.yardName = streamReadString(streamId)

    self.config = {
        quality         = streamReadString(streamId),
        dirtiness       = streamReadFloat32(streamId),
        minWorkingWidth = streamReadInt32(streamId),
        maxWorkingWidth = streamReadInt32(streamId),
        maxPrice        = streamReadInt32(streamId),
        avgStockHours   = streamReadInt32(streamId),
        gridSpacing     = streamReadInt32(streamId),
        categories      = {},
        brands          = {},
    }

    local numCats = streamReadInt32(streamId)
    for _ = 1, numCats do
        local name   = streamReadString(streamId)
        local weight = streamReadInt32(streamId)
        self.config.categories[name] = weight
    end

    local numBrands = streamReadInt32(streamId)
    for _ = 1, numBrands do
        local name   = streamReadString(streamId)
        local weight = streamReadInt32(streamId)
        self.config.brands[name] = weight
    end

    self:run(connection)
end

function YardConfigChangedEvent:run(connection)
    if not connection:getIsServer() then
        -- SERVER: validate, apply, broadcast.
        local manager = UsedEquipmentYards.yardManager
        if manager == nil then return end
        local yard = manager.yards[self.yardId]
        if yard == nil then return end

        -- Apply name change.
        if self.yardName ~= nil and self.yardName ~= "" and self.yardName ~= yard.name then
            YardNameGenerator.rename(yard.name, self.yardName)
            yard.name = self.yardName
        end

        -- Apply config.
        yard.inventory:applyConfig(self.config)

        -- Broadcast to all clients (including the sender).
        g_server:broadcastEvent(YardConfigChangedEvent.new(self.yardId, yard.name, yard.inventory.config))
        return
    end

    -- CLIENT: apply config + name to local client yard.
    local yard = UsedEquipmentYards.clientYards[self.yardId]
    if yard ~= nil then
        if self.yardName ~= nil and self.yardName ~= "" then
            yard.name = self.yardName
        end
        yard.inventory:applyConfig(self.config)
    end
end
