-- YardInventory on the row layout: stock fitted to rows on load (legacy
-- scatter moved, already-parked vehicles left alone), eviction when the rows
-- shrink, spawning only what fits, save/load of the layout, sold vehicles.

local TRACTOR = "data/tractor.xml"
local TRAILER = "data/trailer.xml"
local GIANT = "data/giant.xml"

local function setup()
    local world = stubs.install()
    world:load("src/UeyUtils.lua")
    world:load("src/YardLayout.lua")
    world:load("src/YardZone.lua")
    world:load("src/YardInventory.lua")
    world:load("src/UsedEquipmentYard.lua")
    YardInventory.HOURLY_SPAWN_CHANCE = 0 -- hourly ticks only age stock here
    world.tractor = world:addStoreItem({ xmlFilename = TRACTOR, width = 2.5, length = 5, lengthOffset = 0.4,
        category = "TRACTORSS" })
    world.trailer = world:addStoreItem({ xmlFilename = TRAILER, width = 2.55, length = 12, category = "TRAILERS" })
    world.giant = world:addStoreItem({ xmlFilename = GIANT, width = 4, length = 40, category = "TRACTORSS" })
    return world
end

local function rectBounds(width, depth)
    return {
        cx = width * 0.5, cy = 0, cz = depth * 0.5, sizeX = width, sizeZ = depth,
        polygon = { { x = 0, z = 0 }, { x = width, z = 0 }, { x = width, z = depth }, { x = 0, z = depth } },
    }
end

local function makeYard(width, depth, categories)
    local yard = UsedEquipmentYard.new(1, "Test Yard", rectBounds(width, depth))
    local config = YardInventory.copyConfig(YardInventory.DEFAULT_CONFIG)
    config.categories = categories or { TRACTORSS = 1 }
    config.maxDuplicates = 0 -- one model per category here: don't cap copies
    yard.inventory:applyConfig(config)
    return yard
end

-- A stock item for a vehicle already in the world (as a loaded save has).
local function addStock(world, yard, storeItem, x, z, yaw)
    local vehicle = world:addVehicle(storeItem, x, z, yaw)
    local item = {
        xmlFilename = storeItem.xmlFilename, price = 1000, minPrice = 900, numOwners = 1, age = 1,
        damage = 0, wear = 0, operatingTime = 0, ttlHours = 50, vehicle = vehicle,
    }
    table.insert(yard.inventory.items, item)
    table.insert(yard.inventory.vehicles, vehicle)
    return item
end

local function assertNoOverlaps(items)
    for i = 1, #items do
        for j = i + 1, #items do
            local a, b = items[i].slot, items[j].slot
            if a ~= nil and b ~= nil and a.row == b.row then
                assertTrue(a.u2 <= b.u1 or b.u2 <= a.u1, "two vehicles share row space")
            end
        end
    end
end

-- Each item's vehicle sits exactly where its slot puts its root.
local function assertParkedInSlots(world, inventory)
    for _, item in ipairs(inventory.items) do
        assertTrue(item.slot ~= nil, "item has a slot")
        local rx, rz, yaw = inventory:getRootPose(item)
        local x, _, z = getWorldTranslation(item.vehicle.rootNode)
        assertNear(x, rx, 1e-6)
        assertNear(z, rz, 1e-6)
        assertNear(world:getYaw(item.vehicle), yaw, 1e-6)
    end
end

test("scattered stock from an older save is moved into rows", function()
    local world = setup()
    local yard = makeYard(60, 40)
    for i = 1, 6 do
        addStock(world, yard, world.tractor, 5 + i * 7, 10 + (i % 3) * 8, i * 0.7)
    end
    yard.inventory:ensureLayout()
    assertEquals(world.moves, 6, "every vehicle moved")
    assertParkedInSlots(world, yard.inventory)
    assertNoOverlaps(yard.inventory.items)
    for _, vehicle in ipairs(world.vehicles) do
        assertTrue(vehicle.inPhysics, "back in physics")
    end
end)

