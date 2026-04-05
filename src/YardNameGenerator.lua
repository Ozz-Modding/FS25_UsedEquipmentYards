-- YardNameGenerator
-- Generates unique yard names from a pool of realistic used-equipment-yard
-- style names. Tracks which names are in use so no two yards share a name.

YardNameGenerator = {}

YardNameGenerator.DEFAULT_NAME = "Used Equipment Yard"

-- Pool of ~100 yard name candidates.
YardNameGenerator.NAMES = {
    -- Surname-based
    "Ross's Yard",
    "Dobson & Sons",
    "McAllister Equipment",
    "Harper's Machinery",
    "Sullivan's Yard",
    "Thornton & Co",
    "Brennan Equipment",
    "Fletcher's Used Machinery",
    "Gallagher's Yard",
    "Whitfield & Sons",
    "Jensen Equipment",
    "Calloway's Yard",
    "Dawson & Sons",
    "Barrett Machinery",
    "Mitchell's Yard",
    "Henderson Equipment",
    "Crawford & Sons",
    "O'Brien's Yard",
    "Patterson Machinery",
    "Sinclair Equipment",
    "Walton's Yard",
    "Campbell & Sons",
    "Dixon Equipment",
    "Forsyth's Yard",
    "Hamilton Machinery",
    "Ingram & Co",
    "Lawson's Yard",
    "Murray Equipment",
    "Norris & Sons",
    "Porter's Yard",
    "Reeves Machinery",
    "Shaw Equipment",
    "Tucker's Yard",
    "Vickers & Sons",
    "Ward's Machinery",
    "Young Equipment",

    -- Place / descriptive
    "Crossroads Equipment",
    "Hillside Yard",
    "Valley Farm Machinery",
    "Riverside Equipment",
    "Old Mill Yard",
    "Orchard Lane Machinery",
    "Meadow View Equipment",
    "Stonegate Yard",
    "Brookfield Machinery",
    "Highfield Equipment",
    "Oakwood Yard",
    "Lakeside Machinery",
    "Pinewood Equipment",
    "Ridgeway Yard",
    "Thornfield Machinery",
    "Westgate Equipment",
    "Blackthorn Yard",
    "Copperfield Machinery",
    "Elm Park Equipment",
    "Greenfield Yard",

    -- Trade / descriptive style
    "County Line Equipment",
    "Farmgate Machinery",
    "Iron Horse Yard",
    "Rust Belt Equipment",
    "Second Chance Machinery",
    "Honest Deals Yard",
    "Square Deal Equipment",
    "Workhorse Machinery",
    "Ironside Yard",
    "Heritage Equipment",
    "Pioneer Machinery",
    "Trailside Yard",
    "Blue Ribbon Equipment",
    "Golden Acre Machinery",
    "Clearfield Yard",
    "Prairie Equipment",
    "Harvest Moon Machinery",
    "Sunrise Yard",
    "Stockyard Equipment",
    "Heartland Machinery",

    -- Initials / compact
    "J&R Equipment",
    "T.W. Machinery",
    "A&B Yard",
    "K.D. Equipment",
    "M&S Machinery",
    "P.H. Yard",
    "R&L Equipment",
    "S.J. Machinery",
    "W&T Yard",
    "D.C. Equipment",

    -- Regional flavour
    "Northfield Traders",
    "Southbank Machinery",
    "Eastridge Equipment",
    "Westbury Yard",
    "Millbrook Machinery",
    "Ashford Equipment",
    "Langley Yard",
    "Hadley & Sons",
    "Pemberton Machinery",
    "Kingswood Equipment",
}

-- Set of names currently in use (values are true).
YardNameGenerator.usedNames = {}

--- Initialise from existing yards so loaded names are tracked.
function YardNameGenerator.init(yards)
    YardNameGenerator.usedNames = {}
    for _, yard in pairs(yards) do
        if yard.name ~= nil then
            YardNameGenerator.usedNames[yard.name] = true
        end
    end
end

--- Pick a random unused name. Returns DEFAULT_NAME if all names are taken.
function YardNameGenerator.generateName()
    -- Build list of available names.
    local available = {}
    for _, name in ipairs(YardNameGenerator.NAMES) do
        if not YardNameGenerator.usedNames[name] then
            available[#available + 1] = name
        end
    end

    if #available == 0 then
        return YardNameGenerator.DEFAULT_NAME
    end

    local name = available[math.random(1, #available)]
    YardNameGenerator.usedNames[name] = true
    return name
end

--- Mark a name as in use (e.g. when loaded from save).
function YardNameGenerator.markUsed(name)
    if name ~= nil then
        YardNameGenerator.usedNames[name] = true
    end
end

--- Release a name back to the pool (e.g. when a yard is demolished).
function YardNameGenerator.release(name)
    if name ~= nil then
        YardNameGenerator.usedNames[name] = nil
    end
end

--- Rename a yard: release the old name and mark the new one.
function YardNameGenerator.rename(oldName, newName)
    YardNameGenerator.release(oldName)
    YardNameGenerator.markUsed(newName)
end
