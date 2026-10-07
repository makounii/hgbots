--[[
	Tarkov AI - Settings catalogue

	One list of every bot parameter worth a menu, grouped, with who is
	allowed to change it. Shared, because the client builds the UI from it
	and the server validates against it - a name that isn't in here can't
	be set through the menu at all.

	Entries whose ConVar doesn't exist are dropped on load (with one line
	in the console), so renaming or removing a parameter in the AI files
	can't break the menu.
]]

hg = hg or {}
hg.bots = hg.bots or {}

--\\ Catalogue
	-- Parameters that are 0/1 switches; everything else gets a slider with
	-- the convar's own min/max.
	local BOOLS = {
		hg_bot_autoinit = true, hg_bot_spawn_refresh = true, hg_bot_weapon_switch = true,
		hg_bot_trust = true, hg_bot_trust_forget_on_death = true,
		hg_bot_reload_cover = true, hg_bot_prefire_look = true, hg_bot_hold_crouch = true,
		hg_bot_ambush = true, hg_bot_slice = true, hg_bot_suppress = true, hg_bot_prone = true,
		hg_bot_path_smoothing = true, hg_bot_avoid_water = true, hg_bot_ledge_guard = true,
		hg_bot_crawl = true, hg_bot_cqc_enabled = true, hg_bot_duel = true,
		hg_bot_lunge = true, hg_bot_pummel = true,
		hg_bot_grenades = true, hg_bot_grenade_dodge = true, hg_bot_grenade_dive = true,
		hg_bot_heal = true, hg_bot_heal_premed = true, hg_bot_heal_fear = true,
		hg_bot_downed_fight = true, hg_bot_downed_getup_when_safe = true, hg_bot_downed_ground = true,
		hg_bot_loot_crates = true, hg_bot_loot_crate_shoot = true, hg_bot_loot_corpses = true,
		hg_bot_squad = true, hg_bot_friendlyfire = true, hg_bot_morale = true,
		hg_bot_alert = true, hg_bot_alert_posture = true,
		hg_bot_voice = true, hg_bot_voice_swear = true, hg_bot_voice_chatter = true, hg_bot_voice_fastdl = true,
		hg_bot_factions = true, hg_bot_npc = true,
		hg_bot_director = true, hg_bot_director_debug = true,
		hg_bot_cleanup = true, hg_bot_cleanup_all = true, hg_bot_cleanup_debug = true,
		hg_bot_stealth = true, hg_bot_laststand = true, hg_bot_kit_random = true, hg_bot_kit_strip = true,
		hg_bot_navpatch_follow = true,
		hg_bot_debug = true, hg_bot_pathviz = true, hg_bot_navpatch_debug = true, hg_bot_morale_debug = true,
	}

	-- Parameters only a superadmin may touch (they change how the server
	-- itself behaves rather than how a bot fights).
	local SUPER = {
		hg_bot_friendlyfire = true,
		hg_bot_navpatch_follow = true, hg_bot_navpatch_gap = true, hg_bot_navpatch_maxgap = true,
		hg_bot_navpatch_slice = true, hg_bot_navpatch_width = true, hg_bot_navpatch_rate = true,
		hg_bot_director = true, hg_bot_director_max = true, hg_bot_director_difficulty = true,
		hg_bot_factions = true, hg_bot_npc = true,
	}

	local GROUPS = {
		{ id = "general", keys = {
			"hg_bot_autoinit", "hg_bot_spawn_refresh", "hg_bot_think_rate",
			"hg_bot_move_turnspeed", "hg_bot_weapon_switch", "hg_bot_gear_weight",
		}},
		{ id = "vision", keys = {
			"hg_bot_sight_range", "hg_bot_sight_fov", "hg_bot_sight_fov_peripheral",
			"hg_bot_peripheral_range", "hg_bot_peripheral_speed", "hg_bot_sight_rate",
			"hg_bot_spot_time", "hg_bot_spot_time_far", "hg_bot_spot_decay",
			"hg_bot_reacquire_time", "hg_bot_target_forget_time",
			"hg_bot_alert_gain", "hg_bot_alert_decay",
			"hg_bot_hearing_mult", "hg_bot_hearing_wall_mult", "hg_bot_hearing_error",
			"hg_bot_gunfire_radius", "hg_bot_gunfire_radius_sup",
			"hg_bot_step_radius_run", "hg_bot_step_radius_walk", "hg_bot_step_radius_duck",
			"hg_bot_whiz_radius", "hg_bot_whiz_alert", "hg_bot_damage_alert",
			"hg_bot_suppression_gain", "hg_bot_suppression_decay",
			"hg_bot_trust", "hg_bot_trust_forgive", "hg_bot_trust_forget_on_death",
			"hg_bot_aim_threat_time", "hg_bot_shooter_window",
		}},
		{ id = "alert", keys = {
			"hg_bot_alert", "hg_bot_alert_time", "hg_bot_alert_trigger",
			"hg_bot_alert_posture", "hg_bot_alert_close", "hg_bot_alert_patrol",
		}},
		{ id = "combat", keys = {
			"hg_bot_engage_dist", "hg_bot_backoff_frac", "hg_bot_chase_lead",
			"hg_bot_aim_turnspeed", "hg_bot_aim_jitter", "hg_bot_aim_tolerance",
			"hg_bot_burst_on_min", "hg_bot_burst_on_max", "hg_bot_burst_off_min", "hg_bot_burst_off_max",
			"hg_bot_reload_cover", "hg_bot_reposition_min", "hg_bot_reposition_max",
			"hg_bot_strafe_dist_min", "hg_bot_strafe_dist_max",
			"hg_bot_seek_arrive_dist", "hg_bot_seek_look_time", "hg_bot_seek_points",
			"hg_bot_seek_turnspeed", "hg_bot_seek_lead",
			"hg_bot_slice", "hg_bot_slice_range", "hg_bot_slice_time",
			"hg_bot_suppress", "hg_bot_suppress_range", "hg_bot_suppress_min_clip",
			"hg_bot_prone", "hg_bot_prone_dist", "hg_bot_prone_supp", "hg_bot_prone_chance", "hg_bot_prone_time",
			"hg_bot_tactic_push", "hg_bot_tactic_wait", "hg_bot_tactic_careful", "hg_bot_prefire_look",
			"hg_bot_cover_search_radius", "hg_bot_cover_samples", "hg_bot_cover_min_dist",
			"hg_bot_hold_duration", "hg_bot_hold_crouch", "hg_bot_hold_calm_time",
			"hg_bot_ambush", "hg_bot_ambush_radius", "hg_bot_ambush_samples",
			"hg_bot_ambush_charge_dist", "hg_bot_ambush_backstab_dist", "hg_bot_ambush_time",
			"hg_bot_flee_health_frac", "hg_bot_flee_chance", "hg_bot_flee_dist",
			"hg_bot_flee_safe_dist", "hg_bot_flee_recheck",
			"hg_bot_flee_turnback", "hg_bot_flee_scavenge",
			"hg_bot_laststand", "hg_bot_laststand_blood", "hg_bot_laststand_shock",
		}},
		{ id = "stealth", keys = {
			"hg_bot_stealth", "hg_bot_stealth_range", "hg_bot_stealth_facing", "hg_bot_stealth_min",
		}},
		{ id = "gear", keys = {
			"hg_bot_kit_random", "hg_bot_kit_strip",
		}},
		{ id = "movement", keys = {
			"hg_bot_wander_radius", "hg_bot_arrive_dist", "hg_bot_stuck_time",
			"hg_bot_path_smoothing", "hg_bot_smooth_lookahead", "hg_bot_path_trace_z",
			"hg_bot_step_height", "hg_bot_climb_height", "hg_bot_max_drop",
			"hg_bot_ground_sample", "hg_bot_avoid_water", "hg_bot_ledge_guard",
			"hg_bot_astar_max_nodes", "hg_bot_path_budget",
			"hg_bot_crawl", "hg_bot_crawl_cycle", "hg_bot_crawl_time",
			"hg_bot_crawl_range", "hg_bot_crawl_arrive",
		}},
		{ id = "melee", keys = {
			"hg_bot_cqc_enabled", "hg_bot_melee_range", "hg_bot_bash_range",
			"hg_bot_kick_range", "hg_bot_kick_chance", "hg_bot_kick_cooldown", "hg_bot_bash_retry",
			"hg_bot_duel", "hg_bot_duel_range", "hg_bot_duel_aggression", "hg_bot_duel_restyle",
			"hg_bot_duel_style_circler", "hg_bot_duel_style_hitrun", "hg_bot_duel_style_brawler",
			"hg_bot_duel_style_counter", "hg_bot_duel_style_kicker", "hg_bot_duel_style_feinter",
			"hg_bot_block_chance", "hg_bot_block_react_min", "hg_bot_block_react_max",
			"hg_bot_block_range", "hg_bot_block_turnspeed",
			"hg_bot_duel_guard", "hg_bot_duel_space", "hg_bot_duel_gunrush",
			"hg_bot_lunge", "hg_bot_lunge_min", "hg_bot_lunge_max",
			"hg_bot_lunge_chance", "hg_bot_lunge_cooldown",
			"hg_bot_pummel", "hg_bot_pummel_range", "hg_bot_pummel_time",
		}},
		{ id = "grenades", keys = {
			"hg_bot_grenades", "hg_bot_grenade_cooldown", "hg_bot_grenade_chance",
			"hg_bot_grenade_min", "hg_bot_grenade_max",
			"hg_bot_grenade_dodge", "hg_bot_grenade_danger",
			"hg_bot_grenade_dive", "hg_bot_grenade_dive_time", "hg_bot_grenade_dive_speed",
		}},
		{ id = "medical", keys = {
			"hg_bot_heal", "hg_bot_heal_blood", "hg_bot_heal_pain", "hg_bot_heal_safe",
			"hg_bot_heal_timeout", "hg_bot_heal_premed", "hg_bot_premed_cap", "hg_bot_premed_wait",
			"hg_bot_heal_fear", "hg_bot_heal_fear_at", "hg_bot_heal_fear_morale", "hg_bot_heal_adren_cap",
		}},
		{ id = "downed", keys = {
			"hg_bot_downed_fight", "hg_bot_downed_ground", "hg_bot_downed_ground_range",
			"hg_bot_downed_getup_when_safe", "hg_bot_downed_force_after", "hg_bot_downed_think_rate",
			"hg_bot_downed_aimspeed", "hg_bot_downed_aim_gain", "hg_bot_downed_aim_tol",
			"hg_bot_downed_max_offset", "hg_bot_downed_shoot_range",
		}},
		{ id = "loot", keys = {
			"hg_bot_loot_radius", "hg_bot_pickup_range", "hg_bot_loot_rescan", "hg_bot_loot_ammo_min",
			"hg_bot_loot_corpses", "hg_bot_loot_corpse_range", "hg_bot_loot_corpse_time",
			"hg_bot_loot_crates", "hg_bot_loot_crate_range", "hg_bot_loot_crate_time", "hg_bot_loot_crate_shoot",
		}},
		{ id = "squad", keys = {
			"hg_bot_squad", "hg_bot_squad_radius", "hg_bot_squad_spread", "hg_bot_squad_pushers",
			"hg_bot_squad_personal",
			"hg_bot_friendlyfire",
		}},
		{ id = "morale", keys = {
			"hg_bot_morale", "hg_bot_morale_start", "hg_bot_morale_radius",
			"hg_bot_morale_recover", "hg_bot_anger_decay",
			"hg_bot_morale_kill", "hg_bot_morale_hurt",
		}},
		{ id = "voice", keys = {
			"hg_bot_voice", "hg_bot_voice_chatter", "hg_bot_voice_swear",
			"hg_bot_voice_gap", "hg_bot_voice_world", "hg_bot_voice_range",
			"hg_bot_voice_volume", "hg_bot_voice_fastdl",
		}},
		{ id = "factions", keys = {
			"hg_bot_factions", "hg_bot_guard_follow",
			"hg_bot_npc", "hg_bot_npc_range",
		}},
		{ id = "director", keys = {
			"hg_bot_director", "hg_bot_director_difficulty", "hg_bot_director_max",
			"hg_bot_director_per_player", "hg_bot_director_rate",
			"hg_bot_director_min_dist", "hg_bot_director_max_dist",
			"hg_bot_director_buildup", "hg_bot_director_peak", "hg_bot_director_relax",
			"hg_bot_director_guards", "hg_bot_director_debug",
		}},
		{ id = "cleanup", keys = {
			"hg_bot_cleanup", "hg_bot_cleanup_corpse", "hg_bot_cleanup_looted",
			"hg_bot_cleanup_gore", "hg_bot_cleanup_gore_max", "hg_bot_cleanup_drops",
			"hg_bot_cleanup_near", "hg_bot_cleanup_all", "hg_bot_cleanup_debug",
		}},
		{ id = "navpatch", keys = {
			"hg_bot_navpatch_follow", "hg_bot_navpatch_gap", "hg_bot_navpatch_maxgap",
			"hg_bot_navpatch_slice", "hg_bot_navpatch_width", "hg_bot_navpatch_rate",
		}},
		{ id = "debug", keys = {
			"hg_bot_debug", "hg_bot_pathviz", "hg_bot_navpatch_debug", "hg_bot_morale_debug",
		}},
	}

	hg.bots.SettingGroups = GROUPS
	hg.bots.SettingIndex = {} -- [convar name] = { group, level, bool }

	for _, group in ipairs(GROUPS) do
		for _, name in ipairs(group.keys) do
			hg.bots.SettingIndex[name] = {
				group = group.id,
				level = SUPER[name] and "superadmin" or "admin",
				bool = BOOLS[name] or false,
			}
		end
	end

	--- Is this a parameter the menu is allowed to touch at all?
	function hg.bots.IsSetting(name)
		return hg.bots.SettingIndex[name] ~= nil
	end

	--- Required rights for one parameter: "admin" or "superadmin".
	function hg.bots.SettingLevel(name)
		local info = hg.bots.SettingIndex[name]

		return info and info.level or "superadmin"
	end