test("the footprint, not the root, is centred in the slot", function()
    local world = setup()
    local yard = makeYard(60, 40)
    local item = addStock(world, yard, world.tractor, 30, 20, 0)
    yard.inventory:ensureLayout()
    local x, _, z = getWorldTranslation(item.vehicle.rootNode)
    local cx, cz = YardLayout.centerFromRoot(x, z, world:getYaw(item.vehicle), 0, 0.4)
    assertNear(cx, item.footX, 1e-6)
    assertNear(cz, item.footZ, 1e-6)
end)

test("vehicles already parked in their rows are left where they are", function()
    local world = setup()
    local yard = makeYard(60, 40)
    for i = 1, 5 do
        addStock(world, yard, world.tractor, 5 + i * 9, 20, 0)
    end
    yard.inventory:ensureLayout()
    local before = world.moves
    yard.inventory.layoutDirty = true
    yard.inventory:ensureLayout()
    assertEquals(world.moves, before, "nothing moved the second time")
    assertParkedInSlots(world, yard.inventory)
end)

test("stock that no longer fits a smaller yard is cleared out", function()
    local world = setup()
    local yard = makeYard(40, 30)
    local inventory = yard.inventory
    inventory:reset()
    inventory:update(600)
    local full = #inventory.items
    assertTrue(full >= 8, "filled: " .. full)

    -- The yard's outline is redrawn at half the size.
    yard.bounds.polygon = { { x = 0, z = 0 }, { x = 20, z = 0 }, { x = 20, z = 30 }, { x = 0, z = 30 } }
    inventory.layoutDirty = true
    inventory:ensureLayout()

    -- Whatever stands where a moved vehicle now goes is gone already; the
    -- rest waits for the next hour, as if sold.
    local evicting = 0
    for _, item in ipairs(inventory.items) do
        if item.evicting then
            evicting = evicting + 1
            assertEquals(item.ttlHours, 1)
            assertEquals(item.slot, nil)
        else
            assertTrue(yard:containsPoint(item.footX, item.footZ), "kept stock is inside the new outline")
        end
    end
    local afterReshape = #inventory.items
    assertTrue(afterReshape < full or evicting > 0, "some stock no longer fits")

    inventory:onHourChanged()
    for _, item in ipairs(inventory.items) do
        assertTrue(not item.evicting, "evicted stock removed at the hour")
    end
    assertEquals(#inventory.items, afterReshape - evicting)
    assertTrue(#inventory.items > 0, "what fits is kept")
    assertNoOverlaps(inventory.items)
end)

test("an evicted vehicle standing where another is moved to goes at once", function()
    local world = setup()
    local yard = makeYard(40, 30)
    local inventory = yard.inventory
    local plan = inventory:ensureLayout()
    -- A scattered vehicle that will be moved, and a giant one that fits
    -- nowhere, standing right on the spot the first is moved to.
    local first = YardLayout.findSlot(plan, {}, 2.5, 5)
    addStock(world, yard, world.tractor, 35, 3, 2.0)
    local blocker = addStock(world, yard, world.giant, first.x, first.z, 0)
    inventory.layoutDirty = true
    inventory:ensureLayout()
    assertTrue(blocker.vehicle == nil, "removed now")
    assertEquals(#inventory.items, 1)
    assertParkedInSlots(world, inventory)
end)

test("a yard fills with what fits and never rolls a model too big for it", function()
    local world = setup()
    local yard = makeYard(40, 30)
    yard.inventory:reset()
    yard.inventory:update(600)
    local items = yard.inventory.items
    assertTrue(#items > 0)
    for _, item in ipairs(items) do
        assertEquals(item.xmlFilename, TRACTOR, "the 40 m model never spawns")
    end
    assertNoOverlaps(items)
    assertParkedInSlots(world, yard.inventory)
    assertEquals(yard.inventory:findSlotFor(2.5, 5), nil, "full")
end)

test("a trailers-only yard fills with trailers", function()
    setup()
    local yard = makeYard(50, 40, { TRAILERS = 1 })
    yard.inventory:reset()
    yard.inventory:update(600)
    assertTrue(#yard.inventory.items >= 6, "trailers placed: " .. #yard.inventory.items)
    for _, row in ipairs(yard.inventory.plan.rows) do
        assertTrue(row.depth >= 12.5, "every row holds a 12 m trailer")
    end
end)

test("spawned vehicles keep their spot when a static object is in the way", function()
    local world = setup()
    local yard = makeYard(40, 30)
    local plan = yard.inventory:ensureLayout()
    local first = YardLayout.findSlot(plan, {}, 2.5, 5)
    table.insert(world.obstacles, { x = first.x, z = first.z })
    yard.inventory:reset()
    yard.inventory:update(600)
    for _, item in ipairs(yard.inventory.items) do
        local dx, dz = item.footX - first.x, item.footZ - first.z
        assertTrue(dx * dx + dz * dz > 1, "nothing parked on the obstacle")
    end
end)

test("rows and parked positions survive a save and load", function()
    local world = setup()
    local yard = makeYard(50, 40)
    yard.inventory:reset()
    yard.inventory:update(600)
    local count = #yard.inventory.items
    assertTrue(count > 0)

    local xmlFile = {}
    yard:saveToXML(xmlFile, "yard")
    local loaded = UsedEquipmentYard.loadFromXML(xmlFile, "yard")
    assertEquals(#loaded.inventory.items, count)
    assertTrue(loaded.inventory.layoutSpec ~= nil, "layout spec loaded")
    assertEquals(#loaded.inventory.layoutSpec.rowDepths, #yard.inventory.layoutSpec.rowDepths)

    -- The game restores the vehicles; spawn() finds them by uniqueId.
    local before = world.moves
    loaded.inventory:spawn()
    assertEquals(world.moves, before, "no vehicle moved after loading")
    assertParkedInSlots(world, loaded.inventory)
end)

test("an old save's outline repeating its first corner loads without it", function()
    setup()
    local yard = makeYard(50, 40)
    local polygon = YardZone.polygonOfBounds(yard.bounds)
    local corners = #polygon
    polygon[#polygon + 1] = { x = polygon[1].x, z = polygon[1].z }
    yard.bounds.polygon = polygon
    local xmlFile = {}
    yard:saveToXML(xmlFile, "yard")
    local loaded = UsedEquipmentYard.loadFromXML(xmlFile, "yard")
    assertEquals(#loaded.bounds.polygon, corners)
    assertTrue(YardZone.validate(loaded.bounds.polygon, {}))
end)

test("a sold vehicle standing in the yard is parked, not refused", function()
    local world = setup()
    local yard = makeYard(40, 30)
    local plan = yard.inventory:ensureLayout()
    local first = YardLayout.findSlot(plan, {}, 2.5, 5)
    -- The player drove it right onto the first free spot.
    local vehicle = world:addVehicle(world.tractor, first.x, first.z, 0)
    local item = yard.inventory:acceptSoldVehicle(vehicle, 1000)
    assertTrue(item ~= nil)
    assertEquals(#yard.inventory.pendingSoldItems, 0, "placed straight away")
    assertEquals(item.vehicle, vehicle)
    assertTrue(item.slot ~= nil)
    assertParkedInSlots(world, yard.inventory)
end)

test("a test-driven vehicle's return spot follows its slot", function()
    local world = setup()
    local yard = makeYard(60, 40)
    local item = addStock(world, yard, world.tractor, 12, 12, 1.0)
    item.testDrive = { farmId = 1, returnByDay = 2, returnByHour = 8, origX = 12, origY = 0, origZ = 12,
        origRx = 0, origRy = 1.0, origRz = 0 }
    yard.inventory:ensureLayout()
    assertEquals(world.moves, 0, "not moved while it's out")
    local rx, rz, yaw = yard.inventory:getRootPose(item)
    assertNear(item.testDrive.origX, rx, 1e-6)
    assertNear(item.testDrive.origZ, rz, 1e-6)
    assertNear(item.testDrive.origRy, yaw, 1e-6)
end)
