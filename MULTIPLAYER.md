# Local Co-op — fork documentation

This fork adds same-screen (and optional split-screen) local co-op for up to 4 players to
**Super Mario Bros. Remastered**.

Built on and verified against **1.1.0** (upstream tag `1.1-stable`).

It is built to be **re-mergeable with upstream forever**. Everything below exists to keep that
true: new code lives in its own directory, edits to upstream files are tiny and marked, and the
files upstream churns most (level scenes, `TitleScreen.tscn`) are never touched at all.

Upstream: <https://github.com/JHDev2006/Super-Mario-Bros.-Remastered-Public>

---

## 1. What upstream already provides

Most of the plumbing is already there — dormant, but there. Understanding this is the key to
why the fork's patch surface is so small:

| Already in upstream | Where |
| --- | --- |
| Per-player input indirection | `Global.player_action_pressed(action, player_id)` → action `"<action>_<id>"` |
| Per-player power states | `Global.player_power_states` (a 4-character string) |
| Per-player characters | `Global.player_characters` (a 4-element array, defaulting to `[0,1,2,3]`) |
| Player count variable | `Global.connected_players` (never set above 1) |
| Per-player checkpoint labels + colours | `Player._ready()` |
| Player-vs-player head bounce | `Player.on_area_entered()` |
| Multiplayer item launch | `BlockClass.gd` → `PowerUpItem.player_multiplayer_launch_spawn()` — **broken**, bypassed by this fork (§4) |
| **Lead-player camera tracking** | `CameraHandler.handle_camera()` — **new in 1.1**, see §5 |
| Spawn hook | `Level.spawn_in_extra_players()` — **an empty `return` stub** |
| Input actions for players 0–3 | `project.godot` — present but incomplete (see §4) |

Because every gameplay script already routes input through `player_id`, **no gameplay code
needed to change**. Enemies, blocks, pipes, vines, springs, fireballs and power-ups all work
in co-op unmodified.

---

## 2. Design decisions

| Decision | Choice |
| --- | --- |
| Players | Up to 4 |
| Camera | Group-framed shared camera, **plus** split-screen in two orientations (top/bottom, left/right) |
| Zoom | None — the selected resolution is preserved exactly |
| Stragglers | Shoved along by the left screen edge, exactly as in single player. Killed **only** if genuinely crushed between that edge and solid geometry. Shared-screen only |
| Death | Come back in a rescue bubble after the death fall, costing one of **that player's own** lives |
| Lives | Per player. Player 1 keeps using `Global.lives`; players 2-4 are stored in `CoopManager` |
| Characters | Must all be different — the life counters are labelled by character icon |
| Game over / restart | The level restarts when nobody is left in play; a player who dies with no lives left takes upstream's game-over path |
| Player collision | Pass through each other; jumping on a head bounces you (upstream behaviour) |
| Modes | Campaign, Custom Levels, Level Editor playtest |
| Entry point | A **CO-OP** entry appended to the title screen menu |
| Devices | **Controller-only, including player 1.** Every slot starts empty; the first controller to press A becomes P1 |
| Flagpole / pipes | Everyone can take them; the first player starts a window (6s flag, 3s pipe) after which the rest are taken along |

**Why no zoom.** The game renders at a fixed low resolution (1.1 offers 256×240, 320×240 and
426×240, plus per-level `enforce_resolution`). Zooming out to fit spread-out players would break
pixel alignment and reveal level geometry and unspawned entities never meant to be visible.

---

## 3. New files (all additive — zero merge risk)

Everything new lives in `Scripts/Multiplayer/`. **No new `.tscn` files exist**; the lobby and the
split-screen rig are built in code specifically so upstream scene changes can never conflict.

