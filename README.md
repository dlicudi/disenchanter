# Disenchanter

Guarded one-click disenchanting for WoW Classic Anniversary, Era, and the
forever Classic beta (Interfaces 20506, 11509, and 16001).
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
The order is fixed when the window opens — anything you loot afterwards joins
the bottom of its bucket until you press **Rescan** or reopen the window.
While a disenchant is casting, click its row again to cancel it. The active row
temporarily becomes a secure `/stopcasting` button and cannot target an item.

### Disenchant next

The **Disenchant next** button in the bottom-right corner always points at the
top row of *Safe to disenchant* — that row is tagged `next` — so you can work
through a bag without moving the mouse. It is one item per click, it never
touches a Check first or Protected item, and it does nothing while a cast is
in progress or while the Safe section is collapsed: what you can't see, it
can't disenchant.

You can give it a key: **Settings → Next-item key**, or `/de key F`
(`/de key none` clears it). The key is only bound while the window is open on
the Disenchant tab; close the window or switch tab and the key goes back to
its normal job. Hiding the whole interface (Alt-Z) releases it too. Use a
single key with no modifier, the mouse wheel (`MOUSEWHEELUP` /
`MOUSEWHEELDOWN`) or mouse buttons 3–5. The left and right mouse buttons are
refused.

The button's macro is `/cast [nocombat] Disenchant`: a secure button can't be
disarmed once combat has started, so the refusal travels with the macro.

The compact panel can be moved and resized from its bottom-right grip; its size
and position are remembered. Rows keep their larger two-line targets so the
yield or safety reason stays visible even in the denser layout.

Each row carries a figure on the right: the estimated gain or loss from
disenchanting on the Disenchant tab, the vendor value on Cleanup, the total
worth on Run Split. Section headers add those figures up.

The search box filters by item name or safety reason. Bucket labels include
text markers (`[OK]`, `[CHECK]`, and `[LOCKED]`) so they do not rely on color
alone, and item tooltips identify the exact bag and slot.

When Auctionator or TradeSkillMaster has prices for both an item and its likely
materials, rows show an approximate disenchant gain or loss. Enable **Sort by
estimated profit** in Settings (or `/de profit`) to put the best estimated
return first. The estimate starts from approximate Classic drop odds and is
guidance, not a promise.

It gets better with use. Every disenchant made from the window is counted
against its quality and item-level bracket, and once you have 25 of a kind the
estimate for that bracket uses what you actually received instead of the book
odds. `/de yields` prints the tallies; `/de yields clear` forgets them.

### Item tooltips

Any disenchantable item's tooltip — in your bags, at the auction house, on a
loot roll, from a chat link — gains what it disenchants into and, with prices
available, what those materials are worth against selling it. Items in your
bags add an **In your bags** line with the verdict (Safe, Ctrl-click or
Protected, and why). That line describes the copy you are carrying, so it
also appears on an auction or a chat link for the same item. Turn all of this
off in Settings or with `/de tooltip`.

