-- Auto Rejoin: เน็ตหลุด / โดนเตะ / เซิร์ฟล่ม -> เข้าเกมใหม่เอง (ใช้ได้กับทุกแมพ ทุกเกม)
--   1) เฝ้าหน้าต่างแจ้งหลุดของ Roblox พอขึ้นก็สั่งเข้าเกมใหม่ ถ้าเน็ตยังไม่มาจะลองซ้ำเรื่อยๆ
--   2) กันโดนเตะเพราะ AFK 20 นาที (ปิดได้)
--   3) UI แบบ Dynamic Island สไตล์ iOS: แตะเพื่อดูข้อมูล/ประวัติการหลุด ลากเพื่อย้าย · แท็บ "ธีม" เปลี่ยนโหมดมืด/สว่าง/อัตโนมัติ สีหลัก และขนาดได้ (แท็บเล็ตขยายให้เอง)
-- ไม่มีลูปเข้าโหมด/เข้าด่านอะไรทั้งนั้น ทำแค่พากลับเข้าเกม
-- วางทั้งไฟล์ใน executor แล้วรันครั้งเดียว มันจะเซฟตัวเองเป็น aa_rejoin.lua ใน workspace
-- แล้วรันซ้ำเองหลังวาร์ปทุกครั้ง (queue_on_teleport)
-- แนะนำ: ก๊อป aa_rejoin.lua ไปไว้ในโฟลเดอร์ autoexec ของ executor ด้วย (ถ้ามี)

