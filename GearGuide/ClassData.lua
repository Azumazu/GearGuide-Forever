local _, ns = ...

ns.ITEM_CLASS_WEAPON = 2
ns.ITEM_CLASS_ARMOR = 4

-- Slot groups, in display order. `inv` = equipment slot IDs the group is compared against.
ns.SLOT_GROUPS = {
    { key = "HEAD",     label = "Head",      inv = { 1 } },
    { key = "NECK",     label = "Neck",      inv = { 2 } },
    { key = "SHOULDER", label = "Shoulder",  inv = { 3 } },
    { key = "BACK",     label = "Back",      inv = { 15 } },
    { key = "CHEST",    label = "Chest",     inv = { 5 } },
    { key = "WRIST",    label = "Wrist",     inv = { 9 } },
    { key = "HANDS",    label = "Hands",     inv = { 10 } },
    { key = "WAIST",    label = "Waist",     inv = { 6 } },
    { key = "LEGS",     label = "Legs",      inv = { 7 } },
    { key = "FEET",     label = "Feet",      inv = { 8 } },
    { key = "FINGER",   label = "Finger",    inv = { 11, 12 } },
    { key = "TRINKET",  label = "Trinket",   inv = { 13, 14 } },
    { key = "MAINHAND", label = "Main Hand", inv = { 16 } },
    { key = "OFFHAND",  label = "Off Hand",  inv = { 17 } },
    { key = "RANGED",   label = "Ranged",    inv = { 18 } },
}

ns.SLOT_GROUP_BY_KEY = {}
for _, g in ipairs(ns.SLOT_GROUPS) do ns.SLOT_GROUP_BY_KEY[g.key] = g end

-- Equip location -> slot group. Anything not listed (shirts, tabards, bags, ammo) is ignored.
ns.EQUIPLOC_GROUP = {
    INVTYPE_HEAD = "HEAD", INVTYPE_NECK = "NECK", INVTYPE_SHOULDER = "SHOULDER",
    INVTYPE_CLOAK = "BACK", INVTYPE_CHEST = "CHEST", INVTYPE_ROBE = "CHEST",
    INVTYPE_WRIST = "WRIST", INVTYPE_HAND = "HANDS", INVTYPE_WAIST = "WAIST",
    INVTYPE_LEGS = "LEGS", INVTYPE_FEET = "FEET", INVTYPE_FINGER = "FINGER",
    INVTYPE_TRINKET = "TRINKET",
    INVTYPE_WEAPON = "MAINHAND", INVTYPE_2HWEAPON = "MAINHAND", INVTYPE_WEAPONMAINHAND = "MAINHAND",
    INVTYPE_WEAPONOFFHAND = "OFFHAND", INVTYPE_SHIELD = "OFFHAND", INVTYPE_HOLDABLE = "OFFHAND",
    INVTYPE_RANGED = "RANGED", INVTYPE_RANGEDRIGHT = "RANGED", INVTYPE_THROWN = "RANGED",
    INVTYPE_RELIC = "RANGED",
}

-- Armor subclasses: 0 misc, 1 cloth, 2 leather, 3 mail, 4 plate, 6 shield, 7 libram, 8 idol, 9 totem.
-- `max` = best body armor type; `upgradeAt` = level the class learns the next type (vanilla rules).
ns.ARMOR_PROF = {
    WARRIOR = { max = 3, upgradeAt = 40, shield = true },
    PALADIN = { max = 3, upgradeAt = 40, shield = true, relic = 7 },
    HUNTER  = { max = 2, upgradeAt = 40 },
    SHAMAN  = { max = 2, upgradeAt = 40, shield = true, relic = 9 },
    ROGUE   = { max = 2 },
    DRUID   = { max = 2, relic = 8 },
    PRIEST  = { max = 1 },
    MAGE    = { max = 1 },
    WARLOCK = { max = 1 },
}

local function set(...)
    local t = {}
    for i = 1, select("#", ...) do t[select(i, ...)] = true end
    return t
end

