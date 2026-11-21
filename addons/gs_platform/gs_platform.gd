@tool
class_name GSPlatformHub
extends Node

## Turns an authenticated identity into a player who can enter the world.
##
## [codeblock]
## var platform := GSPlatformHub.new()
## add_child(platform)
##
## var admitted := await platform.admit(identity)
## var player: GSPlatformPlayer = admitted.value
## [/codeblock]
##
## [b]This is the seam nothing else was testing.[/b] GameSpice Auth, GameSpice User and
## GameSpice User Avatar each pass their own self-tests in isolation, and each is
## deliberately unaware of the others — that independence is what makes them
## adoptable one at a time. The cost is that the handoffs between them existed only in
## documentation. This is the handoff, as code, with a self-test that runs all three
## in one process.
##
## [b]Everything optional stays optional.[/b] The managers are found through
## [GSRegistry], never imported, and each one being absent has a defined answer:
##
## - no GameSpice User: every player is a guest with a session identity and no profile;
## - no GameSpice User Avatar: nobody has an avatar and nothing asks for one;
## - neither: [method admit] still returns a usable player, and a game that only
##   wanted authentication has paid nothing for the rest.
##
## That is not politeness. A sandbox that required all three to start would be
## unusable on the first day of a project, which is the day people decide whether to
## adopt something.

const CHANNEL := "platform"
const SERVICE := &"gs_platform"

## Registry names of the addons this joins. Looked up, never imported.
const USER_SERVICE := &"gs_user_manager"
const AVATAR_SERVICE := &"gs_avatar_manager"

## Emitted once a player is fully admitted.
signal player_admitted(player: GSPlatformPlayer)

## Emitted when admission stops. The hook for a rejection message.
signal player_refused(player: GSPlatformPlayer, reason: String)

## Emitted when a player publishes a new avatar.
signal avatar_changed(player: GSPlatformPlayer)

## Emitted when a player leaves and their state is released.
signal player_released(key: String)

@export_group("Configuration")

@export var config: GSPlatformConfig = null

@export var config_file: String = "user://gs_platform.json"

@export var load_layered_config: bool = true

@export_group("Wiring")

@export var register_service: bool = true

@export var service_scope: StringName = &""

## Where a player's entitlements come from.
##
## Takes the identity, returns a [GSAvatarEntitlements]. Unset, every player gets
## whatever is marked free in the schema and nothing else — which is the safe
## default: a bug here should make a cosmetic unwearable, never wearable by everyone.
var entitlement_source: Callable = Callable()

## scoped key -> GSPlatformPlayer, for everyone currently admitted.
var _players: Dictionary = {}

var _registered_name: StringName = &""
var _ready_ok: bool = false

## Admissions that ran out of time and let the player in anyway.
var timed_out_count: int = 0


# --- Lifecycle -------------------------------------------------------------

func _ready() -> void:
	if Engine.is_editor_hint():
		return

	var res := setup()

	if not res.ok:
		GSLog.result(CHANNEL, "platform setup", res)


func setup() -> GSResult:
	if config == null:
		config = GSPlatformConfig.new()

	if load_layered_config or config_file != "":
		var loaded := config.load_layered(config_file)
		if not loaded.ok:
			return loaded.wrap("Platform configuration is not usable.")
	else:
		var valid := config.validate()
		if not valid.ok:
			return valid.wrap("Platform configuration is not usable.")

	if register_service:
		_registered_name = (
			GSRegistry.scoped_name(SERVICE, service_scope)
			if service_scope != &"" else SERVICE
		)
		GSRegistry.register(_registered_name, self)

	_ready_ok = true

	GSLog.info(
		CHANNEL,
		"platform ready",
		{
			"config": config.describe_summary(),
			"profiles": users() != null,
			"avatars": avatars() != null,
		}
	)

	return GSResult.success(null)


func _exit_tree() -> void:
	if _registered_name != &"":
		GSRegistry.unregister_instance(_registered_name, self)
		_registered_name = &""


func is_ready() -> bool:
	return _ready_ok


## GameSpice User's manager, or null.
func users() -> Object:
	return GSRegistry.get_service(USER_SERVICE)


## GameSpice User Avatar's manager, or null.
func avatars() -> Object:
	return GSRegistry.get_service(AVATAR_SERVICE)


# --- Admission -------------------------------------------------------------

