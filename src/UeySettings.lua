UeySettings = {}

function UeySettings.initialize()
    local settingsPage = g_inGameMenu.pageSettings
    local scrollPanel = settingsPage.gameSettingsLayout

    local sectionHeader, buttonElement

    for _, element in pairs(scrollPanel.elements) do
        if element.name == "sectionHeader" and sectionHeader == nil then
            sectionHeader = element
        end
        if element.typeName == "Bitmap" then
            if element.elements[1].typeName == "Button" and buttonElement == nil then
                buttonElement = element
            end
        end
        if sectionHeader and buttonElement then break end
    end

    if sectionHeader == nil or buttonElement == nil then return end

    -- Section header.
    local header = sectionHeader:clone(scrollPanel)
    header:setText(g_i18n:getText("uey_modTitle"))

    -- Reset Inventory button.
    local template = buttonElement:clone(scrollPanel)
    template.id = nil

    for _, element in pairs(template.elements) do
        if element.typeName == "Text" then
            element:setText(g_i18n:getText("uey_settings_resetInventory_label"))
            element.id = nil
        end
        if element.typeName == "Button" then
            element:setText(g_i18n:getText("uey_settings_resetInventory_text"))
            element:applyProfile("ueySettingsButton")
            element.isAlwaysFocusedOnOpen = false
            element.focused = false
            element.id = "uey_resetInventory"
            element.onClickCallback = UeySettings.onClickButton
            UeySettings.resetButton = element
        end
    end

    UeySettings.addViewDistanceOption(settingsPage, scrollPanel)
end

--- Per-machine option: hide yard vehicles beyond a distance from the camera.
function UeySettings.addViewDistanceOption(settingsPage, scrollPanel)
    local originalBox = settingsPage.multiVolumeVoiceBox
    if originalBox == nil then return end

    local box = originalBox:clone(scrollPanel)
    box.id = "uey_viewDistanceBox"

    local option = box.elements[1]
    option.id = "uey_viewDistance"
    option.target = UeySettings
    option:setCallback("onClickCallback", "onViewDistanceChanged")
    option:setDisabled(false)

    option.elements[1]:setText(g_i18n:getText("uey_settings_viewDistance_tooltip"))
    box.elements[2]:setText(g_i18n:getText("uey_settings_viewDistance_label"))

    local texts = {}
    for i, distance in ipairs(YardVisibility.DISTANCES) do
        if distance == 0 then
            texts[i] = g_i18n:getText("uey_settings_off")
        else
            texts[i] = ("%d m"):format(distance)
        end
    end
    option:setTexts(texts)
    option:setState(YardVisibility.getStateIndex())

    local function updateFocusIds(element)
        element.focusId = FocusManager:serveAutoFocusId()
        for _, child in pairs(element.elements) do
            updateFocusIds(child)
        end
    end
    updateFocusIds(box)
    table.insert(settingsPage.controlsList, box)

    UeySettings.viewDistanceOption = option
    scrollPanel:invalidateLayout()
end

function UeySettings:onViewDistanceChanged(state)
    YardVisibility.setMaxDistance(YardVisibility.DISTANCES[state] or 0)
end

function UeySettings.onFrameOpen()
    local isAdmin = g_currentMission.isMasterUser or g_server ~= nil
    if UeySettings.resetButton ~= nil then
        UeySettings.resetButton:setDisabled(not isAdmin)
    end
    -- Local preference: always editable, including for MP clients.
    if UeySettings.viewDistanceOption ~= nil then
        UeySettings.viewDistanceOption:setState(YardVisibility.getStateIndex())
    end
end

function UeySettings.onClickButton(_, state, button)
    if button == nil then button = state end
    if button == nil or button.id ~= "uey_resetInventory" then return end

    if g_server ~= nil then
        local manager = UsedEquipmentYards.yardManager
        if manager ~= nil then
            manager:resetAllInventories()
        end
    else
        g_client:getServerConnection():sendEvent(ResetInventoryEvent.new(-1))
    end
end

InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(InGameMenuSettingsFrame.onFrameOpen, UeySettings.onFrameOpen)
