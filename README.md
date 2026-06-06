# Vain

Vain is a Roblox exploit client built for performance and flexibility. It ships with a polished, themeable UI, dedicated modules for popular games, and a comprehensive toolkit covering combat, movement, visuals, and utility — all from a single lightweight loader.

Auto-updates on every injection, persistent profile support, and a Friends/Targets notification system make Vain a reliable choice for daily use across any game.

---

## Injection

Paste the following into your executor:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/VainV6/Vain/main/init.lua", true))()
```

---

## Features

- **Combat** — Aim assist, reach, velocity, hitbox expansion
- **Movement** — Speed, flight, NoClip, InfiniteFly, AntiGrounded
- **Visuals** — ESP (box, name, health, tracers), Chams, Radar
- **World** — Fullbright, NoFog, Freecam
- **Overlays** — Crosshair, Speedometer, Coordinates, Armor HUD
- **Utility** — Invisibility, AntiAFK, BunnyHop, Clip

---

## Friends & Targets

Add usernames to the **Friends** or **Targets** list in the GUI.

- On injection, Vain immediately checks who is already in the server and notifies you
- You get a notification when a listed player **joins** or **leaves** mid-game
- Friends and Targets do **not** affect which players modules work on — all players are treated equally

---

## Profiles

Save and load your settings using the **Profiles** tab. Type a name and press Enter to save. Click a saved profile to load it. Settings are also auto-saved every 10 seconds.

---

## Keybind

Default toggle keybind is **Right Shift**. Rebind it in the GUI settings.

---

## UI Themes

Vain ships with three UI themes selectable at runtime:

- **new** (default) — Modern, full-featured UI with blur effects and color picker
- **old** — Classic layout
- **rise** — Lightweight variant

---

## Games

Vain includes game-specific modules for:

- BedWars
- Arsenal
- Murder Mystery 2
- Blade Ball
- Flee the Facility
- Jailbreak
- Prison Life
- Frontlines
- Skywars
- The Survival Game
- Block Tales / 1.8 Arena
- Bridge Duel
- and more

Universal modules work across all games.

---

## Auto-Update

On each injection, Vain checks the latest commit hash from GitHub. If a new version is detected, the local cache is wiped and all files are re-downloaded automatically.
