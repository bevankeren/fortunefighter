-- Roblox executor script (FortuneFighter place 16228705671), Airflow UI.
-- Blizzard Hub: auto parry + ML training telemetry.
-- Swing->impact is 22..159ms and ping/2 ~25ms, so a fixed delay always misses. The block is raised
-- late enough to stay fresh at impact, and at close range fired synchronously with zero delay.
-- Telemetry automatically captures combat exchanges and dumps JSON dataset when any player hits 4 points.

if _G.FF_PARRY_UNLOAD then
	pcall(_G.FF_PARRY_UNLOAD)
	_G.FF_PARRY_UNLOAD = nil
	task.wait(0.1)
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Stats = game:GetService("Stats")
local HttpService = game:GetService("HttpService")

local lp = Players.LocalPlayer
local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local cfg = {
	enabled = true,
	manual_delay = -1,        -- -1 derives the delay from the learned gap, >=0 overrides in seconds
	impact_lead = 0.025,      -- freshness margin before impact
	base_gap = 0.09,          -- seed, replaced by the learned gap
	release_grace = 0.12,     -- extra wall time after the horizon clears, for chained punches
	hold_min = 0.22,
	hold_max = 0.85,
	range = 42,
	hard_range = 70,
	slam_range = 48,
	dash_trigger = 24,
	dash_lead = 0.20,
	approach_min = 8,         -- studs/s closing that counts as inbound
	approach_lead = 0.75,
	punch_reach = 9,
	turtle_after = 2,
	turtle_window = 1.0,
	turtle_hold = 0.6,
	close_range = 18,         -- inside this radius: synchronous block, no scheduled delay
	guard_enabled = false,
	guard_up = 0.07,
	guard_gap = 0.03,
	intent_window = 0.9,
	shield_cd = 0.18,         -- minimum spacing between block raises
	close_hold = 0.45,
	pose = true,              -- the game ships no shield pose, so we play one
	log = true,
}

local track = {}          -- [player] = live record
local horizon = 0         -- wall stays up while a threat_until exceeds now
local holding = false
local guard_hold = false  -- wall in play came from the close-range guard
local pending_fire = 0
local last_fire = 0
local T0 = workspace:GetServerTimeNow()
local conns = {}
local anim_conns = {}
local stats = { signals = 0, blocks = 0, blocked = 0, taken = 0, parries = 0, slams = 0, dashes = 0, anims = 0, last_gap = 0, gaps = {}, guard_blocks = 0, instant_blocks = 0 }

local function now() return workspace:GetServerTimeNow() end
local function stamp() return ("%.3f"):format(now() - T0) end
local function ping()
	local ok, v = pcall(function() return Stats.Network.ServerStatsItem["Data Ping"]:GetValue() end)
	return ok and v or -1
end
local function my_char() return lp.Character end
local function my_root()
	local c = my_char()
	return c and c:FindFirstChild("HumanoidRootPart")
end
local function my_dead()
	local c = my_char()
	if not c then return true end
	local h = c:FindFirstChildOfClass("Humanoid")
	return (not h) or h.Health <= 0
end

local function get_track(plr)
	if not plr or plr == lp then return nil end
	local t = track[plr]
	if not t then
		t = { plr = plr, last_swing = 0, swing_times = {}, stun_until = 0, cur_anim = nil, anim_hist = {},
			threat_until = 0, expect_impact = 0, airborne = false, vy = 0, closing = 0, dist = math.huge,
			state = "?", last_seen = 0, dash_t = 0, slam_t = 0 }
		track[plr] = t
	end
	return t
end

-- Forward declarations
local pose_stop, pose_start, release_block
local ShieldEvent = Remotes:FindFirstChild("ShieldEvent")
local ShieldEventDisable = Remotes:FindFirstChild("ShieldEventDisable")

function release_block(reason)
	if holding then
		holding = false
		guard_hold = false
		if ShieldEventDisable then
			pcall(function() ShieldEventDisable:FireServer(0) end)
		end
		pose_stop()
		if cfg.log then print(("[ap] %s block DOWN %s"):format(stamp(), reason or "")) end
	end
end

-- block pose
local POSE_ANIM_ID = 16361064078
local pose_track = nil

function pose_stop()
	if pose_track then
		pcall(function()
			pose_track:AdjustSpeed(1)
			pose_track:Stop(0.08)
		end)
		pose_track = nil
	end
end

function pose_start()
	if not cfg.pose then return end
	local c = my_char()
	local hum = c and c:FindFirstChildOfClass("Humanoid")
	local animator = hum and (hum:FindFirstChildOfClass("Animator") or hum:WaitForChild("Animator", 2))
	if not animator then return end
	if pose_track and pose_track.IsPlaying then return end
	pose_stop()
	pcall(function()
		local anim = Instance.new("Animation")
		anim.AnimationId = "rbxassetid://" .. POSE_ANIM_ID
		local tk = animator:LoadAnimation(anim)
		tk.Priority = Enum.AnimationPriority.Action4
		tk.Looped = false
		tk:Play(0.04, 1, 1)
		pose_track = tk
		task.delay(0.17, function()
			if pose_track == tk and holding then
				pcall(function() tk:AdjustSpeed(0) end)
			end
		end)
	end)
