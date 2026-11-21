# Lion's Pride Slots: the World of Warcraft addon

The slot machine as an in-game window, so you can spin while you wait on a queue, a boat or a flight path.

Made by Andura Kaldorei (RP-PvP realm, WoW Forever).

It is play money only. The addon never reads or touches gold, items, mail or trade, and it does not talk to other players.

**Status: version 0.1, not yet run in game.** The code parses cleanly and the rules engine has been simulated outside the game, but the window itself has never been loaded by a WoW client. Expect to find and report a few errors on the first run.

## Install

1. Quit World of Warcraft, or be ready to type `/reload` afterwards.
2. Copy the `LionsPride` folder into your game's `Interface/AddOns` folder. For the install this was built against:

   ```bash
   cp -R addon/LionsPride "/Applications/World of Warcraft/_forever_/Interface/AddOns/"
   ```

3. Start the game. On the character screen, open **AddOns** and make sure **Lion's Pride Slots** is ticked.

If it is listed as out of date, tick **Load out of date AddOns**, or correct the number on the first line of `LionsPride.toc`. To find your client's number, type this in game:

```
/dump (select(4, GetBuildInfo()))
```

## Play

- `/slots` or `/lionspride` opens and closes the window. Esc also closes it. Drag it anywhere.
- Pick a bet (25 to 250 credits) and a denomination (the value of one credit), then press **SPIN**.
- **Auto** keeps spinning. **Insert $20 / $100** adds play money.
- `/slots rules`, `/slots stats`, `/slots scale 0.8`, `/slots reset`.
- `/slots resetpos` puts the window back in its default spot. `/slots combat` switches closing in combat on or off.

Your credit, level, jackpots, stats and the window's position and scale are saved for your whole account.

## How it sits with the game's own windows

- It lives on the same layer as the character sheet, bags and spellbook, and comes to the front when clicked. Dialogs, menus, tooltips and the full-screen map stay above it.
- It opens on the left of the screen, clear of the middle, the chat box, the action bars and the bags. It can't be dragged off screen, and it follows your UI scale.
- It never takes the keyboard, so movement and hotkeys work while it is open. Esc closes it the normal way.
- When combat or a pet battle starts, auto-spin stops and the window closes; it reopens afterwards. It uses no protected functions, so it can't block your action bars or targeting.
- Sounds use the game's Sound Effects channel and only play while the window is visible. Closing it, hiding the interface (Alt-Z) or a cinematic silences it at once.
- Every spin and bonus is saved the moment it is decided, so a `/reload` or disconnect part-way through loses nothing: the animation is skipped and the result is already in your credit.

## What is in it

- 5 reels, 25 lines, wilds, the Mini / Minor / Major / Grand jackpots.
- **Darkmoon Faire bonus**: six Gold Orbs lock and give 3 respins; every prize ticket that lands resets them.
- **Free games**: three Portals win 10 free games with line wins tripled.
- **XP bar**: every paid spin earns experience; a level-up opens the Faire with a buff.
- Reel suspense when a bonus is one symbol away, and a counted-up big-win moment (click to skip).

Everything on screen and every sound is one of the game's own files, referenced by path or file ID. The addon ships no art or audio.

## Files

- `LionsPride.toc`: the addon manifest.
- `Engine.lua`: the rules (symbols, pays, bonus odds). A port of `engine.js` from the web version.
- `UI.lua`: the window and the game flow.

## Not in this version

Compared with the web game: no background music, no coin fountain or firework visuals (the sounds are there), no inn artwork around the window, and the big-win count is simpler.
