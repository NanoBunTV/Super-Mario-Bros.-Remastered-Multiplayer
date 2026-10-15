class_name CoopCamera
extends Node

## Same-screen camera support for local co-op.
##
## This is deliberately small. Upstream 1.1 rewrote `CameraHandler` so that every player's
## handler scans the whole "Players" group and converges on a single lead player - meaning all
## players' cameras already compute the same position, and same-screen multiplayer is most of
## the way there out of the box.
##
## What is left for co-op is only:
##   1. making sure exactly one camera is current, so the view does not depend on which player
##      node happened to be added to the tree first;
##   2. killing a player who is genuinely crushed by the advancing left screen edge - being left
##      behind just shoves them along, the same as the screen edge does in single player;
##   3. shifting the framing target from the lead player to the group midpoint - which is a
##      single marked hook inside `CameraHandler.handle_camera`, calling
##      `Coop.shared_camera_target_x()`.
##
## The 1.0.2 version of this fork shipped a standalone GroupCamera that reimplemented scrolling,
## offsets and level limits. Upstream then rewrote all of that, which would have left the copy
## silently stale - so it was replaced with this.
##
## Added to the level at runtime by [CoopSpawner]; nothing references it from a .tscn.

var _camera: Camera2D = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	Coop.reset_shared_target()
	take_over.call_deferred()


## Leaves player 1's camera as the only enabled one, so upstream's handler drives a single view.
func take_over() -> void:
	var owner_player := Coop.player_for_slot(0)
	if owner_player == null:
		var players := Coop.players()
		if players.is_empty():
			return
		owner_player = players[0]
	if owner_player.camera == null:
		return

	for player in Coop.players():
		if is_instance_valid(player) and player.camera != null and player != owner_player:
			player.camera.enabled = false

	_camera = owner_player.camera
	_camera.enabled = true
	_camera.make_current()


func _physics_process(delta: float) -> void:
	if not Coop.is_shared_camera():
		return
	# Advanced here, once per tick, rather than inside shared_camera_target_x() - that is called
	# by every player's CameraHandler separately.
	Coop.update_shared_target(delta)
	if not is_instance_valid(_camera) or not _camera.is_inside_tree():
		take_over()
		return
	if get_viewport() == null:
		return

	var view := get_viewport().get_visible_rect().size
	if Global.current_level != null and Global.current_level.enforce_resolution != Vector2.ZERO:
		view = Global.current_level.enforce_resolution
	Coop.crush_check(_camera.get_screen_center_position().x - (view.x / 2.0))
