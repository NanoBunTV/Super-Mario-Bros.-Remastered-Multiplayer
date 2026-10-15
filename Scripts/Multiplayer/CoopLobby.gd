class_name CoopLobby
extends CanvasLayer

## Controller-join lobby for local co-op.
##
## Built entirely in code and styled by duplicating a Label handed in by [CoopTitleHook], so no
## .tscn is added and TitleScreen.tscn is never edited. That scene is ~1600 lines of positional
## signal wiring and is one of the files upstream changes most often; keeping out of it is the
## single biggest thing this fork does to stay mergeable.
##
## **Co-op is controller-only.** Every slot starts empty, including player 1, and the first
## controller to press a button becomes player 1. The keyboard cannot claim a slot or play - its
## only job here is Escape, so someone who opened this screen on a keyboard with no controllers
## connected is not stranded.
##
## Controls:
##   - unassigned controller, A / Start -> claim the next free slot (first one in becomes P1)
##   - unassigned controller, B         -> back out of the lobby
##   - your own controller, left/right  -> change your character
##   - your own controller, B           -> leave your slot
##   - player 1's controller, up/down   -> cycle camera mode (same screen / split top-bottom /
##                                         split left-right)
##   - player 1's controller, Start     -> begin (needs 2+ players)
##   - keyboard, Escape                 -> back out

const CHARACTER_SELECT_SCENE := preload("res://Scenes/Prefabs/UI/CharacterSelect.tscn")

const JOY_JOIN_BUTTONS := [JOY_BUTTON_A, JOY_BUTTON_START]
const CHARACTER_ROW_SPACING := 10

signal start_requested
signal cancelled

var _label_template: Label = null
var _root: VBoxContainer = null
var _slot_labels := []
var _camera_label: Label = null
var _hint_label: Label = null
var _active := false


static func create(label_template: Label) -> CoopLobby:
	var lobby := CoopLobby.new()
	lobby._label_template = label_template
	lobby.name = "CoopLobby"
	return lobby


func _ready() -> void:
	layer = 64
	_build()
	# Keeps the slot rows and the "no controllers" hint honest if a pad is plugged in or pulled
	# out while the lobby is open.
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	hide()


func _on_joy_connection_changed(_device: int, _connected: bool) -> void:
	if _active:
		_refresh.call_deferred()


func open() -> void:
	_scan_custom_characters()
	# Start from a clean slate so backing out and re-entering cannot leave a stale controller
	# bound to a slot that is no longer shown.
	Coop.slot_devices = [Coop.DEVICE_NONE, Coop.DEVICE_NONE, Coop.DEVICE_NONE, Coop.DEVICE_NONE]
	show()
	_refresh()
	await get_tree().physics_frame
	_active = true


func close() -> void:
	_active = false
	hide()


## Loads whatever is in the `custom_characters` folder into `Player.CHARACTERS` and friends.
##
## Upstream only ever scans that folder from inside `CharacterSelect.get_custom_characters()`, so
## until the player has been through the vanilla character screen once, those statics hold just
## the four built-ins - and this lobby would silently offer no custom characters.
##
## That function reads `Global.config_path` and writes statics; it touches no instance state and
## no scene nodes, so it can be run on a detached instance without adding it to the tree.
func _scan_custom_characters() -> void:
	var probe := CHARACTER_SELECT_SCENE.instantiate()
	probe.get_custom_characters()
	probe.free()

	# A character that has since been deleted would leave a slot pointing past the end.
	var count: int = Player.CHARACTERS.size()
	var characters: Array = Global.player_characters.duplicate()
	var changed := false
	for slot in Coop.MAX_PLAYERS:
		if int(characters[slot]) >= count:
			characters[slot] = 0
			changed = true
	if changed:
		Global.player_characters = characters


func _build() -> void:
	var backdrop := ColorRect.new()
	backdrop.color = Color(0, 0, 0, 0.85)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(backdrop)

	_root = VBoxContainer.new()
	_root.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_root.position = Vector2(0, 24)
	_root.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_root.add_theme_constant_override("separation", 2)
	add_child(_root)

	_root.add_child(_make_label("LOCAL CO-OP"))
	_root.add_child(_spacer())

	for slot in Coop.MAX_PLAYERS:
		var label := _make_label("")
		label.modulate = Coop.PLAYER_COLOURS[slot]
		_slot_labels.append(label)
		_root.add_child(label)

	_root.add_child(_spacer())
	_camera_label = _make_label("")
	_root.add_child(_camera_label)
	_hint_label = _make_label("")
	_root.add_child(_hint_label)


## Duplicating the title screen's own Label keeps the pixel font, shadow colour and theme
## overrides in sync with whatever upstream is using, with no hardcoded styling here.
func _make_label(text: String) -> Label:
	var label: Label
	if _label_template != null and is_instance_valid(_label_template):
		label = _label_template.duplicate()
		label.visible = true
	else:
		label = Label.new()
	label.text = text
	label.uppercase = true
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	return label


func _spacer() -> Control:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, CHARACTER_ROW_SPACING)
	return spacer