Each row shows what it's likely to turn into (`Arcane Dust / Greater Planar
Essence / Small Prismatic Shard`) or, if it's held back, why.

## The Cleanup tab

The same idea pointed at deletion, for when the bags are full and there's no
vendor in sight. `/de trash` (or the **Cleanup** tab in the window) lists the
grey and white items in your bags, sorted **lowest vendor value first** — the
top row is always the cheapest thing to lose. Each row shows what deleting it
forfeits.

- **Click deletes a grey.** Gone for good; the chat line says what it was worth.
- **Whites need a Ctrl-click** — consumables you might still want live here.
- **Protected** works as on the other tab: the keep list and quest guard apply,
  and the value guard protects any stack worth more than `/de value` (market
  price if Auctionator/TSM is installed) until you press Allow. Hearthstone is
  never listed at all.

Deletion happens off the cursor (`PickupContainerItem` + `DeleteCursorItem`),
so it needs no free bag slot. The slot is re-read at the instant of the click
and rows disarm the moment bags change, same as disenchanting — a click can
only ever destroy the exact item its row was showing. Deletions are recorded
in `/de audit` as `item → deleted`; shard splits ignore them.

## Run Split and History tabs

For dungeon and raid nights where you're the designated disenchanter — the
audit on screen instead of scrolling away in chat. `/de run` opens the
**Run Split** tab, which shows:

- **Materials this run** — every material produced since the run marker, with
  the split for the current group on each row: `[Large Prismatic Shard] x13 —
  2 each for 5 members, 3 spare`. With Auctionator or TSM prices each row also
  shows what that material is worth, the header totals the run, and the status
  line gives the value of one share.
- **Log** — the drops newest-first: what was consumed → what it produced, the
  time, the zone, and your group size at that moment.

The numbers come from the audit log, never from your bags — so the shards you
walked in with, bank stock, and mail arrivals are all invisible to it. Only
loot attributed to **your** Disenchant casts is counted.

Without a marker the run counts from when you logged in. A `/reload` or a
dropped connection does not restart that: logging back in within 30 minutes
(the instance's own reset timer) resumes the same session, with its totals,
log, and `/de tally` intact. Only a client crash loses anything — the game
writes addon data on a clean shutdown, so disenchants since the last save go
with it.

Press **New run** as the run begins: it saves the run so far to History and
moves the marker to now (same as `/de split start`). Earlier disenchants stay in `/de audit` but stop
counting toward this run. **Announce** posts the totals, shares and (when
priced) the estimated value to party/raid chat — the only time the addon ever
speaks, and only on that click.
The split uses the roster at the moment you announce; who was present for
which boss is the loot master's call, not arithmetic.

The separate **History** tab contains archived runs. Expand a run to inspect
its roster and material totals. The header shows what the run was worth when
it was archived; the rows show each material at today's prices. This keeps the
live split inventory focused on the current run instead of mixing it with
history.

## Safety

The addon never casts automatically. Each row is a Blizzard secure button
carrying a plain macro that runs only on your click:

```
/cast Disenchant
```

That macro only ever runs on **your** click, on the row **you** clicked —
Blizzard's protected-call rules make anything else impossible. There is no
automation loop and no "disenchant everything" button. **Disenchant next** is
the same secure button as the top Safe row, parked where it doesn't move: one
click or key press, one cast, and it disarms with the rows whenever bags
change.

The macro deliberately stops there — there is no `/use <bag> <slot>` line.
A macro doesn't halt when `/cast` fails, so on a character without Disenchant
(or while you're already casting, or dead) a `/use` line would run on its own
and equip the item, sell it to an open vendor, attach it to an open mail, or
drop it into a trade. Instead the item is named by the button's `target-bag` /
`target-slot` attributes. Blizzard's own secure handler reads those after the
action and applies the spell only if `SpellCanTargetItem()` — that is, only if
the cast actually put Disenchant on the cursor. If the click didn't start a
cast, the item is never touched. (`UseContainerItem` is a protected call on
this client, so the addon can't do this step itself — it's the secure
template's job, same as the default bag UI.)

Rows are registered for any button (`RegisterForClicks("AnyUp", "AnyDown")`),
because this client's secure handler acts on whichever click edge
`ActionButtonUseKeyDown` selects and returns silently on the other — register
one edge and the button does nothing at all, with no error. Only left-click is
ever bound, though: the attributes are written as `type1` / `typeLeftButton`
with no bare `type`, so a right-click finds nothing.

Three things stop a click going to the wrong item:

- **Bags change → every row disarms immediately.** `BAG_UPDATE` clears the macro
  off every row, and `ITEM_LOCK_CHANGED` does the same at the start of a drag
  or split, before its bag update arrives. The rebuild lands a tenth of a
  second later and re-arms rows against the correct slots. A row can never
  fire at something that slid into its slot in between.
- **Rows hold their place.** While the window is open the list is not re-sorted:
  a row stays where it was first shown and new items join the bottom of their
  section, so a rebuild never puts a different item under the cursor. Reopening
  the window, switching tab, changing the sort, or pressing Rescan sorts it
  again.
- **Ctrl for anything questionable.** "Check first" rows have no plain-click
  binding at all — only `ctrl-type1` is set — so a stray click is a no-op rather
  than a lost epic.

If the server ever says an item can't be disenchanted, that item id is
remembered and never offered again — `/de learned` lists those items and
`/de learned clear` forgets them, in case one was misattributed.

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
| `loss` | Disenchanting is estimated to lose more than `/de loss` silver against selling the item. Needs Auctionator or TSM prices; without them it stands down. Off by default. *confirm* |

Press **Allow** on a Protected row to drop it to "check first" for this session.
That override is deliberately not saved: a guard you waved past today is back
tomorrow. The button becomes **Restore**, so the override can be undone without
logging out. To protect something permanently, press its **padlock** — that's
the keep list, and it survives logout.

The padlock keeps that exact item: lock "Notched Shortsword of Magic" and
"Notched Shortsword of Healing" is still offered. `/de keep #itemid` is the
broad form and covers every version of the item; such rows read "on your keep
list (every version of this item)", and unlocking one removes the whole entry.

