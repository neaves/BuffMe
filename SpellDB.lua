-- BuffMe Official Spell Database
--
-- Baseline data shipped with the addon and shared by every character on the same realm.
-- This is the "known good" dataset, verified through live testing, that BuffMe_LoadOfficialDB
-- (spells.lua) merges into each character's learned DB (BuffMeCharDB) as defaults every
-- login, keyed by that character's current realm (GetRealmName()). Official data never
-- overwrites data a character has already learned/customized — it only fills gaps.
--
-- Keyed per realm, not shared globally: "Classic" and "Conquest of Azeroth" ruleset realms
-- run non-overlapping spell sets, and Wildcard realms (characters are class "HERO", spells
-- drawn at random per character) have no meaningful shared baseline at all — a Wildcard
-- hero's learned spellGroups are never promoted here (see the promotion workflow note
-- below and Tools/Export-BuffMeDB.ps1, which tags each export with classToken/realm so a
-- HERO-class export is never mistaken for promotable data). A realm absent from this table
-- just means every character on it relies on pure Learn Mode discovery.
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
-- Deliberately excluded: any effectGroup whose sig is "increases speed by #%." /
-- "increases ground speed by #%." (mounts — mounting up is mistakenly registered as a
-- castable "buff spell" since it fires UNIT_AURA like any other self-buff, and every
-- other party member's different mount then tooltip-matches into the same effect group),
-- or a degenerate near-empty sig like "# seconds remaining" (a tooltip-capture failure,
-- not real signature data). Not fixed yet — just excluded from promotion.
--
-- 2026-08-04 promotion: cross-referenced Tools/*.json exports from 8 characters (one from
-- a real 16-person raid) for effectGroups with members from multiple different classes and
-- spell groups matching the "increase"/"restore"/"reduce" candidate keywords (see
-- CANDIDATE_KEYWORDS in spells.lua). Effect groups were re-clustered from each entry's own
-- tooltip sig, but a typeGroup is allowed to (and often should) contain multiple different
-- sigs when the underlying buffs are genuinely mutually exclusive despite providing
-- different effects — e.g. the pre-existing "boonofthebear" stance family below (5 members,
-- 5 different sigs, confirmed self-only). The Primalist "Grove Instinct"/"Primal Instinct"
-- pair and the Necromancer "Bone Ward"/"Glacial Ward"/"Fetid Ward" trio are the same shape
-- (user-confirmed real single-slot exclusivity, also independently confirmed in one
-- character's diagnosticLog via a CLEU-observed same-instant buff replacement — see
-- BuffMe_MergeTypeGroups in spells.lua) and are kept as single typeGroups here rather than
-- split by sig. Don't re-split a typeGroup on sig-diversity alone; verify actual in-game
-- exclusivity first.

BuffMe_OfficialDB = {
  ["Rexxar - Conquest of Azeroth"] = {
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
        -- Earthen Endurance (Primalist) — client-facing spellIds observed for the same
        -- effect (rank/spec variance on Ascension's custom ID scheme), plus the raid-wide
        -- "Greater" group-cast variant confirmed 2026-08-03.
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
        [570755] = {
            name         = "Earthen Endurance",
            auraName     = "Earthen Endurance",
            priority     = 5,
            tooltipSig   = "increases armor by #, all attributes by # and all resistances by #.|# minutes remaining",
            tooltipValue = 30,
        },
        [570756] = {
            name         = "Greater Earthen Endurance",
            auraName     = "Greater Earthen Endurance",
            priority     = 5,
            groupCast    = true,
            tooltipSig   = "increases armor by #, all attributes by # and all resistances by #.|# minutes remaining",
            tooltipValue = 30,
        },

        -- Essence of Nature (Primalist) — confirmed party-member-only target restriction
        -- (see BuffMe_MarkPartyOnly / feedback-partyonly-noop-timeout), plus the "Greater"
        -- group-cast variant.
        [581314] = {
            name         = "Essence of Nature",
            auraName     = "Essence of Nature",
            priority     = 5,
            partyOnly    = true,
            tooltipSig   = "nature resistance increased by #.|# minutes remaining",
            tooltipValue = 10,
        },
        [581315] = {
            name         = "Essence of Nature",
            auraName     = "Essence of Nature",
            priority     = 5,
            partyOnly    = true,
            tooltipSig   = "nature resistance increased by #.|# minutes remaining",
            tooltipValue = 10,
        },
        [582261] = {
            name         = "Greater Essence of Nature",
            auraName     = "Greater Essence of Nature",
            priority     = 5,
            groupCast    = true,
            tooltipSig   = "nature resistance increased by #.|# minutes remaining",
            tooltipValue = 10,
        },

        -- Grove Instinct (Primalist) — CLEU-less spell, only ever observed via the
        -- UNIT_AURA fallback synthetic key. Mana regen; one mutually-exclusive slot shared
        -- with Primal Instinct (attack power) — see the "groveinstinct" typeGroup note above.
        ["__Grove Instinct"] = {
            name         = "Grove Instinct",
            auraName     = "Grove Instinct",
            priority     = 5,
            tooltipSig   = "restores # mana every # seconds.|# minutes remaining",
            tooltipValue = 30,
        },

        -- Primal Instinct (Primalist) — client-facing spellIds observed for the same
        -- effect, plus the "Greater" group-cast variant. Attack power; shares its exclusive
        -- slot with Grove Instinct — see note above.
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
        [680310] = {
            name         = "Greater Primal Instinct",
            auraName     = "Greater Primal Instinct",
            priority     = 5,
            groupCast    = true,
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
        [505217] = {
            name         = "Boon of the Lion",
            auraName     = "Boon of the Lion",
            priority     = 5,
            tooltipSig   = "increases your chance to resist fear, charm, and sleep effects by #%. dispeling # fear, charm, and sleep effect from party members within # yds every # sec.",
            tooltipValue = 44,
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
        -- earthenendurance (armor + all attributes + all resistances)
        earthenendurance          = "earthenendurance",
        beetlepheromones          = "earthenendurance",
        greaterearthenendurance   = "earthenendurance",
        footpadsadaptation        = "earthenendurance",
        greatermanariintuition    = "earthenendurance",
        knightsedict              = "earthenendurance",
        manariintuition           = "earthenendurance",
        markofthewild             = "earthenendurance",

        -- essenceofnature (nature resistance)
        essenceofnature           = "essenceofnature",
        greateressenceofnature    = "essenceofnature",
        shadrasboon               = "essenceofnature",
        runictattoosearth         = "essenceofnature",
        wildblessing              = "essenceofnature",

        -- groveinstinct — Primalist "Instinct" family, ONE mutually-exclusive slot despite
        -- covering two different effects (mana regen vs attack power); user-confirmed real
        -- exclusivity, matches the same shape as the boonofthebear stance family below.
        groveinstinct             = "groveinstinct",
        greatergroveinstinct      = "groveinstinct",
        devotionofgrace           = "groveinstinct",
        greaterdevotionofgrace    = "groveinstinct",
        whispersofyshaarj         = "groveinstinct",
        greaterwhispersofyshaarj  = "groveinstinct",
        blessingofwisdom          = "groveinstinct",
        primalinstinct            = "groveinstinct",
        greaterprimalinstinct     = "groveinstinct",
        devotionofdawn            = "groveinstinct",
        greaterdevotionofdawn     = "groveinstinct",
        powermodule               = "groveinstinct",
        greaterpowermodule        = "groveinstinct",
        aspectofthehawk           = "groveinstinct",
        bearform                  = "groveinstinct",
        catform                   = "groveinstinct",
        luckofthedraw             = "groveinstinct",
        primalweaponprimalmight   = "groveinstinct",

        -- boonofthebear (melee AP + melee haste + rage on auto-attack) — Primalist stance
        -- family plus many confirmed cross-class equivalents.
        boonofthebear             = "boonofthebear",
        boonoftheturtle           = "boonofthebear",
        boonofthehawk             = "boonofthebear",
        boonofthewolf             = "boonofthebear",
        boonofthelion             = "boonofthebear",
        dayhunter                 = "boonofthebear",
        veiledindarkness          = "boonofthebear",
        presenceofcthun           = "boonofthebear",
        rapidincantations         = "boonofthebear",
        ruinousfrenzy             = "boonofthebear",
        strengthofdaloa           = "boonofthebear",
        thebigguns                = "boonofthebear",
        vitalitysurge             = "boonofthebear",
        aircarving                = "boonofthebear",
        bloodcursedweapons        = "boonofthebear",
        bloodfury                 = "boonofthebear",
        instinct                  = "boonofthebear",
        killerspath               = "boonofthebear",
        overwhelmingpresence      = "boonofthebear",
        shieldcombatant           = "boonofthebear",
        skyandstone               = "boonofthebear",
        stratus                   = "boonofthebear",
        unitingvoice              = "boonofthebear",
        widowskiss                = "boonofthebear",

        -- heavyhanded (armor % increase)
        heavyhanded               = "heavyhanded",
        distilledflaskofthewarsong = "heavyhanded",
        dominion                  = "heavyhanded",
        faith                     = "heavyhanded",
        signofvitality            = "heavyhanded",

        -- elixirofthesages (intellect + spirit, guardian elixir)
        elixirofthesages          = "elixirofthesages",
        greatercelestialmind      = "elixirofthesages",
        wellfedfusedsteamedwontons = "elixirofthesages",

        -- guardianelixirarmor (armor only, guardian elixir) — kept separate from
        -- earthenendurance; different slot/effect despite both being "armor" buffs.
        greaterarmor              = "guardianelixirarmor",
        protectorshand            = "guardianelixirarmor",

        -- ancientofwar (crit strike %)
        ancientofwar              = "ancientofwar",
        vowofthevalkyr            = "ancientofwar",

        -- absorptionshield (flat damage absorb) — cross-class, 10 distinct providers
        -- confirmed in one character's data alone.
        blackshield               = "absorptionshield",
        ghastlyform               = "absorptionshield",
        infernobarrier            = "absorptionshield",
        lifeforpower              = "absorptionshield",
        phoenixshield             = "absorptionshield",
        shieldedbyflames          = "absorptionshield",
        soulfurnace               = "absorptionshield",
        teachingsofthekirintor    = "absorptionshield",
        voidshield                = "absorptionshield",
        volcanicshell             = "absorptionshield",

        -- boneward — Necromancer "Ward" family, ONE mutually-exclusive slot despite
        -- covering three different effects (armor%+stamina%, runic power%+intellect%,
        -- healing received%); user-confirmed real exclusivity, and independently confirmed
        -- in one character's diagnosticLog via a CLEU-observed same-instant replacement
        -- ("Buff replacement (CLEU): Fetid Ward -> Bone Ward -- merging typeGroups").
        -- Deliberately excludes plain single-attribute names ("stamina", "intellect",
        -- "strength", "agility", "spirit") — these are generic aura names granted by
        -- "Scroll of <Attribute> <Rank>" item procs, reused across many unrelated sources.
        -- A same-instant CLEU misattribution (2026-08-04, this same character) once wrote
        -- "stamina"/"intellect" here as if they shared the Ward's compound tooltip, which
        -- permanently masked real Ward recommendations any time a stat scroll was active.
        boneward                  = "boneward",
        powerwuju                 = "boneward",
        shieldbeacon              = "boneward",
        woodsmansadaptation       = "boneward",
        callofthestorm            = "boneward",
        celestialmind             = "boneward",
        glacialward               = "boneward",
        nozdormuswisdom           = "boneward",
        sealofalysrazor           = "boneward",
        corpsewagon               = "boneward",
        cyberneticrevivification  = "boneward",
        fetidward                 = "boneward",
        purelight                 = "boneward",

        -- spiritboost (flat spirit)
        chromieswisdom            = "spiritboost",
        spirit                    = "spiritboost",
        spiritwuju                = "spiritboost",
        temporalrestoration       = "spiritboost",

        -- staminaboost (flat stamina)
        foulmandate               = "staminaboost",
        frostpresence             = "staminaboost",
        greatersanguinaryoffering = "staminaboost",
        markofrivendare           = "staminaboost",
        powerwordfortitude        = "staminaboost",
        riteofresolve             = "staminaboost",
        sanguinaryoffering        = "staminaboost",

        -- agilityboost (flat agility)
        agility                   = "agilityboost",
        brutalshout               = "agilityboost",
        etchingofthedextrous      = "agilityboost",
        giftofzeal                = "agilityboost",
        inquisitorsedict          = "agilityboost",
        lesseragility             = "agilityboost",
        nighthunter               = "agilityboost",

        -- chillofthetomb (frost resistance)
        chillofthetomb            = "chillofthetomb",
        frostarmor                = "chillofthetomb",
        frostward                 = "chillofthetomb",

        -- armorboost (flat armor, non-guardian-elixir)
        armor                     = "armorboost",
        beetleform                = "armorboost",
        stonebody                 = "armorboost",

        -- blackblood (periodic healing)
        blackblood                = "blackblood",
        acceleratedrecovery       = "blackblood",
        darkmatter                = "blackblood",
        dawnfall                  = "blackblood",
        overcorrection            = "blackblood",
        standardofrecovery        = "blackblood",
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
                earthenendurance        = { name = "Earthen Endurance", value = 30 },
                beetlepheromones        = { name = "Beetle Pheromones", value = 150 },
                greaterearthenendurance = { name = "Greater Earthen Endurance", value = 30 },
                footpadsadaptation      = { name = "Footpad's Adaptation", value = 105 },
                greatermanariintuition  = { name = "Greater Man'ari Intuition", value = 0 },
                knightsedict            = { name = "Knight's Edict", value = 234 },
                manariintuition         = { name = "Man'ari Intuition", value = 103 },
                markofthewild           = { name = "Mark of the Wild", value = 29 },
            },
        },
        ["nature resistance increased by #.|# minutes remaining"] = {
            typeGroup = "essenceofnature",
            members = {
                essenceofnature      = { name = "Essence of Nature", value = 10 },
                greateressenceofnature = { name = "Greater Essence of Nature", value = 10 },
                shadrasboon          = { name = "Shadra's Boon", value = 50 },
                runictattoosearth    = { name = "Runic Tattoos: Earth", value = 75 },
                wildblessing         = { name = "Wild Blessing", value = 50 },
            },
        },
        ["restores # mana every # seconds.|# minutes remaining"] = {
            typeGroup = "groveinstinct",
            members = {
                groveinstinct            = { name = "Grove Instinct", value = 30 },
                greatergroveinstinct     = { name = "Greater Grove Instinct", value = 36 },
                devotionofgrace          = { name = "Devotion of Grace", value = 10 },
                greaterdevotionofgrace   = { name = "Greater Devotion of Grace", value = 39 },
                whispersofyshaarj        = { name = "Whispers of Y'shaarj", value = 10 },
                greaterwhispersofyshaarj = { name = "Greater Whispers of Y'shaarj", value = 41 },
                blessingofwisdom         = { name = "Blessing of Wisdom", value = 18 },
            },
        },
        ["restores # mana every # seconds. resource costs reduced by #%.|# minutes remaining"] = {
            typeGroup = "groveinstinct",
            members = {
                devotionofgrace   = { name = "Devotion of Grace", value = 30 },
                whispersofyshaarj = { name = "Whispers of Y'shaarj", value = 30 },
            },
        },
        ["increases attack power by #.|# minutes remaining"] = {
            typeGroup = "groveinstinct",
            members = {
                primalinstinct          = { name = "Primal Instinct", value = 30 },
                greaterprimalinstinct   = { name = "Greater Primal Instinct", value = 30 },
                devotionofdawn          = { name = "Devotion of Dawn", value = 30 },
                greaterdevotionofdawn   = { name = "Greater Devotion of Dawn", value = 278 },
                powermodule             = { name = "Power Module", value = 19 },
                greaterpowermodule      = { name = "Greater Power Module", value = 278 },
                aspectofthehawk         = { name = "Aspect of the Hawk", value = 11 },
                bearform                = { name = "Bear Form", value = 65 },
                catform                 = { name = "Cat Form", value = 25 },
                luckofthedraw           = { name = "Luck of the Draw", value = 315 },
                primalweaponprimalmight = { name = "Primal Weapon: Primal Might", value = 25 },
            },
        },
        ["melee attack power and melee haste increased. rage generated from auto attacks increased by #%."] = {
            typeGroup = "boonofthebear",
            members = {
                boonofthebear        = { name = "Boon of the Bear", value = 0 },
                dayhunter            = { name = "Day Hunter", value = 3 },
                veiledindarkness     = { name = "Veiled in Darkness", value = 5 },
                presenceofcthun      = { name = "Presence of C'Thun", value = 20 },
                rapidincantations    = { name = "Rapid Incantations", value = 5 },
                ruinousfrenzy        = { name = "Ruinous Frenzy", value = 15 },
                strengthofdaloa      = { name = "Strength of Da Loa", value = 0 },
                thebigguns           = { name = "The BIG Guns!", value = 5 },
                vitalitysurge        = { name = "Vitality Surge", value = 18 },
                aircarving           = { name = "Air Carving", value = 12 },
                bloodcursedweapons   = { name = "Blood-Cursed Weapons", value = 14 },
                bloodfury            = { name = "Blood Fury", value = 62 },
                instinct             = { name = "Instinct", value = 40 },
                killerspath          = { name = "Killer's Path", value = 5 },
                overwhelmingpresence = { name = "Overwhelming Presence", value = 5 },
                shieldcombatant      = { name = "Shield Combatant", value = 4 },
                skyandstone          = { name = "Sky and Stone", value = 10 },
                stratus              = { name = "Stratus", value = 5 },
                unitingvoice         = { name = "Uniting Voice", value = 16 },
                widowskiss           = { name = "Widow's Kiss", value = 0 },
            },
        },
        ["armor increased by #%.|# seconds remaining"] = {
            typeGroup = "heavyhanded",
            members = {
                heavyhanded                = { name = "Heavy Handed", value = 10 },
                distilledflaskofthewarsong = { name = "Distilled Flask of the Warsong", value = 20 },
                dominion                   = { name = "Dominion", value = 585 },
                faith                      = { name = "Faith", value = 10 },
                signofvitality             = { name = "Sign of Vitality", value = 1350 },
            },
        },
        ["intellect and spirit increased by #. guardian elixir.|# hour remaining"] = {
            typeGroup = "elixirofthesages",
            members = {
                elixirofthesages          = { name = "Elixir of the Sages", value = 18 },
                greatercelestialmind      = { name = "Greater Celestial Mind", value = 0 },
                wellfedfusedsteamedwontons = { name = "Well Fed - Fused Steamed Wontons", value = 25 },
            },
        },
        ["armor increased by #. guardian elixir.|# hour remaining"] = {
            typeGroup = "guardianelixirarmor",
            members = {
                greaterarmor   = { name = "Greater Armor", value = 450 },
                protectorshand = { name = "Protector's Hand", value = 1140 },
            },
        },
        ["chance to critically strike increased by #%.|# seconds remaining"] = {
            typeGroup = "ancientofwar",
            members = {
                ancientofwar   = { name = "Ancient of War", value = 20 },
                vowofthevalkyr = { name = "Vow of the Valkyr", value = 20 },
            },
        },
        ["absorbs # damage.|# seconds remaining"] = {
            typeGroup = "absorptionshield",
            members = {
                blackshield            = { name = "Black Shield", value = 1635 },
                ghastlyform            = { name = "Ghastly Form", value = 168 },
                infernobarrier         = { name = "Inferno Barrier", value = 29 },
                lifeforpower           = { name = "Life For Power", value = 9 },
                phoenixshield          = { name = "Phoenix Shield", value = 705 },
                shieldedbyflames       = { name = "Shielded by Flames", value = 104 },
                soulfurnace            = { name = "Soul Furnace", value = 824 },
                teachingsofthekirintor = { name = "Teachings of the Kirin Tor", value = 30 },
                voidshield             = { name = "Void Shield", value = 256 },
                volcanicshell          = { name = "Volcanic Shell", value = 1800 },
            },
        },
        ["armor is increased by #% and stamina by #% and melee and ranged damage taken reduces the target's attack power.|# minutes remaining"] = {
            typeGroup = "boneward",
            members = {
                boneward            = { name = "Bone Ward", value = 30 },
                powerwuju           = { name = "Power Wuju", value = 55 },
                shieldbeacon        = { name = "Shield Beacon", value = 370 },
                woodsmansadaptation = { name = "Woodsman's Adaptation", value = 30 },
            },
        },
        ["maximum runic power and intellect increased by #%. duration of stun effects is reduced by #%.|# minutes remaining"] = {
            typeGroup = "boneward",
            members = {
                callofthestorm  = { name = "Call of the Storm", value = 0 },
                celestialmind   = { name = "Celestial Mind", value = 25 },
                glacialward     = { name = "Glacial Ward", value = 30 },
                nozdormuswisdom = { name = "Nozdormu's Wisdom", value = 0 },
                sealofalysrazor = { name = "Seal of Alysrazor", value = 15 },
            },
        },
        ["healing received is increased by #% and #% of your damage dealt heals you and your minions, split evenly amongst them.|# minutes remaining"] = {
            typeGroup = "boneward",
            members = {
                corpsewagon              = { name = "Corpse Wagon", value = 3 },
                cyberneticrevivification = { name = "Cybernetic Revivification", value = 0 },
                fetidward                = { name = "Fetid Ward", value = 30 },
                purelight                = { name = "Pure Light", value = 10 },
            },
        },
        ["spirit increased by #.|# minutes remaining"] = {
            typeGroup = "spiritboost",
            members = {
                spirit               = { name = "Spirit", value = 30 },
                chromieswisdom       = { name = "Chromie's Wisdom", value = 0 },
                spiritwuju           = { name = "Spirit Wuju", value = 0 },
                temporalrestoration  = { name = "Temporal Restoration", value = 25 },
            },
        },
        ["increases stamina by #.|# minutes remaining"] = {
            typeGroup = "staminaboost",
            members = {
                foulmandate               = { name = "Foul Mandate", value = 30 },
                frostpresence             = { name = "Frost Presence", value = 60 },
                greatersanguinaryoffering = { name = "Greater Sanguinary Offering", value = 64 },
                markofrivendare           = { name = "Mark of Rivendare", value = 0 },
                powerwordfortitude        = { name = "Power Word: Fortitude", value = 30 },
                riteofresolve             = { name = "Rite of Resolve", value = 32 },
                sanguinaryoffering        = { name = "Sanguinary Offering", value = 38 },
            },
        },
        ["agility increased by #.|# minutes remaining"] = {
            typeGroup = "agilityboost",
            members = {
                agility              = { name = "Agility", value = 51 },
                brutalshout          = { name = "Brutal Shout", value = 8 },
                etchingofthedextrous = { name = "Etching of the Dextrous", value = 43 },
                giftofzeal           = { name = "Gift of Zeal", value = 30 },
                inquisitorsedict     = { name = "Inquisitor's Edict", value = 24 },
                lesseragility        = { name = "Lesser Agility", value = 14 },
                nighthunter          = { name = "Night Hunter", value = 0 },
            },
        },
        ["frost resistance increased by #.|# minutes remaining"] = {
            typeGroup = "chillofthetomb",
            members = {
                chillofthetomb = { name = "Chill of the Tomb", value = 30 },
                frostarmor     = { name = "Frost Armor", value = 27 },
                frostward      = { name = "Frost Ward", value = 30 },
            },
        },
        ["armor increased by #.|# minutes remaining"] = {
            typeGroup = "armorboost",
            members = {
                armor      = { name = "Armor", value = 65 },
                beetleform = { name = "Beetle Form", value = 500 },
                stonebody  = { name = "Stone Body", value = 193 },
            },
        },
        ["healing every # sec.|# seconds remaining"] = {
            typeGroup = "blackblood",
            members = {
                blackblood          = { name = "Black Blood", value = 14 },
                acceleratedrecovery = { name = "Accelerated Recovery", value = 57 },
                darkmatter          = { name = "Dark Matter", value = 186 },
                dawnfall            = { name = "Dawnfall", value = 15 },
                overcorrection      = { name = "Overcorrection", value = 38 },
                standardofrecovery  = { name = "Standard of Recovery", value = 21 },
            },
        },
    },
  },
}
