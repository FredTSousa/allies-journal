# Changelog

## 1.4.0

- `/aj options` is reorganized into six tabs by what you're doing: **Notes** (writing a note and when the window opens), **Alerts** (what the addon tells you, by when it happens), **Display** (chat, Group Finder, Recent Allies, the journal window, the minimap button), **Badges**, **Tooltips**, and **Data & privacy** (what is recorded, backups, deleting and resetting). Your settings are unchanged, they have only moved.
- Each option now has a short name with its explanation underneath. Nameplate badge settings grey out while the nameplate badge is off.
- The options window can be resized, and no longer jumps back to the top after **Back up now** or a reset.
- Everything that deletes or resets is together in **Delete and reset** at the bottom of the Data & privacy tab, and the confirmations now say what they do (Delete, Reset, Restore) instead of Yes and No.
- Allies Journal is now listed in the game's own options (Esc > Options > AddOns), with a button that opens its options window.
- A Thanks message left empty, or badge tex coords that aren't four numbers, now go back to the saved value and say why in chat, instead of being ignored silently.
- Two new switches in `/aj options`, Data & privacy tab, under **What is recorded**: **Record damage and healing numbers** and **Keep chat with my notes**. Both are on by default. With one off, that kind of data is no longer read or saved, and the note window and journal leave it out: no group chart or fight list, no Damage and Healing lines, no chat box or View Chat button. With both off, the note window ends at the ratings. Time grouped and time in combat are still recorded.
- Turning a switch off hides what is already saved without deleting it, so turning it back on brings it back. **Delete saved numbers** and **Delete saved chat**, at the bottom of the same tab, remove it for good after asking first.
- The note window is now only as tall as what's in it, so a short note no longer leaves an empty area above the buttons. The height in `/aj options` is the most it takes.
- **View Chat** now only shows on notes that have chat.

## 1.3.0

- In the **Runs** window, everyone in a run now has a button with their name. Click it to write a note on that person for that run: the note gets the run's place instead of "Manual", is linked to just that run, and says which run it's about at the top. A check on the button means you already have a note for that run, and clicking it opens that note to edit. Writing a note about an older run doesn't change when you last saw them.
- Releasing after a wipe no longer counts as leaving the dungeon. Before, the graveyard outside asked you for notes on the whole group mid-run and split the run in two. Now the run carries on when you get back in, and only ends once you're outside alive.

## 1.2.0

- Players from your journal get a badge right after their name on their nameplate, the name floating over them in the world. It needs nameplates turned on for those players in the game options, and doesn't show on friendly players inside dungeons and raids, where the game hides their nameplates from addons. Turn it off or move it in `/aj options`, Badges tab. `/aj badgetest` now puts a test badge on every nameplate too.
- New `/aj why <name>` (or target someone and type `/aj why`) tells you why the note window did or didn't open for them: the last few times a dungeon or group ended with them, what happened each time (window, chat link, added to notes you put off, or not asked, and why), and where things stand right now.
- The journal list puts people who are online first, ordered by the color of their star (green, then yellow, then no note, then red) and then by highest level.
- **Check Status** only looks up people you have a note on.
- In the LFG Forever addon's window, group listings now show where their leader is too.
- **In numbers** counts dungeon runs and outings in the open world separately, the average group now counts everyone who was in it, and a line at the bottom says what isn't counted (raids, short groupings).
- A dungeon run stays one run when someone leaves partway, and playing on together in the open world is one outing however people leave. This applies to runs from now on; older ones are grouped as before.
- Fixed time in a dungeon being counted a second time when you kept playing together in the open world afterwards, which inflated time together and made that outing look far longer than it was.
- Fixed a disconnect in a dungeon starting the run over when you got back in, which lost its fights and restarted the 10-minute wait, so the note window often never opened at the end. The run is now saved as you go and is picked up again if you're back in the same dungeon within 45 minutes. `/aj why` says whether your run carried on or started over.
- Fixed an empty box in front of chat lines with people from your journal, such as whispers you send them. The star icon shows there now, like everywhere else in chat.
- Fixed Lua errors when right-clicking an NPC or pet, or opening a menu or Group Finder listing while the game was hiding a name.
- Smoother with Group Finder open and while searching your journal: scrolling the listings no longer rechecks every group several times over, the journal list is rebuilt once you stop typing instead of on every key, and its size line at the top is worked out at most every 5 minutes (the Refresh button updates it now). Less work too when a raid group forms.

## 1.1.3

- Fixed possible Lua errors when the game hides which player a unit is, while your group changes or when you add a note. Your group list catches up on the next group change.

## 1.1.2

- Fixed a Lua error when you targeted a player while the game was hiding their name. Their badge and View Journal option come back once the name can be read, and Add Note asks you to try again in a moment.

## 1.1.1

- Fixed friends showing as offline in the journal while they were playing, when Recent Allies said they were offline.

## 1.1.0

- Once you've written 3 notes on someone, you get a line in chat with an **[Add a note]** link instead of the note window. The link opens the same note, with that run's fights and chat. New people in the group still get the window. Change the number in `/aj options`, Sessions tab, or set it to 0 to always get the window.
- No more "Couldn't pin" warning for your friends, who can be missing from Recent Allies. Your notes on them stay in your journal.
- Friends in your journal now show their status automatically while they're playing: online, away or busy, plus level, class and zone, with no [NR] tag or Check Status needed. When they're offline, the game doesn't say which character is theirs, so Check Status still works as before.
- A friend icon marks your friends in the journal list. It stays when they're offline, and it updates when you group with them.

## 1.0.1

