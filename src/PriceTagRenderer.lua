-- PriceTagRenderer
-- Replaces the vehicle's license plate with a custom "for sale" plate showing
-- the price. Supports both ELONGATED and SQUARISH plate types so the correct
-- shape is used for each vehicle mount point.
--
-- Each plate has three currency symbol nodes (£, $, €). On clone, only the
-- node matching the active game currency is shown; the other two are hidden.

PriceTagRenderer = {}

PriceTagRenderer.PLATE_XML = "xml/licensePlatesSale.xml"
PriceTagRenderer.NUM_SLOTS = 6    -- digit character slots (max "999,999")
PriceTagRenderer.MAX_PRICE = 999999

PriceTagRenderer.tags = {}             -- vehicle -> tag data
PriceTagRenderer.plateTemplates = {}   -- [PLATE_TYPE id] -> LicensePlate template
PriceTagRenderer.sharedLoadRequestId = nil
PriceTagRenderer.plateI3DNode = nil


-- ---------------------------------------------------------------------------
-- Loading
-- ---------------------------------------------------------------------------

function PriceTagRenderer.load()
    local xmlFilename = UsedEquipmentYards.dir .. PriceTagRenderer.PLATE_XML
    local xmlFile = XMLFile.load("priceTagXML", xmlFilename, LicensePlateManager.xmlSchema)
    if xmlFile == nil then
        Logging.warning("[UsedEquipmentYards] Failed to load plate XML: %s", xmlFilename)
        return
    end

    -- Both plate entries share the same i3d file — load it once.
    local i3dFilename = xmlFile:getValue("licensePlates.licensePlate(0)#filename")
    if i3dFilename == nil then
        Logging.warning("[UsedEquipmentYards] No filename in plate XML.")
        xmlFile:delete()
        return
    end

    i3dFilename = Utils.getFilename(i3dFilename, UsedEquipmentYards.dir)
    local i3dNode, sharedLoadRequestId = g_i3DManager:loadSharedI3DFile(i3dFilename, false, false)
    if i3dNode == nil or i3dNode == 0 then
        Logging.warning("[UsedEquipmentYards] Failed to load plate i3d: %s", i3dFilename)
        xmlFile:delete()
        return
    end

    PriceTagRenderer.sharedLoadRequestId = sharedLoadRequestId
    PriceTagRenderer.plateI3DNode = i3dNode
    setVisibility(i3dNode, false)

    -- Resolve all plate nodes BEFORE unlinking (indices shift after unlink).
    local entries = {}
    local i = 0
    while true do
        local key = ("licensePlates.licensePlate(%d)"):format(i)
        if not xmlFile:hasProperty(key) then break end
        local node = xmlFile:getValue(key .. "#node", nil, i3dNode)
        local pType = xmlFile:getValue(key .. "#type", "ELONGATED")
        if node ~= nil then
            entries[#entries + 1] = { node = node, plateType = pType, key = key }
        end
        i = i + 1
    end

    -- Now unlink and create LicensePlate templates.
    for _, entry in ipairs(entries) do
        unlink(entry.node)
        local plate = LicensePlate.new()
        if plate:loadFromXML(entry.node, i3dFilename, nil, xmlFile, entry.key) then
            local typeId = LicensePlateManager.PLATE_TYPE[entry.plateType]
            if typeId ~= nil then
                PriceTagRenderer.plateTemplates[typeId] = plate
            end
        end
    end

    xmlFile:delete()

    local count = 0
    for _ in pairs(PriceTagRenderer.plateTemplates) do count = count + 1 end
    print(("[UsedEquipmentYards] Price tag plates loaded (%d types)."):format(count))
end

function PriceTagRenderer.delete()
    PriceTagRenderer.removeAllTags()

    for _, plate in pairs(PriceTagRenderer.plateTemplates) do
        plate:delete()
    end
    PriceTagRenderer.plateTemplates = {}

    if PriceTagRenderer.plateI3DNode ~= nil then
        delete(PriceTagRenderer.plateI3DNode)
        PriceTagRenderer.plateI3DNode = nil
    end
    if PriceTagRenderer.sharedLoadRequestId ~= nil then
        g_i3DManager:releaseSharedI3DFile(PriceTagRenderer.sharedLoadRequestId)
        PriceTagRenderer.sharedLoadRequestId = nil
    end
end

-- ---------------------------------------------------------------------------
-- Price formatting
-- ---------------------------------------------------------------------------

--- Format a price into a character string for the plate variation.
---
--- updateData advances the string position for ALL non-static values,
--- including locked ones. The comma is the only locked slot, so:
---   D D D ,(locked) D D D  →  7 characters total
---
--- Underscore "_" is treated as hidden by the rendering system.
function PriceTagRenderer.formatPriceChars(price)
    price = math.min(price, PriceTagRenderer.MAX_PRICE)
    local numStr = tostring(math.floor(price))

    -- Pad digits to 6.
    while #numStr < PriceTagRenderer.NUM_SLOTS do
        numStr = "_" .. numStr
    end
    if #numStr > PriceTagRenderer.NUM_SLOTS then
        numStr = numStr:sub(#numStr - PriceTagRenderer.NUM_SLOTS + 1)
    end

    -- Insert padding for the locked comma slot: DDD_DDD
    return numStr:sub(1, 3) .. "_" .. numStr:sub(4, 6)
end


-- ---------------------------------------------------------------------------
-- Tag management
-- ---------------------------------------------------------------------------

--- Pick the best plate template for a vehicle mount point.
function PriceTagRenderer.getTemplateForMount(plateInfo)
    -- Try the mount's preferred type first.
    local template = PriceTagRenderer.plateTemplates[plateInfo.preferedType]
    if template ~= nil then return template end

    -- Fallback: use any available template.
    for _, t in pairs(PriceTagRenderer.plateTemplates) do
        return t
    end
    return nil
end

--- Replace the vehicle's license plates with our price tag plates.
--- Saves the original plate data so it can be restored later.
function PriceTagRenderer.addTag(vehicle, item)
    if next(PriceTagRenderer.plateTemplates) == nil then return end
    if vehicle.spec_licensePlates == nil then return end

    local spec = vehicle.spec_licensePlates
    local hasPlates = vehicle.getHasLicensePlates ~= nil and vehicle:getHasLicensePlates()
    if not hasPlates then return end

    -- Save original plate data for later restoration.
    local originalData = nil
    if spec.licensePlateData ~= nil then
        originalData = {
            variation      = spec.licensePlateData.variation,
            characters     = spec.licensePlateData.characters,
            colorIndex     = spec.licensePlateData.colorIndex,
            placementIndex = spec.licensePlateData.placementIndex,
        }
    end

    -- Hide the original plates.
    vehicle:setLicensePlatesData(nil)

    -- Clone the correct plate type for each mount point and link it in.
    local priceStr = PriceTagRenderer.formatPriceChars(item.price)
    local clones = {}

    for _, plateInfo in ipairs(spec.licensePlates) do
        local mountNode = plateInfo.node
        if mountNode ~= nil then
            local template = PriceTagRenderer.getTemplateForMount(plateInfo)
            if template ~= nil then
                local plateClone = template:clone(true)
                if plateClone ~= nil then
                    plateClone:updateData(1, LicensePlateManager.PLATE_POSITION.ANY, priceStr)
                    -- Hide the comma separator for prices ≤ 999.
                    if item.price <= 999 then
                        local symbols = getChildAt(plateClone.node, 0)
                        if symbols ~= nil then
                            local sep = getChildAt(symbols, 3)  -- d1 d2 d3 [sep] d4 d5 d6
                            if sep ~= nil then
                                setVisibility(sep, false)
                            end
                        end
                    end
                    setVisibility(plateClone.node, true)

                    link(mountNode, plateClone.node)
                    setTranslation(plateClone.node, 0, 0, 0)
                    setRotation(plateClone.node, 0, 0, 0)

                    clones[#clones + 1] = plateClone
                end
            end
        end
    end

    PriceTagRenderer.tags[vehicle] = {
        item         = item,
        originalData = originalData,
        clones       = clones,
    }
end

--- Remove price tags and restore the original license plate.
function PriceTagRenderer.removeTag(vehicle)
    local tag = PriceTagRenderer.tags[vehicle]
    if tag == nil then return end

    -- Delete our cloned plates.
    for _, plateClone in ipairs(tag.clones) do
        if plateClone.node ~= nil then
            delete(plateClone.node)
        end
    end

    -- Restore the original plate data.
    if tag.originalData ~= nil and vehicle.setLicensePlatesData ~= nil then
        vehicle:setLicensePlatesData(tag.originalData)
    end

    PriceTagRenderer.tags[vehicle] = nil
end

--- Remove all tags and restore all original plates.
function PriceTagRenderer.removeAllTags()
    for vehicle, _ in pairs(PriceTagRenderer.tags) do
        PriceTagRenderer.removeTag(vehicle)
    end
end
