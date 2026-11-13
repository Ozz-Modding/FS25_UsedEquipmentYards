-- Fake FS25 engine globals for the unit tests. stubs.install() resets them
-- and returns a `world` for loading src/ files, building the scene a test
-- needs (store items, vehicles, obstacles) and reading back what happened
-- (moves, broadcasts, logs). Call it at the start of every test, before
-- loading any src/ file.
--
-- These are our assumptions about the base game (checked against
-- ../Reference/FS25_Lua where it matters), not the game itself: a test
-- that passes here can still be wrong in-game.
--
-- Extend this when code under test needs another engine call.

local stubs = {}

local function installXML()
    -- An xmlFile is a plain table, key -> value.
    local function set(xmlFile, key, value)
        xmlFile[key] = value
    end
    local function get(xmlFile, key)
        return xmlFile[key]
    end
    setXMLInt, setXMLFloat, setXMLString, setXMLBool = set, set, set, set
    getXMLInt, getXMLFloat, getXMLString, getXMLBool = get, get, get, get
    hasXMLProperty = function(xmlFile, key)
        for existing in pairs(xmlFile) do
            if existing == key or existing:sub(1, #key + 1) == key .. "#" or existing:sub(1, #key + 1) == key .. "." then
                return true
            end
        end
        return false
    end
end

-- The mod's real English texts, so a missing key fails the test.
local function loadTexts(path)
    local file = io.open(path, "r")
    assert(file ~= nil, "can't open " .. path)
    local content = file:read("*a")
    file:close()
    local entities = { amp = "&", lt = "<", gt = ">", quot = "\"", apos = "'" }
    local texts = {}
    for name, text in content:gmatch("<text%s+name=\"([^\"]+)\"%s+text=\"([^\"]*)\"") do
        texts[name] = text:gsub("&(%a+);", entities)
    end
    return texts
end

local englishTexts = nil

-- Streams: a plain table used as a queue (world:newStream()).
local function installStreams()
    local function write(stream, value)
        table.insert(stream, value)
        return value
    end
    local function read(stream)
        return table.remove(stream, 1)
    end
    for _, kind in ipairs({ "Int32", "UInt8", "UInt16", "Float32", "String", "Bool" }) do
        _G["streamWrite" .. kind] = write
        _G["streamRead" .. kind] = read
    end
end

function stubs.install()
    math.randomseed(1)
    installStreams()
    englishTexts = englishTexts or loadTexts("languages/l10n_en.xml")
    g_i18n = {
        getText = function(_, key)
            local text = englishTexts[key]
            assert(text ~= nil, "missing l10n key: " .. tostring(key))
            return text
        end,
        convertText = function(_, text)
            return text
        end,
    }
    g_time = 0

    -- Class() as the game defines it: a metatable with __index, plus
    -- superClass() / class() on the members.
    Class = function(members, baseClass)
        members = members or {}
        if baseClass ~= nil then
            setmetatable(members, { __index = baseClass })
        end
        members.superClass = function()
            return baseClass
        end
        members.class = function()
            return members
        end
        return { __index = members }
    end

    local world = {
        logs = {},
        broadcasts = {},
        storeItems = {},
        vehicles = {},     -- every live vehicle
        nodes = {},        -- node id -> { x, y, z, ry }
        nodeToObject = {},
        obstacles = {},    -- { x, z }: static objects overlapBox hits
        nextNode = 1,
        nextVehicleId = 1,
        moves = 0,         -- setAbsolutePosition calls
    }

    local function log(level)
        return function(format, ...)
            table.insert(world.logs, { level = level, text = string.format(format, ...) })
        end
    end
    Logging = { info = log("info"), warning = log("warning"), error = log("error") }

    installXML()

    --- Load a src/ file, path relative to the repo root.
    function world:load(path)
        dofile(path)
    end

    -- Store ------------------------------------------------------------------------------

    --- A store vehicle: { xmlFilename, width, length, widthOffset?, lengthOffset?,
    --- category?, price? }.
    function world:addStoreItem(def)
        local item = {
            xmlFilename = def.xmlFilename,
            name = def.xmlFilename,
            showInStore = true,
            price = def.price or 50000,
            brandIndex = 1,
            categoryNames = { def.category or "TRACTORSS" },
            specs = {}, -- already loaded: UeyUtils.loadStoreItemSpecs skips the XML
            rotation = 0,
            size = {
                width = def.width, length = def.length,
                widthOffset = def.widthOffset or 0, lengthOffset = def.lengthOffset or 0,
            },
        }
        table.insert(self.storeItems, item)
        return item
    end

    g_storeManager = {
        getItems = function()
            return world.storeItems
        end,
        getItemByXMLFilename = function(_, xmlFilename)
            for _, item in ipairs(world.storeItems) do
                if item.xmlFilename == xmlFilename then
                    return item
                end
            end
            return nil
        end,
    }
    g_brandManager = {
        getBrandByIndex = function()
            return { name = "BRAND" }
        end,
    }
    StoreItemUtil = {
        getIsVehicle = function()
            return true
        end,
        getDefaultPrice = function(storeItem)
            return storeItem.price
        end,
        getSizeValues = function(xmlFilename)
            local item = g_storeManager:getItemByXMLFilename(xmlFilename)
            local size = item.size
            return { width = size.width, length = size.length, widthOffset = size.widthOffset,
                lengthOffset = size.lengthOffset }
        end,
    }
    Vehicle = {
        calculateSellPrice = function(_, _, _, price)
            return price * 0.6
        end,
    }
    Wearable = nil

    -- Scene ------------------------------------------------------------------------------

    g_terrainNode = 1
    getTerrainHeightAtWorldPos = function()
        return 0
    end
    getWorldTranslation = function(node)
        local n = world.nodes[node]
        return n.x, n.y, n.z
    end

    --- A vehicle at (x, z) facing yaw, in physics.
    function world:addVehicle(storeItem, x, z, yaw)
        local node = self.nextNode
        self.nextNode = self.nextNode + 1
        self.nodes[node] = { x = x, y = 0, z = z, ry = yaw or 0 }
        local vehicle = {
            id = self.nextVehicleId,
            uniqueId = "vehicle" .. self.nextVehicleId,
            rootNode = node,
            configFileName = storeItem.xmlFilename,
            configurations = {},
            operatingTime = 0,
            age = 1,
            inPhysics = true,
            ownerFarmId = 0,
        }
        self.nextVehicleId = self.nextVehicleId + 1
        function vehicle:removeFromPhysics()
            self.inPhysics = false
        end
        function vehicle:addToPhysics()
            self.inPhysics = true
        end
        function vehicle:setAbsolutePosition(px, py, pz, _, ry)
            world.moves = world.moves + 1
            local n = world.nodes[self.rootNode]
            n.x, n.y, n.z, n.ry = px, py, pz, ry
        end
        function vehicle:delete()
            self.isDeleted = true
            for i, v in ipairs(world.vehicles) do
                if v == self then
                    table.remove(world.vehicles, i)
                    break
                end
            end
        end
        function vehicle:setOperatingTime(ms)
            self.operatingTime = ms
        end
        function vehicle:setOwnerFarmId(farmId)
            self.ownerFarmId = farmId
        end
        function vehicle:getPrice()
            return storeItem.price
        end
        table.insert(self.vehicles, vehicle)
        self.nodeToObject[node] = vehicle
        return vehicle
    end

    function world:getYaw(vehicle)
        return self.nodes[vehicle.rootNode].ry
    end

    -- overlapBox: hits any obstacle point or in-physics vehicle root inside the box.
    overlapBox = function(x, _, z, _, ry, _, ex, _, ez, callback, target)
        local c, s = math.cos(ry), math.sin(ry)
        local function insideBox(px, pz)
            local dx, dz = px - x, pz - z
            -- Local x = (cos, -sin), local z = (sin, cos).
            local lx = dx * c - dz * s
            local lz = dx * s + dz * c
            return math.abs(lx) <= ex and math.abs(lz) <= ez
        end
        for _, obstacle in ipairs(world.obstacles) do
            if insideBox(obstacle.x, obstacle.z) then
                if not target[callback](target, 0) then
                    return
                end
            end
        end
        for _, vehicle in ipairs(world.vehicles) do
            local n = world.nodes[vehicle.rootNode]
            if vehicle.inPhysics and insideBox(n.x, n.z) then
                if not target[callback](target, vehicle.rootNode) then
                    return
                end
            end
        end
    end

    VehicleLoadingState = { OK = 1, ERROR = 2 }
    VehiclePropertyState = { OWNED = 1 }

    -- Loads straight away, at the position it was given.
    VehicleLoadingData = {
        new = function()
            local data = {}
            function data:setStoreItem(storeItem) self.storeItem = storeItem end
            function data:setConfigurations(configurations) self.configurations = configurations end
            function data:setPosition(px, _, pz) self.x, self.z = px, pz end
            function data:setRotation(_, ry) self.ry = ry end
            function data:setIgnoreShopOffset() end
            function data:setPropertyState() end
            function data:setOwnerFarmId() end
            function data:cancelLoading() end
            function data:load(callback, target, args)
                local vehicle = world:addVehicle(self.storeItem, self.x, self.z, self.ry)
                callback(target, { vehicle }, VehicleLoadingState.OK, args)
            end
            return data
        end,
    }

    -- Mission / network ------------------------------------------------------------------

    g_currentMission = {
        environment = { currentMonotonicDay = 1, currentHour = 8 },
        getNodeObject = function(_, node)
            return world.nodeToObject[node]
        end,
        activatableObjectsSystem = {
            addActivatable = function() end,
            removeActivatable = function() end,
        },
        vehicleSystem = {
            getVehicleByUniqueId = function(_, uniqueId)
                for _, vehicle in ipairs(world.vehicles) do
                    if vehicle.uniqueId == uniqueId then
                        return vehicle
                    end
                end
                return nil
            end,
        },
    }
    g_server = {
        broadcastEvent = function(_, event)
            table.insert(world.broadcasts, event)
        end,
    }
    NetworkUtil = {
        getObjectId = function(object)
            return object.id
        end,
    }
    VehicleItemSyncEvent = {
        new = function(yardId, item)
            return { type = "VehicleItemSyncEvent", yardId = yardId, item = item }
        end,
    }
    VehicleItemRemovedEvent = {
        new = function(yardId, vehicleId)
            return { type = "VehicleItemRemovedEvent", yardId = yardId, vehicleId = vehicleId }
        end,
    }
    YardVehicleActivatable = {
        new = function(yard, item)
            return { yard = yard, item = item }
        end,
    }
    PriceTagRenderer = { addTag = function() end, removeTag = function() end }
    UsedEquipmentYards = {
        vehicleToItem = {},
        setADSExcluded = function() end,
        clearVehicleRestrictions = function() end,
    }

    -- Multiplayer / permissions, network events ------------------------------------------

    world.sentEvents = {}   -- client -> server
    world.warnings = {}     -- showBlinkingWarning texts
    world.placeables = {}
    g_currentMission.missionDynamicInfo = { isMultiplayer = false }
    g_currentMission.isMasterUser = false
    g_currentMission.getIsServer = function()
        return world.isServer ~= false
    end
    g_currentMission.showBlinkingWarning = function(_, text)
        table.insert(world.warnings, text)
    end
    g_currentMission.placeableSystem = { placeables = world.placeables }
    g_currentMission.userManager = {
        getUserByConnection = function(_, connection)
            return connection.user
        end,
    }
    world.serverConnection = {
        sendEvent = function(_, event)
            table.insert(world.sentEvents, event)
        end,
    }
    g_client = {
        getServerConnection = function()
            return world.serverConnection
        end,
    }

    --- A connection as the server sees it: from a client (local = host).
    function world:clientConnection(isAdmin, isLocal)
        return {
            getIsServer = function() return false end,
            getIsLocal = function() return isLocal == true end,
            user = { getIsMasterUser = function() return isAdmin == true end },
        }
    end

    function world:newStream()
        return {}
    end

    Event = {
        new = function(mt)
            return setmetatable({}, mt)
        end,
    }
    InitEventClass = function() end

    -- main.lua's load-time hooks --------------------------------------------------------

    g_currentModDirectory = "./"
    g_currentModName = "FS25_UsedEquipmentYards"
    world.brushTypes = {}
    g_constructionBrushTypeManager = {
        addBrushType = function(_, typeName, className, filename, customEnvironment)
            table.insert(world.brushTypes, { typeName = typeName, className = className, filename = filename,
                customEnvironment = customEnvironment })
            return true
        end,
    }
    FSBaseMission = {}
    Mission00 = nil
    Utils = {
        appendedFunction = function(first, second)
            return function(...)
                if first ~= nil then
                    first(...)
                end
                return second(...)
            end
        end,
        overwrittenFunction = function(old, new)
            return function(self, ...)
                return new(self, old, ...)
            end
        end,
    }
    addModEventListener = function() end
    Attachable = nil
    PlayerHUDUpdater = nil

    --- Load main.lua and what the yard manager needs (events, managers, specs).
    function world:loadMod()
        for _, path in ipairs({ "src/UeyUtils.lua", "src/YardLayout.lua", "src/YardZone.lua",
            "src/YardInventory.lua", "src/UsedEquipmentYard.lua", "src/YardManager.lua",
            "src/YardNameGenerator.lua", "src/YardConfigActivatable.lua", "src/PlaceableSaleZone.lua",
            "src/PlaceableUsedEquipmentYard.lua", "src/events/YardCreatedEvent.lua",
            "src/events/YardRemovedEvent.lua", "src/events/YardUpdatedEvent.lua",
            "src/events/YardZoneEvent.lua", "src/main.lua" }) do
            self:load(path)
        end
        YardInventory.HOURLY_SPAWN_CHANCE = 0
    end

    -- The build menu ---------------------------------------------------------------------

    --- The construction cursor: aim it with world:aim(x, z) (nil = no ground hit).
    function world:makeCursor()
        local cursor = { messages = {}, errors = {} }
        function cursor:getHitTerrainPosition()
            if self.x == nil then
                return nil, nil, nil
            end
            return self.x, 0, self.z
        end
        function cursor:setMessage(text) table.insert(self.messages, text) end
        function cursor:setErrorMessage(text) table.insert(self.errors, text) end
        for _, name in ipairs({ "setRotationEnabled", "setShape", "setShapeSize", "setColorMode", "setTerrainOnly",
            "setCursorTerrainOffset" }) do
            cursor[name] = function() end
        end
        self.cursor = cursor
        return cursor
    end

    function world:aim(x, z)
        self.cursor.x, self.cursor.z = x, z
    end

    --- Load the yard tool (and the base brush it extends).
    function world:loadBrush()
        ConstructionBrush = {}
        local ConstructionBrush_mt = Class(ConstructionBrush)
        function ConstructionBrush.new(customMt, cursor)
            local self = setmetatable({}, customMt or ConstructionBrush_mt)
            self.cursor = cursor
            self.isActive = false
            self.inputTextDirty = true
            return self
        end
        function ConstructionBrush:delete()
            if self.isActive then
                self:deactivate()
            end
        end
        function ConstructionBrush:activate() self.isActive = true end
        function ConstructionBrush:deactivate() self.isActive = false end
        function ConstructionBrush:setStoreItem(storeItem) self.storeItem = storeItem end
        function ConstructionBrush:update() end
        function ConstructionBrush:draw() end
        function ConstructionBrush:setInputTextDirty() self.inputTextDirty = true end

        GuiTopDownCursor = { SHAPES = { NONE = 0, CIRCLE = 1 }, SHAPES_COLORS = { SUCCESS = 0, ERROR = 1, SELECT = 3 } }
        Color = { PRESETS = { WHITE = "white", YELLOW = "yellow", RED = "red", GREEN = "green", ORANGE = "orange",
            CYAN = "cyan" } }
        local function visual()
            return {
                items = {},
                setLineScale = function() end,
                setScale = function() end,
                delete = function() end,
                clearVisualization = function(v) v.items = {} end,
                visualizeLine = function(v, sx, sy, sz, ex, ey, ez, align, color)
                    table.insert(v.items, { sx = sx, sz = sz, ex = ex, ez = ez, color = color })
                end,
                visualizeMarker = function(v, x, y, z, color)
                    table.insert(v.items, { x = x, z = z, color = color })
                end,
            }
        end
        Line3D = { new = visual }
        Marker3D = { new = visual }
        world.dialogs = {}
        YesNoDialog = {
            show = function(callback, target, text)
                table.insert(world.dialogs, { callback = callback, text = text })
            end,
        }
        self:load("src/brush/UeyYardZoneBrush.lua")
    end

    return world
end

return stubs