## Takes an authenticated identity all the way to a player who can enter the world.
##
## Never fails for "this player is new" — that is the common case. It fails only when
## the configuration says a missing profile or avatar is disqualifying, or when the
## identity itself is unusable.
func admit(identity: Object) -> GSResult:
	if not _ready_ok:
		return GSResult.fail(
			GSError.CODE_STATE, "The platform is not ready yet."
		)

	if identity == null:
		return GSResult.fail(GSError.CODE_INVALID, "No identity to admit.")

	var player := GSPlatformPlayer.for_identity(identity)
	player.entitlements = _entitlements_for(identity)

	var deadline := (
		Time.get_ticks_msec() + int(config.admission_timeout_sec * 1000.0)
	)

	var profiled := await _resolve_profile(player)

	if not profiled:
		return _refuse(player)

	# The timeout is checked between stages rather than raced against them, because a
	# store call that is already in flight cannot be cancelled and abandoning it would
	# leak the result into the next player's admission.
	if Time.get_ticks_msec() > deadline:
		timed_out_count += 1
		GSLog.warn(
			CHANNEL,
			"admission ran out of time; letting the player in with what resolved",
			{"key": player.key(), "name": player.display_name()}
		)
		return _finish(player)

	var dressed := await _resolve_avatar(player)

	if not dressed:
		return _refuse(player)

	return _finish(player)


func _resolve_profile(player: GSPlatformPlayer) -> bool:
	var manager := users()

	if manager == null:
		# No GameSpice User installed. The player has no profile and everything downstream
		# has to cope, which is why key() is allowed to be empty.
		player.stage = GSPlatformPlayer.Stage.PROFILED
		return true

	var resolved: GSResult = await manager.call("resolve", player.identity)

	if not resolved.ok:
		if config.require_profile:
			player.refuse(resolved.error)
			return false

		GSLog.warn(
			CHANNEL,
			"could not resolve a profile; admitting without one",
			{"error": str(resolved.error)}
		)
		player.stage = GSPlatformPlayer.Stage.PROFILED
		return true

	player.profile = resolved.value

	# GameSpice User marks a stand-in profile by leaving created_at at zero, and refuses to
	# persist one. Carrying that fact forward matters: a game that wrote to this
	# profile would be writing to something that is deliberately never saved, and the
	# change would vanish without an error.
	if manager.has_method("is_persistable"):
		player.degraded = not bool(
			manager.call("is_persistable", player.profile)
		)

	player.stage = GSPlatformPlayer.Stage.PROFILED
	return true


func _resolve_avatar(player: GSPlatformPlayer) -> bool:
	var manager := avatars()

	if manager == null:
		player.stage = GSPlatformPlayer.Stage.DRESSED
		return true

	var key := player.key()

	if key == "":
		# No profile, so no scoped key to file an avatar under. Refusing to invent one
		# is the point: the only other option is keying on the account id, which is
		# exactly the correlation GameSpice User's scoping exists to prevent.
		GSLog.debug(
			CHANNEL,
			"no profile key, so no avatar; install gs-user to give players one"
		)
		player.stage = GSPlatformPlayer.Stage.DRESSED
		return true

	var had_avatar: bool = await _stored_avatar_exists(manager, key)

	var resolved: GSResult = await manager.call(
		"resolve", key, player.entitlements
	)

	if not resolved.ok:
		if config.require_avatar:
			player.refuse(resolved.error)
			return false

		GSLog.warn(
			CHANNEL,
			"could not resolve an avatar; admitting without one",
			{"key": key, "error": str(resolved.error)}
		)
		player.stage = GSPlatformPlayer.Stage.DRESSED
		return true

	player.avatar = resolved.value
	player.needs_onboarding = _needs_onboarding(player, had_avatar)

	if config.require_avatar and player.needs_onboarding:
		player.refuse(GSError.make(
			GSError.CODE_STATE,
			"Make an avatar before joining.",
			key
		))
		return false

	player.stage = GSPlatformPlayer.Stage.DRESSED
	return true


## Whether the store already held an avatar for this player.
##
## Asked before resolving, because [code]resolve[/code] hands back the schema default
## for a player who has none — so afterwards there is no way to tell a first-time
## player from one wearing exactly the defaults.
func _stored_avatar_exists(manager: Object, key: String) -> bool:
	var store: Variant = manager.get("store")

	if store == null or not (store is Object):
		return false

	var fetched: GSResult = await (store as Object).call("fetch", key)

	return fetched.ok and fetched.value != null


func _needs_onboarding(player: GSPlatformPlayer, had_avatar: bool) -> bool:
	if config.onboarded_needs_avatar and not had_avatar:
		return true

	if player.profile != null:
		return not player.profile.onboarded

	return false


func _entitlements_for(identity: Object) -> GSAvatarEntitlements:
	if not entitlement_source.is_valid():
		# Nothing owned. A part is wearable only if the schema marks it free, which is
		# the safe direction to fail in.
		return GSAvatarEntitlements.none()

	var supplied: Variant = entitlement_source.call(identity)

	if supplied is GSAvatarEntitlements:
		return supplied

	GSLog.warn(
		CHANNEL,
		"the entitlement source returned something else; granting nothing",
		{"got": type_string(typeof(supplied))}
	)

	return GSAvatarEntitlements.none()


