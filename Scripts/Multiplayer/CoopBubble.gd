class_name CoopBubble
extends Node2D

## The "New Super Mario Bros." rescue bubble a dead co-op player comes back in.
##
## After the death animation the player is put inside one of these instead of being dropped
## straight back onto a teammate. The bubble drifts; its owner taps their jump button to nudge
## it toward the nearest player still in play, and it pops when the two touch.
##
## Built in code and added to the level at runtime by [CoopManager], so no .tscn is involved.

## Assets/Sprites/Items/Bubble.png is a 96x32 strip of three 32x32 frames: intact, mid-pop,
## dissolved. Frame 0 is the bubble itself; 1 and 2 are used for the pop.
const BUBBLE_TEXTURE := preload("res://Assets/Sprites/Items/Bubble.png")
const FRAME_SIZE := 32

## Gentle idle motion so a bubble left alone still bobs.
const BOB_AMPLITUDE := 6.0
const BOB_SPEED := 2.2
const IDLE_DRIFT := 8.0

## One tap of the jump button.
const TAP_IMPULSE := 78.0
## How far a tap can stray from "straight at the nearest player", in radians. This is what makes
## the bubble wander rather than home in, so it takes a few taps to get across a gap.
const TAP_SPREAD := 0.5
## Velocity bleed-off per second, so taps do not accumulate forever.
const DRAG := 2.4
const MAX_SPEED := 150.0

## How close the bubble has to get to a free player before it pops.
const POP_RADIUS := 16.0
const POP_ANIM_TIME := 0.12

## Keeps the bubble inside the owner's view so it can always be reached.
const VIEW_MARGIN := 20.0

var player: Player = null

var _velocity := Vector2.ZERO
var _bob_time := 0.0
var _sprite: Sprite2D = null
var _popping := false


static func create(for_player: Player) -> CoopBubble:
	var bubble := CoopBubble.new()
	bubble.player = for_player
	bubble.name = "CoopBubble%d" % for_player.player_id
	return bubble


func _ready() -> void:
	z_index = 15
	_sprite = Sprite2D.new()
	_sprite.texture = _atlas_frame(0)
	# Tint faintly with the owner's colour so you can tell whose bubble is whose.
	_sprite.modulate = Coop.PLAYER_COLOURS[player.player_id].lerp(Color.WHITE, 0.55)
	add_child(_sprite)
	AudioManager.play_sfx("item_appear", global_position)


func _atlas_frame(index: int) -> AtlasTexture:
	var atlas := AtlasTexture.new()
	atlas.atlas = BUBBLE_TEXTURE
	atlas.region = Rect2(index * FRAME_SIZE, 0, FRAME_SIZE, FRAME_SIZE)
	return atlas


func _physics_process(delta: float) -> void:
	if _popping or not is_instance_valid(player):
		return

	var target := Coop.nearest_free_player(global_position)

	# Tapping jump nudges the bubble toward whoever is still playing, with enough spread that
	# it has to be spammed rather than held once.
	if Global.player_action_just_pressed("jump", player.player_id):
		var direction := Vector2.UP
		if target != null:
			direction = (target.global_position - global_position).normalized()
		direction = direction.rotated(randf_range(-TAP_SPREAD, TAP_SPREAD))
		_velocity += direction * TAP_IMPULSE
		AudioManager.play_sfx("swim", global_position)

	_bob_time += delta
	_velocity = _velocity.lerp(Vector2.ZERO, clampf(DRAG * delta, 0.0, 1.0))
	_velocity = _velocity.limit_length(MAX_SPEED)

	var drift := Vector2(0.0, sin(_bob_time * BOB_SPEED) * BOB_AMPLITUDE - IDLE_DRIFT)
	global_position += (_velocity + drift) * delta
	_clamp_to_view()

	# Carry the player along inside the bubble.
	player.global_position = global_position
	player.velocity = Vector2.ZERO

	if target != null and global_position.distance_to(target.global_position) <= POP_RADIUS:
		pop()


## Keeps the bubble on screen. Uses the owner's own camera, which their CameraHandler keeps
## updated in both camera modes even when that camera is not the one being displayed.
func _clamp_to_view() -> void:
	if player.camera == null or get_viewport() == null:
		return
	var view := Vector2(Coop.base_view_size())
	var centre := player.camera.global_position
	var half := (view / 2.0) - Vector2(VIEW_MARGIN, VIEW_MARGIN)
	global_position.x = clampf(global_position.x, centre.x - half.x, centre.x + half.x)
	global_position.y = clampf(global_position.y, centre.y - half.y, centre.y + half.y)


## Bursts the bubble and hands the player back to [CoopManager].
func pop() -> void:
	if _popping:
		return
	_popping = true
	AudioManager.play_sfx("bump", global_position)
	for frame in [1, 2]:
		_sprite.texture = _atlas_frame(frame)
		await get_tree().create_timer(POP_ANIM_TIME, false).timeout
		if not is_instance_valid(self):
			return
	if is_instance_valid(player):
		Coop.release_from_bubble(player, global_position)
	queue_free()
