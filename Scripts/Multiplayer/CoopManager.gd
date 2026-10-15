extends Node

## Local co-op session state. Registered as the autoload `Coop`.
##
## Upstream SMB1R already threads `player_id` through input, power states, characters and
## checkpoints, and `Level.spawn_in_extra_players()` exists as an empty stub. This singleton
## supplies the parts that were never written: who is playing, which controller drives which
## player, how the camera is shared, and what happens when one player dies.
##
## Everything here is inert while `Global.connected_players == 1`, so single-player behaviour is
## byte-for-byte upstream's.

const MAX_PLAYERS := CoopInput.MAX_PLAYERS
const DEVICE_NONE := CoopInput.DEVICE_NONE

## Colours used for player number labels, matching the checkpoint labels in Player.gd `_ready`.
const PLAYER_COLOURS := [Color("5050FF"), Color("F73910"), Color("1A912E"), Color("FFB762")]

enum CameraMode {
	SHARED,            ## One camera framing every living player at the native resolution.
	SPLIT_STACKED,     ## Split-screen, 2 players one above the other.
	SPLIT_SIDE_BY_SIDE,## Split-screen, 2 players left and right.
}

## Kept so older references and saved settings still resolve to a working mode.
const SPLIT_SCREEN := CameraMode.SPLIT_STACKED

## Labels for the lobby's camera toggle.
const CAMERA_MODE_NAMES := ["SAME SCREEN", "SPLIT - TOP/BOTTOM", "SPLIT - LEFT/RIGHT"]

## Seconds a locally-dead player spends falling off the screen before their bubble appears.
const RESPAWN_DELAY := 2.0

## Grace window after the first player enters a pipe - the pipe's equivalent of the flagpole's
## countdown, but shorter, since nobody is racing to a pole - before
## everyone still in the level is taken down with them.
const PIPE_FOLLOW_WINDOW := 3.0
## Beat after the stragglers are pulled in, so their pipe animation is seen before the warp.
const PIPE_PULL_IN_TIME := 0.8

## Where a rescue bubble appears relative to the player it is anchored on.
const BUBBLE_SPAWN_OFFSET := Vector2(0, -72)
## How close to the left screen edge a player must be to count as pinned against it. Roughly a
## player half-width, since their origin sits at their centre.
const CRUSH_EDGE_GRACE := 14.0
## How far to the right a pinned player must be blocked before it counts as a crush.
const CRUSH_PROBE_DISTANCE := 3.0

## Rate the shared camera's framing target eases toward the group midpoint, per second. High
## enough to be invisible during normal play, low enough to absorb a player entering or leaving
## the framing set.
const SHARED_TARGET_SMOOTHING := 10.0
## Below this gap the target is taken as-is, so ordinary movement has no camera lag at all. The
## group midpoint shifts about 3px a frame at full running speed, well inside this.
const SHARED_TARGET_SNAP := 8.0

var camera_mode: CameraMode = CameraMode.SHARED

## One entry per slot: a joypad device id, or DEVICE_NONE.
##
## Every slot starts empty, including player 1 - co-op is controller-only, so player 1 is claimed
## by the first controller to press a button in the lobby, exactly like the others.
var slot_devices := [DEVICE_NONE, DEVICE_NONE, DEVICE_NONE, DEVICE_NONE]

## Pristine per-player bindings, captured before the session retargeted anything.
var _binding_template := {}
var _bindings_applied := false

## Collision masks captured when a player entered a local death, keyed by player instance id.
var _stored_collision_masks := {}

## Active rescue bubbles, keyed by player_id.
var _bubbles := {}

## Smoothed framing target for the shared camera. NAN means "not seeded yet".
var _shared_target_x := NAN

## Set once a player has entered a pipe in this level; later entries follow rather than re-warp.
var _pipe_taken := false

## Lives for players 2-4. Player 1 deliberately keeps using `Global.lives`, so upstream's HUD
## row, save data and game-over checks all keep working with no changes; only the extra players
## need storage of their own.
var _extra_lives := [0, 0, 0]