| File | Role |
| --- | --- |
| `CoopManager.gd` | Autoload `Coop`. Session state, slot/device assignment, per-player lives, death & bubble, pipe coordination, shared-camera target, player queries. |
| `CoopInput.gd` | Rebuilds the per-player input actions at runtime, retargeted per device. |
| `CoopSpawner.gd` | Implements the body of `Level.spawn_in_extra_players()`; resets per-level state; installs the camera rig and HUD. |
| `CoopCamera.gd` | Same-screen support: picks the one current camera, advances the smoothed framing target, drives the crush check. |
| `CoopBubble.gd` | The NSMB-style rescue bubble a dead player comes back in. |
| `CoopHud.gd` | Per-player life counters, and the split-screen HUD rearrangement. |
| `CoopSplitScreen.gd` | Optional split-screen rig — one `SubViewport` per player. |
| `CoopLobby.gd` | Controller-join lobby, built in code, styled by cloning a title-screen `Label`. See §5 *Lobby*. |
| `CoopTitleHook.gd` | Injects the **CO-OP** menu entry into the title screen at runtime. |

---

## 4. Modified upstream files

**23 marked regions across 9 script files, plus `project.godot`.** Every edit is wrapped in:

```gdscript
#region MULTIPLAYER
...
#endregion MULTIPLAYER
```

These fold in the Godot editor and are greppable. `tools/coop-sync-check.ps1` verifies they are
all still present, balanced, and the expected count per file.

### `Scripts/Classes/LevelClass.gd` — 1 region
Fills the `spawn_in_extra_players()` stub with a call to `CoopSpawner.spawn(self)`.

### `Scripts/Classes/Entities/Player.gd` — 8 regions
| Function | Change |
| --- | --- |
| `die()` | Routes to `Coop.begin_local_death()` while a teammate is alive. |
| `recenter_camera()` | Drops the shared camera's smoothing history, and also recentres player 1's camera, which is the one actually on screen. |
| `camera_make_current()` | No-op for players 2–4 in shared-camera co-op. |
| `power_up_animation()` | ×2 — skips `get_tree().paused` in co-op, so one player's mushroom doesn't freeze everyone. |
| `enter_pipe()` | ×2 — everyone can climb in; the first entry starts a window, then stragglers are pulled down. |
| `add_stomp_combo()` | The stomp-combo 1-up goes to the player who earned it, not `Global.lives`. |

### `Scripts/Classes/States/Player/Dead.gd` — 3 regions
Adds a `local_death` flag set from the state message, and suppresses the
"press jump to skip" → `death_load()` shortcut for a local death.

### `Scripts/Parts/CameraHandler.gd` — 2 regions
| Function | Change |
| --- | --- |
| `handle_camera()` | Shifts the framing target from upstream's lead player to the group midpoint. |
| `update_camera_barriers()` | Uses the player's own camera in split-screen. |

### `Scripts/Classes/Blocks/BlockClass.gd` — 1 region
Fixes **invisible power-ups in co-op**. Upstream looped over every player in `dispense_item()`
but only ever instantiated one item, so `add_sibling()` was called repeatedly on the same node,
and with 2+ players the co-op branch ran `PowerUpItem.player_multiplayer_launch_spawn()` — which
sets a velocity but never calls `show()`. The item was hidden a line earlier and nothing revealed
it, so every block dispensed a permanently invisible power-up. Now one item is dispensed via
upstream's normal `block_dispense_tween()` and any player can take it. This is upstream's
single-player path verbatim minus the loop, so single player is unchanged.

### `Scripts/Parts/EndFlagpole.gd` — 5 regions
Every player can take the flag, not just the first.

| Region | Change |
| --- | --- |
| `COOP_END_COUNTDOWN` / `coop_flag_taken` | 6-second window and a first-touch latch. |
| `player_touch()` | First grab latches and starts the countdown; later grabs take the short path. |
| `$Hitbox.queue_free()` | Skipped in co-op, or only the first player could ever touch the flag. |
| `coop_late_touch()` / `coop_end_countdown()` | Late grabs get the slide and the points; the countdown force-ends the level. |
| `give_points()` | The top-of-pole 1-up goes to the player who grabbed the flag. |

