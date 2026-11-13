-- The server side of the yard tool: create / reshape / remove requests
-- (YardZoneEvent → YardManager), what clients are told, permissions, the
-- network format, the brush registration and the old-save cleanup.

local TRACTOR = "data/tractor.xml"

local function setup()
    local world = stubs.install()
    world:loadMod()
    world:addStoreItem({ xmlFilename = TRACTOR, width = 2.5, length = 5, category = "TRACTORSS" })
    UsedEquipmentYards.yardManager = YardManager.new(UsedEquipmentYards)
    return world, UsedEquipmentYards.yardManager
end

local function square(x, z, size)
    return { { x = x, z = z }, { x = x + size, z = z }, { x = x + size, z = z + size }, { x = x, z = z + size } }
end

local function broadcastsOf(world, eventClass)
    local found = {}
    for _, event in ipairs(world.broadcasts) do
        if getmetatable(event) ~= nil and getmetatable(event).__index == eventClass then
            table.insert(found, event)
        end
    end
    return found
end

local function onlyYard(manager)
    local id, yard = next(manager.yards)
    assertTrue(yard ~= nil, "a yard exists")
    assertEquals(next(manager.yards, id), nil, "only one yard")
    return yard
end

local OP = function()
    return YardZoneEvent.OP
end

test("the yard tool is registered with the build menu", function()
    local world = setup()
    assertEquals(#world.brushTypes, 1)
    local entry = world.brushTypes[1]
    assertEquals(entry.typeName, "ueyYardZone")
    assertEquals(entry.className, "UeyYardZoneBrush")
    assertEquals(entry.filename, "./src/brush/UeyYardZoneBrush.lua")
    assertEquals(entry.customEnvironment, "FS25_UsedEquipmentYards")
end)

test("the tool's store items name the brush type with the mod's prefix", function()
    setup()
    for _, path in ipairs({ "xml/YardZoneTool.xml", "xml/YardZoneRemoveTool.xml" }) do
        local file = io.open(path, "r")
        local content = file:read("*a")
        file:close()
        assertTrue(content:find("<type>FS25_UsedEquipmentYards.ueyYardZone</type>", 1, true) ~= nil, path)
    end
end)

test("a drawn outline becomes a yard, and clients are told", function()
    local world, manager = setup()
    local ok = manager:applyZoneRequest(OP().CREATE, 0, square(0, 0, 40))
    assertTrue(ok)
    local yard = onlyYard(manager)
    assertEquals(#yard.bounds.polygon, 4)
    assertNear(yard.bounds.cx, 20, 1e-9)
    assertNear(yard.bounds.sizeX, 40, 1e-9)
    assertTrue(yard.name ~= nil and yard.name ~= "")
    assertEquals(#broadcastsOf(world, YardCreatedEvent), 1)
end)

test("an outline crossing another yard is refused", function()
    local _, manager = setup()
    manager:applyZoneRequest(OP().CREATE, 0, square(0, 0, 40))
    local ok, err = manager:applyZoneRequest(OP().CREATE, 0, square(30, 30, 40))
    assertTrue(not ok)
    assertEquals(err, YardZone.ERROR.OVERLAPS_YARD)
end)

test("a bad outline is refused even if the client let it through", function()
    local _, manager = setup()
    local ok, err = manager:applyZoneRequest(OP().CREATE, 0, { { x = 0, z = 0 }, { x = 40, z = 40 },
        { x = 40, z = 0 }, { x = 0, z = 40 } })
    assertTrue(not ok)
    assertEquals(err, YardZone.ERROR.SELF_INTERSECTING)
    assertEquals(next(manager.yards), nil)
end)

test("reshaping a yard updates it, tells clients, and clears out stock that no longer fits", function()
    local world, manager = setup()
    manager:applyZoneRequest(OP().CREATE, 0, square(0, 0, 50))
    local yard = onlyYard(manager)
    yard.inventory.config.maxDuplicates = 0
    yard.inventory:reset()
    yard.inventory:update(600)
    local before = #yard.inventory.items
    assertTrue(before >= 8, "stocked: " .. before)

    local ok = manager:applyZoneRequest(OP().UPDATE, yard.id, square(0, 0, 25))
    assertTrue(ok)
    assertNear(yard.bounds.sizeX, 25, 1e-9)
    assertEquals(#broadcastsOf(world, YardUpdatedEvent), 1)
    local kept = 0
    for _, item in ipairs(yard.inventory.items) do
        if item.evicting then
            assertEquals(item.ttlHours, 1)
        else
            kept = kept + 1
            assertTrue(yard:containsPoint(item.footX, item.footZ), "kept stock is inside the new outline")
        end
    end
    assertTrue(kept < before, "some stock no longer fits")
end)

test("a yard can be reshaped over its own old outline", function()
    local _, manager = setup()
    manager:applyZoneRequest(OP().CREATE, 0, square(0, 0, 40))
    local yard = onlyYard(manager)
    assertTrue(manager:applyZoneRequest(OP().UPDATE, yard.id, square(5, 5, 40)), "only other yards count")
end)

test("reshaping an unknown yard is refused", function()
    local _, manager = setup()
    local ok, err = manager:applyZoneRequest(OP().UPDATE, 99, square(0, 0, 40))
    assertTrue(not ok)
    assertEquals(err, "noYard")
end)

test("removing a yard removes its stock and tells clients", function()
    local world, manager = setup()
    manager:applyZoneRequest(OP().CREATE, 0, square(0, 0, 40))
    local yard = onlyYard(manager)
    yard.inventory:reset()
    yard.inventory:update(600)
    assertTrue(#world.vehicles > 0)
    assertTrue(manager:applyZoneRequest(OP().DELETE, yard.id))
    assertEquals(next(manager.yards), nil)
    assertEquals(#world.vehicles, 0, "its vehicles are deleted")
    assertEquals(#broadcastsOf(world, YardRemovedEvent), 1)
end)

test("a yard with sale zones can't be removed", function()
    local world, manager = setup()
    manager:applyZoneRequest(OP().CREATE, 0, square(0, 0, 40))
    local yard = onlyYard(manager)
    table.insert(world.placeables, { [PlaceableSaleZone.KEY] = { yardId = yard.id } })
    local ok, err = manager:applyZoneRequest(OP().DELETE, yard.id)
    assertTrue(not ok)
    assertEquals(err, "hasSaleZones")
    assertTrue(manager.yards[yard.id] ~= nil)
end)

test("only the host or an admin can change yards", function()
    local world, manager = setup()
    YardZoneEvent.new(OP().CREATE, 0, square(0, 0, 40)):run(world:clientConnection(false, false))
    assertEquals(next(manager.yards), nil, "a plain player is refused")
    YardZoneEvent.new(OP().CREATE, 0, square(0, 0, 40)):run(world:clientConnection(true, false))
    assertTrue(next(manager.yards) ~= nil, "an admin is allowed")
    YardZoneEvent.new(OP().CREATE, 0, square(100, 0, 40)):run(world:clientConnection(false, true))
    local count = 0
    for _ in pairs(manager.yards) do
        count = count + 1
    end
    assertEquals(count, 2, "the host's own (local) connection is allowed")
end)

test("a yard request survives the network", function()
    local world = setup()
    local sent = YardZoneEvent.new(OP().UPDATE, 7, square(1.5, 2.5, 30))
    local stream = world:newStream()
    sent:writeStream(stream, nil)
    local received = YardZoneEvent.emptyNew()
    received.run = function() end
    received:readStream(stream, nil)
    assertEquals(received.op, OP().UPDATE)
    assertEquals(received.yardId, 7)
    assertEquals(#received.polygon, 4)
    assertNear(received.polygon[3].x, 31.5, 1e-9)
    assertEquals(#stream, 0, "nothing left unread")
end)

test("a reshaped outline reaches remote clients", function()
    local world, manager = setup()
    manager:applyZoneRequest(OP().CREATE, 0, square(0, 0, 40))
    local yard = onlyYard(manager)
    -- A remote client knows the yard from before.
    UsedEquipmentYards.clientYards[yard.id] = UsedEquipmentYard.new(yard.id, yard.name,
        YardZone.boundsFromPolygon(square(0, 0, 40)))
    manager:applyZoneRequest(OP().UPDATE, yard.id, square(0, 0, 30))
    local event = broadcastsOf(world, YardUpdatedEvent)[1]
    local stream = world:newStream()
    event:writeStream(stream, nil)
    local received = YardUpdatedEvent.emptyNew()
    received:readStream(stream, nil)
    assertNear(UsedEquipmentYards.clientYards[yard.id].bounds.sizeX, 30, 1e-6)
    assertEquals(#UsedEquipmentYards.clientYards[yard.id].bounds.polygon, 4)
end)

test("old saves: the yard building and fence go, the yard stays", function()
    local world, manager = setup()
    manager:applyZoneRequest(OP().CREATE, 0, square(0, 0, 40))
    local yard = onlyYard(manager)
    local deleted = false
    local legacy = { [PlaceableUsedEquipmentYard.KEY] = { yardId = yard.id } }
    function legacy:delete()
        deleted = true
        -- What Placeable:delete does on the server, eventually.
        PlaceableUsedEquipmentYard.onDelete(self)
    end
    legacy.isServer = true
    table.insert(world.placeables, legacy)
    table.insert(world.placeables, { [PlaceableSaleZone.KEY] = { yardId = yard.id }, delete = function()
        error("sale zones are not touched")
    end })
    UsedEquipmentYards.removeLegacyPlaceables()
    assertTrue(deleted)
    assertTrue(manager.yards[yard.id] ~= nil, "the yard is kept")
end)