signal slots_changed
signal session_started
signal session_ended
signal player_locally_died(player: Player)
signal player_bubbled(player: Player)
signal player_respawned(player: Player)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	# Adds the co-op entry to the title screen whenever one loads, without touching its .tscn.
	var title_hook := CoopTitleHook.new()
	title_hook.name = "CoopTitleHook"
	add_child(title_hook)


#region Session lifecycle

## Game modes co-op is allowed in. Everything else forces single player.
## Not a const: `Global` is an autoload instance, so `Global.GameMode` resolves at runtime and
## cannot be constant-folded into a `const` declaration.
func supported_game_modes() -> Array:
	return [
		Global.GameMode.CAMPAIGN,
		Global.GameMode.CUSTOM_LEVEL,
		Global.GameMode.LEVEL_EDITOR,
	]


## True when more than one player is in the current session.
func is_active() -> bool:
	return Global.connected_players > 1


## True when co-op may run in the mode currently being played.
func mode_supports_coop() -> bool:
	return supported_game_modes().has(Global.current_game_mode)


## The split-screen rig for the current level, or null when it is not in use.
func split_screen() -> CoopSplitScreen:
	if Global.current_level == null:
		return null
	return Global.current_level.get_node_or_null("CoopSplitScreen") as CoopSplitScreen


## True when the shared camera should be doing group framing.
func is_shared_camera() -> bool:
	return is_active() and camera_mode == CameraMode.SHARED


## True for either split-screen orientation. Prefer this over comparing the enum, so adding
## another layout does not mean hunting down every comparison.
func is_split_screen() -> bool:
	return camera_mode != CameraMode.SHARED


## True when 2 players should sit side by side rather than stacked. Only meaningful at 2 players;
## 3 and 4 always use the 2x2 grid.
func is_side_by_side() -> bool:
	return camera_mode == CameraMode.SPLIT_SIDE_BY_SIDE


## The view size one player gets, before any split-screen grid enlargement. Used to size the
## split panes and to keep rescue bubbles inside their owner's view.
func base_view_size() -> Vector2i:
	if Global.current_level != null and Global.current_level.enforce_resolution != Vector2.ZERO:
		return Vector2i(Global.current_level.enforce_resolution)
	var idx: int = clampi(Settings.file.video.size, 0, Global.RESOLUTIONS.size() - 1)
	return Vector2i(Global.RESOLUTIONS[idx])


func occupied_slots() -> Array[int]:
	var slots: Array[int] = []
	for slot in MAX_PLAYERS:
		if slot_devices[slot] != DEVICE_NONE:
			slots.append(slot)
	return slots


func slot_count() -> int:
	return maxi(occupied_slots().size(), 1)


## Applies the current slot assignment to the input map and to `Global.connected_players`.
## Call once the lobby is confirmed, before the first level loads.
func start_session() -> void:
	if _binding_template.is_empty():
		_binding_template = CoopInput.snapshot()
	CoopInput.apply(slot_devices, _binding_template)
	_bindings_applied = true
	Global.connected_players = slot_count()
	_stored_collision_masks.clear()
	_bubbles.clear()
	# Everyone starts with the same allowance the single-player run would have had.
	for i in _extra_lives.size():
		_extra_lives[i] = Global.lives
	session_started.emit()


## Returns to single player and restores the input map exactly as it was.
func end_session() -> void:
	if _bindings_applied:
		CoopInput.restore(_binding_template)
		_bindings_applied = false
	slot_devices = [DEVICE_NONE, DEVICE_NONE, DEVICE_NONE, DEVICE_NONE]
	Global.connected_players = 1
	_stored_collision_masks.clear()
	session_ended.emit()


## Re-applies bindings after something else rewrote the input map - for example the settings
## menu, which reloads player 0's bindings from disk and would otherwise undo the retargeting.
func reapply_bindings() -> void:
	if _bindings_applied:
		CoopInput.apply(slot_devices, _binding_template)

#endregion


#region Slot assignment