A straggler who never reaches the flag can no longer hold the finished level open: 6 seconds after
the first grab, the ending is forced through `EndCastle.exit_level()`, which is re-entry safe via
its own static `is_transitioning` flag. If someone walks into the castle first, that wins and the
countdown is a no-op. Players are deliberately **not** frozen here any more — they need to keep
running to reach the flag.

### `Scripts/Classes/Entities/Items/SuperMushroom.gd` — 1 region
The 1-up mushroom credits the player who collected it rather than `Global.lives`.

### `Scripts/UI/CharacterSelect.gd` — 1 region
Auto-skips in co-op: everyone already chose in the lobby, so `open()` hides the panel and emits
`selected` deferred. Covers every entry point (story, World 9, ANN) without touching
TitleScreen.tscn's signal wiring.

### `Scripts/UI/TitleScreenOptions.gd` — 1 region
Adds `signal option_4_selected`. `option_selected()` emits by index, so a fourth menu entry
needs a fourth signal to land on.

### `project.godot` — not markable
`project.godot` is rewritten by the Godot editor using `ConfigFile`, **which strips comments**, so
marker regions cannot survive there. Its changes are documented here instead:

1. **Autoload added** (must remain last, after `Global`, `Settings` and `AudioManager`):
   ```
   Coop="*res://Scripts/Multiplayer/CoopManager.gd"
   ```
2. **`move_down_2` and `move_down_3` added.** Upstream defines 26 of the 28 per-player actions;
   these two were missing, so `Global.player_action_pressed("move_down", 2)` would have errored.
   They are added empty, because `CoopInput` populates slots 1–3 at runtime anyway.
3. **`config/name` renamed** to `"SMB1R Multiplayer"` (upstream: `"SMB1R"`), for the window title.
4. **`editor/export/convert_text_resources_to_binary=false` added.** Required for exported builds
   to work at all — see §8.
5. **`config/custom_user_dir_name="SMB1R"` added.** With `use_custom_user_dir=true`, Godot derives
   the data directory from `config/name` unless this is set — so the rename in (3) would otherwise
   send the fork to `%APPDATA%\SMB1R Multiplayer`, a fresh directory with no ROM and no generated
   assets. This pins it back to `%APPDATA%\SMB1R`, sharing the ROM, generated asset pack, saves,
   settings, resource packs and mods with the official build.

   **Consequence:** the fork and the official build share save files. Co-op does not change the
   save format, but the two do write to the same `saves/` directory. If you ever need them
   separated again, remove this line — and remember to copy `baserom.nes` and
   `resource_packs/BaseAssets` into the new directory, or the game will boot to the ROM
   asset generator instead of the title screen.

**Player 0's bindings are untouched**, so upstream's defaults and the settings menu still own them.

---

## 5. How it works

### Input
**Co-op is controller-only, for every player including player 1.** Slots all start empty and are
claimed in order by whichever controller presses A first, so the first controller in becomes P1.

`CoopInput.apply()` rebuilds every slot by **cloning slot 0's controller bindings** and retargeting
each copy to that slot's device. Consequences worth knowing:

- All players inherit the layout configured for player 1, **including remaps** made in the settings
  menu (which only ever writes to the `_0` actions).
- There is no second binding table to maintain.
- Keyboard events are dropped from all 28 per-player actions for the duration of a session. This is
  also what stops every pad driving player 1 at once, since upstream binds player 0 to device `-1`
  ("any device").
- Unoccupied slots get **no** bindings, so a stale mapping can never move an absent player.
- The keyboard can still pause and navigate menus — `pause`, `ui_accept` and friends are not
  per-player actions and are never touched. In the lobby, Escape backs out, so opening it on a
  keyboard with no controllers connected is recoverable rather than a soft-lock.

`Coop.start_session()` snapshots the pristine input map first; `end_session()` restores it exactly.
Returning to the title screen always ends the session.

