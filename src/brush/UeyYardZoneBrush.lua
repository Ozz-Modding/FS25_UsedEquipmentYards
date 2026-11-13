-- UeyYardZoneBrush
-- The yard tool in the game's build menu (Buildings → Tools). Two store items
-- use it (xml/YardZoneTool.xml, xml/YardZoneRemoveTool.xml), set apart by
-- their brush parameter:
--
--   "zone"    draw a new yard, or click an existing yard to reshape it
--   "remove"  click a yard to remove it (after a confirmation)
--
-- Drawing (zone mode):
--   left click            add a corner; click the first corner (or right
--                         click) to close the outline
--   drag a corner         move it          (closed outline)
--   drag an edge          add a corner there and move it
--   middle click          remove the last corner (drawing) / the corner
--                         under the cursor (closed outline)
--   fourth (undo) key     undo
--   right click           close the outline / create the yard / apply changes
--   Esc / back            discard what's in hand
--
-- While an outline is closed it is validated (YardZone.validate) and the rows
-- vehicles would park in are drawn live (YardLayout, with the yard's config,
-- or the default config for a new yard), with the area and an estimated
-- vehicle count at the cursor.
--
-- Registered by UsedEquipmentYards.registerBrushType (main.lua) through
-- g_constructionBrushTypeManager:addBrushType, which sources this file — it is
-- not listed in modDesc's extraSourceFiles. The editing logic lives in the
-- pure, tested YardZone.Editor; this file is input, drawing and events.

UeyYardZoneBrush = {}
local UeyYardZoneBrush_mt = Class(UeyYardZoneBrush, ConstructionBrush)

UeyYardZoneBrush.MODE = { ZONE = "zone", REMOVE = "remove" }

UeyYardZoneBrush.LINE_SCALE = 4         -- the outline being edited
UeyYardZoneBrush.OTHER_LINE_SCALE = 2   -- other yards' outlines
UeyYardZoneBrush.ROW_LINE_SCALE = 1.5   -- preview rows
UeyYardZoneBrush.MARKER_SCALE = 0.6
UeyYardZoneBrush.MARKER_LIFT = 0.4
UeyYardZoneBrush.PREVIEW_INTERVAL_MS = 200 -- row preview refresh while dragging

function UeyYardZoneBrush.new(subclass_mt, cursor)
    local self = UeyYardZoneBrush:superClass().new(subclass_mt or UeyYardZoneBrush_mt, cursor)

    self.supportsPrimaryButton = true
    self.supportsPrimaryDragging = true
    self.supportsSecondaryButton = true
    self.supportsTertiaryButton = true
    self.supportsFourthButton = true

    self.mode = UeyYardZoneBrush.MODE.ZONE
    self.editor = YardZone.Editor.new()
    self.hover = nil          -- what's under the cursor: { kind, yard, index, x, z }
    self.hoverKey = nil       -- for refreshing the button texts when it changes
    self.preview = nil        -- { version, plan, capacity, area }
    self.previewAt = 0
    self.modelsByKey = {}     -- layout models per config ("new" or yard id)

    self.outline = UeyYardZoneBrush.newLine(UeyYardZoneBrush.LINE_SCALE)
    self.otherOutlines = UeyYardZoneBrush.newLine(UeyYardZoneBrush.OTHER_LINE_SCALE)
    self.rows = UeyYardZoneBrush.newLine(UeyYardZoneBrush.ROW_LINE_SCALE)
    -- Marker3D (corner handles) and Line3D:setLineScale arrived in game patch
    -- 1.25; without them handles are drawn as crosses with the outline line.
    if Marker3D ~= nil then
        self.markers = Marker3D.new()
        self.markers:setScale(UeyYardZoneBrush.MARKER_SCALE)
    end

    return self
end

function UeyYardZoneBrush.newLine(scale)
    local line = Line3D.new()
    if line.setLineScale ~= nil then
        line:setLineScale(scale, scale)
    end
    return line
end

function UeyYardZoneBrush:delete()
    UeyYardZoneBrush:superClass().delete(self)
    self.outline:delete()
    self.otherOutlines:delete()
    self.rows:delete()
    if self.markers ~= nil then
        self.markers:delete()
    end
end

