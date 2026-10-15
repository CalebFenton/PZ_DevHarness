# Writing a mod's Workshop page

How to make the pages that sell a mod to players: the Steam Workshop item, with its gallery and
description, and the README the description comes from.

- `README.md` is the description. `dev/workshop-txt.sh` turns it into `workshop.txt`, and the
  static check fails while the two differ.
- The gallery is the images in `art/promo/gallery`, which the mod's art script lays out from its
  captures. `dev/workshop-gallery.sh --upload` puts them on the item.

## The process

1. **List what the pages must answer**, from the code and from playing the mod: what the player
   does with it, the stages from a first step to an endgame, every item and recipe, the first
   interaction the game doesn't explain, where things are, the options players reach for, and the
   questions players ask. Find in the code what adding the mod to a save in progress does, and
   removing it: what the mod places on an event that fires once per place (a room first seen, an
   unexplored container) reaches only where the player hasn't been, what it places on every chunk
   load reaches everywhere, and a change it makes to the character, such as a trait, stays behind
   when the mod goes. This list is raw material, not an outline.
2. **Plan the images** ([Images](#images)): the preview, the description's images and the gallery.
   Shoot them with a [capture mode](adopting.md#capture-modes) and lay them out with a script, so
   a change to the mod is a reshoot, never hand work.
3. **Write the description** in the order of [The description](#the-description-top-to-bottom),
   in the [voice](#voice) below. Write the pitch first, and again last.
4. **Cut.** For each sentence ask: would a player deciding whether to subscribe, or stuck in their
   first hour, miss it? If not, it goes, or moves to `DEVELOPMENT.md` if it's for whoever changes
   the mod. Spawn tables, every sandbox option and what a tooltip already says are the usual
   cuts. The README is the description, so Steam's byte budget is the README's too.
5. **Generate `workshop.txt`** with `dev/workshop-txt.sh`, which says how much of Steam's 8000
   bytes the page uses and fails over it. An image costs about a hundred bytes; a page over budget
   cuts words, not images.
6. **Read it as a player.** Render the README 630 pixels wide (`pandoc -f gfm` and a browser) and
   look through the gallery images at the size Steam shows them, 636 by 358:
   - The banner, the pitch and the status line fit the first screen.
   - The headings, images and bold text alone say what the mod does.
   - Every item the mod adds is on the page; every recipe is on the page or in the gallery; no
     spawn table is anywhere.
   - Nothing is about the mod's code or tests.
7. **Publish.** Push the art and make the repository public first, or the description goes up
   without its images. Upload from the game's Workshop screen with `visibility=private`, then run
   `dev/workshop-gallery.sh --upload`, read the item's real page, and make it public. Keep
   `mod.info`'s description, and its translations if the mod has them, in step with the pitch.

## Who reads it

A player with a mod list already too long, deciding in under a minute whether this one earns a
slot. They want four answers, roughly in this order, and leave when one is slow to come:

1. **What do I get to do?** In the player's verbs: find, fix, build, wear, power, survive the
   winter. Not what the mod "adds" or "implements".
2. **Is it well made?** They judge by what they see, not by claims: the art, screenshots of the
   thing in use, and a page that gets to the point. Never claim it's bug-free or say how it's
   tested.
3. **Is it fair?** Players fear a mod that makes the game easy as much as one that makes it a
   chore. They judge from what things cost: the recipes, skills, tools and limits, and the arc
   from a scrappy start to a payoff that took work.
4. **Will it break my game?** The build, single player and multiplayer, an existing save, mods it
   needs or conflicts with.

The second reader is the same player in their first hour, back because they're stuck: how to
start, the interaction the game doesn't explain, where to look.

Nothing else belongs on the pages:

- What the player discovers by playing: every item's numbers, spawn rates, coordinates, loot
  tables. Hint instead; the fun is in the looking.
- How the mod works inside, how it's tested, why a design was chosen: `DEVELOPMENT.md`, comments
  and commit messages hold those.
- History and changes: Steam's Change Notes tab.
- Every sandbox option: the game lists them with tooltips.
- Requests to rate, rules for commenting, permission and license text, the author's name (Steam
  shows it beside the page), other mods' banners.

## Voice

The page is an invitation to play, written by someone who plays.

- **Fun, and a little dry.** Talk in the world's voice where it fits, in the pitch, the captions
  and the hints: "the owners won't mind if you take them". Keep steps plain.
- **Excited about the payoff, honest about the cost.** The thrill is earning something: say what
  the first step is, what it takes to get further, and what's waiting at the end. Let stated costs
  and limits show it's fair ("it never gets better than 60%"); never write "balanced" or "not OP".
- **Concrete over adjectives.** "A car battery in a wooden box runs the TV and a lamp" beats "a
  deep, rewarding power system". No "immersive", "comprehensive", "robust", "seamless".
- **Short.** One idea per paragraph, at most four sentences; a section fits a screen. Like a good
  item tooltip, not a manual or a contract.
- **Second person, present tense**, the game's own names for items, skills and menus.
- **Hints, not spoilers.** Name the kind of person who'd have owned a thing and the kind of place,
  say what's rare, and give away one place to start.

## The description, top to bottom

Each section answers one of the questions above. Leave out a section the mod has nothing for.

1. **Banner.** The mod's name over a shot of it in use: `# ![Name](banner.png)`.
2. **Pitch.** Two to four sentences. The first says what the player gets to do, with the problem
   it solves at most a clause; the rest give the arc from the first step to the payoff.
   `mod.info`'s description says the same in a sentence.
3. **Status line.** The build, single player and multiplayer, existing saves, and any mod it needs
   or is known to conflict with: `**Build 42.21 or newer.** Single player and multiplayer. Fine to
   add to a save in progress.` Claim multiplayer once the mod's tests pass on a dedicated server.
4. **How it plays.** The progression, as an image of a start against an endgame, or three to five
   stages: what the player is after, and what it takes. Every part a stage needs is in its row; a
   cheap-looking endgame misleads.
5. **The things.** One sheet of every item the mod adds, models and names, grouped by what they're
   for, and a sentence each on what the player does with the groups.
6. **Getting started.** The first non-obvious interaction as numbered steps, at most five, with
   the game's menu words in bold.
7. **Recipes.** A sentence on how the player learns them and what they need around them (a table,
   light, a furnace), and the one thing that keeps a recipe greyed out with everything in hand.
   The recipe sheet goes here if it's readable at 630 pixels in about a screen; otherwise it goes
   to the gallery, and this section links to it at full size.
8. **Finding things.** Hints ([Voice](#voice)); never coordinates, rates or a full list of where
   something spawns.
9. **Sandbox options.** The few a player would change first, one line each, starting with the one
   that makes the mod easier or harder, then "The rest are on the **Name** page of the sandbox
   options."
10. **Questions.** Only ones players ask, in their words, answered in a line or two: adding it to
    a save in progress and removing it, a known conflict, why something they expect isn't there.
    Check each answer in the code.
11. **Credits.** Only the mods or people that inspired it, if any; otherwise leave the section out.

README-only sections, such as Install from the repository and Development, go last; `WORKSHOP_SKIP`
names them so the Workshop page leaves them out.

Markdown: headings, paragraphs, **bold**, *italics*, links, `-` and `1.` lists, tables and
`![alt](path)` images, which both GitHub and the Workshop show; no HTML. Bold only what the player
clicks or reads in the game (menu options, the sandbox page), the lead words of a list item and
the status line's build. Numbers a player plans with go in a short table, and a progression table
usually replaces the rest; every number on the page has to be kept in step with the code, so each
must earn its place.

## The gallery

The images above the description, and what players look at before they read a word. Steam shows
them 636 by 358, letterboxed in black, with a strip of thumbnails; a click opens one at full size.

- 16:9, 1920 by 1080, JPEG at most 2 MB (the upload page's limit), named `NN-name.jpg` in the
  order they show. The art script writes the folder whole, so it holds exactly the gallery.
- Each image shows one thing, with one short caption in the image, in the [voice](#voice) above.
- First the hero shot: the mod's most recognisable thing in use, with its name. Then the
  progression, the things in use, the interface, and the sheets: every item, and the full recipes
  split into readable pages by group.
- Five or six shots of the mod in play, then as many sheet pages as the items and recipes need.
  A YouTube video goes first if there is one; add it on the item's page (**Owner Controls**,
  **Add/Edit Images & Videos**), and `--upload` leaves videos alone.

`dev/workshop-gallery.sh` lists the item's gallery; `--upload` makes its images the folder's,
sorted by name, leaving the title, description, files and videos alone, then checks that Steam
serves every image. The game's uploader can't add gallery images
(`SteamWorkshop.SubmitWorkshopItem` sets only the title, description, tags, visibility and
preview), so the script works the item's **Add/Edit Images & Videos** page in Google Chrome. Its
Chrome profile (`~/.cache/pz-devharness/steam-browser`) stays logged in to Steam: the first run
opens a window to log in as the item's owner, later runs are headless. Not the Steamworks API:
its gallery images live in the uploader's Steam Cloud space for the game, a megabyte shared by
all of an account's Project Zomboid items.

## Images

| Image | Where | Size |
|---|---|---|
| `preview.png` | The thumbnail in search results, collections and the item's sidebar: what decides whether anyone opens the page | Square PNG, 256 or 512 pixels, at most 1,024,000 bytes (`SteamWorkshopItem.validatePreviewImage`); the mod's one recognisable thing, readable at thumbnail size |
| Description images | The README and the description | 1260 pixels wide, shown at 630, on a line of their own, with alt text saying what's in them; at most two to a section |
| Gallery | Above the description | See [The gallery](#the-gallery) |
| `poster.png` | The game's mod list | Drawn stretched to 200 by 200, beside `mod.info`'s description |

Every image shows something a player will do or see; none is decoration. Show each item once: a
sheet beats a screenshot per item. Description images load from `raw.githubusercontent.com`, so
they show on Steam only once the repository is public.

## Where it shows

| Surface | Holds | Limits |
|---|---|---|
| Workshop description | `workshop.txt`'s description lines, as BBCode | 8000 bytes, counting the `Workshop ID:`, `Mod ID:` and `Map Folder:` lines the game appends (`SteamWorkshopItem.getSubmitDescription`); images can't be zoomed; every upload from the game replaces it, so edits on the website don't last |
| Workshop gallery | `art/promo/gallery` | Left alone by the game's uploads |
| The game's mod list | `mod.info`'s `name`, `description` and `poster` | The description shows in a box about as tall as the poster: one sentence |
| `README.md` on GitHub | The description, plus Install and Development | Relative images show only to readers who can see the repository |
