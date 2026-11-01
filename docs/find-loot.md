# Finding loot on the map

`dev/harness/lib/findloot.py` answers "where do I find this?" from the installed game's files, without starting the game, in under a second:

```text
$ dev/harness/lib/findloot.py BookPottery
Items: BookPottery1, BookPottery2, BookPottery3, BookPottery4, BookPottery5, BookPotterySet

Procedural lists that hold them (weight a roll, matches summed; rolls a fill):
  UniversityDesk_Art                       84  x4   no room picks it
  UniversityFilingCabinet_Art              84  x4   no room picks it
  BookstoreBooks                           30  x4   bookstore.other, pawnshop.other, pawnshop.shelves
  PotteryBooks                             30  x8   classroom_pottery.shelves, potteryworkshop.shelves
  ...

Rooms, best weight first; buildings at x, y, floor (z0 ground), nearest town:

  potteryworkshop
    shelves -> PotteryBooks 30
      6071, 5438   z0     Riverside, 379 W
      8128, 11630  z0     Rosewood, 44 NW
     11962, 6919   z1     West Point, 313 E
```

- `findloot.py ITEM_REGEX` matches the pattern, case-insensitive, anywhere in the item names the loot tables use, which mostly leave out the `Base.` module (`BookPottery`, `^FishingRod$`, `Hammer$`). It prints the matching items, every procedural list holding them, and then each room that rolls one, best first, with the buildings that have such a room.
- `findloot.py --room ROOM` lists every building with that room type (`bookstore`, `fishingstorage`).
- `--all` lists every building for a room instead of the first 12.
- `--media <folder>` reads another copy of the game's `media` folder; it defaults to the installed game's, which `PZ_APP` moves as in the harness's scripts.

## Reading the output

- **Weights.** A list's weight is the sum of its matching items' weights, its own items and its junk's. Each item rolls on its own on every one of the list's rolls (`x4`), so weights rank lists. They aren't percentages: the game scales them by the loot rarity options and the zombie density.
- **Picks.** A procedural container picks one of its room's lists for that container type. `pick weight 100 of 2665` is that list's weight against the total of the container's other unforced lists, so a closet crate rarely picks the fishing crate. `only for tiles ...` (or zones, or rooms) is a list the container takes only on those tiles or in those zones. `(own items)` is a container with its items written in its room's table.
- **Rooms.** A room is listed under its own table and under every alias the game gives it (`fishing` shares `fishingstorage`'s table). `all` is the fallback for a container type a room's table doesn't name, so it has no buildings of its own. A room the map never uses, such as a safehouse's, says so. A list no room picks is one the game ships but never rolls.
- **Places.** Coordinates are world squares, the same x and y as the online map and admin teleport. Each is the centre of the building's rooms of that type, and the floor is the room's `z`: 0 is the ground floor, 1 the floor above, -1 a basement. The town is the nearest town name on the world map, with the distance in squares and the direction from that label. A landmark the world map names within 300 squares, such as a hospital or a mall, is added after it.

## Where it reads

- **Loot:** every table in `media/lua/server/Items/Distribution*.lua` and `ProceduralDistributions.lua`, loaded in the game's file order, plus the room aliases `SuburbsDistributions.lua` adds when it merges them. The files are table literals apart from references to other tables, so they are read as literals. A file that one day assigns anything else, such as a function call, stops the tool with the file and line, rather than leaving the tables half read.
- **Rooms:** the `.lotheader` files of the vanilla map, `media/maps/Muldraugh, KY`, through `check/lotheader.py`. An unknown header version stops the tool.
- **Places:** the world map's labels in that folder's `worldmap-annotations.lua`, with the town names from the English `MapLabel.json`.

## What it leaves out

- **Bags.** A bag found in a container comes with its own contents, from the bag tables, and the tool doesn't follow them.
- **Other sources.** Loot on zombies, in vehicles, in the stashes annotated maps point to, and in what the game places with code, such as random scenes in houses, isn't in these tables.
- **Map mods.** Only the vanilla map is read, and only the vanilla loot tables: a mod's distribution changes and its map's rooms aren't included.