func _refresh() -> void:
	for slot in Coop.MAX_PLAYERS:
		var label: Label = _slot_labels[slot]
		var device: int = Coop.slot_devices[slot]
		if device == Coop.DEVICE_NONE:
			label.text = "P%d  -  PRESS A ON A CONTROLLER" % (slot + 1)
			label.modulate = Coop.PLAYER_COLOURS[slot] * Color(1, 1, 1, 0.45)
		else:
			var character_name := tr(Player.CHARACTER_NAMES[int(Global.player_characters[slot])])
			var clash := _character_is_shared(slot)
			label.text = "P%d  %s%s  -  %s" % [
				slot + 1, character_name, "  (TAKEN)" if clash else "", Coop.device_label(slot)]
			label.modulate = Color(1, 0.5, 0.5) if clash else Coop.PLAYER_COLOURS[slot]

	var mode_name: String = Coop.CAMERA_MODE_NAMES[int(Coop.camera_mode)]
	# No angle brackets around the mode: the game's bitmap font (Assets/Sprites/UI/Font.fnt) jumps
	# straight from char 59 to 63, so '<' and '>' have no glyph and render as missing-character
	# boxes. Anything added to this screen has to stay inside the font's set.
	_camera_label.text = "CAMERA: %s   (P1 UP/DOWN)" % mode_name

	if Coop.occupied_slots().is_empty() and Input.get_connected_joypads().is_empty():
		_hint_label.text = "NO CONTROLLERS DETECTED"
		_hint_label.modulate = Color(1, 0.6, 0.6)
	elif Coop.occupied_slots().size() < 2:
		_hint_label.text = "NEEDS 2 OR MORE PLAYERS"
		_hint_label.modulate = Color(1, 1, 1, 0.5)
	elif _duplicate_characters():
		# Each player's life counter is labelled by their character icon, so two players on the
		# same character would give the HUD two identical rows.
		_hint_label.text = "EVERYONE NEEDS A DIFFERENT CHARACTER"
		_hint_label.modulate = Color(1, 0.6, 0.6)
	else:
		_hint_label.text = "P1 PRESS START TO BEGIN"
		_hint_label.modulate = Color.WHITE


func _input(event: InputEvent) -> void:
	if not _active:
		return

	if event is InputEventJoypadButton and event.pressed:
		_handle_joypad_button(event)
	elif event is InputEventJoypadMotion:
		_handle_joypad_motion(event)
	elif event is InputEventKey and event.pressed and not event.echo:
		_handle_key(event)


func _handle_joypad_button(event: InputEventJoypadButton) -> void:
	var device: int = event.device
	var slot := Coop.slot_for_device(device)

	if slot == -1:
		if JOY_JOIN_BUTTONS.has(event.button_index):
			if Coop.claim_slot(device) != -1:
				AudioManager.play_global_sfx("menu_move")
				_refresh()
		elif event.button_index == JOY_BUTTON_B:
			# Not in a slot, so B means "leave this screen" rather than "leave my slot".
			_cancel()
		get_viewport().set_input_as_handled()
		return

	match event.button_index:
		JOY_BUTTON_B:
			Coop.release_slot(slot)
			AudioManager.play_global_sfx("menu_move")
			_refresh()
		JOY_BUTTON_DPAD_LEFT:
			_cycle_character(slot, -1)
		JOY_BUTTON_DPAD_RIGHT:
			_cycle_character(slot, 1)
		JOY_BUTTON_DPAD_UP:
			if slot == 0:
				_cycle_camera_mode(-1)
		JOY_BUTTON_DPAD_DOWN:
			if slot == 0:
				_cycle_camera_mode(1)
		JOY_BUTTON_START:
			if slot == 0:
				_try_start()
	get_viewport().set_input_as_handled()


func _handle_joypad_motion(event: InputEventJoypadMotion) -> void:
	# Only act on a decisive push, and only for a device already in a slot, so a resting stick
	# cannot spam character changes.
	if absf(event.axis_value) < 0.7:
		return
	var slot := Coop.slot_for_device(event.device)
	if slot == -1:
		return
	if event.axis == JOY_AXIS_LEFT_X:
		_cycle_character(slot, signi(int(signf(event.axis_value))))


func _handle_key(event: InputEventKey) -> void:
	# The keyboard is not a player in co-op. Escape is kept purely so that opening this screen
	# with no controller connected is recoverable.
	if event.keycode != KEY_ESCAPE:
		return
	_cancel()
	get_viewport().set_input_as_handled()


## True when another joined player is already on this slot's character.
func _character_is_shared(slot: int) -> bool:
	for other in Coop.occupied_slots():
		if other != slot and int(Global.player_characters[other]) == int(Global.player_characters[slot]):
			return true
	return false


## True when two or more joined players picked the same character.
func _duplicate_characters() -> bool:
	var seen := []
	for slot in Coop.occupied_slots():
		var character: int = int(Global.player_characters[slot])
		if seen.has(character):
			return true
		seen.append(character)
	return false


func _cycle_character(slot: int, direction: int) -> void:
	if Coop.slot_devices[slot] == Coop.DEVICE_NONE:
		return
	var count: int = Player.CHARACTERS.size()
	var characters: Array = Global.player_characters.duplicate()
	characters[slot] = wrapi(int(characters[slot]) + direction, 0, count)
	Global.player_characters = characters
	AudioManager.play_global_sfx("menu_move")
	_refresh()


## Cycles same-screen -> split top/bottom -> split left/right.
func _cycle_camera_mode(direction: int) -> void:
	var count: int = Coop.CAMERA_MODE_NAMES.size()
	Coop.camera_mode = wrapi(int(Coop.camera_mode) + direction, 0, count) as Coop.CameraMode
	AudioManager.play_global_sfx("menu_move")
	_refresh()


func _try_start() -> void:
	if Coop.occupied_slots().size() < 2 or _duplicate_characters():
		return
	Coop.start_session()
	close()
	start_requested.emit()


func _cancel() -> void:
	Coop.end_session()
	close()
	cancelled.emit()
