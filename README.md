# Bloodsports

Bloodsports is a World of Warcraft addon for **WoW: Forever**. It covers PvP: duels, an opponent finder, fight clubs and
gambling rings. It records duels and ring sessions, and the Meta Uploader sends them to World of Meta. The ranking lives in
Elders. Bloodsports gives badges only.

Status: in development. The addon is not released.

## What it does

- **Duels.** A duel engine follows the states from request to countdown, active, end and resolved. It records the winner,
  first blood, and how the duel ended (knockout, retreat, timeout). A record is confirmed by the other player (`both`), by a referee's
  verdict (`referee`), or marked `disputed` (`Confirm.lua`).
- **Finder.** Finds duel partners, fight-club rivals and referees over a hidden lobby channel, then sends a party invite
  (`Finder.lua`).
- **Fight clubs.** One champion per class per faction. A champion is challenged after a win streak of 10. The streak counts
  only wins that both players, or a referee, confirmed (`Club.lua`).
- **Gambling rings.** A referee runs a ring session. The addon records trades and bets and computes the parimutuel payouts.
  It never moves gold (`Ring.lua`).
- **Venues** (`Data/Venues.lua`): practice (The Crossroads, Goldshire), a fight club (Honor Road), gambling rings (Ratchet,
  Everlook, Gadgetzan, Booty Bay) and King of the Hill (Gurubashi Arena).
- **Main window** (`/bs`): tabs for Duels, Matches, Finder, Clubs and Ring. Plus a duel card, toasts, a minimap button, and
  champion badges on player tooltips.

## Repository layout

| Path | Contents |
|---|---|
| `Bloodsports/` | The addon: `Core.lua`, `Duel.lua`, `Confirm.lua`, `Finder.lua`, `Club.lua`, `Ring.lua`, `Stats.lua`, `Data/`, `UI/`, `Media.lua` (generated), `Bloodsports.toc`. |
| `Bloodsports/Libs/MetaKit/` | A copy of the MetaKit framework. Written by `../elders/tools/build.py`. Do not edit it here. |
| `tests/` | Lua tests (`run.sh`, `test_*.lua`). |
| `docs/` | Not part of this repository. Planning and research notes are kept locally. |

The build, install and art tools are in the `elders` repo (`../elders/tools/`). Bloodsports has none of its own.

## Tests

```bash
tests/run.sh            # every tests/test_*.lua, each in its own lua5.1 process
tests/run.sh duel       # only the files whose name contains "duel"
```

Needs `lua5.1` on the PATH. The tests use the WoW stub in the `elders` repo, so keep `../elders` next to this repo. The last
full run passed (2026-10-22).

## Install

Bloodsports is built and installed by the Elders build script. From the `elders` repo:

```bash
python3 tools/build.py --install "<WoW>/_retail_/Interface/AddOns"   # copies Elders, Bloodsports and MetaProbe
```

`--install` deletes the existing `Bloodsports` folder in that AddOns folder before copying the new one. Use your game
flavour's folder (`_retail_`, `_classic_` and so on). Run `python3 tools/build.py` without `--install` to refresh the
`Libs/` copy and `Media.lua` only.

## Commands

| Command | What it does |
|---|---|
| `/bs` | Toggles the main window. `/bloodsports` works too. |
| `/bs find` | Opens the opponent finder. |
| `/bs ring` | Opens the gambling ring tab. |
| `/bs referee on` or `off` | Offers you as a referee, or withdraws the offer. |
| `/bs link CODE` | Links this character to your World of Meta account (see below). |
| `/bs sync` | Reloads the UI, so the client writes SavedVariables and the uploader picks up results. |
| `/bs venue` | Prints the venue you are standing in. |
| `/bs debug` | Toggles debug output. |

### Linking to World of Meta

1. Sign in on the World of Meta account page and create a link code. It is valid for 15 minutes and works once.
2. In game, type `/bs link CODE`. The addon accepts exactly 8 letters or digits. It saves the code, and sends it on your next
   logout or `/bs sync`.
3. The Meta Uploader exchanges the code for a token. See `../elders/uploader/README.md`.