### Per-character settings

Guards and thresholds are shared by every character by default. Tick **Own
guards and thresholds** at the top of Settings (or `/de char`) and that
character keeps its own set, starting from a copy of the shared ones — useful
when the upgrade and Pawn guards make sense on a main but not on a bank alt.
The keep list, audit, run history and observed yields are always shared.

## Commands

```
/de                       open the window
/de trash                 open the window on the Cleanup tab
/de run                   open the live Split inventory
/de history               open archived run history
/de scan                  print the verdicts to chat
/de keep <#id|name:text>  never disenchant this (an id covers every version)
/de keep [item link]      never disenchant that exact version (shift-click it)
/de keep del <n>          drop keep-list entry n
/de keeps                 list the keep list
/de value <gold>          BoE value that needs a Ctrl-click (0 = off)
/de loss <silver>         how much a disenchant may lose before the loss guard asks for Ctrl
/de ilvl <n>              item level that needs a Ctrl-click (0 = off)
/de confirm <green|blue|epic>   quality above which a Ctrl-click is needed
/de guard [name]          list guards, or toggle one
/de char                  switch this character between shared and its own guards
/de key [key|none]        show, set or clear the Disenchant next key
/de tooltip               toggle disenchant info in item tooltips
/de yields [clear]        what your own disenchants have produced; clear forgets it
/de learned [clear]       items the server refused; clear forgets them
/de tally                 what you've disenchanted this session
/de audit [n|clear]       the log: what → what, when, where, group size
/de split [start|say|party|raid]   divide shards since the marker
/de runs [name <text>|end|clear]   name, archive, list, or clear run history
/de profit                toggle estimated-profit sorting
/de mode                  swap how a row fires (see below)
/de debug                 client/spell/attribute dump, and toggle click tracing
```

### /de mode

`macro` (default) issues the cast through a `/cast Disenchant` macrotext;
`spell` issues it through the button's `spell` attribute. In both modes the
item is applied by the secure template's `target-bag` / `target-slot`
handling, only while Disenchant is on the cursor. Both work; the second exists
in case a patch breaks macrotext.

`/de debug` prints what the spell name resolved to, which attributes actually
landed on row 1, and whether the button is protected — then toggles a trace that
prints a `PRE`/`POST` pair per click. If `PRE` fires and `POST` shows nothing
casting and no spell on the cursor, the secure handler ran but performed
nothing, which is a click-registration problem rather than a macro one.

## Audit and shard splits

Every completed disenchant is written to a saved log: what was consumed, what
it produced, when, in which zone, and how big your group was at the time.
`/de audit` shows the last 20 entries (`/de audit 50` for more, `/de audit
clear` to wipe it). The log keeps the newest 300 entries.

For dungeon and raid runs where you're the designated disenchanter:

```
/de split start     set the marker as the run begins
/de split           totals since the marker, divided by the current group
/de split party     the same, announced to the group (raid-aware)
```

