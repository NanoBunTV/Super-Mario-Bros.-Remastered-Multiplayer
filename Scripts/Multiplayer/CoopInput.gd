class_name CoopInput
extends RefCounted

## Per-player input binding for local co-op.
##
## SMB1R already routes every gameplay input through `Global.player_action_pressed(action, player_id)`,
## which resolves to the action `"<action>_<player_id>"`. The actions exist in project.godot for
## players 0-3, but only player 0's are usable: the rest are bound to hardcoded device indices and
## are missing entries.
##
## Rather than maintain a second set of default bindings, this rebuilds every slot at runtime by
## cloning slot 0's *controller* bindings and retargeting each copy to that slot's device. All
## players therefore inherit the layout configured for player 1 in the settings menu, including
## any remaps (that menu only ever writes to the `_0` actions - see SettingsMenu.tscn
## `save_inputs`).
##
## **Co-op is controller-only, for every player including player 1.** Keyboard events are dropped
## from all per-player actions for the duration of a session, and each slot responds solely to its
## own pad. Without that, project.godot's player 0 bindings (device -1, "any device") would let
## every controller drive player 1 at once. Single player is unaffected: `apply()` only runs
## during a session and `restore()` puts the original map back afterwards.

## Actions that exist once per player, suffixed `_0` through `_3`.
const PLAYER_ACTIONS := ["jump", "run", "action", "move_left", "move_right", "move_up", "move_down"]

const MAX_PLAYERS := 4

## Slot is unoccupied.
const DEVICE_NONE := -1


static func action_name(base: String, slot: int) -> String:
	return base + "_" + str(slot)


## Copies the current bindings for every per-player action, so a co-op session can be
## undone exactly - including any user remaps loaded from settings at startup.
static func snapshot() -> Dictionary:
	var snap := {}
	for slot in MAX_PLAYERS:
		for base in PLAYER_ACTIONS:
			var action := action_name(base, slot)
			if not InputMap.has_action(action):
				continue
			var events: Array[InputEvent] = []
			for event in InputMap.action_get_events(action):
				events.append(event.duplicate())
			snap[action] = events
	return snap


## Restores a snapshot taken by [method snapshot].
static func restore(snap: Dictionary) -> void:
	for action in snap:
		if not InputMap.has_action(action):
			continue
		InputMap.action_erase_events(action)
		for event in snap[action]:
			InputMap.action_add_event(action, event.duplicate())


static func is_joypad_event(event: InputEvent) -> bool:
	return event is InputEventJoypadButton or event is InputEventJoypadMotion


## Rewrites the per-player actions so each occupied slot responds only to its own controller.
##
## [param slot_devices] is one entry per slot: a joypad device id, or [constant DEVICE_NONE].
## [param template] is a [method snapshot] taken before any retargeting, so repeated calls always
## derive from the pristine bindings.
static func apply(slot_devices: Array, template: Dictionary) -> void:
	for slot in MAX_PLAYERS:
		var device: int = slot_devices[slot]
		for base in PLAYER_ACTIONS:
			var action := action_name(base, slot)
			if not InputMap.has_action(action):
				continue

			# Every slot mirrors the layout configured for player 1.
			var source: Array = template.get(action_name(base, 0), [])
			InputMap.action_erase_events(action)

			if device < 0:
				# Leave an unoccupied slot with no bindings at all, so a stale mapping
				# can never move a player that is not in the session.
				continue

			for event in source:
				# Keyboard events are deliberately skipped: co-op is controller-only, and that
				# includes player 1.
				if is_joypad_event(event):
					InputMap.action_add_event(action, _retarget(event, device))


static func _retarget(event: InputEvent, device: int) -> InputEvent:
	var copy := event.duplicate()
	copy.device = device
	return copy


## Joypad ids currently connected, in a stable order.
static func connected_devices() -> Array[int]:
	var devices: Array[int] = []
	for device in Input.get_connected_joypads():
		devices.append(device)
	devices.sort()
	return devices