### Camera — note what changed in 1.1

**1.1 rewrote `CameraHandler`, and it now scans the whole `Players` group and converges on a
single lead player.** Every player's handler therefore computes the same camera position, which is
most of a same-screen camera for free. Upstream effectively ships lead-player co-op camera
tracking now.

This fork adds only what is left:

1. `CoopCamera` leaves player 1's camera as the only enabled one, so the view does not depend on
   which player node entered the tree first.
2. `CoopCamera` kills a player only when the advancing left edge genuinely **crushes** them
   (`Coop.crush_check`) — pinned against the edge with solid geometry immediately to their right.
   Falling behind just shoves them along via their own left barrier wall, which is upstream's
   normal screen-edge behaviour and needs no change. Split-screen never runs this: each player
   has their own view and cannot be left behind.
3. One marked hook in `handle_camera()` shifts the target from the lead player to
   `Coop.shared_camera_target_x()` — the group midpoint — so a trailing player stays on screen
   instead of only the leader. It runs after upstream's scrolling and before `do_limits()`, so
   level bounds still clamp normally.

> **Historical note.** The 1.0.2 version of this fork shipped a standalone `GroupCamera` that
> reimplemented scrolling, offsets and level limits. Upstream then rewrote all of that in 1.1,
> which would have left the copy silently stale. It was deleted and replaced with the three hooks
> above. **If you ever find yourself duplicating upstream camera logic again, don't** — hook it.
>
> If you would prefer upstream's plain lead-player framing over group framing, delete the
> `handle_camera()` region and everything else keeps working.

**Split-screen.** One `SubViewport` per player sharing the level's `World2D`. 3–4 players use a
2×2 grid, with the last cell left blank at 3. 2 players can go either way, cycled in the lobby:

| Orientation | Panes | Trade-off |
| --- | --- | --- |
| Top/bottom | 426×120 | Full horizontal warning distance, but only half the level height, so the camera has to scroll vertically. |
| Left/right | 426×240 each | Full level height, so the vertical camera is pinned exactly as in single player — the calmest option — at half the horizontal warning distance. |

**Pane cameras must not mirror `player.camera`.** Upstream's `CameraHandler` scans the whole
Players group and converges *every* player's camera on the single lead player, so copying it gave
every pane the leader's view — the panes looked frozen relative to their own player and started
framed on somebody else. Each pane therefore tracks its own player directly, using upstream's own
horizontal rule: pin the player at centre while advancing, hold still when they back up unless the
level allows backscrolling.

**The pane camera needs upstream's vertical deadzone.** It originally tracked `player.y` 1:1 every
frame, which moved the view the full height of every jump and read as a violent bounce in a
half-height pane. It now uses the same rule as `CameraHandler.handle_vertical_scrolling()`: leave
the camera alone until the player crosses out of a band around it, then creep back slowly while
they are grounded. Each pane keeps its own remembered `camera_y`, and the slack is capped to the
pane so a short pane cannot let the player leave the view before the camera reacts. Measured: a
51px hop now moves the camera **0px**, while a 140px climb still moves it 38px.

This runs in `_physics_process`, not `_process` — the catch-up is a fixed step per tick, so at
render rate its speed depended on framerate.

**Multi-column layouts enlarge the root render target.** Four quarter-size panes would each show
only a quarter of the normal view — the world at 1:1 in a 213×120 window, which reads as a 2×
zoom-in. Instead `content_scale_size` is set to `base × grid` (2×2 → 852×480, side-by-side →
852×240), so every pane is a **full-size game display at native resolution** rather than a
cropped or downscaled one. Top/bottom at 2 players is the one layout that does not do this, which
is why its panes are 426×120.
The original value is restored when the rig leaves the tree. A black `Backdrop` fills anything the
panes do not cover, including the empty 3-player cell — the root viewport still renders the world
behind the panes and would otherwise show through as an unlabelled fourth view.

