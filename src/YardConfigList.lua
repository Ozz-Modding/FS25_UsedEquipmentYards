-- YardConfigList
-- Pure logic (no engine calls): the equipment list shown in the barter dialog -
-- which option a yard vehicle has for each configuration a buyer could have
-- chosen in the shop. Filters like ShopConfigScreen.processStoreItemConfigurationSet:
-- colour pickers, single-option types and types driven by another
-- configuration are left out.

YardConfigList = {}

--- The option item for a vehicle's config index (items carry their own .index).
local function findItem(items, index)
    for _, item in ipairs(items) do
        if item.index == index then
            return item
        end
    end
    return items[index]
end

--- The option the shop preselects: the selectable default, else the first selectable.
local function defaultItem(items)
    for _, item in ipairs(items) do
        if item.isDefault and item.isSelectable ~= false then
            return item
        end
    end
    for _, item in ipairs(items) do
        if item.isSelectable ~= false then
            return item
        end
    end
    return items[1]
end

local function countSelectable(items)
    local count = 0
    for _, item in ipairs(items) do
        if item.isSelectable ~= false then
            count = count + 1
        end
    end
    return count
end

--- Config names another configuration's options set (the shop hides these).
local function dependentNames(storeConfigs)
    local names = {}
    for _, items in pairs(storeConfigs) do
        for _, item in pairs(items) do
            if type(item.dependentConfigurations) == "table" then
                for _, dependent in pairs(item.dependentConfigurations) do
                    if dependent.name ~= nil then
                        names[dependent.name] = true
                    end
                end
            end
        end
    end
    return names
end

--- Build the rows.
-- @param types          ordered list of { name, title, isColor } (shop order)
-- @param storeConfigs   storeItem.configurations: name -> list of option items
-- @param vehicleConfigs vehicle.configurations: name -> chosen index
-- @return list of { name, title, optionName, price, isUpgrade }
function YardConfigList.build(types, storeConfigs, vehicleConfigs)
    local rows = {}
    if type(types) ~= "table" or type(storeConfigs) ~= "table" then
        return rows
    end
    vehicleConfigs = vehicleConfigs or {}
    local dependents = dependentNames(storeConfigs)

    for _, configType in ipairs(types) do
        local name = configType.name
        local items = storeConfigs[name]
        if not configType.isColor and not dependents[name] and type(items) == "table"
            and countSelectable(items) > 1 then
            local default = defaultItem(items)
            local chosen = vehicleConfigs[name] ~= nil and findItem(items, vehicleConfigs[name]) or default
            if chosen ~= nil then
                local price = chosen.price or 0
                local defaultPrice = default ~= nil and (default.price or 0) or 0
                rows[#rows + 1] = {
                    name = name,
                    title = chosen.overwrittenTitle or configType.title or name,
                    optionName = chosen.name or tostring(chosen.index),
                    price = price,
                    isUpgrade = price > defaultPrice,
                }
            end
        end
    end
    return rows
end