local SRC = [==[
local CFG = {
    -- เข้าเกมใหม่ที่ไหน:
    --   0 = อัตโนมัติ (หน้าหลักของเกมนั้นถ้าหาได้ ไม่งั้นแมพที่อยู่ตอนหลุด)
    --   ใส่ PlaceId เอง = บังคับเข้าแมพนั้นทุกครั้ง (ใช้เมื่อเกมมีหลายแมพแล้วอยากกลับแมพที่ฟาร์มโดยตรง)
    REJOIN_PLACE_ID    = 0,
    USE_ROOT_PLACE     = true,  -- โหมดอัตโนมัติ: ใช้หน้าหลักของเกม (เช่น ล็อบบี้) แทนแมพที่หลุด
    TRY_SAME_SERVER    = true,  -- ครั้งแรกลองกลับเซิร์ฟเดิม (ได้เฉพาะเซิร์ฟสาธารณะที่ยังไม่ปิด) ไม่ได้ค่อยเข้าใหม่
    CONFIRM_SECONDS    = 4,     -- หน้าต่างหลุดต้องค้างกี่วินาทีถึงจะเริ่มรีจอย (กันเด้งผิด)
    RETRY_DELAY        = 15,    -- พักระหว่างพยายามเข้าใหม่ (เพิ่มทีละเท่านี้ สูงสุด 120 วิ)
    ANTI_IDLE          = true,  -- กันโดนเตะเพราะ AFK
    AFTER_REJOIN_FILE  = "",    -- ชื่อไฟล์สคิปฟาร์มใน workspace ที่อยากให้รันหลังรีจอย (เว้นว่างถ้าสคิปนั้นอยู่ใน autoexec แล้ว)
    WEBHOOK            = "",    -- ลิงก์ Discord webhook ถ้าอยากให้แจ้งเตือนตอนกลับเข้าเกมได้ (เว้นว่าง = ไม่ใช้)
    DISABLE_OLD        = true,  -- ปิดสคิปเก่า (aa_failsafe / aa_guard) ไม่ให้รันซ้ำหลังวาร์ป
    DEBUG              = true,
    SHOW_UI            = true,
}

local FILE        = "aa_rejoin.lua"
local STATE_FILE  = "aa_rejoin_state.json"

local Players    = game:GetService("Players")
local TS         = game:GetService("TeleportService")
local HS         = game:GetService("HttpService")
local UIS        = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local lp = Players.LocalPlayer
if not game:IsLoaded() then game.Loaded:Wait() end

local genv = (getgenv and getgenv()) or _G
if genv.AA_REJOIN_RUNNING then return end
genv.AA_REJOIN_RUNNING = true

local T0 = os.clock()
local function fmt(sec)
    sec = math.max(0, math.floor(sec))
    return string.format("%d:%02d:%02d", math.floor(sec / 3600), math.floor((sec % 3600) / 60), sec % 60)
end
local function span(d)
    d = math.max(0, math.floor(d))
    if d < 60 then return d .. " วิ" end
    if d < 3600 then return math.floor(d / 60) .. " นาที" end
    return math.floor(d / 3600) .. " ชม. " .. math.floor((d % 3600) / 60) .. " น."
end
local function ago(t)
    if not t then return "ยังไม่เคย" end
    return span(os.time() - t) .. " ที่แล้ว"
end

-- ===================== สถานะที่เก็บข้ามการวาร์ป =====================
local function loadState()
    local ok, d = pcall(function() return HS:JSONDecode(readfile(STATE_FILE)) end)
    if ok and type(d) == "table" then return d end
    return {}
end
local S = loadState()
S.reconnects = S.reconnects or 0
S.events = S.events or {}
S.roots = S.roots or {}
if S.auto == nil then S.auto = true end
local function saveState()
    pcall(writefile, STATE_FILE, HS:JSONEncode(S))
end
local function pushEvent(kind, msg)
    table.insert(S.events, { t = os.time(), k = kind, m = msg })
    while #S.events > 30 do table.remove(S.events, 1) end
    saveState()
end

-- ตัวแปรขณะรัน
local RT = { auto = S.auto, rejoining = false, idleHits = 0 }

-- จะรีจอยไปแมพไหน (ตัดสินตอนหลุดจริง จึงอ่านจากค่าที่เก็บไว้ ไม่ต้องใช้เน็ต)
local function resolveTarget()
    if type(CFG.REJOIN_PLACE_ID) == "number" and CFG.REJOIN_PLACE_ID ~= 0 then
        return CFG.REJOIN_PLACE_ID, "ตั้งเอง"
    end
    if CFG.USE_ROOT_PLACE then
        local r = S.roots[tostring(game.GameId)]
        if r then return r, "หน้าหลักเกม" end
    end
    return game.PlaceId, "แมพปัจจุบัน"
end

-- ===================== UI (Dynamic Island สไตล์ iOS) =====================
local TweenService = game:GetService("TweenService")
local RunService   = game:GetService("RunService")

-- ฟอนต์: Gotham ใกล้ SF Pro ที่สุดใน Roblox (ถ้าตัวอักษรไทยดูแปลก เปลี่ยนตรงนี้ที่เดียวได้)
local F = {
    reg  = Enum.Font.GothamMedium,
    semi = Enum.Font.GothamSemibold,
    bold = Enum.Font.GothamBold,
    mono = Enum.Font.RobotoMono,
}

-- ---------- ธีม (โทนสีระบบของ iOS) ----------
local THEMES = {
    dark = {
        island = Color3.fromRGB(0, 0, 0),
        card   = Color3.fromRGB(28, 28, 30),
        seg    = Color3.fromRGB(28, 28, 30),
        segIn  = Color3.fromRGB(58, 58, 62),
        thumb  = Color3.fromRGB(99, 99, 102),
        line   = Color3.fromRGB(58, 58, 62),
        text   = Color3.fromRGB(255, 255, 255),
        dim    = Color3.fromRGB(142, 142, 147),
        swOff  = Color3.fromRGB(57, 57, 61),
        ok     = Color3.fromRGB(48, 209, 88),
        warn   = Color3.fromRGB(255, 159, 10),
        bad    = Color3.fromRGB(255, 69, 58),
    },
    light = {
        island = Color3.fromRGB(242, 242, 247),
        card   = Color3.fromRGB(255, 255, 255),
        seg    = Color3.fromRGB(226, 226, 231),
        segIn  = Color3.fromRGB(238, 238, 243),
        thumb  = Color3.fromRGB(255, 255, 255),
        line   = Color3.fromRGB(214, 214, 220),
        text   = Color3.fromRGB(20, 20, 22),
        dim    = Color3.fromRGB(110, 110, 118),
        swOff  = Color3.fromRGB(225, 225, 230),
        ok     = Color3.fromRGB(52, 199, 89),
        warn   = Color3.fromRGB(255, 149, 0),
        bad    = Color3.fromRGB(255, 59, 48),
    },
}
-- { ชื่อ, สีโหมดสว่าง, สีโหมดมืด }
local ACCENTS = {
    { "ฟ้า",     Color3.fromRGB(0, 122, 255),  Color3.fromRGB(10, 132, 255) },
    { "เขียว",   Color3.fromRGB(52, 199, 89),  Color3.fromRGB(48, 209, 88) },
    { "ส้ม",     Color3.fromRGB(255, 149, 0),  Color3.fromRGB(255, 159, 10) },
    { "ชมพู",    Color3.fromRGB(255, 45, 85),  Color3.fromRGB(255, 55, 95) },
    { "ม่วง",    Color3.fromRGB(175, 82, 222), Color3.fromRGB(191, 90, 242) },
    { "แดง",     Color3.fromRGB(255, 59, 48),  Color3.fromRGB(255, 69, 58) },
    { "ฟ้าอ่อน", Color3.fromRGB(48, 176, 199), Color3.fromRGB(64, 200, 224) },
}
local MODES     = { "dark", "light", "auto" }
local SIZE_MULT = { 0.85, 1, 1.2 }

-- ชื่อสีสำหรับส่งเข้า UI.set (ค่าสีจริงเปลี่ยนตามธีมเอง)
local COL = { ok = "ok", warn = "warn", bad = "bad", dim = "dim", text = "text", acc = "acc" }

local CW, CH = 262, 36    -- ขนาดตอนย่อ (เม็ดยา)
local EW, EH = 336, 366   -- ขนาดตอนขยาย (ขนาดออกแบบ ก่อนคูณสเกลตามหน้าจอ)
local UI = {
    gui = nil, color = "dim", act = {}, expanded = false, page = 1, tick = false,
    dots = {}, hooks = {}, lastToggle = 0, isDark = true,
}
local logLines, allLines = {}, {}
local FPS = { frames = 0, value = 0, t = os.clock() }
local TH = {}   -- ธีมที่ใช้อยู่ตอนนี้ (ชื่อสี -> Color3)

local function currentDark()
    local m = S.mode or "dark"
    if m == "auto" then
        local h = tonumber(os.date("%H")) or 20
        return not (h >= 6 and h < 18)   -- กลางวันสว่าง กลางคืนมืด ตามนาฬิกาเครื่อง
    end
    return m ~= "light"
end

local function computeTheme()
    local dark = currentDark()
    local base = dark and THEMES.dark or THEMES.light
    for k, v in pairs(base) do TH[k] = v end
    local a = ACCENTS[S.accent or 1] or ACCENTS[1]
    TH.acc = dark and a[3] or a[2]
    return dark
end
computeTheme()

-- ---------- ตัวช่วยสร้าง UI + ระบบผูกสีกับธีม ----------
local binds, bindOf = {}, {}
local TI_THEME = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- ค่าที่เป็นข้อความในพร็อพเพอร์ตี้สี (เช่น BackgroundColor3 = "card") = ชื่อสีของธีม จะเปลี่ยนตามธีมเอง
local function new(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props) do
        if type(v) == "string" and (k == "Color" or k:sub(-6) == "Color3") then
            local rec = { o = o, p = k, k = v }
            binds[#binds + 1] = rec
            bindOf[o] = bindOf[o] or {}
            bindOf[o][k] = rec
            o[k] = TH[v]
        else
            o[k] = v
        end
    end
    o.Parent = parent
    return o
end

local function round(o, r)
    new("UICorner", { CornerRadius = r or UDim.new(1, 0) }, o)
    return o
end

local function tw(o, t, props, style, dir)
    local tween = TweenService:Create(o, TweenInfo.new(t, style or Enum.EasingStyle.Quint, dir or Enum.EasingDirection.Out), props)
    tween:Play()
    return tween
end

-- เปลี่ยนชื่อสีที่ผูกไว้ (เช่น ตัวหนังสือจาก "dim" เป็น "text") แบบมีแอนิเมชัน
local function recolor(o, p, key, animated)
    local rec = bindOf[o] and bindOf[o][p]
    if rec then
        if rec.k == key then return end
        rec.k = key
    end
    local c = TH[key]
    if not c then return end
    if animated == false then o[p] = c else TweenService:Create(o, TI_THEME, { [p] = c }):Play() end
end

local function applyTheme(animated)
    UI.isDark = computeTheme()
    for _, rec in ipairs(binds) do
        local c = TH[rec.k]
        if c and rec.o.Parent ~= nil then
            if animated then TweenService:Create(rec.o, TI_THEME, { [rec.p] = c }):Play()
            else rec.o[rec.p] = c end
        end
    end
    for _, h in ipairs(UI.hooks) do pcall(h, animated) end
    if UI.paint then UI.paint(true) end
end

local function mount(gui)
    local getters = {
        function() return gethui and gethui() end,
        function() return game:GetService("CoreGui") end,
        function() return lp:WaitForChild("PlayerGui", 10) end,
    }
    for _, get in ipairs(getters) do
        local ok, p = pcall(get)
        if ok and p then
            local ok2 = pcall(function() gui.Parent = p end)
            if ok2 and gui.Parent == p then return true end
        end
    end
    return false
end

local function commas(n)
    local s = tostring(math.floor(n))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    out = (out:gsub("^,", ""))
    return out
end

local function getPing()
    local ok, v = pcall(function()
        return game:GetService("Stats").Network.ServerStatsItem["Data Ping"]:GetValue()
    end)
    if ok and type(v) == "number" then return math.floor(v) end
    return nil
end

-- ขนาดหน้าจอ + กันเกาะหลุดขอบ
local function getVP()
    local v = UI.gui and UI.gui.AbsoluteSize or Vector2.new(0, 0)
    if v.X < 50 or v.Y < 50 then
        local cam = workspace.CurrentCamera
        v = cam and cam.ViewportSize or Vector2.new(1280, 720)
    end
    return v
end

local function clampXY(x, y, w, h)
    local vp = getVP()
    local mx = math.max(0, vp.X / 2 - w / 2 - 6)
    local my = math.max(6, vp.Y - h - 6)
    return math.clamp(x, -mx, mx), math.clamp(y, 6, my)
end

-- ลาก = ย้าย / แตะ = onTap
local function makeDrag(handle, target, onTap)
    local down, moved, startPos, startPosV = false, false, nil, nil
    handle.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            down, moved = true, false
            startPosV, startPos = i.Position, target.Position
            i.Changed:Connect(function()
                if i.UserInputState == Enum.UserInputState.End then
                    local wasDown, wasMoved = down, moved
                    down = false
                    if wasDown then
                        if wasMoved then
                            S.ox = target.Position.X.Offset
                            S.oy = target.Position.Y.Offset
                            saveState()
                        elseif onTap then
                            onTap()
                        end
                    end
                end
            end)
        end
    end)
    UIS.InputChanged:Connect(function(i)
        if down and (i.UserInputType == Enum.UserInputType.MouseMovement
            or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - startPosV
            if not moved and d.Magnitude > 8 then moved = true end
            if moved then
                local a = target.AbsoluteSize
                local x, y = clampXY(startPos.X.Offset + d.X, startPos.Y.Offset + d.Y, a.X, a.Y)
                target.Position = UDim2.new(startPos.X.Scale, x, startPos.Y.Scale, y)
            end
        end
    end)
end

-- กดแล้วย่อลงนิดนึงแล้วเด้งกลับ (เหมือนปุ่มใน iOS)
local function pressFx(btn, depth)
    local sc = new("UIScale", { Scale = 1 }, btn)
    local function isPtr(i)
        return i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch
    end
    btn.InputBegan:Connect(function(i)
        if isPtr(i) then tw(sc, 0.12, { Scale = depth or 0.95 }) end
    end)
    btn.InputEnded:Connect(function(i)
        if isPtr(i) then tw(sc, 0.4, { Scale = 1 }, Enum.EasingStyle.Back) end
    end)
end

-- Segmented control แบบ iOS (แถบเลื่อนลื่นๆ)
local function segmented(parent, o)
    local labels = o.labels
    local n = #labels
    local track = new("Frame", {
        AnchorPoint = o.anchor or Vector2.new(0, 0), Position = o.pos, Size = o.size,
        BackgroundColor3 = o.track or "seg", BorderSizePixel = 0,
    }, parent)
    round(track, UDim.new(0, 9))
    local inner = new("Frame", {
        Position = UDim2.fromOffset(2, 2), Size = UDim2.new(1, -4, 1, -4), BackgroundTransparency = 1,
    }, track)
    local thumb = new("Frame", {
        Size = UDim2.new(1 / n, 0, 1, 0), BackgroundColor3 = "thumb", BorderSizePixel = 0,
    }, inner)
    round(thumb, UDim.new(0, 7))
    new("UIStroke", { Color = "line", Thickness = 1, Transparency = 0.6 }, thumb)
    local btns = {}
    local api = {}
    for i, name in ipairs(labels) do
        local b = new("TextButton", {
            Text = name, Font = F.semi, TextSize = o.ts or 13, TextColor3 = "dim",
            Position = UDim2.new((i - 1) / n, 0, 0, 0), Size = UDim2.new(1 / n, 0, 1, 0),
            BackgroundTransparency = 1, BorderSizePixel = 0, AutoButtonColor = false, ZIndex = 2,
        }, inner)
        b.Activated:Connect(function()
            api.set(i, true)
            if o.onPick then o.onPick(i) end
        end)
        btns[i] = b
    end
    function api.set(i, animate)
        local pos = UDim2.new((i - 1) / n, 0, 0, 0)
        if animate then tw(thumb, 0.32, { Position = pos }) else thumb.Position = pos end
        for j, b in ipairs(btns) do
            recolor(b, "TextColor3", j == i and "text" or "dim", animate and true or false)
        end
    end
    return api
end

-- สวิตช์เปิด/ปิดแบบ iOS
local function iosSwitch(parent, pos, onTap)
    local W, H = 46, 28
    local btn = new("TextButton", {
        Text = "", AutoButtonColor = false, Position = pos, Size = UDim2.fromOffset(W, H),
        BackgroundColor3 = "swOff", BorderSizePixel = 0,
    }, parent)
    round(btn)
    local knob = new("Frame", {
        Position = UDim2.fromOffset(2, 2), Size = UDim2.fromOffset(H - 4, H - 4),
        BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0,
    }, btn)
    round(knob)
    new("UIStroke", { Color = Color3.new(0, 0, 0), Thickness = 1, Transparency = 0.9 }, knob)
    pressFx(btn, 0.94)
    local api = { on = false }
    function api.set(on, animate)
        api.on = on and true or false
        local x = on and (W - (H - 4) - 2) or 2
        local p = UDim2.fromOffset(x, 2)
        if animate then tw(knob, 0.3, { Position = p }, Enum.EasingStyle.Back) else knob.Position = p end
        recolor(btn, "BackgroundColor3", on and "ok" or "swOff", animate and true or false)
    end
    btn.Activated:Connect(function() if onTap then onTap() end end)
    return api
end

-- ปุ่มสีจางแบบ iOS (tinted)
local function tintedBtn(parent, text, key, pos, size, needConfirm, fn)
    local b = new("TextButton", {
        Text = text, Font = F.semi, TextSize = 15, TextColor3 = key, BackgroundColor3 = key,
        BackgroundTransparency = 0.84, BorderSizePixel = 0, AutoButtonColor = false,
        Position = pos, Size = size,
    }, parent)
    round(b, UDim.new(0, 12))
    pressFx(b, 0.95)
    local armed = false
    local function reset()
        armed = false
        b.Text = text
        recolor(b, "TextColor3", key)
        recolor(b, "BackgroundColor3", key)
    end
    b.Activated:Connect(function()
        if needConfirm and not armed then
            armed = true
            b.Text = "กดอีกที?"
            recolor(b, "TextColor3", "bad")
            recolor(b, "BackgroundColor3", "bad")
            task.delay(3, function() if armed then reset() end end)
            return
        end
        reset()
        pcall(fn)
    end)
    return b
end

local function buildUI()
    if genv.AA_REJOIN_GUI then pcall(function() genv.AA_REJOIN_GUI:Destroy() end) end
    UI.isDark = computeTheme()

    local gui = new("ScreenGui", {
        Name = "Rejoin_Island", ResetOnSpawn = false, DisplayOrder = 999,
        IgnoreGuiInset = true, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    })
    UI.gui = gui

    -- ตัวเกาะ
    local island = new("Frame", {
        Name = "Island", AnchorPoint = Vector2.new(0.5, 0),
        Position = UDim2.new(0.5, S.ox or 0, 0, S.oy or 14),
        Size = UDim2.fromOffset(CW, CH),
        BackgroundColor3 = "island", BorderSizePixel = 0, Active = true, ClipsDescendants = true,
    }, gui)
    local corner = new("UICorner", { CornerRadius = UDim.new(0, CH / 2) }, island)
    local rim = new("UIStroke", { Color = "line", Thickness = 1, Transparency = 0.25 }, island)
    new("UIGradient", {   -- ขอบสว่างด้านบน จางลงด้านล่าง (ลุคกระจกแบบ iOS)
        Rotation = 90,
        Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 0.65),
        }),
    }, rim)
    local scaleObj = new("UIScale", { Scale = 1 }, island)

    -- ขนาดตามหน้าจอ: แท็บเล็ต/จอใหญ่จะขยายเอง, มือถือไม่ล้นจอ, ปรับ เล็ก/กลาง/ใหญ่ ได้ในแท็บ "ธีม"
    local function calcScale()
        local vp = getVP()
        local auto = math.clamp(vp.Y / 420, 0.9, 1.6)
        local s = auto * (SIZE_MULT[S.size or 2] or 1)
        local fit = math.min((vp.Y - 16) / EH, (vp.X - 16) / EW)
        return math.max(0.55, math.min(s, fit))
    end

    local function makeDot(parent, cx, cy, d)
        local glow = new("Frame", {
            AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(cx, cy),
            Size = UDim2.fromOffset(d + 8, d + 8), BackgroundColor3 = TH.dim,
            BackgroundTransparency = 0.85, BorderSizePixel = 0,
        }, parent)
        round(glow)
        local dot = new("Frame", {
            AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(cx, cy),
            Size = UDim2.fromOffset(d, d), BackgroundColor3 = TH.dim, BorderSizePixel = 0,
        }, parent)
        round(dot)
        table.insert(UI.dots, { dot = dot, glow = glow, d = d })
        return dot
    end

    -- ---------- แบบย่อ ----------
    local compact = new("CanvasGroup", {
        Name = "Compact", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0),
        Size = UDim2.fromOffset(CW, CH), BackgroundTransparency = 1, BorderSizePixel = 0,
    }, island)
    makeDot(compact, 19, CH / 2, 10)
    local cStatus = new("TextLabel", {
        Text = "กำลังเริ่ม...", Position = UDim2.fromOffset(38, 0), Size = UDim2.new(1, -112, 1, 0),
        BackgroundTransparency = 1, Font = F.semi, TextSize = 14, TextColor3 = "text",
        TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
    }, compact)
    local cTime = new("TextLabel", {
        Text = "0:00:00", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -16, 0, 0),
        Size = UDim2.fromOffset(60, CH), BackgroundTransparency = 1, Font = F.reg,
        TextSize = 12, TextColor3 = "dim", TextXAlignment = Enum.TextXAlignment.Right,
    }, compact)

    -- ---------- แบบขยาย ----------
    local full = new("CanvasGroup", {
        Name = "Full", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0),
        Size = UDim2.fromOffset(EW, EH), BackgroundTransparency = 1, BorderSizePixel = 0,
        Visible = false, GroupTransparency = 1,
    }, island)
    local fullScale = new("UIScale", { Scale = 0.92 }, full)

    -- พื้นที่แตะ/ลากส่วนหัว (แตะ = ย่อ) วางไว้ล่างสุดให้ข้อความอยู่ข้างบน
    local hit = new("TextButton", {
        Text = "", AutoButtonColor = false, BackgroundTransparency = 1, BorderSizePixel = 0,
        Size = UDim2.new(1, -80, 0, 76),
    }, full)

    local grab = new("Frame", {   -- ที่จับด้านบนแบบ sheet ของ iOS
        AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 6), Size = UDim2.fromOffset(36, 5),
        BackgroundColor3 = "dim", BackgroundTransparency = 0.55, BorderSizePixel = 0,
    }, full)
    round(grab)
    new("TextLabel", {
        Text = "AUTO REJOIN", Position = UDim2.fromOffset(20, 14), Size = UDim2.fromOffset(140, 14),
        BackgroundTransparency = 1, Font = F.semi, TextSize = 11, TextColor3 = "dim",
        TextXAlignment = Enum.TextXAlignment.Left,
    }, full)
    makeDot(full, 26, 41, 12)
    local status = new("TextLabel", {
        Text = "กำลังเริ่ม...", Position = UDim2.fromOffset(40, 29), Size = UDim2.new(1, -116, 0, 24),
        BackgroundTransparency = 1, Font = F.bold, TextSize = 18, TextColor3 = "text",
        TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
    }, full)
    local detail = new("TextLabel", {
        Text = "", Position = UDim2.fromOffset(20, 54), Size = UDim2.new(1, -92, 0, 18),
        BackgroundTransparency = 1, Font = F.reg, TextSize = 12, TextColor3 = "dim",
        TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
    }, full)

    -- สวิตช์รีจอยอัตโนมัติ (มุมขวาบน)
    local sw = iosSwitch(full, UDim2.new(1, -66, 0, 22), function()
        if UI.act.auto then UI.act.auto() end
    end)
    new("TextLabel", {
        Text = "รีจอย", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(1, -43, 0, 52),
        Size = UDim2.fromOffset(70, 14), BackgroundTransparency = 1, Font = F.reg, TextSize = 11,
        TextColor3 = "dim",
    }, full)

    -- แท็บ (segmented control)
    local pages = {}
    local showPage
    local tabsSeg = segmented(full, {
        labels = { "ตัวละคร", "สถานะ", "Log", "ธีม" },
        pos = UDim2.fromOffset(14, 80), size = UDim2.new(1, -28, 0, 30), track = "seg", ts = 13,
        onPick = function(i)
            showPage(i, true)
            pcall(UI.refresh)
        end,
    })

    local holder = new("Frame", {
        Position = UDim2.fromOffset(14, 118), Size = UDim2.new(1, -28, 0, 188), BackgroundTransparency = 1,
    }, full)
    for i = 1, 4 do
        pages[i] = new("CanvasGroup", {
            Name = "Page" .. i, Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1,
            BorderSizePixel = 0, Visible = false,
        }, holder)
    end

    showPage = function(n, animate)
        local prev = UI.page
        UI.page = n
        tabsSeg.set(n, animate)
        for i, p in ipairs(pages) do
            if i == n then
                p.Visible = true
                if animate and prev ~= n then
                    local dir = (n > prev) and 1 or -1
                    p.Position = UDim2.fromOffset(16 * dir, 0)
                    p.GroupTransparency = 1
                    tw(p, 0.32, { Position = UDim2.fromOffset(0, 0), GroupTransparency = 0 })
                else
                    p.Position = UDim2.fromOffset(0, 0)
                    p.GroupTransparency = 0
                end
            elseif p.Visible then
                if animate then
                    tw(p, 0.15, { GroupTransparency = 1 }, Enum.EasingStyle.Quad)
                    task.delay(0.16, function() if UI.page ~= i then p.Visible = false end end)
                else
                    p.Visible = false
                end
            end
        end
    end

    local function newCard(parent, order, title, h)
        local f = new("Frame", { LayoutOrder = order, BackgroundColor3 = "card", BorderSizePixel = 0 }, parent)
        round(f, UDim.new(0, 12))
        local y0 = math.floor((h - 36) / 2)
        local t = new("TextLabel", {
            Text = title, Size = UDim2.new(1, -20, 0, 14), Position = UDim2.fromOffset(12, y0),
            BackgroundTransparency = 1, Font = F.reg, TextSize = 11, TextColor3 = "dim",
            TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
        }, f)
        local v = new("TextLabel", {
            Text = "-", Size = UDim2.new(1, -24, 0, 20), Position = UDim2.fromOffset(12, y0 + 16),
            BackgroundTransparency = 1, Font = F.bold, TextScaled = true, TextColor3 = "text",
            TextXAlignment = Enum.TextXAlignment.Left,
        }, f)
        new("UITextSizeConstraint", { MaxTextSize = 16, MinTextSize = 9 }, v)
        return t, v
    end

    -- ----- หน้า 1: ตัวละคร -----
    local p1 = pages[1]
    local avatar = new("ImageLabel", {
        Size = UDim2.fromOffset(52, 52), BackgroundColor3 = "card", BorderSizePixel = 0,
        Image = "rbxthumb://type=AvatarHeadShot&id=" .. tostring(lp.UserId) .. "&w=150&h=150",
    }, p1)
    round(avatar)
    new("UIStroke", { Color = "acc", Thickness = 2 }, avatar)
    new("TextLabel", {
        Text = lp.DisplayName, Position = UDim2.fromOffset(64, 4), Size = UDim2.new(1, -64, 0, 24),
        BackgroundTransparency = 1, Font = F.bold, TextSize = 18, TextColor3 = "text",
        TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
    }, p1)
    new("TextLabel", {
        Text = "@" .. lp.Name .. " · ID " .. tostring(lp.UserId), Position = UDim2.fromOffset(64, 29),
        Size = UDim2.new(1, -64, 0, 18), BackgroundTransparency = 1, Font = F.reg, TextSize = 12,
        TextColor3 = "dim", TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
    }, p1)

    local hpTrack = new("Frame", {
        Position = UDim2.fromOffset(0, 62), Size = UDim2.new(1, -72, 0, 8),
        BackgroundColor3 = "seg", BorderSizePixel = 0,
    }, p1)
    round(hpTrack)
    local hpFill = new("Frame", { Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = TH.ok, BorderSizePixel = 0 }, hpTrack)
    round(hpFill)
    local hpText = new("TextLabel", {
        Text = "HP -", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 56),
        Size = UDim2.fromOffset(64, 20), BackgroundTransparency = 1, Font = F.bold,
        TextSize = 13, TextColor3 = "text", TextXAlignment = Enum.TextXAlignment.Right,
    }, p1)

    local chipGrid = new("Frame", {
        Position = UDim2.fromOffset(0, 78), Size = UDim2.new(1, 0, 0, 110), BackgroundTransparency = 1,
    }, p1)
    new("UIGridLayout", {
        CellSize = UDim2.new(0.5, -3, 0, 52), CellPadding = UDim2.fromOffset(6, 6),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, chipGrid)
    UI.chips = {}
    for i = 1, 4 do
        local t, v = newCard(chipGrid, i, "-", 52)
        UI.chips[i] = { t = t, v = v }
    end

    -- ----- หน้า 2: สถานะ -----
    local p2 = pages[2]
    local grid2 = new("Frame", { Size = UDim2.new(1, 0, 0, 144), BackgroundTransparency = 1 }, p2)
    new("UIGridLayout", {
        CellSize = UDim2.new(0.5, -3, 0, 44), CellPadding = UDim2.fromOffset(6, 6),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, grid2)
    local _, sRe    = newCard(grid2, 1, "ต่อใหม่สำเร็จแล้ว", 44)
    local _, sUp    = newCard(grid2, 2, "ออนไลน์รอบนี้", 44)
    local _, sLast  = newCard(grid2, 3, "หลุดล่าสุด (ผ่านมา)", 44)
    local _, sPing  = newCard(grid2, 4, "Ping", 44)
    local _, sFps   = newCard(grid2, 5, "FPS", 44)
    local _, sPlace = newCard(grid2, 6, "รีจอยไปแมพ", 44)
    UI.sRe, UI.sUp, UI.sLast, UI.sPing, UI.sFps, UI.sPlace = sRe, sUp, sLast, sPing, sFps, sPlace
    UI.info = new("TextLabel", {
        Position = UDim2.fromOffset(2, 150), Size = UDim2.new(1, -4, 0, 38), BackgroundTransparency = 1,
        Font = F.reg, TextSize = 11, TextColor3 = "dim", TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Text = "",
    }, p2)

    -- ----- หน้า 3: Log -----
    local logBox = new("TextLabel", {
        Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = "card", BorderSizePixel = 0,
        Font = F.mono, TextSize = 11, TextColor3 = "dim", TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Bottom,
        ClipsDescendants = true, Text = "",
    }, pages[3])
    round(logBox, UDim.new(0, 12))
    new("UIPadding", {
        PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10),
        PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8),
    }, logBox)

    -- ----- หน้า 4: ธีม (เปลี่ยนโหมด สีหลัก ขนาด) -----
    local p4 = pages[4]
    local listCard = new("Frame", {
        Size = UDim2.new(1, 0, 0, 150), BackgroundColor3 = "card", BorderSizePixel = 0,
    }, p4)
    round(listCard, UDim.new(0, 12))
    local function rowLabel(y, text)
        new("TextLabel", {
            Text = text, Position = UDim2.fromOffset(14, y), Size = UDim2.fromOffset(86, 50),
            BackgroundTransparency = 1, Font = F.semi, TextSize = 14, TextColor3 = "text",
            TextXAlignment = Enum.TextXAlignment.Left,
        }, listCard)
    end
    local function hairline(y)
        new("Frame", {
            Position = UDim2.fromOffset(14, y), Size = UDim2.new(1, -14, 0, 1),
            BackgroundColor3 = "line", BackgroundTransparency = 0.3, BorderSizePixel = 0,
        }, listCard)
    end
    rowLabel(0, "ธีม");     hairline(50)
    rowLabel(50, "สีหลัก");  hairline(100)
    rowLabel(100, "ขนาด")

    local function indexOf(list, v, default)
        for i, x in ipairs(list) do if x == v then return i end end
        return default
    end

    local modeSeg = segmented(listCard, {
        labels = { "มืด", "สว่าง", "อัตโนมัติ" },
        pos = UDim2.new(1, -12, 0, 25), anchor = Vector2.new(1, 0.5), size = UDim2.fromOffset(190, 30),
        track = "segIn", ts = 12,
        onPick = function(i)
            S.mode = MODES[i]
            saveState()
            applyTheme(true)
            UI.addLog("เปลี่ยนธีม: " .. ({ "มืด", "สว่าง", "อัตโนมัติ (ตามเวลา)" })[i])
        end,
    })
    modeSeg.set(indexOf(MODES, S.mode or "dark", 1), false)

    local swHolder = new("Frame", {
        AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0, 75),
        Size = UDim2.fromOffset(196, 28), BackgroundTransparency = 1,
    }, listCard)
    local swBtns, rings = {}, {}
    local function selectAccent(idx, animate)
        for j, rs in ipairs(rings) do
            local t = (j == idx) and 0 or 1
            if animate then tw(rs, 0.25, { Transparency = t }, Enum.EasingStyle.Quad) else rs.Transparency = t end
        end
    end
    for i, a in ipairs(ACCENTS) do
        local x = (i - 1) * 28
        local ring = new("Frame", {
            Position = UDim2.fromOffset(x, 0), Size = UDim2.fromOffset(28, 28), BackgroundTransparency = 1,
        }, swHolder)
        round(ring)
        rings[i] = new("UIStroke", { Color = "text", Thickness = 2, Transparency = 1 }, ring)
        local b = new("TextButton", {
            Text = "", AutoButtonColor = false, Position = UDim2.fromOffset(x + 3, 3),
            Size = UDim2.fromOffset(22, 22), BorderSizePixel = 0,
            BackgroundColor3 = UI.isDark and a[3] or a[2],
        }, swHolder)
        round(b)
        pressFx(b, 0.85)
        b.Activated:Connect(function()
            S.accent = i
            saveState()
            selectAccent(i, true)
            applyTheme(true)
            UI.addLog("เปลี่ยนสีหลัก: " .. a[1])
        end)
        swBtns[i] = b
    end
    selectAccent(S.accent or 1, false)
    table.insert(UI.hooks, function(animated)   -- สีตัวอย่างต้องเปลี่ยนตามโหมดมืด/สว่างด้วย
        for i, a in ipairs(ACCENTS) do
            local c = UI.isDark and a[3] or a[2]
            if animated then tw(swBtns[i], 0.35, { BackgroundColor3 = c }, Enum.EasingStyle.Quad)
            else swBtns[i].BackgroundColor3 = c end
        end
    end)

    local sizeSeg = segmented(listCard, {
        labels = { "เล็ก", "กลาง", "ใหญ่" },
        pos = UDim2.new(1, -12, 0, 125), anchor = Vector2.new(1, 0.5), size = UDim2.fromOffset(150, 30),
        track = "segIn", ts = 12,
        onPick = function(i)
            S.size = i
            saveState()
            if UI.applyScale then UI.applyScale() end
            UI.addLog("ปรับขนาด: " .. ({ "เล็ก", "กลาง", "ใหญ่" })[i])
        end,
    })
    sizeSeg.set(S.size or 2, false)

    new("TextLabel", {
        Text = "อัตโนมัติ = สว่าง 06:00–18:00 ตามนาฬิกาเครื่อง · ขนาดปรับตามหน้าจอเอง (แท็บเล็ตจะใหญ่ขึ้นให้)",
        Position = UDim2.fromOffset(4, 156), Size = UDim2.new(1, -8, 0, 30), BackgroundTransparency = 1,
        Font = F.reg, TextSize = 11, TextColor3 = "dim", TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
    }, p4)

    -- ----- ปุ่มด้านล่าง -----
    local actions = new("Frame", {
        Position = UDim2.fromOffset(14, 314), Size = UDim2.new(1, -28, 0, 38), BackgroundTransparency = 1,
    }, full)
    tintedBtn(actions, "ทดสอบรีจอย", "warn", UDim2.new(0, 0, 0, 0), UDim2.new(0.5, -4, 1, 0), true,
        function() if UI.act.test then UI.act.test() end end)
    tintedBtn(actions, "คัดลอก log", "acc", UDim2.new(0.5, 4, 0, 0), UDim2.new(0.5, -4, 1, 0), false,
        function() if UI.act.copy then UI.act.copy() end end)

    -- ---------- สเกล/ตำแหน่ง ----------
    UI.applyScale = function()
        tw(scaleObj, 0.3, { Scale = calcScale() })
        local sc = calcScale()
        local w, h = (UI.expanded and EW or CW) * sc, (UI.expanded and EH or CH) * sc
        local x, y = clampXY(S.ox or 0, S.oy or 14, w, h)
        tw(island, 0.3, { Position = UDim2.new(0.5, x, 0, y) })
    end
    gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
        if UI.applyScale and not UI.entering then UI.applyScale() end
    end)

    -- ---------- ขยาย / ย่อ ----------
    local TWEEN_SIZE = TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
    local peeking = false

    local function expand()
        if UI.expanded or os.clock() - UI.lastToggle < 0.3 then return end
        UI.lastToggle = os.clock()
        UI.expanded = true
        local sc = calcScale()
        local x, y = clampXY(S.ox or 0, S.oy or 14, EW * sc, EH * sc)
        full.Visible = true
        full.GroupTransparency = 1
        fullScale.Scale = 0.9
        tw(compact, 0.12, { GroupTransparency = 1 }, Enum.EasingStyle.Quad)
        TweenService:Create(island, TWEEN_SIZE, { Size = UDim2.fromOffset(EW, EH) }):Play()
        tw(island, 0.45, { Position = UDim2.new(0.5, x, 0, y) })
        tw(corner, 0.45, { CornerRadius = UDim.new(0, 34) })
        task.delay(0.08, function()
            if UI.expanded then
                tw(full, 0.3, { GroupTransparency = 0 }, Enum.EasingStyle.Quad)
                tw(fullScale, 0.5, { Scale = 1 }, Enum.EasingStyle.Back)
                pcall(UI.refresh)
            end
        end)
        task.delay(0.14, function() if UI.expanded then compact.Visible = false end end)
    end

    local function collapse()
        if not UI.expanded or os.clock() - UI.lastToggle < 0.3 then return end
        UI.lastToggle = os.clock()
        UI.expanded = false
        local sc = calcScale()
        local x, y = clampXY(S.ox or 0, S.oy or 14, CW * sc, CH * sc)
        tw(full, 0.16, { GroupTransparency = 1 }, Enum.EasingStyle.Quad)
        tw(fullScale, 0.25, { Scale = 0.92 })
        compact.Visible = true
        tw(island, 0.42, { Size = UDim2.fromOffset(CW, CH), Position = UDim2.new(0.5, x, 0, y) })
        tw(corner, 0.35, { CornerRadius = UDim.new(0, CH / 2) })
        task.delay(0.1, function()
            if not UI.expanded then tw(compact, 0.25, { GroupTransparency = 0 }, Enum.EasingStyle.Quad) end
        end)
        task.delay(0.2, function() if not UI.expanded then full.Visible = false end end)
    end

    -- เด้งกว้างขึ้นแป๊บนึงตอนสถานะเปลี่ยน (เหมือน Live Activity)
    UI.peek = function()
        if UI.expanded or peeking then return end
        peeking = true
        tw(island, 0.3, { Size = UDim2.fromOffset(CW + 40, CH + 8) }, Enum.EasingStyle.Back)
        task.delay(1.7, function()
            if not UI.expanded then tw(island, 0.4, { Size = UDim2.fromOffset(CW, CH) }) end
            peeking = false
        end)
    end

    makeDrag(island, island, expand)
    makeDrag(hit, island, collapse)

    RunService.Heartbeat:Connect(function() FPS.frames = FPS.frames + 1 end)

    showPage(1, false)
    if not mount(gui) then gui:Destroy() error("ไม่มีที่ใส่ UI") end
    genv.AA_REJOIN_GUI = gui
    UI.island = island
    UI.status, UI.detail, UI.cStatus, UI.cTime = status, detail, cStatus, cTime
    UI.logBox = logBox
    UI.hpFill, UI.hpText = hpFill, hpText
    UI.setSwitch = function(on) sw.set(on, true) end
    sw.set(RT.auto, false)

    -- เปิดตัว: เกาะร่วงลงมาจากด้านบนแบบสปริง
    UI.entering = true
    task.delay(0.9, function()
        UI.entering = false
        if UI.applyScale and not UI.expanded then UI.applyScale() end
    end)
    local sc0 = calcScale()
    scaleObj.Scale = sc0
    local fx, fy = clampXY(S.ox or 0, S.oy or 14, CW * sc0, CH * sc0)
    island.Position = UDim2.new(0.5, fx, 0, -CH * sc0 - 12)
    compact.GroupTransparency = 1
    tw(island, 0.7, { Position = UDim2.new(0.5, fx, 0, fy) }, Enum.EasingStyle.Back)
    tw(compact, 0.45, { GroupTransparency = 0 }, Enum.EasingStyle.Quad)
