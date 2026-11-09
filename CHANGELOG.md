# Changelog

## Unreleased

- Added **Disenchant next**: a fixed button in the footer that disenchants the
  top Safe row, one item per click, with an optional key (`/de key`, or
  Settings) that is only bound while the window is open on the Disenchant tab.
- Added the `loss` guard: asks for a Ctrl-click when disenchanting is estimated
  to lose more than `/de loss` silver against selling the item. Off by default.
- Item tooltips now show what a disenchantable item turns into, what the
  materials are worth, and — for items in your bags — the verdict.
  `/de tooltip` turns it off.
- The Run Split tab, `/de split` and Announce now include the run's estimated
  value and the value of one share when materials are priced; archived runs
  remember what they were worth.
- Value estimates learn from your own results: after 25 disenchants in a
  quality and item-level bracket the estimate uses what you actually received.
  `/de yields` lists them.
- Guards and thresholds can be per-character (`/de char`, or Settings); the
  keep list, audit and history stay shared.
- Interface: flat buttons throughout, a right-hand figure column on rows with
  section totals in the headers, a placeholder in the filter box, and a
  scrolling Settings tab organised into sections. The minimum window width is
  now 380.
- Interface: one-pixel flat borders, a flat filter box, a thin scrollbar that
  appears only when the list overflows, and plain +/- section toggles. Empty
  sections no longer draw a "(0)" header, and zero counts in the summary line
  are muted. The padlock is faint until an item is actually on the keep list.
- Money is written as `4s 84c` instead of with coin icons, in the window,
  tooltips and chat.
- Rows and the Next button now cast with `/cast [nocombat] Disenchant`, so a
  button left armed when combat starts refuses on its own. (`/de mode spell`
  cannot carry the condition and still relies on the game refusing the cast.)
- Fixed: clicking the resize grip made the window jump in size. It hung by
  whatever point the last drag left it on; it is now pinned by its top-left
  corner before sizing.
- Fixed: pressing Escape in the filter box emptied the box but left the list
  filtered.
- Rows now hold their position while the window is open: a bag update no longer
  re-sorts the list under the cursor, and newly looted items join the bottom of
  their section. Opening the window, switching tab, changing the sort, or
  pressing Rescan puts the list back in sorted order.
- Bag moves now disarm rows at the initial item-lock event, not only at the
  bag update that follows.
- Reworked the panel hierarchy with compact navigation, neutral surfaces,
  denser rows, restrained state accents, and Protected sections collapsed by
  default instead of presenting a wall of low-priority items.
- Replaced the combined Run tab with a live Run Split inventory and a separate,
  expandable History tab for archived material totals and captured rosters.
- Split static disenchant data and saved-variable repair into load-ordered
  modules, keeping persistence and data maintenance out of runtime UI code.
- Unified yield hints, skill requirements, and profit-estimate material IDs in
  one band table so the two calculations cannot drift apart.
- Saved-variable validation now runs once per database table instead of during
  bag scans and sort comparisons.
- Removed the duplicated user manual from the main Lua file and expanded data
  consistency coverage for both Era and TBC rules.
- Fixed: two versions of one item ("Notched Shortsword of Magic" / "of
  Healing") were treated as the same item. The keep list and the session
  **Allow** override are now keyed by the item's variant — its random suffix on
  older clients, its bonus ids on 1.60 — and rows show the suffixed name. A
  padlock keeps that exact version; `/de keep #itemid` (and any entry saved by
  an earlier version) still covers every version, and says so on the row.
  `/de keep` also accepts a shift-clicked item link.
- Fixed: nothing was ever written to the audit, the Run Split log, or run
  history on the 1.60 client. Its item links start `|cnIQ2:` rather than a hex
  colour, which the loot matcher rejected.
- Fixed: a material looted either side of a level-up was totalled as two
  separate rows in the split, because links embed the character level.
- **New run** and `/de runs end` now archive what the Run Split tab is showing
  even when no marker was set, instead of discarding disenchants made since
  login. Ending a run leaves a fresh marker, so its drops can't reappear in the
  live split or be archived twice.
- A run with no marker now survives `/reload` and disconnects: the session
  start is saved, and logging back in within 30 minutes resumes it instead of
  restarting the count. `/de tally` is rebuilt from the audit the same way.

## 0.6.0 — 2026-10-31

- Clicking the active disenchant row again now cancels the cast. During the
  cast the row becomes a secure `/stopcasting` action with no bag-slot target.
- Added item/reason filtering, non-color bucket markers, bag/slot tooltip
  details, visible price sources, and reversible session Allow overrides.
- Added approximate disenchant profit display and optional profit sorting when
  Auctionator or TSM has all required market prices.
- Added named run history: starting a new run archives the previous non-empty
  run, with compact summaries retained independently of the capped audit.
- Added an explicit saved-data schema version and validation for run history.
- Audit attribution now closes after the first accepted material loot event;
  trash deletion also verifies hyperlink and binding identity before acting.
- Reworked the window into a compact, resizable meter-style panel shared with
  Summon: slim title bar, state-tinted rows, tighter chrome, and remembered size
  and position. Item rows remain tall enough for explicit safety guidance.
- Added a compatibility module for modern and legacy container APIs.
- Repairs malformed saved-variable fields instead of failing during a scan.
- Trash deletion now verifies that the original stack disappeared before it is
  reported or written to the audit.
- Audit attribution accepts only known or API-classified enchanting materials,
  preventing unrelated personal loot from polluting run splits.
- Expanded automated coverage for compatibility, guards, secure click gates,
  saved data, loot attribution, and deletion, plus a real-client release checklist.

## 0.5.0 — 2026-09-30

- `/de value 0` now genuinely disables the value guard on both tabs.
- Disenchant rows sort by calculated market or vendor value first.
- The secure window is built at login; combat-time opening is deferred.
- Added syntax, upvalue, version-consistency, and smoke tests.
- Documentation now names all supported clients and secure click behavior.

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
