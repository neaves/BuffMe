# Buff Me — Addon Plan

## Objectives

Smart party/raid buff manager for **Project Ascension** (WotLK 3.3.5a), a private server with
fully custom class compositions. Because any character can have any ability, no hardcoded spell
list is possible. All spells and their exclusivity relationships are **learned at runtime** and
persisted in SavedVariables.

- One-click button: cast the next missing buff for any party member
- Badge on button: count of missing buff slots across the party
- Right-click panel: per-member buff status at a glance
- Combat lock: button disabled while in combat (`PLAYER_REGEN_DISABLED/ENABLED`)
- Three exclusivity dimensions learned dynamically:
  - **typeGroup** — what effect a buff provides (cross-class; prevents overwriting an equivalent)
  - **targetGroup** — which of the player's spells are mutually exclusive on a single target
  - **playerGroup** — which of the player's spells are mutually exclusive on the caster
- Drag-to-reposition button with lock/unlock; native Interface > AddOns config panel
- Diagnostic mode: chat output + persistent log written to SavedVariables on `/reload`
- Passive raid-wide diagnostics: unknown-buff keyword flagging, "displaces a known buff" pair
  detection, held for user review rather than auto-applied (see Candidate Merges below)

## Files
```
BuffMe/
├── BuffMe.toc
├── BuffMe.lua       — event dispatch, cast queue, proc guard, diagnostic log, raid-wide
│                       buff-diff/displacement detection
├── spells.lua        — DB schema, RegisterSpell, typeGroup/targetGroup/playerGroup ops,
│                        tooltip-sig matching, candidate-pair accept/reject
├── optimizer.lua      — ScanPartyAuras, GetNextCast, group-cast-aware spell selection
├── ui.lua              — container + title bar + button + panel + drag/hover
└── config.lua          — native Interface > AddOns panels: main, Spell Groups (rename UI),
                           Ignored Spells, Candidate Merges, Effect Groups, Diagnostics
```

## SavedVariables (`BuffMeDB`, account-wide; per-character data nested under `BuffMeDB.chars[name]`)
```
Account-wide:
  typeGroupDisplayNames [tg]    → user-chosen display name (Spell Groups panel rename; overlay only)

Per character (BuffMeDB.chars[charName], aliased to BuffMeCharDB):
  spells               [key]   → { spellId, name, auraName, priority, groupCast?, selfOnly?,
                                    partyOnly?, ineligible?, tooltipSig, tooltipValue }
  nameToKey            [name]  → key  (reverse index for O(1) "already known" checks)
  auraToTypeGroup      [norm]  → typeGroup string
  typeGroupMembers     [tg]    → { norm, ... }
  globalTypeGroups     [tg]    → true  (server allows only one live instance anywhere, e.g. "Bless")
  effectGroups         [sig]   → { typeGroup, members = { [norm] = { name, value } } }
  auraDisplayNames     [norm]  → original display name
  spellToTargetGroup / targetGroupMembers, spellToPlayerGroup / playerGroupMembers — as typeGroup
  lastCastForGroup     [tg][targetName] → spellKey  (per-target cast preference)
  candidatePairs       []      → { key, nameA, nameB, unit, firstSeen, lastSeen, seenCount }
                                  — passively-detected "these displace each other" pairs, held
                                  for review (Candidate Merges panel), not auto-merged
  rejectedPairs        [key]   → true  (user-dismissed candidate pairs, never re-suggested)
  diagnosticMode       bool
  diagnosticLog        []      — timestamped strings; capped at 500; written on /reload
```

## Confirmed BuffMe-specific findings

(General WotLK/Ascension API gotchas — CLEU format, UNIT_AURA-before-CLEU ordering,
`SecureActionButtonTemplate` rules, etc. — live in the shared `wow-addon-dev` skill, not here.)

- **Spell name ≠ aura name.** Use buff-diff (gained list) to detect the aura a cast actually
  produced, never a name-match against the spell name.
