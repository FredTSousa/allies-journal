# Changelog

## 0.3.0-beta

- A line in chat when someone you have a note on joins your group (how it went, how many sessions together, and your note). Not in raids.
- At the end of a dungeon, a line in chat listing who in the group you already have a note on ("Familiar faces this run"). Not in raids.
- `/aj runs`: a diary of your recorded runs, newest first, with who was there and a note you can write about each run. It is built from the sessions you already have, so your past runs show up too and nothing extra is stored apart from the notes you type.
- `/aj numbers`: your journal in numbers (players, notes, time grouped, who you have played with most, where you have been most).
- A line in chat when someone you noted as Great comes online. Both reminders can be switched off in `/aj options`.
- A right-click menu on a player's card in `/aj`: Whisper, Invite, Add Friend, Add Note and View history.
- A journal-style icon for the minimap button and the addon list.
- Search in `/aj` now looks inside your notes and the places you played, not just names. Several words all have to match.
- Each player now shows "Together so far": sessions, total time grouped, first and last date.
- New option in `/aj options` (off by default): ask one question, "How was it?" (Great / Fine / Not for me), instead of Social and Performance, with one note box and one set of quick tags. Each note remembers how it was written, so switching never changes a note you already have, and editing a note opens it the way it was saved.

## 0.2.0-beta

- Renamed from Player Reviews to **Allies Journal**: it's a private journal of the people you group with, not a score. The addon folder is now `AlliesJournal`, the commands are `/aj`, `/alliesjournal` and `/journal` (`/pr` still works), and the wording in the window, tooltips and options talks about notes instead of reviews.
- The three levels are reworded so they describe your own experience instead of grading the other player: Social is Great to play with / Fine / Not for me, and Performance is Strong / Solid / Struggled. Your existing notes carry over unchanged.
- Players you marked Not for me or Struggled are not pinned in Recent Allies unless you turn that on in the options. This applies everywhere a pin is made.
- **If you were using Player Reviews:** your saved data is stored under the addon folder's name. Close the game, copy `WTF/.../SavedVariables/PlayerReviews.lua` to `AlliesJournal.lua` (in the account folder and in each character's folder), then delete the old `PlayerReviews` addon folder.

## 0.1.1-beta

- The minimum time you need to be grouped with someone before a review window opens (10 minutes by default) is now a slider in `/pr options`, on the Sessions tab.
- Badges on party, raid and target frames are repainted a moment after you save a review, so they show up reliably on EllesmereUI frames.

## 0.1.0-beta

- First public beta, built and tested on the Forever client. Expect rough edges; please report problems with the steps that caused them.
- Review the players you group with after a run or when they leave: Social and Performance ratings with notes, quick-pick tags, and the fights, DPS chart and chat from your time together.
- Browse your history with `/pr`: player cards with class, role, online status, last place seen, filters and search.
- Badges on target, party, raid and Group Finder rows, plus tooltips and chat markers for reviewed players; leader location on Group Finder listings.
- Recent Allies integration: reviewed players are pinned with a short note, and Blizzard's own interaction history shows in the detail view.
- "Check Not Recent" in `/pr` uses /who (one click per player) to see whether players missing from Recent Allies are online.
- Session history, storage clean-up, minimap button and an options window.