Side effect: because the canvas is larger, the HUD draws smaller relative to the screen in the
enlarged layouts. That is normal for split-screen and leaves more room, but it is a visible
change if you are comparing against top/bottom. The HUD's `layer` is raised from 0 to 2 for
the duration and restored afterwards, because it otherwise draws underneath the panes.

Two more things about the panes are load-bearing:

- **Clamps are redone against the pane's own size.** `CameraHandler.do_limits()` clamps against
  `get_viewport_rect()` — the *root* viewport — so its Y is only right for a full-height view.
  Used in a 120px-tall pane it framed the top half of the level and left the players below it.
- **The SubViewports must be told about pixel snapping and nearest filtering.**
  `snap_2d_transforms_to_pixel`, `snap_2d_vertices_to_pixel` and the default texture filter are
  *project* settings that apply to the root viewport only; a `SubViewport` created at runtime does
  not inherit them, and without them the panes render soft and smeared.

### Lives
Lives are **per player**. Player 1 deliberately keeps using `Global.lives`, so upstream's HUD row,
save data and game-over checks all keep working untouched; players 2-4 live in `CoopManager`.
`Coop.get_lives()` / `set_lives()` / `add_lives()` hide the split, and 1-ups are credited to
whoever earned them (stomp combo, mushroom, flagpole).

Two 1-up sites are deliberately left on `Global.lives`, because neither has a player reference to
credit: `ShellClass.award_score()` and `EndCastle`'s firework bonus. Both therefore go to player 1.

The lobby refuses to start while two players share a character, since each life counter is
labelled only by its character icon — duplicates would give the HUD two identical rows.

### The HUD
`CoopHud` clones upstream's `ModernHUD/TopLeft/LifeCount` row (icon + count) once per *extra*
player, so the font, shadow shader and icon pipeline stay whatever upstream is using. Player 1
keeps upstream's own row.

- **Shared camera:** the clones stack directly beneath player 1's row in the top-left.
- **Split-screen:** each row is parked at its own pane's top-left, at the same offset player 1's
  row has inside pane 0 (measured each frame, not hard-coded, so HUD scale changes keep them
  aligned). The counters that are the same
  for everybody — score, time, coins — are shown once rather than per pane, and go where there is
  spare room:
  - **2 and 4 players** (full grid): the very top-right of the whole screen.
  - **3 players**: centred in the empty bottom-right cell, via
    `CoopSplitScreen.blank_cell_rect()`.

  Two traps here. The groups have **different parents** — the coin counter lives under
  `ModernHUD/TopLeft`, score/time directly under `ModernHUD` — so equal `position` values put them
  in different places on screen; everything is done in *global* space. And the score/time group is
  32px tall, so stacking the coins one 16px row below it drew them straight through its middle:
  the stack is laid out from the groups' measured `size` instead of fixed offsets.

These positions are re-applied every frame *after* upstream's own HUD update, which works because
the GameHUD autoload sits earlier in the tree than the level that owns `CoopHud`. Original
positions are restored when the rig leaves the tree. Note the life counters only exist on the
**modern** HUD — the classic HUD has no life display at all, upstream or otherwise.

### Shared camera smoothing
The framing target is the midpoint of the players currently *in play*, so it steps discontinuously
whenever someone enters or leaves that set — a death, a bubble, a pipe, a flagpole. Fed straight
to the camera that reads as a sideways jolt.

`Coop.update_shared_target()` eases across those steps, but **snaps whenever the target is already
close** (within 8px). Smoothing unconditionally would lag the camera behind the group the whole
time in proportion to running speed; the midpoint only shifts ~3px a frame at full speed, so
anything past the threshold means the set changed and that is the only case worth easing. Measured:
a player dropping out moves the target 100px, with a largest single-frame step of 15px instead of
the whole 100 at once.