end

local function tokColor(t)
    if typeof(t) == "Color3" then return t end
    return TH[t] or TH.text
end

-- ทาสีจุดสถานะ (เปลี่ยนเฉพาะตอนสีเปลี่ยนจริง)
function UI.paint(force)
    local c = tokColor(UI.color)
    if not force and UI.paintC == c then return end
    UI.paintC = c
    for _, d in ipairs(UI.dots) do
        tw(d.dot, 0.3, { BackgroundColor3 = c }, Enum.EasingStyle.Quad)
        tw(d.glow, 0.3, { BackgroundColor3 = c }, Enum.EasingStyle.Quad)
    end
end

function UI.set(text, color, det)
    if not UI.gui then return end
    local changed = (UI.lastText ~= text)
    UI.lastText = text
    UI.status.Text = text
    UI.cStatus.Text = text
    UI.color = color or "text"
    if det ~= nil then UI.detail.Text = det end
    UI.paint(false)
    if changed and UI.peek then UI.peek() end
end

function UI.addLog(msg)
    local line = "[" .. fmt(os.clock() - T0) .. "] " .. msg
    table.insert(logLines, line)
    while #logLines > 14 do table.remove(logLines, 1) end
    table.insert(allLines, line)
    while #allLines > 300 do table.remove(allLines, 1) end
    if UI.gui and UI.logBox then UI.logBox.Text = table.concat(logLines, "\n") end