-- Weapon subclasses: 0 1H axe, 1 2H axe, 2 bow, 3 gun, 4 1H mace, 5 2H mace, 6 polearm, 7 1H sword,
-- 8 2H sword, 10 staff, 13 fist, 15 dagger, 16 thrown, 18 crossbow, 19 wand.
ns.WEAPON_PROF = {
    WARRIOR = set(0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 13, 15, 16, 18),
    PALADIN = set(0, 1, 4, 5, 6, 7, 8),
    HUNTER  = set(0, 1, 2, 3, 6, 7, 8, 10, 13, 15, 16, 18),
    ROGUE   = set(2, 3, 4, 7, 13, 15, 16, 18),
    SHAMAN  = set(0, 1, 4, 5, 10, 13, 15),
    DRUID   = set(4, 5, 10, 13, 15),
    PRIEST  = set(4, 10, 15, 19),
    MAGE    = set(7, 10, 15, 19),
    WARLOCK = set(7, 10, 15, 19),
}

ns.CLASS_LIST = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

-- Level at which a class learns dual wield (so they may want two copies of INVTYPE_WEAPON items).
ns.DUAL_WIELD = { WARRIOR = 20, HUNTER = 20, ROGUE = 10 }

-- Specializations, in talent-tab order (tab = which talent tree auto-detection maps to the spec).
-- role picks the base weights in ROLE_WEIGHTS; mod overrides individual stat weights for the spec.
local I = "Interface\\Icons\\"
ns.CLASS_SPECS = {
    WARRIOR = {
        { key = "ARMS",        label = "Arms",          role = "MELEE",  tab = 1, icon = I .. "Ability_Warrior_SavageBlow", mod = { STR = 1.2, AGI = 0.8 } },
        { key = "FURY",        label = "Fury",          role = "MELEE",  tab = 2, icon = I .. "Ability_Warrior_InnerRage",  mod = { STR = 1.2, AGI = 0.9, HIT = 16 } },
        { key = "PROTECTION",  label = "Protection",    role = "TANK",   tab = 3, icon = I .. "INV_Shield_06",              mod = {} },
    },
    PALADIN = {
        { key = "HOLY",        label = "Holy",          role = "HEALER", tab = 1, icon = I .. "Spell_Holy_HolyBolt",        mod = { INT = 1.2, SPI = 0.3, HEAL = 0.7 } },
        { key = "PROTECTION",  label = "Protection",    role = "TANK",   tab = 2, icon = I .. "Spell_Holy_DevotionAura",    mod = { INT = 0.3, SP = 0.4, BLOCK = 4 } },
        { key = "RETRIBUTION", label = "Retribution",   role = "MELEE",  tab = 3, icon = I .. "Spell_Holy_AuraOfLight",     mod = { STR = 1.2, AGI = 0.6, INT = 0.2 } },
    },
    HUNTER = {
        { key = "BEASTMASTERY", label = "Beast Mastery", role = "RANGED", tab = 1, icon = I .. "Ability_Hunter_BeastTaming", mod = {} },
        { key = "MARKSMANSHIP", label = "Marksmanship",  role = "RANGED", tab = 2, icon = I .. "Ability_Marksmanship",       mod = { RAP = 0.6 } },
        { key = "SURVIVAL",     label = "Survival",      role = "RANGED", tab = 3, icon = I .. "Ability_Hunter_SwiftStrike", mod = { AGI = 1.4 } },
    },
    ROGUE = {
        { key = "ASSASSINATION", label = "Assassination", role = "MELEE", tab = 1, icon = I .. "Ability_Rogue_Eviscerate", mod = { STR = 0.5, AGI = 1.3 } },
        { key = "COMBAT",        label = "Combat",        role = "MELEE", tab = 2, icon = I .. "Ability_BackStab",         mod = { STR = 0.5, AGI = 1.3, HIT = 16, DPS = 3.5 } },
        { key = "SUBTLETY",      label = "Subtlety",      role = "MELEE", tab = 3, icon = I .. "Ability_Stealth",          mod = { STR = 0.5, AGI = 1.3 } },
    },
    PRIEST = {
        { key = "DISCIPLINE",  label = "Discipline",    role = "HEALER", tab = 1, icon = I .. "Spell_Holy_WordFortitude",   mod = { INT = 1.1, SPI = 0.5 } },
        { key = "HOLY",        label = "Holy",          role = "HEALER", tab = 2, icon = I .. "Spell_Holy_HolyBolt",        mod = { SPI = 0.8 } },
        { key = "SHADOW",      label = "Shadow",        role = "CASTER", tab = 3, icon = I .. "Spell_Shadow_ShadowWordPain", mod = { SPI = 0.4, SHIT = 14 } },
    },
    SHAMAN = {
        { key = "ELEMENTAL",   label = "Elemental",     role = "CASTER", tab = 1, icon = I .. "Spell_Nature_Lightning",       mod = {} },
        { key = "ENHANCEMENT", label = "Enhancement",   role = "MELEE",  tab = 2, icon = I .. "Spell_Nature_LightningShield", mod = { STR = 1.1, AGI = 0.8, INT = 0.2 } },
        { key = "RESTORATION", label = "Restoration",   role = "HEALER", tab = 3, icon = I .. "Spell_Nature_MagicImmunity",   mod = { MP5 = 2.5 } },
    },
    MAGE = {
        { key = "ARCANE",      label = "Arcane",        role = "CASTER", tab = 1, icon = I .. "Spell_Holy_MagicalSentry",   mod = { INT = 1.0, SPI = 0.4 } },
        { key = "FIRE",        label = "Fire",          role = "CASTER", tab = 2, icon = I .. "Spell_Fire_FireBolt02",      mod = { SCRIT = 12 } },
        { key = "FROST",       label = "Frost",         role = "CASTER", tab = 3, icon = I .. "Spell_Frost_FrostBolt02",    mod = { STA = 0.5 } },
    },
    WARLOCK = {
        { key = "AFFLICTION",  label = "Affliction",    role = "CASTER", tab = 1, icon = I .. "Spell_Shadow_DeathCoil",     mod = { STA = 0.6, SHIT = 14 } },
        { key = "DEMONOLOGY",  label = "Demonology",    role = "CASTER", tab = 2, icon = I .. "Spell_Shadow_Metamorphosis", mod = { STA = 0.7 } },
        { key = "DESTRUCTION", label = "Destruction",   role = "CASTER", tab = 3, icon = I .. "Spell_Shadow_RainOfFire",    mod = { STA = 0.6, SCRIT = 11 } },
    },
    DRUID = {
        { key = "BALANCE",     label = "Balance",       role = "CASTER", tab = 1, icon = I .. "Spell_Nature_StarFall",      mod = {} },
        { key = "FERAL_CAT",   label = "Feral (Cat)",   role = "MELEE",  tab = 2, icon = I .. "Ability_Druid_CatForm",      mod = { STR = 1.2, AGI = 1.0 } },
        { key = "FERAL_BEAR",  label = "Feral (Bear)",  role = "TANK",   tab = 2, icon = I .. "Ability_Racial_BearForm",    mod = { AGI = 0.8, STR = 0.4 } },
        { key = "RESTORATION", label = "Restoration",   role = "HEALER", tab = 3, icon = I .. "Spell_Nature_HealingTouch",  mod = { SPI = 0.8 } },
    },
}

