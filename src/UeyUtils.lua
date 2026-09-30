-- Defensive helpers. Each one checks the preconditions the
-- engine function would otherwise fail on, so callers never need to trap errors.
UeyUtils = {}

function UeyUtils.isNumber(value)
    -- value ~= value filters NaN, which setXMLFloat would write as garbage.
    return type(value) == "number" and value == value
end

function UeyUtils.isNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

--- Return value if it is a valid number, otherwise default.
function UeyUtils.toNumber(value, default)
    local n = tonumber(value)
    if UeyUtils.isNumber(n) then
        return n
    end
    return default
end

--- Safe replacement for StoreItemUtil.loadSpecsFromXML. The engine version passes the
--- result of XMLFile.load straight to getSpecsFromXML and calls :delete() on it with no
--- nil check, so a store item whose XML is missing or unreadable throws. Here we bail
--- out instead and leave si.specs nil. Bundle items are not handled (callers exclude
--- bundles or only need the top-level item's specs).
--- @return boolean true if si.specs is available after the call
function UeyUtils.loadStoreItemSpecs(si)
    if si == nil then
        return false
    end
    if si.specs ~= nil then
        return true
    end
    if not UeyUtils.isNonEmptyString(si.xmlFilename) or si.xmlSchema == nil then
        return false
    end
    if g_storeManager == nil or g_storeManager.getSpecTypes == nil then
        return false
    end

    local xmlFile = XMLFile.loadIfExists("storeItemXML", si.xmlFilename, si.xmlSchema)
    if xmlFile == nil then
        return false
    end

    si.specs = StoreItemUtil.getSpecsFromXML(g_storeManager:getSpecTypes(), si.species, xmlFile,
        si.customEnvironment, si.baseDir)
    xmlFile:delete()
    return si.specs ~= nil
end
