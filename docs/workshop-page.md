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
   Shoot them with a [capture mode](adopting.md#capture-modes) and lay them out with a script
   ([Laying out the images](#laying-out-the-images)), so a change to the mod is a reshoot, never
   hand work.
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
| `poster.png` | The game's mod list | Drawn stretched to 200 by 200, beside `mod.info`'s description; the same picture as `preview.png` |
| The mod's icon | The game's mod list, beside the mod's name, at about 22 pixels, and the load order list at about 28 | `mod.info`'s `icon=`: a 64 square PNG, drawn pixel by pixel at 32 and doubled (`promo.save_mod_icon`); one object in a few blocks of colour |

Every image shows something a player will do or see; none is decoration. Show each item once: a
sheet beats a screenshot per item. Description images load from `raw.githubusercontent.com`, so
they show on Steam only once the repository is public.

## Laying out the images

`lib/promo.py` lays out every image above from the captures a [capture mode](adopting.md#capture-modes)
wrote to `art/promo/captures`, in the look every mod's pages share: a dark card, NotoSans
(`lib/fonts`, under the SIL Open Font License in `lib/fonts/OFL.txt`), icons and interface
captures grown by whole numbers with nearest-neighbour sampling so their pixels stay crisp. The
mod's `art/promo/compose.py` holds what is the mod's own: which captures go where, the crops, the
rows of the item sheet and the sections of the recipe sheet, the captions. It is a `uv run
--script` file that puts the harness's `lib` on `sys.path`:

```python
#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["pillow==12.3.0"]
# ///
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "dev" / "harness" / "lib"))
import promo

CAPTURES = promo.Captures(REPO / "art" / "promo" / "captures")
ITEMS = promo.ItemSheet(CAPTURES, [("Tools", ["MyMod.Kettle", "MyMod.Whistle"])])

promo.save(ITEMS.draw(), REPO / "art" / "promo" / "images" / "items.png")
promo.save_gallery([("items", promo.page("Everything you can make", ITEMS.draw(width=promo.PAGE[0], k=1.4,
                                                                               height=promo.PAGE[1])))],
                   REPO / "art" / "promo" / "gallery")
```

Pinning Pillow keeps a rerun from unchanged captures writing the same bytes. What it has:

- **Captures.** `Captures(folder)` reads the folder's `promo.json`: `strings` (`modName`, the
  mod's name as the game shows it), and `items` and `recipes` as `PZHarness/Capture.lua` writes
  them, each naming its icon's capture (`icon_<Module>_<Type>`, `icon_build_<name>`). Calling it
  with a name gives that capture; `icon(key, size)` an icon grown by the largest whole number
  that fits size; `thing(key)` the name and icon of an item, by full type, or of what a build
  menu recipe builds, by the recipe's id.
- **Drawing.** Everything is drawn at the README's width, `WIDTH`, or `k` times that for a
  gallery page, where `sized(n, k)` is n of the README's pixels. `canvas`, `paste` (over a soft
  shadow), `text`, `wrap`, `panel`, `badge`, `caption` (a pill on a world shot), `arrow`;
  `pixels`, `scaled`, `fit`, `cover`, `full_width`, `trim`, `rounded`; `title_over`, the mod's
  name over a world shot's darkened left side, for the banner; the colours `BACKGROUND`,
  `PANEL`, `TEXT` and `MUTED`. `save(image, path)` writes a README image and fails unless it is
  `WIDTH` wide.
- **The item sheet.** `ItemSheet(captures, rows, models=False)`, rows of (caption, keys) by
  what the things are for, a key being what `thing` takes. It fails unless every item in
  `promo.json` has a place. A card is the icon over the name; with `models`, the item's
  `model_<Module>_<Type>` capture framed from its box in `promo.json`'s `models`, over the icon
  beside the name. `draw(rows, width, columns, k, height)` draws the rows given, or all of them;
  `pages(pages, k)` makes gallery pages of (file name, caption, row captions, columns), and fails
  unless each row is on one.
- **The recipe sheet.** `RecipeSheet(captures, sections, accent, accents, results)`, sections of
  (caption, recipe ids). It fails unless every recipe is in exactly one section. A card is the
  recipe's name, skills, how it's learned and its tools, then its inputs, an arrow and its
  results; a build menu recipe shows what it builds, and one with neither inputs nor outputs,
  which a character only learns for a menu to offer, only its name and how it's learned.
  `accents` colours a section's cards by its caption, else `accent`; `results` names, by full
  type, the item a recipe whose OnCreate makes it shows. `draw` and `pages` are the item
  sheet's, a page taking (section caption, slice of its ids) pairs and failing unless every
  recipe is on exactly one page.
- **The gallery.** `page(caption, content)` puts content of `PAGE`'s size under the caption
  band; `hero(shot, title)` is the hero's content, the shot covering the page under the mod's
  name, and `shot_page(shot)` a capture centred on the page. `save_gallery(pictures, folder)`
  writes (name, picture) pairs as `NN-name.jpg` in upload order, deletes everything else in the
  folder, and fails on a file of a megabyte or more, the limit of
  `ISteamUGC::AddItemPreviewFile` and half the upload page's.
- **The poster.** `poster(shot, title, line, accent)`: the shot over a band with the mod's name,
  as large as fits, and a line of a few words; `save_poster(image, paths)` writes it to
  `42/poster.png` and `preview.png` and fails over the preview's limit.
- **The icon.** `save_mod_icon(image, path)` takes a `MOD_ICON` (32) square drawing and writes
  it doubled with hard edges: the lists shrink it with linear filtering and no mipmaps, and from
  64 each screen pixel blends at most two of the drawing's, where from 32 a one-pixel line
  smears into its neighbours.

Crops are in capture pixels, as named constants in the script: a reshoot that frames a shot
differently moves them. After a run, look at every image at the size Steam shows it
([The process](#the-process), step 6), the poster at 200 pixels and the icon at 22.

## Where it shows

| Surface | Holds | Limits |
|---|---|---|
| Workshop description | `workshop.txt`'s description lines, as BBCode | 8000 bytes, counting the `Workshop ID:`, `Mod ID:` and `Map Folder:` lines the game appends (`SteamWorkshopItem.getSubmitDescription`); images can't be zoomed; every upload from the game replaces it, so edits on the website don't last |
| Workshop gallery | `art/promo/gallery` | Left alone by the game's uploads |
| The game's mod list | `mod.info`'s `name`, `description` and `poster` | The description shows in a box about as tall as the poster: one sentence |
| `README.md` on GitHub | The description, plus Install and Development | Relative images show only to readers who can see the repository |