## Claims the first free slot for a device. Returns the slot, or -1 if the device is already
## assigned or the session is full.
func claim_slot(device: int) -> int:
	if slot_devices.has(device):
		return -1
	for slot in MAX_PLAYERS:
		if slot_devices[slot] == DEVICE_NONE:
			slot_devices[slot] = device
			_assign_free_character(slot)
			slots_changed.emit()
			return slot
	return -1


## Moves a newly joined player onto a character nobody else has taken.
##
## Saved settings usually leave every slot on the same character, and the lobby refuses to start
## while two players share one - so without this, joining would immediately dead-end and everyone
## would have to cycle off Mario by hand before the game could begin.
func _assign_free_character(slot: int) -> void:
	var taken := []
	for other in occupied_slots():
		if other != slot:
			taken.append(int(Global.player_characters[other]))
	if not taken.has(int(Global.player_characters[slot])):
		return
	var characters: Array = Global.player_characters.duplicate()
	for candidate in Player.CHARACTERS.size():
		if not taken.has(candidate):
			characters[slot] = candidate
			Global.player_characters = characters
			return


func release_slot(slot: int) -> void:
	# Slot 0 is releasable too: it is an ordinary controller slot now, not the keyboard.
	if slot < 0 or slot >= MAX_PLAYERS:
		return
	slot_devices[slot] = DEVICE_NONE
	slots_changed.emit()


func slot_for_device(device: int) -> int:
	return slot_devices.find(device)


func device_label(slot: int) -> String:
	var device: int = slot_devices[slot]
	if device == DEVICE_NONE:
		return ""
	var joy_name := Input.get_joy_name(device)
	return joy_name if joy_name != "" else "Controller " + str(device)


func _on_joy_connection_changed(device: int, connected: bool) -> void:
	if connected:
		return
	var slot := slot_for_device(device)
	if slot >= 0:
		release_slot(slot)
		reapply_bindings()

#endregion


#region Lives

## Lives remaining for one player. Player 1 reads straight from `Global.lives`.
func get_lives(player_id: int) -> int:
	if player_id <= 0:
		return Global.lives
	return _extra_lives[player_id - 1]


func set_lives(player_id: int, value: int) -> void:
	if player_id <= 0:
		Global.lives = value
	else:
		_extra_lives[player_id - 1] = value


func add_lives(player_id: int, amount: int) -> void:
	set_lives(player_id, get_lives(player_id) + amount)

#endregion


#region Player queries

func players() -> Array:
	if not is_inside_tree():
		return []
	return get_tree().get_nodes_in_group("Players")


func living_players() -> Array:
	return players().filter(func(p: Player): return is_instance_valid(p) and not p.is_dead)


## The player furthest along the level.
func lead_player() -> Player:
	var best: Player = null
	for player in living_players():
		if best == null or player.global_position.x > best.global_position.x:
			best = player
	return best


func player_for_slot(slot: int) -> Player:
	for player in players():
		if player.player_id == slot:
			return player
	return null


## States where the player is not under their own control and should neither pull the shared
## camera around nor be counted as a straggler. "Stunned" is deliberately absent: a stunned
## player can still be left behind and should still die, or they would be stranded off-screen
## with no way back into play.
const NON_GAMEPLAY_STATES := ["Pipe", "FlagPole", "LevelExit", "Dead", "Freeze", "PipeCutscene"]


func is_in_gameplay(player: Player) -> bool:
	if not is_instance_valid(player) or player.is_dead:
		return false
	if player.state_machine == null or player.state_machine.state == null:
		return false
	return not NON_GAMEPLAY_STATES.has(player.state_machine.state.name)


## Players the shared camera should frame. Falls back to everyone still alive so the camera
## never loses its subject during a level-ending cutscene.
func framing_players() -> Array:
	var active := living_players().filter(is_in_gameplay)
	return active if not active.is_empty() else living_players()


