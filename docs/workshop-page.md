# Writing a mod's Workshop page

How to write the page that sells a mod to players: the Steam Workshop description, and the README it
comes from. `README.md` is the one source; `dev/workshop-txt.sh` turns it into `workshop.txt`'s
description, and the static check fails while the two differ.

## Who reads it, and what they want

A player with a mod list already too long, deciding in under a minute whether this one earns a
slot. They want four answers, roughly in this order, and leave when one is slow to come:

1. **What do I get to do?** Said in the player's verbs: find, fix, build, wear, power, survive the
   winter. Not what the mod "adds" or "implements".
2. **Is it well made?** They judge by what they see, not by claims: the art, screenshots of the
   thing in use, and a page that gets to the point. A page that reads like a manual or a contract
   tells them the mod will too. Never claim it's bug-free or say how it's tested.
3. **Is it fair?** Players fear a mod that makes the game easy as much as one that's a chore. They
   judge from what things cost: the recipes, the skills, the tools, the limits. Show those and the
   arc from a scrappy start to a payoff that took work; never write "balanced" or "not OP".
4. **Will it break my game?** Which build, single player and multiplayer, an existing save, known
   conflicts.

The second reader is the same player in their first hour, back on the page because they're stuck:
how to start, the one interaction the game doesn't explain, where to look.

Nothing else belongs on the page:

- What the player discovers by playing: every item's numbers, spawn rates, coordinates, loot
  tables. Give hints instead (section 8 below): the fun is in the looking.
- How the mod works inside, how it's tested, why a design was chosen: `DEVELOPMENT.md`, comments
  and commit messages hold those.
- History and changes: Steam's Change Notes tab.
- Every sandbox option: the game lists them with tooltips. Name the few a player picks the mod
  over.
- Requests to rate, rules for commenting, permission and license text, other mods' banners. A
  license line in the credits is enough.

## Where it shows

| Surface | What it holds | Limits |
|---|---|---|
| Workshop gallery | The screenshots above the description, and the first thing players see after the title | The game's uploader can't add them (`SteamWorkshop.SubmitWorkshopItem` sets only the title, description, tags, visibility and preview); add them on the item's Steam page, where uploads leave them alone |
| Workshop description | `workshop.txt`'s description lines, as BBCode | 8000 bytes, counting the `Workshop ID:`, `Mod ID:` and `Map Folder:` lines the game appends (`SteamWorkshopItem.getSubmitDescription`); images show at most 630 pixels wide and can't be zoomed; every upload replaces it, so edits on the website don't last |
| Workshop preview | `preview.png`, the thumbnail in search results, and what decides whether anyone opens the page | Square PNG, 256 or 512 pixels, at most 1,024,000 bytes (`SteamWorkshopItem.validatePreviewImage`) |
| The game's mod list | `mod.info`'s `name`, `description` and `poster` | The poster is drawn stretched to 200 by 200, and the description in a box beside it about as tall: one sentence |
| `README.md` on GitHub | The page, plus what only someone with the repository needs: installing from it, developing | Relative image paths show only to readers who can see the repository |

Images in the description come from `raw.githubusercontent.com`, so they show on Steam only once
the repository is public. The first upload of a private repository's mod has none.

## The page, top to bottom

Each section answers one of the questions above. Leave out a section the mod has nothing for.

1. **Banner.** The mod's name over a shot of it in use, `# ![Name](banner.png)`.
2. **Pitch.** Two to four sentences. The first says what the player gets to do, in their verbs,
   with the problem it solves at most a clause; the rest give the arc from the first scrappy step
   to the payoff. This is the paragraph that decides; `mod.info`'s description says the same in a
   sentence.
