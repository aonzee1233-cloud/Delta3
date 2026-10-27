--[[
Goblin Auto v12.4 | Fisch - FischFright 3 | Delta
Run it once while the event is on. Re-running replaces the previous instance.

Flow per goblin (nearest first):
TP -> Talk -> pick difficulty -> read objective -> do it -> TP back -> Talk -> claim

Auto objectives : type in chat, dance, jump, walk
Skipped + logged: catch / perfect catch / drown / burn / freeze / trick-or-treat / guess / insult

What changed in v12.4 (wave hunt + held quests)
 * Teleporting is now a "hunt": teleport + scan the islands only until CFG.goblinCount (3) NEW goblins
   are found, then STOP. The time the wave showed up is remembered (spawn event if the game fires one,
   otherwise the moment the goblins were seen) and the next hunt starts ~CFG.spawnPeriod (240s) later.
   Goblins from an earlier wave (done, or stuck with a quest we cannot do) are never counted again.
   No more sweeping after every goblin / after every idle timeout.
 * A quest we cannot do (catch / drown / burn / ...) is left alone: no clicking, no turn-in. If it
   blocks new quests from other goblins, the bot waits for it to run out (CFG.holdMax) instead of
   hammering the dialog, then goes back to work.
 * Multiple-choice question: ONE random answer (every answer pays the same), no re-asking.

What changed vs v9 (self-heal)
 * No more standing still after a quest ends or is skipped: the old code waited up to 120s
   before looking for the next goblin. Now every goblin outcome (done / skipped / failed /
   error) triggers a sweep within CFG.sweepGap seconds, and idle sweeps run every CFG.sweepEvery.
 * A goblin that keeps failing is put on a cooldown (40s, 80s, 160s ... max 300s) and the bot
   goes to other goblins instead of retrying the same one forever.
 * Supervisor thread: restarts a dead / hung loop, unfreezes anchored / sitting / ragdolled
   characters, closes a dialog left open, forces a sweep when nothing happened for
   CFG.idleLimit seconds, teleports to Moosewood if stuck or out of the world, and as a last
   resort respawns the character (CFG.hardResetAfter).
 * Dying during any objective (not only walking) is detected and the try is refunded.
 * New button: Fix now (runs the same repair by hand).

Panel (drag the title bar; "-" minimizes; RightShift hides on PC):
  status card + ON/OFF | Main: Talk, Sweep now, Fix now, quest levels | Islands: teleport, Mark spot
  | Tools: Copy report, Clear log, Dump UI, Stop script
If something still fails: open the dialog by hand, press Dump UI, then Copy report.
]]

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local PPS = game:GetService("ProximityPromptService")
local TCS = game:GetService("TextChatService")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local lp = Players.LocalPlayer

local genv = (getgenv and getgenv()) or _G
if genv.GoblinAutoStop then pcall(genv.GoblinAutoStop) end

local okVim, VIM = pcall(function() return game:GetService("VirtualInputManager") end)
if not okVim then VIM = nil end

local CFG = {
	difficulty = "Easy",     -- Easy | Normal | Hard | Extreme | Ultimate
	scanDelay = 0.25,        -- seconds between goblin scans
	dialogWait = 1.1,        -- seconds between dialog clicks
	tpOffset = CFrame.new(0, 3, 6),
	fastJump = false,        -- true = fire the Jump quest remote directly (faster, riskier)
	clickMode = "conn",      -- "conn" = fire button connections | "vim" = real click
	useDisplayName = false,  -- fills <player> if it ever shows up literally in a sentence
	resumeActive = true,     -- if a goblin quest is already active, do it instead of failing
	sweep = true,            -- visit the event islands to find goblins that are not loaded
	sweepEvery = 10,         -- seconds between two sweeps while a hunt is running (see goblinCount)
	sweepWait = 1.0,         -- seconds to wait on each island for things to stream in
	sweepGap = 1,            -- min seconds between two sweeps while hunting (a spawn event / new wave skips the wait)
	goblinCount = 3,         -- goblins per spawn wave: teleport + scan until this many NEW ones are found, then STOP
	spawnPeriod = 240,       -- seconds between waves (learned from the real spawn times, kept within +-45s)
	spawnLead = 15,          -- start the next hunt this many seconds BEFORE the next wave is due
	eventMinGap = 90,        -- a spawn event this long after a finished hunt starts a new hunt right away
	huntDry = 2,             -- sweeps in a row that find nothing new -> accept the goblins found so far
	huntSlow = 45,           -- seconds between sweeps once a hunt has found nothing at all
	holdMax = 300,           -- max seconds to wait for a quest we cannot do to run out
	retryAfter = 300,        -- a finished goblin that stays in place is retried after this long
	extraSpots = {},         -- optional: { { name = "Island", pos = Vector3.new(x, y, z) } }
	talk = true,             -- false = ไม่คุยกับ goblin เลย
	levels = { easy = true, normal = false, hard = false, extreme = false, ultimate = false },
	watchdog = true,
	idleLimit = 120,         -- only while hunting: no work for this long -> force a sweep (the loop is probably stuck)
	failCool = 40,           -- goblin ที่ทำไม่สำเร็จครบ 4 ครั้ง พักกี่วินาที (x2 ทุกรอบ สูงสุด 300) แล้วไปหาตัวอื่นก่อน
	hardResetAfter = 4,      -- ซ่อมแบบเบากี่รอบติดแล้วยังไม่หาย -> รีเซ็ตตัวละคร (0 = ปิด)
	islandPos = {
		["Moosewood"]       = Vector3.new(380, 135, 234),
		["Roslit Bay"]      = Vector3.new(-1473, 133, 708),
		["Forsaken Shores"] = Vector3.new(-2491, 133, 1561),
		["Sunstone Island"] = Vector3.new(-913, 138, -1133),
		["Terrapin Island"] = Vector3.new(-193, 135, 1951),
		["Mushgrove Swamp"] = Vector3.new(2434, 132, -692),
		["Ancient Isle"]    = Vector3.new(6056, 195, 307),
		["Lost Jungle"]     = Vector3.new(-2589, 158, -2194),
		["Scoria Reach"]    = Vector3.new(-4976, 145, -1577),
	},
}

local running, enabled = true, true
local lines, seen, conns = {}, {}, {}

---------------------------------------------------------------- state
local state = setmetatable({}, { __mode = "k" })      -- goblin model -> status table
local dialogAt = setmetatable({}, { __mode = "k" })   -- npc -> time of last dialogstart
local dialogCfg = setmetatable({}, { __mode = "k" })
local lastClick = setmetatable({}, { __mode = "k" })  -- button -> { t = text, at = time }
local hints = {}
local sweepNow = true
local lastSweep = -1000
local dialogRoot = nil
local statusLbl = nil
local working = false         -- true while a goblin / sweep is being processed
local lastWork = os.clock()   -- last time the loop did something real
local recoverNow = nil        -- set by the supervisor (used by the Fix now button)
local held = nil              -- a quest we cannot do is running: { at, why, seen, gone, chk, blocked }
local wave = nil              -- current spawn wave / hunt (created below, after goblins())

-- watchdog: ทุก step ใหญ่เรียก touch() ถ้าเงียบเกิน limit วินาที = ค้าง
local wd = { beat = os.clock(), limit = 60 }
local lastDied = false -- doWalk2 ตั้งเป็น true ตอนตัวละครตายระหว่างทำเควส
local function touch(limit)
	wd.beat = os.clock()
	wd.limit = limit or 60
end

local function setStatus(s)
	touch(60)
	if statusLbl then statusLbl.Text = s end
end

local function log(s)
	if #lines < 1500 then lines[#lines + 1] = s end
	print("[GA] " .. s)
end