## Parks every other player when one of them triggers something that ends the level - a
## flagpole or a pipe warp. Without this the rest keep running during the outro and can drown,
## fall in a pit, or be killed as stragglers by the shared camera.
func freeze_others(except_player: Player) -> void:
	if not is_active():
		return
	for player in living_players():
		if player == except_player:
			continue
		if NON_GAMEPLAY_STATES.has(player.state_machine.state.name):
			continue
		player.velocity = Vector2.ZERO
		player.state_machine.transition_to("Freeze")

#endregion


#region Shared camera

## Horizontal midpoint of the players the camera should be framing.
##
## Upstream 1.1's CameraHandler already converges every player's handler on a single "lead"
## player (the furthest ahead), which is most of a same-screen camera on its own. This shifts
## the target from that lead player to the midpoint of the group, which is what keeps both a
## leading and a trailing player on screen instead of only the leader.
##
## Returns NAN when there is nothing to frame, so the caller leaves upstream's value alone.
##
## This is the *smoothed* value. The raw midpoint jumps the moment the set of framed players
## changes - a death, a bubble, a pipe, a flagpole all remove someone instantly - and feeding that
## straight to the camera snaps the view sideways. [method update_shared_target] eases it.
func shared_camera_target_x() -> float:
	return _shared_target_x


## Advances the smoothed framing target. Driven once per physics tick by [CoopCamera], rather
## than from `shared_camera_target_x()`, which every player's CameraHandler calls separately -
## smoothing there would advance several times per frame and the rate would depend on how many
## players were alive.
func update_shared_target(delta: float) -> void:
	var framed := framing_players()
	if framed.is_empty():
		return
	var min_x := INF
	var max_x := -INF
	for player in framed:
		min_x = minf(min_x, player.global_position.x)
		max_x = maxf(max_x, player.global_position.x)
	var raw := (min_x + max_x) / 2.0

	if is_nan(_shared_target_x):
		_shared_target_x = raw
		return

	# Snap while the target is already tracking, ease only across a discontinuity.
	#
	# Smoothing unconditionally would lag the camera behind the group the whole time, by an amount
	# proportional to how fast they are running. The midpoint only ever moves a couple of pixels
	# per frame during normal play, so anything past the threshold means the *set* changed - a
	# death, a bubble, a pipe, a flagpole - and that is the only case worth easing.
	if absf(raw - _shared_target_x) <= SHARED_TARGET_SNAP:
		_shared_target_x = raw
	else:
		_shared_target_x = lerpf(_shared_target_x, raw, 1.0 - exp(-SHARED_TARGET_SMOOTHING * delta))


## Drops the smoothing history, so a new level or a warp starts framed rather than easing in from
## wherever the last one ended.
func reset_shared_target() -> void:
	_shared_target_x = NAN


## Kills a player who is actually being crushed by the advancing left edge of the shared screen.
##
## A player left behind is simply *shoved* along by their own left barrier wall, exactly as the
## screen edge behaves in single player - being slow is not fatal. They only die when that wall
## has nowhere left to push them: pinned against the screen edge with solid level geometry
## immediately to their right.
##
## Split-screen never calls this, since each player has their own view and cannot be left behind.
## Driven by [CoopCamera].
func crush_check(left_edge: float) -> void:
	for player in living_players():
		if not is_in_gameplay(player):
			continue
		# Must actually be up against the advancing edge.
		if player.global_position.x > left_edge + CRUSH_EDGE_GRACE:
			continue
		# ...and have nowhere to be pushed to.
		if player.test_move(player.global_transform, Vector2(CRUSH_PROBE_DISTANCE, 0)):
			player.die(false)

#endregion


#region Pipes

## True once somebody has already gone down the pipe this level, so later entries just follow
## them in rather than each starting their own warp.
func pipe_already_taken() -> bool:
	return _pipe_taken


