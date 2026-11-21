# Lion's Pride Casino: the World of Warcraft addon

A gambling-inspired slot machine as an in-game window, so you can spin while you wait on a queue, a boat or a flight path. **It is play money only: there are no real stakes and no gold involved.**

Made by Andura Kaldorei (RP-PvP realm, WoW Forever).

The addon never reads or touches gold, items, mail or trade, and it does not talk to other players.

**Status: version 0.2.** Version 0.1 loaded and played in game. Version 0.2 rebuilds the look and motion to match the web game and adds a minimap button and a settings panel. It has not been seen in game yet: it parses, stays inside Lua 5.1's limits, and plays thousands of spins against a mock of the WoW API, but only the real client can show whether the artwork lines up.

## Install

1. Quit World of Warcraft, or be ready to type `/reload` afterwards.
2. Copy the `LionsPride` folder into your game's `Interface/AddOns` folder. For the install this was built against:

   ```bash
   cp -R addon/LionsPride "/Applications/World of Warcraft/_forever_/Interface/AddOns/"
   ```

3. Start the game. On the character screen, open **AddOns** and make sure **Lion's Pride Casino** is ticked.

If it is listed as out of date, tick **Load out of date AddOns**, or correct the number on the first line of `LionsPride.toc`. To find your client's number, type this in game:

```
/dump (select(4, GetBuildInfo()))
```

## Play

- `/slots`, `/casino` or `/lionspride` opens and closes the window. So does the minimap button. Esc also closes it. Drag it anywhere.
- Pick a bet (25 to 250 credits) and a denomination (the value of one credit), then press **SPIN**.
- **Auto** keeps spinning. **Insert $20 / $100** adds play money.
- `/slots rules`, `/slots stats`, `/slots scale 0.8`, `/slots reset` (a reset keeps your settings).
- `/slots resetpos` puts the window back in its default spot.
- `/slots music` (or the Music button) turns Elwynn Forest music on while the window is open. It is off by default because it replaces the zone music while it plays.

Your credit, progress, jackpots, stats and settings are saved for your whole account.

## Minimap button

A round gold-orb button sits on the rim of the minimap.

- **Click** it to open or close the slot machine.
- **Drag** it around the rim; it stays where you leave it.
- Hide it in the settings or with `/slots minimap`. `/slots` and `/casino` still work when it is hidden.

On versions of the game that have the addon list on the minimap, Lion's Pride Casino appears there too.

## Settings

Press **Options** on the slot window, or type `/slots options`.

| Setting | Default | What it does |
| --- | --- | --- |
| Stop auto-spin in combat | On | When combat or a pet battle starts, auto-spin turns off. The spin in progress finishes and pays as normal. |
| Close window in combat | Off | When combat or a pet battle starts, the window closes, then reopens afterwards. Auto-spin always stops when the window closes. `/slots combat` switches this too. |
| Show minimap button | On | Shows or hides the minimap button. |
| Sound effects | On | Reel, win and bonus sounds. |
| Music | Off | Elwynn Forest music while the window is open. |
| Window scale | 85% | Minus and plus change it in steps of 5%, from 50% to 150%. |

The panel also has **Rules** (prints them to chat) and **Reset position**.

If you are coming from version 0.1: the window used to close in combat. It now stays open unless you turn **Close window in combat** on.

## How it sits with the game's own windows

- It lives on the same layer as the character sheet, bags and spellbook, and comes to the front when clicked. Dialogs, menus, tooltips and the full-screen map stay above it.
- It opens on the left of the screen, clear of the middle, the chat box, the action bars and the bags. It can't be dragged off screen, and it follows your UI scale.
- It never takes the keyboard, so movement and hotkeys work while it is open. Esc closes it the normal way.
- When combat or a pet battle starts, auto-spin stops and the window stays open. Both parts are settings: you can let auto-spin run on, or have the window close and reopen afterwards. It uses no protected functions, so it can't block your action bars or targeting, in or out of combat.
- Sounds use the game's Sound Effects channel and only play while the window is visible. Closing it, hiding the interface (Alt-Z) or a cinematic silences it at once.
- Every spin and bonus is saved the moment it is decided, so a `/reload` or disconnect part-way through loses nothing: the animation is skipped and the result is already in your credit.

## What is in it

- 5 reels, 25 lines, wilds, the Mini / Minor / Major / Grand jackpots.
- **Darkmoon Faire bonus**: six Gold Orbs lock and give 3 respins; every prize ticket that lands resets them.
- **Free games**: three Portals win 10 free games with line wins tripled.
- **XP bar**: every paid spin earns experience. The bar always looks close to full and glows when it is nearly there. On a level-up it fills to the top, flashes, says "Level Up!" and opens the Faire with a buff.

## How it looks and moves

- **The inn**: a peaked blue-shingle roof with a hanging "Lion's Pride Casino" sign, timber posts, plaster walls, jackpots and the XP bar on dark parchment in timber frames, and the reels in a timber-framed window with a warm glow. The textures are the Goldshire inn's own.
- **Reels**: they scroll, stop left to right and settle with a small bounce. A reel that could complete a bonus spins on with a pulsing gold glow.
- **Wins**: winning cells light up, the rest dim, and the paylines are drawn across the reels, cycling when there is more than one.
- **Darkmoon Faire**: the inn fades to purple (roof, walls and timber tinted, velvet over the plaster, the Faire curtain over the reel window), the board fades in, tickets flash into place, then it fades back.
- **Big wins**: every credit is counted in the reel window while the title climbs Big Win, Epic Win, Legendary Win, with a fountain of gold coins and fireworks. The Stormwind theme starts with the count and fades out as the ceremony closes. Click to skip the count.

Everything on screen and every sound is one of the game's own files, referenced by path or file ID. The addon ships no art or audio.

## Files

- `LionsPride.toc`: the addon manifest.
- `Engine.lua`: the rules (symbols, pays, bonus odds). A port of `engine.js` from the web version.
- `View.lua`: everything you see and hear: the inn, the reels, effects, sound and music.
- `UI.lua`: the game flow, the controls and the chat commands.
- `Options.lua`: the minimap button and the settings panel. Written from scratch; the addon ships no libraries.

## Differences from the web game

An addon can't blur or recolour images, so a few things are approximated:

- The Faire is tinted purple rather than hue-shifted, and there is no blur on spinning reels.
- Titles are solid gold with a shadow, not a gradient.
- The roof's slopes are built from thin stepped strips, so the edges are very slightly stepped.
- The big-win drum beat is made from game sounds (two ticks and a coin hit), since an addon can't synthesise sound.
- The settings live in the addon's own panel. They are not listed in the game's Options > AddOns screen.