func _finish(player: GSPlatformPlayer) -> GSResult:
	player.stage = GSPlatformPlayer.Stage.READY

	if player.key() != "":
		_players[player.key()] = player

	player_admitted.emit(player)

	GSLog.info(
		CHANNEL,
		"player admitted",
		{
			"key": player.key(),
			"name": player.display_name(),
			"avatar": player.avatar.digest() if player.avatar != null else "-",
			"onboarding": player.needs_onboarding,
		}
	)

	return GSResult.success(player)


func _refuse(player: GSPlatformPlayer) -> GSResult:
	var reason := (
		player.refusal.message if player.refusal != null else "Refused."
	)

	player_refused.emit(player, reason)

	GSLog.info(
		CHANNEL, "player refused", {"name": player.display_name(), "reason": reason}
	)

	return GSResult.failure(
		player.refusal if player.refusal != null
		else GSError.make(GSError.CODE_FORBIDDEN, "Refused.")
	)


# --- While they are here ----------------------------------------------------

func player(key: String) -> GSPlatformPlayer:
	return _players.get(key)


func players() -> Array[GSPlatformPlayer]:
	var out: Array[GSPlatformPlayer] = []

	for key in _players:
		out.append(_players[key])

	return out


func count() -> int:
	return _players.size()


## Accepts a new avatar from a player and republishes it.
##
## [b]Goes through GameSpice User Avatar's own validation[/b] rather than trusting what
## arrived, and passes the entitlements resolved at admission — not any the client
## sent, which would make the whole entitlement system a suggestion.
func set_avatar(key: String, avatar: GSAvatar) -> GSResult:
	var target := player(key)

	if target == null:
		return GSResult.fail(
			GSError.CODE_INVALID, "That player is not here.", key
		)

	var manager := avatars()

	if manager == null:
		return GSResult.fail(
			GSError.CODE_UNSUPPORTED, "This server has no avatar support."
		)

	var published: GSResult = await manager.call(
		"publish", key, avatar, target.entitlements
	)

	if not published.ok:
		return published

	target.avatar = avatar
	target.needs_onboarding = false

	# The profile records that first-time setup is done, so a reconnect does not send
	# them back to the editor.
	if target.profile != null and not target.profile.onboarded:
		target.profile.onboarded = true

		var users_manager := users()
		if users_manager != null and not target.degraded:
			var saved: GSResult = await users_manager.call("save", target.profile)
			if not saved.ok:
				GSLog.result(CHANNEL, "recording onboarding", saved)

	avatar_changed.emit(target)

	return GSResult.success(avatar.digest())


## Changes a display name, through GameSpice User so every name rule applies.
func set_display_name(key: String, requested: String) -> GSResult:
	var target := player(key)

	if target == null:
		return GSResult.fail(GSError.CODE_INVALID, "That player is not here.")

	var manager := users()

	if manager == null or target.profile == null:
		return GSResult.fail(
			GSError.CODE_UNSUPPORTED, "This server has no profiles."
		)

	return manager.call(
		"set_display_name", target.profile, requested, target.is_guest()
	)


## Releases a player's platform state when they leave.
func release(key: String) -> void:
	var target := player(key)

	if target == null:
		return

	_players.erase(key)

	var users_manager := users()
	if users_manager != null and users_manager.has_method("release"):
		users_manager.call("release", key)

	var avatar_manager := avatars()
	if avatar_manager != null and avatar_manager.has_method("release"):
		avatar_manager.call("release", key)

	player_released.emit(key)


# --- Diagnostics -----------------------------------------------------------

func describe() -> Dictionary:
	return {
		"ready": _ready_ok,
		"config": config.describe_summary() if config != null else "<none>",
		"profiles": "gs-user" if users() != null else "<absent>",
		"avatars": "gs-user-avatar" if avatars() != null else "<absent>",
		"players": _players.size(),
		"timed_out": timed_out_count,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	out.append("platform     %s" % (
		config.describe_summary() if config != null else "<unconfigured>"
	))
	out.append("profiles     %s" % (
		"gs-user" if users() != null else "not installed"
	))
	out.append("avatars      %s" % (
		"gs-user-avatar" if avatars() != null else "not installed"
	))
	out.append("players      %d admitted" % _players.size())

	if timed_out_count > 0:
		out.append("timed out    %d admission(s)" % timed_out_count)

	for p in players():
		out.append("  %-24s %-16s %s" % [
			p.key(), p.display_name(), p.stage_name()
		])

	return out


# --- A note on the name ----------------------------------------------------
#
# This class is GSPlatformHub, not GSPlatform, because GameSpice Core already has a
# GSPlatform — the capability helper behind GSPlatform.has_threads() and
# GSPlatform.is_web(). class_name is global in Godot and these addons install side
# by side, so the collision was not a style problem: it made GameSpice Core's own scripts
# fail to parse the moment this addon was present, and the errors pointed at
# GameSpice Auth, which does not mention either class.
#
# Worth checking a proposed class_name against every addon in the family before
# taking it, not just against the one being written.