end

local function refreshChar()
    local char = lp.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if hum then
        local mh = math.max(hum.MaxHealth, 1)
        local frac = math.clamp(hum.Health / mh, 0, 1)
        local tok = frac > 0.5 and "ok" or (frac > 0.25 and "warn" or "bad")
        tw(UI.hpFill, 0.4, { Size = UDim2.new(frac, 0, 1, 0), BackgroundColor3 = TH[tok] })
        UI.hpText.Text = "HP " .. math.floor(hum.Health)
    else
        tw(UI.hpFill, 0.3, { Size = UDim2.new(0, 0, 1, 0) })
        UI.hpText.Text = "HP -"
    end

    local items = {}
    local ls = lp:FindFirstChild("leaderstats")
    if ls then
        for _, v in ipairs(ls:GetChildren()) do
            if #items < 4 and v:IsA("ValueBase") then
                local val = v.Value
                if type(val) == "number" then val = commas(val) else val = tostring(val) end
                table.insert(items, { v.Name, val })
            end
        end
    end
    local extras = {
        { "อายุบัญชี", tostring(lp.AccountAge) .. " วัน" },
        { "ตำแหน่ง X, Z", hrp and (math.floor(hrp.Position.X) .. ", " .. math.floor(hrp.Position.Z)) or "-" },
        { "ความเร็วเดิน", hum and tostring(math.floor(hum.WalkSpeed)) or "-" },
        { "PlaceId", tostring(game.PlaceId) },
    }
    for _, e in ipairs(extras) do
        if #items < 4 then table.insert(items, e) end
    end
    for i = 1, 4 do
        UI.chips[i].t.Text = items[i][1]
        UI.chips[i].v.Text = items[i][2]
    end
