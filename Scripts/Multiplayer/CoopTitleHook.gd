class_name CoopTitleHook
extends Node

## Adds the co-op entry to the title screen at runtime.
##
## TitleScreen.tscn wires its menu by *position*: `TitleScreenOptions.option_selected` emits
## `option_<index + 1>_selected`, and the scene connects those signals to specific nodes. Editing
## that scene to add an entry would mean touching one of the files upstream changes most, so the
## entry is injected here instead - appended last, so it becomes `option_4_selected` and no
## existing index shifts.
##
## Instantiated by [CoopManager]; it watches for a TitleScreen entering the tree.

const OPTIONS_PATH := "CanvasLayer/Options1"
const CAMPAIGN_SELECT_PATH := "CanvasLayer/CampaignSelect"
const OPTION_LABEL_NAME := "CoopOption"
const OPTION_TEXT := "CO-OP"

var _lobby: CoopLobby = null


func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)


func _on_node_added(node: Node) -> void:
	if node is TitleScreen:
		_install.call_deferred(node)


func _install(title: TitleScreen) -> void:
	if not is_instance_valid(title) or not title.is_inside_tree():
		return

	# Returning to the title screen is the clean reset point: drop any controller assignment
	# and put the input map back the way upstream had it.
	Coop.end_session()

	var options := title.get_node_or_null(OPTIONS_PATH) as TitleScreenOptions
	if options == null:
		push_warning("[Co-op] Title screen options not found at %s; co-op entry not added." % OPTIONS_PATH)
		return
	if options.get_node_or_null(OPTION_LABEL_NAME) != null:
		return
	if options.options.is_empty():
		return

	var template: Label = options.options[0]
	var label: Label = template.duplicate()
	label.name = OPTION_LABEL_NAME
	label.text = OPTION_TEXT
	label.visible = true
	options.add_child(label)
	# Sit directly below the last real entry, ahead of the trailing Buffer control.
	options.move_child(label, options.options[options.options.size() - 1].get_index() + 1)
	options.options.append(label)

	_lobby = CoopLobby.create(template)
	title.add_child(_lobby)

	if not options.option_4_selected.is_connected(_open_lobby):
		options.option_4_selected.connect(_open_lobby.bind(title, options))


func _open_lobby(title: TitleScreen, options: TitleScreenOptions) -> void:
	if _lobby == null or not is_instance_valid(_lobby):
		return
	options.close()
	if not _lobby.start_requested.is_connected(_on_start_requested):
		_lobby.start_requested.connect(_on_start_requested.bind(title))
	if not _lobby.cancelled.is_connected(_on_cancelled):
		_lobby.cancelled.connect(_on_cancelled.bind(options))
	_lobby.open()


## Hands straight over to the normal campaign flow - the same node `option_1_selected` opens -
## so co-op inherits campaign select, save slots and the story intro without duplicating them.
func _on_start_requested(title: TitleScreen) -> void:
	var campaign_select := title.get_node_or_null(CAMPAIGN_SELECT_PATH)
	if campaign_select != null and campaign_select.has_method("open"):
		campaign_select.open()


func _on_cancelled(options: TitleScreenOptions) -> void:
	options.open()