It is advanced once per tick from `CoopCamera`, not from `shared_camera_target_x()` — that is
called separately by every player's `CameraHandler`, so smoothing there would advance several
times a frame and the rate would depend on how many players were alive. A `recenter_camera()`
drops the history, so deliberate jumps (checkpoints, pipe exits, level starts) are not eased.

### Pipes
Pipes work like the flagpole: everyone can climb in. The first player down latches the pipe and
replaces upstream's flat one-second wait with a 3-second window, during which the others are left
free to reach it themselves and follow in without starting a second warp. When the window closes,
anyone still in the level is pulled down too — so one straggler cannot strand the group — with a
short beat afterwards so their animation is seen before the scene changes.

### Death and the rescue bubble
`Coop.begin_local_death()` runs the death animation without pausing the tree and deducts one of
**that player's own** lives. Once the player has fallen off screen (2s) they come back in a **rescue bubble**
above the nearest player still in play, as in New Super Mario Bros:

- The bubble drifts on its own. Its owner taps **jump** to nudge it toward the nearest free
  player, with ±0.5 rad of random spread per tap — so it has to be spammed and wanders rather
  than homing cleanly.
- It stays inside its owner's view, and **pops on contact** with a free player, handing control
  back with i-frames and Small power.
- While bubbled the player is intangible: `collision_mask` is zeroed **and** the `Hitbox` area is
  switched off. The body sits on no collision layer of its own (`Player.tscn` has
  `collision_layer = 0`), so items, enemies and hazards all route through that area — zeroing the
  mask alone is not enough.
- Bubbled players are in the `Freeze` state, which is already in `NON_GAMEPLAY_STATES`, so they
  are automatically skipped by camera framing and the crush check.

**A bubbled player does not count as a survivor.** `should_local_death()` tests `free_players()`
(alive, un-bubbled, in gameplay), so when the last player still in play dies there is nobody left
to rescue them, upstream's `die()` runs its normal course, and the level restarts. That is the
"everyone bubbled or dead at once" rule, and it needs no separate check. The same fall-through
happens when a player dies with **no lives of their own left**: they get no bubble, and upstream's
game-over handling takes over for the whole group.

Two ordering traps worth remembering:

- The stored collision mask is consumed on restore, so it must only be restored when the bubble
  **pops** — restoring it on bubble entry left the freed player at mask 0, falling through the
  floor into a second death.
- The `Hitbox` is re-enabled explicitly (deferred `monitoring`/`monitorable`); without it a freed
  player cannot collect items or take damage. Do **not** call `Player.refresh_hitbox()` after it:
  that reads overlaps immediately, before the deferred set lands, and errors with "Can't find
  overlapping areas when monitoring is off". Overlapping areas fire `area_entered` on their own
  once the hitbox is monitorable again.

### Lobby
- **Custom characters are scanned on open.** Upstream only scans `custom_characters/` inside
  `CharacterSelect.get_custom_characters()`; the lobby runs that same function on a detached
  instance (it touches only statics), so customs appear without visiting the vanilla screen first.
  Slots pointing past the end of the list (a deleted custom character) reset to 0.
- **Joining picks a free character.** Saved settings usually leave every slot on the same
  character, which the duplicate rule would otherwise dead-end on, so `Coop.claim_slot()` moves a
  joining player onto the first character nobody has.
- **Duplicates block the start** and are shown in red with `(TAKEN)`.
- **Camera mode** is cycled by P1's d-pad up/down: same screen → split top/bottom → split
  left/right. Upstream's final character-select screen is then skipped (§4, `CharacterSelect.gd`).
- **Stay inside the font.** `Assets/Sprites/UI/Font.fnt` has no lowercase, no `<`, `=` or `>`,
  and no arrows — they render as missing-glyph boxes. It does have `«`/`»` (171/187) and `∞`.

