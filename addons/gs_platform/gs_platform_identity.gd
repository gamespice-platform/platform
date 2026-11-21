class_name GSPlatformIdentity
extends Node

## Who a player is, for a game: content delivery, a profile, an avatar, and one admission
## flow, built in the order they depend on each other.
##
## [codeblock]
## GameSpice Cloud    downloads and mounts content. Registers `gs_cloud_client`.
## GameSpice Auth     reports this server to its site listing, when asked to.
## GameSpice User     the profile that follows a player between servers (on the site, for a
##              player the site issued a key for, when the host holds its credential).
## gs-avatar   what they look like, over the GAME's schema.
## GameSpice Platform joins the three into ONE admission, as its own GSModule.
## [/codeblock]
##
## [b]This is the identity layer every game had a copy of.[/b] game-fatal-contact's was 262 lines
## and game-airdrift's 215, and with the class names taken out they differed in one line:
## which avatar schema, and which stock avatar a player without one gets. Those are the two
## things a game hands this; everything else is the chain.
##
## [b]Authentication is not here.[/b] Proving who somebody is happens in GameSpice Server's
## handshake, against whatever `gs_auth_server` the host registered; a deployment turns it
## on for every game it runs, and a game does not get a say. What this layer does is
## everything AFTER that: turning the proven identity into a scoped profile, a name and an
## avatar.
##
## [b]GameSpice Cloud is registered or it is not built at all.[/b] Four call sites in two other
## addons look it up under `gs_cloud_client`, and every one of them treats an absent cloud
## as "this deployment ships its content in its build" — a legitimate configuration, and
## therefore indistinguishable from `GSCloudClient` once failing to publish itself, which
## left GameSpice Server, GameSpice User Avatar and GameSpice Map all finding null without one error between
## them. A registered client that failed to start is a third thing: present, found, and
## unable to do anything.
##
## [codeblock]
## var identity := GSPlatformIdentity.new()
## identity.avatar_schema = MyAvatars.schema()
## identity.stock_avatar_fn = MyAvatars.stock_avatar
## add_child(identity)
## await identity.setup()
## # By PATH: GSModuleHost constructs the module itself, and finds the hub this
## # registered. platform_module() is for a host that adds the node by hand.
## await server.modules.load_module("res://addons/gs_platform/gs_platform_module.gd")
## [/codeblock]
##
## A GameSpice Game module returns one from `_make_identity()` and needs none of the last line:
## [code]GSGameModule[/code] loads the platform module itself.

const CHANNEL := "platform.identity"

@export_group("Content")

## Where delivered content is fetched from. Empty means everything ships in the build.
@export var content_urls: PackedStringArray = PackedStringArray()

## Directories searched before the network. A server serving content off its own disk.
@export var content_dirs: PackedStringArray = PackedStringArray()

@export_group("Backbone")

## Report the player count, the map and the roster to the site listing.
##
## Off by default. A server that phones home without its operator asking is a server
## nobody would run, and GameSpice Auth's own defaults agree.
@export var report_to_backbone: bool = false

## Where the backbone is. Empty uses [GSAuthConfig]'s own default.
##
## [b]A default endpoint is a security property, not a convenience.[/b] GameSpice Auth once
## shipped a domain that was not the site and was registered to nobody, so every deployment
## that did not override it aimed the opening request of an authentication flow at a name
## any stranger could buy.
@export var backbone_url: String = ""

@export_group("Admission")

## Refuse a player whose profile could not be resolved.
##
## Off. An unreachable profile store is a reason to let somebody play as a guest, not a
## reason to leave them at a loading screen.
@export var require_profile: bool = false

@export_group("Avatars")

## The game's avatar schema. Set before [method setup].
##
## [b]The game's own, never a second one.[/b] A game's renderer conforms every document to
## its schema before drawing it, so a manager validating against a different schema would
## accept avatars the renderer then silently rewrote. Null builds no avatar manager, and
## nobody has an avatar — which GameSpice Platform already answers.
var avatar_schema: GSAvatarSchema = null

## `func(player_key: StringName) -> GSAvatar`: the avatar a player with none of their own
## gets. Unset, [method GSAvatarSchema.default_avatar] — which dresses everybody alike.
##
## A game usually derives it from the key, so two stock players are not identical and one
## player is the same on every machine and every visit.
var stock_avatar_fn: Callable = Callable()

## `func(site_avatar: GSAvatar) -> GSAvatar`: a member's site avatar, in this game's
## schema. See [member GSAvatarManager.translate_fn].
##
## The site keeps one avatar per member over its own `builtin` schema; a game with a
## schema of its own says here what those choices mean in its terms. Unset, a member's
## site avatar is not drawn and they wear the game's stock look.
var avatar_translate_fn: Callable = Callable()

## Read avatars from the site when the server holds an integration credential.
##
## [b]On, and found rather than configured.[/b] A host that has registered a
## `gs_backbone_client` (GameSpice Server Deploy does, from data/listing.json) has the one
## credential the site's avatar route accepts for this server, and the keys GameSpice Auth's
## scoped introspection hands GameSpice User are the ones that route resolves. Without it the
## manager's store is a local file the site never sees, which is how every avatar a
## member chose on the site stayed there. Read only: a server draws players and the site
## is where they dress, and AVATAR_WRITE is a scope an operator should have to ask for.
var use_backbone_avatars: bool = true