end

local function refreshStatus()
    UI.sRe.Text = S.reconnects .. " ครั้ง"
    UI.sUp.Text = fmt(os.clock() - T0)
    UI.sLast.Text = S.lastDisc and span(os.time() - S.lastDisc) or "ยังไม่เคย"
    local ping = getPing()
    UI.sPing.Text = ping and (ping .. " ms") or "-"
    recolor(UI.sPing, "TextColor3", (not ping) and "text" or (ping < 150 and "ok" or (ping < 300 and "warn" or "bad")))
    UI.sFps.Text = tostring(FPS.value)
    local tid, how = resolveTarget()
    UI.sPlace.Text = tostring(tid)
    local mem = 0
    pcall(function() mem = math.floor(game:GetService("Stats"):GetTotalMemoryUsageMb()) end)
    UI.info.Text = "กัน AFK " .. (RT.idleHits or 0) .. " ครั้ง · ผู้เล่นในเซิร์ฟ " .. #Players:GetPlayers()
        .. " · อายุเซิร์ฟ " .. span(workspace.DistributedGameTime) .. " · RAM " .. mem .. " MB · รีจอยแบบ: " .. how
end

-- เรียกทุกวินาที: จุดสถานะกะพริบ = สคิปยังมีชีวิต
function UI.refresh()
    if not UI.gui then return end
    local now = os.clock()
    local dt = now - FPS.t
    if dt >= 0.9 then
        FPS.value = math.floor(FPS.frames / dt + 0.5)
        FPS.frames = 0
        FPS.t = now
    end
    UI.tick = not UI.tick
    if currentDark() ~= UI.isDark then applyTheme(true) end   -- โหมดอัตโนมัติ: สลับตามเวลา
    UI.paint(false)
    for _, d in ipairs(UI.dots) do
        local big = UI.tick and (d.d + 14) or (d.d + 6)
        TweenService:Create(d.glow, TweenInfo.new(0.9, Enum.EasingStyle.Sine), {
            BackgroundTransparency = UI.tick and 0.6 or 0.9,
            Size = UDim2.fromOffset(big, big),
        }):Play()
    end
    UI.cTime.Text = fmt(now - T0)
    if not UI.expanded then return end
    if UI.page == 1 then refreshChar() elseif UI.page == 2 then refreshStatus() end
