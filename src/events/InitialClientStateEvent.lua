-- InitialClientStateEvent
-- Sent by the server to a client joining mid-game so they receive the full
-- list of existing yards and can register them locally (activatables, etc.).

InitialClientStateEvent = {}
local InitialClientStateEvent_mt = Class(InitialClientStateEvent, Event)

InitEventClass(InitialClientStateEvent, "InitialClientStateEvent")

function InitialClientStateEvent.emptyNew()
    return Event.new(InitialClientStateEvent_mt)
end

function InitialClientStateEvent.new()
    return InitialClientStateEvent.emptyNew()
end

function InitialClientStateEvent:writeStream(streamId, connection)
    local manager = UsedEquipmentYards.yardManager
    local yards   = (manager ~= nil) and manager.yards or {}

    -- Write yard count then each yard's data.
    local count = 0
    for _ in pairs(yards) do count = count + 1 end
    streamWriteInt32(streamId, count)

    for _, yard in pairs(yards) do
        streamWriteInt32(streamId,   yard.id)
        streamWriteString(streamId,  yard.name)
        streamWriteFloat32(streamId, yard.bounds.cx)
        streamWriteFloat32(streamId, yard.bounds.cy)
        streamWriteFloat32(streamId, yard.bounds.cz)
        streamWriteFloat32(streamId, yard.bounds.sizeX)
        streamWriteFloat32(streamId, yard.bounds.sizeZ)
        streamWriteFloat32(streamId, yard.bounds.anchorX or yard.bounds.cx)
        streamWriteFloat32(streamId, yard.bounds.anchorZ or yard.bounds.cz)

        local poly      = yard.bounds.polygon
        local vertCount = (poly ~= nil) and #poly or 0
        streamWriteInt32(streamId, vertCount)
        if poly ~= nil then
            for _, pt in ipairs(poly) do
                streamWriteFloat32(streamId, pt.x)
                streamWriteFloat32(streamId, pt.z)
            end
        end

        -- Yard config so clients have accurate settings for display.
        local cfg = yard.inventory.config
        streamWriteString(streamId, cfg.quality or "MEDIUM")
        streamWriteFloat32(streamId, cfg.dirtiness or 0.20)
        streamWriteInt32(streamId, cfg.minWorkingWidth or 0)
        streamWriteInt32(streamId, cfg.maxWorkingWidth or 0)
        streamWriteInt32(streamId, cfg.maxPrice or 0)
        streamWriteInt32(streamId, cfg.avgStockHours or 96)
        streamWriteInt32(streamId, cfg.gridSpacing or 8)

        local cats = {}
        for name, weight in pairs(cfg.categories or {}) do
            cats[#cats + 1] = { name = name, weight = weight }
        end
        streamWriteInt32(streamId, #cats)
        for _, c in ipairs(cats) do
            streamWriteString(streamId, c.name)
            streamWriteInt32(streamId, c.weight)
        end

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

    -- Barter state.
    BarterState.writeStream(streamId)

    -- Yard credit.
    YardCredit.writeStream(streamId)

    -- Sell offer cache.
    SellBarterDialog.writeOfferCacheStream(streamId)

    -- Recent sales memory.
    UsedEquipmentYards.writeRecentSalesStream(streamId)

    -- Yard vehicle items — so remote clients can interact with them.
    local totalItems = 0
    for _, yard in pairs(yards) do
        for _, item in ipairs(yard.inventory.items) do
            if item.vehicle ~= nil then
                totalItems = totalItems + 1
            end
        end
    end
    streamWriteInt32(streamId, totalItems)

    for _, yard in pairs(yards) do
        for idx, item in ipairs(yard.inventory.items) do
            if item.vehicle ~= nil then
                -- Reuse VehicleItemSyncEvent's write format.
                local syncEvent = VehicleItemSyncEvent.new(yard.id, idx, item)
                syncEvent:writeStream(streamId, connection)
            end
        end
    end
end

function InitialClientStateEvent:readStream(streamId, connection)
    local count = streamReadInt32(streamId)

    for _ = 1, count do
        local yardId   = streamReadInt32(streamId)
        local yardName = streamReadString(streamId)
        local bounds   = {
            cx    = streamReadFloat32(streamId),
            cy    = streamReadFloat32(streamId),
            cz    = streamReadFloat32(streamId),
            sizeX = streamReadFloat32(streamId),
            sizeZ = streamReadFloat32(streamId),
        }
        bounds.anchorX = streamReadFloat32(streamId)
        bounds.anchorZ = streamReadFloat32(streamId)

        local vertCount = streamReadInt32(streamId)
        if vertCount >= 3 then
            local poly = {}
            for i = 1, vertCount do
                poly[i] = {
                    x = streamReadFloat32(streamId),
                    z = streamReadFloat32(streamId),
                }
            end
            bounds.polygon = poly
        end

        -- Yard config.
        local cfg = {
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
            cfg.categories[name] = weight
        end
        local numBrands = streamReadInt32(streamId)
        for _ = 1, numBrands do
            local name   = streamReadString(streamId)
            local weight = streamReadInt32(streamId)
            cfg.brands[name] = weight
        end

        UsedEquipmentYards.registerClientYard(yardId, yardName, bounds, cfg)
    end

    -- Barter state.
    BarterState.readStream(streamId)

    -- Yard credit.
    YardCredit.readStream(streamId)

    -- Sell offer cache.
    SellBarterDialog.readOfferCacheStream(streamId)

    -- Recent sales memory.
    UsedEquipmentYards.readRecentSalesStream(streamId)

    -- Yard vehicle items.
    local totalItems = streamReadInt32(streamId)
    for _ = 1, totalItems do
        local syncEvent = VehicleItemSyncEvent.emptyNew()
        syncEvent:readStream(streamId, connection)
        -- readStream registers immediately or adds to pending for update-loop resolution.
    end

    self:run(connection)
end

function InitialClientStateEvent:run(connection)
    -- Nothing extra needed after registration.
end