- **Proc guard**: gate new-spell registration on `UNIT_SPELLCAST_SUCCEEDED` having fired for that
  spell name in the same frame (`recentlyCastName`) — CLEU `SPELL_AURA_APPLIED` alone fires for
  passive procs too.
- **Synthetic keys** (`"__SpellName"`) are used when no numeric spell ID is available (Ascension's
  custom spell IDs often don't surface via `UNIT_SPELLCAST_SUCCEEDED`).
- **"greater"/"lesser" are not meaningful keywords** for the keyword-overlap matcher
  (`NAME_STOPWORDS` in `spells.lua`) — confirmed via a real 16-person raid (2026-08-03) that
  treating "greater" as meaningful caused unrelated "Greater X" spells sharing nothing else to
  get pre-grouped or merged together (e.g. "Greater Whispers of N'zoth" into the nature-resistance
  typeGroup via "Greater Essence of Nature" alone). Fixed in `NAME_STOPWORDS`; a one-time repair
  migration (`BuffMeCharDB.greaterKeywordRepairV1`) re-derives every known spell's typeGroup from
  its own captured tooltip sig (authoritative) to fix data already corrupted before the fix.
- **A CLEU-less pendingCast can mis-attribute an unrelated concurrent external buff.** If the
  player casts a CLEU-less spell (e.g. "Greater Grove Instinct") in the same `UNIT_AURA` diff
  window as an unrelated external buff change landing on them (someone else's buff applying or
  refreshing), the "sole new buff in the diff" heuristic can register the external buff's name as
  the player's own spell's aura. No general fix applied (rare, self-correcting on a clean re-cast)
  — just something to check for when a synthetic `__SpellName` entry's `auraName` looks suspicious.
- **Raid-wide coverage requires `raid1..N` tokens, not just `party1-4`.** WotLK has no `partyN`
  tokens once grouped as a raid. `BuffMe_GetTrackedUnits()` (spells.lua) returns the right set for
  the current group state; `UNIT_AURA`'s unit filter and `GUIDToUnit` (BuffMe.lua) both use it.
  `RAID_ROSTER_UPDATE` must be registered alongside `PARTY_MEMBERS_CHANGED`.
- **Group-cast ("Greater X") detection needs a multi-second accumulation window, not one frame.**
  Confirmed via the same raid: a single raid-wide splash cast's CLEU `SPELL_AURA_APPLIED` events
  for ~15 recipients spread across ~1-2 real seconds, not one frame. The original per-frame wipe
  of `pendingGroupCastGUIDs` cleared the accumulator between almost every event, so `groupCast`
  never got confirmed at raid scale despite visibly working in-game. Fixed with a `GROUP_CAST_WINDOW
  = 3` second time-based expiry (`BuffMe.lua`) instead of an unconditional per-frame wipe.
  Also: `AccumulateGroupCast` must NOT require the triggering cast to have been self-targeted — the
  first cast of a not-yet-known group-cast spell gets aimed at whoever has the gap, not "player".
- **`SelectSpellForGroup` (optimizer.lua) must prefer a confirmed `groupCast` sibling over a
  per-target "last cast" preference**, not just over the plain priority fallback — otherwise a
  recorded preference for the single-target version can pin the optimizer to it indefinitely even
  after the group-cast version becomes known.

## Open items

- **Priority system**: all spells still default `priority = 5`; no way to express one typeGroup
  mattering more than another beyond the groupCast preference above.
- **playerGroup learning**: still never confirmed triggered in testing; needs two spells that
  conflict with each other on the caster's own buff bar.
- **Rank/ID variance**: some spells register under multiple numeric IDs for the same effect
  (correctly treated as equivalent providers via shared typeGroup) — fine as-is, no action needed.
- **DB pruning**: `BuffMeCharDB.spells` never prunes entries for spells no longer in the player's
  book (spec/talent changes). Low priority — `GetKnownBuffSpells` already filters them from
  candidate selection at read time.