end

if CFG.SHOW_UI then
    local ok, err = pcall(buildUI)
    if not ok then
        UI.gui = nil
        warn("[REJOIN] สร้าง UI ไม่สำเร็จ:", err)
    end
end

local function log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    local msg = table.concat(parts, " ")
    if CFG.DEBUG then print("[REJOIN]", msg) end
    UI.addLog(msg)
end

-- รันงานเบื้องหลัง ถ้าพังจะแจ้งใน log แล้วเริ่มใหม่เอง (กันงานหลักตายเงียบๆ ตอนหลับ)
local function guard(name, fn)
    task.spawn(function()
        while true do
            local ok, err = xpcall(fn, function(e) return tostring(e) end)
            if ok then return end
            log("ERROR", name .. ":", tostring(err):sub(1, 140))
            task.wait(5)
        end
    end)
end

UI.act.copy = function()
    local txt = table.concat(allLines, "\n")
    local fn = setclipboard or toclipboard
    if fn then
        local ok = pcall(fn, txt)
        log(ok and "คัดลอก log ทั้งหมดแล้ว (วางในแชทได้เลย)" or "คัดลอกไม่สำเร็จ")
    else
        log("executor นี้ไม่มี setclipboard คัดลอกไม่ได้")
    end
end

local function refreshAutoBtn()
    if UI.setSwitch then UI.setSwitch(RT.auto) end