## A player reaching the pipe after someone else already went down it. They get the same entry
## animation, but no second warp - the countdown started by the first player owns that.
func follow_into_pipe(player: Player, pipe: PipeArea) -> void:
	if NON_GAMEPLAY_STATES.has(player.state_machine.state.name):
		return
	player.z_index = -10
	player.can_bump_sfx = false
	player.pipe_enter_direction = pipe.get_vector(pipe.enter_direction)
	if player.pipe_enter_direction.x != 0:
		player.global_position.y = pipe.global_position.y + 14
	AudioManager.play_sfx("pipe", player.global_position)
	player.state_machine.transition_to("Pipe")
	player.hide_pipe_animation()


## Latches the pipe so later entries follow rather than starting their own warp.
func mark_pipe_taken() -> void:
	_pipe_taken = true


## Replaces the flat one-second wait before a pipe warp. Holds the level open long enough for the
## others to climb in themselves, then pulls in whoever is left so one straggler cannot strand
## the group, and gives their animation a beat to play before the scene changes.
func await_pipe_window(pipe: PipeArea) -> void:
	await get_tree().create_timer(PIPE_FOLLOW_WINDOW, false).timeout
	if not is_inside_tree():
		return
	var pulled := false
	for player in living_players():
		if is_in_gameplay(player):
			follow_into_pipe(player, pipe)
			pulled = true
	if pulled:
		await get_tree().create_timer(PIPE_PULL_IN_TIME, false).timeout


## Cleared whenever a level is entered, since `_pipe_taken` is session-wide state about a pipe
## that no longer exists.
func reset_pipe_state() -> void:
	_pipe_taken = false

#endregion


#region Death and respawn

## True when this death should be a local one - the player comes back in a rescue bubble rather
## than the level ending for everybody.
##
## A bubbled player does **not** count as a survivor. So when the last player still in play dies,
## this returns false, upstream's `die()` runs its normal course and the level restarts - which
## is the "everyone is bubbled or dead at once" rule.
func should_local_death(player: Player) -> bool:
	if not is_active() or not mode_supports_coop():
		return false
	var survivors := free_players().filter(func(p: Player): return p != player)
	if survivors.is_empty():
		return false
	# Lives are per-player now, so it is this player's own allowance that decides whether they
	# get another bubble. Running out falls through to upstream's game-over handling.
	if Settings.file.difficulty.inf_lives == 0 and get_lives(player.player_id) <= 0:
		return false
	return true


## Runs the death animation for one player, then brings them back in a rescue bubble, without
## pausing the level for everyone else.
func begin_local_death(player: Player, pit := false) -> void:
	player.is_dead = true
	player.visible = not pit
	player.stop_all_timers()
	player.dead.emit()
	Global.total_deaths += 1
	if Settings.file.difficulty.inf_lives == 0:
		add_lives(player.player_id, -1)

	_stored_collision_masks[player.get_instance_id()] = player.collision_mask
	player.sprite.process_mode = Node.PROCESS_MODE_ALWAYS
	player.state_machine.transition_to("Dead", {"Pit": pit, "Local": true})
	player_locally_died.emit(player)

	# Upstream scores a solo death with the DEATH music override, which would stomp the level
	# music for everybody still playing. The sting alone is the right cue here.
	AudioManager.play_sfx("die_sting", player.global_position)

	await get_tree().create_timer(RESPAWN_DELAY, false).timeout
	if not is_instance_valid(player):
		return
	enter_bubble(player)


## Brings a dead player back inside a rescue bubble, floating near whoever is still playing.
func enter_bubble(player: Player) -> void:
	var anchor := nearest_free_player(player.global_position)
	if anchor == null:
		# Nobody left to be rescued by - hand back to upstream's flow.
		player.death_load()
		return

	_reset_player_visuals(player)
	player.global_position = anchor.global_position + BUBBLE_SPAWN_OFFSET
	player.reset_physics_interpolation()
	player.show()
	# Frozen rather than Normal: the bubble drives their position, and Freeze is already in
	# NON_GAMEPLAY_STATES so they are skipped by camera framing and the crush check.
	player.state_machine.transition_to("Freeze")
	# Intangible while bubbled. The body only masks world geometry (Player.tscn sits on no layer
	# of its own), so contact with items, enemies and hazards all runs through the Hitbox area -
	# both have to be switched off.
	player.collision_mask = 0
	player.can_hurt = false
	var hitbox := player.get_node_or_null("Hitbox")
	if hitbox != null:
		hitbox.set_deferred("monitoring", false)
		hitbox.set_deferred("monitorable", false)

	var bubble := CoopBubble.create(player)
	bubble.global_position = player.global_position
	player.add_sibling(bubble)
	_bubbles[player.player_id] = bubble
	player_bubbled.emit(player)