end

-- arm threat horizon
local function arm(duration, reason)
	local t = now()
	local until_t = t + duration
	if until_t > horizon then
		horizon = until_t
		if cfg.log then print(("[ap] %s arm +%.0fms (total %.0fms) [%s]"):format(stamp(), duration * 1000, (horizon - t) * 1000, reason or "")) end
	end
end

-- timing model
local function gap_for(tr)
	if not tr then return cfg.base_gap end
	local d = tr.dist or 999
	if tr.gaps then
		if d <= cfg.close_range and tr.gaps.close then return tr.gaps.close end
		if d <= 30 and tr.gaps.mid then return tr.gaps.mid end
		if tr.gaps.far then return tr.gaps.far end
	end
	return tr.avg_gap or cfg.base_gap
end

local function compute_delay(tr)
	if cfg.manual_delay >= 0 then return cfg.manual_delay end
	local gap = gap_for(tr)
	local one_way = (ping() / 2) / 1000
	local d = gap - one_way - cfg.impact_lead
	if d < 0 then d = 0 end
	if d > gap * 0.6 then d = gap * 0.6 end
	return d
end

local function enemy_attacking_close()
	local root = my_root()
	if not root then return false end
	local t = now()
	for plr, tr in pairs(track) do
		if tr.dist and tr.dist <= cfg.close_range and tr.state ~= "dead" and t >= tr.stun_until then
			local swung = (t - (tr.last_swing or 0)) < cfg.intent_window
			local dashed = (t - (tr.dash_t or 0)) < cfg.intent_window
			local slammed = (t - (tr.slam_t or 0)) < cfg.intent_window
			local animating = false
			local ca = tr.cur_anim
			if ca and ca.prof and ca.prof.samples >= 2 then
				local eff = (ca.len or 1) / math.max(ca.speed or 1, 0.1)
				animating = (t - ca.t) < eff + 0.15
			end
			if swung or dashed or slammed or animating then
				return true, tr, plr
			end
		end
	end
	return false
end

-- =========================================================================
-- TELEMETRY & ML TRAINING RECORDER
-- =========================================================================
local telemetry = {
	completed_matches = (_G.FF_TELEMETRY and _G.FF_TELEMETRY.completed_matches) or {},
	current_match = nil,
	pending_exchanges = {},
	exchange_counter = 0,
	save_count = 0,
	latest_json = "",
}

local function start_new_match(opponent_name)
	local opp_plr = nil
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= lp then opp_plr = p break end
	end
	local opp_str = opp_plr and opp_plr.Name or (opponent_name or "duel_opponent")
	local m_id = ("match_%d_%s"):format(os.time(), opp_str)
	telemetry.current_match = {
		id = m_id,
		place_id = game.PlaceId,
		start_time = os.time(),
		wall_start = os.date("!%Y-%m-%d %H:%M:%SZ"),
		opponent = {
			name = opp_str,
			userId = opp_plr and opp_plr.UserId or 0
		},
		score = { p1 = 0, p2 = 0 },
		max_score = 0,
		exchanges = {},
		summary = { parries = 0, blocks = 0, taken = 0, total_swings = 0 },
		saved = false,
	}
	telemetry.pending_exchanges = {}
	print(("[telemetry] >>> NEW MATCH SESSION: %s vs %s <<<"):format(lp.Name, opp_str))
end