### Title screen
`TitleScreen.tscn` wires its menu **by position**: `TitleScreenOptions.option_selected()` emits
`option_<index + 1>_selected` and the scene connects those signals to specific nodes. The co-op
entry is therefore **appended last** (becoming `option_4_selected`) so no existing index shifts,
and it is injected at runtime by `CoopTitleHook` rather than by editing that ~1700-line scene.
Starting a session hands straight over to the normal `CampaignSelect` flow.

---

## 6. Syncing with upstream

This fork currently tracks the **`1.1`** branch, not `main`. Upstream also tags each release on
that branch (`1.1-rc4`, `1.1-stable`, ...); to move to a release rather than the branch tip, merge
the tag instead, and check against it with `-Ref`.

```bash
git fetch upstream --tags
```

```bash
pwsh tools/coop-sync-check.ps1 -Branch 1.1
```

```bash
pwsh tools/coop-sync-check.ps1 -Ref 1.1-stable
```

It reports how far behind upstream you are, which upstream-changed files overlap this fork's
edits, and verifies every `#region MULTIPLAYER` is still present with the expected count. It fails
loudly if the upstream ref is missing rather than pretending you are up to date.

**Conflicts are expected only in the 9 script files in §4 (plus `project.godot`).** Because each edit is a small marked block,
resolving a conflict is normally "keep both sides": take upstream's version of the function, then
re-insert the marked region. If upstream rewrites one of these functions substantially, §4 tells
you exactly what the region was for so it can be re-applied deliberately.

**Watch for specifically:**
- `spawn_in_extra_players()` gaining a real upstream implementation — if upstream ships their own
  co-op, this fork should be retired rather than merged. The sync script warns about this.
- Changes to `Player.die()` / `death_load()` — the local-death branch must stay immediately after
  the existing state guard.
- Changes to `CameraHandler` — upstream is actively working on it (it was rewritten between 1.0.2
  and 1.1). Re-check its two regions after any camera-related upstream change, and remember the
  split-screen pane cameras copy its constants (deadzone, offset, level bounds) in
  `CoopSplitScreen.gd`.
- Renamed or re-tiered physics params. The 1.0.2→1.1 port broke on exactly this: `FALL_GRAVITY`
  became `FALL_GRAVITY_IDLE`/`_WALK`/`_RUN`, resolved through `calculate_speed_param()`.
- New per-player actions added to `PLAYER_ACTIONS` in `CoopInput.gd` if upstream adds a gameplay
  input (that list must match the `_0`-suffixed actions in `project.godot`).
- `project.godot` autoload order — `Coop` must stay after `Global`, `Settings` and `AudioManager`.
- HUD node paths `ModernHUD/TopLeft/LifeCount`, `ModernHUD/TopLeft/CoinCount` and
  `ModernHUD/Right` in `GameHud.tscn` — `CoopHud` clones and moves them by path.

---

## 7. Testing

There is no automated test suite; each change was verified with a temporary probe scene (headless,
or windowed for screenshots) run against **Godot 4.6.3-stable**, then removed. Re-run on 1.1.0 after
the RC4 → stable upgrade. Confirmed that way:

- **Spawning & input:** players spawn with correct ids, characters and power states; each slot's
  actions respond only to its own pad; zero keyboard events across the 28 per-player actions during
  a session; `end_session()` restores the original map.
- **Lobby:** CO-OP appended as the 4th title entry; first controller claims slot 0; joining assigns
  distinct characters; duplicates block the start; custom characters listed without visiting the
  vanilla screen; no missing glyphs.
- **Shared camera:** only player 1's camera enabled; a player dropping out moves the target 100px
  with a largest per-frame step of 15px; the crush check kills only a player pinned against
  geometry.
- **Split-screen:** each pane tracks its own player, not the leader; a 51px hop moves the pane
  camera 0px; 2×2 and side-by-side panes are full 426×240 views; the 3-player blank cell is black;
  shared counters sit top-right or in the blank cell; rendering is crisp.
