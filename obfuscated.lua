-- Roblox executor script (FortuneFighter place 16228705671), Airflow UI.
-- Blizzard Hub: auto parry.
-- Swing->impact is 22..159ms and ping/2 ~25ms, so a fixed delay always misses. The block is raised
-- late enough to stay fresh at impact, and at close range fired synchronously with zero delay.

if _G.FF_PARRY_UNLOAD then
	pcall(_G.FF_PARRY_UNLOAD)
	_G.FF_PARRY_UNLOAD = nil
	task.wait(0.1)
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Stats = game:GetService("Stats")

local lp = Players.LocalPlayer
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local ProximitySoundEvent = Remotes:WaitForChild("ProximitySoundEvent")
local ShieldEvent = Remotes:WaitForChild("ShieldEvent")
local ShieldEventDisable = Remotes:WaitForChild("ShieldEventDisable")
local CombatVFXEvent = Remotes:WaitForChild("CombatVFXEvent")
local DamageIndicatorEvent = Remotes:WaitForChild("DamageIndicatorEvent")
local StartCountdownEvent = Remotes:FindFirstChild("StartCountdownEvent")

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
	approach_min = 8,         -- studs/s closing that counts as inbound (walking is ~18)
	approach_lead = 0.75,     -- raise the wall when they reach punch reach within this long
	punch_reach = 9,          -- studs at which their punch can land
	turtle_after = 2,
	turtle_window = 1.0,
	turtle_hold = 0.6,
	close_range = 18,         -- inside this radius: synchronous block, no scheduled delay
	guard_enabled = false,    -- 100ms shield cycling makes the server reject the block
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

-- forward declarations: release_block cannot see the pose helpers until they exist
local pose_stop, pose_start

local function release_block(reason)
	if holding then
		holding = false
		guard_hold = false
		ShieldEventDisable:FireServer(0)
		pose_stop()
		if cfg.log then print(("[ap] %s block DOWN %s"):format(stamp(), reason or "")) end
	end
end

-- block pose: the game plays nothing for StartShieldAnimation, so we render the guard ourselves.
-- 16361064078 is 0.2s, looped while the wall is up.
local POSE_ANIM_ID = 16361064078
local pose_track = nil

function pose_stop()
	if pose_track then
		pcall(function()
			pose_track:AdjustSpeed(1)
			pose_track:Stop(0.08)
		end)
	end
	local c = my_char()
	local hum = c and c:FindFirstChildOfClass("Humanoid")
	local animator = hum and hum:FindFirstChildOfClass("Animator")
	if animator then
		for _, t in ipairs(animator:GetPlayingAnimationTracks()) do
			if t.Animation and tonumber(tostring(t.Animation.AnimationId):match("%d+")) == POSE_ANIM_ID then
				pcall(function()
					t:AdjustSpeed(1)
					t:Stop(0.08)
				end)
			end
		end
	end
end

function pose_start()
	if not cfg.pose then return end
	local c = my_char()
	local hum = c and c:FindFirstChildOfClass("Humanoid")
	local animator = hum and hum:FindFirstChildOfClass("Animator")
	if not animator then return end
	-- a respawn gives a new rig, so the cached track is stale: drop it and rebuild
	if pose_track and pose_track.Animation and pose_track.Animation.Parent ~= c then pose_track = nil end
	if not pose_track then
		local obj = nil
		for _, d in ipairs(c:GetDescendants()) do
			if d:IsA("Animation") and tonumber(tostring(d.AnimationId):match("%d+")) == POSE_ANIM_ID then obj = d break end
		end
		-- not on the rig (fresh spawn may not have loaded it): build one
		if not obj then
			obj = Instance.new("Animation")
			obj.Name = "BlizzardBlockPose"
			obj.AnimationId = "rbxassetid://" .. POSE_ANIM_ID
			obj.Parent = c
		end
		local ok, t = pcall(function() return animator:LoadAnimation(obj) end)
		if not ok or not t then return end
		pose_track = t
		pcall(function() pose_track.Priority = Enum.AnimationPriority.Action4 end)
		pcall(function() pose_track.Looped = false end)
	end
	if not pose_track.IsPlaying then
		pcall(function()
			pose_track:Play(0.04)
			pose_track:AdjustSpeed(1)
		end)
		task.spawn(function()
			local t = 0
			while pose_track and pose_track.IsPlaying and holding and t < 0.17 do
				local dt = task.wait()
				t += dt
			end
			if pose_track and pose_track.IsPlaying and holding then
				pcall(function() pose_track:AdjustSpeed(0) end)
			end
		end)
	else
		if holding and pose_track.TimePosition >= 0.16 then
			pcall(function() pose_track:AdjustSpeed(0) end)
		end
	end
