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
end

function UeySettings.onFrameOpen()
    local isAdmin = g_currentMission.isMasterUser or g_server ~= nil
    if UeySettings.resetButton ~= nil then
        UeySettings.resetButton:setDisabled(not isAdmin)
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