- The note window no longer keeps asking about people you play with often. Once it has asked about someone, or you've written them a note, it leaves them alone for 12 hours, even across dungeons, regrouping and a `/reload`. Change the wait in `/aj options`, Sessions tab. Sessions are still recorded, and you can still right-click a name to write a note.
- The chat reminder about notes put off for later now comes every 10 minutes instead of every minute.
- Fixed a `/reload` inside a dungeon starting the run over, which lost its fights, time and boss counts.

## 1.0.0

- First full release, for the launch of World of Warcraft: Forever. Allies Journal is out of beta.
- No new features since 0.3.4-beta, and your journal carries over as it is.
- If something breaks, please [open an issue](https://github.com/FredTSousa/allies-journal/issues) with what you were doing and any error text.

## 0.3.4-beta

- **Kept for good:** what Blizzard's Recent Allies logged about each person (dungeons, raids, trades) is now saved in your journal, so it stays after they drop off that list.
- **Private tags and nicknames** for each player, in their detail. They show on cards and in tooltips, and search finds them (`tag:helpful`).
- The journal shows which of your characters you met someone on and played with them as.
- The join line says "last together 45 days ago" after a long gap.
- **Forget player** (right-click a card) removes everything about someone. **Pause recording** (`/aj pause` or the options) stops new sessions and automatic note windows.
- New **Show** filters: My last group and In my party.
- A **Thanks** button in the note window opens a whisper with your thank-you ready. Nothing is sent until you press Enter, and you can change the message in the options.
- Right-click a card: Copy name, and Ignore for people you noted as Not for me.
- Trades with people in your journal are counted (how many, and the last date).
- **Streamer mode** (`/aj streamer`) hides your notes, nicknames and tags in tooltips, chat and the journal.
- An optional small panel lists the people you know when they join your group.
- **Seen nearby** (off by default): remembers friendly players you pass in the open world for 7 days, so you can add them to your journal later. Open it with the Nearby button or `/aj nearby`.
- `/aj demo` adds a few demo people to try the journal out, and `/aj resetwindow` puts the windows back to their default size and place.

## 0.3.3-beta

- **Backup:** a safety copy of your journal is kept on your computer every 12 hours (the last three). Restore one in `/aj options`, General tab, or make one now with `/aj backup`.
- **More on every player:** how you met (level, race, class, where, their guild), what you did together (dungeons, bosses, mobs, quests), the role you saw them in, and their interrupts and dispels. This is saved from now on, so players you already have fill in as you group with them again.
- **Favorites** (right-click a card) and a new **Show** filter: Favorites, Online now, Recent Allies. Search understands `class:`, `role:`, `guild:`, `since:` and `fav:`.
- **`/aj numbers`** has badges, streaks, an activity chart, a comparison with the period before, bosses, mobs and wipes, and a Copy as text button.
- **Run recap:** one chat line at the end of a dungeon with the time, bosses, mobs, quests and wipes.
- **A small star in chat** in front of what players you have a note on say. Hover it to read your note, click it to open them in your journal.
- **Optional warning** on screen, with a sound, when someone you noted as Not for me joins your group.
- **Works with LFG Forever:** the star and journal tooltip also show in its Group Finder window.
- Cleaning up old sessions now keeps their totals.

## 0.3.2-beta

- Fixed an error on login in 0.3.1-beta that stopped waiting notes from surviving a `/reload`.

## 0.3.1-beta

- Notes you have not written yet (open or put off with Later) now survive a `/reload` or relog, for up to 24 hours.
- The journal window has less empty space under the title bar.

## 0.3.0-beta

- At the end of a run the whole group now shares one note window with a tab per person (fight bars, chat and quick tags all included), instead of a window each. It can be switched off in `/aj options`.
- A **Later** button puts the notes off: the window closes, everything is kept in memory, and you get a chat reminder every minute plus a green, flashing minimap button until they are written or skipped. Left-click the minimap button or type `/aj notes` to come back (`/aj notes skip` drops them). Closing the window with the X does the same as Later.
- UI improvements: a new window frame, a tidier note form, a clearer Save button and a journal-style icon.
- The chat lines about waiting notes have a clickable "[Write them now]" link.
- A line in chat when someone you have a note on joins your group (how it went, how many sessions together, and your note). Not in raids.
- At the end of a dungeon, a line in chat listing who in the group you already have a note on ("Familiar faces this run"). Not in raids.
- `/aj runs`: a diary of your recorded runs, newest first, with who was there and a note you can write about each run. It is built from the sessions you already have, so your past runs show up too and nothing extra is stored apart from the notes you type.
- A note you write on a run also shows under that run's session in each player's detail.
- `/aj numbers`: your journal "wrapped". Pick all time, last year, last 30 days or last 7 days and see time grouped, your most-played-with companions, your favorite place, busiest day and time of day, longest run, new faces versus regulars, how your notes landed, and more. Everything is worked out when you open it, nothing extra is stored.
- A line in chat when someone you noted as Great comes online. Both reminders can be switched off in `/aj options`.
- A right-click menu on a player's card in `/aj`: Whisper, Invite, Add Friend, Add Note and View history.
- Search in `/aj` now looks inside your notes and the places you played, not just names. Several words all have to match.
- Each player now shows "Together so far": sessions, total time grouped, first and last date.
- New option in `/aj options` (off by default): ask one question, "How was it?" (Great / Fine / Not for me), instead of Social and Performance, with one note box and one set of quick tags. Each note remembers how it was written, so switching never changes a note you already have, and editing a note opens it the way it was saved.
- The "Check Not Recent" button in `/aj` shows what it is doing (which player it is on, "2 of 7") and a countdown until you can check the next one.
- A note you ask for (right-click menu, Add Note on a target, or `/aj` with a name) opens right away with that person selected, even if the group window is put off or you are in the middle of another note.
- The Group Finder scan no longer runs while the list is hidden, which is lighter on the game.

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
