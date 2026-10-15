class_name CoopSpawner
extends RefCounted

## Fills in `Level.spawn_in_extra_players()`, which upstream ships as an empty stub.
##
## Levels contain exactly one `Player` instance placed in the editor. For co-op the extra
## players are cloned from that instance at runtime, so they inherit whatever the level author
## configured (starting power state, `auto_death_pit`, gravity flags) without every level scene
## needing to change.
##
## Also resets per-level co-op state (pipe latch, camera smoothing) and installs the camera rig
## ([CoopCamera] or [CoopSplitScreen]) and the per-player HUD ([CoopHud]).

const PLAYER_SCENE := preload("res://Scenes/Prefabs/Entities/Player.tscn")

const CAMERA_NODE_NAME := "CoopCamera"
const SPLIT_NODE_NAME := "CoopSplitScreen"


## Spawns players for every occupied slot beyond the first and installs the camera rig.
## Called from `Level._enter_tree`, deferred until the level's own children have run their
## `_ready` - Checkpoint in particular repositions everything in the "Players" group, and the
## clones need to inherit the post-checkpoint position rather than the level's start marker.
static func spawn(level: Node) -> void:
	if not Coop.is_active() or not Coop.mode_supports_coop():
		return
	await level.get_tree().process_frame
	if not is_instance_valid(level) or not level.is_inside_tree():
		return

	var template := _find_template(level)
	if template == null:
		push_warning("[Co-op] No Player found in level; extra players not spawned.")
		return

	for slot in Coop.occupied_slots():
		if slot == 0:
			continue
		if Coop.player_for_slot(slot) != null:
			continue
		_spawn_player(template, slot)

	# Per-level state that must not carry over from the level just left.
	Coop.reset_pipe_state()
	Coop.reset_shared_target()

	_install_camera_rig(level)
	_install_hud(level)


static func _find_template(level: Node) -> Player:
	for player in level.get_tree().get_nodes_in_group("Players"):
		if player is Player and player.player_id == 0:
			return player
	var players := level.get_tree().get_nodes_in_group("Players")
	return players[0] if not players.is_empty() else null


static func _spawn_player(template: Player, slot: int) -> void:
	var player: Player = PLAYER_SCENE.instantiate()
	# Set before entering the tree: Player._ready reads player_id to pick the character,
	# power state, palette and checkpoint label colour.
	player.player_id = slot
	player.starting_power_state = template.starting_power_state
	player.auto_death_pit = template.auto_death_pit

	template.add_sibling(player)
	# Stacked exactly on player 1 rather than offset - players pass through each other, and any
	# horizontal offset risks spawning inside level geometry at a checkpoint or pipe exit.
	player.global_position = template.global_position
	player.reset_physics_interpolation()


## Adds whichever camera rig the session asked for. Skipped while the level editor is open but
## not playtesting, where the editor owns the camera.
static func _install_camera_rig(level: Node) -> void:
	if Global.level_editor != null and not Global.level_editor_is_playtesting():
		return
	if Coop.is_split_screen():
		var split := CoopSplitScreen.new()
		split.name = SPLIT_NODE_NAME
		level.add_child(split)
	else:
		var camera := CoopCamera.new()
		camera.name = CAMERA_NODE_NAME
		level.add_child(camera)


## Adds the per-player life counters. Installed after the camera rig, because in split-screen it
## positions each row against its pane.
static func _install_hud(level: Node) -> void:
	if Global.level_editor != null and not Global.level_editor_is_playtesting():
		return
	var hud := CoopHud.new()
	hud.name = "CoopHud"
	level.add_child(hud)


## The active shared-camera helper, or null in split-screen / single player.
static func get_coop_camera() -> CoopCamera:
	if Global.current_level == null:
		return null
	return Global.current_level.get_node_or_null(CAMERA_NODE_NAME) as CoopCamera