--//

--\\ Actions and their rights
	hg.bots.MenuActions = {
		spawn = "superadmin",
		spawn_guard = "superadmin",
		director_place = "superadmin",
		director_clear = "superadmin",
		director_status = "admin",
		spawn_random = "superadmin",
		spawn_kit = "superadmin",
		kit_save = "admin",
		kit_build = "admin",
		kit_get = "admin",
		kit_random = "admin",
		kit_delete = "admin",
		removeall = "superadmin",
		navpatch = "superadmin",
		navpatch_undo = "superadmin",
		reinit = "admin",
		remove = "superadmin",
		faction = "superadmin",
		kit_apply = "superadmin",
		teleport = "superadmin",
		enable = "admin",
		order_move = "admin",
		order_hold = "admin",
		order_follow = "admin",
		order_stop = "admin",
		state = "admin",
		preset = "admin",
	}
--//

--\\ Net message names
	hg.bots.NetSync = "hg_bot_cfg_sync"
	hg.bots.NetReq = "hg_bot_cfg_req"
	hg.bots.NetSet = "hg_bot_cfg_set"
	hg.bots.NetAct = "hg_bot_cfg_act"
	hg.bots.NetMsg = "hg_bot_cfg_msg"
	hg.bots.NetKits = "hg_bot_cfg_kits"
--//