local function save_current_match(reason)
	local m = telemetry.current_match
	if not m or m.saved then return end
	m.saved = true
	m.end_time = os.time()
	m.end_reason = reason or "score_4_points"
	m.summary.parries = stats.parries
	m.summary.blocks = stats.blocked
	m.summary.taken = stats.taken
	m.summary.total_swings = stats.signals

	table.insert(telemetry.completed_matches, m)
	telemetry.save_count += 1

	local ok_enc, json = pcall(function()
		return HttpService:JSONEncode(m)
	end)

	if ok_enc and json then
		telemetry.latest_json = json
		if writefile then
			pcall(function()
				local fname = "training_data_" .. m.id .. ".json"
				writefile(fname, json)
				print("[telemetry] Saved dataset to disk: " .. fname)
			end)
		end
	end

	print("=========================================================")
	print(("[telemetry] MATCH #%d SAVED [Reason: %s]"):format(telemetry.save_count, m.end_reason))
	print(("[telemetry] Match ID: %s | Score: %d - %d"):format(m.id, m.score.p1 or 0, m.score.p2 or 0))
	print(("[telemetry] Exchanges Logged: %d | Parries: %d | Blocks: %d | Taken: %d"):format(#m.exchanges, stats.parries, stats.blocked, stats.taken))
	print("=========================================================")
end

local function resolve_pending_exchange(outcome, impact_t, extra)
	local best_ex, best_idx = nil, nil
	for i = #telemetry.pending_exchanges, 1, -1 do
		local ex = telemetry.pending_exchanges[i]
		if (impact_t - ex.t_swing) <= 0.75 and ex.outcome == "pending" then
			best_ex = ex
			best_idx = i
			break
		end
	end
	if best_ex then
		best_ex.outcome = outcome
		best_ex.t_impact = impact_t
		best_ex.actual_gap_ms = math.round((impact_t - best_ex.t_swing) * 1000)
		if extra and extra.damage then best_ex.damage = extra.damage end
		table.remove(telemetry.pending_exchanges, best_idx)
	end
end

-- Periodic cleaner for pending exchanges
task.spawn(function()
	while true do
		task.wait(0.5)
		local t = now()
		for i = #telemetry.pending_exchanges, 1, -1 do
			local ex = telemetry.pending_exchanges[i]
			if t - ex.t_swing > 0.9 then
				if ex.outcome == "pending" then
					ex.outcome = (ex.dist > 25) and "whiff" or "miss"
				end
				table.remove(telemetry.pending_exchanges, i)
			end
		end
	end
end)

-- Global telemetry interface for MCP & scripts
_G.FF_TELEMETRY = {
	completed_matches = telemetry.completed_matches,
	current_match = telemetry.current_match,
	get_state = function()
		return {
			current_id = telemetry.current_match and telemetry.current_match.id or "none",
			completed_count = #telemetry.completed_matches,
			logged_exchanges = telemetry.current_match and #telemetry.current_match.exchanges or 0,
			score = telemetry.current_match and telemetry.current_match.score or { p1 = 0, p2 = 0 },
			saved = telemetry.current_match and telemetry.current_match.saved or false,
		}
	end,
	get_latest_json = function()
		return telemetry.latest_json or "{}"
	end,
	get_match_json = function(idx)
		local m = telemetry.completed_matches[idx] or telemetry.current_match
		if m then
			local ok, s = pcall(function() return HttpService:JSONEncode(m) end)
			if ok then return s end
		end
		return "{}"
	end,
	force_save = function(reason)
		save_current_match(reason or "force_save")
	end,
	start_match = function(opp)
		start_new_match(opp)
	end,
}

-- Tracker loop
task.spawn(function()
	local prev_t = now()
	while true do
		local ok, err = pcall(function()
			local t = now()
			local dt = math.max(t - prev_t, 0.001)
			prev_t = t
			local root = my_root()
			if not root or my_dead() then
				for _, tr in pairs(track) do tr.dist = math.huge end
				return
			end
			for plr, tr in pairs(track) do
				if plr == lp then
					track[plr] = nil
					continue
				end
				local c = plr.Character
				local hrp = c and c:FindFirstChild("HumanoidRootPart")
				local hum = c and c:FindFirstChildOfClass("Humanoid")
				if not hrp or not hum or hum.Health <= 0 then
					tr.dist = math.huge
					tr.state = "dead"
					tr.closing = 0
				else
					local delta = hrp.Position - root.Position
					local dist = delta.Magnitude
					tr.prev_dist = tr.dist
					tr.dist = dist
					tr.pos = hrp.Position
					tr.vel = hrp.AssemblyLinearVelocity
					tr.state = tostring(hum:GetState())
					tr.airborne = (hum:GetState() == Enum.HumanoidStateType.Freefall or hum:GetState() == Enum.HumanoidStateType.Jumping)
					tr.vy = tr.vel.Y
					tr.health = hum.Health
					local raw = (tr.prev_dist and tr.prev_dist < math.huge) and ((tr.prev_dist - dist) / dt) or 0
					tr.closing = tr.closing and (tr.closing * 0.6 + raw * 0.4) or raw
					tr.last_seen = t

					if tr.closing > cfg.approach_min then
						local reach = cfg.punch_reach
						tr.ttr = (dist - reach) / math.max(tr.closing, 0.1)
					end
					if tr.airborne and tr.vy < -25 and dist < cfg.slam_range then
						local fall = math.abs(hrp.Position.Y - root.Position.Y)
						local t_land = fall / math.max(math.abs(tr.vy), 1)
						if t_land < 0.9 then
							arm(t_land + 0.25, "downslam fall " .. plr.Name)
						end
					end
				end
			end
		end)
		if not ok then warn("[ap] tracker: " .. tostring(err)) end
		RunService.Heartbeat:Wait()
	end
end)

-- signals
local function on_swing(plr)
	local tr = get_track(plr)
	local t = now()
	if t < tr.stun_until then return end
	tr.last_swing = t
	table.insert(tr.swing_times, t)
	while #tr.swing_times > 8 do table.remove(tr.swing_times, 1) end
	stats.signals += 1

	local gap = tr.avg_gap or cfg.base_gap
	local impact_in = math.max(gap - cfg.impact_lead, 0.02)
	tr.expect_impact = t + impact_in
	arm(impact_in + 0.16, "swing " .. plr.Name)

	-- Log to telemetry
	local ex_id = telemetry.exchange_counter + 1
	telemetry.exchange_counter = ex_id
	local cur_ex = {
		id = ex_id,
		attacker = plr.Name,
		t_swing = t,
		dist = tr.dist or -1,
		closing = tr.closing or 0,
		airborne = tr.airborne or false,
		vy = tr.vy or 0,
		anim_id = tr.cur_anim and tr.cur_anim.id or "none",
		anim_speed = tr.cur_anim and tr.cur_anim.speed or 1,
		ping_ms = ping(),
		block_attempted = false,
		block_mode = "none",
		t_block_fire = 0,
		delay_scheduled = 0,
		outcome = "pending",
		t_impact = 0,
		actual_gap_ms = 0,
		damage = 0,
	}
	if telemetry.current_match then
		table.insert(telemetry.current_match.exchanges, cur_ex)
		table.insert(telemetry.pending_exchanges, cur_ex)
	end

	-- combo turtle
	local recent = 0
	for _, s in ipairs(tr.swing_times) do
		if t - s < cfg.turtle_window then recent += 1 end
	end
	if recent >= cfg.turtle_after then
		arm(cfg.turtle_hold, ("combo x%d %s"):format(recent, plr.Name))
	end

	-- fire SYNCHRONOUSLY on the signal inside close range
	local fired_instant = false
	if holding then
		horizon = math.max(horizon, t + cfg.close_hold)
		fired_instant = true
		cur_ex.block_attempted = true
		cur_ex.block_mode = "extended_hold"
		cur_ex.t_block_fire = t
	elseif tr.dist and tr.dist <= cfg.close_range and (t - last_fire) >= cfg.shield_cd and not my_dead() then
		if ShieldEvent then ShieldEvent:FireServer(t, 0) end
		holding = true
		guard_hold = false
		last_fire = t
		pose_start()
		stats.blocks += 1
		stats.instant_blocks += 1
		horizon = math.max(horizon, t + cfg.close_hold)
		fired_instant = true
		cur_ex.block_attempted = true
		cur_ex.block_mode = "instant"
		cur_ex.t_block_fire = t
		if cfg.log then print(("[ap] %s INSTANT BLOCK dist=%.0f gap=%.0fms ping=%.0f"):format(stamp(), tr.dist, gap_for(tr) * 1000, ping())) end
	end
	if fired_instant then return end

	-- schedule the block
	if not holding and t >= pending_fire then
		local d = compute_delay(tr)
		pending_fire = t + d
		cur_ex.delay_scheduled = d
	end
end

local function on_impact(plr)
	local tr = get_track(plr)
	local t = now()
	if tr.last_swing > 0 then
		local gap = t - tr.last_swing
		if gap > 0.02 and gap < 0.5 then
			table.insert(stats.gaps, gap)
			if #stats.gaps > 40 then table.remove(stats.gaps, 1) end
			stats.last_gap = gap
			tr.avg_gap = tr.avg_gap and (tr.avg_gap * 0.5 + gap * 0.5) or gap
			tr.gaps = tr.gaps or {}
			local d = tr.dist or 999
			local band = (d <= cfg.close_range) and "close" or ((d <= 30) and "mid" or "far")
			local prev = tr.gaps[band]
			tr.gaps[band] = prev and (prev * 0.5 + gap * 0.5) or gap
		end
	end
	local best, best_start = nil, -1
	for _, ca in ipairs(tr.anim_hist) do
		local eff = (ca.len or 1) / math.max(ca.speed or 1, 0.1)
		local rel = t - ca.t
		if rel >= -0.3 and rel <= eff + 0.3 and ca.t > best_start and (ca.len or 1) <= 1.2 then
			best, best_start = ca, ca.t
		end
	end
	if best then
		local off = t - best.t
		if off > 0.02 and off < 0.6 then
			local p = best.prof
			p.offset = p.offset and (p.offset * 0.65 + off * 0.35) or off
			p.samples += 1
			tr.avg_gap = tr.avg_gap or off
		end
	end
end

local function on_downslam(plr)
	local tr = get_track(plr)
	local t = now()
	tr.slam_t = t
	stats.slams += 1
	arm(0.45, "downslam " .. plr.Name)
end

-- enemy animation tracking
local anim_profiles = {}
local function get_anim_profile(id)
	local p = anim_profiles[id]
	if not p then
		p = { samples = 0, offset = nil }
		anim_profiles[id] = p
	end
	return p
end

local KNOWN_ATTACK_ANIM_IDS = {
	["18986949297"] = true,
	["18986951866"] = true,
	["18997147938"] = true,
	["18986953749"] = true,
	["18505543219"] = true,
	["18505554445"] = true,
	["102539226343990"] = true,
}

local function on_enemy_anim(plr, track_obj)
	if not cfg.enabled then return end
	local a = track_obj.Animation
	local id = a and a.AnimationId or ""
	if id == "" then return end
	local num_id = id:match("%d+") or ""
	local tr = get_track(plr)
	local t = now()

	local prio = track_obj.Priority
	if prio == Enum.AnimationPriority.Core or prio == Enum.AnimationPriority.Idle or prio == Enum.AnimationPriority.Movement then
		return
	end

	local name_lower = track_obj.Name:lower()
	if name_lower:find("walk") or name_lower:find("run") or name_lower:find("idle") or name_lower:find("jump") or name_lower:find("fall") or name_lower:find("climb") then
		return
	end

	local is_known_attack = KNOWN_ATTACK_ANIM_IDS[num_id] == true
	local short = num_id ~= "" and num_id or id:sub(-14)
	local rec = { id = id, num_id = num_id, t = t, len = track_obj.Length, speed = track_obj.Speed, prof = get_anim_profile(id), is_attack = is_known_attack }
	tr.cur_anim = rec
	table.insert(tr.anim_hist, rec)
	while #tr.anim_hist > 8 do table.remove(tr.anim_hist, 1) end
	stats.anims += 1

	local p = rec.prof
	if is_known_attack or (p.samples >= 2 and p.offset) then
		local eff = (p.offset or 0.11) / math.max(track_obj.Speed, 0.1)
		if eff > 0.02 and eff < 0.8 then
			local impact_in = math.max(eff - cfg.impact_lead, 0.02)
			tr.expect_impact = t + impact_in
			arm(impact_in + 0.16, "anim " .. short)
			if not holding and t >= pending_fire then
				pending_fire = t + compute_delay(tr)
			end
		end
	end
end

local function hook_anim(plr)
	if plr == lp then return end
	if anim_conns[plr] and anim_conns[plr].Connected then return end
	local function try(char)
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local animator = hum and (hum:FindFirstChildOfClass("Animator") or hum:WaitForChild("Animator", 3))
		if animator then
			if anim_conns[plr] then pcall(function() anim_conns[plr]:Disconnect() end) end
			anim_conns[plr] = animator.AnimationPlayed:Connect(function(tk)
				pcall(on_enemy_anim, plr, tk)
			end)
		end
	end
	if plr.Character then try(plr.Character) end
	table.insert(conns, plr.CharacterAdded:Connect(function(c)
		task.wait(0.4)
		try(c)
	end))
	if plr.Character then try(plr.Character) end
end

for _, plr in ipairs(Players:GetPlayers()) do
	if plr ~= lp then
		get_track(plr)
		pcall(hook_anim, plr)
	end
end
table.insert(conns, Players.PlayerAdded:Connect(function(plr)
	task.wait(0.5)
	get_track(plr)
	pcall(hook_anim, plr)
end))

-- Scheduler
task.spawn(function()
	while true do
		local ok, err = pcall(function()
			local t = now()
			local guard_active = guard_hold
			if pending_fire > 0 and t >= pending_fire then
				pending_fire = 0
				if not holding and cfg.enabled and not my_dead() and (t - last_fire) >= cfg.shield_cd then
					if ShieldEvent then ShieldEvent:FireServer(t, 0) end
					holding = true
					guard_hold = false
					last_fire = t
					pose_start()
					stats.blocks += 1
					
					-- update pending exchange
					local latest_ex = telemetry.pending_exchanges[#telemetry.pending_exchanges]
					if latest_ex and (t - latest_ex.t_swing) < 0.6 then
						latest_ex.block_attempted = true
						latest_ex.block_mode = "scheduled"
						latest_ex.t_block_fire = t
					end
					
					if cfg.log then print(("[ap] %s BLOCK UP (delay=%.0fms gap=%.0fms ping=%.0f)"):format(stamp(), compute_delay(nil) * 1000, gap_for(nil) * 1000, ping())) end
				end
			end
			if cfg.guard_enabled and cfg.enabled and not holding and pending_fire == 0 and not my_dead() then
				local attacking, tr, plr = enemy_attacking_close()
				if attacking then
					guard_active = true
					if t - last_fire >= math.max(cfg.guard_gap, cfg.shield_cd) then
						if ShieldEvent then ShieldEvent:FireServer(t, 0) end
						holding = true
						guard_hold = true
						last_fire = t
						pose_start()
						stats.blocks += 1
						stats.guard_blocks += 1
						horizon = math.max(horizon, t + cfg.guard_up)
						if cfg.log and (t - (stats.last_guard_log or 0)) > 1.5 then
							stats.last_guard_log = t
							print(("[ap] %s GUARD vs %s dist=%.0f"):format(stamp(), plr and plr.Name or "?", tr and tr.dist or 0))
						end
					end
				end
			end
			if holding then
				local alive = horizon > t
				local too_long = (t - last_fire) > cfg.hold_max
				local min_served = (t - last_fire) >= (guard_active and cfg.guard_up or cfg.hold_min)
				local graced = (not guard_active) and ((t - horizon) < cfg.release_grace)
				if ((not alive and not graced) and min_served) or too_long or my_dead() then
					release_block(alive and "cap" or "clear")
				end
			end
		end)
		if not ok then warn("[ap] scheduler: " .. tostring(err)) end
		RunService.Heartbeat:Wait()
	end
end)

-- Main remotes binder
local function bind_duel_remotes()
	ShieldEvent = Remotes:WaitForChild("ShieldEvent", 10)
	ShieldEventDisable = Remotes:FindFirstChild("ShieldEventDisable")
	local ProximitySoundEvent = Remotes:FindFirstChild("ProximitySoundEvent")
	local CombatVFXEvent = Remotes:FindFirstChild("CombatVFXEvent")
	local DamageIndicatorEvent = Remotes:FindFirstChild("DamageIndicatorEvent")
	local StartCountdownEvent = Remotes:FindFirstChild("StartCountdownEvent")
	local UpdatePointsAndRound = Remotes:FindFirstChild("UpdatePointsAndRound")
	local DisplayEnding = Remotes:FindFirstChild("DisplayEnding")

	if not ShieldEvent or not ProximitySoundEvent then
		return false
	end

	local function is_me(obj)
		if not obj then return false end
		local c = my_char()
		if typeof(obj) == "Instance" then
			if c and (obj == c or obj:IsDescendantOf(c)) then return true end
			if obj.Name == lp.Name then return true end
		elseif type(obj) == "string" then
			if obj == lp.Name or (c and obj == c:GetFullName()) or obj:find(lp.Name, 1, true) then return true end
		end
		return false
	end

	-- Sound router
	table.insert(conns, ProximitySoundEvent.OnClientEvent:Connect(function(action, torso, asset, key, ...)
		if not cfg.enabled then return end
		if action ~= "play" or typeof(torso) ~= "Instance" then return end
		local aname = typeof(asset) == "Instance" and asset.Name or tostring(asset)
		local k = tostring(key)
		local t = now()

		if k == "punch" or (aname:find("Punch", 1, true) and not aname:find("PunchSwing", 1, true)) then
			local best, best_t = nil, 0
			for plr, tr in pairs(track) do
				if t - tr.last_swing < 0.8 and tr.last_swing > best_t then best, best_t = plr, tr.last_swing end
			end
			if best then
				pcall(on_impact, best)
				if is_me(torso) then
					resolve_pending_exchange("hit_or_blocked", t)
				end
			end
			return
		end

		local char = torso.Parent
		local plr = char and Players:GetPlayerFromCharacter(char)
		if not plr or plr == lp then return end
		local tr = get_track(plr)
		local root = my_root()
		if root and (root.Position - torso.Position).Magnitude > cfg.hard_range then return end

		if k == "swing" or aname:find("PunchSwing", 1, true) then
			pcall(on_swing, plr)
		elseif k:lower():find("slam") or k:lower():find("smash") or aname:find("DownSmash", 1, true) then
			pcall(on_downslam, plr)
		elseif k:lower():find("dash") or aname:find("Dash", 1, true) then
			tr.dash_t = t
			stats.dashes += 1
			arm(cfg.dash_lead, "dash-sound " .. plr.Name)
		end
	end))

	-- Combat feedback
	if CombatVFXEvent then
		table.insert(conns, CombatVFXEvent.OnClientEvent:Connect(function(etype, target, meta)
			local c = my_char()
			if not c then return end
			local on_me = is_me(target)
			local t = now()
			if etype == "parry" then
				local reactor_me = (type(meta) == "table" and is_me(meta.reactor)) or on_me
				if reactor_me then
					stats.parries += 1
					print(("[ap] %s *** PARRY LANDED *** total=%d"):format(stamp(), stats.parries))
					horizon = 0
					release_block("parry landed")
					resolve_pending_exchange("parry", t)
				else
					local plr = Players:GetPlayerFromCharacter(target)
					if plr then get_track(plr).stun_until = now() + 1.2 end
				end
			elseif on_me and etype == "block" then
				stats.blocked += 1
				print(("[ap] %s BLOCK ABSORBED total=%d"):format(stamp(), stats.blocked))
				horizon = math.max(horizon, now() + 0.3)
				resolve_pending_exchange("block", t)
			elseif on_me and (etype == "stun" or etype == "break") then
				print(("[ap] %s %s ON ME"):format(stamp(), string.upper(etype)))
				horizon = 0
				release_block("debuff")
			elseif not on_me and (etype == "stun" or etype == "parry") then
				local plr = Players:GetPlayerFromCharacter(target)
				if plr then get_track(plr).stun_until = now() + 1.2 end
			end
		end))
	end

	-- Damage indicator
	if DamageIndicatorEvent then
		table.insert(conns, DamageIndicatorEvent.OnClientEvent:Connect(function(who, amount, tag, flag)
			if not is_me(who) then return end
			local t = now()
			if tag == "blocked" then
				stats.blocked += 1
				resolve_pending_exchange("block", t)
			elseif type(amount) == "number" and amount > 0 then
				stats.taken += 1
				resolve_pending_exchange("taken", t, { damage = amount })
				if cfg.log then print(("[ap] %s DAMAGE TAKEN %s"):format(stamp(), tostring(amount))) end
			end
		end))
	end

	-- Points & round updates (Telemetry Trigger)
	if UpdatePointsAndRound then
		table.insert(conns, UpdatePointsAndRound.OnClientEvent:Connect(function(...)
			local args = {...}
			local p1_score, p2_score = nil, nil
			local max_val = 0
			if type(args[1]) == "number" and type(args[2]) == "number" then
				p1_score, p2_score = args[1], args[2]
				max_val = math.max(p1_score, p2_score)
			elseif type(args[1]) == "table" then
				local nums = {}
				for k, v in pairs(args[1]) do
					if type(v) == "number" then
						table.insert(nums, v)
						if v > max_val then max_val = v end
					end
				end
				p1_score = nums[1] or 0
				p2_score = nums[2] or 0
			end
			if telemetry.current_match then
				if p1_score and p2_score then
					telemetry.current_match.score = { p1 = p1_score, p2 = p2_score }
				end
				telemetry.current_match.max_score = math.max(telemetry.current_match.max_score or 0, max_val)
				if max_val >= 4 and not telemetry.current_match.saved then
					print(("[telemetry] 4 points reached (%s - %s) -> SAVING DATASET"):format(tostring(p1_score), tostring(p2_score)))
					save_current_match("score_4_points")
				end
			end
		end))
	end

	if DisplayEnding then
		table.insert(conns, DisplayEnding.OnClientEvent:Connect(function(...)
			print("[telemetry] DisplayEnding received -> SAVING DATASET")
			if telemetry.current_match and not telemetry.current_match.saved then
				save_current_match("display_ending")
			end
		end))
	end

	if StartCountdownEvent then
		table.insert(conns, StartCountdownEvent.OnClientEvent:Connect(function()
			for plr in pairs(track) do track[plr] = nil end
			horizon = 0
			pending_fire = 0
			release_block("round")
			for _, plr in ipairs(Players:GetPlayers()) do
				if plr ~= lp then get_track(plr) end
			end
			print("[ap] round reset")
			if not telemetry.current_match or telemetry.current_match.saved then
				start_new_match()
			end
		end))
	end

	-- Start initial match
	if not telemetry.current_match or telemetry.current_match.saved then
		start_new_match()
	end
	return true
end

-- Fallback GUI score scanner
task.spawn(function()
	while true do
		task.wait(1)
		pcall(function()
			local m = telemetry.current_match
			if m and not m.saved then
				local pg = lp:FindFirstChildOfClass("PlayerGui")
				if pg then
					for _, d in ipairs(pg:GetDescendants()) do
						if d:IsA("TextLabel") and d.Visible then
							local s1, s2 = d.Text:match("^(%d)%s*[-:]%s*(%d)$")
							if s1 and s2 then
								local n1, n2 = tonumber(s1), tonumber(s2)
								if n1 and n2 then
									m.score = { p1 = n1, p2 = n2 }
									m.max_score = math.max(n1, n2)
									if (n1 >= 4 or n2 >= 4) and not m.saved then
										print(("[telemetry] GUI score 4 reached (%d-%d) -> Saving match dataset!"):format(n1, n2))
										save_current_match("gui_score_4")
										break
									end
								end
							end
						end
					end
				end
			end
		end)
	end
end)

-- Auto-connect duel remotes when available
task.spawn(function()
	while not bind_duel_remotes() do
		task.wait(1.5)
	end
	print("[blizzard] Duel combat & telemetry successfully bound!")
end)

table.insert(conns, Players.PlayerRemoving:Connect(function(plr)
	track[plr] = nil
	if anim_conns[plr] then pcall(function() anim_conns[plr]:Disconnect() end) anim_conns[plr] = nil end
end))

-- Airflow UI
local ok_ui, Airflow = pcall(function()
	return loadstring(game:HttpGet("https://raw.githubusercontent.com/joustingmatch/-3/main/Source.luau"))()
end)

local Window
if ok_ui then
	local okb, errb = xpcall(function()
		local scheme = {
			Background = Color3.fromRGB(15, 18, 26),
			Surface = Color3.fromRGB(18, 22, 31),
			Surface2 = Color3.fromRGB(22, 26, 37),
			Surface3 = Color3.fromRGB(37, 44, 60),
			Stroke = Color3.fromRGB(34, 40, 55),
			StrokeHover = Color3.fromRGB(58, 92, 104),
			Accent = Color3.fromRGB(100, 205, 215),
			AccentDark = Color3.fromRGB(14, 18, 30),
			Text = Color3.fromRGB(228, 232, 242),
			Muted = Color3.fromRGB(116, 126, 148),
			Warning = Color3.fromRGB(240, 176, 108),
			Success = Color3.fromRGB(150, 220, 170),
			Error = Color3.fromRGB(240, 120, 120),
		}

		Window = Airflow:CreateWindow({
			Name = "Blizzard Hub",
			LoadingSubtitle = "v1.1 (ML Telemetry)",
			Icon = "rbxassetid://74093118428711",
			ToggleUIKeybind = "RightControl",
			Backdrop = { Weather = "Snow", Tint = 0.45 },
			ConfigurationSaving = { Enabled = true, FolderName = "BlizzardHub" },
		})

		pcall(function() Airflow:SetTheme(scheme) end)

		local Parry = Window:CreateTab({ Name = "Auto Parry", Icon = "shield" })
		local gp = Parry:CreateGroupbox({ Name = "Auto Parry", Side = "Left" })
		local gs = Parry:CreateGroupbox({ Name = "Status", Side = "Right" })
		local gt = Parry:CreateGroupbox({ Name = "Training Telemetry", Side = "Right" })

		gp:CreateToggle({ Name = "Enable", Flag = "ParryEnable", CurrentValue = true, Callback = function(v)
			cfg.enabled = v
			if not v then horizon = 0 release_block("off") end
		end })
		gp:CreateSlider({ Name = "Reaction Range", Range = { 10, 70 }, Increment = 2, Suffix = " studs", CurrentValue = 42, Flag = "ParryRange", Callback = function(v) cfg.range = v end })
		gp:CreateSlider({ Name = "Close Range", Range = { 8, 30 }, Increment = 1, Suffix = " studs", CurrentValue = 18, Flag = "ParryClose", Callback = function(v) cfg.close_range = v end })
		gp:CreateToggle({ Name = "Block Pose", Flag = "ParryPose", CurrentValue = true, Callback = function(v)
			cfg.pose = v
			if not v then pose_stop() end
		end })

		gs:CreateStatus({ Name = "State", Style = "Row", Pin = true, Update = function()
			if not cfg.enabled then return "<Error>Disabled</Error>" end
			if holding then return "<Success>Blocking</Success>" end
			if horizon > now() then return "<Warning>Engaging</Warning>" end
			return "<Accent>Watching</Accent>"
		end })
		gs:CreateStatus({ Name = "Parries", Style = "Row", Update = function() return "<Success>" .. stats.parries .. "</Success>" end })
		gs:CreateStatus({ Name = "Blocks / Hits Taken", Style = "Row", Update = function() return ("<Accent>%d</Accent> / <Error>%d</Error>"):format(stats.blocked, stats.taken) end })

		-- Telemetry UI
		gt:CreateStatus({ Name = "Current Match", Style = "Row", Update = function()
			return telemetry.current_match and telemetry.current_match.id or "None"
		end })
		gt:CreateStatus({ Name = "Score", Style = "Row", Update = function()
			if not telemetry.current_match then return "-" end
			local s = telemetry.current_match.score
			return ("<Accent>%d</Accent> - <Error>%d</Error>"):format(s.p1 or 0, s.p2 or 0)
		end })
		gt:CreateStatus({ Name = "Exchanges Logged", Style = "Row", Update = function()
			local count = telemetry.current_match and #telemetry.current_match.exchanges or 0
			return "<Accent>" .. tostring(count) .. "</Accent>"
		end })
		gt:CreateStatus({ Name = "Saved Datasets", Style = "Row", Update = function()
			return "<Success>" .. tostring(telemetry.save_count) .. "</Success>"
		end })
		gt:CreateButton({ Name = "Force Save Match", Style = "Default", Callback = function()
			save_current_match("manual_button")
		end })

		local Settings = Window:CreateTab({ Name = "Settings", Icon = "settings" })
		Settings:CreateConfigManager({ Side = "Left" })
		Settings:CreateThemeManager({ Side = "Right" })
		local gsc = Settings:CreateGroupbox({ Name = "Hub", Side = "Left" })
		gsc:CreateButton({ Name = "Unload Hub", Style = "Danger", Callback = function()
			task.spawn(function() if _G.FF_PARRY_UNLOAD then _G.FF_PARRY_UNLOAD() end end)
		end })
		pcall(function() Window:LoadAutoload() end)
	end, function(e) return debug.traceback(tostring(e), 2) end)
	if not okb then warn("[ap] UI build failed: " .. tostring(errb)) Window = nil end
else
	warn("[ap] Airflow load failed: " .. tostring(Airflow))
end

_G.FF_PARRY_UNLOAD = function()
	horizon = 0
	pending_fire = 0
	pose_stop()
	release_block("unload")
	for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	for _, c in pairs(anim_conns) do pcall(function() c:Disconnect() end) end
	conns = {}
	anim_conns = {}
	if Window then pcall(function() Window:Destroy() end) Window = nil end
	print("[ap] unloaded")
end

print(("[blizzard] hub loaded | auto parry + telemetry ready | ping=%.0fms"):format(ping()))
