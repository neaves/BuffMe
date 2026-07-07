# Buff Me — Addon Plan

## Original Objectives

Smart party buff manager for **Project Ascension** (WotLK 3.3.5a), a private server with fully
custom class compositions. Because any character can have any ability, no hardcoded spell list is
possible. All spells and their exclusivity relationships must be **learned at runtime** and
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

---

## Current Implementation State

All five files are complete and deployed. Core loop works: spells are learned, the optimizer
selects the next cast, and the button executes it.

### Files
```
BuffMe/
├── BuffMe.toc
├── BuffMe.lua       — event dispatch, cast queue, proc guard, diagnostic log
├── spells.lua       — DB schema, RegisterSpell, typeGroup/targetGroup/playerGroup ops
├── optimizer.lua    — ScanPartyAuras, GetNextCast, CountMissingBuffs
├── ui.lua           — container + title bar + button + panel + drag/hover
└── config.lua       — native Interface > AddOns panel (anchor, diagnostics, reset DB)
```

### SavedVariables (`BuffMeDB`)
```
spells               [key]   → { spellId, name, auraName, priority }
nameToKey            [name]  → key  (reverse index for O(1) "already known" checks)
auraToTypeGroup      [norm]  → typeGroup string
typeGroupMembers     [tg]    → { norm, ... }
spellToTargetGroup   [key]   → targetGroup string
targetGroupMembers   [tg]    → { key, ... }
spellToPlayerGroup   [key]   → playerGroup string
playerGroupMembers   [pg]    → { key, ... }
anchorLocked         bool
diagnosticMode       bool
diagnosticLog        []      — timestamped strings; capped at 500; written on /reload
```

---

## Lessons Learned This Session

### WotLK / Project Ascension API behaviour
- `UNIT_SPELLCAST_SUCCEEDED` does not always carry `spellId`; value depends on server implementation
- `UnitBuff` in WotLK returns 9 values — **no spellId** (unlike modern WoW)
- `GetSpellInfo` in WotLK does **not** return a spellId as a return value (unlike modern WoW)
- `GetSpellBookItemInfo(i, BOOKTYPE_SPELL)` → `(type, id)` is the reliable spellbook ID source
- Some Ascension custom spells emit **zero CLEU events** for both application and removal
  (confirmed: Grove Instinct). UNIT_AURA still fires; UNIT_SPELLCAST_SUCCEEDED still fires.
- CLEU `SPELL_AURA_REMOVED` fires **before** `SPELL_AURA_APPLIED` within the same server tick —
  this ordering is reliable for detecting mutually exclusive buff swaps
- `SPELL_AURA_REFRESH` is a valid cast outcome (buff already active, timer reset) — must clear
  `pendingCast` to suppress false "no new buff appeared" warnings
