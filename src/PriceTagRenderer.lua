-- PriceTagRenderer
-- Replaces the vehicle's license plate with a custom plate showing the price.
-- Uses the map's existing license plate font (digits + comma/period separators).
--
-- Clones our plate i3d per vehicle, linked to the existing plate mount nodes.
-- Original plate data is saved and restored on removal (e.g. on purchase).

PriceTagRenderer = {}

PriceTagRenderer.PLATE_XML = "xml/priceTag.xml"
PriceTagRenderer.NUM_SLOTS = 7    -- character slots (max "999,999")
PriceTagRenderer.MAX_PRICE = 999999

PriceTagRenderer.tags = {}        -- vehicle -> tag data
PriceTagRenderer.plateTemplate = nil
PriceTagRenderer.sharedLoadRequestId = nil
PriceTagRenderer.plateI3DNode = nil

-- ---------------------------------------------------------------------------
-- Loading
-- ---------------------------------------------------------------------------

function PriceTagRenderer.load()
    local xmlFilename = UsedEquipmentYards.dir .. PriceTagRenderer.PLATE_XML
    local xmlFile = XMLFile.load("priceTagXML", xmlFilename, LicensePlateManager.xmlSchema)
    if xmlFile == nil then
        Logging.warning("[UsedEquipmentYards] Failed to load price tag XML: %s", xmlFilename)
        return
    end

    local i3dFilename = xmlFile:getValue("licensePlates.licensePlate(0)#filename")
    if i3dFilename == nil then
        Logging.warning("[UsedEquipmentYards] No filename in price tag XML.")
        xmlFile:delete()
        return
    end

    i3dFilename = Utils.getFilename(i3dFilename, UsedEquipmentYards.dir)
    local i3dNode, sharedLoadRequestId = g_i3DManager:loadSharedI3DFile(i3dFilename, false, false)
    if i3dNode == nil or i3dNode == 0 then
        Logging.warning("[UsedEquipmentYards] Failed to load price tag i3d: %s", i3dFilename)
        xmlFile:delete()
        return
    end

    PriceTagRenderer.sharedLoadRequestId = sharedLoadRequestId

    local plateNode = xmlFile:getValue("licensePlates.licensePlate(0)#node", nil, i3dNode)
    if plateNode == nil then
        Logging.warning("[UsedEquipmentYards] Could not find plate node in i3d.")
        delete(i3dNode)
        xmlFile:delete()
        return
    end

    unlink(plateNode)

    local plate = LicensePlate.new()
    local key = "licensePlates.licensePlate(0)"
    if not plate:loadFromXML(plateNode, i3dFilename, nil, xmlFile, key) then
        Logging.warning("[UsedEquipmentYards] Failed to load LicensePlate from XML.")
        delete(plateNode)
        delete(i3dNode)
        xmlFile:delete()
        return
    end

    PriceTagRenderer.plateTemplate = plate
    PriceTagRenderer.plateI3DNode = i3dNode
    setVisibility(i3dNode, false)

    xmlFile:delete()
    print("[UsedEquipmentYards] Price tag plate template loaded.")
end

function PriceTagRenderer.delete()
    PriceTagRenderer.removeAllTags()

    if PriceTagRenderer.plateTemplate ~= nil then
        PriceTagRenderer.plateTemplate:delete()
        PriceTagRenderer.plateTemplate = nil
    end
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

--- Format a price into characters for the plate using the game's number format.
--- Uses digits + locale thousand separators (comma or period).
--- Padded to NUM_SLOTS with leading "_" (hidden).
function PriceTagRenderer.formatPriceChars(price)
    price = math.min(price, PriceTagRenderer.MAX_PRICE)
    local numStr = g_i18n:formatNumber(math.floor(price), 0)

    -- Strip non-breaking spaces (UTF-8: \194\160) that formatNumber may add.
    numStr = numStr:gsub("\194\160", "")

    local numSlots = PriceTagRenderer.NUM_SLOTS

    while #numStr < numSlots do
        numStr = "_" .. numStr
    end
    if #numStr > numSlots then
        numStr = numStr:sub(#numStr - numSlots + 1)
    end

    return numStr
end

-- ---------------------------------------------------------------------------
-- Tag management
-- ---------------------------------------------------------------------------

--- Replace the vehicle's license plates with our price tag plates.
--- Saves the original plate data so it can be restored later.
function PriceTagRenderer.addTag(vehicle, item)
    if PriceTagRenderer.plateTemplate == nil then return end
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

    -- Clone our custom plate for each mount point and link it in.
    local priceStr = PriceTagRenderer.formatPriceChars(item.price)
    local clones = {}

    for _, plateInfo in ipairs(spec.licensePlates) do
        local mountNode = plateInfo.node
        if mountNode ~= nil then
            local plateClone = PriceTagRenderer.plateTemplate:clone(true)
            if plateClone ~= nil then
                plateClone:updateData(1, LicensePlateManager.PLATE_POSITION.ANY, priceStr)
                setVisibility(plateClone.node, true)

                link(mountNode, plateClone.node)
                setTranslation(plateClone.node, 0, 0, 0)
                setRotation(plateClone.node, 0, 0, 0)

                clones[#clones + 1] = plateClone
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
