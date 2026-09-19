# Changelog

## 0.4.2 — 2026-09-19

- **Runs on the 1.60 Classic beta client.** That build finished an API
  migration the Anniversary and Era clients haven't started: the loose item,
  spell and money globals now live in `C_Item`, `C_SpellBook` and
  `C_CurrencyInfo`, and the old globals are gone — so opening the window threw
  `attempt to call a nil value` on the first `GetItemInfo` of the bag scan.
  Each one is now resolved once at load to whichever spelling the running
  client has, leaving every call site written the old way.
- Two of those were failing quietly rather than loudly: `IsSpellKnown` and
  `IsPlayerSpell` were already nil-guarded, so on that client the window would
  have claimed you don't know Disenchant.

## 0.4.1 — 2026-08-31

- **Fix: a click could equip, sell, mail or trade the item instead of
  disenchanting it.** The row macro was `/cast Disenchant` + `/use <bag>
  <slot>`, and a macro doesn't stop when `/cast` fails — so on a character
  without Disenchant (or mid-cast, or dead) the `/use` line ran on its own
  against the item. The macro is now `/cast Disenchant` alone; the item is
  named by the button's `target-bag` / `target-slot` attributes, which
  Blizzard's secure handler applies only if `SpellCanTargetItem()` confirms
  the click actually put Disenchant on the cursor. A click whose cast didn't
  start now does nothing at all.
- Rows are no longer armed on a character that doesn't know Disenchant.

## 0.4.0 — 2026-08-26

- Trash tab: the same guarded-click idea pointed at deletion, for when the
  bags are full. Lists grey and white items sorted lowest vendor value first,
  so the top row is always the cheapest thing to lose. Click deletes a grey;
  whites need a Ctrl-click; the keep list and quest guard protect as usual,
  and the value guard protects any stack worth more than `/de value` (market
  price if Auctionator/TSM is installed). Deleting works off the cursor, so
  it needs no free bag slot and no vendor. Hearthstone is never listed.
- `/de trash` (or `/de junk`) opens the window on the Trash tab.
- Deletions are written to `/de audit` as `item → deleted`; `/de split`
  ignores them.
- Run tab: the audit on screen for dungeon/raid nights. Materials produced
  since the run marker with the per-member split on each row, and the drop
  log (what → what, when, where, group size) newest-first. Reads the audit,
  never your bags, so pre-existing shards are invisible to it. "New run"
  moves the marker (same one as `/de split start`); "Announce" posts the
  split to party/raid — the only time the addon speaks, and only on that
  click. `/de run` opens straight to it.

## 0.3.0 — 2026-08-17

- Saved audit log: every completed disenchant records what was consumed, what
  it produced, when, the zone, and your group size. `/de audit [n]` shows the
  newest entries; `/de audit clear` wipes it; capped at 300 entries.
- `/de split` for designated disenchanters: `/de split start` marks the start
  of a run, `/de split` totals every material since the marker and divides it
  by the current group with remainders, and `/de split party` (or `say` /
  `raid`) announces it — never announced without that explicit argument.
- Loot attribution now only accepts your own loot lines ("You receive
  loot: …"), so a party member looting during your cast can't pollute the
  tally or the audit.

## 0.2.0 — 2026-08-17

- In-row cast progress: the row you clicked sweeps a fill while your
  Disenchant is casting, honouring haste and pushback.
- LibDataBroker plugin for Titan Panel / Bazooka / ChocolateBar: safe and
  check-first counts on the bar, session tally in the tooltip. Nothing is
  bundled; it registers only if another addon provides LDB.
- `/de learned` lists the items the server refused to disenchant;
  `/de learned clear` forgets them.
- In combat the list now actually greys out, as the README always claimed.
- The broker counts update when Allow, the padlock, or a guard toggle changes
  them, not just on bag changes.
- Options number boxes commit when they lose focus instead of silently
  discarding what you typed.
- `/de tally` prints its header before the items; `/de value 0` says the
  guard is off; `/de keep del <n>` numbering no longer depends on table
  iteration order; Enchanting-skill lookup survives every shape of
  `GetSpellInfo` this client has shipped.

## 0.1.0

- First release: the three-bucket window (Safe / Check first / Protected),
  secure per-row disenchant macros, guards (quest, relic, set, Use:,
  upgrade, Pawn, ItemRack, BoE, value), keep list, session Allow overrides,
  yield hints, chat report, and the `/de` command set.
