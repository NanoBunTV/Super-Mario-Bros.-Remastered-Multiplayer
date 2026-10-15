class_name CoopSplitScreen
extends CanvasLayer

## Optional split-screen rig for local co-op.
##
## Each player gets a SubViewport sharing the level's World2D, with its own pane camera that
## tracks that player directly (see `_pane_camera_position`). The player's own Camera2D cannot be
## used or mirrored: a Camera2D only drives the viewport it lives in, and upstream's CameraHandler
## converges every player's camera on the lead player anyway.
##
## Layouts: 2 players stacked top/bottom or side by side (lobby choice); 3-4 players a 2x2 grid
## with the last cell blank at 3. Any multi-column layout enlarges the root render target so each
## pane is a full-size view at native resolution.
##
## Player 1's camera stays current in the root viewport even though the panes cover it, because
## a lot of upstream code reaches for `get_viewport().get_camera_2d()` (`AudioManager
## .play_global_sfx`, `Player.reset_camera_to_center`) and would break on a null camera.
##
## Added to the level at runtime by [CoopSpawner]; nothing references it from a .tscn.

## Panes sit above the world, below the HUD. See [method _raise_hud].
const PANE_LAYER := 1
const HUD_LAYER_WHILE_SPLIT := 2

## Above this many players the 2x2 grid is used; at or below it, 2 players split top/bottom or
## left/right depending on `Coop.camera_mode`.
const STACKED_PLAYER_LIMIT := 2

## Level bounds, matching `CameraHandler.do_limits()`.
const LEVEL_LEFT_BOUND := -256.0
const LEVEL_BOTTOM_BOUND := 32.0
const DEFAULT_VERTICAL_HEIGHT := -208.0

## How far above the player the pane camera starts out.
const VERTICAL_PLAYER_OFFSET := 32.0

## Resting horizontal lead, matching `CameraHandler.camera_offset`.
const HORIZONTAL_OFFSET := 8.0

## Vertical deadzone and catch-up, matching `CameraHandler.handle_vertical_scrolling()`. The
## camera only moves once the player leaves this band, which is what stops jumps bouncing it.
const VERTICAL_SLACK_UP := 64.0
const VERTICAL_SLACK_DOWN := 32.0
const VERTICAL_CATCHUP_SPEED := 3.0
## Keeps the slack inside a short pane, so the player can never leave the view before the camera
## starts following.
const VERTICAL_EDGE_MARGIN := 16.0

var _panes := []          ## Array of { "player_id": int, "camera": Camera2D, "container": SubViewportContainer }
var _hud_layer_restore := 0
var _hud: CanvasLayer = null

## Root content scale size to put back on exit. Zero means "not overridden".
var _content_scale_restore := Vector2i.ZERO

## Pane grid in use, as (columns, rows).
var _grid := Vector2i(1, 1)


func _ready() -> void:
	layer = PANE_LAYER
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_raise_hud()
	_build_backdrop()
	_build_panes()
	get_viewport().size_changed.connect(_layout_panes)


## Fills everything the panes do not cover. With 3 players the layout is the 4-player 2x2 grid
## with the last cell left empty, and without this the root viewport - which still renders the
## world from player 1's camera - would show through that gap as a fourth, unlabelled view.
func _build_backdrop() -> void:
	var backdrop := ColorRect.new()
	backdrop.name = "Backdrop"
	backdrop.color = Color.BLACK
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)


func _exit_tree() -> void:
	_restore_hud()
	_restore_content_scale()


## The view size a single player would get, which each pane is sized to match.
func _base_resolution() -> Vector2i:
	return Coop.base_view_size()


## Screen rect of one player's pane, or a zero rect if they have none. Used by [CoopHud] to park
## each player's life counter inside their own view.
func pane_rect(player_id: int) -> Rect2:
	for pane in _panes:
		if pane["player_id"] == player_id:
			var container: SubViewportContainer = pane["container"]
			return Rect2(container.position, container.size)
	return Rect2()


## The grid cell with no pane in it - the bottom-right square at 3 players. Returns a zero rect
## for 2 and 4 players, where the grid is full. [CoopHud] parks the shared counters here.
func blank_cell_rect() -> Rect2:
	if _panes.is_empty():
		return Rect2()
	var cells := _grid.x * _grid.y
	if _panes.size() >= cells:
		return Rect2()
	var pane_size: Vector2 = _panes[0]["container"].size
	var index := _panes.size()  # first unused cell
	var column := index % _grid.x
	var row := index / _grid.x
	return Rect2(Vector2(column * pane_size.x, row * pane_size.y), pane_size)


