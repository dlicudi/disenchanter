# Disenchanter

Guarded one-click disenchanting for WoW Classic (Anniversary, Interface 20506).
Companion to [mail-mule](https://github.com/dlicudi/mail-mule) — same shape, same
"the addon never acts on its own" rule.

`/de` opens a window listing every disenchantable item in your bags, sorted into
three buckets:

| Bucket | What it means |
| --- | --- |
| **Safe to disenchant** | Left-click the row and it disenchants. |
| **Check first** | Ctrl-click required. Blues and epics, valuable BoEs, anything over your item-level cap. |
| **Protected** | No click does anything. Keep list, quest items, relics, set pieces, Use: effects, gear that beats what you're wearing, Pawn upgrades, ItemRack set members. |

Rows are sorted cheapest-first inside each bucket, so working through a bag of
greens is: click the top row, wait for the cast, click the new top row.

Each row shows what it's likely to turn into (`Arcane Dust / Greater Planar
Essence / Small Prismatic Shard`) or, if it's held back, why.

## Safety

The addon never casts anything. Each row is a Blizzard secure button carrying a
plain macro:

```
/cast Disenchant
/use <bag> <slot>
```

That macro only ever runs on **your** click, on the row **you** clicked —
Blizzard's protected-call rules make anything else impossible. There is no
automation loop and no "disenchant everything" button.

Rows are registered for any button (`RegisterForClicks("AnyUp", "AnyDown")`),
because this client's secure handler acts on whichever click edge
`ActionButtonUseKeyDown` selects and returns silently on the other — register
one edge and the button does nothing at all, with no error. Only left-click is
ever bound, though: the attributes are written as `type1` / `typeLeftButton`
with no bare `type`, so a right-click finds nothing.

Two things stop a click going to the wrong item:

- **Bags change → every row disarms immediately.** `BAG_UPDATE` clears the macro
  off every row; the rebuild ~0.1s later re-arms them against the correct slots.
  A row can never fire at something that slid into its slot in between.
- **Ctrl for anything questionable.** "Check first" rows have no plain-click
  binding at all — only `ctrl-type1` is set — so a stray click is a no-op rather
  than a lost epic.

If the server ever says an item can't be disenchanted, that item id is
remembered and never offered again.

## Guards

`/de guard` lists them; `/de guard <name>` toggles one. Guards marked *protect*
move an item to Protected; the rest only ask for a Ctrl-click.

| Guard | |
| --- | --- |
| `quest` | Quest items and anything that begins a quest. *protect* |
| `relic` | Idols, librams, totems, sigils. *protect* |
| `set` | Item-set pieces. *protect* |
| `use` | Anything with a Use: effect. *protect* |
| `upgrade` | Out-levels what you have equipped in that slot, comparing like armour class for like. *protect* |
| `pawn` | Pawn (if installed) rates it an upgrade. *protect* |
| `itemrack` | Named in one of your ItemRack sets. *protect* |
| `boe` | Any bind-on-equip item. Off by default. *confirm* |
| `value` | BoEs worth more than `/de value` — Auctionator or TSM market price if either is installed, vendor price otherwise. *confirm* |

Press **Allow** on a Protected row to drop it to "check first" for this session.
That override is deliberately not saved: a guard you waved past today is back
tomorrow. To protect something permanently, press its **padlock** — that's the
keep list, and it survives logout.

## Commands

```
/de                       open the window
/de scan                  print the verdicts to chat
/de keep <#id|name:text>  never disenchant this
/de keep del <n>          drop keep-list entry n
/de keeps                 list the keep list
/de value <gold>          BoE value that needs a Ctrl-click (0 = off)
/de ilvl <n>              item level that needs a Ctrl-click (0 = off)
/de confirm <green|blue|epic>   quality above which a Ctrl-click is needed
/de guard [name]          list guards, or toggle one
/de tally                 what you've disenchanted this session
/de mode                  swap how a row fires (see below)
/de debug                 client/spell/attribute dump, and toggle click tracing
```

### /de mode

`macro` (default) puts `/cast` + `/use` in one macrotext, entirely inside the
secure handler. `spell` casts Disenchant from the secure button and lets
`PostClick` apply it with `UseContainerItem`, which isn't a protected call.
Both work; the second exists in case a patch breaks macrotext.

`/de debug` prints what the spell name resolved to, which attributes actually
landed on row 1, and whether the button is protected — then toggles a trace that
prints a `PRE`/`POST` pair per click. If `PRE` fires and `POST` shows nothing
casting and no spell on the cursor, the secure handler ran but performed
nothing, which is a click-registration problem rather than a macro one.

## Optional integrations

All soft — the addon works without any of them.

- **Auctionator** / **TradeSkillMaster** — market price for the value guard.
- **Pawn** — the upgrade guard also asks Pawn.
- **ItemRack** — items in your saved sets are protected.

## Notes

- The yield table (`YIELD` in `Disenchanter.lua`) is the TBC 2.5.x item-level
  bands. It's a hint for "is this worth my time", not a promise — the actual roll
  inside a band is dust vs essence vs shard.
- In combat the list freezes and greys out: arming a row means `SetAttribute`,
  which Blizzard forbids in combat. You can't disenchant in combat anyway.
- Without Enchanting the window still works as a "what would this give me"
  viewer; nothing will cast.

## Install / sync

```
npm run sync-addon    # or: ./sync.sh — copies into the WoW AddOns dir, then /reload in game
```
