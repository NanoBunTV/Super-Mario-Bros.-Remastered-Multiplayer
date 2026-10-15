class_name CoopHud
extends CanvasLayer

## Per-player HUD additions for local co-op.
##
## Lives are per-player, so each one needs its own counter. Rather than build new widgets, this
## clones upstream's `ModernHUD/TopLeft/LifeCount` row (character icon + count) once per extra
## player, so the font, shadow shader and icon pipeline all stay whatever upstream is using.
##
## Player 1 keeps using upstream's own row - it already reads `Global.lives`, which is player 1's
## count - so only players 2-4 get clones. In the shared camera they stack underneath it; in
## split-screen each row is parked at its own pane's top-left instead, and the shared
## score/time/coins counters are shown once: top-right of the whole screen at 2 and 4 players,
## centred in the empty cell at 3.
##
## Built in code and added to the level at runtime; GameHud.tscn is never edited.

const LIFE_COUNT_PATH := "ModernHUD/TopLeft/LifeCount"
const COIN_COUNT_PATH := "ModernHUD/TopLeft/CoinCount"
const SCORE_TIME_PATH := "ModernHUD/Right"

## Vertical pitch between stacked life rows, matching the row's own 16px height.
const ROW_HEIGHT := 16.0


var _hud: CanvasLayer = null
var _rows := {}            ## player_id -> Control (clones only; player 1 uses upstream's row)
var _template: Control = null

var _coin_count: Control = null
var _score_time: Control = null
var _coin_home := Vector2.ZERO
var _score_home := Vector2.ZERO
var _homes_captured := false


func _ready() -> void:
	# Above the split-screen panes, which sit at layer 1 and raise the HUD to 2.
	layer = 3
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_hud = Global.get_node_or_null("GameHUD")
	if _hud == null:
		return
	_template = _hud.get_node_or_null(LIFE_COUNT_PATH)
	_coin_count = _hud.get_node_or_null(COIN_COUNT_PATH)
	_score_time = _hud.get_node_or_null(SCORE_TIME_PATH)
	_build_rows()


func _exit_tree() -> void:
	_restore_shared_counters()


func _build_rows() -> void:
	if _template == null:
		return
	for slot in Coop.occupied_slots():
		if slot == 0:
			continue  # upstream's own row already shows player 1
		var row: Control = _template.duplicate()
		row.name = "LifeCount%d" % slot
		row.visible = true
		var label := row.get_node_or_null("ModernLifeCount")
		if label != null:
			# Clear the unique-name flag inherited from the original, so `%ModernLifeCount`
			# lookups inside GameHUD can never resolve to a clone.
			label.unique_name_in_owner = false
		var icon := row.get_node_or_null("CharacterIcon")
		if icon != null:
			icon.visible = true
			var setter := icon.get_node_or_null("ResourceSetterNew")
			var character := int(Global.player_characters[slot])
			if setter != null and character < GameHUD.character_icons.size():
				if GameHUD.character_icons[character] != null:
					setter.json_path = GameHUD.character_icons[character]
		add_child(row)
		_rows[slot] = row


func _process(_delta: float) -> void:
	if _hud == null or _rows.is_empty() and _coin_count == null:
		return
	# Everything below runs after upstream's own HUD update this frame (the GameHUD autoload is
	# earlier in the tree than this node), so these positions win.
	var modern: bool = bool(Settings.file.visuals.modern_hud)
	var infinite: bool = Settings.file.difficulty.inf_lives != 0
	for slot in _rows:
		var row: Control = _rows[slot]
		row.visible = modern
		var label := row.get_node_or_null("ModernLifeCount")
		if label != null:
			label.text = "*" + ("∞" if infinite else str(Coop.get_lives(slot)).pad_zeros(2))

	if Coop.is_split_screen():
		_layout_split()
	else:
		_layout_stacked()


## Shared camera: extra rows stack straight under upstream's player 1 row.
func _layout_stacked() -> void:
	_restore_shared_counters()
	if _template == null:
		return
	var index := 1
	for slot in _rows:
		_rows[slot].position = _template.global_position + Vector2(0, ROW_HEIGHT * index)
		index += 1


## Split-screen: each row sits in its own pane, and the counters that are the same for everyone
## go top-right (full grid) or into the blank cell (3 players).
func _layout_split() -> void:
	var split := Coop.split_screen()
	if split == null or _template == null:
		return

	# Player 1's row is upstream's, anchored to the screen corner, which already coincides with
	# pane 0's corner - nothing to move. Every other row copies its offset within pane 0, so all
	# the rows line up whatever HUD scale or canvas size is in use.
	var inset := _template.global_position - split.pane_rect(0).position
	for slot in _rows:
		var rect := split.pane_rect(slot)
		if rect.size == Vector2.ZERO:
			continue
		_rows[slot].position = rect.position + inset

	_capture_homes()
	var blank := split.blank_cell_rect()
	if blank.size == Vector2.ZERO:
		_place_shared_top_right()
	else:
		_place_shared_in_cell(blank)


## 2 and 4 players: the grid is full, so the shared counters go in the very top-right corner of
## the whole screen. Score/time is already anchored there by upstream, so only the coin counter
## has to travel across from the top-left; it tucks in one row underneath.
func _place_shared_top_right() -> void:
	# `_score_home` is already the top-right corner: upstream anchors ModernHUD to the full width,
	# so the score/time group sits flush against the right edge of whatever canvas is in use.
	_stack_shared(_score_home)


## 3 players: park them in the middle of the empty bottom-right cell, where nothing is drawn.
func _place_shared_in_cell(cell: Rect2) -> void:
	if _score_time == null or _coin_count == null:
		return
	var centre := cell.position + cell.size / 2.0
	var block := Vector2(_score_time.size.x, _score_time.size.y + _coin_count.size.y)
	_stack_shared(centre - block / 2.0)


## Score/time on top, coins right-aligned directly underneath. Positions come from the groups'
## measured sizes rather than fixed offsets - the score group is 32px tall, so stacking the coins
## a single 16px row below it put them straight through the middle of the score.
func _stack_shared(top_left: Vector2) -> void:
	if _score_time == null or _coin_count == null:
		return
	_score_time.global_position = top_left
	_coin_count.global_position = Vector2(
		top_left.x + _score_time.size.x - _coin_count.size.x,
		top_left.y + _score_time.size.y
	)


## Homes are stored in *global* space. The two groups have different parents - the coin counter
## lives under `ModernHUD/TopLeft`, score/time directly under `ModernHUD` - so equal `position`
## values do not put them in the same place on screen.
func _capture_homes() -> void:
	if _homes_captured:
		return
	if _coin_count != null:
		_coin_home = _coin_count.global_position
	if _score_time != null:
		_score_home = _score_time.global_position
	_homes_captured = true


func _restore_shared_counters() -> void:
	if not _homes_captured:
		return
	if _coin_count != null and is_instance_valid(_coin_count):
		_coin_count.global_position = _coin_home
	if _score_time != null and is_instance_valid(_score_time):
		_score_time.global_position = _score_home
	_homes_captured = false
