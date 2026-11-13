-- The yard tool in the build menu (UeyYardZoneBrush): drawing a new yard,
-- reshaping one by dragging corners and edges, undo, cancel, removing a yard,
-- and what it shows. Driven with a fake cursor and mouse.

local TRACTOR = "data/tractor.xml"

local function setup(mode)
    local world = stubs.install()
    world:loadMod()
    world:addStoreItem({ xmlFilename = TRACTOR, width = 2.5, length = 5, category = "TRACTORSS" })
    UsedEquipmentYards.yardManager = YardManager.new(UsedEquipmentYards)
    world:loadBrush()
    local brush = UeyYardZoneBrush.new(nil, world:makeCursor())
    brush:setParameters(mode or "zone")
    brush:activate()
    return world, brush
end

local function square(x, z, size)
    return { { x = x, z = z }, { x = x + size, z = z }, { x = x + size, z = z + size }, { x = x, z = z + size } }
end

-- A mouse click at (x, z): press and release.
local function click(world, brush, x, z)
    world:aim(x, z)
    brush:update(16)
    brush:onButtonPrimary(true, false, false)
    brush:onButtonPrimary(false, false, true)
    brush:update(16)
end

-- Press at (x1, z1), drag to (x2, z2), release.
local function drag(world, brush, x1, z1, x2, z2)
    world:aim(x1, z1)
    brush:update(16)
    brush:onButtonPrimary(true, false, false)
    world:aim((x1 + x2) / 2, (z1 + z2) / 2)
    brush:onButtonPrimary(false, true, false)
    brush:update(16)
    world:aim(x2, z2)
    brush:onButtonPrimary(false, true, false)
    brush:update(16)
    brush:onButtonPrimary(false, false, true)
    brush:update(16)
end

