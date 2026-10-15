extends Node2D

const FLAG_POINTS := [100, 400, 800, 2000, 5000]

const FLAG_POINTS_MODERN := [100, 200, 800, 4000, 8000]

signal player_reached

signal sequence_begin

var flag_direction := -1

#region MULTIPLAYER
## Seconds the stragglers get to reach the flag after the first player grabs it.
const COOP_END_COUNTDOWN := 6.0

## Set once the first player has taken the flag, so later touches take the short path.
var coop_flag_taken := false
#endregion MULTIPLAYER

func on_area_entered(area: Area2D) -> void:
	if area.owner is Player:
		player_touch(area.owner)

func player_touch(player: Player) -> void:
	if ConditionalClear.valid == false:
		return
	#region MULTIPLAYER
	# In co-op every player can take the flag, not just the first. The first grab starts a
	# countdown that ends the level whether or not the stragglers make it in time.
	if Coop.is_active():
		if coop_flag_taken:
			coop_late_touch(player)
			return
		coop_flag_taken = true
		coop_end_countdown()
	#endregion MULTIPLAYER
	player_reached.emit()
	if Global.current_game_mode == Global.GameMode.MARATHON_PRACTICE:
		SpeedrunHandler.is_warp_run = false
		SpeedrunHandler.run_finished()
	Global.can_pause = false
	if get_node_or_null("Top") != null:
		$Top.queue_free()
	#region MULTIPLAYER
	# The hitbox has to survive in co-op, otherwise only the first player could ever touch the
	# flag. Repeat touches are filtered by coop_late_touch().
	if not Coop.is_active():
		$Hitbox.queue_free()
	#endregion MULTIPLAYER
	get_tree().call_group("Enemies", "flag_die")
	give_points(player)
	Global.can_time_tick = false
	if player.can_pose_anim == false:
		player.z_index = -2
	player.global_position.x = global_position.x - 5
	$Animation.play("FlagDown")
	player.state_machine.transition_to("FlagPole")
	if not player.physics_params("FLAG_SKIP_GRAB", player.ENDING_PARAMETERS):
		AudioManager.set_music_override(AudioManager.MUSIC_OVERRIDES.SILENCE, 99, false)
		AudioManager.play_global_sfx("flag_slide")
		if player.physics_params("FLAG_HANG_TIMER", player.ENDING_PARAMETERS) > 0:
			await get_tree().create_timer(player.physics_params("FLAG_HANG_TIMER", player.ENDING_PARAMETERS), false).timeout
	else:
		AudioManager.play_global_sfx("flag_slide")
	sequence_begin.emit()
	if Global.current_game_mode == Global.GameMode.BOO_RACE:
		AudioManager.set_music_override(AudioManager.MUSIC_OVERRIDES.RACE_WIN, 99, false)
	else:
		AudioManager.set_music_override(AudioManager.MUSIC_OVERRIDES.LEVEL_COMPLETE, 99, false)
	Global.level_complete_begin.emit()
	deactivate_all_generators()
	await get_tree().create_timer(1, false).timeout
	if [Global.GameMode.BOO_RACE].has(Global.current_game_mode) == false:
		Global.tally_time()

#region MULTIPLAYER
## A player reaching the flag after someone else already took it. They get the slide and the
## points, but none of the level-ending sequence - that is already running.
func coop_late_touch(player: Player) -> void:
	if Coop.NON_GAMEPLAY_STATES.has(player.state_machine.state.name):
		return
	give_points(player)
	if player.can_pose_anim == false:
		player.z_index = -2
	player.global_position.x = global_position.x - 5
	player.state_machine.transition_to("FlagPole")
	AudioManager.play_global_sfx("flag_slide")


## Ends the level a fixed time after the first player took the flag, so one straggler cannot
## hold everyone else on the finished level indefinitely. Harmless if the normal ending (a
## player walking into the castle) already happened - EndCastle guards re-entry with its own
## static `is_transitioning` flag.
func coop_end_countdown() -> void:
	await get_tree().create_timer(COOP_END_COUNTDOWN, false).timeout
	if not is_inside_tree():
		return
	var castle = get_tree().get_first_node_in_group("EndCastles")
	if castle != null and "is_transitioning" in castle:
		if castle.is_transitioning:
			return
		castle.is_transitioning = true
		castle.exit_level()
	elif Global.current_level != null:
		Global.current_level.transition_to_next_level()
#endregion MULTIPLAYER

func deactivate_all_generators() -> void:
	for i in get_tree().get_nodes_in_group("EntityGenerators"):
		i.active = false
		i.deactivate()
	get_tree().call_group("Enemies", "start_retreat") # Lakitus

func _ready() -> void:
	$FlagJoint/Flag.position.x = 8 * flag_direction
	$FlagJoint/Flag.scale.x = -flag_direction

func _physics_process(_delta: float) -> void:
	$Hollow.visible = not ConditionalClear.valid
	$Pole.visible = ConditionalClear.valid
	$FlagJoint.visible = $Pole.visible

func give_points(player: Player) -> void:
	var value = clamp(int(lerp(0, 4, (player.global_position.y / -144))), 0, 4)
	var nearest_value = FLAG_POINTS[value]
	if Settings.file.difficulty.flagpole_lives:
		nearest_value = FLAG_POINTS_MODERN[value]
	$Score.text = str(nearest_value)
	if nearest_value == 8000 and not [Global.GameMode.CHALLENGE, Global.GameMode.BOO_RACE].has(Global.current_game_mode) and not Settings.file.difficulty.inf_lives:
		AudioManager.play_sfx("1_up", global_position)
		#region MULTIPLAYER
		# Lives are per-player in co-op, so the flagpole 1-up goes to whoever grabbed the flag.
		Coop.add_lives(player.player_id, 1)
		#endregion MULTIPLAYER
		$ScoreNoteSpawner.spawn_one_up_note()
	else:
		Global.score += nearest_value
		$Score/Animation2.play("ScoreRise")
