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
	sweepEvery = 300,        -- seconds between sweeps while no goblin is around
	sweepWait = 2.5,         -- seconds to wait on each island for things to stream in
	retryAfter = 300,        -- a finished goblin that stays in place is retried after this long
	extraSpots = {},         -- optional: { { name = "Island", pos = Vector3.new(x, y, z) } }
	talk = true,             -- false = ไม่คุยกับ goblin เลย
	levels = { easy = true, normal = false, hard = false, extreme = false, ultimate = false },
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

local function setStatus(s)
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
			-- a model without any part is not streamed in yet
			if m:IsA("Model") and m:FindFirstChildWhichIsA("BasePart", true) then
				out[#out + 1] = m
			end
		end
	end
	return out
end

local function tpTo(model)
	local hrp = hrpOf()
	if not hrp or not model.Parent then return false end
	local cf = model:GetPivot()
	pcall(function() lp:RequestStreamAroundAsync(cf.Position) end)
	hrp.CFrame = cf * CFG.tpOffset
	hrp.AssemblyLinearVelocity = Vector3.zero
	task.wait(1)
	return model.Parent ~= nil
end

local function exitEmote()
	local hrp, hum = hrpOf()
	if not hrp or not hum then return end
	for _, tr in ipairs(hum:GetPlayingAnimationTracks()) do
		pcall(function() tr:Stop(0.1) end)
	end
	hum:MoveTo(hrp.Position + hrp.CFrame.LookVector * 4) -- ขยับตัวแล้วท่าเต้นจะหลุด
	task.wait(0.4)
	hum.Jump = true
	task.wait(0.5)
end

local ISLANDS = {
	{ "Ancient Isle", "ancient" }, { "Drylands", "dryland" }, { "Everturn Forest", "everturn" },
	{ "Forsaken Shores", "forsaken" }, { "Lost Jungle", "lost jungle", "lostjungle" },
	{ "Moosewood", "moosewood" }, { "Mushgrove Swamp", "mushgrove" }, { "Roslit Bay", "roslit" },
	{ "Scoria Reach", "scoria" }, { "Skycrest", "skycrest" }, { "Sunstone Island", "sunstone" },
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

local function findIsland(isl)
	local name = isl[1]
	if CFG.islandPos[name] then return CFrame.new(CFG.islandPos[name]) end
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

local MAXTRY = 2
local function stOf(m)
	local pos = m:GetPivot().Position
	local s = state[m]
	if s then
		local age = os.clock() - s.at
		local moved = (s.pos - pos).Magnitude > 25
		local expired = (s.done and age > CFG.retryAfter)
			or (not s.done and s.tries >= MAXTRY and age > 120)
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

local function listen(r)
	if r and r:IsA("BaseRemoteEvent") then
		conns[#conns + 1] = r.OnClientEvent:Connect(function(...)
			local t = table.pack(...)
			local parts = {}
			local deep = (r.Name == "dialogstart") and 6 or 2
			for i = 1, t.n do parts[i] = fmt(t[i], 0, deep) end
			local s = "EVENT " .. r.Name .. "(" .. table.concat(parts, ", ") .. ")"
			if #s > 6000 then s = s:sub(1, 6000) .. "...<cut>" end
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

---------------------------------------------------------------- dialog
local DIFF = { "easy", "normal", "hard", "extreme", "ultimate" }
local function levelOrder()
	local o = {}
	for _, d in ipairs(DIFF) do
		if CFG.levels[d] then o[#o + 1] = d end
	end
	return o
end

local EXCLUDE = { "never", "leave", "bye", "cancel", "close", "decline", "nope", "not now", "no thanks" }
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
	for attempt = 1, 4 do
		if not model.Parent then return false end
		local hrp = hrpOf()
		if hrp and (hrp.Position - model:GetPivot().Position).Magnitude > 14 then
			tpTo(model)
		end
		dialogAt[model] = nil
		if attempt >= 2 then exitEmote() end
		if fireproximityprompt and attempt % 2 == 1 then
			pcall(fireproximityprompt, pp)
		else
			pcall(function()
				pp:InputHoldBegin()
				task.wait(0.2)
				pp:InputHoldEnd()
			end)
		end
		local w0 = os.clock()
		while os.clock() - w0 < 2.5 do
			if dialogAt[model] then break end
			if not dsEvent and pickRoot() then break end
			task.wait(0.1)
		end
		if dialogAt[model] or (not dsEvent and pickRoot()) then
			log("TALK " .. model.Name)
			return true
		end
		log("NOTE: no dialog yet on " .. model.Name .. " (try " .. attempt .. ")")
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
	if l:find("dance", 1, true) and l:find("%d") then
		return { kind = "dance", secs = numAfter(l, "dance") or 15 }
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

local function activeObjective()
	for _, g in ipairs(texts(false)) do
		local o = parse(g.Text)
		if o and o.kind ~= "skip" then return o, clean(g.Text) end
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
			if not running then return false end
			r:FireServer()
			task.wait(0.12)
		end
	else
		for _ = 1, n do
			if not running then return false end
			hum.Jump = true
			hum:ChangeState(Enum.HumanoidStateType.Jumping)
			task.wait(0.55)
		end
	end
	return true
end

local function doWalk(o)
	local hrp, hum = hrpOf()
	if not hrp or not hum then return false end
	local goal = (o.n or 50) * 1.1 + 5
	log("WALK " .. goal .. " studs")
	local walked, last = 0, hrp.Position
	local hb = RunService.Heartbeat:Connect(function()
		local h = hrpOf()
		if not h then return end
		local d = (h.Position - last).Magnitude
		if d < 8 then walked = walked + d end -- ignore teleports
		last = h.Position
	end)

	local fwd = hrp.CFrame.LookVector * Vector3.new(1, 0, 1)
	if fwd.Magnitude < 0.1 then fwd = Vector3.new(0, 0, 1) end
	local a, b = hrp.Position, hrp.Position + fwd.Unit * 25
	local toB = true
	local t0 = os.clock()
	local timeout = goal / 10 + 30

	while walked < goal and running and os.clock() - t0 < timeout do
		local target = toB and b or a
		hum:MoveTo(target)
		local s = os.clock()
		repeat
			task.wait(0.1)
			local h = hrpOf()
			if not h then break end
		until (h.Position - target).Magnitude < 4 or os.clock() - s > 3.5
		toB = not toB
	end
	hb:Disconnect()
	return walked >= goal
end

local function perform(o)
	if o.kind == "chat" then return doChat(o)
	elseif o.kind == "dance" then return doDance(o)
	elseif o.kind == "jump" then return doJump(o)
	elseif o.kind == "walk" then return doWalk(o)
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
	advance(5, false)
	log("DONE " .. m.Name)
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
		log("NOTE: no quest/objective found on " .. m.Name
			.. " - open the dialog, press Dump UI, then send the report")
		return false
	end
	log("OBJECTIVE " .. raw .. " -> " .. obj.kind)
	if obj.kind == "skip" then
		log("SKIP (do it manually): " .. obj.why)
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

local function sweepOnce()
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

---------------------------------------------------------------- UI
local function dumpUI()
	log("---- UI DUMP (visible text) ----")
	local n = 0
	for _, g in ipairs(texts(false)) do
		n = n + 1
		if n > 120 then break end
		log(('UI %s | "%s" | button=%s'):format(g:GetFullName(), clean(g.Text):sub(1, 50),
			tostring(clickTarget(g) ~= nil)))
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

local function goIsland(isl)
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
islandFrame.CanvasSize = UDim2.new(0, 0, 0, (#ISLANDS + 1) * 40 + 4)
islandFrame.Parent = gui
for i = 1, #ISLANDS + 1 do
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
	else
		b.Text = "Dump islands"
		b.Activated:Connect(dumpIslands)
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
	sweepNow = true; lastSweep = -1000
end)

task.spawn(function()
	while running do
		if enabled and hrpOf() then
			local list = fresh()
			local now = os.clock()
			if #list == 0 and CFG.sweep
				and ((sweepNow and now - lastSweep > 20) or now - lastSweep > CFG.sweepEvery) then
				sweepNow = false
				lastSweep = now
				local ok, err = pcall(sweepOnce)
				if not ok then log("ERR sweep " .. tostring(err)) end
				local h = hrpOf()
				if h then h.Anchored = false end
				list = fresh()
			end

			local hrp = hrpOf()
			if hrp then
				table.sort(list, function(x, y)
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
						local ok, res = pcall(handleGoblin, m, s)
						if not ok then
							log("ERR " .. tostring(res))
						elseif res then
							s.done = true
							s.at = os.clock()
						end
					end
				end
			end
			setStatus("idle")
		end
		task.wait(CFG.scanDelay)
	end
end)

log("READY v4 | difficulty=" .. CFG.difficulty .. " | waiting for goblins")