local function lastSent(world)
    return world.sentEvents[#world.sentEvents]
end

local function makeYard(polygon)
    UsedEquipmentYards.yardManager:applyZoneRequest(YardZoneEvent.OP.CREATE, 0, polygon)
    local _, yard = next(UsedEquipmentYards.yardManager.yards)
    return yard
end

test("draw a yard: four corners, clicking the first one creates it", function()
    local world, brush = setup()
    click(world, brush, 0, 0)
    click(world, brush, 40, 0)
    click(world, brush, 40, 30)
    click(world, brush, 0, 30)
    assertEquals(brush.editor.state, YardZone.STATE.DRAWING)
    assertEquals(#world.sentEvents, 0)
    click(world, brush, 0.5, 0.4)
    local event = lastSent(world)
    assertTrue(event ~= nil, "a request was sent")
    assertEquals(event.op, YardZoneEvent.OP.CREATE)
    assertEquals(#event.polygon, 4)
    assertEquals(brush.editor.state, YardZone.STATE.IDLE, "ready for the next yard")
end)

test("a single right click closes the outline and creates the yard", function()
    local world, brush = setup()
    click(world, brush, 0, 0)
    click(world, brush, 40, 0)
    click(world, brush, 20, 30)
    brush:onButtonSecondary()
    assertEquals(#world.sentEvents, 1)
    assertEquals(lastSent(world).op, YardZoneEvent.OP.CREATE)
    assertEquals(brush.editor.state, YardZone.STATE.IDLE)
end)

test("an outline being edited shows its area and how many vehicles fit", function()
    local world, brush = setup()
    makeYard({ { x = 0, z = 0 }, { x = 40, z = 0 }, { x = 40, z = 30 }, { x = 0, z = 30 } })
    click(world, brush, 20, 15)
    assertEquals(brush.editor.state, YardZone.STATE.EDITING)
    brush:update(16)
    assertTrue(brush.preview ~= nil and brush.preview.plan ~= nil, "rows are previewed")
    assertTrue(brush.preview.capacity > 0)
    assertNear(brush.preview.area, 1200, 1e-6)
    assertTrue(#brush.rows.items > 0, "rows are drawn")
    brush:draw()
    local message = world.cursor.messages[#world.cursor.messages]
    assertEquals(message, string.format(g_i18n:getText("uey_zone_info"), 1200, brush.preview.capacity))
end)

test("an invalid outline stays open to fix, then right click creates it", function()
    local world, brush = setup()
    makeYard(square(20, 0, 40))
    click(world, brush, 0, 0)
    click(world, brush, 30, 0)
    click(world, brush, 30, 30)
    click(world, brush, 0, 30)
    brush:onButtonSecondary() -- close: overlaps, so not created
    assertEquals(#world.sentEvents, 0, "nothing sent")
    assertEquals(world.warnings[#world.warnings], g_i18n:getText("uey_zone_error_overlapsYard"))
    assertEquals(brush.editor.state, YardZone.STATE.EDITING, "left open to fix")
    brush:update(16)
    brush:draw()
    assertEquals(world.cursor.errors[#world.cursor.errors], g_i18n:getText("uey_zone_error_overlapsYard"))
    assertEquals(brush:getButtonSecondaryText(), g_i18n:getText("uey_zone_createYard"))
    brush:onButtonSecondary()
    assertEquals(#world.sentEvents, 0, "still refused")
    -- Pull the right side back out of the other yard.
    drag(world, brush, 30, 0, 15, 0)
    drag(world, brush, 30, 30, 15, 30)
    brush:onButtonSecondary()
    assertEquals(lastSent(world).op, YardZoneEvent.OP.CREATE)
    assertEquals(brush.editor.state, YardZone.STATE.IDLE)
end)

test("drag an existing yard's corner and apply", function()
    local world, brush = setup()
    local yard = makeYard(square(0, 0, 40))
    drag(world, brush, 40.3, 40.2, 50, 45)
    assertEquals(brush.editor.yardId, yard.id, "grabbing a corner selects the yard")
    assertEquals(brush:getButtonSecondaryText(), g_i18n:getText("uey_zone_applyChanges"))
    brush:onButtonSecondary()
    local event = lastSent(world)
    assertEquals(event.op, YardZoneEvent.OP.UPDATE)
    assertEquals(event.yardId, yard.id)
    assertNear(event.polygon[3].x, 50, 1e-9)
    assertNear(event.polygon[3].z, 45, 1e-9)
end)

test("drag an edge to add a corner", function()
    local world, brush = setup()
    makeYard(square(0, 0, 40))
    drag(world, brush, 20, -0.3, 20, -10)
    assertEquals(#brush.editor.points, 5)
    assertNear(brush.editor.points[2].z, -10, 1e-9)
end)

test("undo takes back a drag; a corner can be deleted", function()
    local world, brush = setup()
    makeYard(square(0, 0, 40))
    drag(world, brush, 40, 40, 50, 50)
    brush:onButtonFourth()
    assertNear(brush.editor.points[3].x, 40, 1e-9)
    assertTrue(not brush.editor:isDirty())
    -- Middle click on a corner deletes it.
    world:aim(0, 40)
    brush:update(16)
    assertEquals(brush:getButtonTertiaryText(), g_i18n:getText("uey_zone_deleteCorner"))
    brush:onButtonTertiary()
    assertEquals(#brush.editor.points, 3)
end)

test("Esc discards the outline in hand", function()
    local world, brush = setup()
    click(world, brush, 0, 0)
    click(world, brush, 40, 0)
    assertTrue(brush:canCancel())
    brush:cancel()
    assertEquals(brush.editor.state, YardZone.STATE.IDLE)
    assertTrue(not brush:canCancel())
end)

test("middle click takes back the last corner while drawing", function()
    local world, brush = setup()
    click(world, brush, 0, 0)
    click(world, brush, 40, 0)
    brush:onButtonTertiary()
    assertEquals(#brush.editor.points, 1)
end)

test("a gamepad press (no drag) on a corner doesn't leave it stuck to the cursor", function()
    local world, brush = setup()
    makeYard(square(0, 0, 40))
    world:aim(40, 40)
    brush:update(16)
    brush:onButtonPrimary()
    assertEquals(brush.editor.dragIndex, nil)
    world:aim(60, 60)
    brush:update(16)
    assertNear(brush.editor.points[3].x, 40, 1e-9)
end)

test("switching to another yard is refused while changes are unapplied", function()
    local world, brush = setup()
    makeYard(square(0, 0, 40))
    makeYard(square(100, 0, 40))
    drag(world, brush, 40, 40, 45, 45)
    local editing = brush.editor.yardId
    click(world, brush, 120, 20)
    assertEquals(brush.editor.yardId, editing)
    assertEquals(world.warnings[#world.warnings], g_i18n:getText("uey_zone_unsaved"))
end)

test("remove mode: click a yard, confirm, and it's requested gone", function()
    local world, brush = setup("remove")
    local yard = makeYard(square(0, 0, 40))
    click(world, brush, 20, 20)
    assertEquals(#world.dialogs, 1)
    assertEquals(world.dialogs[1].text, string.format(g_i18n:getText("uey_zone_removeConfirm"), yard.name))
    world.dialogs[1].callback(true)
    local event = lastSent(world)
    assertEquals(event.op, YardZoneEvent.OP.DELETE)
    assertEquals(event.yardId, yard.id)
end)

test("remove mode: a yard with sale zones says why it can't go", function()
    local world, brush = setup("remove")
    local yard = makeYard(square(0, 0, 40))
    table.insert(world.placeables, { [PlaceableSaleZone.KEY] = { yardId = yard.id } })
    click(world, brush, 20, 20)
    assertEquals(#world.dialogs, 0)
    assertEquals(world.warnings[#world.warnings], g_i18n:getText("uey_zone_error_hasSaleZones"))
end)

test("in multiplayer only admins can use the tool", function()
    local world, brush = setup()
    g_currentMission.missionDynamicInfo.isMultiplayer = true
    world.isServer = false
    g_currentMission.isMasterUser = false
    click(world, brush, 0, 0)
    assertEquals(brush.editor.state, YardZone.STATE.IDLE)
    brush:draw()
    assertEquals(world.cursor.errors[#world.cursor.errors], g_i18n:getText("uey_warning_adminOnly"))
    assertEquals(brush:getButtonPrimaryText(), nil)
end)

test("every button text is a real translation key in every state", function()
    local world, brush = setup()
    local yard = makeYard(square(50, 50, 40))
    local function readAll()
        brush:getButtonPrimaryText()
        brush:getButtonSecondaryText()
        brush:getButtonTertiaryText()
        brush:getButtonFourthText()
        brush:draw()
    end
    readAll()
    click(world, brush, 0, 0)
    readAll()
    click(world, brush, 30, 0)
    click(world, brush, 30, 30)
    world:aim(0.3, 0.3)
    brush:update(16)
    readAll()
    brush:onButtonSecondary()
    readAll()
    world:aim(30, 0)
    brush:update(16)
    readAll()
    brush:cancel()
    world:aim(70, 70)
    brush:update(16)
    readAll()
    assertTrue(yard ~= nil)
end)

test("other yards are outlined; the one under the cursor is highlighted", function()
    local world, brush = setup()
    makeYard(square(0, 0, 40))
    world:aim(20, 20)
    brush:update(16)
    local colors = {}
    for _, line in ipairs(brush.otherOutlines.items) do
        colors[line.color] = true
    end
    assertTrue(colors.yellow, "hovered yard")
    world:aim(200, 200)
    brush:update(16)
    colors = {}
    for _, line in ipairs(brush.otherOutlines.items) do
        colors[line.color] = true
    end
    assertTrue(colors.white and not colors.yellow)
end)

test("on game versions without Marker3D, corner handles are drawn as crosses", function()
    local world = setup()
    Marker3D = nil
    local brush = UeyYardZoneBrush.new(nil, world:makeCursor())
    brush:setParameters("zone")
    brush:activate()
    click(world, brush, 0, 0)
    click(world, brush, 30, 0)
    world:aim(15, 20)
    brush:update(16)
    -- 1 placed edge + preview line + 2 crosses of 2 strokes.
    assertEquals(#brush.outline.items, 1 + 1 + 4)
    brush:delete()
end)
