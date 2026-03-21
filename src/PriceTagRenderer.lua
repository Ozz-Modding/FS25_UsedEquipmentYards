-- PriceTagRenderer
-- Sets the vehicle's existing license plate to display the price.
-- No custom models or per-frame rendering — just updates the plate text
-- that's already attached to the vehicle.

PriceTagRenderer = {}

PriceTagRenderer.tags = {}

-- ---------------------------------------------------------------------------
-- Loading / cleanup (no-ops now, kept for API compatibility with main.lua)
-- ---------------------------------------------------------------------------

function PriceTagRenderer.load()
end

function PriceTagRenderer.delete()
    PriceTagRenderer.removeAllTags()
end

-- ---------------------------------------------------------------------------
-- Price formatting
-- ---------------------------------------------------------------------------

--- Format a price into characters for a license plate.
--- Plates only reliably support digits (0-9), so we use plain numbers.
--- The plate slot count varies per map/template, but typically 7-9 slots.
--- We pad with leading "_" (hidden) to fill available slots.
function PriceTagRenderer.formatPriceChars(price, numSlots)
    local str = tostring(math.floor(price))
    local chars = {}
    for i = 1, #str do
        chars[#chars + 1] = str:sub(i, i)
    end
    -- Pad to numSlots with leading "_" (hidden character).
    while #chars < numSlots do
        table.insert(chars, 1, "_")
    end
    -- Truncate from the left if price has more digits than slots.
    while #chars > numSlots do
        table.remove(chars, 1)
    end
    return chars
end

--- Count the number of non-static, non-locked character slots in the plate.
function PriceTagRenderer.countEditableSlots(vehicle)
    local spec = vehicle.spec_licensePlates
    if spec == nil or #spec.licensePlates == 0 then return 0 end
    local plateInfo = spec.licensePlates[1]
    if plateInfo.data == nil then return 0 end
    local variation = plateInfo.data.variations[1]
    if variation == nil then return 0 end
    local count = 0
    for _, val in ipairs(variation.values) do
        if not val.isStatic and not val.locked then
            count = count + 1
        end
    end
    return count
end

-- ---------------------------------------------------------------------------
-- Tag management
-- ---------------------------------------------------------------------------

--- Update the vehicle's license plate to show its price.
function PriceTagRenderer.addTag(vehicle, item)
    if vehicle.setLicensePlatesData == nil or not vehicle:getHasLicensePlates() then
        return
    end

    local numSlots = PriceTagRenderer.countEditableSlots(vehicle)
    if numSlots <= 0 then return end

    local chars = PriceTagRenderer.formatPriceChars(item.price, numSlots)

    local data = {
        variation      = 1,
        characters     = chars,
        colorIndex     = 1,
        placementIndex = LicensePlateManager.PLACEMENT_OPTION.BOTH,
    }

    vehicle:setLicensePlatesData(data)
    PriceTagRenderer.tags[vehicle] = true
end

--- Restore default plate (hide it) when vehicle is removed.
function PriceTagRenderer.removeTag(vehicle)
    if PriceTagRenderer.tags[vehicle] then
        if vehicle.setLicensePlatesData ~= nil then
            vehicle:setLicensePlatesData(nil)
        end
        PriceTagRenderer.tags[vehicle] = nil
    end
end

--- Remove all tags.
function PriceTagRenderer.removeAllTags()
    for vehicle, _ in pairs(PriceTagRenderer.tags) do
        if vehicle.setLicensePlatesData ~= nil then
            vehicle:setLicensePlatesData(nil)
        end
    end
    PriceTagRenderer.tags = {}
end