local function fmt(a, d, maxd)
	d = d or 0
	maxd = maxd or 2
	if typeof(a) == "Instance" then return a:GetFullName() end
	if type(a) == "table" then
		if d >= maxd then return "{...}" end
		local p = {}
		for k, v in pairs(a) do p[#p + 1] = tostring(k) .. "=" .. fmt(v, d + 1, maxd) end
		return "{" .. table.concat(p, ", ") .. "}"
	end
	return tostring(a)
end

---------------------------------------------------------------- helpers
local function hrpOf()
	local c = lp.Character
	return c and c:FindFirstChild("HumanoidRootPart"), c and c:FindFirstChildOfClass("Humanoid")
end

local function clean(s)
	s = tostring(s or "")
	local nm = CFG.useDisplayName and lp.DisplayName or lp.Name
	s = s:gsub("<[Pp]layer>", function() return nm end)
	s = s:gsub("<[^>]+>", "")
	s = s:gsub("\226\128\156", '"'):gsub("\226\128\157", '"'):gsub("\226\128\153", "'")
	return s
end

local function goblins()
	local out = {}
	local w = workspace:FindFirstChild("world")
	local npcs = w and w:FindFirstChild("npcs")
	local folder = npcs and npcs:FindFirstChild("FischfrightGoblins")
	if folder then
		for _, m in ipairs(folder:GetChildren()) do
			if m:IsA("Model") then
				local loaded = m:FindFirstChildWhichIsA("BasePart", true) ~= nil
				local p = m:GetPivot().Position
				local ok = loaded or (p.Y > 100 and Vector3.new(p.X, 0, p.Z).Magnitude > 150)
				if not loaded then
					local d = ("FAR %s | %.0f, %.0f, %.0f | %s"):format(m.Name, p.X, p.Y, p.Z, ok and "use" or "ignored")
					if not seen[d] then seen[d] = true; log(d) end
				end
				if ok then out[#out + 1] = m end
			end
		end
	end
	return out
end

local function promptPos(m)
	local pp = m:FindFirstChildWhichIsA("ProximityPrompt", true)
	local par = pp and pp.Parent
	if par and par:IsA("Attachment") then return par.WorldPosition end
	if par and par:IsA("BasePart") then return par.Position end
	return m:GetPivot().Position
end

local function standCF(m)
	local gp = promptPos(m)
	local root = m:FindFirstChild("RootPart") or m.PrimaryPart
	local look = root and root.CFrame.LookVector or Vector3.new(0, 0, -1)
	look = Vector3.new(look.X, 0, look.Z)
	look = look.Magnitude > 0.1 and look.Unit or Vector3.new(0, 0, -1)
	local side = Vector3.new(-look.Z, 0, look.X)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { lp.Character, m }
	rp.IgnoreWater = true
	for _, d in ipairs({ look, side, -side, -look }) do
		local p = gp + d * 5
		local hit = workspace:Raycast(p + Vector3.new(0, 4, 0), Vector3.new(0, -25, 0), rp)
		if hit and math.abs(hit.Position.Y - gp.Y) < 8 then
			local pos = hit.Position + Vector3.new(0, 3.2, 0)
			return CFrame.lookAt(pos, Vector3.new(gp.X, pos.Y, gp.Z))
		end
	end
	local pos = gp + look * 5 + Vector3.new(0, 2, 0)
	return CFrame.lookAt(pos, Vector3.new(gp.X, pos.Y, gp.Z))
end

local function tpTo(model)
	local hrp = hrpOf()
	if not hrp or not model.Parent then return false end
	local cf = model:GetPivot()
	if not model:FindFirstChildWhichIsA("BasePart", true) then
		pcall(function() lp:RequestStreamAroundAsync(cf.Position, 2) end)
		hrp.Anchored = true -- ลอยรอให้ goblin โหลด
		hrp.CFrame = cf + Vector3.new(0, 40, 0)
		hrp.AssemblyLinearVelocity = Vector3.zero
		local t0 = os.clock()
		while model.Parent and os.clock() - t0 < 8
			and not model:FindFirstChildWhichIsA("BasePart", true) do
			task.wait(0.1)
		end
		hrp.Anchored = false
		if not model.Parent or not model:FindFirstChildWhichIsA("BasePart", true) then
			log("NOTE: " .. model.Name .. " did not load at its saved spot")
			return false
		end
		cf = model:GetPivot()
	end
	hrp.CFrame = standCF(model)
	hrp.AssemblyLinearVelocity = Vector3.zero
	task.wait(0.5)
	return model.Parent ~= nil
end

local function tap(key, t)
	if not VIM then return end
	pcall(function() VIM:SendKeyEvent(true, key, false, game) end)
	task.wait(t or 0.15)
	pcall(function() VIM:SendKeyEvent(false, key, false, game) end)
end

local function cancelEmote()
	local e = RS:FindFirstChild("events")
	local r = e and e:FindFirstChild("CancelEmote")
	if r then pcall(function() r:FireServer() end) end
end

local function exitEmote()
	cancelEmote()
	local hrp, hum = hrpOf()
	if not hrp or not hum then return end
	local n = 0
	for _, tr in ipairs(hum:GetPlayingAnimationTracks()) do
		n = n + 1
		pcall(function() tr:Stop(0.1) end)
	end
	-- restart the Animate script: clears an emote that is stuck in a loop
	local an = lp.Character and lp.Character:FindFirstChild("Animate")
	if an then
		pcall(function() an.Disabled = true end)
		pcall(function() an.Enabled = false end)
		task.wait(0.15)
		pcall(function() an.Disabled = false end)
		pcall(function() an.Enabled = true end)
	end
	hum:MoveTo(hrp.Position + hrp.CFrame.LookVector * 4)
	tap(Enum.KeyCode.W, 0.35) -- a real key press: most games cancel an emote on input
	tap(Enum.KeyCode.Space, 0.1)
	hum.Jump = true
	task.wait(0.5)
	log("EMOTE stop (" .. n .. " tracks)")
end

local ISLANDS = {
	{ "Ancient Isle", "ancient" }, { "Drylands", "dryland", "dry land" },
	{ "Everturn Forest", "everturn" }, { "Forsaken Shores", "forsaken" },
	{ "Lost Jungle", "lost jungle", "lostjungle" }, { "Moosewood", "moosewood" },
	{ "Mushgrove Swamp", "mushgrove" }, { "Roslit Bay", "roslit" },
	{ "Scoria Reach", "scoria" }, { "Skycrest", "skycrest", "sky crest" },
	{ "Snowcap Island", "snowcap" }, { "Sunstone Island", "sunstone" },
	{ "Terrapin Island", "terrapin" },
}

local function posOf(o)
	if o:IsA("BasePart") then return o.Position end
	if o:IsA("Model") then
		local ok, cf = pcall(function() return o:GetPivot() end)
		if ok then return cf.Position end
	end
	return nil
end

local function islandRoots()
	local out = {}
	local function add(r) if r then out[#out + 1] = r end end
	local w = workspace:FindFirstChild("world")
	local sp = w and w:FindFirstChild("spawns")
	local z = workspace:FindFirstChild("zones")
	add(sp and sp:FindFirstChild("TpSpots"))
	add(w and w:FindFirstChild("map"))
	add(z and z:FindFirstChild("fishing"))
	return out
end

local islandCache, islandMiss = {}, {}
-- พิกัดสำรอง "ค่าประมาณจากความจำ ไม่ได้เช็คกับเกมนี้" ใช้เมื่อหาด้วยชื่อไม่เจอ; ถ้าตกน้ำให้ใช้ปุ่ม Mark spot
local islandGuess = { ["Snowcap Island"] = Vector3.new(2607, 135, 2436) }

-- ค้นทุกอย่างใต้ workspace.world / workspace.zones หา Model/Part ที่ชื่อมีคีย์เวิร์ดเกาะ (เช่น "Snowcap Shipwright")
local function deepFind(isl)
	local best, bd
	for _, rn in ipairs({ "world", "zones" }) do
		local r = workspace:FindFirstChild(rn)
		if r then
			for _, o in ipairs(r:GetDescendants()) do
				if (o:IsA("Model") or o:IsA("BasePart")) and #o.Name <= 40 then
					local n = o.Name:lower()
					for i = 2, #isl do
						if n:find(isl[i], 1, true) then
							local p = posOf(o)
							local d = #o:GetFullName()
							if p and (not bd or d < bd) then best, bd = p, d end
						end
					end
				end
			end
		end
	end
	return best
end

local function findIsland(isl)
	local name = isl[1]
	if CFG.islandPos[name] then return CFrame.new(CFG.islandPos[name]) end
	if islandCache[name] then return CFrame.new(islandCache[name]) end
	for _, r in ipairs(islandRoots()) do
		local best, bl
		for _, o in ipairs(r:GetChildren()) do
			local n = o.Name:lower()
			for i = 2, #isl do
				if n:find(isl[i], 1, true) and (not bl or #n < bl) and posOf(o) then
					best, bl = o, #n
				end
			end
		end
		if best then return CFrame.new(posOf(best)) end
	end
	if not islandMiss[name] or os.clock() - islandMiss[name] > 90 then
		local p = deepFind(isl)
		if p then
			islandCache[name] = p
			return CFrame.new(p)
		end
		islandMiss[name] = os.clock()
	end
	if islandGuess[name] then return CFrame.new(islandGuess[name]) end
	return nil
end

local function islandSpots()
	local out = {}
	local w = workspace:FindFirstChild("world")
	local sp = w and w:FindFirstChild("spawns")
	local tp = sp and sp:FindFirstChild("TpSpots")
	if false then
		for _, p in ipairs(tp:GetChildren()) do
			if p:IsA("BasePart") then
				out[#out + 1] = { name = p.Name, cf = p.CFrame }
			elseif p:IsA("Model") then
				out[#out + 1] = { name = p.Name, cf = p:GetPivot() }
			end
		end
	end
	for _, isl in ipairs(ISLANDS) do
		local cf = findIsland(isl)
		if cf then out[#out + 1] = { name = isl[1], cf = cf } end
	end
	for _, e in ipairs(CFG.extraSpots) do
		out[#out + 1] = { name = e.name, cf = CFrame.new(e.pos) }
	end
	return out
end

local function spotByName(str)
	local s = str:lower()
	if #s < 4 then return nil end
	for _, sp in ipairs(islandSpots()) do
		local n = sp.name:lower()
		if n:find(s, 1, true) or s:find(n, 1, true) then return sp.cf end
	end
	return nil
end

-- pull positions / island names out of a spawn event so the sweep can go there first
local function collectHints(v, out, d)
	if d > 3 then return end
	local ty = typeof(v)
	if ty == "Vector3" then
		out[#out + 1] = CFrame.new(v)
	elseif ty == "CFrame" then
		out[#out + 1] = v
	elseif ty == "Instance" then
		if v:IsA("BasePart") then
			out[#out + 1] = v.CFrame
		elseif v:IsA("Model") then
			out[#out + 1] = v:GetPivot()
		end
	elseif ty == "string" then
		local cf = spotByName(v)
		if cf then out[#out + 1] = cf end
	elseif ty == "table" then
		for _, x in pairs(v) do collectHints(x, out, d + 1) end
	end
end

local MAXTRY = 4
local function stOf(m)
	local pos = m:GetPivot().Position
	local s = state[m]
	local strikes = 0
	if s and s.skip and held then return s end -- its quest is still running: do not talk to it again
	if s then
		local age = os.clock() - s.at
		local moved = (s.pos - pos).Magnitude > 25
		local expired = (s.done and age > CFG.retryAfter)
			or (not s.done and s.tries >= MAXTRY and age > (s.cool or 40))
		if expired and not moved then strikes = s.strikes or 0 end
		if moved or expired then s = nil end -- respawned somewhere else / cooldown over
	end
	if not s then
		s = { pos = pos, tries = 0, done = false, claim = false, at = os.clock(), strikes = strikes }
		state[m] = s
	end
	return s
end

local diffByName = { ["goblin"] = "easy", ["ghoulish goblin"] = "normal" }

local function wantsModel(m)
	if not CFG.talk then return false end
	local lv = diffByName[m.Name:lower()]
	return lv == nil or CFG.levels[lv] == true
end

local function fresh()
	local out = {}
	for _, m in ipairs(goblins()) do
		local ok, s = pcall(stOf, m)
		if ok and not s.done and s.tries < MAXTRY and wantsModel(m) then out[#out + 1] = m end
	end
	return out
end

-- goblin ยังอยู่แต่ลองครบแล้ว: อย่าวิ่งหนีไป sweep เกาะอื่น
local function pending()
	for _, m in ipairs(goblins()) do
		local ok, s = pcall(stOf, m)
		if ok and not s.done and wantsModel(m) then return true end
	end
	return false
end

---------------------------------------------------------------- spawn waves (hunt -> stop -> learn -> wait)
-- The event spawns CFG.goblinCount goblins roughly every CFG.spawnPeriod seconds. A "hunt" teleports
-- around the islands only until that many NEW goblins are found, then it STOPS (no more teleporting),
-- remembers when the wave showed up and sleeps until the next one is due. Goblins that belong to an
-- earlier wave (done, or stuck with a quest we cannot do) are never counted again.
local old = {}                                   -- goblin key -> true: belongs to an earlier wave
local spawn = { period = CFG.spawnPeriod, last = nil }

local function gKey(m)
	local u = m:GetAttribute("UID")
	if u ~= nil then return "uid:" .. tostring(u) end
	return m
end

-- remember when a wave appeared; the gap between waves refines the period
local function learnSpawn(t, exact)
	local last = spawn.last
	spawn.last = t
	if not last then return end
	local gap = t - last
	local k = math.max(1, math.floor(gap / spawn.period + 0.5)) -- a wave we missed in between = 2x the period
	local per = gap / k
	if per < CFG.spawnPeriod * 0.75 or per > CFG.spawnPeriod * 1.25 then
		log(("WAVE learn: gap %ds ignored"):format(math.floor(gap)))
		return
	end
	local w = exact and 0.5 or 0.25
	spawn.period = math.clamp(spawn.period * (1 - w) + per * w, CFG.spawnPeriod - 45, CFG.spawnPeriod + 45)
	log(("WAVE learn: gap %ds -> period %ds (%s)"):format(math.floor(gap), math.floor(spawn.period),
		exact and "from spawn event" or "from first sighting"))
end

local function newWave(why, byEvent)
	local prev = wave and wave.nextAt
	wave = { at = os.clock(), found = {}, n = 0, dry = 0, done = false, byEvent = byEvent, prevNext = prev }
	sweepNow = true
	log("WAVE hunt: " .. why)
end

-- all (or all we are going to get) found: stop hunting, learn the time, schedule the next hunt
local function finishWave(why)
	if not wave or wave.done then return end
	local now = os.clock()
	wave.done, wave.doneAt = true, now
	for _, m in ipairs(goblins()) do old[gKey(m)] = true end
	table.clear(hints)
	local anchor = wave.evtAt or wave.firstSeen or now
	learnSpawn(anchor, wave.evtAt ~= nil)
	wave.nextAt = math.max(anchor + spawn.period - CFG.spawnLead, now + 5)
	log(("WAVE done (%s): %d/%d goblins | no more teleporting, next hunt in %ds"):format(
		why, wave.n, CFG.goblinCount, math.floor(wave.nextAt - now)))
end

-- nothing new showed up: stop hunting WITHOUT learning anything and try again later
local function abandonWave(why, nextAt)
	wave.done, wave.doneAt, wave.nextAt = true, os.clock(), nextAt
	table.clear(hints)
	log(("WAVE gave up (%s): next hunt in %ds"):format(why, math.floor(nextAt - os.clock())))
end

-- count the NEW goblins we can see right now
local function refreshWave()
	if not wave or wave.done then return end
	for _, m in ipairs(goblins()) do
		local k = gKey(m)
		if not old[k] and not wave.found[k] then
			wave.found[k] = true
			wave.n = wave.n + 1
			wave.firstSeen = wave.firstSeen or os.clock()
			log(("WAVE new goblin %d/%d: %s"):format(wave.n, CFG.goblinCount, m.Name))
		end
	end
	if wave.n >= CFG.goblinCount then finishWave("found all") end
end

-- every tick: count, close a hunt that has nothing more to give, open the next one when it is due
local function wavePoll()
	local now = os.clock()
	if wave.done and now >= wave.nextAt then newWave("next wave is due") end
	refreshWave()
	if wave.done then return end
	if wave.n > 0 then
		if wave.dry >= CFG.huntDry then finishWave("nothing more found") end
	elseif wave.byEvent and wave.dry >= CFG.huntDry then
		abandonWave("spawn event but nothing new", math.max(wave.prevNext or 0, now + 30))
	elseif now - wave.at > spawn.period then
		abandonWave("nothing spawned this period", now + spawn.period - CFG.spawnLead)
	end
end

-- a goblin spawn event arrived (exact spawn time + maybe positions in `hints`)
local function spawnEvent()
	local now = os.clock()
	if not wave.done then
		wave.evtAt = wave.evtAt or now
		sweepNow = true
	elseif now - wave.doneAt > CFG.eventMinGap then
		newWave("spawn event", true)
		wave.evtAt = now
	end
end

newWave("script start")

---------------------------------------------------------------- events + remote logging
local function onEvent(name, t)
	if name == "dialogstart" then
		local d = t[1]
		if type(d) == "table" and typeof(d.npc) == "Instance" then
			dialogAt[d.npc] = os.clock()
			dialogCfg[d.npc] = t[3]
		end
	elseif name:find("Goblins/", 1, true) then
		if name:find("Hide", 1, true) then
			for i = 1, t.n do
				local v = t[i]
				if type(v) == "string" then
					for _, m in ipairs(goblins()) do
						if m:GetAttribute("UID") == v then
							state[m] = { pos = m:GetPivot().Position, tries = 0, done = true,
								claim = true, at = os.clock() }
						end
					end
				end
			end
		else
			local before = #hints
			for i = 1, t.n do collectHints(t[i], hints, 0) end
			-- only something that looks like a spawn counts: a "spawn" remote, or one that carries a position / island
			if name:lower():find("spawn", 1, true) or #hints > before then spawnEvent() end
		end
	end
end

local skipKeys = { "ClientKit", "Settings/Edit", "ResourceStream", "SetHotbar", "Analytics", "SetZone" }
local function noisy(path)
	for _, k in ipairs(skipKeys) do
		if path:find(k, 1, true) then return true end
	end
	return false
end

genv.GA_CALL = function(line)
	if not seen[line] then
		seen[line] = true
		log(line)
	end
end

if hookmetamethod and getnamecallmethod then
	if not genv.GA_HOOKED then
		genv.GA_HOOKED = true
		local nc = newcclosure or function(f) return f end
		local old
		old = hookmetamethod(game, "__namecall", nc(function(self, ...)
			local m = getnamecallmethod()
			if m == "FireServer" or m == "InvokeServer" then
				local t = table.pack(...)
				local remote = self
				task.defer(function()
					local path = fmt(remote)
					if noisy(path) then return end
					local parts = {}
					for i = 1, t.n do parts[i] = fmt(t[i]) end
					local f = genv.GA_CALL
					if f then f("CALL " .. path .. ":" .. m .. "(" .. table.concat(parts, ", ") .. ")") end
				end)
			end
			return old(self, ...)
		end))
	end
else
	log("NOTE: executor has no hookmetamethod (remote calls will not be logged)")
end

-- one short line per dialogstart instead of the whole dialog tree (keeps the report small)
local function briefDialog(t)
	local d, c = t[1], t[3]
	local npc = type(d) == "table" and typeof(d.npc) == "Instance" and d.npc.Name or "?"
	c = type(c) == "table" and c or {}
	local n1 = type(c.dialog) == "table" and c.dialog[1]
	return ("DIALOG %s | cs_start=%s | init=%s | node1=%s"):format(
		npc, tostring(c.cs_start), fmt(c.initial_data, 0, 2),
		type(n1) == "table" and clean(tostring(n1.text)) or "?")
end

local function listen(r)
	if r and r:IsA("BaseRemoteEvent") then
		conns[#conns + 1] = r.OnClientEvent:Connect(function(...)
			local t = table.pack(...)
			local parts = {}
			for i = 1, t.n do parts[i] = fmt(t[i], 0, 2) end
			local s = "EVENT " .. r.Name .. "(" .. table.concat(parts, ", ") .. ")"
			if r.Name == "dialogstart" then s = briefDialog(t) end
			if #s > 1500 then s = s:sub(1, 1500) .. "...<cut>" end
			if not seen[s] then
				seen[s] = true
				log(s)
			end
			local ok, err = pcall(onEvent, r.Name, t)
			if not ok then log("ERR onEvent " .. tostring(err)) end
		end)
	end
end

local ev = RS:FindFirstChild("events")
local dsEvent = ev and ev:FindFirstChild("dialogstart")
if dsEvent then listen(dsEvent) end
local pk = RS:FindFirstChild("packages")
local net = pk and pk:FindFirstChild("Net")
local DI = net and net:FindFirstChild("RF/DialogInteract")
if net then
	for _, r in ipairs(net:GetChildren()) do
		local n = r.Name
		if n:find("Goblins/", 1, true) or n:find("TrickOrTreat/", 1, true) or n:find("QuestTrigger", 1, true) or n:find("Dialog", 1, true) then
			listen(r)
		end
	end
end

conns[#conns + 1] = PPS.PromptTriggered:Connect(function(p)
	log("PROMPT " .. p:GetFullName() .. " | " .. p.ActionText .. " / " .. p.ObjectText)
end)

---------------------------------------------------------------- GUI reading / clicking
local function visibleChain(g)
	local pg = lp.PlayerGui
	local o = g
	while o and o ~= pg do
		if o:IsA("GuiObject") and not o.Visible then return false end
		if o:IsA("ScreenGui") and not o.Enabled then return false end
		o = o.Parent
	end
	return o == pg
end

local function alive(o)
	return o ~= nil and o.Parent ~= nil and visibleChain(o)
end

local function isText(g) return g:IsA("TextButton") or g:IsA("TextLabel") end

local function hasAny(txt, list)
	for _, w in ipairs(list) do
		if txt:find(w, 1, true) then return true end
	end
	return false
end

-- HUD stuff that must never be clicked: timers, counters, icon names
local function noise(t)
	if t:find("^time left") then return true end
	if t:find("^[%d%.,%s]+[kmb]?$") then return true end
	if t:find("^[%l%d]+%-[%l%d%-]+$") then return true end
	return false
end

-- remember which text objects are visible right now; only objects that are NOT in this
-- set count as "new" later (keyed by instance, so a ticking timer text is never new)
local base = setmetatable({}, { __mode = "k" })
local function snapshot()
	base = setmetatable({}, { __mode = "k" })
	for _, g in ipairs(lp.PlayerGui:GetDescendants()) do
		if isText(g) and visibleChain(g) then base[g] = true end
	end
end

local function texts(onlyNew)
	local out = {}
	for _, g in ipairs(lp.PlayerGui:GetDescendants()) do
		if isText(g) and #g.Text > 1 and visibleChain(g) then
			if not onlyNew or not base[g] then out[#out + 1] = g end
		end
	end
	return out
end

local function clickTarget(g)
	if g:IsA("GuiButton") then return g end
	return g:FindFirstAncestorWhichIsA("GuiButton")
end

local function fireConns(sig)
	if not getconnections then return 0 end
	local n = 0
	local ok, list = pcall(getconnections, sig)
	if ok and type(list) == "table" then
		for _, c in ipairs(list) do
			if pcall(function() c:Fire() end) then n = n + 1 end
		end
	end
	return n
end

local function realClick(g)
	if not VIM then return false end
	local p, s = g.AbsolutePosition, g.AbsoluteSize
	local sg = g:FindFirstAncestorWhichIsA("ScreenGui")
	local inset = (sg and sg.IgnoreGuiInset) and Vector2.zero or GuiService:GetGuiInset()
	local x, y = p.X + s.X / 2 + inset.X, p.Y + s.Y / 2 + inset.Y
	VIM:SendMouseButtonEvent(x, y, 0, true, game, 0)
	task.wait(0.06)
	VIM:SendMouseButtonEvent(x, y, 0, false, game, 0)
	return true
end

local function press(btn)
	if CFG.clickMode == "conn" then
		if fireConns(btn.Activated) > 0 then return "Activated" end
		if fireConns(btn.MouseButton1Click) > 0 then return "MouseButton1Click" end
	end
	if realClick(btn) then return "vim" end
	return "none"
end

local function emoteBtn()
	for _, g in ipairs(texts(false)) do
		if clean(g.Text):lower():find("cancel emote", 1, true) then
			return clickTarget(g) or g
		end
	end
	return nil
end

local function stopEmote()
	for i = 1, 6 do
		local b = emoteBtn()
		if not b then
			if i > 1 then log("EMOTE stopped") end
			return true
		end
		if i % 2 == 1 then
			local ok, how = pcall(press, b)
			log("EMOTE cancel click via " .. tostring(ok and how or "error"))
		else
			pcall(realClick, b) -- รอบคู่ กดจริงบนจอ
		end
		cancelEmote()
		task.wait(0.4)
	end
	log("NOTE: emote cancel button still showing after 6 tries")
	return false
end

local function closeDialog()
	for _, g in ipairs(texts(false)) do
		if clean(g.Text):lower():find("nevermind", 1, true) then
			local b = clickTarget(g)
			if b then
				press(b)
				return
			end
		end
	end
end

-- a dialog window that stays open blocks the prompt. Close it ("Nevermind..."), then walk
-- out of its range (maxdistance = 12) so it closes by itself
local function leaveDialog(m)
	closeDialog()
	task.wait(0.3)
	local hrp = hrpOf()
	if not hrp then return end
	local origin = (m and m.Parent) and m:GetPivot().Position or hrp.Position
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { lp.Character }
	rp.IgnoreWater = true
	for i = 0, 7 do
		local a = math.rad(i * 45)
		local p = origin + Vector3.new(math.cos(a), 0, math.sin(a)) * 28
		local hit = workspace:Raycast(p + Vector3.new(0, 60, 0), Vector3.new(0, -120, 0), rp)
		if hit and math.abs(hit.Position.Y - origin.Y) < 10 then
			hrp.CFrame = CFrame.new(hit.Position + Vector3.new(0, 4, 0))
			hrp.AssemblyLinearVelocity = Vector3.zero
			task.wait(1.2)
			return
		end
	end
	-- no ground found around it: hang in the air for a moment instead
	hrp.Anchored = true
	hrp.CFrame = CFrame.new(origin + Vector3.new(0, 45, 0))
	task.wait(1.2)
	hrp.Anchored = false
end

-- ปิด dialog แบบไม่วาปหนี: กด Nevermind แล้วรอ ถ้ายังไม่ปิดจริงๆ ค่อยถอยออกไป
local function softLeave(m)
	closeDialog()
	task.wait(0.5)
	for _, g in ipairs(texts(false)) do
		if clean(g.Text):lower():find("nevermind", 1, true) then
			leaveDialog(m)
			return
		end
	end
end

---------------------------------------------------------------- dialog
local DIFF = { "easy", "normal", "hard", "extreme", "ultimate" }
local function levelOrder()
	local o = {}
	for _, d in ipairs(DIFF) do
		if CFG.levels[d] then o[#o + 1] = d end
	end
	return o
end

local EXCLUDE = { "never", "leave", "bye", "cancel", "close", "decline", "nope", "not now", "no thanks", "[no]", "navigate" }
local QUESTY = { "goblin quest", "friend quest", "quest:", "track" }
local PREFER = { "accept", "okay", "ok", "sure", "deal", "yes", "fine", "continue", "next",
	"claim", "complete", "done", "turn in", "reward", "thank", "alright", "bring it" }

local BADUI = { "statuses", "popupNotif", "topbar", "changelogs", "PlayerList", "backpack", "TopbarStandard" }
local function badUI(o)
	local p = o:GetFullName()
	for _, k in ipairs(BADUI) do
		if p:find(k, 1, true) then return true end
	end
	return false
end

-- find the container (direct child of a ScreenGui) that holds the most NEW text:
-- that is the dialog window
local function pickRoot()
	local score, best, bestRoot = {}, 0, nil
	for _, g in ipairs(texts(true)) do
		local t = clean(g.Text):lower()
		if not noise(t) and not badUI(g) then
			local sg = g:FindFirstAncestorWhichIsA("ScreenGui")
			if sg then
				local top = g
				while top.Parent and top.Parent ~= sg do top = top.Parent end
				score[top] = (score[top] or 0) + 1
				if score[top] > best then
					best = score[top]
					bestRoot = top
				end
			end
		end
	end
	return bestRoot
end

local function inRoot(o)
	return dialogRoot ~= nil and (o == dialogRoot or o:IsDescendantOf(dialogRoot))
end

-- clickable options inside the dialog window only
local function dialogButtons()
	if not alive(dialogRoot) then dialogRoot = pickRoot() end
	local out = {}
	if not dialogRoot then return out end
	for _, g in ipairs(texts(true)) do
		local b = clickTarget(g)
		if b and inRoot(b) and not badUI(b) then
			local t = clean(g.Text):lower()
			local lc = lastClick[b]
			local recent = lc and lc.t == t and os.clock() - lc.at < 1.8
			if not recent and not noise(t) and not hasAny(t, EXCLUDE)
				and not hasAny(t, DIFF) and not hasAny(t, QUESTY) then
				out[#out + 1] = { b = b, t = t }
			end
		end
	end
	return out
end

local function stepDialog()
	local cands = dialogButtons()
	if #cands == 0 then return false end
	local pick = cands[1]
	for _, c in ipairs(cands) do
		if hasAny(c.t, PREFER) then
			pick = c
			break
		end
	end
	lastClick[pick.b] = { t = pick.t, at = os.clock() }
	log(('CLICK "%s" via %s'):format(pick.t:sub(1, 60), press(pick.b)))
	return true
end

-- the 5 difficulty options ("Can I just get an Easy one?" ...), never the quest HUD
local function diffButtons()
	local out = {}
	for _, g in ipairs(texts(true)) do
		local b = clickTarget(g)
		if b then
			local t = clean(g.Text):lower()
			if #t <= 60 and not noise(t) and not hasAny(t, QUESTY) and hasAny(t, DIFF) then
				out[#out + 1] = { b = b, t = t }
			end
		end
	end
	return out
end

local function pickDifficulty()
	local order = levelOrder()
	local t0, settled = os.clock(), false
	while os.clock() - t0 < (held and 5 or 12) do
		if not alive(dialogRoot) then dialogRoot = pickRoot() end
		local cands = diffButtons()
		if #cands > 0 then
			if not settled then
				settled = true -- let the rest of the options finish appearing
				task.wait(0.7)
			else
				for _, w in ipairs(order) do
					for _, c in ipairs(cands) do
						if c.t:find(w, 1, true) then return c.b, c.t end
					end
				end
				task.wait(0.3)
			end
		else
			-- intro lines first: click "continue"-like buttons inside the dialog
			stepDialog()
			task.wait(CFG.dialogWait)
		end
	end
	return nil
end

local function firePrompt(pp, useFire)
	if fireproximityprompt and useFire then
		pcall(fireproximityprompt, pp)
	else
		pcall(function()
			pp:InputHoldBegin()
			task.wait(0.2)
			pp:InputHoldEnd()
		end)
	end
end

local function openDialog(model)
	local pp
	local t0 = os.clock()
	while model.Parent do
		pp = model:FindFirstChildWhichIsA("ProximityPrompt", true)
		if pp or os.clock() - t0 > 6 then break end
		task.wait(0.4)
	end
	if not pp then
		log("NOTE: no prompt on " .. model.Name)
		return false
	end
	pcall(function()
		pp.HoldDuration = 0
		pp.RequiresLineOfSight = false
		pp.MaxActivationDistance = 40
	end)
	dialogRoot = nil
	snapshot()
	for attempt = 1, 5 do
		touch(60)
		if not model.Parent then return false end
		-- prompt ถูกปิดอยู่ (goblin กำลังคุย / คูลดาวน์): รอให้เปิดก่อน ไม่ต้องยิงรัวแล้ววาปหนี
		local w1 = os.clock()
		while model.Parent and not pp.Enabled and os.clock() - w1 < 6 do
			task.wait(0.3)
		end
		local hrp = hrpOf()
		if hrp and (hrp.Position - promptPos(model)).Magnitude > 10 then
			tpTo(model)
		end
		dialogAt[model] = nil
		cancelEmote()
		if attempt >= 2 then stopEmote(); exitEmote() end
		task.wait(0.1)
		firePrompt(pp, attempt % 2 == 1)
		local w0, again = os.clock(), false
		while os.clock() - w0 < 4.5 do -- dialogstart มาช้าแล้วโดนวาปหนีกลางทาง
			if dialogAt[model] then break end
			if not dsEvent and pickRoot() then break end
			if not again and os.clock() - w0 > 2.2 then
				again = true
				firePrompt(pp, attempt % 2 == 0)
			end
			task.wait(0.1)
		end
		if dialogAt[model] or (not dsEvent and pickRoot()) then
			log("TALK " .. model.Name)
			return true
		end
		log("NOTE: no dialog yet on " .. model.Name .. " (try " .. attempt .. ")")
		closeDialog()
		task.wait(0.6)
		if attempt == 3 then leaveDialog(model) end -- วาปถอยแค่ครั้งเดียว หลังลองครบ 3 รอบ
	end
	return false
end

---------------------------------------------------------------- objective parsing
local function numAfter(l, kw)
	local rest = l:match(kw .. "(.*)")
	if not rest then return nil end
	local n = rest:match("(%d[%d,]*)")
	return n and tonumber((n:gsub(",", ""))) or nil
end

-- "(12/50)" style progress -> how many are still left
local function remaining(l, total)
	local a, b = l:match("(%d[%d,]*)%s*/%s*(%d[%d,]*)")
	a = a and tonumber((a:gsub(",", "")))
	b = b and tonumber((b:gsub(",", "")))
	if a and b and b >= a then return b - a end
	return total
end

local function parse(raw)
	local t = clean(raw)
	local l = t:lower()

	local q = t:match('[Tt]ype%s*"(.-)"')
	if q and l:find("in chat", 1, true) then
		local n = tonumber(l:match("in chat%s+(%d+)%s+times"))
			or (l:find("in chat twice", 1, true) and 2) or 1
		return { kind = "chat", text = q, count = n }
	end
	if l:find("%f[%a]danc") or l:find("%f[%a]jig%f[%A]") then
		local n = numAfter(l, "danc") or numAfter(l, "jig")
		return { kind = "dance", secs = n and remaining(l, n) or 15 }
	end
	if l:find("jump%D*%d") then
		local n = numAfter(l, "jump")
		return { kind = "jump", n = n and remaining(l, n) }
	end
	if l:find("walk%D*%d") then
		local n = numAfter(l, "walk")
		return { kind = "walk", n = n and remaining(l, n) }
	end

	for _, k in ipairs({ "catch", "perfect", "beatrix", "insult", "trick", "guess", "drown", "burn", "freeze" }) do
		if l:find(k, 1, true) then return { kind = "skip", why = k } end
	end
	return nil
end

-- prefers something we can actually do over something we have to skip
local function readObjective()
	local skip
	for _, g in ipairs(texts(true)) do
		local o = parse(g.Text)
		if o then
			if o.kind ~= "skip" then return o, clean(g.Text) end
			skip = skip or { o = o, raw = clean(g.Text) }
		end
	end
	if skip then return skip.o, skip.raw end
	return nil
end

local function hasGoblinQuest()
	for _, g in ipairs(texts(false)) do
		if clean(g.Text):lower():find("goblin quest", 1, true) then return true end
	end
	return false
end

local function activeObjective(hudOnly)
	for pass = 1, 2 do
		if pass == 1 or not hudOnly then
			for _, g in ipairs(texts(false)) do
				if pass == 2 or g:GetFullName():find("deviceinset", 1, true) then
					local o = parse(g.Text)
					if o and o.kind ~= "skip" then return o, clean(g.Text) end
				end
			end
		end
	end
	return nil
end

-- first quest line on the HUD (PlayerGui.hud.deviceinset...) that parse() understands, skip types included
local function hudQuest()
	for _, g in ipairs(texts(false)) do
		if g:GetFullName():find("deviceinset", 1, true) then
			local o = parse(g.Text)
			if o then return o, clean(g.Text) end
		end
	end
	return nil
end

-- we hold a quest we cannot do (catch / drown / ...): it stays on the player until it runs out
local function markHeld(why)
	held = { at = os.clock(), why = why, seen = false, gone = nil, chk = 0, blocked = false }
	log("HOLD: quest we cannot do (" .. tostring(why) .. ") - leaving it to run out, max " .. CFG.holdMax .. "s")
end

-- is that quest still running? (clears `held` once it is over)
local function heldAlive()
	if not held then return false end
	local now = os.clock()
	if now - held.at > CFG.holdMax then
		log("HOLD over: waited " .. CFG.holdMax .. "s")
		held = nil
		return false
	end
	if now - held.chk >= 2 then
		held.chk = now
		if hudQuest() then
			held.seen, held.gone = true, nil
		elseif held.seen then
			held.gone = held.gone or now
		end
	end
	if held.gone and now - held.gone >= 4 then
		log("HOLD over: the quest left the HUD (ran out)")
		held = nil
		return false
	end
	return true
end

-- true when a quest we cannot do is the reason this goblin gives us nothing
local function blockedByHeld()
	if not held then -- the script may have been started while such a quest was already running
		local o = hudQuest()
		if o and o.kind == "skip" then markHeld(o.why) end
	end
	return heldAlive()
end

local function advance(rounds, wantObj)
	local obj, raw
	for _ = 1, rounds do
		task.wait(CFG.dialogWait)
		if wantObj and not obj then obj, raw = readObjective() end
		if not stepDialog() then break end
	end
	if wantObj then
		local t0 = os.clock()
		while not obj and os.clock() - t0 < 6 do
			obj, raw = readObjective()
			if not obj then task.wait(0.5) end
		end
	end
	return obj, raw
end

---------------------------------------------------------------- objective actions
local function sendChat(msg)
	local ok = false
	if TCS.ChatVersion == Enum.ChatVersion.TextChatService then
		local chans = TCS:FindFirstChild("TextChannels")
		local ch = chans and (chans:FindFirstChild("RBXGeneral") or chans:FindFirstChildWhichIsA("TextChannel"))
		if ch then ok = pcall(function() ch:SendAsync(msg) end) end
	end
	if not ok then
		local dce = RS:FindFirstChild("DefaultChatSystemChatEvents")
		local req = dce and dce:FindFirstChild("SayMessageRequest")
		if req then
			req:FireServer(msg, "All")
			ok = true
		end
	end
	return ok
end

local function doChat(o)
	for _ = 1, o.count do
		if not running then return false end
		if not sendChat(o.text) then
			log("NOTE: could not send chat")
			return false
		end
		log("CHAT " .. o.text)
		task.wait(1.7)
	end
	return true
end

local function doDance(o)
	local _, hum = hrpOf()
	if not hum then return false end
	local ok, res = pcall(function() return hum:PlayEmote("dance") end)
	if not (ok and res) then sendChat("/e dance") end
	log("DANCE " .. o.secs .. "s")
	task.wait(o.secs + 2)
	exitEmote()
	return true
end

local function doJump(o)
	local _, hum = hrpOf()
	if not hum then return false end
	local n = o.n or 15
	local r = net and net:FindFirstChild("URE/QuestTrigger/Jump")
	log("JUMP x" .. n)
	if CFG.fastJump and r then
		for _ = 1, n do
			touch(30)
			if not running then return false end
			r:FireServer()
			task.wait(0.12)
		end
	else
		for _ = 1, n do
			touch(30)
			if not running then return false end
			hum.Jump = true
			hum:ChangeState(Enum.HumanoidStateType.Jumping)
			task.wait(0.55)
		end
	end
	return true
end

-- "(a/b)" of the first quest-HUD line that mentions `word` (PlayerGui.hud.deviceinset.quests)
local function hudProgress(word)
	for _, g in ipairs(texts(false)) do
		if g:GetFullName():find("deviceinset", 1, true) then
			local l = clean(g.Text):lower()
			if l:find(word, 1, true) then
				local a, b = l:match("(%d[%d,]*)%s*/%s*(%d[%d,]*)")
				if a and b then
					return tonumber((a:gsub(",", ""))), tonumber((b:gsub(",", "")))
				end
			end
		end
	end
	return nil
end

-- direction with the longest stretch of flat ground (no water, wall or cliff) from here
local function openLane(hrp)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { lp.Character }
	rp.IgnoreWater = true
	local base = hrp.Position
	local best, bestLen = Vector3.new(0, 0, 1), -1
	for i = 0, 7 do
		local a = math.rad(i * 45)
		local dir = Vector3.new(math.cos(a), 0, math.sin(a))
		local len = 0
		for step = 1, 8 do
			local p = base + dir * (step * 5)
			local hit = workspace:Raycast(p + Vector3.new(0, 20, 0), Vector3.new(0, -60, 0), rp)
			if not (hit and math.abs(hit.Position.Y - (base.Y - 3)) < 6) then break end
			len = step * 5
		end
		if len > bestLen then best, bestLen = dir, len end
	end
	return best, bestLen
end

-- walks back and forth until the HUD says (b/b). Studs and the quest's own unit may differ,
-- so the HUD is the judge; the stud goal is only the fallback when the HUD line is unreadable
local function doWalk(o)
	local hrp, hum = hrpOf()
	if not hrp or not hum then return false end
	local goal = (o.n or 50) * 1.1 + 5
	local dir, len = openLane(hrp)
	len = math.clamp(len, 12, 35)
	local a = hrp.Position
	local b = a + dir * len
	log(("WALK n=%s lane=%d studs"):format(tostring(o.n), len))
	local walked, last = 0, hrp.Position
	local hbc = RunService.Heartbeat:Connect(function()
		local h = hrpOf()
		if not h then return end
		local d = (h.Position - last).Magnitude
		if d < 8 then walked = walked + d end -- ignore teleports
		last = h.Position
	end)

	local toB, done, sawHud, missing = true, false, false, 0
	local t0, lastLog = os.clock(), 0
	local lastHud, lastMove = nil, os.clock()
	while running and not done and os.clock() - t0 < 300 do
		local target = toB and b or a
		hum:MoveTo(target)
		local s0 = os.clock()
		repeat
			task.wait(0.1)
			local h = hrpOf()
			if not h then break end
		until (h.Position - target).Magnitude < 4 or os.clock() - s0 > 3.5
		toB = not toB

		local pa, pb = hudProgress("walk")
		if pa then
			sawHud, missing = true, 0
			if pa ~= lastHud then lastHud, lastMove = pa, os.clock() end
			if pa >= pb then done = true end
			if os.clock() - lastLog > 5 then
				lastLog = os.clock()
				log(("WALK hud %d/%d | moved %.0f studs"):format(pa, pb, walked))
			end
			if not done and os.clock() - lastMove > 25 and walked > 60 then
				log("NOTE: walk progress is stuck on the HUD - send this report")
				break
			end
		elseif sawHud then
			missing = missing + 1
			if missing >= 2 then done = true end -- the line is gone: objective finished
		elseif walked >= goal then
			done = true
		end
	end
	hbc:Disconnect()
	return done
end

local function logHud(tag)
	local n = 0
	for _, g in ipairs(texts(false)) do
		if g:GetFullName():find("deviceinset", 1, true) then
			n = n + 1
			if n <= 8 then log(("HUD[%s] %s"):format(tag, clean(g.Text):sub(1, 80))) end
		end
	end
end

local function doDance2(o)
	local _, hum = hrpOf()
	if not hum then return false end
	cancelEmote()
	task.wait(0.4)
	logHud("dance start")
	log("DANCE " .. o.secs .. "s")
	local methods = {
		function() return hum:PlayEmote("dance") end,
		function() return sendChat("/e dance") end,
		function() return sendChat("/e dance2") end,
		function() return sendChat("/e dance3") end,
	}
	local counted = false
	for i, f in ipairs(methods) do
		pcall(f)
		local a
		for _ = 1, 6 do
			task.wait(1)
			touch(30)
			a = hudProgress("dance")
			if a == nil or a > 0 then break end
		end
		log(("DANCE method %d | hud=%s"):format(i, tostring(a)))
		if a == nil or a > 0 then
			counted = true
			break
		end
		cancelEmote()
		task.wait(0.4)
	end
	local t0 = os.clock()
	while running and os.clock() - t0 < o.secs + 6 do
		touch(30)
		local a, b = hudProgress("dance")
		if a and b and a >= b then break end
		task.wait(1)
	end
	logHud("dance end")
	stopEmote()
	exitEmote()
	stopEmote()
	return counted
end

-- มีพื้นอยู่ข้างหน้าไหม (กันเดินตกหน้าผา / ลงน้ำลึก)
local function groundAhead(h, dir)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { lp.Character }
	rp.IgnoreWater = true
	local p = h.Position + dir * 5
	local hit = workspace:Raycast(p + Vector3.new(0, 4, 0), Vector3.new(0, -20, 0), rp)
	return hit ~= nil and math.abs(hit.Position.Y - (h.Position.Y - 3)) < 6
end

local function doWalk2(o)
	local hrp, hum = hrpOf()
	if not hrp or not hum then return false end
	local char = lp.Character
	cancelEmote()
	logHud("walk start")
	local dir, len = openLane(hrp)
	local leg = math.clamp(len / 16, 1.2, 3)
	local goal = (o.n or 50) * 1.1 + 5
	local flip, done, sawHud, missing = 1, false, false, 0
	local walked, last = 0, hrp.Position
	local t0 = os.clock()
	local flipAt, chkAt, hudAt, logAt = t0 + leg, t0 + 1.2, t0 + 1, t0 + 8
	local ledgeAt = t0 + 0.4
	local chkPos, lastHud, lastMove = hrp.Position, nil, t0
	pcall(function() RunService:UnbindFromRenderStep("GA_walk") end)
	RunService:BindToRenderStep("GA_walk", Enum.RenderPriority.Last.Value, function()
		pcall(function() hum:Move(dir * flip, false) end)
	end)
	local ok, err = pcall(function()
		while running and not done and os.clock() - t0 < 300 do
			task.wait(0.1)
			touch(30)
			-- ตายระหว่างเดิน: เลิกทันที ห้ามนับว่าเควสเสร็จ
			if lp.Character ~= char or hum.Health <= 0 then
				lastDied = true
				log("NOTE: died while walking - will redo the quest after respawn")
				break
			end
			local h = hrpOf()
			if not h then break end
			local now = os.clock()
			local d = (h.Position - last).Magnitude
			if d < 8 then walked = walked + d end
			last = h.Position
			if now > ledgeAt and not groundAhead(h, dir * flip) then
				flip = -flip
				flipAt = now + leg
				ledgeAt = now + 0.6
			end
			if now > chkAt then
				if (h.Position - chkPos).Magnitude < 1 then
					dir = CFrame.Angles(0, math.rad(90), 0):VectorToWorldSpace(dir)
				end
				chkPos, chkAt = h.Position, now + 1.2
			end
			if now > flipAt then
				flip, flipAt = -flip, now + leg
			end
			if now > logAt then
				logAt = now + 8
				logHud(("walk %.0f studs"):format(walked))
			end
			if now > hudAt then
				hudAt = now + 1
				local pa, pb = hudProgress("walk")
				if pa then
					sawHud, missing = true, 0
					if pa ~= lastHud then lastHud, lastMove = pa, now end
					if pa >= pb then done = true end
					if not done and now - lastMove > 25 and walked > 60 then
						log(("NOTE: walk hud stuck at %d/%d after %.0f studs - send this report"):format(pa, pb, walked))
						break
					end
				elseif sawHud then
					missing = missing + 1
					if missing >= 2 and walked > 20 then done = true end
				elseif walked >= goal then
					done = true
				end
			end
		end
	end)
	RunService:UnbindFromRenderStep("GA_walk")
	pcall(function() hum:Move(Vector3.zero, false) end)
	if not ok then log("ERR walk " .. tostring(err)) end
	return done
end

local function perform(o)
	if o.kind == "chat" then return doChat(o)
	elseif o.kind == "dance" then return doDance2(o)
	elseif o.kind == "jump" then return doJump(o)
	elseif o.kind == "walk" then return doWalk2(o)
	end
	return false
end

---------------------------------------------------------------- per-goblin flow
local function pickByRemote(m)
	local cfg = dialogCfg[m]
	local node = cfg and cfg.dialog and cfg.dialog[1]
	local ch = node and node.choices
	if not (DI and ch) then return false end
	local order = levelOrder()
	for _, w in ipairs(order) do
		for i, c in ipairs(ch) do
			if c.callback and clean(tostring(c.arg or c.text)):lower():find(w, 1, true) then
				log(("PICK %s -> DialogInteract(1, %d)"):format(w, i))
				local ok, res = pcall(function() return DI:InvokeServer(1, i) end)
				log("DialogInteract returned " .. tostring(ok) .. " " .. fmt(res))
				return ok
			end
		end
	end
	return false
end

local function objFromCfg(m)
	local cfg = dialogCfg[m]
	local msg = cfg and cfg.initial_data and cfg.initial_data.msg
	if not msg then return nil end
	local o = parse(msg)
	if o then return o, clean(msg) end
end

local function turnIn(m)
	if not m.Parent then
		log("NOTE: goblin left before turn-in")
		return false
	end
	setStatus("claim: " .. m.Name)
	if not tpTo(m) then return false end
	if not openDialog(m) then return false end
	local st = state[m]
	if st then st.pos = m:GetPivot().Position end
	advance(5, false)
	softLeave(m)
	log("DONE " .. m.Name)
	return true
end

-- multiple-choice question (guess ...): reopening the dialog gives cs_start = "choicesN" and
-- initial_data = { msg, choice1..N }. The answer is DialogInteract(8 + N, picked index).
-- Every answer pays the same, so: ONE random answer, never re-ask after a wrong one.
-- true = answered | false = could not open the dialog | nil = not a multiple-choice dialog
local function doChoice(m, alreadyOpen)
	if not alreadyOpen and not openDialog(m) then return false end
	if not DI then return false end
	local cfg = dialogCfg[m]
	local cs = cfg and tostring(cfg.cs_start) or ""
	local d = cfg and cfg.initial_data or {}
	if cs == "started2" then -- one button only (insult / say-this)
		log("ANSWER " .. clean(tostring(d.msg)) .. " -> " .. clean(tostring(d.choice)))
		local ok, res = pcall(function() return DI:InvokeServer(3, 1) end)
		log("DialogInteract returned " .. tostring(ok) .. " " .. fmt(res))
		softLeave(m)
		return ok
	end
	local n = tonumber(cs:match("^choices(%d+)$"))
	if not n then
		log("NOTE: no multiple-choice dialog (cs_start=" .. cs .. ")")
		return nil
	end
	local pick = math.random(n) -- random: every answer gives the same reward
	log(("ANSWER %s -> #%d %s (random, once)"):format(clean(tostring(d.msg)), pick, clean(tostring(d["choice" .. pick]))))
	local ok, res = pcall(function() return DI:InvokeServer(8 + n, pick) end)
	log("DialogInteract returned " .. tostring(ok) .. " " .. fmt(res))
	softLeave(m)
	return ok
end

local function handleGoblin(m, s)
	if s.claim then return turnIn(m) end

	setStatus("quest: " .. m.Name)
	if not tpTo(m) then return false end
	if not openDialog(m) then return false end

	local obj, raw
	local cfg0 = dialogCfg[m]
	if not (cfg0 and cfg0.cs_start) then
		local ch = cfg0 and cfg0.dialog and cfg0.dialog[1] and cfg0.dialog[1].choices
		if ch then
			local lvs, ok = {}, false
			for _, c in ipairs(ch) do
				if c.callback and c.arg then
					local lv = clean(tostring(c.arg)):lower()
					lvs[#lvs + 1] = lv
					if CFG.levels[lv] then ok = true end
				end
			end
			local key = m.Name:lower()
			if #lvs == 1 and diffByName[key] ~= lvs[1] then
				diffByName[key] = lvs[1]
				log("LEARN " .. m.Name .. " = " .. lvs[1])
			end
			if #lvs > 0 and not ok then
				log("SKIP level " .. table.concat(lvs, "/") .. " (not selected) on " .. m.Name)
				closeDialog()
				return true
			end
		end
	end
	if cfg0 and cfg0.cs_start and cfg0.initial_data then
		obj, raw = objFromCfg(m) -- quest already running
		if not obj and tostring(cfg0.cs_start):find("^choices%d") then
			obj, raw = { kind = "skip", why = "guess" }, clean(tostring(cfg0.initial_data.msg))
		end
		if not obj then obj, raw = activeObjective(true) end
		if obj then log("RESUME " .. raw) end
	elseif pickByRemote(m) then
		obj, raw = advance(5, true)
		if not obj and openDialog(m) then obj, raw = objFromCfg(m) end
	else
		local btn, label = pickDifficulty()
		if btn then
			lastClick[btn] = { t = label, at = os.clock() }
			log(('PICK "%s" via %s'):format(label:sub(1, 60), press(btn)))
			obj, raw = advance(5, true)
		elseif CFG.resumeActive and hasGoblinQuest() then
			obj, raw = activeObjective()
			if obj then log("RESUME " .. raw) end
		end
	end

	if not obj then
		local c = dialogCfg[m]
		local cs = c and tostring(c.cs_start) or ""
		if cs:find("^choices%d") or cs == "started2" then
			obj = { kind = "skip", why = "guess" }
			raw = clean(tostring(c.initial_data and c.initial_data.msg))
		end
	end
	if not obj then
		obj, raw = activeObjective(true) -- บรรทัดเควสบน HUD เช่น "Dance for 15 seconds (0/15)"
		if obj then log("HUD " .. raw) end
	end

	if not obj and s.obj then -- เควสที่เคยอ่านไว้ (ตายแล้ววนกลับมา / ข้อความ resume อ่านไม่ออก)
		obj, raw = s.obj, "(remembered) " .. tostring(s.obj.kind)
		log("RESUME " .. raw)
	end
	if not obj then
		if blockedByHeld() then
			log("HOLD: a quest we cannot do is still running, " .. m.Name .. " has nothing for us - waiting for it to run out")
			softLeave(m)
			return "hold"
		end
		log("NOTE: no quest/objective found on " .. m.Name
			.. " - open the dialog, press Dump UI, then send the report")
		return false
	end
	log("OBJECTIVE " .. raw .. " -> " .. obj.kind)
	if obj.kind ~= "skip" then s.obj = obj end
	if obj.kind == "skip" and (obj.why == "guess" or obj.why == "insult") then
		local c = dialogCfg[m]
		local cs = c and tostring(c.cs_start) or ""
		local r = doChoice(m, cs:find("^choices%d") ~= nil or cs == "started2")
		if r == true then
			s.claim = true
			pcall(turnIn, m) -- dialog "finish" ให้ของรางวัล
			return true
		end
		if r ~= nil then return r end
	end
	softLeave(m)
	if obj.kind == "skip" then
		log("SKIP (cannot do this one yet): " .. obj.why .. " - leaving it to run out")
		s.skip = true
		markHeld(obj.why)
		return true
	end

	setStatus(obj.kind .. ": " .. m.Name)
	if not perform(obj) then
		log("NOTE: objective did not finish")
		return false
	end
	s.claim = true
	return turnIn(m)
end

---------------------------------------------------------------- island sweep
local spotsLogged = false
local function sweepSpots()
	local spots = islandSpots()
	if not spotsLogged then
		spotsLogged = true
		for _, s in ipairs(spots) do log("SPOT " .. s.name) end
	end
	return spots
end

-- spot guard: a spot where the character ended up out of the world is skipped for 10 minutes,
-- so one bad island can no longer abort every sweep before it reaches the others
local badSpot = {}                                  -- spot name -> os.clock() of the fall
local sweepInfo = { name = nil, at = 0, seen = {} } -- spot being visited now (the supervisor reads it)

-- stream the area around pos WITHOUT ever blocking longer than maxT (RequestStreamAroundAsync can yield forever)
local function streamAround(pos, maxT)
	maxT = maxT or 4
	local done = false
	task.spawn(function()
		pcall(function() lp:RequestStreamAroundAsync(pos, maxT) end)
		done = true
	end)
	local t0 = os.clock()
	while not done and os.clock() - t0 < maxT + 1 do
		task.wait(0.1)
		touch(60)
	end
end

-- put the (anchored) character on real ground at pos, or hover above it if no ground streamed in
local function landAt(p)
	local hrp = hrpOf()
	if not hrp then return end
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { lp.Character }
	local hit
	for _ = 1, 6 do
		hit = workspace:Raycast(p + Vector3.new(0, 300, 0), Vector3.new(0, -700, 0), rp)
		if hit then break end
		task.wait(0.4)
		touch(60)
	end
	if hit then
		hrp.CFrame = CFrame.new(hit.Position + Vector3.new(0, 5, 0))
		hrp.AssemblyLinearVelocity = Vector3.zero
		hrp.Anchored = false
		return true
	end
	return false
end

local function sweepOnce()
	local order = {}
	for _, h in ipairs(hints) do order[#order + 1] = { name = "hint", cf = h } end
	table.clear(hints)
	for _, s in ipairs(sweepSpots()) do order[#order + 1] = s end
	if #order == 0 then
		log("NOTE: no island spots (workspace.world.spawns.TpSpots) - fill CFG.extraSpots")
		return false
	end
	log(("SWEEP %d spots | hunting %d new goblins (have %d)"):format(#order, CFG.goblinCount, wave.n))
	local startN, lastFound = wave.n, nil
	for _, s in ipairs(order) do
		if not running or not enabled then return false end
		local hrp, hum = hrpOf()
		if not hrp or not hum or hum.Health <= 0 then return false end

		local sp = s.cf.Position
		local info = ("%s (%.0f, %.0f, %.0f)"):format(s.name, sp.X, sp.Y, sp.Z)
		local skipWhy
		if sp.Y ~= sp.Y or sp.Y < 0 or sp.Y > 2000 then
			skipWhy = "bad coordinates"
		elseif badSpot[s.name] and os.clock() - badSpot[s.name] < 600 then
			skipWhy = "character fell out of the world here last time"
		end
		if not sweepInfo.seen[info] then -- log each distinct spot once, not every sweep
			sweepInfo.seen[info] = true
			log("SWEEP spot " .. info .. (skipWhy and (" -> SKIP: " .. skipWhy) or ""))
		end

		if not skipWhy then
			lastWork = os.clock()
			setStatus("looking: " .. s.name)
			sweepInfo.name, sweepInfo.at = s.name, os.clock()

			-- stay anchored the WHOLE time (before, during and after streaming)
			hrp.Anchored = true
			hrp.AssemblyLinearVelocity = Vector3.zero
			hrp.CFrame = s.cf + Vector3.new(0, 8, 0)
			streamAround(sp, 2) -- bounded: can never hang the loop

			local hrp2 = hrpOf()
			if not hrp2 then return false end
			hrp2.Anchored = true

			local before = wave.n
			local t0 = os.clock()
			while os.clock() - t0 < CFG.sweepWait do
				task.wait(0.15)
				touch(60)
				refreshWave()
				if wave.done then break end
				if wave.n > before then -- something new showed up here: give the rest of this area a moment, then move on
					task.wait(0.6)
					touch(60)
					refreshWave()
					break
				end
			end
			if wave.n > before then lastFound = sp end
			if wave.done then
				log("FOUND all " .. wave.n .. " goblins (last one near " .. s.name .. ") - hunt over")
				landAt(sp) -- stand on real ground before the goblin handler takes over
				local h3 = hrpOf()
				if h3 then h3.Anchored = false end
				return true
			end
		end
	end
	sweepInfo.name = nil
	if wave.n > startN then -- found some (not all): stand on the ground and go work on them
		wave.dry = 0
		log(("SWEEP done: %d/%d new goblins so far"):format(wave.n, CFG.goblinCount))
		if lastFound then landAt(lastFound) end
		local hh = hrpOf()
		if hh then hh.Anchored = false end
		return true
	end
	wave.dry = wave.dry + 1
	-- nothing new -> do not drop from mid-air on the last island; go stand on Moosewood
	local home = CFG.islandPos["Moosewood"]
	if home then
		local h = hrpOf()
		if h then
			h.Anchored = true
			h.CFrame = CFrame.new(home + Vector3.new(0, 8, 0))
			streamAround(home, 2)
			if not landAt(home) then
				local h4 = hrpOf()
				if h4 then h4.Anchored = false end
			end
		end
	end
	log("SWEEP done, nothing found")
	return false
end

---------------------------------------------------------------- UI
local function dumpUI()
	log("---- UI DUMP (visible text) ----")
	local n = 0
	for _, g in ipairs(texts(false)) do
		if not badUI(g) and not g:GetFullName():find("announcements", 1, true) then
			n = n + 1
			if n > 120 then break end
			log(('UI %s | "%s" | button=%s'):format(g:GetFullName(), clean(g.Text):sub(1, 50),
				tostring(clickTarget(g) ~= nil)))
		end
	end
end

local gui = Instance.new("ScreenGui")
gui.Name = "GoblinAuto"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 999
gui.Parent = (gethui and gethui()) or game:GetService("CoreGui")

-- stand on real ground at cf (island buttons + self-heal use this)
local function goTo(cf)
	local hrp = hrpOf()
	if not hrp then return false end
	local p = cf.Position
	hrp.Anchored = true
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.CFrame = CFrame.new(p + Vector3.new(0, 150, 0))
	streamAround(p, 3) -- bounded: never hangs
	task.wait(1)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { lp.Character }
	local hit
	for _ = 1, 8 do
		hit = workspace:Raycast(p + Vector3.new(0, 400, 0), Vector3.new(0, -900, 0), rp)
		if hit then break end
		task.wait(0.5)
	end
	local h2 = hrpOf()
	if not h2 then return false end
	h2.CFrame = CFrame.new(hit and (hit.Position + Vector3.new(0, 5, 0)) or (p + Vector3.new(0, 8, 0)))
	h2.Anchored = false
	return true
end

---------------------------------------------------------------- control panel (v12.2)
-- one draggable panel: status card + [Main | Islands | Tools] tabs. Minimize with "-" (becomes a
-- draggable "GA" bubble). RightShift (PC) hides / shows everything.
do
	local UIS = game:GetService("UserInputService")
	local F, FB = Enum.Font.GothamMedium, Enum.Font.GothamBold
	local C = {
		bg = Color3.fromRGB(20, 20, 27), card = Color3.fromRGB(31, 31, 42), btn = Color3.fromRGB(46, 46, 62),
		on = Color3.fromRGB(32, 140, 84), red = Color3.fromRGB(176, 58, 58), accent = Color3.fromRGB(96, 84, 230),
		text = Color3.fromRGB(238, 238, 247), dim = Color3.fromRGB(152, 152, 172),
		green = Color3.fromRGB(70, 200, 120), amber = Color3.fromRGB(240, 180, 60),
	}
	local W, H, TOP = 260, 256, 114

	local function mk(class, props, parent)
		local o = Instance.new(class)
		for k, v in pairs(props) do o[k] = v end
		if parent then o.Parent = parent end
		return o
	end
	local function corner(o, r) mk("UICorner", { CornerRadius = UDim.new(0, r or 8) }, o) end

	local function newButton(parent, text, color, size, onClick)
		local b = mk("TextButton", {
			Size = size, BackgroundColor3 = color, BorderSizePixel = 0, AutoButtonColor = true,
			Font = F, TextSize = 13, TextColor3 = C.text, Text = text,
		}, parent)
		b:SetAttribute("base", text)
		corner(b, 8)
		b.Activated:Connect(function()
			local ok, err = pcall(onClick, b)
			if not ok then log("ERR ui " .. tostring(err)) end
		end)
		return b
	end
	-- show a short message on a button for a moment (instant feedback)
	local function flash(b, txt)
		b.Text = txt
		task.delay(1.2, function()
			if b.Parent then b.Text = b:GetAttribute("base") end
		end)
	end
	local function caption(parent, text, size, color, pos, sz)
		return mk("TextLabel", {
			Position = pos, Size = sz, BackgroundTransparency = 1, Font = F, TextSize = size, TextColor3 = color,
			TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = text,
		}, parent)
	end

	-- drag by a handle; returns a function that tells whether the last press turned into a drag
	local function makeDraggable(handle, target)
		local dragging, startMouse, startPos, moved = false, nil, nil, false
		handle.InputBegan:Connect(function(i)
			if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
				dragging, moved = true, false
				startMouse, startPos = i.Position, target.Position
				i.Changed:Connect(function()
					if i.UserInputState == Enum.UserInputState.End then dragging = false end
				end)
			end
		end)
		conns[#conns + 1] = UIS.InputChanged:Connect(function(i)
			if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement
				or i.UserInputType == Enum.UserInputType.Touch) then
				local d = i.Position - startMouse
				if d.Magnitude > 6 then moved = true end
				if moved then
					target.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
						startPos.Y.Scale, startPos.Y.Offset + d.Y)
				end
			end
		end)
		return function() return moved end
	end

	---------------------------------------------------------- frame + title
	local panel = mk("Frame", {
		Name = "Panel", Size = UDim2.fromOffset(W, H), Position = UDim2.new(1, -(W + 12), 0, 60),
		BackgroundColor3 = C.bg, BorderSizePixel = 0, Active = true,
	}, gui)
	corner(panel, 12)
	mk("UIStroke", { Color = Color3.fromRGB(72, 72, 96), Thickness = 1 }, panel)

	local mini -- minimized bubble (created below)
	local title = mk("Frame", { Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1, Active = true }, panel)
	mk("TextLabel", {
		Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -56, 1, 0), BackgroundTransparency = 1,
		Font = FB, TextSize = 14, TextColor3 = C.text, TextXAlignment = Enum.TextXAlignment.Left,
		Text = "Goblin Auto  v12.4",
	}, title)
	local minBtn = newButton(title, "-", C.btn, UDim2.fromOffset(30, 22), function()
		local ap = panel.AbsolutePosition
		mini.Position = UDim2.fromOffset(ap.X, ap.Y)
		panel.Visible = false
		mini.Visible = true
	end)
	minBtn.AnchorPoint = Vector2.new(1, 0.5)
	minBtn.Position = UDim2.new(1, -8, 0.5, 0)
	makeDraggable(title, panel)

	---------------------------------------------------------- status card (always visible)
	local card = mk("Frame", {
		Position = UDim2.fromOffset(8, 34), Size = UDim2.new(1, -16, 0, 44),
		BackgroundColor3 = C.card, BorderSizePixel = 0,
	}, panel)
	corner(card, 8)
	local dot = mk("Frame", {
		Position = UDim2.fromOffset(10, 9), Size = UDim2.fromOffset(10, 10), BackgroundColor3 = C.green, BorderSizePixel = 0,
	}, card)
	corner(dot, 5)
	statusLbl = caption(card, "idle", 13, C.text, UDim2.fromOffset(26, 3), UDim2.new(1, -96, 0, 20))
	local statsLbl = caption(card, "", 11, C.dim, UDim2.fromOffset(10, 24), UDim2.new(1, -80, 0, 16))

	local autoBtn
	local function refreshAuto()
		autoBtn.Text = enabled and "ON" or "OFF"
		autoBtn.BackgroundColor3 = enabled and C.on or C.red
	end
	autoBtn = newButton(card, "ON", C.on, UDim2.fromOffset(58, 32), function()
		enabled = not enabled
		if enabled then sweepNow = true; lastSweep = -1000 end
		refreshAuto()
	end)
	autoBtn.AnchorPoint = Vector2.new(1, 0.5)
	autoBtn.Position = UDim2.new(1, -6, 0.5, 0)
	autoBtn.Font = FB

	---------------------------------------------------------- tabs
	local pages, tabBtns = {}, {}
	local function newPage(name)
		local f = mk("Frame", {
			Name = name, Position = UDim2.fromOffset(8, TOP), Size = UDim2.new(1, -16, 1, -(TOP + 8)),
			BackgroundTransparency = 1, Visible = false,
		}, panel)
		pages[name] = f
		return f
	end
	local function showTab(name)
		for n, f in pairs(pages) do f.Visible = (n == name) end
		for n, b in pairs(tabBtns) do b.BackgroundColor3 = (n == name) and C.accent or C.btn end
	end
	local tabRow = mk("Frame", {
		Position = UDim2.fromOffset(8, 84), Size = UDim2.new(1, -16, 0, 26), BackgroundTransparency = 1,
	}, panel)
	mk("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder,
	}, tabRow)
	for i, n in ipairs({ "Main", "Islands", "Tools" }) do
		local b = newButton(tabRow, n, C.btn, UDim2.new(1 / 3, -3, 1, 0), function() showTab(n) end)
		b.LayoutOrder = i
		tabBtns[n] = b
	end

	---------------------------------------------------------- Main
	local main = newPage("Main")
	local row = mk("Frame", { Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1 }, main)
	mk("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder,
	}, row)
	local cell = UDim2.new(1 / 3, -3, 1, 0)
	local talkBtn
	local function refreshTalk()
		talkBtn.Text = CFG.talk and "Talk: ON" or "Talk: OFF"
		talkBtn.BackgroundColor3 = CFG.talk and C.on or C.btn
	end
	talkBtn = newButton(row, "Talk", C.on, cell, function()
		CFG.talk = not CFG.talk
		refreshTalk()
	end)
	talkBtn.LayoutOrder = 1
	local sweepBtn = newButton(row, "Sweep now", C.btn, cell, function(b)
		if held then held.blocked = false end
		newWave("manual (Sweep now button)")
		lastSweep = -1000
		flash(b, "Sweeping...")
	end)
	sweepBtn.LayoutOrder = 2
	local fixBtn = newButton(row, "Fix now", C.btn, cell, function(b)
		if recoverNow then task.spawn(recoverNow, "manual (Fix now button)") end
		flash(b, "Fixing...")
	end)
	fixBtn.LayoutOrder = 3

	caption(main, "Quest levels - tap to toggle", 11, C.dim, UDim2.fromOffset(2, 42), UDim2.new(1, 0, 0, 14))
	local chips = mk("Frame", {
		Position = UDim2.fromOffset(0, 60), Size = UDim2.new(1, 0, 0, 70), BackgroundTransparency = 1,
	}, main)
	mk("UIGridLayout", {
		CellSize = UDim2.new(1 / 3, -4, 0, 32), CellPadding = UDim2.fromOffset(6, 6), SortOrder = Enum.SortOrder.LayoutOrder,
	}, chips)
	for i, l in ipairs(DIFF) do
		local b = newButton(chips, l:sub(1, 1):upper() .. l:sub(2), CFG.levels[l] and C.on or C.btn, UDim2.new(), function(self)
			CFG.levels[l] = not CFG.levels[l]
			self.BackgroundColor3 = CFG.levels[l] and C.on or C.btn
		end)
		b.LayoutOrder = i
	end

	---------------------------------------------------------- Islands
	local islandBtns, lastIsl, tping = {}, nil, false
	local function selectIsland(name)
		for n, b in pairs(islandBtns) do b.BackgroundColor3 = (n == name) and C.on or C.btn end
	end

	-- tap an island -> teleport; walk to a better spot yourself -> "Mark spot" saves it (+ copies the config line)
	local function markSpot(b)
		local hrp = hrpOf()
		if not (hrp and lastIsl) then
			flash(b, "Tap island 1st")
			return
		end
		local p = hrp.Position
		CFG.islandPos[lastIsl[1]] = p
		local line = ('["%s"] = Vector3.new(%.0f, %.0f, %.0f),'):format(lastIsl[1], p.X, p.Y, p.Z)
		log("SPOT SAVED " .. line)
		if setclipboard then pcall(setclipboard, line) end
		setStatus("saved " .. lastIsl[1])
		flash(b, "Saved!")
	end
	local function goIsland(isl)
		if tping then return end
		lastIsl = isl
		selectIsland(isl[1])
		local cf = findIsland(isl)
		if not cf then
			log("NOTE: island not found: " .. isl[1] .. " - press Dump islands, or fill CFG.islandPos")
			setStatus("no spot: " .. isl[1])
			return
		end
		tping = true
		log("TP island " .. isl[1])
		setStatus("tp: " .. isl[1])
		pcall(goTo, cf)
		tping = false
		setStatus("idle")
	end
	local function dumpIslands()
		log("---- ISLAND DUMP ----")
		for _, r in ipairs(islandRoots()) do
			log("ROOT " .. r:GetFullName())
			for i, o in ipairs(r:GetChildren()) do
				if i > 80 then break end
				local p = posOf(o)
				log(("  %s | %s"):format(o.Name, p and ("%.0f, %.0f, %.0f"):format(p.X, p.Y, p.Z) or "no pos"))
			end
		end
	end

	local isl = newPage("Islands")
	local scroll = mk("ScrollingFrame", {
		Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
		ScrollingDirection = Enum.ScrollingDirection.Y, AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
	}, isl)
	mk("UIGridLayout", {
		CellSize = UDim2.new(0.5, -4, 0, 32), CellPadding = UDim2.fromOffset(6, 6), SortOrder = Enum.SortOrder.LayoutOrder,
	}, scroll)
	local mark = newButton(scroll, "Mark spot", C.accent, UDim2.new(), markSpot)
	mark.LayoutOrder = 1
	local dump = newButton(scroll, "Dump islands", C.btn, UDim2.new(), function(b)
		dumpIslands()
		flash(b, "Dumped")
	end)
	dump.LayoutOrder = 2
	for i, d in ipairs(ISLANDS) do
		local b = newButton(scroll, d[1], C.btn, UDim2.new(), function() goIsland(d) end)
		b.LayoutOrder = 2 + i
		b.TextSize = 12
		islandBtns[d[1]] = b
	end

	---------------------------------------------------------- Tools
	local tools = newPage("Tools")
	mk("UIGridLayout", {
		CellSize = UDim2.new(0.5, -4, 0, 38), CellPadding = UDim2.fromOffset(6, 6), SortOrder = Enum.SortOrder.LayoutOrder,
	}, tools)
	local copyBtn = newButton(tools, "Copy report", C.accent, UDim2.new(), function(b)
		local txt = table.concat(lines, "\n")
		if setclipboard then
			pcall(setclipboard, txt)
			flash(b, "Copied " .. #lines)
		else
			flash(b, "no clipboard")
		end
	end)
	copyBtn.LayoutOrder = 1
	local clearBtn = newButton(tools, "Clear log", C.btn, UDim2.new(), function(b)
		table.clear(lines)
		table.clear(seen)
		flash(b, "Cleared")
	end)
	clearBtn.LayoutOrder = 2
	local uiBtn = newButton(tools, "Dump UI", C.btn, UDim2.new(), function(b)
		dumpUI()
		flash(b, "Dumped")
	end)
	uiBtn.LayoutOrder = 3
	local armed = false
	local stopBtn = newButton(tools, "Stop script", C.red, UDim2.new(), function(b)
		if not armed then
			armed = true
			b.Text = "Tap again!"
			task.delay(2, function()
				armed = false
				if b.Parent then b.Text = "Stop script" end
			end)
			return
		end
		if genv.GoblinAutoStop then genv.GoblinAutoStop() end
	end)
	stopBtn.LayoutOrder = 4

	---------------------------------------------------------- minimized bubble
	mini = mk("TextButton", {
		Size = UDim2.fromOffset(46, 46), Position = panel.Position, BackgroundColor3 = C.bg, BorderSizePixel = 0,
		Font = FB, TextSize = 15, TextColor3 = C.text, Text = "GA", Visible = false, Active = true,
	}, gui)
	corner(mini, 23)
	local miniRing = mk("UIStroke", { Color = C.green, Thickness = 2.5 }, mini)
	local miniMoved = makeDraggable(mini, mini)
	mini.Activated:Connect(function()
		if miniMoved() then return end
		local ap, vp = mini.AbsolutePosition, gui.AbsoluteSize
		local pw, ph = panel.AbsoluteSize.X, panel.AbsoluteSize.Y
		panel.Position = UDim2.fromOffset(math.clamp(ap.X, 0, math.max(0, vp.X - pw)),
			math.clamp(ap.Y, 0, math.max(0, vp.Y - ph)))
		mini.Visible = false
		panel.Visible = true
	end)

	-- PC: RightShift hides / shows the whole UI
	conns[#conns + 1] = UIS.InputBegan:Connect(function(i, processed)
		if not processed and i.KeyCode == Enum.KeyCode.RightShift then gui.Enabled = not gui.Enabled end
	end)

	---------------------------------------------------------- live status (dot color + counters)
	refreshAuto()
	refreshTalk()
	showTab("Main")
	task.spawn(function()
		while running and gui.Parent do
			local now = os.clock()
			local seenN, doneN = 0, 0
			for _, s in pairs(state) do
				seenN = seenN + 1
				if s.done then doneN = doneN + 1 end
			end
			local col = (not enabled) and C.red or (working and C.amber or C.green)
			dot.BackgroundColor3 = col
			miniRing.Color = col
			statsLbl.Text = ("done %d/%d  |  %s"):format(doneN, seenN,
				working and "working" or ("idle " .. math.floor(now - lastWork) .. "s"))
			task.wait(0.4)
		end
	end)
end

genv.GoblinAutoStop = function()
	running = false
	for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	local h = hrpOf()
	if h then pcall(function() h.Anchored = false end) end
	gui:Destroy()
end

---------------------------------------------------------------- main loop + self-heal
local loopThread
local heal = { fails = 0, lastFix = 0 } -- consecutive repairs that did not lead to progress

local function activity() lastWork = os.clock() end

-- ปลดทุกอย่างที่อาจค้าง: anchor, bind เดิน, emote, dialog, สถานะตัวละคร
local function unstick(why)
	log("HEAL unstick: " .. why)
	pcall(function() RunService:UnbindFromRenderStep("GA_walk") end)
	local h, hum = hrpOf()
	if h then pcall(function() h.Anchored = false end) end
	if hum then
		pcall(function() hum:Move(Vector3.zero, false) end)
		pcall(function() hum.PlatformStand = false end)
		pcall(function() hum.Sit = false end)
	end
	dialogRoot = nil
	pcall(closeDialog)
	pcall(cancelEmote)
end

local function waitAlive(maxT)
	local t0 = os.clock()
	while os.clock() - t0 < (maxT or 20) do
		task.wait(0.5)
		touch(60)
		local h, hum = hrpOf()
		if h and hum and hum.Health > 0 then
			task.wait(2.5) -- ให้ตัวละครโหลดนิ่งก่อน
			return true
		end
	end
	return false
end

local function refundTries()
	for _, st in pairs(state) do
		if not st.done then
			st.tries = 0
			st.cool = nil
		end
	end
end

-- stand on ground that is known to exist (Moosewood) when stuck in geometry / out of the world
local function safeTeleport()
	local p = CFG.islandPos["Moosewood"]
	if not p then return end
	pcall(goTo, CFrame.new(p))
	local h = hrpOf()
	if h then pcall(function() h.Anchored = false end) end
end

-- goblin failed this try; after MAXTRY tries it rests for a while (longer each time)
local function noteFail(s)
	s.at = os.clock()
	if s.tries >= MAXTRY then
		s.strikes = (s.strikes or 0) + 1
		s.cool = math.min(CFG.failCool * 2 ^ (s.strikes - 1), 300)
		log(("GIVE UP on this goblin for %ds (strike %d) - going to look for others"):format(
			math.floor(s.cool), s.strikes))
	end
end

local function sweepDue(now)
	if not CFG.sweep or not CFG.talk or #levelOrder() == 0 then return false end
	if wave.done then return false end -- found them all: stay put until the next wave is due
	local gap = CFG.sweepEvery
	if wave.n == 0 and wave.dry >= CFG.huntDry then gap = CFG.huntSlow end -- nothing out there: ease off
	if sweepNow and now - lastSweep > CFG.sweepGap then return true end
	return now - lastSweep > gap
end

local function tickOnce()
	-- a quest we cannot do is running and blocks new ones: no clicking, no teleporting, just wait
	if held and held.blocked then
		if heldAlive() then
			working = false
			activity()
			setStatus(("waiting: %s quest runs out (max %ds)"):format(tostring(held.why),
				math.max(0, math.floor(CFG.holdMax - (os.clock() - held.at)))))
			return
		end
		-- it ran out: look at everything again
		refundTries()
		if not wave.done then wave.at, wave.dry = os.clock(), 0 end
		lastSweep = -1000
		sweepNow = true
	elseif held then
		heldAlive() -- clears it once the quest is over
	end

	wavePoll()
	local list = fresh()
	local now = os.clock()
	if #list == 0 and sweepDue(now) then
		sweepNow = false
		lastSweep = now
		working = true
		activity()
		touch(150)
		local ok, err = pcall(sweepOnce)
		working = false
		lastSweep = os.clock() -- count from the end of the sweep
		activity()
		if not ok then log("ERR sweep " .. tostring(err)) end
		local h = hrpOf()
		if h then h.Anchored = false end
		wavePoll()
		list = fresh()
	end

	local hrp = hrpOf()
	if hrp then
		pcall(table.sort, list, function(x, y)
			return (x:GetPivot().Position - hrp.Position).Magnitude
				< (y:GetPivot().Position - hrp.Position).Magnitude
		end)
	end

	for _, m in ipairs(list) do
		if not running or not enabled then break end
		if m.Parent then
			local okS, s = pcall(stOf, m)
			if okS and not s.done and s.tries < MAXTRY then
				s.tries = s.tries + 1
				s.at = os.clock()
				working = true
				activity()
				lastDied = false
				touch(90)
				local char0 = lp.Character
				local ok, res = pcall(handleGoblin, m, s)
				working = false
				activity()
				if not ok then
					log("ERR " .. tostring(res))
					unstick("error in handleGoblin")
					noteFail(s)
				elseif lastDied or lp.Character ~= char0 then
					lastDied = false
					s.tries = math.max(0, s.tries - 1) -- dying does not count as a try
					waitAlive(25)
				elseif res == "hold" then
					-- another quest of ours (that we cannot do) blocks this one: wait for it, stop poking goblins
					s.tries = math.max(0, s.tries - 1)
					s.at = os.clock()
					if held then held.blocked = true end
					break
				elseif res then
					s.done = true -- done OR skipped (a quest we cannot do): either way, move on
					s.at = os.clock()
					heal.fails = 0
				else
					noteFail(s)
				end
				wavePoll() -- no sweep here any more: the hunt decides whether more goblins are needed
			end
		end
	end
	if wave.done then
		setStatus(("waiting: next wave in %ds"):format(math.max(0, math.floor(wave.nextAt - os.clock()))))
	else
		setStatus("idle")
	end
end

local function startLoop()
	if loopThread then pcall(task.cancel, loopThread) end
	touch(60)
	working = false
	activity()
	loopThread = task.spawn(function()
		while running do
			local h, hum = hrpOf()
			if enabled and h and hum and hum.Health > 0 then
				local ok, err = pcall(tickOnce)
				if not ok then
					log("ERR loop " .. tostring(err))
					working = false
					unstick("loop error")
				end
			end
			task.wait(CFG.scanDelay)
		end
	end)
end

-- full repair, escalating: restart loop -> + teleport to safe ground -> + respawn character
local function recover(why)
	local now = os.clock()
	if now - heal.lastFix > 300 then heal.fails = 0 end
	heal.lastFix = now
	heal.fails = heal.fails + 1
	log(("HEAL #%d: %s"):format(heal.fails, why))
	if loopThread then pcall(task.cancel, loopThread) end
	working = false
	unstick(why)
	refundTries()
	sweepNow = true
	lastSweep = -1000
	if heal.fails >= 2 then pcall(safeTeleport) end
	if CFG.hardResetAfter > 0 and heal.fails >= CFG.hardResetAfter then
		heal.fails = 0
		log("HEAL hard reset: respawning the character")
		local _, hum = hrpOf()
		if hum then pcall(function() hum.Health = 0 end) end
		waitAlive(30)
	end
	startLoop()
end
recoverNow = recover

conns[#conns + 1] = lp.CharacterAdded:Connect(function()
	sweepNow = true
	lastSweep = -1000
	dialogRoot = nil
	task.delay(3, function()
		if running and not working then pcall(unstick, "respawned") end
	end)
end)

startLoop()

-- supervisor: runs on its own thread, so it still works when the main loop is hung or dead
task.spawn(function()
	local anchoredSince, seatedSince
	while running do
		task.wait(2)
		if CFG.watchdog and enabled then
			local ok, err = pcall(function()
				local now = os.clock()

				-- 1) loop thread is dead
				if loopThread ~= nil and coroutine.status(loopThread) == "dead" then
					recover("loop thread died")
					return
				end

				-- no character / dead: the game is respawning us, that is not a hang
				local h, hum = hrpOf()
				if not h or not hum or hum.Health <= 0 then
					touch(60)
					anchoredSince, seatedSince = nil, nil
					return
				end

				-- 2) loop is alive but has not reported in for too long
				if now - wd.beat > wd.limit then
					recover(("loop hung %ds at: %s"):format(math.floor(now - wd.beat),
						statusLbl and statusLbl.Text or "?"))
					return
				end

				-- 3) fell out of the world
				if h.Position.Y < -50 then
					local spot = sweepInfo.name
					if spot and now - sweepInfo.at < 15 then
						badSpot[spot] = now
						log(("BAD SPOT %s: Y=%.0f, skipping it for 10 min"):format(spot, h.Position.Y))
					end
					recover(("fell out of the world (Y=%.0f) at: %s"):format(h.Position.Y,
						statusLbl and statusLbl.Text or "?"))
					return
				end

				-- 4) frozen / sitting / ragdolled for too long
				if h.Anchored and not working then -- a sweep keeps the character anchored on purpose
					anchoredSince = anchoredSince or now
					if now - anchoredSince > 15 then
						h.Anchored = false
						anchoredSince = nil
						log("HEAL: character was frozen (anchored) for 15s -> released")
					end
				else
					anchoredSince = nil
				end
				if hum.PlatformStand or hum.Sit then
					seatedSince = seatedSince or now
					if now - seatedSince > 6 then
						hum.PlatformStand = false
						hum.Sit = false
						hum.Jump = true
						seatedSince = nil
						log("HEAL: character was sitting / ragdolled -> stood up")
					end
				else
					seatedSince = nil
				end

				-- 5) nothing happened for a long time: close any dialog and look for goblins now
				if not working and CFG.sweep and CFG.talk and #levelOrder() > 0
					and wave and not wave.done and not (held and held.blocked)
					and now - lastWork > CFG.idleLimit then
					log(("HEAL: idle %ds -> closing dialog + sweeping now"):format(math.floor(now - lastWork)))
					lastWork = now
					sweepNow = true
					lastSweep = -1000
					dialogRoot = nil
					pcall(closeDialog)
					pcall(cancelEmote)
				end
			end)
			if not ok then log("ERR supervisor " .. tostring(err)) end
		end
	end
end)


do
	local qn = {}
	for _, r in ipairs(net and net:GetChildren() or {}) do
		if r.Name:find("QuestTrigger", 1, true) then qn[#qn + 1] = r.Name end
	end
	log("QUEST REMOTES: " .. table.concat(qn, ", "))
end
do
	local names = {}
	for _, root in ipairs({ RS:FindFirstChild("events"), net }) do
		if root then
			for _, r in ipairs(root:GetChildren()) do
				if r.Name:lower():find("emote", 1, true) then names[#names + 1] = r:GetFullName() end
			end
		end
	end
	log("EMOTE REMOTES: " .. table.concat(names, ", "))
end
log("READY v12.4 (wave hunt + held quests) | difficulty=" .. CFG.difficulty .. " | waiting for goblins")
do
	local names = {}
	for _, root in ipairs({ RS:FindFirstChild("events"), net }) do
		if root then
			for _, r in ipairs(root:GetChildren()) do
				local n = r.Name:lower()
				if n:find("goblin", 1, true) or n:find("spawn", 1, true) or n:find("haunt", 1, true) then
					names[#names + 1] = r:GetFullName()
					listen(r)
				end
			end
		end
	end
	log("SPAWN REMOTES: " .. table.concat(names, ", "))
end
