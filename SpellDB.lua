-- BuffMe Official Spell Database
--
-- Baseline, class-agnostic data shipped with the addon and shared by every character on
-- every account. This is the "known good" dataset, verified through live testing, that
-- BuffMe_InitDB (spells.lua) merges into each character's learned DB (BuffMeCharDB) as
-- defaults every login. Official data never overwrites data a character has already
-- learned/customized — it only fills gaps.
--
-- "Learn Mode" (config: Learn new spells/relationships) is ON by default, since this file
-- is still sparse. With Learn Mode off, BuffMe stops auto-registering NEW spells/typeGroups/
-- effectGroups beyond what's listed here (see BuffMe_RegisterSpell, BuffMe_MergeTypeGroups,
-- and the "create new group" branch of BuffMe_RegisterInEffectGroup in spells.lua) — so a
-- database reset (BuffMe_ResetSpellDB) no longer loses ground truth, only in-progress
-- discovery. Behavioral safety flags (selfOnly/partyOnly/ineligible) and per-target cast
-- preferences are never gated by Learn Mode; they keep correcting live regardless.
--
-- Promotion workflow: run Tools/Export-BuffMeDB.ps1 -CharacterName <Name> to dump a
-- character's learned data to JSON, inspect it, then hand-copy verified entries here.
-- Promotion bar: only promote typeGroups/effectGroups with 2+ members (a relationship
-- confirmed by cross-validation, not a single spell's own unconfirmed self-registration).
--
-- Deliberately excluded: the "battletestedcresthorn" typeGroup / "increases ground speed
-- by #%." effect group. Mounting up is mistakenly registered as a castable "buff spell"
-- (fires UNIT_AURA like any other self-buff), and every other party member's different
-- mount then tooltip-matches into the same effect group. Not fixed yet — just excluded
-- from promotion for now (2026-07-12).

BuffMe_OfficialDB = {
    -- Player-castable spells this character can learn to buff with.
    -- [spellId] = {
    --     name       = "Spell Name",       -- as cast (matches UNIT_SPELLCAST_SENT/SUCCEEDED)
    --     auraName   = "Buff Name",        -- as it appears in UnitBuff (usually == name)
    --     priority   = 5,                  -- optional, defaults to 5; higher wins within a typeGroup
    --     tooltipSig = "...",              -- optional pre-seeded aura tooltip signature (digits→#)
    --     tooltipValue = 30,               -- optional pre-seeded primary numeric value
    --     selfOnly   = true,                -- optional: buff always applies to caster regardless of target
    --     partyOnly  = true,                -- optional: server rejects non-party targets (see BuffMe_MarkPartyOnly)
    --     ineligible = true,                -- optional: never auto-suggest (e.g. requires a hostile target)
    -- }
    spells = {
        -- Earthen Endurance (Primalist) — two client-facing spellIds observed for the same
        -- effect (rank/spec variance on Ascension's custom ID scheme).
        [570752] = {
            name         = "Earthen Endurance",
            auraName     = "Earthen Endurance",
            priority     = 5,
            tooltipSig   = "increases armor by #, all attributes by # and all resistances by #.|# minutes remaining",
            tooltipValue = 30,
        },
        [570753] = {
            name         = "Earthen Endurance",
            auraName     = "Earthen Endurance",
            priority     = 5,
            tooltipSig   = "increases armor by #, all attributes by # and all resistances by #.|# minutes remaining",
            tooltipValue = 30,
        },

        -- Essence of Nature (Primalist) — confirmed party-member-only target restriction
        -- (see BuffMe_MarkPartyOnly / feedback-partyonly-noop-timeout).
        [581314] = {
            name         = "Essence of Nature",
            auraName     = "Essence of Nature",
            priority     = 5,
            partyOnly    = true,
            tooltipSig   = "nature resistance increased by #.|# minutes remaining",
            tooltipValue = 10,
        },

        -- Grove Instinct (Primalist) — CLEU-less spell, only ever observed via the
        -- UNIT_AURA fallback synthetic key.
        ["__Grove Instinct"] = {
            name         = "Grove Instinct",
            auraName     = "Grove Instinct",
            priority     = 5,
            tooltipSig   = "restores # mana every # seconds.|# minutes remaining",
            tooltipValue = 30,
        },

        -- Primal Instinct (Primalist) — four client-facing spellIds observed for the same
        -- effect (rank/spec variance on Ascension's custom ID scheme).
        [800197] = {
            name         = "Primal Instinct",
            auraName     = "Primal Instinct",
            priority     = 5,
            tooltipSig   = "increases attack power by #.|# minutes remaining",
            tooltipValue = 30,
        },
        [803315] = {
            name         = "Primal Instinct",
            auraName     = "Primal Instinct",
            priority     = 5,
            tooltipSig   = "increases attack power by #.|# minutes remaining",
            tooltipValue = 30,
        },
        [803316] = {
            name         = "Primal Instinct",
            auraName     = "Primal Instinct",
            priority     = 5,
            tooltipSig   = "increases attack power by #.|# minutes remaining",
            tooltipValue = 30,
        },
        [803317] = {
            name         = "Primal Instinct",
            auraName     = "Primal Instinct",
            priority     = 5,
            tooltipSig   = "increases attack power by #.|# minutes remaining",
            tooltipValue = 30,
        },

        -- Boon of the X (Primalist stance family) — all five confirmed self-only; the
        -- server always applies these to the caster regardless of cast target.
        [500935] = {
            name         = "Boon of the Turtle",
            auraName     = "Boon of the Turtle",
            priority     = 5,
            selfOnly     = true,
            tooltipSig   = "reduces your damage taken by -#%. melee attackers will suffer nature damage when striking you.",
            tooltipValue = 0,
        },
        [500939] = {
            name         = "Boon of the Bear",
            auraName     = "Boon of the Bear",
            priority     = 5,
            selfOnly     = true,
            tooltipSig   = "melee attack power and melee haste increased. rage generated from auto attacks increased by #%.",
            tooltipValue = 0,
        },
        [500943] = {
            name         = "Boon of the Hawk",
            auraName     = "Boon of the Hawk",
            priority     = 5,
            selfOnly     = true,
            tooltipSig   = "increase your spell haste, reduces the cost of spells and abilities, and causes you to regenerate maximum health every # sec.",
            tooltipValue = 5,
        },
        [504856] = {
            name         = "Boon of the Lion",
            auraName     = "Boon of the Lion",
            priority     = 5,
            selfOnly     = true,
            tooltipSig   = "increases your chance to resist fear, charm, and sleep effects by #%. dispeling # fear, charm, and sleep effect from party members within # yds every # sec.",
            tooltipValue = 30,
        },
        [800137] = {
            name         = "Boon of the Wolf",
            auraName     = "Boon of the Wolf",
            priority     = 5,
            selfOnly     = true,
            tooltipSig   = "dodge chance increased. movement speed increased.",
            tooltipValue = 0,
        },
    },

    -- [normalizedAuraName] = typeGroup
    -- normalizedAuraName is BuffMe_NormalizeName(auraName): lowercase, letters/digits only.
    -- Includes external (non-castable) auras confirmed via effect-group tooltip matching,
    -- not just our own spells — e.g. "beetlepheromones" is some other class's buff.
    auraToTypeGroup = {
        earthenendurance   = "earthenendurance",
        beetlepheromones   = "earthenendurance",

        essenceofnature    = "essenceofnature",
        shadrasboon        = "essenceofnature",

        groveinstinct      = "groveinstinct",
        primalinstinct     = "groveinstinct",
        whispersofyshaarj  = "groveinstinct",
        devotionofgrace    = "groveinstinct",

        boonofthebear      = "boonofthebear",
        boonoftheturtle    = "boonofthebear",
        boonofthehawk      = "boonofthebear",
        boonofthewolf      = "boonofthebear",
        boonofthelion      = "boonofthebear",
        dayhunter          = "boonofthebear",
        veiledindarkness   = "boonofthebear",
    },

    -- Tooltip-signature-keyed effect groups, used by the optimizer to recognize when an
    -- external (non-player-cast) buff already provides one of our known effects.
    -- [tooltipSig] = {
    --     typeGroup = "typegroupname",
    --     members = { [normalizedAuraName] = { name = "Display Name", value = 30 }, ... }
    -- }
    effectGroups = {
        ["increases armor by #, all attributes by # and all resistances by #.|# minutes remaining"] = {
            typeGroup = "earthenendurance",
            members = {
                earthenendurance = { name = "Earthen Endurance", value = 30 },
                beetlepheromones = { name = "Beetle Pheromones", value = 150 },
            },
        },
        ["nature resistance increased by #.|# minutes remaining"] = {
            typeGroup = "essenceofnature",
            members = {
                essenceofnature = { name = "Essence of Nature", value = 10 },
                shadrasboon     = { name = "Shadra's Boon",     value = 50 },
            },
        },
        ["restores # mana every # seconds.|# minutes remaining"] = {
            typeGroup = "groveinstinct",
            members = {
                groveinstinct     = { name = "Grove Instinct",       value = 30 },
                whispersofyshaarj = { name = "Whispers of Y'shaarj", value = 10 },
                devotionofgrace   = { name = "Devotion of Grace",    value = 10 },
            },
        },
        ["melee attack power and melee haste increased. rage generated from auto attacks increased by #%."] = {
            typeGroup = "boonofthebear",
            members = {
                boonofthebear    = { name = "Boon of the Bear",    value = 0 },
                dayhunter        = { name = "Day Hunter",          value = 3 },
                veiledindarkness = { name = "Veiled in Darkness",  value = 5 },
            },
        },
    },
}