function UeyYardZoneBrush:setParameters(mode)
    if mode == UeyYardZoneBrush.MODE.REMOVE then
        self.mode = UeyYardZoneBrush.MODE.REMOVE
    else
        self.mode = UeyYardZoneBrush.MODE.ZONE
    end
end

function UeyYardZoneBrush:activate()
    UeyYardZoneBrush:superClass().activate(self)
    self.cursor:setRotationEnabled(false)
    self.cursor:setShape(GuiTopDownCursor.SHAPES.CIRCLE)
    self.cursor:setShapeSize(0.5)
    self.cursor:setColorMode(GuiTopDownCursor.SHAPES_COLORS.SUCCESS)
    self.cursor:setTerrainOnly(true)
    self.editor:reset()
    self.hover = nil
    self.preview = nil
    self:setInputTextDirty()
end

function UeyYardZoneBrush:deactivate()
    self:clearVisuals()
    self.editor:reset()
    self.cursor:setTerrainOnly(false)
    self.cursor:setColorMode(GuiTopDownCursor.SHAPES_COLORS.SELECT)
    UeyYardZoneBrush:superClass().deactivate(self)
end

function UeyYardZoneBrush:clearVisuals()
    self.outline:clearVisualization()
    self.otherOutlines:clearVisualization()
    self.rows:clearVisualization()
    if self.markers ~= nil then
        self.markers:clearVisualization()
    end
end

-- Esc / back discards the outline in hand.
function UeyYardZoneBrush:canCancel()
    return self.editor.state ~= YardZone.STATE.IDLE
end

function UeyYardZoneBrush:cancel()
    self.editor:reset()
    self.preview = nil
    self:setInputTextDirty()
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

function UeyYardZoneBrush:getCursorXZ()
    local x, _, z = self.cursor:getHitTerrainPosition()
    return x, z
end

function UeyYardZoneBrush:isAllowed()
    return UsedEquipmentYards.isAdminInMP()
end

