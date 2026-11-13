-- YardConfigList: the equipment rows in the barter dialog.

local function setup()
    local world = stubs.install()
    world:load("src/YardConfigList.lua")
    return world
end

local function option(index, name, price, extra)
    local item = { index = index, name = name, price = price or 0, isSelectable = true }
    for k, v in pairs(extra or {}) do
        item[k] = v
    end
    return item
end

local TYPES = {
    { name = "baseColor", title = "Colour", isColor = true },
    { name = "nozzle", title = "Nozzle Control" },
    { name = "spot", title = "Spot Spraying" },
    { name = "wheel", title = "Tyres" },
}

local function sprayerConfigs()
    return {
        baseColor = { option(1, "Red"), option(2, "Blue") },
        nozzle = { option(1, "Standard", 0, { isDefault = true }), option(2, "PWM", 14000) },
        spot = { option(1, "None", 0, { isDefault = true }), option(2, "WeedSeeker", 33000) },
        wheel = { option(1, "Narrow") },
    }
end

test("one row per choosable type, in type order, with the vehicle's option", function()
    setup()
    local rows = YardConfigList.build(TYPES, sprayerConfigs(), { baseColor = 2, nozzle = 2, spot = 1, wheel = 1 })
    assertEquals(#rows, 2)
    assertEquals(rows[1].name, "nozzle")
    assertEquals(rows[1].optionName, "PWM")
    assertEquals(rows[1].price, 14000)
    assertTrue(rows[1].isUpgrade)
    assertEquals(rows[2].name, "spot")
    assertEquals(rows[2].optionName, "None")
    assertEquals(rows[2].price, 0)
    assertTrue(not rows[2].isUpgrade)
end)

test("colour types and single-option types are skipped", function()
    setup()
    local rows = YardConfigList.build(TYPES, sprayerConfigs(), {})
    for _, row in ipairs(rows) do
        assertTrue(row.name ~= "baseColor" and row.name ~= "wheel", row.name)
    end
end)

test("a type with only one selectable option is skipped", function()
    setup()
    local configs = { nozzle = { option(1, "Standard"), option(2, "PWM", 14000, { isSelectable = false }) } }
    assertEquals(#YardConfigList.build(TYPES, configs, { nozzle = 1 }), 0)
end)

test("no vehicle choice falls back to the default option", function()
    setup()
    local rows = YardConfigList.build(TYPES, sprayerConfigs(), {})
    assertEquals(rows[1].optionName, "Standard")
    assertTrue(not rows[1].isUpgrade)
end)

test("upgrade is measured against the default option's price, not zero", function()
    setup()
    local configs = { nozzle = {
        option(1, "Basic", 2000),
        option(2, "Mid", 5000, { isDefault = true }),
        option(3, "Top", 9000),
    } }
    local cheaper = YardConfigList.build(TYPES, configs, { nozzle = 1 })[1]
    assertEquals(cheaper.price, 2000)
    assertTrue(not cheaper.isUpgrade)
    assertTrue(YardConfigList.build(TYPES, configs, { nozzle = 3 })[1].isUpgrade)
end)

test("options are found by their own index", function()
    setup()
    local configs = { nozzle = { option(4, "Four"), option(7, "Seven", 100) } }
    assertEquals(YardConfigList.build(TYPES, configs, { nozzle = 7 })[1].optionName, "Seven")
end)

test("a type set by another configuration is skipped", function()
    setup()
    local configs = sprayerConfigs()
    configs.spot[2].dependentConfigurations = { { name = "nozzle", index = 2 } }
    local rows = YardConfigList.build(TYPES, configs, { nozzle = 2, spot = 2 })
    assertEquals(#rows, 1)
    assertEquals(rows[1].name, "spot")
end)

test("the option's own title overrides the type title", function()
    setup()
    local configs = { nozzle = { option(1, "A"), option(2, "B", 0, { overwrittenTitle = "Section Control" }) } }
    assertEquals(YardConfigList.build(TYPES, configs, { nozzle = 2 })[1].title, "Section Control")
    assertEquals(YardConfigList.build(TYPES, configs, { nozzle = 1 })[1].title, "Nozzle Control")
end)

test("missing store configurations give no rows", function()
    setup()
    assertEquals(#YardConfigList.build(TYPES, nil, {}), 0)
end)
