--[[
Goblin Auto v4 | Fisch - FischFright 3 | Delta
Run it once while the event is on. Re-running replaces the previous instance.

Flow per goblin (nearest first):
TP -> Talk -> pick difficulty -> read objective -> do it -> TP back -> Talk -> claim

Auto objectives : type in chat, dance, jump, walk
Skipped + logged: catch / perfect catch / drown / burn / freeze / trick-or-treat / guess / insult

What changed vs v3
 * Goblins on other islands: the "done/tries" flags were stuck on the goblin model, so a
   goblin that respawned somewhere else was ignored. State now resets when a goblin moves.
   Goblins that are not streamed in are searched for with an island sweep (TpSpots), which
   runs when a goblin spawn event fires, or every CFG.sweepEvery seconds.
 * Teleports but does not talk: waits for the prompt, fires it up to 4 times and confirms
   with the dialogstart event before continuing.
 * Random UIs (shop / backpack / timers): the baseline is per UI instance now (the ticking
   "time left" label no longer counts as new), clicks are limited to the dialog container,
   and HUD / timer / icon texts are ignored.
 * Objective parser bug: "Jump 50 times (0/50)" was read as 15.

Buttons: Auto ON/OFF | Copy report | Clear | Dump UI | Sweep now
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
	scanDelay = 2,           -- seconds between goblin scans
	dialogWait = 1.1,        -- seconds between dialog clicks
	tpOffset = CFrame.new(0, 3, 6),
	fastJump = false,        -- true = fire the Jump quest remote directly (faster, riskier)
	clickMode = "conn",      -- "conn" = fire button connections | "vim" = real click
	useDisplayName = false,  -- fills <player> if it ever shows up literally in a sentence
	resumeActive = true,     -- if a goblin quest is already active, do it instead of failing
	sweep = true,            -- visit the event islands to find goblins that are not loaded
	sweepTp = false, -- true = ถ้า stream ไม่เจอ ค่อยวาปไล่เกาะแบบเดิม | false = ไม่วาปเลย
	sweepEvery = 15,         -- seconds between sweeps while no goblin is around
	sweepWait = 2.5,         -- seconds to wait on each island for things to stream in
	retryAfter = 300,        -- a finished goblin that stays in place is retried after this long
	extraSpots = {},         -- optional: { { name = "Island", pos = Vector3.new(x, y, z) } }
	talk = true,             -- false = ไม่คุยกับ goblin เลย
	levels = { easy = true, normal = false, hard = false, extreme = false, ultimate = false },
	watchdog = true,
	holdManual = true,    -- มีเควสที่ต้องทำเอง: หยุดวาปไปหา goblin ตัวอื่นจนกว่าจะเสร็จ
	manualTimeout = 1200, -- รอเควสทำเองได้นานสุดกี่วินาที
	wdKick = 60, -- goblin รออยู่แต่เงียบเกินกี่วินาที -> ดึงกลับ
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
	pcall(function() lp:RequestStreamAroundAsync(cf.Position) end)
	if not model:FindFirstChildWhichIsA("BasePart", true) then
		hrp.Anchored = true -- ลอยรอให้ goblin โหลด
		hrp.CFrame = cf + Vector3.new(0, 40, 0)
		hrp.AssemblyLinearVelocity = Vector3.zero
		local t0 = os.clock()
		while model.Parent and os.clock() - t0 < 8
			and not model:FindFirstChildWhichIsA("BasePart", true) do
			task.wait(0.3)
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
	task.wait(1.4)
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
	if s then
		local age = os.clock() - s.at
		local moved = (s.pos - pos).Magnitude > 25
		local expired = (s.done and age > CFG.retryAfter)
			or (not s.done and s.tries >= MAXTRY and age > 40)
		if moved or expired then s = nil end -- respawned somewhere else / cooldown over
	end
	if not s then
		s = { pos = pos, tries = 0, done = false, claim = false, at = os.clock() }
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
			sweepNow = true
			for i = 1, t.n do collectHints(t[i], hints, 0) end
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
	while os.clock() - t0 < 12 do
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
	dialogAt[model] = nil -- รีเซ็ตครั้งเดียว ไม่รีเซ็ตทุกรอบ (กัน event ที่มาช้าหาย)
	for attempt = 1, 5 do
		touch(60)
		if not model.Parent then return false end
		-- prompt ถูกปิดอยู่ (goblin กำลังคุย / คูลดาวน์): รอให้เปิดก่อน ไม่ต้องยิงรัวแล้ววาปหนี
		local w1 = os.clock()
		while model.Parent and not pp.Enabled and not dialogAt[model] and os.clock() - w1 < 25 do
			setStatus("prompt disabled, waiting: " .. model.Name)
			task.wait(0.3)
		end
		if dialogAt[model] then
			log("TALK " .. model.Name .. " (late)")
			return true
		end
		local hrp = hrpOf()
		if hrp and (hrp.Position - promptPos(model)).Magnitude > 10 then
			tpTo(model)
		end
		cancelEmote()
		if attempt >= 2 then exitEmote() end
		task.wait(0.4)
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
		local hp = hrpOf()
		log(("NOTE: no dialog yet on %s (try %d) enabled=%s dist=%.0f"):format(model.Name, attempt,
			tostring(pp.Enabled), hp and (hp.Position - promptPos(model)).Magnitude or -1))
		closeDialog()
		task.wait(0.6)
		if attempt == 3 then leaveDialog(model) end -- วาปถอยแค่ครั้งเดียว หลังลองครบ 3 รอบ
	end
	task.wait(3) -- event ที่มาช้ามากๆ
	if dialogAt[model] then return true end
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
	if l:find("catch%D*%d") and not l:find("different", 1, true) and not l:find("ghost", 1, true) then
		local n = numAfter(l, "catch")
		local key = l:gsub("%s*%(%s*%d[%d,]*%s*/%s*%d[%d,]*%s*%)", "")
		key = key:gsub("^%s+", ""):gsub("%s+$", "")
		return { kind = "catch", n = n and remaining(l, n) or 3, key = key,
			perfect = l:find("perfect", 1, true) ~= nil, flimsy = l:find("flimsy", 1, true) ~= nil }
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
					if o and o.kind ~= "skip" and o.kind ~= "catch" then return o, clean(g.Text) end
				end
			end
		end
	end
	return nil
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
		task.wait(3)
		local a = hudProgress("dance")
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
	cancelEmote() -- หยุดเต้นผ่าน remote ของเกมเอง
	exitEmote()
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

---------------------------------------------------------------- fishing (best effort)
local function findRod(flimsy)
	local best
	for _, c in ipairs({ lp.Character, lp.Backpack }) do
		if c then
			for _, t in ipairs(c:GetChildren()) do
				if t:IsA("Tool") then
					local n = t.Name:lower()
					if n:find("rod", 1, true) or t:FindFirstChild("events") then
						if not flimsy then
							best = best or t
						elseif n:find("flimsy", 1, true) then
							return t
						end
					end
				end
			end
		end
	end
	return best
end

-- ยิงเรย์ออกไป 16 ทิศ หาจุดพื้นสุดท้ายก่อนถึงน้ำ แล้วเลือกจุดที่ใกล้สุด
local function findShore(origin)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { lp.Character }
	rp.IgnoreWater = false
	local best, bestD
	for i = 0, 15 do
		local a = math.rad(i * 22.5)
		local dir = Vector3.new(math.cos(a), 0, math.sin(a))
		local prev
		for d = 6, 300, 6 do
			local p = origin + dir * d
			local hit = workspace:Raycast(p + Vector3.new(0, 120, 0), Vector3.new(0, -300, 0), rp)
			if not hit then break end
			if hit.Material == Enum.Material.Water then
				if prev and (not bestD or d < bestD) then best, bestD = { pos = prev, dir = dir }, d end
				break
			end
			prev = hit.Position
		end
	end
	return best
end

local function clickCenter(hold)
	if not VIM then return false end
	local v = workspace.CurrentCamera.ViewportSize
	VIM:SendMouseButtonEvent(v.X / 2, v.Y / 2, 0, true, game, 0)
	task.wait(hold)
	VIM:SendMouseButtonEvent(v.X / 2, v.Y / 2, 0, false, game, 0)
	return true
end

local function shakeClick()
	local sg = lp.PlayerGui:FindFirstChild("shakeui")
	if not (sg and sg:IsA("ScreenGui") and sg.Enabled) then return false end
	for _, g in ipairs(sg:GetDescendants()) do
		if g:IsA("GuiButton") and visibleChain(g) then
			press(g)
			return true
		end
	end
	return false
end

local function reelActive()
	local rg = lp.PlayerGui:FindFirstChild("reel")
	return rg ~= nil and rg:IsA("ScreenGui") and rg.Enabled
end

-- ตกปลาอัตโนมัติ (เดาจากโครงเกม Fisch เดิม: rod.events.cast / shakeui / reel / events.reelfinished)
-- ถ้าอันไหนไม่ตรง จะ log "FISH ..." ไว้ใน report ให้เอามาแก้ต่อ
local function doCatch(o)
	local hrp, hum = hrpOf()
	if not hrp or not hum then return false end
	local char = lp.Character
	local rod = findRod(o.flimsy)
	if not rod then
		log("FISH no " .. (o.flimsy and "Flimsy Rod" or "rod") .. " in backpack")
		return false
	end
	pcall(function() hum:EquipTool(rod) end)
	task.wait(0.6)
	local shore = findShore(hrp.Position)
	if shore then
		local eye = shore.pos + Vector3.new(0, 3.5, 0)
		hrp.CFrame = CFrame.lookAt(eye, eye + shore.dir * 10)
		hrp.AssemblyLinearVelocity = Vector3.zero
		task.wait(1)
	else
		log("FISH no water found near here - fishing where I stand")
	end
	local ev = rod:FindFirstChild("events")
	local castEv = ev and ev:FindFirstChild("cast")
	local resetEv = ev and ev:FindFirstChild("reset")
	local evs = RS:FindFirstChild("events")
	local finEv = evs and evs:FindFirstChild("reelfinished")
	local names = {}
	for _, root in ipairs({ evs, net }) do
		if root then
			for _, r in ipairs(root:GetChildren()) do
				local n = r.Name:lower()
				if n:find("reel", 1, true) or n:find("fishing", 1, true) or n:find("shake", 1, true) then
					names[#names + 1] = r:GetFullName()
				end
			end
		end
	end
	log(("FISH start rod=%s cast=%s reelfinished=%s need=%s | remotes: %s"):format(rod.Name,
		tostring(castEv ~= nil), tostring(finEv ~= nil), tostring(o.n), table.concat(names, ", ")))

	local fished, last = 0, nil
	local t0, moved = os.clock(), os.clock()
	while running and os.clock() - t0 < 1500 do
		touch(40)
		if lp.Character ~= char or hum.Health <= 0 then
			lastDied = true
			return false
		end
		local a, b = hudProgress(o.key)
		if a and b and a >= b then return true end
		if a == nil and fished >= (o.n or 3) then return true end -- ไม่เจอ HUD: นับเอง
		if a ~= last then last, moved = a, os.clock() end
		if os.clock() - moved > 180 then
			log("FISH progress not moving for 180s (hud=" .. tostring(a) .. ", caught=" .. fished .. ")")
			return false
		end

		if rod.Parent ~= lp.Character then
			pcall(function() hum:EquipTool(rod) end)
			task.wait(0.5)
		end
		if castEv then
			pcall(function() castEv:FireServer(100, 1) end)
		else
			clickCenter(0.9)
		end

		local c0, bite = os.clock(), false
		while os.clock() - c0 < 40 do
			touch(40)
			if not shakeClick() and reelActive() then
				bite = true
				task.wait(0.7)
				if not finEv then
					log("FISH reel ui is up but there is no events.reelfinished remote")
					return false
				end
				pcall(function() finEv:FireServer(100, true) end) -- 100 = perfect
				break
			end
			task.wait(0.1)
		end
		if bite then
			fished = fished + 1
			log(("FISH caught #%d hud=%s"):format(fished, tostring(a)))
			task.wait(2)
		else
			log("FISH no bite in 40s - reset + recast")
			if resetEv then pcall(function() resetEv:FireServer() end) end
			local nr = net and net:FindFirstChild("RE/FishingRod/Reset")
			if nr then pcall(function() nr:FireServer() end) end
			task.wait(1.5)
		end
	end
	return false
end

local function perform(o)
	if o.kind == "chat" then return doChat(o)
	elseif o.kind == "dance" then return doDance2(o)
	elseif o.kind == "jump" then return doJump(o)
	elseif o.kind == "walk" then return doWalk2(o)
	elseif o.kind == "catch" then return doCatch(o)
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

---------------------------------------------------------------- quest ledger
-- เควสที่รับแล้วแต่ยังไม่ส่ง: จำว่ารับจาก goblin ตัวไหน (UID / ชื่อ / ตำแหน่ง) + บรรทัด HUD ของเควสนั้น
local quests = {}
local spawnedAt = os.clock()
conns[#conns + 1] = lp.CharacterAdded:Connect(function() spawnedAt = os.clock() end)

-- "Perfect Catch 5 fish (0/5)" -> "perfect catch 5 fish"
local function questKey(raw)
	local l = clean(raw):lower()
	l = l:gsub("%s*%(%s*%d[%d,]*%s*/%s*%d[%d,]*%s*%)", "")
	l = l:gsub("^%s+", ""):gsub("%s+$", "")
	return l
end

-- หาบรรทัดเควสบน HUD: คืน a, b, found
local function hudLine(key)
	if key == "" then return nil, nil, false end
	for _, g in ipairs(texts(false)) do
		if g:GetFullName():find("deviceinset", 1, true) then
			local l = clean(g.Text):lower()
			if l:find(key, 1, true) then
				local a, b = l:match("(%d[%d,]*)%s*/%s*(%d[%d,]*)")
				if a and b then
					return tonumber((a:gsub(",", ""))), tonumber((b:gsub(",", ""))), true
				end
				return nil, nil, true
			end
		end
	end
	return nil, nil, false
end

local function dropQuest(q)
	for j = #quests, 1, -1 do
		if quests[j] == q then table.remove(quests, j) end
	end
end

local function addQuest(m, obj, raw)
	local uid = m:GetAttribute("UID")
	local key = questKey(raw)
	local manual = obj.kind == "skip" and obj.why ~= "guess" and obj.why ~= "insult"
	for _, q in ipairs(quests) do
		if q.model == m or (uid ~= nil and q.uid == uid) then
			q.raw, q.key, q.kind, q.model, q.manual = raw, key, obj.kind, m, manual
			return q
		end
	end
	local q = { model = m, name = m.Name, uid = uid, pos = m:GetPivot().Position,
		raw = raw, key = key, kind = obj.kind, manual = manual, at = os.clock(),
		seen = false, miss = 0, lastTry = 0, tries = 0, force = false }
	local _, _, f = hudLine(key)
	q.seen = f
	quests[#quests + 1] = q
	log(("QUEST saved: %s <- %s [%s]%s"):format(m.Name, raw, key, manual and " (manual)" or ""))
	return q
end

local function removeQuestFor(m)
	local uid = m:GetAttribute("UID")
	for j = #quests, 1, -1 do
		local q = quests[j]
		if q.model == m or (uid ~= nil and q.uid == uid) then table.remove(quests, j) end
	end
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
	removeQuestFor(m)
	return true
end

-- multiple-choice question (guess ...): reopening the dialog gives cs_start = "choicesN" and
-- initial_data = { msg, choice1..N }. The answer is DialogInteract(8 + N, picked index).
-- true = answered | false = could not open the dialog | nil = not a multiple-choice dialog
local function doChoice(m, alreadyOpen)
	local st0 = state[m]
	local tried = (st0 and st0.tried) or {} -- จำคำตอบที่ผิดข้ามรอบ
	if st0 then st0.tried = tried end
	for round = 1, 4 do
		if not (round == 1 and alreadyOpen) and not openDialog(m) then return false end
		local cfg = dialogCfg[m]
		local cs = cfg and tostring(cfg.cs_start) or ""
		local n = tonumber(cs:match("^choices(%d+)$"))
		local d = cfg and cfg.initial_data or {}
		if not DI then return false end
		if cs == "started2" then -- มีปุ่มเดียวให้กด (insult / say-this)
			log("ANSWER " .. clean(tostring(d.msg)) .. " -> " .. clean(tostring(d.choice)))
			local ok, res = pcall(function() return DI:InvokeServer(3, 1) end)
			log("DialogInteract returned " .. tostring(ok) .. " " .. fmt(res))
			softLeave(m)
			return ok
		end
		if not n then
			if round == 1 then
				log("NOTE: no multiple-choice dialog (cs_start=" .. cs .. ")")
				return nil
			end
			return true
		end
		local pool = {}
		for i = 1, n do
			if not tried[tostring(d["choice" .. i])] then pool[#pool + 1] = i end
		end
		if #pool == 0 then return true end
		local pick = pool[math.random(#pool)] -- สุ่มตอบ
		tried[tostring(d["choice" .. pick])] = true
		log(("ANSWER %s -> #%d %s"):format(clean(tostring(d.msg)), pick, clean(tostring(d["choice" .. pick]))))
		local ok, res = pcall(function() return DI:InvokeServer(8 + n, pick) end)
		log("DialogInteract returned " .. tostring(ok) .. " " .. fmt(res))
		softLeave(m)
		if not ok then return false end
		if not tostring(res):lower():find("wrong", 1, true) then return true end
	end
	return true
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
		log("NOTE: no quest/objective found on " .. m.Name
			.. " - open the dialog, press Dump UI, then send the report")
		return false
	end
	log("OBJECTIVE " .. raw .. " -> " .. obj.kind)
	if obj.kind ~= "skip" then s.obj = obj end
	if not raw:find("^%(remembered%)") then addQuest(m, obj, raw) end
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
		log("SKIP (do it manually): " .. obj.why)
		return true
	end

	setStatus(obj.kind .. ": " .. m.Name)
	if not perform(obj) then
		log("NOTE: objective did not finish")
		if obj.kind == "catch" and not lastDied then
			local q = addQuest(m, obj, raw)
			q.manual = true -- ตกเองไม่ได้: ให้เราตกเอง สคริปต์รอแล้วไปส่งให้ตอน HUD เต็ม
			log("FISH auto failed - fish by hand, I will turn it in when the HUD is full")
			return true
		end
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

local function sweepTp()
	local order = {}
	for _, h in ipairs(hints) do order[#order + 1] = { name = "hint", cf = h } end
	table.clear(hints)
	for _, s in ipairs(sweepSpots()) do order[#order + 1] = s end
	if #order == 0 then
		log("NOTE: no island spots (workspace.world.spawns.TpSpots) - fill CFG.extraSpots")
		return false
	end
	log("SWEEP " .. #order .. " spots")
	for _, s in ipairs(order) do
		if not running or not enabled then return false end
		local hrp = hrpOf()
		if not hrp then return false end
		setStatus("looking: " .. s.name)
		pcall(function() lp:RequestStreamAroundAsync(s.cf.Position) end)
		hrp.CFrame = s.cf + Vector3.new(0, 8, 0)
		hrp.AssemblyLinearVelocity = Vector3.zero
		hrp.Anchored = true -- do not fall while the ground streams in
		local found = false
		local t0 = os.clock()
		while os.clock() - t0 < CFG.sweepWait do
			task.wait(0.4)
			if #fresh() > 0 then
				found = true
				break
			end
		end
		local h2 = hrpOf()
		if h2 then h2.Anchored = false end
		if found then
			log("FOUND goblins near " .. s.name)
			return true
		end
	end
	log("SWEEP done, nothing found")
	return false
end


-- รอบแรกไม่ขยับตัวละคร: ขอให้เกม stream พื้นที่แต่ละเกาะมาให้ แล้วดูว่า goblin โผล่ไหม
local function sweepOnce()
	local order = {}
	for _, h in ipairs(hints) do order[#order + 1] = { name = "hint", cf = h } end
	for _, s in ipairs(sweepSpots()) do order[#order + 1] = s end
	log("SWEEP stream " .. #order .. " spots")
	for _, s in ipairs(order) do
		if not running or not enabled then return false end
		setStatus("scan: " .. s.name)
		pcall(function() lp:RequestStreamAroundAsync(s.cf.Position, 4) end)
		local t0 = os.clock()
		while os.clock() - t0 < 1.2 do
			if #fresh() > 0 then
				table.clear(hints)
				log("FOUND goblins near " .. s.name .. " (stream)")
				return true
			end
			task.wait(0.3)
		end
	end
	if CFG.sweepTp then
		log("SWEEP stream found nothing - fallback to teleport sweep")
		return sweepTp()
	end
	log("SWEEP stream found nothing")
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
gui.Parent = (gethui and gethui()) or game:GetService("CoreGui")

local function addButton(text, y, fn, x)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(0, 140, 0, 38)
	b.AnchorPoint = Vector2.new(1, 0)
	b.Position = UDim2.new(1, -(x or 10), 0, y)
	b.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
	b.TextColor3 = Color3.new(1, 1, 1)
	b.Text = text
	b.Parent = gui
	b.Activated:Connect(function() fn(b) end)
	return b
end

addButton("Auto: ON", 110, function(b)
	enabled = not enabled
	b.Text = enabled and "Auto: ON" or "Auto: OFF"
	if enabled then sweepNow = true; lastSweep = -1000 end
end)
addButton("Copy report", 156, function()
	local txt = table.concat(lines, "\n")
	if setclipboard then setclipboard(txt) else warn("executor has no setclipboard") end
end)
addButton("Clear", 202, function()
	table.clear(lines)
	table.clear(seen)
end)
addButton("Dump UI", 248, function() dumpUI() end)
addButton("Sweep now", 294, function()
	sweepNow = true
	lastSweep = -1000
end)

-- คอลัมน์ 2: เลือกระดับเควส
local function paint(b, on)
	b.BackgroundColor3 = on and Color3.fromRGB(30, 120, 60) or Color3.fromRGB(25, 25, 30)
end
for i, l in ipairs(DIFF) do
	local function label() return (CFG.levels[l] and "[x] " or "[ ] ") .. l end
	local btn = addButton(label(), 110 + (i - 1) * 46, function(b)
		CFG.levels[l] = not CFG.levels[l]
		b.Text = label()
		paint(b, CFG.levels[l])
	end, 156)
	paint(btn, CFG.levels[l])
end
local talkBtn = addButton(CFG.talk and "Talk: ON" or "Talk: OFF", 340, function(b)
	CFG.talk = not CFG.talk
	b.Text = CFG.talk and "Talk: ON" or "Talk: OFF"
	paint(b, CFG.talk)
end, 156)
paint(talkBtn, CFG.talk)

-- คอลัมน์ 3: วาปไปเกาะ (goblin โหลดแล้ว Auto จะหยิบเอง)
local function goTo(cf)
	local hrp = hrpOf()
	if not hrp then return false end
	local p = cf.Position
	pcall(function() lp:RequestStreamAroundAsync(p) end)
	hrp.Anchored = true
	hrp.CFrame = CFrame.new(p + Vector3.new(0, 150, 0))
	hrp.AssemblyLinearVelocity = Vector3.zero
	task.wait(1.5)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { lp.Character }
	local hit
	for _ = 1, 8 do
		hit = workspace:Raycast(p + Vector3.new(0, 400, 0), Vector3.new(0, -900, 0), rp)
		if hit then break end
		task.wait(0.5)
	end
	hrp.CFrame = CFrame.new(hit and (hit.Position + Vector3.new(0, 5, 0)) or (p + Vector3.new(0, 8, 0)))
	hrp.Anchored = false
	return true
end

local lastIsl
-- กดปุ่มเกาะที่วาปไม่ได้ -> ไปยืนบนเกาะนั้นเอง -> กด Mark spot : เซฟพิกัด + log บรรทัดให้ก๊อปไปใส่ CFG.islandPos
local function markSpot()
	local hrp = hrpOf()
	if not (hrp and lastIsl) then
		setStatus("press an island first")
		return
	end
	local p = hrp.Position
	CFG.islandPos[lastIsl[1]] = p
	log(('SPOT SAVED ["%s"] = Vector3.new(%.0f, %.0f, %.0f),'):format(lastIsl[1], p.X, p.Y, p.Z))
	setStatus("saved " .. lastIsl[1])
end

local function goIsland(isl)
	lastIsl = isl
	local cf = findIsland(isl)
	if not cf then
		log("NOTE: island not found: " .. isl[1] .. " - press Dump islands, or fill CFG.islandPos")
		setStatus("no spot: " .. isl[1])
		return
	end
	log("TP island " .. isl[1])
	setStatus("tp: " .. isl[1])
	goTo(cf)
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

local islandFrame = Instance.new("ScrollingFrame")
islandFrame.Size = UDim2.new(0, 150, 0, 280)
islandFrame.AnchorPoint = Vector2.new(1, 0)
islandFrame.Position = UDim2.new(1, -302, 0, 110)
islandFrame.BackgroundColor3 = Color3.new(0, 0, 0)
islandFrame.BackgroundTransparency = 0.5
islandFrame.ScrollBarThickness = 4
islandFrame.CanvasSize = UDim2.new(0, 0, 0, (#ISLANDS + 2) * 40 + 4)
islandFrame.Parent = gui
for i = 1, #ISLANDS + 2 do
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, -10, 0, 36)
	b.Position = UDim2.new(0, 4, 0, 4 + (i - 1) * 40)
	b.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
	b.TextColor3 = Color3.new(1, 1, 1)
	b.TextSize = 14
	b.Parent = islandFrame
	if ISLANDS[i] then
		b.Text = ISLANDS[i][1]
		b.Activated:Connect(function() goIsland(ISLANDS[i]) end)
	elseif i == #ISLANDS + 1 then
		b.Text = "Dump islands"
		b.Activated:Connect(dumpIslands)
	else
		b.Text = "Mark spot"
		b.Activated:Connect(markSpot)
	end
end

statusLbl = Instance.new("TextLabel")
statusLbl.Size = UDim2.new(0, 140, 0, 36)
statusLbl.AnchorPoint = Vector2.new(1, 0)
statusLbl.Position = UDim2.new(1, -10, 0, 340)
statusLbl.BackgroundColor3 = Color3.new(0, 0, 0)
statusLbl.BackgroundTransparency = 0.4
statusLbl.TextColor3 = Color3.new(1, 1, 1)
statusLbl.TextSize = 12
statusLbl.TextWrapped = true
statusLbl.Text = "idle"
statusLbl.Parent = gui

genv.GoblinAutoStop = function()
	running = false
	for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	local h = hrpOf()
	if h then pcall(function() h.Anchored = false end) end
	gui:Destroy()
end

---------------------------------------------------------------- main loop
conns[#conns + 1] = lp.CharacterAdded:Connect(function()
	sweepNow = true
end)

---------------------------------------------------------------- main loop + watchdog
local loopThread
local lastWork = os.clock() -- ครั้งสุดท้ายที่ loop เข้าไปทำงานกับ goblin จริงๆ

-- ปลดทุกอย่างที่อาจค้าง: anchor, bind เดิน, emote, dialog
local function unstick(why)
	log("WATCHDOG unstick: " .. why)
	pcall(function() RunService:UnbindFromRenderStep("GA_walk") end)
	local h, hum = hrpOf()
	if h then pcall(function() h.Anchored = false end) end
	if hum then pcall(function() hum:Move(Vector3.zero, false) end) end
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
		if not st.done then st.tries = 0 end
	end
end

-- goblin ที่รับเควสนี้มา (ตัวเดิม > UID เดิม > ชื่อเดียวกันที่ใกล้ตำแหน่งเดิมสุด)
local function findQuestGoblin(q)
	if q.model and q.model.Parent then return q.model end
	local best, bd
	for _, m in ipairs(goblins()) do
		if q.uid ~= nil and m:GetAttribute("UID") == q.uid then return m end
		if m.Name == q.name then
			local d = (m:GetPivot().Position - q.pos).Magnitude
			if not bd or d < bd then best, bd = m, d end
		end
	end
	return best
end

local function claimQuest(q)
	pcall(function() lp:RequestStreamAroundAsync(q.pos, 4) end)
	local m
	local t0 = os.clock()
	while os.clock() - t0 < 8 do
		m = findQuestGoblin(q)
		if m then break end
		task.wait(0.4)
	end
	if not m then
		log("QUEST claim: " .. q.name .. " not found")
		return false
	end
	local res = turnIn(m)
	if res then
		local ok, s = pcall(stOf, m)
		if ok then
			s.done = true
			s.at = os.clock()
		end
	end
	return res
end

-- มีเควสที่สคริปต์ทำเองไม่ได้ (catch / perfect / ...) กำลังรอให้เราทำเองอยู่ไหม
local function holdNow()
	if not CFG.holdManual then return nil end
	for _, q in ipairs(quests) do
		if q.manual and os.clock() - q.at < CFG.manualTimeout then return q end
	end
	return nil
end

-- ดู HUD ทุกรอบ: เสร็จแล้ว (a>=b) หรือบรรทัดหายไปหลังเคยเห็น -> วาปไปส่งที่ goblin ตัวที่รับมาทันที
local function checkQuests()
	for i = #quests, 1, -1 do
		local q = quests[i]
		if q then
			local a, b, found = hudLine(q.key)
			local ready = q.force
			if found then
				q.seen, q.miss = true, 0
				q.prog = (a and b) and (a .. "/" .. b) or "?"
				if a and b and a >= b then ready = true end
			elseif q.seen then
				q.miss = q.miss + 1
				if q.miss >= 3 and os.clock() - spawnedAt > 12 then ready = true end
			end
			if ready and os.clock() - q.lastTry > 20 then
				q.lastTry = os.clock()
				q.tries = q.tries + 1
				q.force = false
				log(("QUEST ready: %s <- %s (%s) -> turn in"):format(q.name, q.raw, tostring(q.prog)))
				setStatus("turn in: " .. q.name)
				touch(90)
				local ok, res = pcall(claimQuest, q)
				if not ok then
					log("ERR claim " .. tostring(res))
					unstick("claim error")
				elseif res then
					dropQuest(q)
				end
				if q.tries >= 6 then
					log("QUEST gave up: " .. q.name)
					dropQuest(q)
				end
			end
		end
	end
end

local holdBtn = addButton(CFG.holdManual and "Hold: ON" or "Hold: OFF", 386, function(b)
	CFG.holdManual = not CFG.holdManual
	b.Text = CFG.holdManual and "Hold: ON" or "Hold: OFF"
	paint(b, CFG.holdManual)
end, 156)
paint(holdBtn, CFG.holdManual)
addButton("Claim now", 386, function()
	for _, q in ipairs(quests) do q.force, q.lastTry = true, 0 end
	log("QUEST claim now: " .. #quests)
end, 10)

local function tickOnce()
	checkQuests()
	local hq = holdNow()
	if hq then -- เควสที่ต้องทำเอง: ไม่วาป ไม่ sweep รอจนเสร็จ แล้ว checkQuests จะพาไปส่งเอง
		setStatus(("manual: %s %s"):format(hq.raw, hq.prog and ("[" .. hq.prog .. "]") or ""))
		return
	end
	local list = fresh()
	local now = os.clock()
	if #list == 0 and CFG.sweep
		and ((sweepNow and not pending() and now - lastSweep > 8) or now - lastSweep > CFG.sweepEvery) then
		sweepNow = false
		lastSweep = now
		touch(150)
		local ok, err = pcall(sweepOnce)
		lastSweep = os.clock() -- นับเวลาจากตอนจบ sweep
		if not ok then log("ERR sweep " .. tostring(err)) end
		local h = hrpOf()
		if h then h.Anchored = false end
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
				lastWork = os.clock()
				lastDied = false
				touch(90)
				local ok, res = pcall(handleGoblin, m, s)
				lastWork = os.clock()
				if not ok then
					log("ERR " .. tostring(res))
					unstick("error in handleGoblin")
				elseif lastDied then
					lastDied = false
					s.tries = math.max(0, s.tries - 1) -- ตายไม่นับเป็นความพยายาม
					waitAlive(25)
				elseif res then
					s.done = true
					s.at = os.clock()
				end
			end
		end
	end
	setStatus("idle")
end

local function startLoop()
	if loopThread then pcall(task.cancel, loopThread) end
	touch(60)
	lastWork = os.clock()
	loopThread = task.spawn(function()
		while running do
			if enabled and hrpOf() then
				local ok, err = pcall(tickOnce)
				if not ok then
					log("ERR loop " .. tostring(err))
					unstick("loop error")
				end
			end
			task.wait(CFG.scanDelay)
		end
	end)
end
startLoop()

-- watchdog: loop ค้าง / ตาย / goblin รออยู่แต่ไม่มีใครทำอะไร -> ปลด + เริ่มใหม่ + ดึงกลับไปหา goblin
task.spawn(function()
	while running do
		task.wait(3)
		if CFG.watchdog and enabled and hrpOf() then
			local now = os.clock()
			local dead = loopThread ~= nil and coroutine.status(loopThread) == "dead"
			if dead or now - wd.beat > wd.limit then
				log(("WATCHDOG %s (%.0fs, status=%s)"):format(dead and "loop dead" or "hung",
					now - wd.beat, statusLbl and statusLbl.Text or "?"))
				unstick("restart loop")
				refundTries()
				sweepNow = true
				startLoop()
			elseif now - lastWork > CFG.wdKick and pending() and not holdNow() then
				log("WATCHDOG kick: goblin waiting, idle " .. CFG.wdKick .. "s")
				unstick("idle kick")
				refundTries()
				lastWork = now
			end
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
log("READY v4 | difficulty=" .. CFG.difficulty .. " | waiting for goblins")
