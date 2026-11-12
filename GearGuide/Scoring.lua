local _, ns = ...

-- ScoreItem turns an item into one number so items in the same slot can be ranked.
--
--   item.st  : normalized stats, e.g. { STR = 12, STA = 8, ARMOR = 210, DPS = 14.5 }
--   item.c   : item class (2 = weapon, 4 = armor)
--   item.sc  : subclass (armor: 1 cloth, 2 leather, 3 mail, 4 plate)
--   item.eq  : equip location, e.g. "INVTYPE_2HWEAPON", "INVTYPE_RANGED"
--   weights  : value per stat point for the player's class + role (ClassData.lua)
--   ctx      : { class = "WARRIOR", role = "MELEE", level = 34,
--                armorMax = 3 }  -- best armor type the class can wear at the item's level
--
-- Return a number; higher is better. Called for every item in the browser,
-- so keep it cheap (no API calls).
function ns.ScoreItem(item, weights, ctx)
    local score = 0
    for stat, value in pairs(item.st or {}) do
        score = score + value * (weights[stat] or 0)
    end
    -- TODO(human): adjust `score` for armor type below ctx.armorMax, weapon DPS relevance, two-handers
    return score
end