## Grows the root render target so the pane grid fits at native resolution. Remembers the
## original so it can be put back - `Level.reset_resolution()` owns this value normally.
func _apply_content_scale(wanted: Vector2i) -> void:
	# `size_changed` can fire while the tree is being torn down, with get_tree() already null.
	var tree := get_tree()
	if tree == null or not is_instance_valid(tree.root):
		return
	var root := tree.root
	if _content_scale_restore == Vector2i.ZERO:
		_content_scale_restore = root.content_scale_size
	if root.content_scale_size != wanted:
		root.content_scale_size = wanted


func _restore_content_scale() -> void:
	if _content_scale_restore == Vector2i.ZERO:
		return
	# get_tree() is already null if this runs while the tree is being torn down.
	var tree := get_tree()
	if tree != null and is_instance_valid(tree.root):
		tree.root.content_scale_size = _content_scale_restore
	_content_scale_restore = Vector2i.ZERO


## The HUD lives on the Global autoload at layer 0, the same layer the world draws on, so the
## panes would cover it. Bumped for the duration of the session and put back afterwards; this
## is a runtime-only change, the .tscn is untouched.
func _raise_hud() -> void:
	_hud = Global.get_node_or_null("GameHUD")
	if _hud != null:
		_hud_layer_restore = _hud.layer
		_hud.layer = HUD_LAYER_WHILE_SPLIT


func _restore_hud() -> void:
	if _hud != null and is_instance_valid(_hud):
		_hud.layer = _hud_layer_restore


func _build_panes() -> void:
	for slot in Coop.occupied_slots():
		var sub_viewport := SubViewport.new()
		sub_viewport.world_2d = get_viewport().world_2d
		sub_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		sub_viewport.handle_input_locally = false
		# Only the root viewport should position the audio listener, otherwise positional SFX
		# get panned by whichever pane updated last.
		sub_viewport.audio_listener_enable_2d = false
		sub_viewport.transparent_bg = false
		# These are *project* settings applied to the root viewport, and a SubViewport created at
		# runtime does not inherit them. Without them the panes render sprites at fractional
		# positions with linear filtering, which is the soft, "bicubic blurred" look.
		sub_viewport.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
		sub_viewport.snap_2d_transforms_to_pixel = true
		sub_viewport.snap_2d_vertices_to_pixel = true

		var pane_camera := Camera2D.new()
		pane_camera.name = "PaneCamera"
		pane_camera.position_smoothing_enabled = false
		pane_camera.ignore_rotation = true
		sub_viewport.add_child(pane_camera)

		var container := SubViewportContainer.new()
		container.name = "Pane" + str(slot)
		container.stretch = true
		container.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		container.add_child(sub_viewport)
		add_child(container)
		# Only valid once the camera is inside the tree.
		pane_camera.make_current()

		_panes.append({
			"player_id": slot,
			"camera": pane_camera,
			"container": container,
		})

	_layout_panes()


func _layout_panes() -> void:
	# is_inside_tree() first: get_tree() itself errors once the node has left the tree, which
	# happens here on quit when the level's reset_resolution() resizes the window.
	if _panes.is_empty() or not is_inside_tree():
		return
	var count := _panes.size()

	var columns := 1
	var rows := count
	if count > STACKED_PLAYER_LIMIT:
		columns = 2
		rows = 2
	elif Coop.is_side_by_side():
		# 2 players left/right instead of top/bottom. Each pane is then full level height, so the
		# vertical camera barely has to move at all - which is the calmest option on tall levels,
		# at the cost of half the horizontal warning distance.
		columns = count
		rows = 1
	_grid = Vector2i(columns, rows)

	var pane_size: Vector2
	if columns > 1:
		# A 2x2 grid of quarter-size panes would only show a quarter of the normal view each -
		# the world at 1:1 in a 213x120 window, which reads as a 2x zoom-in. Instead the root
		# render target is enlarged to hold the whole grid, so every pane is a full-size game
		# display at native resolution rather than a cropped or downscaled one.
		var base := _base_resolution()
		_apply_content_scale(Vector2i(base.x * columns, base.y * rows))
		pane_size = Vector2(base)
	else:
		_restore_content_scale()
		var view := get_viewport().get_visible_rect().size
		pane_size = Vector2(view.x / columns, view.y / rows)
	var index := 0
	for pane in _panes:
		var column := index % columns
		var row := index / columns
		var container: SubViewportContainer = pane["container"]
		container.position = Vector2(column * pane_size.x, row * pane_size.y)
		container.size = pane_size
		index += 1


