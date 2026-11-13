-- Auto Rejoin: เน็ตหลุด / โดนเตะ / เซิร์ฟล่ม -> เข้าเกมใหม่เอง (ใช้ได้กับทุกแมพ ทุกเกม)
--   1) เฝ้าหน้าต่างแจ้งหลุดของ Roblox พอขึ้นก็สั่งเข้าเกมใหม่ ถ้าเน็ตยังไม่มาจะลองซ้ำเรื่อยๆ
--   2) กันโดนเตะเพราะ AFK 20 นาที (ปิดได้)
--   3) UI แบบ Dynamic Island: แตะเพื่อดูข้อมูล/ประวัติการหลุด ลากเพื่อย้าย
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

-- ===================== UI (Dynamic Island) =====================
local TweenService = game:GetService("TweenService")
local RunService   = game:GetService("RunService")

local COL = {
    bg    = Color3.fromRGB(0, 0, 0),
    panel = Color3.fromRGB(28, 28, 32),
    line  = Color3.fromRGB(80, 80, 90),
    text  = Color3.fromRGB(245, 245, 250),
    dim   = Color3.fromRGB(142, 142, 152),
    ok    = Color3.fromRGB(52, 211, 120),
    warn  = Color3.fromRGB(255, 190, 60),
    bad   = Color3.fromRGB(255, 84, 84),
    acc   = Color3.fromRGB(100, 140, 255),
    tab   = Color3.fromRGB(62, 62, 70),
}

local CW, CH = 270, 38    -- ขนาดตอนย่อ (เม็ดยา)
local EW, EH = 340, 364   -- ขนาดตอนขยาย
local UI = { gui = nil, color = COL.dim, act = {}, expanded = false, page = 1, tick = false }
local logLines, allLines = {}, {}
local FPS = { frames = 0, value = 0, t = os.clock() }

local function new(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props) do o[k] = v end
    o.Parent = parent
    return o
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
                target.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
                    startPos.Y.Scale, startPos.Y.Offset + d.Y)
            end
        end
    end)
end