The output is per-material: `[Large Prismatic Shard] x13 — 2 each, 3 spare`.
The division uses the roster *at the moment you ask* — who was present for
which boss is the loot master's call, not arithmetic. And in keeping with the
house rule, nothing is ever announced to chat except on the explicit
`say`/`party`/`raid` argument.

Two honest caveats: the log only sees **your** casts, and a loot line is
attributed to a disenchant by landing within ~3 seconds of your cast finishing.
Only your own enchanting-material loot is accepted, and the pending transaction
closes after its first accepted material line.

Starting a new run archives whatever the Run Split tab was showing, if it has
any drops — including disenchants since login when no marker was ever set. Up
to 20 run summaries retain their name, time, roster, material totals, and drop
count even after old audit rows roll off. They are browsable in the **History**
tab. `/de runs end` archives the same way and leaves a fresh marker, so an
ended run's drops never reappear in the live split; `/de runs name` and
`/de runs clear` name the current run and wipe the history.

## Optional integrations

All soft — the addon works without any of them.

- **Auctionator** / **TradeSkillMaster** — market prices for the value and loss
  guards, profit estimates, tooltips and run values.
- **Pawn** — the upgrade guard also asks Pawn.
- **ItemRack** — items in your saved sets are protected.

## Notes

- `Disenchanter_Data.lua` holds the Era and TBC item-level bands used by both
  yield hints and profit estimates. They're guidance, not a promise — the actual
  roll inside a band is dust vs essence vs shard.
- In combat the list freezes and greys out: arming a row means `SetAttribute`,
  which Blizzard forbids in combat. Opening or changing tabs is deferred until
  combat ends, and the secure rows are built safely at login.
- Without Enchanting the window still works as a "what would this give me"
  viewer; nothing will cast.

## Install / sync

```
npm run sync-addon    # or: ./sync.sh — copies into the WoW AddOns dir, then /reload in game
```

## Development and release checks

The load order is intentionally small: `Disenchanter_Compat.lua` normalizes
client APIs, `Disenchanter_Data.lua` owns static disenchant bands,
`Disenchanter_DB.lua` migrates and repairs saved data once at login, and
`Disenchanter.lua` contains runtime classification, audit, commands, and UI.
This keeps compatibility, data, and persistence work out of the secure and
destructive paths.

Run the automated checks before packaging:

```
npm test
```

The tests cover syntax and version consistency, legacy/modern container APIs,
saved-variable repair, guard precedence, value and quality gates, secure
plain/Ctrl attribute separation, loot filtering, combat deferral, verified
Trash deletion, the Next button's arming and key lifetime, the loss guard,
per-character settings, tooltip lines, observed yields, and run values. Blizzard's secure execution and lockdown cannot be simulated
outside the game, so each release also needs this short client checklist on
every supported branch:

1. Open `/de` before and during combat; confirm combat opening is deferred and
   rows work again after combat.
2. Move or split a listed stack; confirm the old row disarms and cannot target
   the item now occupying that slot.
3. Disenchant one Safe and one Check first item; confirm plain click only works
   for Safe and Ctrl-click is required for Check first.
4. On Trash, delete one grey and one Ctrl-gated white; confirm the audit records
   them only after they disappear. Cancel any client deletion prompt and confirm
   no success line or audit row is produced.
5. Complete a disenchant, then loot an unrelated item immediately; confirm only
   enchanting materials appear in `/de tally`, `/de audit`, and the Run Split tab.
6. Click **Disenchant next** and confirm it disenchants the row tagged `next`
   and nothing else. Set a key with `/de key`, confirm it works on the
   Disenchant tab, does nothing on Cleanup, and returns to its normal binding
   when the window closes and when the interface is hidden with Alt-Z. Enter
   combat with the window open and confirm the key does nothing.
7. Hover a disenchantable item in the bags and at a vendor or in a chat link;
   confirm the tooltip lines appear once and the bag item shows its verdict.
8. Open Settings, scroll it, change a threshold, and toggle per-character
   settings; confirm the list follows.