end
UI.act.auto = function()
    RT.auto = not RT.auto
    S.auto = RT.auto
    saveState()
    refreshAutoBtn()
    log("รีจอยอัตโนมัติ:", RT.auto and "เปิด" or "ปิด")
    if not RT.rejoining then
        UI.set(RT.auto and "เฝ้าดูการหลุดอยู่" or "ปิดรีจอยอยู่", RT.auto and COL.ok or COL.dim, "")
    end
end
refreshAutoBtn()

-- ===================== แจ้งเตือน (ไม่บังคับ) =====================
local function notify(msg)
    if CFG.WEBHOOK == "" then return end
    local req = request or http_request or (syn and syn.request)
    if not req then return end
    task.spawn(function()
        pcall(req, {
            Url = CFG.WEBHOOK, Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = HS:JSONEncode({ content = msg }),
        })
    end)
end

-- ให้สคิปนี้รันซ้ำเองหลังทุกการวาร์ป
if queue_on_teleport then
    queue_on_teleport('loadstring(readfile("' .. FILE .. '"))()')
end

pcall(function()
    TS.TeleportInitFailed:Connect(function(_, result, msg)
        log("วาร์ปล้มเหลว:", tostring(result), tostring(msg))
    end)
end)

-- ===================== ตัวช่วยกดปุ่ม =====================
local function btnOf(o)
    while o and not o:IsA("LayerCollector") do
        if o:IsA("GuiButton") then return o end
        o = o.Parent
    end
    return nil
end

local SIGS = { "MouseButton1Down", "MouseButton1Up", "MouseButton1Click", "Activated", "TouchTap" }
local function click(btn)
    for _, name in ipairs(SIGS) do
        pcall(function()
            if firesignal then firesignal(btn[name]) end
        end)
        pcall(function()
            if getconnections then
                for _, c in ipairs(getconnections(btn[name])) do pcall(function() c:Fire() end) end
            end
        end)
    end
end

-- ปุ่มบนหน้าต่างแจ้งหลุดของ Roblox (CoreGui) เช่น Reconnect
local function findCoreButton(pats)
    local ok, b, t = pcall(function()
        local g = game:GetService("CoreGui"):FindFirstChild("RobloxPromptGui")
        if not g then return nil end
        for _, o in ipairs(g:GetDescendants()) do
            if (o:IsA("TextLabel") or o:IsA("TextButton")) and o.Text ~= "" then
                local tl = o.Text:lower()
                for _, p in ipairs(pats) do
                    if tl:find(p, 1, true) then
                        local btn = btnOf(o)
                        if btn then return btn, o.Text end
                    end
                end
            end
        end
        return nil
    end)
    if ok then return b, t end
    return nil
end

-- ===================== ตรวจว่าหลุดไหม =====================
local function disconnectInfo()
    -- 1) หน้าต่าง ErrorPrompt ของ Roblox โผล่ขึ้นมา
    local up = false
    pcall(function()
        local g = game:GetService("CoreGui"):FindFirstChild("RobloxPromptGui")
        local po = g and g:FindFirstChild("promptOverlay")
        local ep = po and po:FindFirstChild("ErrorPrompt")
        if ep and (not ep:IsA("GuiObject") or ep.Visible) then up = true end
    end)
    -- 2) ข้อความ error ของ GuiService (กรณี executor เข้า CoreGui ไม่ได้)
    local msg = ""
    pcall(function() msg = GuiService:GetErrorMessage() or "" end)
    if type(msg) ~= "string" then msg = "" end
    return (up or msg ~= ""), msg
end

-- หา "หน้าหลัก" (RootPlace) ของเกม ตอนที่เน็ตยังดีอยู่ เก็บไว้ใช้ตอนหลุด
local function fetchRoot()
    local req = request or http_request or (syn and syn.request)
    if not req then return nil, "executor ไม่มี request" end
    local ok, res = pcall(req, {
        Url = "https://games.roblox.com/v1/games?universeIds=" .. tostring(game.GameId),
        Method = "GET",
    })
    if not ok then return nil, tostring(res) end
    if type(res) ~= "table" or not res.Body then return nil, "ไม่มีข้อมูลตอบกลับ" end
    local ok2, data = pcall(function() return HS:JSONDecode(res.Body) end)
    if ok2 and type(data) == "table" and type(data.data) == "table"
        and data.data[1] and data.data[1].rootPlaceId then
        return data.data[1].rootPlaceId
    end
    return nil, "อ่านข้อมูลเกมไม่ได้"
end

