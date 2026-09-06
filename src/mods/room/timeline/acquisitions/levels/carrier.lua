-- Stateless classification shared by level acquisition and producer binding.
local carrier = {}

local visibleNames = {
    StackUpgrade = true,
    StackUpgradeBig = true,
    StackUpgradeTriple = true,
}

function carrier.isVisible(value)
    return type(value) == "table" and visibleNames[value.Name or value.ItemName or value.LootName] == true
end

return carrier