local function buildUI()
    if genv.AA_REJOIN_GUI then pcall(function() genv.AA_REJOIN_GUI:Destroy() end) end

    local gui = new("ScreenGui", {
        Name = "Rejoin_Island", ResetOnSpawn = false, DisplayOrder = 999,
        IgnoreGuiInset = true, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    })

    -- ตัวเกาะ (ดำสนิท ขอบบางๆ เหมือน Dynamic Island)
    local island = new("Frame", {
        Name = "Island", AnchorPoint = Vector2.new(0.5, 0),
        Position = UDim2.new(0.5, S.ox or 0, 0, S.oy or 44),
        Size = UDim2.fromOffset(CW, CH),
        BackgroundColor3 = COL.bg, BorderSizePixel = 0, Active = true, ClipsDescendants = true,
    }, gui)
    local corner = new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, island)
    new("UIStroke", { Color = COL.line, Thickness = 1, Transparency = 0.5 }, island)

    -- ---------- แบบย่อ ----------
    local compact = new("Frame", { Name = "Compact", Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1 }, island)
    local glow = new("Frame", {
        Size = UDim2.fromOffset(22, 22), Position = UDim2.fromOffset(8, 8),
        BackgroundColor3 = COL.dim, BackgroundTransparency = 0.85, BorderSizePixel = 0,
    }, compact)
    new("UICorner", { CornerRadius = UDim.new(1, 0) }, glow)
    local dot = new("Frame", {
        Size = UDim2.fromOffset(10, 10), Position = UDim2.fromOffset(14, 14),
        BackgroundColor3 = COL.dim, BorderSizePixel = 0,
    }, compact)
    new("UICorner", { CornerRadius = UDim.new(1, 0) }, dot)
    local cStatus = new("TextLabel", {
        Text = "กำลังเริ่ม...", Position = UDim2.fromOffset(38, 0), Size = UDim2.new(1, -116, 1, 0),
        BackgroundTransparency = 1, Font = Enum.Font.SourceSansBold, TextSize = 17, TextColor3 = COL.text,
        TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
    }, compact)
    local cTime = new("TextLabel", {
        Text = "0:00:00", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -16, 0, 0),
        Size = UDim2.fromOffset(66, CH), BackgroundTransparency = 1, Font = Enum.Font.SourceSans,
        TextSize = 15, TextColor3 = COL.dim, TextXAlignment = Enum.TextXAlignment.Right,
    }, compact)

    -- ---------- แบบขยาย ----------
    local full = new("Frame", { Name = "Full", Size = UDim2.fromOffset(EW, EH), BackgroundTransparency = 1, Visible = false }, island)

    local head = new("Frame", { Size = UDim2.new(1, 0, 0, 58), BackgroundTransparency = 1, Active = true }, full)
    local dot2 = new("Frame", {
        Size = UDim2.fromOffset(12, 12), Position = UDim2.fromOffset(20, 15),
        BackgroundColor3 = COL.dim, BorderSizePixel = 0,
    }, head)
    new("UICorner", { CornerRadius = UDim.new(1, 0) }, dot2)
    local status = new("TextLabel", {
        Text = "กำลังเริ่ม...", Position = UDim2.fromOffset(42, 6), Size = UDim2.new(1, -100, 0, 26),
        BackgroundTransparency = 1, Font = Enum.Font.SourceSansBold, TextSize = 21, TextColor3 = COL.text,
        TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
    }, head)
    local detail = new("TextLabel", {
        Text = "", Position = UDim2.fromOffset(20, 33), Size = UDim2.new(1, -40, 0, 20),
        BackgroundTransparency = 1, Font = Enum.Font.SourceSans, TextSize = 14, TextColor3 = COL.dim,
        TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
    }, head)
    new("TextLabel", {
        Text = "แตะเพื่อย่อ", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -18, 0, 10),
        Size = UDim2.fromOffset(70, 20), BackgroundTransparency = 1, Font = Enum.Font.SourceSans,
        TextSize = 13, TextColor3 = COL.dim, TextXAlignment = Enum.TextXAlignment.Right,
    }, head)

    -- แท็บ
    local tabs = new("Frame", {
        Position = UDim2.fromOffset(12, 62), Size = UDim2.new(1, -24, 0, 28),
        BackgroundColor3 = COL.panel, BorderSizePixel = 0,
    }, full)
    new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, tabs)

    local holder = new("Frame", {
        Position = UDim2.fromOffset(12, 98), Size = UDim2.new(1, -24, 0, 206), BackgroundTransparency = 1,
    }, full)
    local pages = {}
    for i = 1, 3 do
        pages[i] = new("Frame", { Name = "Page" .. i, Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Visible = false }, holder)
    end

    local tabNames = { "ตัวละคร", "สถานะ", "Log" }
    local tabBtns = {}
    local function showPage(n)
        UI.page = n
        for i, b in ipairs(tabBtns) do
            b.BackgroundTransparency = (i == n) and 0 or 1
            b.TextColor3 = (i == n) and COL.text or COL.dim
            pages[i].Visible = (i == n)
        end
    end
    for i, name in ipairs(tabNames) do
        local b = new("TextButton", {
            Text = name, Font = Enum.Font.SourceSansBold, TextSize = 15, TextColor3 = COL.dim,
            Position = UDim2.new((i - 1) / 3, 0, 0, 0), Size = UDim2.new(1 / 3, 0, 1, 0),
            BackgroundColor3 = COL.tab, BackgroundTransparency = 1, BorderSizePixel = 0, AutoButtonColor = false,
        }, tabs)
        new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, b)
        b.Activated:Connect(function()
            showPage(i)
            pcall(UI.refresh)
        end)
        tabBtns[i] = b
    end

    local function newCard(parent, order, title)
        local f = new("Frame", { LayoutOrder = order, BackgroundColor3 = COL.panel, BorderSizePixel = 0 }, parent)
        new("UICorner", { CornerRadius = UDim.new(0, 12) }, f)
        local t = new("TextLabel", {
            Text = title, Size = UDim2.new(1, -20, 0, 16), Position = UDim2.fromOffset(10, 5),
            BackgroundTransparency = 1, Font = Enum.Font.SourceSans, TextSize = 13,
            TextColor3 = COL.dim, TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
        }, f)
        local v = new("TextLabel", {
            Text = "-", Size = UDim2.new(1, -20, 0, 22), Position = UDim2.fromOffset(10, 21),
            BackgroundTransparency = 1, Font = Enum.Font.SourceSansBold, TextScaled = true,
            TextColor3 = COL.text, TextXAlignment = Enum.TextXAlignment.Left,
        }, f)
        new("UITextSizeConstraint", { MaxTextSize = 18, MinTextSize = 10 }, v)
        return t, v
    end

    -- ----- หน้า 1: ตัวละคร -----
    local p1 = pages[1]
    local avatar = new("ImageLabel", {
        Size = UDim2.fromOffset(60, 60), BackgroundColor3 = COL.panel, BorderSizePixel = 0,
        Image = "rbxthumb://type=AvatarHeadShot&id=" .. tostring(lp.UserId) .. "&w=150&h=150",
    }, p1)
    new("UICorner", { CornerRadius = UDim.new(1, 0) }, avatar)
    new("UIStroke", { Color = COL.line, Thickness = 1.5 }, avatar)
    new("TextLabel", {
        Text = lp.DisplayName, Position = UDim2.fromOffset(72, 4), Size = UDim2.new(1, -72, 0, 28),
        BackgroundTransparency = 1, Font = Enum.Font.SourceSansBold, TextSize = 22, TextColor3 = COL.text,
        TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
    }, p1)
    new("TextLabel", {
        Text = "@" .. lp.Name .. " · ID " .. tostring(lp.UserId), Position = UDim2.fromOffset(72, 34),
        Size = UDim2.new(1, -72, 0, 20), BackgroundTransparency = 1, Font = Enum.Font.SourceSans,
        TextSize = 14, TextColor3 = COL.dim, TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, p1)

    local hpTrack = new("Frame", {
        Position = UDim2.fromOffset(0, 71), Size = UDim2.new(1, -78, 0, 10),
        BackgroundColor3 = COL.panel, BorderSizePixel = 0,
    }, p1)
    new("UICorner", { CornerRadius = UDim.new(1, 0) }, hpTrack)
    local hpFill = new("Frame", { Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = COL.ok, BorderSizePixel = 0 }, hpTrack)
    new("UICorner", { CornerRadius = UDim.new(1, 0) }, hpFill)
    local hpText = new("TextLabel", {
        Text = "HP -", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 64),
        Size = UDim2.fromOffset(72, 24), BackgroundTransparency = 1, Font = Enum.Font.SourceSansBold,
        TextSize = 15, TextColor3 = COL.text, TextXAlignment = Enum.TextXAlignment.Right,
    }, p1)

    local chipGrid = new("Frame", { Position = UDim2.fromOffset(0, 98), Size = UDim2.new(1, 0, 0, 108), BackgroundTransparency = 1 }, p1)
    new("UIGridLayout", {
        CellSize = UDim2.new(0.5, -3, 0, 51), CellPadding = UDim2.fromOffset(6, 6),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, chipGrid)
    UI.chips = {}
    for i = 1, 4 do
        local t, v = newCard(chipGrid, i, "-")
        UI.chips[i] = { t = t, v = v }
    end

    -- ----- หน้า 2: สถานะ -----
    local p2 = pages[2]
    local grid2 = new("Frame", { Size = UDim2.new(1, 0, 0, 144), BackgroundTransparency = 1 }, p2)
    new("UIGridLayout", {
        CellSize = UDim2.new(0.5, -3, 0, 44), CellPadding = UDim2.fromOffset(6, 6),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, grid2)
    local _, sRe    = newCard(grid2, 1, "ต่อใหม่สำเร็จแล้ว")
    local _, sUp    = newCard(grid2, 2, "ออนไลน์รอบนี้")
    local _, sLast  = newCard(grid2, 3, "หลุดล่าสุด (ผ่านมา)")
    local _, sPing  = newCard(grid2, 4, "Ping")
    local _, sFps   = newCard(grid2, 5, "FPS")
    local _, sPlace = newCard(grid2, 6, "รีจอยไปแมพ")
    UI.sRe, UI.sUp, UI.sLast, UI.sPing, UI.sFps, UI.sPlace = sRe, sUp, sLast, sPing, sFps, sPlace
    UI.info = new("TextLabel", {
        Position = UDim2.fromOffset(2, 152), Size = UDim2.new(1, -4, 0, 52), BackgroundTransparency = 1,
        Font = Enum.Font.SourceSans, TextSize = 14, TextColor3 = COL.dim, TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Text = "",
    }, p2)

    -- ----- หน้า 3: Log -----
    local logBox = new("TextLabel", {
        Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = COL.panel, BorderSizePixel = 0,
        Font = Enum.Font.SourceSans, TextSize = 14, TextColor3 = COL.dim, TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Bottom,
        ClipsDescendants = true, Text = "",
    }, pages[3])
    new("UICorner", { CornerRadius = UDim.new(0, 12) }, logBox)
    new("UIPadding", {
        PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10),
        PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8),
    }, logBox)

    -- ----- ปุ่มด้านล่าง -----
    local actions = new("Frame", {
        Position = UDim2.fromOffset(12, 312), Size = UDim2.new(1, -24, 0, 36), BackgroundTransparency = 1,
    }, full)
    new("UIGridLayout", {
        CellSize = UDim2.new(1 / 3, -4, 1, 0), CellPadding = UDim2.fromOffset(6, 0),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, actions)
    local function pill(order, text, color, needConfirm, fn)
        local b = new("TextButton", {
            LayoutOrder = order, Text = text, Font = Enum.Font.SourceSansBold, TextScaled = true,
            TextColor3 = COL.text, BackgroundColor3 = color, BorderSizePixel = 0,
        }, actions)
        new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, b)
        new("UITextSizeConstraint", { MaxTextSize = 16, MinTextSize = 9 }, b)
        new("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }, b)
        local armed = false
        b.Activated:Connect(function()
            if needConfirm and not armed then
                armed = true
                b.Text = "กดอีกที?"
                task.delay(3, function() armed = false; b.Text = text end)
                return
            end
            armed = false
            b.Text = text
            pcall(fn)
        end)
        return b
    end
    UI.btnAuto = pill(1, "รีจอย", COL.ok, false, function() if UI.act.auto then UI.act.auto() end end)
    pill(2, "ทดสอบรีจอย", Color3.fromRGB(170, 100, 40), true, function() if UI.act.test then UI.act.test() end end)
    pill(3, "คัดลอก log", Color3.fromRGB(60, 80, 170), false, function() if UI.act.copy then UI.act.copy() end end)

    -- ---------- ขยาย / ย่อ ----------
    local TWEEN_IN  = TweenInfo.new(0.40, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
    local TWEEN_OUT = TweenInfo.new(0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
    local peeking = false

    local function expand()
        if UI.expanded then return end
        UI.expanded = true
        compact.Visible = false
        TweenService:Create(island, TWEEN_IN, { Size = UDim2.fromOffset(EW, EH) }):Play()
        TweenService:Create(corner, TWEEN_IN, { CornerRadius = UDim.new(0, 30) }):Play()
        task.delay(0.12, function()
            if UI.expanded then full.Visible = true; pcall(UI.refresh) end
        end)
    end
    local function collapse()
        if not UI.expanded then return end
        UI.expanded = false
        full.Visible = false
        TweenService:Create(island, TWEEN_OUT, { Size = UDim2.fromOffset(CW, CH) }):Play()
        TweenService:Create(corner, TWEEN_OUT, { CornerRadius = UDim.new(0.5, 0) }):Play()
        task.delay(0.18, function()
            if not UI.expanded then compact.Visible = true end
        end)
    end

    -- เด้งกว้างขึ้นแป๊บนึงตอนสถานะเปลี่ยน (เหมือน Live Activity)
    UI.peek = function()
        if UI.expanded or peeking then return end
        peeking = true
        TweenService:Create(island, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
            { Size = UDim2.fromOffset(CW + 44, CH + 8) }):Play()
        task.delay(1.6, function()
            if not UI.expanded then
                TweenService:Create(island, TWEEN_OUT, { Size = UDim2.fromOffset(CW, CH) }):Play()
            end
            peeking = false
        end)
    end

    makeDrag(island, island, function() if not UI.expanded then expand() end end)
    makeDrag(head, island, collapse)

    RunService.Heartbeat:Connect(function() FPS.frames = FPS.frames + 1 end)

    showPage(1)
    if not mount(gui) then gui:Destroy() error("ไม่มีที่ใส่ UI") end
    genv.AA_REJOIN_GUI = gui
    UI.gui, UI.island = gui, island
    UI.status, UI.detail, UI.cStatus, UI.cTime = status, detail, cStatus, cTime
    UI.dot, UI.dot2, UI.glow, UI.logBox = dot, dot2, glow, logBox
    UI.hpFill, UI.hpText = hpFill, hpText
end

function UI.set(text, color, det)
    if not UI.gui then return end
    local changed = (UI.lastText ~= text)
    UI.lastText = text
    UI.status.Text = text
    UI.cStatus.Text = text
    UI.color = color or COL.text
    if det ~= nil then UI.detail.Text = det end
    if changed and UI.peek then UI.peek() end
end

function UI.addLog(msg)
    local line = "[" .. fmt(os.clock() - T0) .. "] " .. msg
    table.insert(logLines, line)
    while #logLines > 14 do table.remove(logLines, 1) end
    table.insert(allLines, line)
    while #allLines > 300 do table.remove(allLines, 1) end
    if UI.gui then UI.logBox.Text = table.concat(logLines, "\n") end
end

local function refreshChar()
    local char = lp.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if hum then
        local mh = math.max(hum.MaxHealth, 1)
        local frac = math.clamp(hum.Health / mh, 0, 1)
        UI.hpFill.Size = UDim2.new(frac, 0, 1, 0)
        UI.hpFill.BackgroundColor3 = frac > 0.5 and COL.ok or (frac > 0.25 and COL.warn or COL.bad)
        UI.hpText.Text = "HP " .. math.floor(hum.Health)
    else
        UI.hpFill.Size = UDim2.new(0, 0, 1, 0)
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
    UI.sPing.TextColor3 = (not ping) and COL.text or (ping < 150 and COL.ok or (ping < 300 and COL.warn or COL.bad))
    UI.sFps.Text = tostring(FPS.value)
    local tid, how = resolveTarget()
    UI.sPlace.Text = tostring(tid)
    local mem = 0
    pcall(function() mem = math.floor(game:GetService("Stats"):GetTotalMemoryUsageMb()) end)
    UI.info.Text = "กัน AFK " .. (RT.idleHits or 0) .. " ครั้ง · ผู้เล่นในเซิร์ฟ " .. #Players:GetPlayers()
        .. " · อายุเซิร์ฟ " .. span(workspace.DistributedGameTime) .. " · RAM " .. mem .. " MB · รีจอยแบบ: " .. how
end

-- เรียกทุกวินาที: ไฟกะพริบ = สคิปยังมีชีวิต
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
    UI.dot.BackgroundColor3 = UI.color
    UI.dot2.BackgroundColor3 = UI.color
    UI.glow.BackgroundColor3 = UI.color
    TweenService:Create(UI.glow, TweenInfo.new(0.9, Enum.EasingStyle.Sine),
        { BackgroundTransparency = UI.tick and 0.55 or 0.9 }):Play()
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
    if UI.btnAuto then
        UI.btnAuto.Text = RT.auto and "รีจอย: เปิด" or "รีจอย: ปิด"
        UI.btnAuto.BackgroundColor3 = RT.auto and COL.ok or Color3.fromRGB(70, 74, 92)
    end
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