## Keep the profiles of players the site issued a key for on the site, when the server
## holds an integration credential.
##
## [b]On, found the same way as the avatar store, and only for those players.[/b] With
## it, a member's name, avatar choice and preferences follow them to every server whose
## credential shares a scope (an app-bound credential: the app; a server's own enrolled
## one: that server). Everybody else — guests, local accounts, any key GameSpice User derived
## from this server's own secret — keeps a profile on this server's disk as before: the
## site has never heard of their key, and sending it would make every read a first-time
## player and every save on leave an ERROR. See [GSPlatformProfileStore]. Read and
## written: the credential needs PROFILE_READ and PROFILE_WRITE, and a credential
## without them is said once and falls back to this server's disk.
var use_backbone_profiles: bool = true

var cloud: GSCloudClient = null
var users: GSUserManager = null
var avatars: GSAvatarManager = null
var platform: GSPlatformHub = null
var backbone: GSBackboneClient = null

var _module: GSPlatformModule = null


## Builds the whole chain. Returns the platform hub.
func setup() -> GSResult:
	# Awaited, and typed, every one. Each step may reach a network — a content source, a
	# profile store, an avatar store — and an un-awaited GDScript coroutine returns at its
	# first suspension, so the branch after it would be testing a property of a Signal.
	var clouded: GSResult = await _build_cloud()

	if not clouded.ok:
		return clouded

	if report_to_backbone:
		# Not fatal. A server that cannot reach the backbone is a server that runs without
		# a site listing, which is every LAN server there has ever been.
		var reached: GSResult = await _build_backbone()
		GSLog.result(CHANNEL, "the backbone client", reached)

	var usered: GSResult = await _build_users()

	if not usered.ok:
		return usered

	var avatared: GSResult = await _build_avatars()

	if not avatared.ok:
		return avatared

	var platformed: GSResult = await _build_platform()
	return platformed


func _build_cloud() -> GSResult:
	if content_urls.is_empty() and content_dirs.is_empty():
		# [b]No sources means no client, and building one anyway is worse than not.[/b]
		# `GSCloudClient.start` refuses when signing is required and no trusted key is
		# configured — correctly, because a client that mounts unsigned content will mount
		# anything a server sends it — and says so with a red line on every boot: the shape
		# this family calls "a warning that reads like a setting nobody has filled in".
		GSLog.info(CHANNEL, "content ships in this build", {
			"reason": "no content sources are configured"
		})
		return GSResult.success(null)

	cloud = GSCloudClient.new()
	cloud.name = "Cloud"
	cloud.http_base_urls = content_urls
	cloud.local_search_dirs = content_dirs
	# Registered: the line whose absence cost four silent failures. See the class note.
	cloud.register_service = true
	add_child(cloud)

	var started: GSResult = await cloud.start()

	if not started.ok:
		# Downgraded rather than fatal: a game whose content ships in its build is the
		# ordinary case rather than a broken one.
		GSLog.info(CHANNEL, "content delivery is off", {"why": started.error.message})

	return GSResult.success(cloud)


func _build_backbone() -> GSResult:
	# The host's client, when it has one (GameSpice Server Deploy builds it from data/listing.json), is the
	# server's credential. A second client here is built from a bare GSAuthConfig with no token, so it
	# fails with "No integration token" at ERROR on every boot of an enrolled server and reports nothing.
	var host_client: Object = GSRegistry.get_service(&"gs_backbone_client")

	if host_client != null:
		GSLog.info(CHANNEL, "the host's backbone client is used", {})
		return GSResult.success(null)

	var config := GSAuthConfig.new()

	if backbone_url != "":
		config.backbone_url = backbone_url

	backbone = GSBackboneClient.new()
	backbone.name = "Backbone"
	backbone.config = config
	backbone.auto_report = true
	add_child(backbone)

	var ready: GSResult = await backbone.start()
	return ready


func _build_users() -> GSResult:
	var managed := GSPlatformUsers.new()

	if use_backbone_profiles:
		# Before add_child: the manager's _ready builds its store.
		managed.site_store = _backbone_profile_store()

	users = managed
	users.name = "Users"
	users.register_service = true
	add_child(users)

	var ready: GSResult = await users.setup()
	return ready