--- Outlines of every yard except `exceptId` (for overlap checks).
function UeyYardZoneBrush:getOtherPolygons(exceptId)
    local others = {}
    for id, yard in pairs(UsedEquipmentYards.getAllYards()) do
        if id ~= exceptId then
            others[#others + 1] = YardZone.polygonOfBounds(yard.bounds)
        end
    end
    return others
end

function UeyYardZoneBrush:getYardAt(x, z)
    if x == nil then
        return nil
    end
    for _, yard in pairs(UsedEquipmentYards.getAllYards()) do
        if YardZone.pointInPolygon(YardZone.polygonOfBounds(yard.bounds), x, z) then
            return yard
        end
    end
    return nil
end

--- What's under the cursor: a corner or edge of the outline in hand, or
--- (when idle) a corner, edge or inside of an existing yard.
function UeyYardZoneBrush:findHover(x, z)
    if x == nil then
        return nil
    end
    local editor = self.editor
    if editor.state ~= YardZone.STATE.IDLE then
        local index = editor:pickVertex(x, z)
        if index ~= nil then
            return { kind = "vertex", index = index }
        end
        if editor:isClosed() then
            local edge, px, pz = editor:pickEdge(x, z)
            if edge ~= nil then
                return { kind = "edge", index = edge, x = px, z = pz }
            end
        end
        local yard = self:getYardAt(x, z)
        if yard ~= nil and yard.id ~= editor.yardId then
            return { kind = "otherYard", yard = yard }
        end
        return nil
    end
    local limits = YardZone.LIMITS
    for _, yard in pairs(UsedEquipmentYards.getAllYards()) do
        local polygon = YardZone.polygonOfBounds(yard.bounds)
        local index = YardZone.nearestVertex(polygon, x, z, limits.vertexPickRadius)
        if index ~= nil then
            return { kind = "yardVertex", yard = yard, index = index }
        end
        local edge, px, pz = YardZone.nearestEdge(polygon, x, z, limits.edgePickRadius)
        if edge ~= nil then
            return { kind = "yardEdge", yard = yard, index = edge, x = px, z = pz }
        end
    end
    local yard = self:getYardAt(x, z)
    if yard ~= nil then
        return { kind = "yardInside", yard = yard }
    end
    return nil
end

--- Layout models for the outline in hand: its yard's config, or the
--- default config for a new yard. Measured once per config per session.
function UeyYardZoneBrush:getPreviewModels()
    local key = self.editor.yardId or "new"
    local models = self.modelsByKey[key]
    if models == nil then
        local yard = self.editor.yardId ~= nil and UsedEquipmentYards.getYard(self.editor.yardId) or nil
        local config = yard ~= nil and yard.inventory.config or YardInventory.DEFAULT_CONFIG
        models = YardInventory.getLayoutModelsForConfig(config)
        self.modelsByKey[key] = models
    end
    return models
end

function UeyYardZoneBrush:getPreviewOptions()
    local yard = self.editor.yardId ~= nil and UsedEquipmentYards.getYard(self.editor.yardId) or nil
    local config = yard ~= nil and yard.inventory.config or YardInventory.DEFAULT_CONFIG
    return { aisleWidth = config.aisleWidth or YardInventory.DEFAULT_CONFIG.aisleWidth }
end

--- Validity of the closed outline in hand: ok, error key.
function UeyYardZoneBrush:validateOutline()
    local ok, err = self.editor:validate(self:getOtherPolygons(self.editor.yardId))
    if ok and self.preview ~= nil and self.preview.version == self.editor.version and self.preview.capacity == 0 then
        return false, "noRows"
    end
    return ok, err
end

-- ---------------------------------------------------------------------------
-- Update / draw
-- ---------------------------------------------------------------------------

function UeyYardZoneBrush:update(dt)
    UeyYardZoneBrush:superClass().update(self, dt)

    local x, z = self:getCursorXZ()
    local editor = self.editor

    if editor.dragIndex ~= nil and x ~= nil then
        editor:dragTo(x, z)
    end

    local hover = nil
    if self:isAllowed() then
        if self.mode == UeyYardZoneBrush.MODE.REMOVE then
            local yard = self:getYardAt(x, z)
            hover = yard ~= nil and { kind = "yardInside", yard = yard } or nil
        elseif editor.dragIndex == nil then
            hover = self:findHover(x, z)
        else
            hover = { kind = "dragging" }
        end
    end
    self.hover = hover

    local key = (hover ~= nil and hover.kind or "none") .. ":" .. tostring(editor.state) .. ":" ..
        tostring(editor:canUndo()) .. ":" .. tostring(editor:isDirty()) .. ":" ..
        tostring(x ~= nil and editor:isNearFirst(x, z) or false)
    if key ~= self.hoverKey then
        self.hoverKey = key
        self:setInputTextDirty()
    end

    self:updatePreview()
    self:updateVisuals(x, z)
end

--- Recompute the row preview when the closed outline changes (throttled
--- while a corner is being dragged).
function UeyYardZoneBrush:updatePreview()
    local editor = self.editor
    if not editor:isClosed() or #editor.points < 3 then
        self.preview = nil
        return
    end
    if self.preview ~= nil and self.preview.version == editor.version then
        return
    end
    local now = g_time or 0
    if editor.dragIndex ~= nil and self.preview ~= nil and now - self.previewAt < UeyYardZoneBrush.PREVIEW_INTERVAL_MS then
        return
    end
    self.previewAt = now
    local polygon = YardZone.copy(editor.points)
    local ok = YardZone.validate(polygon, {})
    local preview = { version = editor.version, area = YardZone.area(polygon), capacity = 0 }
    if ok then
        local models = self:getPreviewModels()
        local options = self:getPreviewOptions()
        local plan = YardLayout.plan(polygon, models, options)
        if plan ~= nil then
            preview.plan = plan
            preview.capacity = YardLayout.estimateCapacity(plan, models, options)
        end
    end
    self.preview = preview
end

function UeyYardZoneBrush:updateVisuals(x, z)
    self:clearVisuals()
    local editor = self.editor
    local presets = Color.PRESETS
    local hover = self.hover

    -- Every other yard, thin; the one under the cursor highlighted.
    for id, yard in pairs(UsedEquipmentYards.getAllYards()) do
        if id ~= editor.yardId then
            local color = presets.WHITE
            if hover ~= nil and hover.yard == yard then
                color = self.mode == UeyYardZoneBrush.MODE.REMOVE and presets.RED or presets.YELLOW
            end
            self:drawPolygon(self.otherOutlines, YardZone.polygonOfBounds(yard.bounds), true, color)
        end
    end

    if editor.state == YardZone.STATE.IDLE then
        return
    end

    local points = editor.points
    if editor.state == YardZone.STATE.DRAWING then
        self:drawPolygon(self.outline, points, false, presets.ORANGE)
        if x ~= nil and #points > 0 then
            local last = points[#points]
            local canAdd = editor:canExtendTo(x, z)
            local closing = editor:canClose() and editor:isNearFirst(x, z)
            local color = (closing and presets.GREEN) or (canAdd and presets.ORANGE) or presets.RED
            self.outline:visualizeLine(last.x, 0, last.z, x, 0, z, true, color)
            if editor:canClose() then
                -- How the outline would close.
                local first = points[1]
                local target = closing and first or { x = x, z = z }
                self.outline:visualizeLine(target.x, 0, target.z, first.x, 0, first.z, true, presets.GREEN)
            end
        end
    else
        local ok = self:validateOutline()
        self:drawPolygon(self.outline, points, true, ok and presets.GREEN or presets.RED)
        if self.preview ~= nil and self.preview.plan ~= nil then
            self:drawRows(self.preview.plan, ok and presets.CYAN or presets.ORANGE)
        end
    end

    -- Corner handles: the hovered/dragged one stands out.
    for i, p in ipairs(points) do
        local highlighted = editor.dragIndex == i or (hover ~= nil and hover.kind == "vertex" and hover.index == i)
        local color = highlighted and presets.YELLOW or presets.WHITE
        if self.markers ~= nil then
            local y = getTerrainHeightAtWorldPos(g_terrainNode, p.x, 0, p.z) + UeyYardZoneBrush.MARKER_LIFT
            self.markers:visualizeMarker(p.x, y, p.z, color)
        else
            self.outline:visualizeLine(p.x - 1, 0, p.z - 1, p.x + 1, 0, p.z + 1, true, color)
            self.outline:visualizeLine(p.x - 1, 0, p.z + 1, p.x + 1, 0, p.z - 1, true, color)
        end
    end
end

function UeyYardZoneBrush:drawPolygon(line, polygon, closed, color)
    local n = #polygon
    local edges = closed and n or n - 1
    for i = 1, edges do
        local a, b = polygon[i], polygon[i % n + 1]
        line:visualizeLine(a.x, 0, a.z, b.x, 0, b.z, true, color)
    end
end

--- The rows vehicles would park in: one rectangle per usable stretch.
function UeyYardZoneBrush:drawRows(plan, color)
    for _, row in ipairs(plan.rows) do
        for _, interval in ipairs(row.intervals) do
            local corners = {}
            for i, c in ipairs({ { interval[1], row.v1 }, { interval[2], row.v1 }, { interval[2], row.v2 },
                { interval[1], row.v2 } }) do
                local wx, wz = YardLayout.toWorld(plan.angle, c[1], c[2])
                corners[i] = { x = wx, z = wz }
            end
            self:drawPolygon(self.rows, corners, true, color)
        end
    end
end

--- Status text at the cursor (rendered here: cursor messages draw at once).
function UeyYardZoneBrush:draw()
    UeyYardZoneBrush:superClass().draw(self)

    if not self:isAllowed() then
        self.cursor:setErrorMessage(g_i18n:getText("uey_warning_adminOnly"))
        return
    end

    local hover = self.hover
    if self.mode == UeyYardZoneBrush.MODE.REMOVE then
        if hover ~= nil and hover.yard ~= nil then
            self.cursor:setMessage(hover.yard.name or "")
        end
        return
    end

    local editor = self.editor
    if editor.state == YardZone.STATE.IDLE then
        if hover ~= nil and hover.yard ~= nil then
            self.cursor:setMessage(hover.yard.name or "")
        end
    elseif editor.state == YardZone.STATE.DRAWING then
        self.cursor:setMessage(string.format(g_i18n:getText("uey_zone_infoDrawing"), #editor.points))
    else
        local ok, err = self:validateOutline()
        if not ok then
            self.cursor:setErrorMessage(g_i18n:getText("uey_zone_error_" .. tostring(err)))
        elseif self.preview ~= nil then
            self.cursor:setMessage(string.format(g_i18n:getText("uey_zone_info"), math.floor(self.preview.area + 0.5),
                self.preview.capacity))
        end
    end
end

-- ---------------------------------------------------------------------------
-- Input
-- ---------------------------------------------------------------------------

--- Called with (isDown, isDrag, isUp) for mouse drags, and with no
--- arguments for a plain press (gamepad / keyboard accept).
function UeyYardZoneBrush:onButtonPrimary(isDown, isDrag, isUp)
    if not self:isAllowed() then
        return
    end
    local bare = isDown == nil and isDrag == nil and isUp == nil
    local editor = self.editor
    local x, z = self:getCursorXZ()

    if isDrag then
        if editor.dragIndex ~= nil and x ~= nil then
            editor:dragTo(x, z)
        end
        return
    end
    if isUp then
        if editor.dragIndex ~= nil then
            editor:endDrag()
            self:setInputTextDirty()
        end
        return
    end
    if x == nil then
        return
    end

    if self.mode == UeyYardZoneBrush.MODE.REMOVE then
        self:askRemoveYard(self:getYardAt(x, z))
        return
    end

    local hover = self:findHover(x, z)
    if editor.state == YardZone.STATE.IDLE then
        if hover ~= nil and hover.yard ~= nil then
            editor:loadExisting(hover.yard.id, YardZone.polygonOfBounds(hover.yard.bounds))
            if hover.kind == "yardVertex" then
                editor:beginDrag(hover.index)
            elseif hover.kind == "yardEdge" then
                editor:insertAndDrag(hover.index, hover.x, hover.z)
            end
        else
            editor:startNew(x, z)
        end
    elseif editor.state == YardZone.STATE.DRAWING then
        local result = editor:addPoint(x, z)
        if result == "closed" then
            self:onOutlineClosed()
        elseif result == nil and not (editor:canClose() and editor:isNearFirst(x, z)) then
            g_currentMission:showBlinkingWarning(g_i18n:getText("uey_zone_error_cornerRefused"), 1500)
        end
    else
        if hover ~= nil and hover.kind == "vertex" then
            editor:beginDrag(hover.index)
        elseif hover ~= nil and hover.kind == "edge" then
            editor:insertAndDrag(hover.index, hover.x, hover.z)
        elseif hover ~= nil and hover.kind == "otherYard" then
            if editor:isDirty() then
                g_currentMission:showBlinkingWarning(g_i18n:getText("uey_zone_unsaved"), 2000)
            else
                editor:loadExisting(hover.yard.id, YardZone.polygonOfBounds(hover.yard.bounds))
            end
        end
    end

    -- A plain press has no drag to follow: let go straight away.
    if bare and editor.dragIndex ~= nil then
        editor:endDrag()
    end
    self:setInputTextDirty()
end

--- Validate the closed outline and send it: create the yard, or apply the
--- changes to an existing one. Returns true if sent.
function UeyYardZoneBrush:submitOutline()
    local editor = self.editor
    self:updatePreview()
    local ok, err = self:validateOutline()
    if not ok then
        g_currentMission:showBlinkingWarning(g_i18n:getText("uey_zone_error_" .. tostring(err)), 2000)
        return false
    end
    local op = editor.yardId ~= nil and YardZoneEvent.OP.UPDATE or YardZoneEvent.OP.CREATE
    g_client:getServerConnection():sendEvent(YardZoneEvent.new(op, editor.yardId, YardZone.copy(editor.points)))
    editor:reset()
    self.preview = nil
    return true
end

--- Closing a new outline creates the yard straight away (yards are free).
--- If it isn't valid yet it stays open to fix, and right click creates it.
function UeyYardZoneBrush:onOutlineClosed()
    if self.editor.yardId == nil then
        self:submitOutline()
    end
end

--- Right click: close the outline (creating a new yard), or apply the
--- changes to a reshaped / not-yet-valid outline.
function UeyYardZoneBrush:onButtonSecondary()
    if not self:isAllowed() or self.mode ~= UeyYardZoneBrush.MODE.ZONE then
        return
    end
    local editor = self.editor
    if editor.dragIndex ~= nil then
        editor:cancelDrag()
    elseif editor.state == YardZone.STATE.DRAWING then
        if editor:close() then
            self:onOutlineClosed()
        end
    elseif editor:isClosed() and editor:isDirty() then
        self:submitOutline()
    end
    self:setInputTextDirty()
end

--- Middle click: take back the last corner while drawing, or delete the
--- corner under the cursor on a closed outline.
function UeyYardZoneBrush:onButtonTertiary()
    if not self:isAllowed() or self.mode ~= UeyYardZoneBrush.MODE.ZONE then
        return
    end
    local editor = self.editor
    if editor.state == YardZone.STATE.DRAWING then
        editor:removeLastPoint()
    elseif editor:isClosed() and self.hover ~= nil and self.hover.kind == "vertex" then
        if not editor:deleteVertex(self.hover.index) then
            g_currentMission:showBlinkingWarning(g_i18n:getText("uey_zone_error_tooFewPoints"), 1500)
        end
    end
    self:setInputTextDirty()
end

function UeyYardZoneBrush:onButtonFourth()
    if self.editor:undo() then
        self:setInputTextDirty()
    end
end

function UeyYardZoneBrush:askRemoveYard(yard)
    if yard == nil then
        return
    end
    if UsedEquipmentYards.getConnectedSaleZoneCount(yard.id) > 0 then
        g_currentMission:showBlinkingWarning(g_i18n:getText("uey_zone_error_hasSaleZones"), 2500)
        return
    end
    local yardId = yard.id
    YesNoDialog.show(function(yes)
        if yes then
            g_client:getServerConnection():sendEvent(YardZoneEvent.new(YardZoneEvent.OP.DELETE, yardId))
        end
    end, nil, string.format(g_i18n:getText("uey_zone_removeConfirm"), yard.name or ""))
end

-- ---------------------------------------------------------------------------
-- Button texts
-- ---------------------------------------------------------------------------

function UeyYardZoneBrush:getButtonPrimaryText()
    if not self:isAllowed() then
        return nil
    end
    if self.mode == UeyYardZoneBrush.MODE.REMOVE then
        return g_i18n:getText("uey_zone_removeYard")
    end
    local editor, hover = self.editor, self.hover
    if editor.state == YardZone.STATE.IDLE then
        if hover ~= nil and hover.yard ~= nil then
            return g_i18n:getText("uey_zone_editYard")
        end
        return g_i18n:getText("uey_zone_startYard")
    elseif editor.state == YardZone.STATE.DRAWING then
        local x, z = self:getCursorXZ()
        if x ~= nil and editor:canClose() and editor:isNearFirst(x, z) then
            return g_i18n:getText("uey_zone_createYard")
        end
        return g_i18n:getText("uey_zone_addCorner")
    end
    if hover ~= nil and (hover.kind == "vertex" or hover.kind == "dragging") then
        return g_i18n:getText("uey_zone_moveCorner")
    elseif hover ~= nil and hover.kind == "edge" then
        return g_i18n:getText("uey_zone_insertCorner")
    elseif hover ~= nil and hover.kind == "otherYard" then
        return g_i18n:getText("uey_zone_editYard")
    end
    return nil
end

function UeyYardZoneBrush:getButtonSecondaryText()
    if not self:isAllowed() or self.mode ~= UeyYardZoneBrush.MODE.ZONE then
        return nil
    end
    local editor = self.editor
    if editor.state == YardZone.STATE.DRAWING and editor:canClose() then
        return g_i18n:getText("uey_zone_createYard")
    elseif editor:isClosed() and editor:isDirty() then
        return g_i18n:getText(editor.yardId ~= nil and "uey_zone_applyChanges" or "uey_zone_createYard")
    end
    return nil
end

function UeyYardZoneBrush:getButtonTertiaryText()
    if not self:isAllowed() or self.mode ~= UeyYardZoneBrush.MODE.ZONE then
        return nil
    end
    local editor = self.editor
    if editor.state == YardZone.STATE.DRAWING then
        return g_i18n:getText("uey_zone_removeLastCorner")
    elseif editor:isClosed() and self.hover ~= nil and self.hover.kind == "vertex" then
        return g_i18n:getText("uey_zone_deleteCorner")
    end
    return nil
end

function UeyYardZoneBrush:getButtonFourthText()
    if self.editor:canUndo() then
        return g_i18n:getText("uey_zone_undo")
    end
    return nil
end