end

-- block fire
local function arm(how_long, why)
	horizon = math.max(horizon, now() + how_long)
	if cfg.log and why then
		print(("[ap] %s threat %.0fms (%s)"):format(stamp(), how_long * 1000, why))
	end
end

-- delay = learned_gap - one_way_ping - lead. Gap is bucketed by distance: close punches land sooner.
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
	-- never schedule past the impact itself
	if d > gap * 0.6 then d = gap * 0.6 end
	return d
end

-- proximity is not an attack: blocking a walking enemy burns the shield and its cooldown.
local function enemy_attacking_close()
	local root = my_root()
	if not root then return false end
	local t = now()
	for plr, tr in pairs(track) do
		if tr.dist and tr.dist <= cfg.close_range and tr.state ~= "dead" and t >= tr.stun_until then
			local swung = (t - (tr.last_swing or 0)) < cfg.intent_window
			local dashed = (t - (tr.dash_t or 0)) < cfg.intent_window
			local slammed = (t - (tr.slam_t or 0)) < cfg.intent_window
			-- an attack animation (profile-bearing custom anim) currently in flight
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

-- live tracking: per-enemy position, velocity and state, refreshed every frame.
task.spawn(function()
	local prev_t = now()
	while true do
		local ok, err = pcall(function()
			local t = now()
			-- real delta, not a fixed step: a fixed 0.03s divisor underreads the closing speed
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
					-- closing speed on real dt; smoothed so one jittery frame cannot spike it
					local raw = (tr.prev_dist and tr.prev_dist < math.huge) and ((tr.prev_dist - dist) / dt) or 0
					tr.closing = tr.closing and (tr.closing * 0.6 + raw * 0.4) or raw
					tr.last_seen = t

					-- tracking telemetry only: never pre-raise block or arm on mere distance closing
					if tr.closing > cfg.approach_min then
						local reach = cfg.punch_reach
						tr.ttr = (dist - reach) / math.max(tr.closing, 0.1)
					end
					-- airborne descent over me = incoming downslam: predict landing
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
-- swing sound: measured impact is ~116ms later. arm the horizon for impact + margin.
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

	-- combo turtle: chained swings -> keep the wall up
	local recent = 0
	for _, s in ipairs(tr.swing_times) do
		if t - s < cfg.turtle_window then recent += 1 end
	end
	if recent >= cfg.turtle_after then
		arm(cfg.turtle_hold, ("combo x%d %s"):format(recent, plr.Name))
	end

	-- fire SYNCHRONOUSLY on the signal: at close range a scheduler round-trip costs a whole frame
	-- (~16ms) which is most of the 22..40ms window. Instant fire, zero delay, hold through the strike.
	local fired_instant = false
	if holding then
		-- extend the existing wall through this strike instead of toggling it
		horizon = math.max(horizon, t + cfg.close_hold)
		fired_instant = true
	elseif tr.dist and tr.dist <= cfg.close_range and (t - last_fire) >= cfg.shield_cd and not my_dead() then
		ShieldEvent:FireServer(t, 0)
		holding = true
		guard_hold = false
		last_fire = t
		pose_start()
		stats.blocks += 1
		stats.instant_blocks += 1
		horizon = math.max(horizon, t + cfg.close_hold)
		fired_instant = true
		if cfg.log then print(("[ap] %s INSTANT BLOCK dist=%.0f gap=%.0fms ping=%.0f"):format(stamp(), tr.dist, gap_for(tr) * 1000, ping())) end
	end
	if fired_instant then return end

	-- schedule the block: raise it so it is FRESH at the predicted impact (delay derived from the learned gap)
	if not holding and t >= pending_fire then
		pending_fire = t + compute_delay(tr)
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
			-- fast convergence: react to the newest punch hard, since the gap is re-learned every fight
			tr.avg_gap = tr.avg_gap and (tr.avg_gap * 0.5 + gap * 0.5) or gap
			-- bucket by distance: a close punch lands much sooner than a long one
			tr.gaps = tr.gaps or {}
			local d = tr.dist or 999
			local band = (d <= cfg.close_range) and "close" or ((d <= 30) and "mid" or "far")
			local prev = tr.gaps[band]
			tr.gaps[band] = prev and (prev * 0.5 + gap * 0.5) or gap
		end
	end
	-- learned attack animation profile: correlate with the anim that contains this impact
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
	if not holding and t >= pending_fire then
		pending_fire = t + 0.02
	end
	if cfg.log then print(("[ap] %s DOWNSLAM %s dist=%.0f airborne=%s"):format(stamp(), plr.Name, tr.dist, tostring(tr.airborne))) end
end

-- attack animation hooks (per-anim impact profiles)
local anim_profiles = {
	["18986949297"] = { offset = 0.08, samples = 10, name = "Punch1" },
	["18986951866"] = { offset = 0.08, samples = 10, name = "Punch2" },
	["18997147938"] = { offset = 0.08, samples = 10, name = "Punch3" },
	["18986953749"] = { offset = 0.08, samples = 10, name = "Punch4" },
}
local function profile_for(id, name)
	local p = anim_profiles[id]
	if not p then
		p = { offset = nil, samples = 0, name = name or id }
		anim_profiles[id] = p
	end
	return p
end

local function on_enemy_anim(plr, track_obj)
	local tr = get_track(plr)
	local t = now()
	local anim = track_obj.Animation
	local id = tostring(anim and anim.AnimationId or track_obj.Name)
	local short = id:match("(%d+)$") or id

	-- Strict combat filter: ignore all locomotion, idle, and non-action tracks
	local pri = track_obj.Priority
	if pri == Enum.AnimationPriority.Core or pri == Enum.AnimationPriority.Movement or pri == Enum.AnimationPriority.Idle then
		return
	end

	local name_lower = track_obj.Name:lower()
	if name_lower:find("walk") or name_lower:find("run") or name_lower:find("idle")
		or name_lower:find("jump") or name_lower:find("fall") or name_lower:find("climb")
		or name_lower:find("strafe") or name_lower:find("swim") or name_lower:find("tool")
		or name_lower:find("sit") then
		return
	end

	local is_default = id:find("roblox.com/asset") ~= nil
	if is_default or not cfg.enabled then return end

	local rec = { t = t, id = short, len = track_obj.Length, speed = track_obj.Speed, prof = profile_for(short, track_obj.Name) }
	tr.cur_anim = rec
	table.insert(tr.anim_hist, rec)
	while #tr.anim_hist > 8 do table.remove(tr.anim_hist, 1) end
	stats.anims += 1

	-- custom anim = attack candidate. If its profile is armed, this is an early trigger.
	local p = rec.prof
	if p.samples >= 2 and p.offset then
		local eff = p.offset / math.max(track_obj.Speed, 0.1)
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

-- sound router
-- impact sounds arrive at the VICTIM torso; attribute to the freshest recent swinger.
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
		if best then pcall(on_impact, best) end
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

-- scheduler
task.spawn(function()
	while true do
		local ok, err = pcall(function()
			local t = now()
			-- guard_active is only true on the frame the guard fires, so the hold check reads the
			-- latch instead: otherwise a 70ms guard block gets stretched to 200ms by hold_min.
			local guard_active = guard_hold
			-- fire the scheduled block (fresh at predicted impact); respect the shield cooldown
			if pending_fire > 0 and t >= pending_fire then
				pending_fire = 0
				if not holding and cfg.enabled and not my_dead() and (t - last_fire) >= cfg.shield_cd then
					ShieldEvent:FireServer(t, 0)
					holding = true
					guard_hold = false
					last_fire = t
					pose_start()
					stats.blocks += 1
					if cfg.log then print(("[ap] %s BLOCK UP (delay=%.0fms gap=%.0fms ping=%.0f)"):format(stamp(), compute_delay(nil) * 1000, gap_for(nil) * 1000, ping())) end
				end
			end
			-- close-range guard: ONLY against a real attack (intent-gated), never on mere approach
			if cfg.guard_enabled and cfg.enabled and not holding and pending_fire == 0 and not my_dead() then
				local attacking, tr, plr = enemy_attacking_close()
				if attacking then
					guard_active = true
					if t - last_fire >= math.max(cfg.guard_gap, cfg.shield_cd) then
						ShieldEvent:FireServer(t, 0)
						holding = true
						guard_hold = true
						last_fire = t
						pose_start()
						stats.blocks += 1
						stats.guard_blocks += 1
						-- the guard block itself is a threat window; horizon covers the up slice
						horizon = math.max(horizon, t + cfg.guard_up)
						if cfg.log and (t - (stats.last_guard_log or 0)) > 1.5 then
							stats.last_guard_log = t
							print(("[ap] %s GUARD (attack intent) vs %s dist=%.0f"):format(stamp(), plr and plr.Name or "?", tr and tr.dist or 0))
						end
					end
				end
			end
			-- hold while the horizon is alive (+ grace); hard caps prevent never-releasing
			if holding then
				local alive = horizon > t
				local too_long = (t - last_fire) > cfg.hold_max
				-- a guard block must expire on its OWN short slice: the 80ms grace would stretch a
				-- 70ms guard block to 210ms and make the wall stale (block, never parry)
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

-- feedback
table.insert(conns, CombatVFXEvent.OnClientEvent:Connect(function(etype, target, meta)
	local c = my_char()
	if not c then return end
	local ts = tostring(target)
	local on_me = ts == c:GetFullName()
	if etype == "parry" then
		local reactor_me = type(meta) == "table" and tostring(meta.reactor) == c:GetFullName()
		if reactor_me then
			stats.parries += 1
			print(("[ap] %s *** PARRY LANDED *** total=%d"):format(stamp(), stats.parries))
			horizon = 0
			release_block("parry landed")
		elseif on_me then
			print(("[ap] %s parried BY %s"):format(stamp(), ts:gsub("Workspace%.", "")))
		else
			local plr = Players:GetPlayerFromCharacter(target)
			if plr then get_track(plr).stun_until = now() + 1.2 end
		end
	elseif on_me and etype == "block" then
		stats.blocked += 1
		print(("[ap] %s BLOCK ABSORBED total=%d"):format(stamp(), stats.blocked))
		-- keep the guard active to absorb the rest of the combo chain
		horizon = math.max(horizon, now() + 0.3)
	elseif on_me and (etype == "stun" or etype == "break") then
		print(("[ap] %s %s ON ME"):format(stamp(), string.upper(etype)))
		horizon = 0
		release_block("debuff")
	elseif not on_me and (etype == "stun" or etype == "parry") then
		local plr = Players:GetPlayerFromCharacter(target)
		if plr then get_track(plr).stun_until = now() + 1.2 end
	end
end))

table.insert(conns, DamageIndicatorEvent.OnClientEvent:Connect(function(who, amount, tag, flag)
	local c = my_char()
	if not c or tostring(who) ~= c:GetFullName() then return end
	if tag == "blocked" then
		stats.blocked += 1
	elseif type(amount) == "number" and amount > 0 then
		stats.taken += 1
		if cfg.log then print(("[ap] %s DAMAGE TAKEN %s"):format(stamp(), tostring(amount))) end
	end
end))

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
	end))
end

table.insert(conns, Players.PlayerRemoving:Connect(function(plr)
	track[plr] = nil
	if anim_conns[plr] then pcall(function() anim_conns[plr]:Disconnect() end) anim_conns[plr] = nil end
end))

-- ui: timing is derived and locked, so only the knobs a player reasons about are exposed.
local ok_ui, Airflow = pcall(function()
	return loadstring(game:HttpGet("https://raw.githubusercontent.com/joustingmatch/-3/main/Source.luau"))()
end)

local Window
if ok_ui then
	local okb, errb = xpcall(function()
		-- Midnight base with the Blizzard cyan accent.
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
			LoadingSubtitle = "v1.0",
			Icon = "rbxassetid://74093118428711",
			ToggleUIKeybind = "RightControl",
			Backdrop = { Weather = "Snow", Tint = 0.45 },
			ConfigurationSaving = { Enabled = true, FolderName = "BlizzardHub" },
		})

		-- the palette lives on the root library, not the window: Window has no SetTheme, only
		-- LoadTheme, so calling it there fails silently and the hub keeps the default grey.
		pcall(function() Airflow:SetTheme(scheme) end)

		local Parry = Window:CreateTab({ Name = "Auto Parry", Icon = "shield" })
		local gp = Parry:CreateGroupbox({ Name = "Auto Parry", Side = "Left" })
		local gs = Parry:CreateGroupbox({ Name = "Status", Side = "Right" })

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

print(("[blizzard] hub loaded | auto parry ready | ping=%.0fms"):format(ping()))