func _build_avatars() -> GSResult:
	if avatar_schema == null:
		GSLog.info(CHANNEL, "no avatars", {"reason": "the game gave no avatar schema"})
		return GSResult.success(null)

	avatars = GSAvatarManager.new()
	avatars.name = "Avatars"
	avatars.schema = avatar_schema
	# [b]The game's stock look for somebody with nothing stored, not the schema's one
	# document.[/b] Admission resolves a first-time player to the manager's default, and a
	# game prefers the platform's answer to its own — so without this, everybody the
	# platform had admitted was the same person, and the per-player variety a game draws
	# lasted exactly until the profile arrived. Asked with the scoped key, so a player is
	# the same person on every visit. Read at call time, so a game may set it late.
	avatars.default_avatar_fn = func(user_key: String) -> GSAvatar:
		if not stock_avatar_fn.is_valid():
			return null
		var stock: Variant = stock_avatar_fn.call(StringName(user_key))
		return stock as GSAvatar if stock is GSAvatar else null
	avatars.translate_fn = func(foreign: GSAvatar) -> GSAvatar:
		if not avatar_translate_fn.is_valid():
			return null
		var mine: Variant = avatar_translate_fn.call(foreign)
		return mine as GSAvatar if mine is GSAvatar else null

	if use_backbone_avatars:
		var site_store := _backbone_avatar_store()

		if site_store != null:
			avatars.store = site_store

	avatars.register_service = true
	add_child(avatars)

	var ready: GSResult = await avatars.setup()
	return ready


## The site's avatar store over the host's integration credential, or null.
func _backbone_avatar_store() -> GSAvatarStoreBackbone:
	var credential := _integration_credential()

	if credential.is_empty():
		return null

	var store := GSAvatarStoreBackbone.at(credential[0], credential[1])
	store.read_only = true

	GSLog.info(CHANNEL, "avatars are read from the site", {"url": credential[0]})
	return store


## The site's profile store over the host's integration credential, or null.
func _backbone_profile_store() -> GSUserStoreBackbone:
	var credential := _integration_credential()

	if credential.is_empty():
		return null

	var store := GSUserStoreBackbone.at(credential[0], credential[1])

	GSLog.info(CHANNEL, "site-issued players' profiles live on the site", {
		"url": credential[0]
	})
	return store


## `[integration base URL, token]` from the host's `gs_backbone_client`, or empty.
##
## Duck-typed through the registry: the client is GameSpice Auth's, and a host without one is
## a LAN server whose avatars and profiles are its own.
func _integration_credential() -> PackedStringArray:
	var client: Object = GSRegistry.get_service(&"gs_backbone_client")
	var cfg: Object = client.get("config") if client != null else null

	if cfg == null or not cfg.has_method("integration_endpoint"):
		return PackedStringArray()

	var token := str(cfg.get("integration_token")).strip_edges()

	if token == "":
		return PackedStringArray()

	var base := str(cfg.call("integration_endpoint", "")).trim_suffix("/")
	return PackedStringArray([base, token])


func _build_platform() -> GSResult:
	var config := GSPlatformConfig.new()
	config.require_profile = require_profile
	# Never. A player without an avatar gets a stock document that is a real avatar over
	# the same schema; refusing them would be refusing somebody for the colour of a capsule.
	config.require_avatar = false
	config.apply_profile_name = true
	config.broadcast_avatar_changes = true

	platform = GSPlatformHub.new()
	platform.name = "Platform"
	platform.config = config
	platform.load_layered_config = false
	platform.register_service = true
	add_child(platform)

	var ready: GSResult = await platform.setup()
	return ready


## The module a [GSServer] loads to put this in front of joining players.
##
## GameSpice Platform ships its own [GSModule], which is the right shape: everything it
## registers is removed again when it unloads, and a game that wanted a different admission
## flow replaces one module rather than editing another.
func platform_module() -> GSPlatformModule:
	if _module == null:
		_module = GSPlatformModule.new()
		_module.platform = platform

	return _module


func _notification(what: int) -> void:
	# [b]The module is a Node outside the tree until a server loads it.[/b] One nothing
	# loaded — a GameSpice Game module loads GameSpice Platform's own by path, and a test asks only to
	# compare it — has no parent to free it, and outlives this layer as a leaked instance
	# holding the hub it was bound to. One a server DID load is the server's to free.
	if what == NOTIFICATION_PREDELETE and is_instance_valid(_module) \
			and _module.get_parent() == null:
		_module.free()


## An avatar for a player: theirs if the platform resolved one, a stock one if not.
##
## [b]Never null while there is a schema, and that is the contract.[/b] A caller that had
## to branch on "did this player have an avatar" would be a caller that draws nothing for a
## guest, and a server full of invisible guests is worse than one full of identical ones.
## Null only when the game gave no schema, which is a game with no avatars.
func avatar_for(player_key: String) -> GSAvatar:
	if platform != null:
		var held := platform.player(player_key)

		if held != null and held.avatar != null:
			return held.avatar

	if stock_avatar_fn.is_valid():
		var stock: Variant = stock_avatar_fn.call(StringName(player_key))

		if stock is GSAvatar:
			return stock as GSAvatar

	if avatar_schema != null:
		return avatar_schema.default_avatar()

	return null


func describe() -> Dictionary:
	return {
		"cloud": cloud.describe() if cloud != null else {},
		"users": users.describe() if users != null else {},
		"avatars": avatars.describe() if avatars != null else {},
		"platform": platform.describe() if platform != null else {},
		"backbone": backbone.describe() if backbone != null else {},
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	if platform != null:
		out.append_array(platform.describe_lines())

	if users != null:
		out.append_array(users.describe_lines())

	if avatars != null:
		out.append_array(avatars.describe_lines())

	return out