- **Deaths:** the bubble spawns above the nearest free player, carries its owner, pops on contact
  and restores `Normal` state, collision mask and hitbox; the last free player dying restarts the
  level.
- **Lives:** per-player counts are independent and player 1 mirrors `Global.lives`; HUD rows stack
  in shared mode and sit per pane in split.
- **Flag & pipes:** several players can take the flag or enter a pipe; stragglers are pulled down
  when the pipe window closes.
- **Items:** power-ups from blocks are visible in co-op.
- **Single player is unaffected:** `connected_players=1`, one player, no camera rig, no HUD
  additions, input map untouched, character select opens normally.

---

## 8. Known upstream issue — exported builds need `convert_text_resources_to_binary=false`

**Not a co-op issue, but it will bite anyone building this fork.** Without the project setting
below, an exported build black-screens on boot with no disclaimer screen.

Godot's export-time text→binary scene conversion drops any node property whose name ends in `/`.
Every AnimationPlayer in this project uses the default, *empty-named* animation library, stored as
the property `libraries/` — so **all 56 animation libraries are stripped from the .pck**. The first
thing to touch one (`Disclaimer.gd:14`) throws inside `_ready()`, so the disclaimer never plays,
its `animation_finished → go_to_menu` connection never fires, and the boot sequence dies:

```
[source]  AnimationPlayer properties = ["libraries/", "autoplay"]   animations=[Go, RESET]
[in .pck] AnimationPlayer properties = ["autoplay"]
```

### The fix (already applied in `project.godot`)

```
[editor]
export/convert_text_resources_to_binary=false
```

**After changing it, delete `.godot/exported/` once.** Godot caches converted scenes there and
will happily ship the already-broken conversions otherwise — this is what made the setting look
ineffective on the first attempt. With conversion disabled, nothing accumulates in that cache
again.

Cost: the .pck grows about 3% (57.6 MB → 59.2 MB) and text scenes parse slightly slower than
binary at runtime. Nothing measurable in practice.

### Ruled out by testing

| Suspect | Result |
| --- | --- |
| This fork's co-op code | **Not it** — reproduces on a pristine upstream export with all co-op code removed |
| Godot version | **Not it** — reproduces identically on 4.6-dev4 *and* 4.6.3-stable |
| ModLoader's export plugin | Not it — reproduces with it disabled (and it only processes GDScript) |
| Any other export plugin | None exist in the project |
| Export template mismatch | Not it — templates matched the editor in both versions |
| Stale `.godot/exported/` cache alone | Not it on its own — but it *masks* the fix, see above |

Note the conversion bug is specific to Godot's `convert_file_to_binary` path used by the exporter.
A plain `load()` + `ResourceSaver.save()` round-trip to `.scn` preserves the library correctly,
which is why this never shows up when running from the editor.

---

## 9. Known limitations

- **Not supported in Marathon, Challenge, Boo Race or Disco.** These have single-player scoring,
  ghost recording and leaderboard logic; `Coop.supported_game_modes()` gates them out, and any
  session started there runs as single player.
- **Score, coins and time are shared**, matching upstream's globals. Lives are per player (§5).
- **Two 1-up sources still credit player 1** — shell combos and the castle firework bonus have no
  player reference to credit (§5, *Lives*).
- **Per-player life counters exist only on the modern HUD.** The classic HUD has no life display.
- **One player running out of lives ends the run for everyone**, via upstream's game-over path;
  there is no per-player elimination.
- **Split-screen renders the world once per pane**, so 4-player split is roughly 4× the 2D draw cost.
- **Enlarged split layouts letterbox** on a 16:9 window (852×480 and 852×240 are not 16:9).
- **Co-op sessions are not saved.** Player count and controller assignment reset on returning to
  the title screen, by design.
- **Speedrun input simulation is not co-op aware.** `Global.player_action_pressed` swaps in a
  `"s"` player id when `SpeedrunHandler.simulating_inputs` is set; co-op does not touch that path.
