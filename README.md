# Buff Me

A smart party buff manager for [Project Ascension](https://ascension.gg).

Buff Me adds a single draggable button to your UI. Click it to cast the next most-needed buff for your party. Right-click to expand a panel showing each party member's buff coverage at a glance. Only operates outside of combat.

## Features

- **One-click buffing** — each press casts the optimal next buff for the party
- **Party status panel** — right-click to see all members and their missing buffs
- **Self-learning spell database** — discovers your buff spells automatically as you play; no configuration needed
- **Three-dimensional exclusivity model**:
  - `typeGroup` — prevents overwriting a stronger equivalent buff already applied by another player (e.g. won't cast Fortitude on top of another priest's)
  - `targetGroup` — tracks which of your own spells are mutually exclusive on a target
  - `playerGroup` — tracks which spells are mutually exclusive on yourself (e.g. auras)
- **Adapts to custom classes** — works on Project Ascension's classless system; learns your actual spell kit rather than assuming a fixed class

## How It Learns

On first use, the spell database is empty. As you buff your party:

1. Each successful buff application (detected via combat log) registers that spell
2. If a cast is rejected with *"A more powerful spell is already active"*, the addon links the competing auras into the same exclusivity group
3. Over time the database becomes a complete map of your buff kit and its interactions

## Usage

- **Left-click** the button to cast the next needed buff
- **Right-click** to toggle the party status panel
- **Shift-drag** the button to reposition it

The button badge shows the count of missing buffs across all party members.

## Installation

Copy the `BuffMe` folder into your WoW AddOns directory:

```
<WoW>/Interface/AddOns/BuffMe/
```

Enable **Buff Me** on the AddOns screen at character select.

## Compatibility

Built for the **Project Ascension** client (WoW 3.3.5a, Interface 30300).