3. **Status line.** One line: the build, single player and multiplayer, existing saves, and any
   mod it needs or the one it's known to conflict with. `**Build 42.21 or newer.** Single player
   and multiplayer. Fine to add to a save in progress.` Check the save claim in the code (step 1
   of [Making it](#making-it)).
4. **How it plays.** The progression, as an image of a start against an endgame, or three to five
   stages: what the player is after, and what it takes. This is where fairness shows. Every part
   a stage needs is in its row; a cheap-looking endgame misleads.
5. **The things.** One sheet of every model with its name, grouped by what it's for, and a
   screenshot of them in the world, each with a sentence on what the player does with them. Show
   each model once; a sheet beats a screenshot per item. Other in-world shots go where the page
   talks about them.
6. **Getting started.** The first non-obvious interaction as numbered steps, at most five, in the
   game's own menu words in bold. What a tooltip or the menu already says, leave to the game.
7. **Recipes.** One image of the recipes with their inputs, skills, tools and how they're learned,
   drawn from the game's recipe data so it never goes stale. A sentence on how the player learns
   them, and the one thing that keeps a recipe greyed out with everything in hand. Recipes are
   how players judge whether the mod is fair, so they're never cut. A sheet whose text is too
   small to read at 630 pixels links to itself at full size, `[![alt](recipes.png)](recipes.png)`.
8. **Finding things.** Hints, not tables: who would have owned this in 1993, the kinds of places,
   which things are rare. Name one place to start, as a reward for reading; leave the rest to find.
   Never coordinates, rates or a full list of where something spawns.
9. **Sandbox options.** The few a player would change first, one line each, starting with the one
   that makes the mod easier or harder. "The rest are on the **Name** page of the sandbox options."
10. **Questions.** Only the ones players do ask, in their words, each answered in a line or two:
    adding it to a save in progress and removing it, a known conflict, why something they expect
    isn't there. Check each answer in the code, not from memory.
11. **Credits.** Who made it, what inspired it, the license, a link to the source.

README-only sections, such as Install from the repository and Development, go last and are named in
`WORKSHOP_SKIP` so the Workshop page leaves them out.

## Writing it

- Second person, present tense, the game's own names for items, skills and menus. Bold what the
  player clicks or reads in the game's interface (menu options, the sandbox page), the lead words
  of a list item and the status line's build, and nothing else.
- Concrete beats adjectives: "a car battery in a wooden box runs the TV and a lamp" says more than
  "a deep, rewarding power system".
- A little fun: the world's voice ("the owners won't mind if you take them") in the pitch and the
  hints, plain instructions in the steps.
- Fairness by cost: what it takes, what it's limited to, what wears out. A stated limit ("it never
  gets better than 60%") reassures more than any adjective.
- Numbers a player plans with go in a short table, and a progression table usually replaces the
  rest: what each stage takes says what each part is worth. Numbers they'd discover by playing
  don't go at all. Every number on the page has to be kept in step with the code, so each must
  earn its place.
- One idea per paragraph, at most four sentences; one screen per section at most.
- Markdown that both surfaces show: headings, paragraphs, **bold**, *italics*, links, `-` and `1.`
  lists, tables and `![alt](path)` images. No HTML: the Workshop page can't show it.
- Images go on a line of their own, 1260 pixels wide (630 on the Workshop page, sharp on dense
  screens), with alt text that says what's in them. Every image shows something a player will do
  or see; none is decoration.

## Making it

1. **List what the page must answer**, from the code and from playing it: what the player does
   with the mod, the stages from a first step to an endgame, every recipe, the first interaction
   the game doesn't explain, where the things are, the options players will reach for, and the
   questions players have asked. Find in the code what adding the mod to a save in progress does,
   and removing it: what the mod places on an event that fires once per place (a room first seen,
   an unexplored container) reaches only where the player hasn't been, while what it places on
   every chunk load reaches everywhere; and a change the mod makes to the character, such as a
   trait, stays behind when the mod is removed. This list is the page's raw material, not its
   outline.
2. **Plan the images**: the preview, the banner, the progression, the sheet of models, a few
   in-world shots, the recipes, and four to eight gallery shots. The preview shows the mod's one
   recognisable thing, readable at thumbnail size. A section holds at most two images. Shoot them
   with a [capture mode](adopting.md#capture-modes) so a reshoot after a change is one command,
   and lay them out with a script, never by hand.
3. **Write the sections in order**, the pitch first and last: rewrite it once the rest is done.
4. **Cut.** For each sentence ask: would a player deciding whether to subscribe, or stuck in their
   first hour, miss it? If not, it goes, or moves to `DEVELOPMENT.md` if it's for whoever changes
   the mod. A table of where everything spawns, every sandbox option, and an explanation of what a
   tooltip already says are the usual cuts. The README is the Workshop page, so Steam's byte
   budget is the README's too.
5. **Generate the Workshop description** with `dev/workshop-txt.sh`, which reports how much of
   Steam's 8000 bytes the page uses and fails when it's over. An image costs about a hundred bytes;
   a page over the budget cuts words, not images.
6. **Read it as a player.** Render the README 630 pixels wide (`pandoc -f gfm` and a browser) and check:
   - The banner, the pitch and the status line fit the first screen.
   - Skimming only the headings, images and bold text still tells you what the mod does.
   - Every recipe and every model is on the page, and no spawn table is.
   - Nothing on it is about the mod's code or tests.
7. **Publish.** Push the art and make the repository public first, or the page goes up without its
   images. Upload with `visibility=private`, read the item's real page, then make it public. Add the
   gallery shots on the item's Steam page, and keep `mod.info`'s description, and its translations
   if the mod has them, in step with the pitch.