- Some Ascension custom spell names are borrowed from other Warcraft IP games (e.g. "Vitality
  Surge") — not a code issue; a data registration issue

### Registration correctness
- **Spell name ≠ aura name** is valid in WoW. Use buff-diff (gained list) to detect the aura,
  not a name-match against the spell name
- **Proc guard**: CLEU `SPELL_AURA_APPLIED` fires for passive procs with `playerGUID` as source.
  `UNIT_SPELLCAST_SUCCEEDED` does NOT fire for procs. Gate new-spell registration on whether
  `UNIT_SPELLCAST_SUCCEEDED` fired for that spell name in the same frame (`recentlyCastName`)
- **Synthetic keys**: when no numeric spell ID is available, register under `"__SpellName"`.
  `GetKnownBuffSpells` checks availability with `GetSpellInfo(entry.name)` for these entries
- **nameToKey reverse index**: needed to detect "already registered" for spells known under a
  numeric key when UNIT_SPELLCAST_SUCCEEDED provides no ID
- `CAST_AURA_EVENTS` lookup table must be **module-level**, not allocated per-event inside the
  high-frequency CLEU handler

### Casting / UI security
- `CastSpellByName` is restricted on Ascension's emulator even out of combat ("blocked from an
  action only available to the Blizzard UI"). Use `SecureActionButtonTemplate` with
  `type/spell/unit` attributes set in `PreClick` — this is the macro-equivalent path and
  bypasses the restriction entirely.
- `SetScript("OnMouseDown/Up", ...)` on a `SecureActionButtonTemplate` taints the frame and
  breaks its secure handler. Use `HookScript` instead.
- `SetScript("PreClick", ...)` and `SetScript("PostClick", ...)` ARE safe to call on a
  `SecureActionButtonTemplate` from addon code — they are the designed extension points.
- For right-click on a `SecureActionButtonTemplate`: set `type = ""` in `PreClick` (suppresses
  the secure action), then handle the panel in `PostClick`.

### Event ordering on Ascension
- UNIT_AURA fires **before** CLEU on this emulator — the opposite of retail WoW. This means:
  - SPELL_AURA_REFRESH clearing `pendingCast = nil` in the CLEU handler is too late; UNIT_AURA
    has already run and seen the non-nil `pendingCast` → false "No new buff appeared" warning
  - Fix: in the UNIT_AURA miss branch, scan `BuffMeDB.spells` directly to check if the spell
    is already registered before logging the warning
  - `recentlyCastName` (proc guard) may also be affected: if UNIT_AURA fires before CLEU,
    `recentlyCastName` might already have been cleared by OnUpdate before CLEU AURA_APPLIED
    runs → procs could slip through. Watch for this in testing.

### Diagnostic infrastructure
- SavedVariables are written to disk on `/reload` or logout — usable as a persistent log
- File path: `D:\games\Ascension Launcher\resources\client\WTF\Account\TODDIMER@GMAIL.COM\SavedVariables\BuffMe.lua`
- Read this file after a test session to review `BuffMeDB.diagnosticLog` without copy-paste

---

## Outstanding Implementation Goals

### 1. Validate new typeGroup learning (next test session)
The CLEU REMOVED→APPLIED learning and the 1-for-1 diff-based swap learning were both
implemented but not yet tested with a fresh DB. After resetting the spell DB via the config
panel, verify that:
- Boon of the X family all merge into a single typeGroup after cycling through them
- Primal Instinct and Grove Instinct merge into a single typeGroup when one replaces the other
- `spellToTargetGroup` begins populating via the error path when a cast is rejected

### 2. Validate proc guard (next test session)
After deploying the `recentlyCastName` guard:
- Reset the spell DB
- Verify "Vitality Surge" (or equivalent procs) are no longer registered
- Verify all actively-cast spells still register correctly

### 3. Priority system
All spells are currently `priority = 5`. There is no way to express that one typeGroup matters
more than another (e.g., a stamina buff may be lower priority than a critical damage buff).
Consider: adjustable priority per typeGroup in the config panel, or a drag-to-reorder list.

### 4. Party member targeting
Currently uses `TargetUnit(unit)` then `CastSpellByName(name)` for non-self targets. This
changes the player's target, which is disruptive in practice. Consider:
- `CastSpellByName(name, false)` with a macro-style target (`/target name; /cast ...`) — not
  available in Lua
- `SecureActionButtonTemplate` with attribute-based casting for proper macro-equivalent behaviour
- Or: detect if the buff is self-only and skip party members who aren't the player

### 5. playerGroup learning
The playerGroup dimension (mutual exclusivity on the caster) has never been triggered in
testing. Needs a spell that conflicts with another on the caster's own buff bar (e.g. two auras
that can't coexist on self). The current error-path learning should handle this when it
eventually fires.

### 6. Rank handling
Some spells appear under multiple IDs (e.g. Boon of the Lion: IDs 504856 and 505217; Primal
Instinct: 800197 and 803315). These register as separate entries but share a typeGroup. The
optimizer treats them as equivalent providers, which is correct. However, if ranks differ in
strength, the priority field could distinguish them.

### 7. Score decay for the buff DB
Spells learned months ago may no longer be in the player's book. `GetKnownBuffSpells` filters
by `GetSpellInfo` / `GetSpellInfo(name)` availability, so orphaned entries are naturally
excluded — but they persist in `BuffMeDB.spells` forever. A periodic cleanup pass (e.g. on
`PLAYER_ENTERING_WORLD`) could prune entries that fail the availability check.

### 8. HelloAgain integration
When BuffMe successfully applies a buff to a party member, it could emit an event (or call
`HelloAgain_AddInteraction` directly) to record `buff_given` for that member's familiarity
score. Requires a soft dependency check (`if HelloAgain_AddInteraction then ... end`).