-- ===================== เข้าเกมใหม่เมื่อหลุด =====================
local function reconnect(reason)
    if RT.rejoining then return end
    RT.rejoining = true
    S.disconnectAt = S.disconnectAt or os.time()
    S.lastDisc = os.time()
    pushEvent("หลุด", reason)
    log("หลุดจากเกม:", reason)
    notify("Auto Rejoin: หลุดจากเกม (" .. reason .. ") กำลังพยายามเข้าใหม่")

    -- สคิปฟาร์มที่อยากให้รันหลังรีจอย: ฝากไว้ในคิวของการวาร์ปครั้งถัดไป (ครั้งเดียวต่อการหลุด)
    if CFG.AFTER_REJOIN_FILE ~= "" and queue_on_teleport then
        queue_on_teleport('pcall(function() loadstring(readfile("' .. CFG.AFTER_REJOIN_FILE .. '"))() end)')
        log("ฝากสคิปฟาร์มไว้รันหลังรีจอย:", CFG.AFTER_REJOIN_FILE)
    end

    task.spawn(function()
        local attempt = 0
        while true do
            if not RT.auto then
                log("ปิดรีจอยอัตโนมัติ หยุดพยายามเข้าใหม่")
                UI.set("ปิดรีจอยอยู่", COL.dim, "กดปุ่มรีจอยเพื่อเปิดอีกครั้ง")
                RT.rejoining = false
                return
            end
            attempt = attempt + 1
            local target, how = resolveTarget()
            UI.set("หลุด! กำลังเข้าใหม่", COL.bad, "ครั้งที่ " .. attempt .. " · ไป " .. target .. " (" .. how .. ")")
            local ok, err

            -- ครั้งแรก: ลองกลับเซิร์ฟเดิม (ถ้าแมพเดียวกับที่อยู่)
            if CFG.TRY_SAME_SERVER and attempt == 1 and target == game.PlaceId and game.JobId ~= "" then
                ok, err = pcall(function() TS:TeleportToPlaceInstance(game.PlaceId, game.JobId, lp) end)
                log("ลองกลับเซิร์ฟเดิม:", ok and "ส่งคำสั่งแล้ว" or tostring(err))
                task.wait(15)
            end

            ok, err = pcall(function() TS:Teleport(target, lp) end)
            log("เข้าใหม่ครั้งที่", attempt, "Teleport:", ok and "ส่งคำสั่งแล้ว" or tostring(err))
            task.wait(20)

            -- วิธีสำรอง: กดปุ่ม Reconnect/Rejoin บนหน้าต่างแจ้งหลุด
            local b, bt = findCoreButton({ "reconnect", "rejoin" })
            if b then
                log("กดปุ่มหน้าต่างหลุด:", bt)
                click(b)
                task.wait(15)
            end

            local delay = math.min(CFG.RETRY_DELAY * attempt, 120)
            UI.set("ยังเข้าไม่ได้ รอลองใหม่", COL.warn, "รออีก " .. delay .. " วิ (เน็ตอาจยังไม่กลับมา)")
            task.wait(delay)
        end
    end)
end

-- ===================== เริ่มทำงาน =====================
local function main()
    log("PlaceId =", game.PlaceId, "· GameId =", game.GameId)

    -- เช็ค executor
    local caps = {
        { "writefile", writefile }, { "readfile", readfile },
        { "queue_on_teleport", queue_on_teleport },
        { "firesignal", firesignal }, { "getconnections", getconnections },
    }
    local missing = {}
    for _, c in ipairs(caps) do
        if not c[2] then table.insert(missing, c[1]) end
    end
    local hasVU = pcall(function() game:GetService("VirtualUser") end)
    if not hasVU then table.insert(missing, "VirtualUser") end
    if #missing == 0 then
        log("executor รองรับครบทุกฟังก์ชัน")
    else
        log("executor ไม่มี:", table.concat(missing, ", "))
    end

    -- ปิดสคิปตัวเก่า
    if CFG.DISABLE_OLD then
        pcall(function() if genv.AA_FS_GUI then genv.AA_FS_GUI:Destroy() end end)
        pcall(function() if genv.AA_GUARD_GUI then genv.AA_GUARD_GUI:Destroy() end end)
        for _, f in ipairs({ "aa_failsafe.lua", "aa_guard.lua" }) do
            pcall(function()
                if isfile and isfile(f) then
                    writefile(f, "-- disabled by Auto Rejoin")
                    log("ปิดสคิปเก่า:", f)
                end
            end)
        end
    end

    -- ประวัติหลุดย้อนหลัง (ตื่นมาดูได้เลย)
    local n = #S.events
    if n == 0 then
        log("ยังไม่มีประวัติหลุด")
    else
        for i = math.max(1, n - 2), n do
            local e = S.events[i]
            log("ประวัติ:", ago(e.t), e.k, e.m or "")
        end
    end

    -- จำหน้าหลักของเกมนี้ไว้ (ทำครั้งเดียวต่อเกม ตอนเน็ตยังดี)
    local gid = tostring(game.GameId)
    if CFG.USE_ROOT_PLACE and CFG.REJOIN_PLACE_ID == 0 then
        if S.roots[gid] then
            log("หน้าหลักของเกมนี้ PlaceId =", S.roots[gid])
        else
            task.spawn(function()
                local id, why = fetchRoot()
                if id then
                    S.roots[gid] = id
                    saveState()
                    log("พบหน้าหลักของเกมนี้ PlaceId =", id)
                else
                    log("หาหน้าหลักของเกมไม่ได้ จะรีจอยแมพที่อยู่แทน:", why)
                end
            end)
        end
    end

    -- เพิ่งกลับเข้าเกมได้?
    if S.disconnectAt then
        local down = os.time() - S.disconnectAt
        S.reconnects = S.reconnects + 1
        S.disconnectAt = nil
        pushEvent("เข้าใหม่", "กลับเข้าเกมได้ หลุดไป " .. span(down))
        log("กลับเข้าเกมสำเร็จ หลุดไป", span(down))
        notify("Auto Rejoin: กลับเข้าเกมได้แล้ว หลุดไป " .. span(down) .. " (รวม " .. S.reconnects .. " ครั้ง)")
        UI.set("กลับเข้าเกมสำเร็จ", COL.ok, "หลุดไป " .. span(down) .. " · เฝ้าดูต่อ")
    else
        local target, how = resolveTarget()
        UI.set(RT.auto and "เฝ้าดูการหลุดอยู่" or "ปิดรีจอยอยู่", RT.auto and COL.ok or COL.dim,
            "ถ้าหลุดจะเข้า " .. target .. " (" .. how .. ")")
    end

    UI.act.test = function()
        log("ทดสอบ: จำลองว่าหลุด (จะวาร์ปจริงตามเป้าหมายรีจอย)")
        reconnect("ทดสอบ (กดปุ่มเอง)")
    end

    -- อัปเดตข้อมูลบนเกาะทุกวินาที (ไฟกะพริบ = สคิปยังมีชีวิต)
    guard("ui", function()
        while UI.gui and UI.gui.Parent do
            pcall(UI.refresh)
            task.wait(1)
        end
    end)

    -- กันโดนเตะเพราะ AFK
    if CFG.ANTI_IDLE then
        guard("antiidle", function()
            local VU = game:GetService("VirtualUser")
            lp.Idled:Connect(function()
                pcall(function() VU:CaptureController(); VU:ClickButton2(Vector2.new(0, 0)) end)
                RT.idleHits = (RT.idleHits or 0) + 1
                log("กัน AFK (Idled)")
            end)
            while true do
                task.wait(540)
                pcall(function() VU:CaptureController(); VU:ClickButton2(Vector2.new(0, 0)) end)
                RT.idleHits = (RT.idleHits or 0) + 1
            end
        end)
    end

    -- เฝ้าดูว่าหลุดไหม
    guard("watch", function()
        local downSince = nil
        while true do
            task.wait(2)
            if RT.auto and not RT.rejoining then
                local up, msg = disconnectInfo()
                if up then
                    downSince = downSince or os.clock()
                    if os.clock() - downSince >= CFG.CONFIRM_SECONDS then
                        downSince = nil
                        if msg:lower():find("banned", 1, true) then
                            RT.rejoining = true
                            log("ดูเหมือนโดนแบน หยุดรีจอย:", msg:sub(1, 80))
                            UI.set("โดนแบน? หยุดรีจอย", COL.bad, msg:sub(1, 100))
                            pushEvent("แบน?", msg:sub(1, 80))
                        else
                            reconnect(msg ~= "" and msg:sub(1, 80) or "ไม่ทราบสาเหตุ")
                        end
                    end
                else
                    downSince = nil
                end
            end
        end
    end)
end

local ok, err = xpcall(main, function(e) return tostring(e) end)
if not ok then
    genv.AA_REJOIN_RUNNING = nil
    warn("[REJOIN] error:", err)
    UI.set("สคิปเกิดข้อผิดพลาด", COL.bad, tostring(err):sub(1, 140))
    UI.addLog("ERROR: " .. tostring(err):sub(1, 200))
end
]==]

local okW, errW = pcall(function() writefile("aa_rejoin.lua", SRC) end)
if not okW then warn("[REJOIN] เซฟไฟล์ไม่ได้ (ต่อไปจะไม่รันซ้ำเองหลังวาร์ป):", errW) end

local fn, perr = loadstring(SRC)
if not fn then
    warn("[REJOIN] โหลดสคิปไม่ได้:", perr)
    return
end
fn()
