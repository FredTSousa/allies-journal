# Player Reviews

A World of Warcraft addon for remembering the players you group with. Rate them on how they were to play with and how they performed, and see those reviews again wherever you meet them.

> **Beta.** Player Reviews is new and has only been tested on the Forever client. If something breaks, please [open an issue](https://github.com/FredTSousa/Player-reviews/issues) with what you were doing and any error text (BugSack or `/console scriptErrors 1` helps).

## What it does

- **Review prompts.** When a run ends or someone leaves your group, a review window opens: Social and Performance ratings (Good, Average, Bad), a note for each (required when the rating isn't Average), one-click tags, and the fights, DPS chart and chat from your time together.
- **Player list (`/pr`).** Cards for everyone you've reviewed or grouped with, showing class, role, online status, last place seen and their ratings. Filter by role or review, search by name, and open a player for their full history.
- **Badges and tooltips.** A colored badge on target, party and raid frames and on Group Finder listings, a tooltip with the latest review, and a marker in chat.
- **Group Finder.** Reviewed players are flagged on listings, and each listing shows where its leader currently is.
- **Recent Allies.** Reviewed players are pinned in Blizzard's Recent Allies list with a short note, and the interactions Blizzard recorded (fought together, traded and so on) appear in the player's detail.
- **History and housekeeping.** Session history, storage clean-up, a minimap button, and an options window (`/pr options`).

## Commands

| Command | |
| --- | --- |
| `/pr` | Open the player list |
| `/pr options` | Open the settings |
| `/pr queue [unit]` | Review a unit (default: your target) |
| `/pr queuename <name>` | Review someone by name |
| `/pr minimap` | Show or hide the minimap button |
| `/pr help` | Full list |

## Your data

Everything is stored locally in your own SavedVariables file: the reviews you write, their notes, and the chat lines captured while grouped with someone you review. Nothing is sent anywhere.

## Installing

Player Reviews is built for the Forever client and only loads there. Copy the `PlayerReviews` folder into that client's `Interface/AddOns/` folder.

## Releasing

Pushing a version tag (for example `v0.1.0-beta`; a tag containing "beta" is published as a beta) runs `.github/workflows/release.yml`, which builds the package with BigWigs Packager and uploads it. Before the first release, fill in the `X-Curse-Project-ID`, `X-WoWI-ID`, `X-Wago-ID` and `X-Website` lines in `PlayerReviews/PlayerReviews.toc` and add the `CF_API_TOKEN`, `WOWI_API_TOKEN` and `WAGO_API_TOKEN` secrets to the repository.
