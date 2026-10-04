# Allies Journal

A World of Warcraft addon that works like a private journal of the players you group with. Write a note on someone you enjoyed playing with (or didn't), keep a record of the times you played together, and see it again when you meet them. Everything stays on your own computer.

I used to add players I liked as friends, and ended up with a huge list of names I couldn't place. This pins them in Blizzard's Recent Allies list with your note instead.

> **Beta.** Allies Journal is new and has only been tested on the Forever client. If something breaks, please [open an issue](https://github.com/FredTSousa/player-reviews/issues) with what you were doing and any error text (BugSack or `/console scriptErrors 1` helps).

## What it does

- **Notes.** When a run ends or someone leaves your group, a small window lets you write a note on them: how they were to play with and how they played (Good, Average, Bad), quick tags, and the fights, DPS chart and chat from your time together.
- **Recent Allies.** Players with a note are pinned in Blizzard's Recent Allies list with a short note, and the interactions Blizzard recorded (fought together, traded and so on) show in their detail. Players you rated Bad aren't pinned unless you turn that on.
- **Session history.** Every run you played together is recorded: when, where, how long, and how it went. Dungeons are tracked one run at a time.
- **Group Finder.** Listings with someone from your journal get a badge and a tooltip with your note, and each listing shows where its leader currently is.
- **Frames and tooltips.** A badge on target, party and raid frames, a line in the tooltip, and a mark next to their name in chat.
- **Your journal (`/aj`).** Everyone you've written about or grouped with, with class, role, online status and your notes. Search it and filter by role, rating or whether they're in Recent Allies.
- **Short groupings.** The note window only opens after you've been grouped for a while (10 minutes by default, set in the options). After a shorter grouping you get a line in chat with how long you were together and a reminder that you can right-click their name to add a note. Raids never prompt, but the data is still captured.

## Commands

| Command | |
| --- | --- |
| `/aj` | Open your journal |
| `/aj options` | Open the settings |
| `/aj queue [unit]` | Write a note on a unit (default: your target) |
| `/aj queuename <name>` | Write a note on someone by name |
| `/aj minimap` | Show or hide the minimap button |
| `/aj help` | Full list |

`/alliesjournal` and `/journal` work too.

## Your data

Everything is stored locally in your own SavedVariables file: your notes, the sessions, and the chat lines captured while grouped with someone you write about. Nothing is uploaded or shared, and nobody else can see it.

## Installing

Allies Journal is built for the Forever client and only loads there. Copy the `AlliesJournal` folder into that client's `Interface/AddOns/` folder.

## Releasing

Pushing a version tag (for example `v0.1.0-beta`; a tag containing "beta" is published as a beta) runs `.github/workflows/release.yml`, which builds the package with BigWigs Packager and uploads it. Before the first release, fill in the `X-Curse-Project-ID`, `X-WoWI-ID`, `X-Wago-ID` and `X-Website` lines in `AlliesJournal/AlliesJournal.toc` and add the `CF_API_TOKEN`, `WOWI_API_TOKEN` and `WAGO_API_TOKEN` secrets to the repository.
