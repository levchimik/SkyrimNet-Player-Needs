# SkyrimNet Player Needs

![SkyrimNet Player Needs](media/banner.jpg)

Surfaces the **player's physical state** to [SkyrimNet](https://www.nexusmods.com/skyrimspecialedition/mods/141988) so NPCs (and the player's own inner voice) can perceive and react to it — survival needs, intoxication, and what the player just ate or drank.

Everything is exposed the way SkyrimNet is designed to consume it: **bio context**, **decorators**, and **native Player Reaction events** you configure in-game. Nothing is hardcoded — reaction chance and cooldown are yours to set.

## Features

### 🍖 Consumption → native Player Reactions
Eating food, drinking a potion, or consuming a raw ingredient is reported to SkyrimNet as a batched event (duplicates collapse as `(x2)`). Each type is registered with an event **schema**, so it appears as a first-class row in **SkyrimNet Settings → Events & Reactions → Player Reactions**:

| Event | Fires when you… |
|-------|-----------------|
| **Player Ate Food** | eat food |
| **Player Drank Potion** | drink a potion |
| **Player Ate Ingredient** | eat a raw ingredient |
| **Player Consumed (Mixed)** | consume a mix in one go |

Set **Response = thought** (or audible) with your own probability/cooldown, and the player will think about what they just ate — governed entirely by your settings.

### 🍺 Intoxication (portable, perk-aware)
An `snpn_drunk` decorator reports how drunk any actor is — **player or NPC** — mapped to tiers (tipsy → drunk → very drunk → blind drunk). It's portable across modlists, auto-detecting whichever alcohol system is installed:

- **Requiem** (`REQ_Storage_Alcohol` rank, using Requiem's own 25/50/75/100 tiers)
- **CACO**, **Last Seed**, **SunHelm**, **Conner's Survival**, **Alcoholic Lite Effects**

It also understands **tolerance**: characters with a "holds their liquor" perk (Requiem's *Drunken Combat*, *Boozy Bard*, the *Addict* trait, etc.) are described as functional and steady despite a high blood-alcohol level, not stumbling drunk.

### 🥖 Survival needs
A first-person bio section describing the player's **hunger, thirst, cold, and exhaustion**, read live from CC Survival Mode / Survival Mode Improved (and LoreRim's thirst notifications) via `has_magic_effect`.

### 😰 Stress & fear
A first-person bio section describing the player's **stress level** (calm → breaking point) and any **creature phobias** they've picked up from near-death encounters, read from the [Stress And Fear](https://www.nexusmods.com/skyrimspecialedition/mods/116522) mod. Prompt-only and silent if that mod isn't installed.

## Requirements

- **SKSE64**
- **SkyrimNet** (beta22+)
- *Optional:* a survival mod (CC Survival Mode / SMI) for the survival section
- *Optional:* any supported alcohol mod for graduated intoxication

## Installation

Install the FOMOD with **Mod Organizer 2** or **Vortex** and pick your components — all default to on except where noted:

- **Core** (ESP + scripts) — consumption events + the intoxication decorators. On by default; deselect if you only want the standalone bio prompts below.
- **Survival Needs prompt** — hunger/thirst/cold/exhaustion. Pure prompt, works without Core.
- **Intoxication prompt** — the drunkenness bio section. **Requires Core.**
- **Stress and Fear prompt** — stress level, active phobias, and overcome phobias. Pure prompt, works without Core. **Auto-selected only when [Stress And Fear](https://www.nexusmods.com/skyrimspecialedition/mods/116522) is installed**, otherwise left off.

The two "pure prompt" modules (Survival, Stress and Fear) need neither the ESP nor Core — they read the relevant mods through SkyrimNet's own decorators and stay silent if those mods aren't present.

After installing, launch the game once, then open **SkyrimNet Settings → Events & Reactions → Player Reactions** and configure how the player reacts to eating/drinking.

## Building the FOMOD from source

The repo layout under `fomod-src/` is the installable tree. Pack its **contents** (so `fomod/` sits at the archive root) with 7-Zip:

```
7z a -t7z "SkyrimNet Player Needs.7z" ./fomod-src/*
```

> Pack with 7-Zip, **not** PowerShell `Compress-Archive` or .NET `ZipFile` — those write backslash path separators that break FOMOD detection in MO2/Vortex.

## Credits

- Built on [SkyrimNet](https://www.nexusmods.com/skyrimspecialedition/mods/141988) by the SkyrimNet team.
- Idiom modeled on SeverActions and the Magic Tattoos Framework SkyrimNet bridge.