## Physics rate, not render rate: the catch-up below is a fixed step per tick, exactly as
## CameraHandler does it, and the player position it follows is updated in physics too. Running
## it in _process made the camera speed depend on framerate.
func _physics_process(_delta: float) -> void:
	for pane in _panes:
		var player: Player = Coop.player_for_slot(pane["player_id"])
		if player == null or not is_instance_valid(player) or player.camera == null:
			continue
		var container: SubViewportContainer = pane["container"]
		var pane_camera: Camera2D = pane["camera"]
		pane_camera.global_position = _pane_camera_position(pane, player, container.size)


## Where a pane's camera belongs, given how large that pane actually is.
##
## The player's own camera cannot simply be mirrored here. `CameraHandler.do_limits()` clamps
## against `get_viewport_rect()` - the *root* viewport - so in a level 240px tall it pins the
## camera at the one Y that shows the whole level. Copying that into a 120px-tall pane framed
## the top half of the level and left the players below the pane entirely: you only saw them
## when they jumped. The clamp has to be redone against the pane's own size.
func _pane_camera_position(pane: Dictionary, player: Player, pane_size: Vector2) -> Vector2:
	var half := pane_size / 2.0

	var vertical_height := DEFAULT_VERTICAL_HEIGHT
	if Global.current_level != null:
		vertical_height = float(Global.current_level.vertical_height)

	# Horizontal: track this pane's *own* player.
	#
	# This deliberately does not mirror `player.camera`. Upstream's CameraHandler scans the whole
	# Players group and converges every player's camera on the single lead player, so copying it
	# showed every pane the leader's view - the panes appeared frozen relative to their own player
	# and started off framing somebody else entirely.
	#
	# The rule is upstream's own: the camera pins the player at centre while they advance, and
	# holds still when they back up unless the level allows backscrolling.
	var right_limit: float = clampf(Player.camera_right_limit, LEVEL_LEFT_BOUND + pane_size.x, INF)
	var target_x: float = player.global_position.x + HORIZONTAL_OFFSET
	var camera_x: float = pane.get("camera_x", target_x)
	var can_backscroll: bool = Global.current_level != null and Global.current_level.can_backscroll
	if target_x > camera_x or can_backscroll:
		camera_x = target_x
	camera_x = clampf(camera_x, LEVEL_LEFT_BOUND + half.x, right_limit - half.x)
	pane["camera_x"] = camera_x

	# Vertical: the same deadzone-and-catch-up rule as CameraHandler.handle_vertical_scrolling.
	#
	# Tracking the player's Y directly - which is what this did originally - moves the camera the
	# full height of every jump, every frame, which reads as a violent bounce in a pane only half
	# the screen tall. Upstream instead leaves the camera alone until the player crosses out of a
	# band around it, and creeps back slowly while they are grounded.
	var camera_y: float = pane.get("camera_y", player.global_position.y - VERTICAL_PLAYER_OFFSET)
	var player_y := player.global_position.y
	# Slack is capped to the pane so a short pane cannot let the player leave the view before the
	# camera reacts; upstream's 64/32 assume a full-height 240px screen.
	var slack_up: float = minf(VERTICAL_SLACK_UP, half.y - VERTICAL_EDGE_MARGIN)
	var slack_down: float = minf(VERTICAL_SLACK_DOWN, half.y - VERTICAL_EDGE_MARGIN)

	if player_y < camera_y and player.is_on_floor():
		camera_y = move_toward(camera_y, player_y, VERTICAL_CATCHUP_SPEED)
	elif player_y < camera_y - slack_up:
		camera_y = player_y + slack_up
	elif player_y > camera_y + slack_down:
		camera_y = player_y - slack_down

	camera_y = clampf(camera_y, vertical_height + half.y, LEVEL_BOTTOM_BOUND - half.y)
	pane["camera_y"] = camera_y
	return Vector2(camera_x, camera_y)