## True while this player is waiting inside a rescue bubble.
func is_bubbled(player: Player) -> bool:
	var bubble = _bubbles.get(player.player_id)
	return bubble != null and is_instance_valid(bubble)


## Players who are actually in play: alive, not bubbled, and in control of themselves.
func free_players() -> Array:
	return living_players().filter(func(p: Player): return is_in_gameplay(p) and not is_bubbled(p))


## Closest player still in play, used both as the bubble's spawn anchor and its homing target.
func nearest_free_player(from: Vector2) -> Player:
	var best: Player = null
	var best_distance := INF
	for player in free_players():
		var distance := from.distance_squared_to(player.global_position)
		if distance < best_distance:
			best_distance = distance
			best = player
	return best


## Called by [CoopBubble] when it touches a player still in play.
func release_from_bubble(player: Player, at_position: Vector2) -> void:
	_bubbles.erase(player.player_id)
	if not is_instance_valid(player):
		return
	player.global_position = at_position
	_finish_respawn(player)
	player_respawned.emit(player)


## Undoes the *visual* half of the death sequence - sprite, power state, gravity. Deliberately
## does not touch collision, because a bubbled player has to stay intangible until they pop.
func _reset_player_visuals(player: Player) -> void:
	player.velocity = Vector2.ZERO
	# 1.1 splits fall gravity into _IDLE/_WALK/_RUN variants resolved by speed, so there is no
	# plain "FALL_GRAVITY" param to read - this is how Player itself initialises `gravity`.
	player.velocity_x_jump_stored = 0
	player.gravity = player.calculate_speed_param("FALL_GRAVITY", 0)
	player.z_index = 0
	player.is_dead = false
	player.last_damage_source = ""
	player.sprite.process_mode = Node.PROCESS_MODE_INHERIT
	player.sprite.speed_scale = 1
	player.power_state = player.get_node("PowerStates/Small")
	Global.player_power_states[player.player_id] = "0"
	player.handle_power_up_states(0)
	player.set_power_state_frame()


## Gives the player their collision back. Only ever called on final release, never when entering
## a bubble - calling it early would consume the stored mask and leave the freed player at mask 0,
## falling straight through the floor into another death.
func _restore_player_collision(player: Player) -> void:
	var mask: int = _stored_collision_masks.get(player.get_instance_id(), player.collision_mask)
	_stored_collision_masks.erase(player.get_instance_id())
	player.collision_mask = mask
	# Upstream's Dead state also disables the hitbox shape directly when the death type has no
	# DEATH_COLLISION, so it has to be put back by hand.
	var hitbox_shape := player.get_node_or_null("Hitbox/Shape")
	if hitbox_shape != null:
		hitbox_shape.set_deferred("disabled", false)
	# Re-enable the area we switched off for the bubble, or the freed player cannot collect items
	# or take damage. Once it is monitorable again, overlapping areas get their own area_entered on
	# the next physics step, so Player.refresh_hitbox() is not needed - and calling it before the
	# deferred set lands errors, because it reads overlaps while monitoring is still off.
	var hitbox := player.get_node_or_null("Hitbox")
	if hitbox != null:
		hitbox.set_deferred("monitoring", true)
		hitbox.set_deferred("monitorable", true)


## Hands control back after a bubble pops.
func _finish_respawn(player: Player) -> void:
	_reset_player_visuals(player)
	_restore_player_collision(player)
	player.reset_physics_interpolation()
	player.show()
	player.state_machine.transition_to("Normal")
	player.do_i_frames()

#endregion