ns.ROLE_LABELS = {
    MELEE = "Melee DPS", TANK = "Tank", RANGED = "Ranged DPS", CASTER = "Caster DPS", HEALER = "Healer",
}

-- Value of one point of each stat, per role. Percent stats (CRIT, HIT...) are per 1%.
-- Stat keys: STR AGI STA INT SPI ARMOR DPS AP RAP SP HEAL CRIT HIT SCRIT SHIT HASTE EXPERTISE DEF DODGE PARRY BLOCK MP5
ns.ROLE_WEIGHTS = {
    MELEE  = { STR = 1.0, AGI = 1.0, STA = 0.4, AP = 0.5, CRIT = 12, HIT = 14, DPS = 3.0, ARMOR = 0.01 },
    TANK   = { STA = 1.2, ARMOR = 0.06, AGI = 0.6, STR = 0.5, DEF = 1.5, DODGE = 12, PARRY = 10,
               BLOCK = 2, HIT = 6, DPS = 1.0 },
    RANGED = { AGI = 1.2, STA = 0.4, INT = 0.3, STR = 0.1, RAP = 0.5, AP = 0.5, CRIT = 12, HIT = 14,
               DPS = 3.0, ARMOR = 0.01 },
    CASTER = { INT = 0.8, SPI = 0.3, STA = 0.4, SP = 1.0, SCRIT = 10, SHIT = 12, MP5 = 1.0 },
    HEALER = { INT = 1.0, SPI = 0.6, STA = 0.3, HEAL = 0.6, SP = 0.3, SCRIT = 8, MP5 = 2.0 },
}
