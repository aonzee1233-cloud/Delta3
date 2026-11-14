-- v4: ระบบกันหลุดฉลาดขึ้น
--   · ตรวจหลุดหลายสัญญาณ: เช็คว่า "ยังเชื่อมเซิร์ฟอยู่จริงไหม" -> ข้ามหน้าต่างวาร์ปล้มเหลวที่ไม่ใช่การหลุด · จับหลุดเงียบที่ไม่มีหน้าต่างแจ้ง · ไม่ยุ่งตอนเกมวาร์ปเอง
--   · อ่านผลวาร์ปล้มเหลวจริง (เต็ม/ปิด/ถี่เกิน/ไม่มีสิทธิ์) แล้วเลือกทางต่อเอง · จำเซิร์ฟที่เข้าไม่ได้ · เรียงวิธีเข้าตามที่เคยสำเร็จบ่อย
--   · หาเซิร์ฟว่างดีขึ้น (ดึงหลายหน้า ตัดเซิร์ฟแลค/ใกล้เต็ม รู้จักโดนลิมิต 429) · พักก่อนลองใหม่แบบสุ่มเวลาเล็กน้อย (หลายบัญชีไม่แห่พร้อมกัน)
--   · กัน AFK ปรับระดับเองถ้ายังโดนเตะ · ติดลูปพักนานขึ้นเรื่อยๆ · หยุดเองถ้าโดนเตะเชิงโกง · webhook ส่งซ้ำเมื่อเน็ตกลับ · กันค้างโหลด
-- v3: แก้ "หลุดในแมตช์แล้วไม่รีจอย" -> ในแมตช์/เซิร์ฟส่วนตัวจะกดปุ่ม Reconnect ของ Roblox ก่อน (รู้จักตัวหนังสือไทย/อังกฤษ) แล้วค่อยวาร์ปไปล็อบบี้
-- Auto Rejoin v2 (เบา ไม่เกะกะ): เน็ตหลุด / โดนเตะ / เซิร์ฟล่ม -> เข้าเกมใหม่เอง (ใช้ได้กับทุกแมพ ทุกเกม)
--   1) เฝ้าหน้าต่างแจ้งหลุดของ Roblox แล้วแยกสาเหตุ (เน็ต / เซิร์ฟปิด / โดนเตะ / บัญชีเข้าซ้ำ / แบน) ตัดสินใจเอง
--   2) รอเน็ตกลับก่อนค่อยสั่งเข้า · หาเซิร์ฟสาธารณะที่ยังว่างถ้าเซิร์ฟเดิมเข้าไม่ได้ · จับเกมค้าง · กันวนลูป
--   3) กันโดนเตะเพราะ AFK 20 นาที (ปิดได้)
--   4) UI เม็ดยาเล็กที่มุมจอ: แตะเพื่อดูสถานะ ลากเพื่อย้าย จางลงเองตอนไม่ได้ใช้ · ปุ่ม "ตั้งค่า" เปลี่ยนธีม/ขนาด/การจาง
-- ไม่มีลูปเข้าโหมด/เข้าด่านอะไรทั้งนั้น ทำแค่พากลับเข้าเกม
-- วางทั้งไฟล์ใน executor แล้วรันครั้งเดียว มันจะเซฟตัวเองเป็น aa_rejoin.lua ใน workspace
-- แล้วรันซ้ำเองหลังวาร์ปทุกครั้ง (queue_on_teleport)
-- แนะนำ: ก๊อป aa_rejoin.lua ไปไว้ในโฟลเดอร์ autoexec ของ executor ด้วย (ถ้ามี)

local SRC = [==[
local CFG = {
    -- เข้าเกมใหม่ที่ไหน:
    --   0 = อัตโนมัติ (หน้าหลักของเกมนั้นถ้าหาได้ ไม่งั้นแมพที่อยู่ตอนหลุด)
    --   ใส่ PlaceId เอง = บังคับเข้าแมพนั้นทุกครั้ง
    REJOIN_PLACE_ID   = 0,
    USE_ROOT_PLACE    = true,  -- โหมดอัตโนมัติ: ใช้หน้าหลักของเกม (เช่น ล็อบบี้) แทนแมพที่หลุด
    TRY_SAME_SERVER   = true,  -- ครั้งแรกลองกลับเซิร์ฟเดิม (ไม่ได้ค่อยเข้าใหม่) ข้ามเองถ้าเซิร์ฟปิดแล้ว
    FIND_OPEN_SERVER  = true,  -- ถ้าเข้าไม่ได้ ลองหาเซิร์ฟสาธารณะที่ยังไม่เต็มแล้วเข้าตรงๆ
    CONFIRM_SECONDS   = 4,     -- หน้าต่างหลุดต้องค้างกี่วินาทีถึงจะเริ่มรีจอย (กันเด้งผิด)
    RETRY_DELAY       = 15,    -- พักระหว่างพยายามเข้าใหม่ (เพิ่มทีละเท่านี้ สูงสุด 120 วิ)
    ONLINE_WAIT       = 180,   -- รอเน็ตกลับสูงสุดกี่วินาทีก่อนสั่งเข้า (เกินแล้วลองสั่งเข้าเลย)
    STUCK_SECONDS     = 60,    -- สั่งวาร์ปแล้วยังไม่ไปภายในกี่วินาที ถือว่าค้าง ลองวิธีถัดไป
    CLICK_RECONNECT   = true,  -- ในแมตช์/เซิร์ฟส่วนตัว: กดปุ่ม Reconnect ของ Roblox ก่อน (เหมือนที่เรากดเอง) ไม่พาเข้าค่อยวาร์ปไปล็อบบี้
    RECONNECT_WAIT    = 45,    -- กดปุ่มแล้วรอกี่วินาทีว่าเกมพากลับเข้าเอง (โหลดแมตช์ในมือถือ/อีมูช้า ไม่ควรตั้งต่ำกว่า 30)
    NO_CHAR_SECONDS   = 240,   -- ไม่มีตัวละครนานเกินนี้ถือว่าเกมค้าง รีจอย (ตั้ง 0 = ปิด ใช้กับเกมที่ไม่มีตัวละคร)
    LOOP_LIMIT        = 5,     -- หลุดกี่ครั้งภายใน LOOP_WINDOW ถึงถือว่า "ติดลูป"
    LOOP_WINDOW       = 600,
    LOOP_COOLDOWN     = 300,   -- ติดลูปแล้วพักกี่วินาทีก่อนลองใหม่
    RAM_LIMIT_MB      = 0,     -- RAM สูงเกินค่านี้ (MB) นาน ~1.5 นาที ให้รีจอยก่อนเกมแครช (0 = ปิด เช่น มือถือลอง 2500)
    RAM_MIN_UPTIME    = 600,   -- ต้องอยู่ในเซิร์ฟมาแล้วอย่างน้อยกี่วินาทีถึงรีจอยเพราะ RAM (กันวนลูป)
    ANTI_IDLE         = true,  -- กันโดนเตะเพราะ AFK
    IDLE_LEVEL        = 0,     -- ระดับกัน AFK: 0 = ปรับเอง (เริ่ม 1 แล้วเพิ่มถ้ายังโดนเตะ AFK) · 1-3 = บังคับระดับ (สูง = ถี่ขึ้น/วิธีเยอะขึ้น)
    SMART_DETECT      = true,  -- ตรวจหลุดหลายสัญญาณ: ดูว่ายังเชื่อมเซิร์ฟอยู่จริงไหมก่อนตัดสิน (false = ทำงานแบบ v3)
    SILENT_SECONDS    = 15,    -- หลุดจากเซิร์ฟจริงแต่ไม่มีหน้าต่างแจ้ง นานกี่วินาทีถึงรีจอย (0 = ปิด)
    LOAD_TIMEOUT      = 240,   -- เกมโหลดไม่เสร็จนานกี่วินาทีถือว่าค้าง สั่งเข้าใหม่ (0 = ปิด)
    LEARN_METHODS     = true,  -- จำว่าวิธีเข้าแบบไหน (เซิร์ฟเดิม/ว่าง/สุ่ม) สำเร็จบ่อย แล้วลองวิธีนั้นก่อน
    BAD_SERVER_TTL    = 1800,  -- เซิร์ฟที่เข้าไม่ได้ (เต็ม/ปิด/ค้าง) จำไว้กี่วินาที ไม่เลือกซ้ำ
    LOOP_BACKOFF      = true,  -- ติดลูปซ้ำๆ พักนานขึ้นเรื่อยๆ (สูงสุด 30 นาที)
    HALT_ON_SUSPECT   = true,  -- ข้อความเตะมีคำเชิงโกง/ผิดกติกา -> หยุดรีจอย (กันบัญชีโดนซ้ำ) แตะสวิตช์เพื่อเริ่มใหม่
    AFTER_REJOIN_FILE = "",    -- ชื่อไฟล์สคิปฟาร์มใน workspace ที่อยากให้รันหลังรีจอย (เว้นว่างถ้าอยู่ใน autoexec แล้ว)
    WEBHOOK           = "",    -- ลิงก์ Discord webhook (แจ้งเฉพาะ หลุด / กลับมาได้ / ติดลูป / หยุดรีจอย) เว้นว่าง = ไม่ใช้
    WEBHOOK_TAG       = true,  -- ใส่ชื่อบัญชีนำหน้าข้อความ webhook (ช่วยตอนรันหลายบัญชี)
    DISABLE_OLD       = true,  -- ปิดสคิปเก่า (aa_failsafe / aa_guard) ไม่ให้รันซ้ำหลังวาร์ป
    DEBUG             = true,
    SHOW_UI           = true,
}

local FILE        = "aa_rejoin.lua"
local STATE_FILE  = "aa_rejoin_state.json"

local Players      = game:GetService("Players")
local TS           = game:GetService("TeleportService")
local HS           = game:GetService("HttpService")
local UIS          = game:GetService("UserInputService")
local GuiService   = game:GetService("GuiService")
local TweenService = game:GetService("TweenService")
local RunService   = game:GetService("RunService")
local lp = Players.LocalPlayer
-- กันค้างโหลด: ถ้า executor รันสคริปต์ก่อนเกมโหลดเสร็จ แล้วเกมค้างหน้าโหลดนานเกิน LOAD_TIMEOUT ให้สั่งเข้าใหม่เอง
if not game:IsLoaded() then
    if (CFG.LOAD_TIMEOUT or 0) > 0 then
        task.spawn(function()
            local t0 = os.clock()
            while not game:IsLoaded() do
                task.wait(5)
                if not game:IsLoaded() and os.clock() - t0 >= CFG.LOAD_TIMEOUT then
                    t0 = os.clock()
                    local target = game.PlaceId
                    if CFG.REJOIN_PLACE_ID ~= 0 then
                        target = CFG.REJOIN_PLACE_ID
                    elseif CFG.USE_ROOT_PLACE then
                        pcall(function()
                            local r = HS:JSONDecode(readfile(STATE_FILE)).roots[tostring(game.GameId)]
                            if type(r) == "number" then target = r end
                        end)
                    end
                    warn("[REJOIN] ค้างโหลดเกินกำหนด สั่งเข้าใหม่ PlaceId =", target)
                    pcall(function() TS:Teleport(target, lp) end)
                end
            end
        end)
    end
    game.Loaded:Wait()
end

local genv = (getgenv and getgenv()) or _G
-- กันรันซ้ำ "ในเซิร์ฟเดียวกัน" (ผูกกับ JobId) เพื่อให้ executor ที่เก็บ getgenv ข้ามการวาร์ป ยังรันรอบใหม่ได้หลังรีจอย
local SESSION = (game.JobId ~= "" and game.JobId or "x") .. ":" .. tostring(game.PlaceId)
local prevRun = genv.AA_REJOIN_RUNNING
if prevRun == SESSION then return end
genv.AA_REJOIN_RUNNING = SESSION
local LEGACY = (prevRun == true)   -- ค่าที่รุ่นเก่า (v3) ทิ้งไว้

local T0 = os.clock()
local function fmt(sec)
    sec = math.max(0, math.floor(sec))
    return string.format("%d:%02d:%02d", math.floor(sec / 3600), math.floor((sec % 3600) / 60), sec % 60)
end
local function fmtHM(sec)
    sec = math.max(0, math.floor(sec))
    return string.format("%d:%02d", math.floor(sec / 3600), math.floor((sec % 3600) / 60))
end
local function span(d)
    d = math.max(0, math.floor(d))
    if d < 60 then return d .. " วิ" end
    if d < 3600 then return math.floor(d / 60) .. " นาที" end
    return math.floor(d / 3600) .. " ชม. " .. math.floor((d % 3600) / 60) .. " น."
end

local function reqFn() return request or http_request or (syn and syn.request) end

-- ===================== สถานะที่เก็บข้ามการวาร์ป =====================
local function loadState()
    local ok, d = pcall(function() return HS:JSONDecode(readfile(STATE_FILE)) end)
    if ok and type(d) == "table" then return d end
    return {}
end
local S = loadState()
S.reconnects = S.reconnects or 0
S.drops = S.drops or 0
S.events = S.events or {}
S.roots = S.roots or {}
S.recent = S.recent or {}
S.recentK = S.recentK or {}      -- สาเหตุของแต่ละครั้งใน S.recent (เรียงตรงกัน)
while #S.recentK < #S.recent do table.insert(S.recentK, 1, "?") end
while #S.recentK > #S.recent do table.remove(S.recentK, 1) end
S.bad = S.bad or {}              -- เซิร์ฟที่เข้าไม่ได้ -> เวลาหมดอายุ
S.badTarget = S.badTarget or {}  -- PlaceId เป้าหมายที่เข้าไม่ได้ -> เวลาที่จด
S.mstat = S.mstat or {}          -- สถิติวิธีเข้าเกม (same/open/any)
S.outbox = S.outbox or {}        -- ข้อความ webhook ที่ยังส่งไม่สำเร็จ
S.loopStreak = S.loopStreak or 0
S.idleLevel = S.idleLevel or 1
if S.auto == nil then S.auto = true end
local function saveState()
    pcall(function() writefile(STATE_FILE, HS:JSONEncode(S)) end)
end
local function pushEvent(kind, msg)
    table.insert(S.events, { t = os.time(), k = kind, m = msg })
    while #S.events > 30 do table.remove(S.events, 1) end
    saveState()
end
-- นับจำนวนครั้งที่หลุดภายในช่วง LOOP_WINDOW (ล้างอันเก่าทิ้งด้วย)
local function recentCount()
    local now, keep, keepK = os.time(), {}, {}
    for i, t in ipairs(S.recent) do
        if now - t <= CFG.LOOP_WINDOW then
            keep[#keep + 1] = t
            keepK[#keepK + 1] = S.recentK[i] or "?"
        end
    end
    S.recent, S.recentK = keep, keepK
    return #keep
end

-- ตัวแปรขณะรัน
local RT = { auto = S.auto, rejoining = false, idleHits = 0, halted = nil, tpFailed = false }

-- จะรีจอยไปแมพไหน (ตัดสินตอนหลุดจริง จึงอ่านจากค่าที่เก็บไว้ ไม่ต้องใช้เน็ต)
local function resolveTarget()
    -- เป้าหมายที่เพิ่งเข้าไม่ได้ (ไม่มีสิทธิ์/ไม่เจอแมพ) ภายใน 1 ชม. -> ข้ามไปใช้แมพที่อยู่แทน
    local function bad(id)
        local ts = S.badTarget[tostring(id)]
        return ts ~= nil and os.time() - ts < 3600
    end
    if type(CFG.REJOIN_PLACE_ID) == "number" and CFG.REJOIN_PLACE_ID ~= 0 and not bad(CFG.REJOIN_PLACE_ID) then
        return CFG.REJOIN_PLACE_ID, "ตั้งเอง"
    end
    if CFG.USE_ROOT_PLACE and CFG.REJOIN_PLACE_ID == 0 then
        local r = S.roots[tostring(game.GameId)]
        if r and not bad(r) then return r, "หน้าหลักเกม" end
    end
    return game.PlaceId, "แมพปัจจุบัน"
end

-- ===================== แยกสาเหตุที่หลุด =====================
-- ตัดสินจากข้อความ + เลข Error Code ในข้อความ (ถ้าไม่ตรงอะไรเลย = ไม่ทราบสาเหตุ แล้วรีจอยตามปกติ)
-- stop = true  -> หยุดรีจอย (เข้าซ้ำ/แบน ถ้ารีจอยต่อจะวนแย่งกันหรือโดนซ้ำ)
-- nosame = true -> เซิร์ฟเดิมน่าจะปิดไปแล้ว ไม่ต้องลองกลับเซิร์ฟเดิม
-- คำในข้อความเตะที่บ่งว่าโดนจับเรื่องโกง/ผิดกติกา (ใช้กับ HALT_ON_SUSPECT)
local SUSPECT = { "exploit", "cheat", "hack", "suspicious", "violat", "unfair", "anti-cheat", "anticheat", "โกง", "ผิดกติกา", "น่าสงสัย" }

local function classify(msg)
    msg = msg or ""
    local l = msg:lower()
    local code = tonumber(l:match("code:?%s*(%d+)")) or tonumber(l:match("(%d%d%d)%)?%s*$"))
    local function has(...)
        for _, p in ipairs({ ... }) do
            if l:find(p, 1, true) then return true end
        end
        return false
    end
    local function codeIn(...)
        for _, c in ipairs({ ... }) do
            if code == c then return true end
        end
        return false
    end
    local r
    if has("banned") or msg:find("แบน", 1, true) then
        r = { k = "ban", label = "โดนแบน?", stop = true }
    elseif codeIn(264, 273) or has("different device", "same account") then
        r = { k = "dup", label = "บัญชีเข้าซ้ำ", stop = true }
    elseif codeIn(278) or has("idle") then
        r = { k = "idle", label = "AFK โดนเตะ" }
    elseif codeIn(267, 268) or has("kick") then
        r = { k = "kick", label = "โดนเตะ" }
        if CFG.HALT_ON_SUSPECT and has(table.unpack(SUSPECT)) then
            r.stop, r.label = true, "โดนเตะ (เชิงโกง?)"
        end
    elseif codeIn(772) or has("is full") then
        r = { k = "full", label = "เซิร์ฟเต็ม", nosame = true }
    elseif codeIn(274, 275, 771) or has("shut down", "shutdown", "maintenance") then
        r = { k = "server", label = "เซิร์ฟปิด/ล่ม", nosame = true }
    elseif has("memory") then
        r = { k = "mem", label = "RAM เต็ม" }
    elseif codeIn(260, 261, 262, 263, 266, 277, 279, 280, 17) or has("connection", "internet", "network", "timeout", "timed out") then
        r = { k = "net", label = "เน็ตหลุด" }
    else
        r = { k = "unknown", label = "ไม่ทราบสาเหตุ" }
    end
    r.code = code
    r.msg = msg
    -- รหัส 5xx-7xx = เข้าเกม/วาร์ปล้มเหลว (ไม่ได้ทำให้หลุดจากเซิร์ฟที่อยู่เสมอไป)
    r.soft = (code ~= nil and code >= 512 and code < 800) or has("teleport")
    return r
end
local function mkInfo(k, label) return { k = k, label = label, msg = "" } end
local function whyText(info)
    return info.label .. (info.code and (" (" .. info.code .. ")") or "")
end

-- ===================== UI (เม็ดยาเล็ก สไตล์ iOS) =====================
-- ฟอนต์: Gotham ใกล้ SF Pro ที่สุดใน Roblox (ถ้าตัวอักษรไทยดูแปลก เปลี่ยนตรงนี้ที่เดียวได้)
local F = {
    reg  = Enum.Font.GothamMedium,
    semi = Enum.Font.GothamSemibold,
    bold = Enum.Font.GothamBold,
}

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
local ACC_LIGHT, ACC_DARK = Color3.fromRGB(0, 122, 255), Color3.fromRGB(10, 132, 255)
local MODES     = { "dark", "light", "auto" }
local SIZE_MULT = { 0.85, 1, 1.2 }

-- ชื่อสีสำหรับส่งเข้า UI.set (ค่าสีจริงเปลี่ยนตามธีมเอง)
local COL = { ok = "ok", warn = "warn", bad = "bad", dim = "dim", text = "text", acc = "acc" }

local CW, CH = 88, 22     -- ตอนย่อ (เม็ดยา)
local PW     = 208        -- ตอนเด้งบอกสถานะ (กว้างขึ้นชั่วคราว)
local EW, EH = 272, 192   -- ตอนขยาย (ขนาดออกแบบ ก่อนคูณสเกลตามหน้าจอ)
local UI = {
    gui = nil, color = "dim", act = {}, expanded = false, tick = false,
    dots = {}, hooks = {}, lastToggle = 0, isDark = true,
    dimmed = false, lastActive = os.clock(), curW = CW, curH = CH,
}
local allLines = {}
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
    TH.acc = dark and ACC_DARK or ACC_LIGHT
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

local function getPing()
    local ok, v = pcall(function()
        return game:GetService("Stats").Network.ServerStatsItem["Data Ping"]:GetValue()
    end)
    if ok and type(v) == "number" then return math.floor(v) end
    return nil
end

-- ขนาดหน้าจอ
local function getVP()
    local v = UI.gui and UI.gui.AbsoluteSize or Vector2.new(0, 0)
    if v.X < 50 or v.Y < 50 then
        local cam = workspace.CurrentCamera
        v = cam and cam.ViewportSize or Vector2.new(1280, 720)
    end
    return v
end

local function isPointer(i)
    return i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch
end

-- ลาก = ย้าย / แตะ = onTap (ตำแหน่งเป็นพิกเซลจริงของหน้าจอ จุดยึดมุมซ้ายบน)
local function makeDrag(handle, target, onTap)
    local down, moved, startPosV, startXY = false, false, nil, nil
    handle.InputBegan:Connect(function(i)
        if isPointer(i) then
            down, moved = true, false
            startPosV = i.Position
            startXY = Vector2.new(target.Position.X.Offset, target.Position.Y.Offset)
            if UI.wake then UI.wake() end
            i.Changed:Connect(function()
                if i.UserInputState == Enum.UserInputState.End then
                    local wasDown, wasMoved = down, moved
                    down = false
                    if wasDown then
                        if wasMoved then
                            if UI.savePos then UI.savePos(target) end
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
                local vp = getVP()
                local x = math.clamp(startXY.X + d.X, 0, math.max(0, vp.X - a.X))
                local y = math.clamp(startXY.Y + d.Y, 0, math.max(0, vp.Y - a.Y))
                target.Position = UDim2.fromOffset(x, y)
            end
        end
    end)
end

-- กดแล้วย่อลงนิดนึงแล้วเด้งกลับ (เหมือนปุ่มใน iOS)
local function pressFx(btn, depth)
    local sc = new("UIScale", { Scale = 1 }, btn)
    btn.InputBegan:Connect(function(i)
        if isPointer(i) then tw(sc, 0.12, { Scale = depth or 0.95 }) end
    end)
    btn.InputEnded:Connect(function(i)
        if isPointer(i) then tw(sc, 0.4, { Scale = 1 }, Enum.EasingStyle.Back) end
    end)
end

-- Segmented control แบบ iOS
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
    local W, H = 40, 24
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

-- ปุ่มสีจางแบบ iOS (tinted) คืนค่า: ปุ่ม, ฟังก์ชันโชว์ข้อความชั่วคราว
local function tintedBtn(parent, text, key, pos, size, needConfirm, fn)
    local b = new("TextButton", {
        Text = text, Font = F.semi, TextSize = 13, TextColor3 = key, BackgroundColor3 = key,
        BackgroundTransparency = 0.84, BorderSizePixel = 0, AutoButtonColor = false,
        Position = pos, Size = size,
    }, parent)
    round(b, UDim.new(0, 10))
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
    local function flash(txt)
        b.Text = txt
        task.delay(1.6, function() if not armed then b.Text = text end end)
    end
    return b, flash
end

local function indexOf(list, v, default)
    for i, x in ipairs(list) do if x == v then return i end end
    return default
end

local hbConn
local function fpsOn()
    if hbConn then return end
    FPS.frames = 0
    FPS.t = os.clock()
    hbConn = RunService.Heartbeat:Connect(function() FPS.frames = FPS.frames + 1 end)
end
local function fpsOff()
    if hbConn then hbConn:Disconnect() hbConn = nil end
end

local function buildUI()
    if genv.AA_REJOIN_GUI then pcall(function() genv.AA_REJOIN_GUI:Destroy() end) end
    UI.isDark = computeTheme()

    local gui = new("ScreenGui", {
        Name = "Rejoin_Island", ResetOnSpawn = false, DisplayOrder = 999,
        IgnoreGuiInset = true, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    })
    UI.gui = gui

    -- ตัวเกาะ (จุดยึดมุมซ้ายบน ตำแหน่งเป็นพิกเซลจริง จำเป็นขอบซ้าย/ขวา + ระยะห่างไว้ใน S)
    local island = new("Frame", {
        Name = "Island", AnchorPoint = Vector2.new(0, 0), Position = UDim2.fromOffset(0, 0),
        Size = UDim2.fromOffset(CW, CH), BackgroundColor3 = "island", BorderSizePixel = 0,
        Active = true, ClipsDescendants = true,
    }, gui)
    local corner = new("UICorner", { CornerRadius = UDim.new(0, CH / 2) }, island)
    local rim = new("UIStroke", { Color = "line", Thickness = 1, Transparency = 0.25 }, island)
    new("UIGradient", {
        Rotation = 90,
        Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 0.65),
        }),
    }, rim)
    local scaleObj = new("UIScale", { Scale = 1 }, island)

    -- ขนาดตามหน้าจอ: แท็บเล็ต/จอใหญ่ขยายเอง, มือถือไม่ล้นจอ, ปรับ เล็ก/กลาง/ใหญ่ ได้ในตั้งค่า
    local function calcScale()
        local vp = getVP()
        local auto = math.clamp(vp.Y / 420, 0.9, 1.6)
        local s = auto * (SIZE_MULT[S.size or 2] or 1)
        local fit = math.min((vp.Y - 16) / EH, (vp.X - 16) / EW)
        return math.max(0.55, math.min(s, fit))
    end

    -- ตำแหน่งตามมุมที่ยึดไว้ (ค่าเริ่มต้น: มุมขวาบน) ขยายแล้วเติบโตเข้าหาจอ ไม่ล้นขอบ
    local function placeFor(wd, hd)
        local sc = calcScale()
        local vp = getVP()
        local w, h = wd * sc, hd * sc
        local mx, my = S.mx or 8, S.my or 6
        local left = (S.side == "l") and mx or (vp.X - w - mx)
        local x = math.clamp(left, 4, math.max(4, vp.X - w - 4))
        local y = math.clamp(my, 4, math.max(4, vp.Y - h - 4))
        return UDim2.fromOffset(x, y)
    end

    function UI.savePos(target)
        local vp = getVP()
        local a = target.AbsoluteSize
        local left, top = target.Position.X.Offset, target.Position.Y.Offset
        if left + a.X / 2 > vp.X / 2 then
            S.side = "r"
            S.mx = math.max(0, math.floor(vp.X - left - a.X))
        else
            S.side = "l"
            S.mx = math.max(0, math.floor(left))
        end
        S.my = math.max(0, math.floor(top))
        saveState()
    end

    local function makeDot(parent, cx, cy, d, withGlow)
        local rec = { d = d }
        if withGlow then
            rec.glow = new("Frame", {
                AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(cx, cy),
                Size = UDim2.fromOffset(d + 8, d + 8), BackgroundColor3 = TH.dim,
                BackgroundTransparency = 0.85, BorderSizePixel = 0,
            }, parent)
            round(rec.glow)
        end
        rec.dot = new("Frame", {
            AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(cx, cy),
            Size = UDim2.fromOffset(d, d), BackgroundColor3 = TH.dim, BorderSizePixel = 0,
        }, parent)
        round(rec.dot)
        table.insert(UI.dots, rec)
        return rec.dot
    end

    -- ---------- แบบย่อ: จุดสี + เวลาออนไลน์ (เด้งกว้างขึ้นโชว์ข้อความตอนสถานะเปลี่ยน) ----------
    local compact = new("CanvasGroup", {
        Name = "Compact", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0,
    }, island)
    makeDot(compact, 12, CH / 2, 8, false)
    local cTime = new("TextLabel", {
        Text = "0:00", Position = UDim2.fromOffset(26, 0), Size = UDim2.new(1, -32, 1, 0),
        BackgroundTransparency = 1, Font = F.semi, TextSize = 12, TextColor3 = "text",
        TextXAlignment = Enum.TextXAlignment.Left,
    }, compact)
    local cStatus = new("TextLabel", {
        Text = "", Position = UDim2.fromOffset(26, 0), Size = UDim2.new(1, -34, 1, 0),
        BackgroundTransparency = 1, Font = F.semi, TextSize = 13, TextColor3 = "text",
        TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
        TextTransparency = 1,
    }, compact)

    -- ---------- แบบขยาย (หน้าเดียว) ----------
    local full = new("CanvasGroup", {
        Name = "Full", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0),
        Size = UDim2.fromOffset(EW, EH), BackgroundTransparency = 1, BorderSizePixel = 0,
        Visible = false, GroupTransparency = 1,
    }, island)
    local fullScale = new("UIScale", { Scale = 0.92 }, full)

    -- พื้นที่แตะ/ลากส่วนหัว (แตะ = ย่อ) วางไว้ล่างสุดให้ข้อความอยู่ข้างบน
    local hit = new("TextButton", {
        Text = "", AutoButtonColor = false, BackgroundTransparency = 1, BorderSizePixel = 0,
        Size = UDim2.new(1, -64, 0, 42),
    }, full)

    makeDot(full, 22, 21, 10, true)
    local status = new("TextLabel", {
        Text = "กำลังเริ่ม...", Position = UDim2.fromOffset(40, 5), Size = UDim2.new(1, -104, 0, 20),
        BackgroundTransparency = 1, Font = F.bold, TextSize = 16, TextColor3 = "text",
        TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
    }, full)
    local detail = new("TextLabel", {
        Text = "", Position = UDim2.fromOffset(40, 25), Size = UDim2.new(1, -104, 0, 14),
        BackgroundTransparency = 1, Font = F.reg, TextSize = 11, TextColor3 = "dim",
        TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
    }, full)
    local sw = iosSwitch(full, UDim2.new(1, -54, 0, 9), function()
        if UI.act.auto then UI.act.auto() end
    end)

    -- มุมมองหลัก: ข้อมูล 3 บรรทัด + ประวัติ 2 เหตุการณ์
    local mainView = new("Frame", {
        Position = UDim2.fromOffset(0, 46), Size = UDim2.new(1, 0, 0, 102), BackgroundTransparency = 1,
    }, full)
    local function infoLine(y)
        return new("TextLabel", {
            Text = "", Position = UDim2.fromOffset(16, y), Size = UDim2.new(1, -32, 0, 16),
            BackgroundTransparency = 1, Font = F.reg, TextSize = 12, TextColor3 = "dim",
            TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
        }, mainView)
    end
    UI.info1, UI.info2, UI.info3 = infoLine(0), infoLine(17), infoLine(34)
    local histCard = new("Frame", {
        Position = UDim2.fromOffset(14, 56), Size = UDim2.new(1, -28, 0, 44),
        BackgroundColor3 = "card", BorderSizePixel = 0,
    }, mainView)
    round(histCard, UDim.new(0, 10))
    UI.hist = new("TextLabel", {
        Text = "", Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -20, 1, 0),
        BackgroundTransparency = 1, Font = F.reg, TextSize = 11, TextColor3 = "dim",
        TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Center,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, histCard)

    -- มุมมองตั้งค่า: ธีม / ขนาด / จางเมื่อไม่ได้ใช้
    local setView = new("Frame", {
        Position = UDim2.fromOffset(14, 46), Size = UDim2.new(1, -28, 0, 102),
        BackgroundColor3 = "card", BorderSizePixel = 0, Visible = false,
    }, full)
    round(setView, UDim.new(0, 12))
    local function rowLabel(i, text)
        new("TextLabel", {
            Text = text, Position = UDim2.fromOffset(14, (i - 1) * 34), Size = UDim2.fromOffset(110, 34),
            BackgroundTransparency = 1, Font = F.semi, TextSize = 13, TextColor3 = "text",
            TextXAlignment = Enum.TextXAlignment.Left,
        }, setView)
    end
    local function hairline(y)
        new("Frame", {
            Position = UDim2.fromOffset(14, y), Size = UDim2.new(1, -14, 0, 1),
            BackgroundColor3 = "line", BackgroundTransparency = 0.3, BorderSizePixel = 0,
        }, setView)
    end
    rowLabel(1, "ธีม");   hairline(34)
    rowLabel(2, "ขนาด");  hairline(68)
    rowLabel(3, "จางเมื่อไม่ได้ใช้")

    local modeSeg = segmented(setView, {
        labels = { "มืด", "สว่าง", "อัตโนมัติ" },
        pos = UDim2.new(1, -12, 0, 17), anchor = Vector2.new(1, 0.5), size = UDim2.fromOffset(176, 26),
        track = "segIn", ts = 12,
        onPick = function(i)
            S.mode = MODES[i]
            saveState()
            applyTheme(true)
            UI.addLog("เปลี่ยนธีม: " .. ({ "มืด", "สว่าง", "อัตโนมัติ (ตามเวลา)" })[i])
        end,
    })
    modeSeg.set(indexOf(MODES, S.mode or "dark", 1), false)

    local sizeSeg = segmented(setView, {
        labels = { "เล็ก", "กลาง", "ใหญ่" },
        pos = UDim2.new(1, -12, 0, 51), anchor = Vector2.new(1, 0.5), size = UDim2.fromOffset(140, 26),
        track = "segIn", ts = 12,
        onPick = function(i)
            S.size = i
            saveState()
            if UI.applyScale then UI.applyScale() end
            UI.addLog("ปรับขนาด: " .. ({ "เล็ก", "กลาง", "ใหญ่" })[i])
        end,
    })
    sizeSeg.set(S.size or 2, false)

    local dimSw
    dimSw = iosSwitch(setView, UDim2.new(1, -52, 0, 73), function()
        S.dim = not (S.dim ~= false)
        saveState()
        dimSw.set(S.dim, true)
        if not S.dim and UI.wake then UI.wake() end
        UI.addLog("จางเมื่อไม่ได้ใช้: " .. (S.dim and "เปิด" or "ปิด"))
    end)
    dimSw.set(S.dim ~= false, false)

    -- ปุ่มด้านล่าง
    local actions = new("Frame", {
        Position = UDim2.fromOffset(14, 154), Size = UDim2.new(1, -28, 0, 30), BackgroundTransparency = 1,
    }, full)
    local BW = UDim2.new(1 / 3, -4, 1, 0)
    tintedBtn(actions, "ทดสอบ", "warn", UDim2.new(0, 0, 0, 0), BW, true,
        function() if UI.act.test then UI.act.test() end end)
    local copyFlash
    local _, cf = tintedBtn(actions, "คัดลอก log", "acc", UDim2.new(1 / 3, 2, 0, 0), BW, false,
        function()
            local r = UI.act.copy and UI.act.copy()
            if copyFlash then copyFlash(r and "คัดลอกแล้ว" or "คัดลอกไม่ได้") end
        end)
    copyFlash = cf
    local inSettings = false
    local setBtn
    setBtn = tintedBtn(actions, "ตั้งค่า", "dim", UDim2.new(2 / 3, 4, 0, 0), BW, false,
        function()
            inSettings = not inSettings
            mainView.Visible = not inSettings
            setView.Visible = inSettings
            setBtn.Text = inSettings and "กลับ" or "ตั้งค่า"
        end)

    -- ---------- สเกล/ตำแหน่ง ----------
    UI.applyScale = function()
        tw(scaleObj, 0.3, { Scale = calcScale() })
        tw(island, 0.3, { Position = placeFor(UI.curW, UI.curH) })
    end
    gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
        if UI.applyScale and not UI.entering then UI.applyScale() end
    end)

    -- ---------- จางลงตอนไม่ได้ใช้ (เฉพาะตอนย่อและสถานะปกติ) ----------
    local peeking, peekToken = false, 0
    local TI_DIM = TweenInfo.new(0.5, Enum.EasingStyle.Quad)
    local function undim()
        UI.lastActive = os.clock()
        if not UI.dimmed then return end
        UI.dimmed = false
        TweenService:Create(island, TI_DIM, { BackgroundTransparency = 0 }):Play()
        TweenService:Create(rim, TI_DIM, { Transparency = 0.25 }):Play()
        if not UI.expanded then TweenService:Create(compact, TI_DIM, { GroupTransparency = 0 }):Play() end
    end
    local function dim()
        if UI.dimmed or UI.expanded or peeking or S.dim == false then return end
        UI.dimmed = true
        TweenService:Create(island, TI_DIM, { BackgroundTransparency = 0.6 }):Play()
        TweenService:Create(rim, TI_DIM, { Transparency = 0.85 }):Play()
        TweenService:Create(compact, TI_DIM, { GroupTransparency = 0.55 }):Play()
    end
    UI.wake = undim
    UI.dimIfIdle = function()
        if not UI.expanded and not UI.dimmed and not peeking and S.dim ~= false
            and os.clock() - UI.lastActive > 5 then
            dim()
        end
    end
    island.MouseEnter:Connect(undim)

    -- ---------- ขยาย / ย่อ ----------
    local TWEEN_SIZE = TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
    local function isAlert() return UI.color == "bad" or UI.color == "warn" end

    local function expand()
        if UI.expanded or os.clock() - UI.lastToggle < 0.3 then return end
        UI.lastToggle = os.clock()
        peekToken = peekToken + 1
        peeking = false
        undim()
        UI.expanded = true
        UI.curW, UI.curH = EW, EH
        full.Visible = true
        full.GroupTransparency = 1
        fullScale.Scale = 0.9
        tw(compact, 0.12, { GroupTransparency = 1 }, Enum.EasingStyle.Quad)
        TweenService:Create(island, TWEEN_SIZE, { Size = UDim2.fromOffset(EW, EH) }):Play()
        tw(island, 0.45, { Position = placeFor(EW, EH) })
        tw(corner, 0.45, { CornerRadius = UDim.new(0, 28) })
        fpsOn()
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
        UI.curW, UI.curH = CW, CH
        UI.lastActive = os.clock()
        fpsOff()
        cStatus.TextTransparency = 1
        cTime.TextTransparency = 0
        tw(full, 0.16, { GroupTransparency = 1 }, Enum.EasingStyle.Quad)
        tw(fullScale, 0.25, { Scale = 0.92 })
        compact.Visible = true
        TweenService:Create(island, TweenInfo.new(0.42, Enum.EasingStyle.Quint), { Size = UDim2.fromOffset(CW, CH) }):Play()
        tw(island, 0.42, { Position = placeFor(CW, CH) })
        tw(corner, 0.35, { CornerRadius = UDim.new(0, CH / 2) })
        task.delay(0.1, function()
            if not UI.expanded then tw(compact, 0.25, { GroupTransparency = 0 }, Enum.EasingStyle.Quad) end
        end)
        task.delay(0.2, function() if not UI.expanded then full.Visible = false end end)
        task.delay(0.5, function()
            if not UI.expanded and isAlert() and UI.peek then UI.peek() end
        end)
    end

    -- เด้งกว้างขึ้นโชว์ข้อความสถานะ (เหมือน Live Activity) ถ้าเป็นเรื่องร้ายแรงจะค้างไว้จนกว่าจะกลับปกติ
    UI.peek = function()
        if UI.expanded then return end
        undim()
        peekToken = peekToken + 1
        local mine = peekToken
        peeking = true
        UI.curW, UI.curH = PW, CH
        TweenService:Create(island, TweenInfo.new(0.35, Enum.EasingStyle.Back), { Size = UDim2.fromOffset(PW, CH) }):Play()
        tw(island, 0.35, { Position = placeFor(PW, CH) })
        tw(cStatus, 0.2, { TextTransparency = 0 }, Enum.EasingStyle.Quad)
        tw(cTime, 0.2, { TextTransparency = 1 }, Enum.EasingStyle.Quad)
        task.delay(3.2, function()
            if mine ~= peekToken or UI.expanded or isAlert() then return end
            peeking = false
            UI.curW, UI.curH = CW, CH
            TweenService:Create(island, TweenInfo.new(0.4, Enum.EasingStyle.Quint), { Size = UDim2.fromOffset(CW, CH) }):Play()
            tw(island, 0.4, { Position = placeFor(CW, CH) })
            tw(cStatus, 0.2, { TextTransparency = 1 }, Enum.EasingStyle.Quad)
            tw(cTime, 0.2, { TextTransparency = 0 }, Enum.EasingStyle.Quad)
            UI.lastActive = os.clock()
        end)
    end

    makeDrag(island, island, expand)
    makeDrag(hit, island, collapse)

    if not mount(gui) then gui:Destroy() error("ไม่มีที่ใส่ UI") end
    genv.AA_REJOIN_GUI = gui
    UI.status, UI.detail, UI.cStatus, UI.cTime = status, detail, cStatus, cTime
    UI.setSwitch = function(on) sw.set(on, true) end
    sw.set(RT.auto, false)

    -- เปิดตัว: เม็ดยาร่วงลงมาจากด้านบนแบบสปริงไปอยู่มุมจอ
    UI.entering = true
    task.delay(0.9, function() UI.entering = false end)
    local sc0 = calcScale()
    scaleObj.Scale = sc0
    local final = placeFor(CW, CH)
    island.Position = UDim2.fromOffset(final.X.Offset, -CH * sc0 - 12)
    compact.GroupTransparency = 1
    tw(island, 0.7, { Position = final }, Enum.EasingStyle.Back)
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
        if d.glow then tw(d.glow, 0.3, { BackgroundColor3 = c }, Enum.EasingStyle.Quad) end
    end
end

function UI.set(text, color, det)
    if not UI.gui or not UI.status then return end
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
    table.insert(allLines, line)
    while #allLines > 300 do table.remove(allLines, 1) end
end

local function refreshInfo()
    local ping = getPing()
    UI.info1.Text = "ออนไลน์ " .. fmt(os.clock() - T0) .. " · " .. (ping and (ping .. " ms") or "- ms")
        .. " · " .. FPS.value .. " fps"
    if (S.drops or 0) == 0 then
        UI.info2.Text = "ยังไม่เคยหลุด"
    else
        UI.info2.Text = "หลุด " .. S.drops .. " ครั้ง · ล่าสุด " .. span(os.time() - (S.lastDisc or os.time()))
            .. "ก่อน" .. (S.lastReason and (" (" .. S.lastReason .. ")") or "")
    end
    local tid, how = resolveTarget()
    UI.info3.Text = "ไป: " .. tostring(tid) .. " (" .. how .. ")" .. (RT.idleLevel and (" · AFK L" .. RT.idleLevel) or "")
    local ev = {}
    for i = #S.events, math.max(1, #S.events - 1), -1 do
        local e = S.events[i]
        ev[#ev + 1] = os.date("%H:%M", e.t) .. " " .. tostring(e.k) .. ((e.m and e.m ~= "") and (": " .. e.m) or "")
    end
    UI.hist.Text = (#ev > 0) and table.concat(ev, "\n") or "ยังไม่มีประวัติ"
end

-- เรียกเป็นระยะ: ตอนย่อทำน้อยมาก (แค่เวลา + เช็คว่าจะจางไหม) ตอนขยายถึงอัปเดตเต็ม
function UI.refresh()
    if not UI.gui or not UI.cTime then return end
    local now = os.clock()
    if currentDark() ~= UI.isDark then applyTheme(true) end   -- โหมดอัตโนมัติ: สลับตามเวลา
    UI.paint(false)
    UI.cTime.Text = fmtHM(now - T0)
    if not UI.expanded then
        if UI.dimIfIdle then UI.dimIfIdle() end
        return
    end
    local dt = now - FPS.t
    if dt >= 0.9 then
        FPS.value = math.floor(FPS.frames / dt + 0.5)
        FPS.frames = 0
        FPS.t = now
    end
    UI.tick = not UI.tick
    for _, d in ipairs(UI.dots) do
        if d.glow then
            local big = UI.tick and (d.d + 14) or (d.d + 6)
            TweenService:Create(d.glow, TweenInfo.new(0.9, Enum.EasingStyle.Sine), {
                BackgroundTransparency = UI.tick and 0.6 or 0.9,
                Size = UDim2.fromOffset(big, big),
            }):Play()
        end
    end
    refreshInfo()
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
        return ok
    end
    log("executor นี้ไม่มี setclipboard คัดลอกไม่ได้")
    return false
end

-- สวิตช์รีจอย: เปิด/ปิด หรือถ้ากำลังหยุดอยู่ (เข้าซ้ำ/แบน) แตะเพื่อเริ่มใหม่
UI.act.auto = function()
    if RT.halted then
        RT.halted = nil
        RT.rejoining = false
        RT.auto = true
        S.auto = true
        saveState()
        if UI.setSwitch then UI.setSwitch(true) end
        log("เริ่มเฝ้าดูอีกครั้ง")
        UI.set("เฝ้าดูการหลุดอยู่", COL.ok, "")
        return
    end
    RT.auto = not RT.auto
    S.auto = RT.auto
    saveState()
    if UI.setSwitch then UI.setSwitch(RT.auto) end
    log("รีจอยอัตโนมัติ:", RT.auto and "เปิด" or "ปิด")
    if not RT.rejoining then
        UI.set(RT.auto and "เฝ้าดูการหลุดอยู่" or "ปิดรีจอยอยู่", RT.auto and COL.ok or COL.dim, "")
    end
end

-- ===================== แจ้งเตือน (ไม่บังคับ) =====================
-- ข้อความเก็บในคิว (บันทึกลงไฟล์) ถ้าส่งไม่สำเร็จ เช่น เน็ตยังไม่กลับ จะส่งซ้ำเองทีหลัง ไม่หายเงียบ
local function sendHook(text)
    local req = reqFn()
    if not req then return false end
    local ok, res = pcall(req, {
        Url = CFG.WEBHOOK, Method = "POST",
        Headers = { ["Content-Type"] = "application/json" },
        Body = HS:JSONEncode({ content = text }),
    })
    if not ok or type(res) ~= "table" then return false end
    local sc = res.StatusCode
    return type(sc) == "number" and sc >= 200 and sc < 300
end
local flushing = false
local function flushOutbox()
    if flushing or CFG.WEBHOOK == "" or #S.outbox == 0 then return end
    flushing = true
    task.spawn(function()
        pcall(function()
            local sent = 0
            while #S.outbox > 0 and sent < 10 do
                local item = S.outbox[1]
                local text = tostring(item.m)
                if os.time() - (item.t or os.time()) > 90 then text = os.date("[%H:%M] ", item.t) .. text end
                if not sendHook(text) then break end
                table.remove(S.outbox, 1)
                sent = sent + 1
                saveState()
                task.wait(1)
            end
        end)
        flushing = false
    end)
end
local function notify(msg)
    if CFG.WEBHOOK == "" then return end
    local tag = CFG.WEBHOOK_TAG and ("[" .. tostring(lp.Name) .. "] ") or ""
    table.insert(S.outbox, { t = os.time(), m = tag .. msg })
    while #S.outbox > 20 do table.remove(S.outbox, 1) end
    saveState()
    flushOutbox()
end

-- ให้สคิปนี้รันซ้ำเองหลังทุกการวาร์ป
if queue_on_teleport then
    queue_on_teleport('loadstring(readfile("' .. FILE .. '"))()')
end

local function enumName(v)
    local s = tostring(v)
    return s:match("([%w_]+)$") or s
end
-- ผลวาร์ปล้มเหลวจริงๆ (GameFull / GameEnded / GameNotFound / Unauthorized / Flooded / IsTeleporting)
-- เก็บไว้ให้ตัวรีจอยเลือกทางต่อ · IsTeleporting = มีวาร์ปค้างอยู่แล้ว ไม่นับว่าล้มเหลว (รอต่อ)
pcall(function()
    TS.TeleportInitFailed:Connect(function(_, result, msg)
        local name = enumName(result)
        RT.tpResult, RT.tpMsg = name, tostring(msg or "")
        if name == "IsTeleporting" then
            log("วาร์ป: มีวาร์ปค้างอยู่แล้ว รอต่อ")
        else
            RT.tpFailed = true
            log("วาร์ปล้มเหลว:", name, RT.tpMsg:sub(1, 80))
        end
    end)
end)
-- รู้ว่าเกม/เรากำลังวาร์ปอยู่ (กันตีความว่าหลุดเงียบตอนวาร์ปเข้าแมตช์ตามปกติ)
pcall(function()
    lp.OnTeleport:Connect(function(state)
        if enumName(state) == "Failed" then RT.tpSeen = nil else RT.tpSeen = os.clock() end
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

-- จำลองการแตะจริงที่กลางปุ่ม (สำรอง เผื่อยิงสัญญาณแล้วปุ่มไม่ตอบสนอง)
local function realClick(btn)
    pcall(function()
        local VIM = game:GetService("VirtualInputManager")
        local p, s = btn.AbsolutePosition, btn.AbsoluteSize
        local x, y = p.X + s.X / 2, p.Y + s.Y / 2
        local sg = btn:FindFirstAncestorWhichIsA("ScreenGui")
        if not (sg and sg.IgnoreGuiInset) then
            local inset = GuiService:GetGuiInset()
            x, y = x + inset.X, y + inset.Y
        end
        VIM:SendMouseButtonEvent(x, y, 0, true, game, 1)
        task.wait(0.08)
        VIM:SendMouseButtonEvent(x, y, 0, false, game, 1)
    end)
end

-- ปุ่ม "เชื่อมต่อใหม่" บนหน้าต่างแจ้งหลุดของ Roblox (CoreGui)
-- Roblox ที่ตั้งภาษาไทยจะเขียนปุ่มเป็นภาษาไทย จึงต้องรู้จักทั้งไทยและอังกฤษ (และดูชื่อปุ่มด้วย)
local RECONNECT_PATS = { "reconnect", "rejoin", "retry", "try again", "เชื่อมต่อ", "เข้าร่วม", "ลองอีกครั้ง", "ลองใหม่" }
local LEAVE_PATS     = { "leave", "ออก" }

local function hasAny(s, pats)
    s = tostring(s):lower()
    for _, p in ipairs(pats) do
        if s:find(p, 1, true) then return true end
    end
    return false
end

-- คืน (ปุ่ม, คำอธิบาย, รายการปุ่มทั้งหมดที่เห็นบนหน้าต่าง)
local function findReconnectButton()
    local found = {}
    local ok, btn, desc = pcall(function()
        local g = game:GetService("CoreGui"):FindFirstChild("RobloxPromptGui")
        if not g then return nil end
        local po = g:FindFirstChild("promptOverlay")
        local root = (po and po:FindFirstChild("ErrorPrompt")) or g
        for _, o in ipairs(root:GetDescendants()) do
            if o:IsA("GuiButton") then
                local shown, a = true, o
                while a and a ~= root do
                    if a:IsA("GuiObject") and not a.Visible then
                        shown = false
                        break
                    end
                    a = a.Parent
                end
                if shown then
                    local txt = o:IsA("TextButton") and o.Text or ""
                    for _, d in ipairs(o:GetDescendants()) do
                        if d:IsA("TextLabel") and d.Text ~= "" then txt = txt .. " " .. d.Text end
                    end
                    local label = o.Name .. "|" .. txt
                    found[#found + 1] = label
                    if hasAny(o.Name .. " " .. txt, RECONNECT_PATS) and not hasAny(txt, LEAVE_PATS) then
                        return o, label
                    end
                end
            end
        end
        return nil
    end)
    if ok and btn then return btn, desc, found end
    return nil, nil, found
end

-- กดปุ่ม Reconnect แล้วรอให้เกมพากลับเข้าเอง (ถ้าสำเร็จ สคิปนี้จะถูกปิดไปกับเซิร์ฟเดิม)
-- คืน true = กดแล้ว (แต่ยังไม่ไป) · false = ไม่เจอปุ่ม
local function pressReconnect(waitSec)
    local b, desc, found = findReconnectButton()
    if not b then
        if #found > 0 then
            log("ไม่เจอปุ่ม Reconnect ที่รู้จัก ปุ่มที่มี:", table.concat(found, " / "))
        else
            log("ไม่เจอปุ่มบนหน้าต่างหลุด (หน้าต่างอาจหายไปแล้ว หรือ executor เข้า CoreGui ไม่ได้)")
        end
        return false
    end
    log("กดปุ่มหน้าต่างหลุด:", desc)
    RT.tpFailed = false
    click(b)
    local t0, tried = os.clock(), false
    while RT.auto and os.clock() - t0 < waitSec do
        task.wait(1)
        if RT.tpFailed then break end
        -- ผ่านไป 8 วิปุ่มยังอยู่ = ยิงสัญญาณไม่ติด ลองแตะจริงอีกวิธี
        if not tried and os.clock() - t0 >= 8 then
            tried = true
            local b2 = findReconnectButton()
            if b2 then
                log("ปุ่มยังอยู่ ลองแตะปุ่มจริงอีกวิธี")
                realClick(b2)
            end
        end
    end
    return true
end

-- ปิดหน้าต่างแจ้งที่ไม่ใช่การหลุด (เช่น วาร์ปล้มเหลวแต่ยังอยู่ในเซิร์ฟ) ด้วยการกดปุ่ม OK/ปิด (ไม่แตะปุ่ม Reconnect/Leave)
local OK_PATS = { "ok", "ตกลง", "close", "ปิด", "dismiss", "got it" }
local function dismissPrompt()
    pcall(function()
        local g = game:GetService("CoreGui"):FindFirstChild("RobloxPromptGui")
        local po = g and g:FindFirstChild("promptOverlay")
        local root = po and po:FindFirstChild("ErrorPrompt")
        if not root then return end
        for _, o in ipairs(root:GetDescendants()) do
            if o:IsA("GuiButton") then
                local txt = o:IsA("TextButton") and o.Text or ""
                for _, d in ipairs(o:GetDescendants()) do
                    if d:IsA("TextLabel") and d.Text ~= "" then txt = txt .. " " .. d.Text end
                end
                local all = o.Name .. " " .. txt
                if hasAny(all, OK_PATS) and not hasAny(all, RECONNECT_PATS) and not hasAny(txt, LEAVE_PATS) then
                    log("ปิดหน้าต่างแจ้ง:", o.Name .. "|" .. txt)
                    click(o)
                    return
                end
            end
        end
    end)
end

-- ===================== เช็คว่า "ยังเชื่อมกับเซิร์ฟอยู่จริงไหม" =====================
-- ตอนเชื่อมอยู่ NetworkClient มีตัวเชื่อมเครือข่ายเป็นลูก และ LocalPlayer อยู่ใน Players · ถ้าหลุดสองอย่างนี้จะหายไป
-- ใช้ประกอบการตัดสินเท่านั้น: ถ้าเริ่มสคริปต์ตอนหลุดอยู่แล้ว หรือสัญญาณขัดกัน = "unknown" แล้วทำงานแบบเดิม (v3)
local NC
pcall(function() NC = game:GetService("NetworkClient") end)
local function repCount()
    local ok, n = pcall(function() return #NC:GetChildren() end)
    if ok and type(n) == "number" then return n end
    return nil
end
RT.hadRep = (repCount() or 0) > 0
local function sessionState()
    if not RT.hadRep then return "unknown" end
    local n = repCount()
    if n == nil then return "unknown" end
    local inPlayers = (lp.Parent == Players)
    if n > 0 and inPlayers then return "alive" end
    if n == 0 and not inPlayers then return "dead" end
    return "unknown"
end
-- เกม/เรากำลังวาร์ปอยู่ไหม (ภายใน 90 วิหลังได้สัญญาณวาร์ป ไม่ตีความว่าหลุดเงียบ)
local function tpRecent()
    return RT.tpSeen ~= nil and os.clock() - RT.tpSeen < 90
end

-- ===================== ตรวจว่าหลุดไหม =====================
-- คืน (หลุดไหม, ข้อความ, มาจากหน้าต่างจริงไหม, เห็น CoreGui ไหม)
local function disconnectInfo()
    -- 1) หน้าต่าง ErrorPrompt ของ Roblox โผล่ขึ้นมา (อ่านข้อความในหน้าต่างด้วย)
    local up, pmsg, coreSeen = false, "", false
    pcall(function()
        local g = game:GetService("CoreGui"):FindFirstChild("RobloxPromptGui")
        coreSeen = (g ~= nil)
        local po = g and g:FindFirstChild("promptOverlay")
        local ep = po and po:FindFirstChild("ErrorPrompt")
        if ep and (not ep:IsA("GuiObject") or ep.Visible) then
            up = true
            for _, o in ipairs(ep:GetDescendants()) do
                if o:IsA("TextLabel") and o.Name == "ErrorMessage" and o.Text ~= "" then
                    pmsg = o.Text
                    break
                end
            end
        end
    end)
    -- 2) ข้อความ error ของ GuiService (กรณี executor เข้า CoreGui ไม่ได้) · ถ้ามีหน้าต่างจริง ใช้ข้อความในหน้าต่างก่อน (สดกว่า)
    local msg = ""
    pcall(function() msg = GuiService:GetErrorMessage() or "" end)
    if type(msg) ~= "string" then msg = "" end
    if pmsg ~= "" then msg = pmsg end
    return (up or msg ~= ""), msg, up, coreSeen
end

-- เช็คว่าเน็ตกลับมาไหม (ยิงขอข้อมูลเล็กๆ ไป Roblox) ถ้า executor ไม่มี request ถือว่าออนไลน์
local function isOnline()
    local req = reqFn()
    if not req then return true end
    local ok, res = pcall(req, { Url = "https://users.roblox.com/v1/users/" .. tostring(lp.UserId), Method = "GET" })
    if not ok or type(res) ~= "table" then return false end
    local sc = res.StatusCode
    return type(sc) == "number" and sc > 0 and sc < 500
end

local function waitOnline(maxWait)
    local t0 = os.clock()
    while RT.auto do
        if isOnline() then return true end
        local waited = os.clock() - t0
        if waited >= maxWait then return false end
        UI.set("รอเน็ตกลับมา", COL.warn, "เช็คทุก 5 วิ · รอมาแล้ว " .. span(waited))
        task.wait(5)
    end
    return false
end

-- หา "หน้าหลัก" (RootPlace) ของเกม ตอนที่เน็ตยังดีอยู่ เก็บไว้ใช้ตอนหลุด
local function fetchRoot()
    local req = reqFn()
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

-- ===================== จำเซิร์ฟที่เข้าไม่ได้ =====================
local function isBad(id)
    local ts = S.bad[id]
    if not ts then return false end
    if ts <= os.time() then
        S.bad[id] = nil
        return false
    end
    return true
end
local function markBad(id, ttl)
    if not id then return end
    local now = os.time()
    S.bad[id] = now + (ttl or CFG.BAD_SERVER_TTL)
    local n, oldK, oldT = 0, nil, math.huge
    for k, ts in pairs(S.bad) do
        if ts <= now then
            S.bad[k] = nil
        else
            n = n + 1
            if ts < oldT then oldK, oldT = k, ts end
        end
    end
    if n > 60 and oldK then S.bad[oldK] = nil end
    saveState()
end

-- คัดเซิร์ฟที่น่าเข้า: มีคนอยู่ (ยังไม่ปิด) · เหลือที่ว่างพอ (ไม่ใกล้เต็มจนแย่งที่ไม่ทัน) · ไม่แลค · ไม่ใช่เซิร์ฟเดิม/เซิร์ฟที่เคยเข้าไม่ได้
local function qualify(list)
    local cands = {}
    for _, s in ipairs(list) do
        if type(s) == "table" and type(s.id) == "string" and s.id ~= game.JobId and not isBad(s.id) then
            local pl, mx = tonumber(s.playing) or 0, tonumber(s.maxPlayers) or 0
            local fps, ping = tonumber(s.fps), tonumber(s.ping)
            local minFree = math.max(2, math.floor(mx * 0.15))
            local laggy = (fps ~= nil and fps > 0 and fps < 20)
            if pl >= 1 and mx - pl >= minFree and not laggy then
                cands[#cands + 1] = { id = s.id, pl = pl, score = math.min(fps or 40, 60) - math.min(ping or 0, 500) / 25 }
            end
        end
    end
    table.sort(cands, function(a, b) return a.score > b.score end)
    return cands
end

-- ดึงรายการเซิร์ฟสาธารณะ (ไม่รวมเซิร์ฟเต็ม) สูงสุด 2 หน้า · โดนลิมิต 429 = จำไว้แล้วข้ามการค้นหา 60 วิ
local function fetchServers(placeId)
    local req = reqFn()
    if not req then return nil, "executor ไม่มี request" end
    local list, cursor = {}, nil
    local function partial(why) return (#list > 0) and list or nil, why end
    for page = 1, 2 do
        local url = "https://games.roblox.com/v1/games/" .. tostring(placeId)
            .. "/servers/Public?sortOrder=Asc&excludeFullGames=true&limit=100"
            .. (cursor and ("&cursor=" .. cursor) or "")
        local ok, res = pcall(req, { Url = url, Method = "GET" })
        if not ok then return partial(tostring(res)) end
        if type(res) ~= "table" or not res.Body then return partial("ไม่มีข้อมูลตอบกลับ") end
        if res.StatusCode == 429 then
            RT.apiBlockedUntil = os.clock() + 60
            return partial("HTTP 429 (โดนจำกัดความถี่)")
        end
        if res.StatusCode and res.StatusCode ~= 200 then return partial("HTTP " .. tostring(res.StatusCode)) end
        local ok2, data = pcall(function() return HS:JSONDecode(res.Body) end)
        if not ok2 or type(data) ~= "table" or type(data.data) ~= "table" then return partial("อ่านรายการเซิร์ฟไม่ได้") end
        for _, s in ipairs(data.data) do list[#list + 1] = s end
        cursor = data.nextPageCursor
        if type(cursor) ~= "string" or cursor == "" or #qualify(list) >= 8 then break end
        if page < 2 then task.wait(0.6) end
    end
    return list
end

-- เลือกเซิร์ฟว่าง: สุ่มจาก 6 อันดับแรก (หลายบัญชีจะไม่แห่ไปเซิร์ฟเดียวกัน) · ใช้รายการที่เพิ่งดึงไม่เกิน 60 วิซ้ำได้
local function findOpenServer(placeId)
    if RT.apiBlockedUntil and os.clock() < RT.apiBlockedUntil then
        return nil, "API ติดลิมิต รออีก " .. math.ceil(RT.apiBlockedUntil - os.clock()) .. " วิ"
    end
    local cands
    local c = RT.srvCache
    if c and c.place == placeId and os.clock() - c.t < 60 then cands = qualify(c.list) end
    if not cands or #cands == 0 then
        local list, err = fetchServers(placeId)
        if not list then return nil, err end
        RT.srvCache = { place = placeId, t = os.clock(), list = list }
        cands = qualify(list)
        if #cands == 0 then return nil, err or "ไม่มีเซิร์ฟที่ว่าง" end
    end
    return cands[math.random(1, math.min(6, #cands))].id
end

-- ===================== เข้าเกมใหม่เมื่อหลุด =====================
-- ---------- ตัวช่วย: จำวิธีที่ใช้ได้ผล / ทำอะไรต่อหลังลองแต่ละครั้ง ----------
-- อัตราสำเร็จ (ปรับให้เรียบ) ของแต่ละวิธี: ยังไม่มีข้อมูล = 0.5
local function mrate(m)
    local st = S.mstat[m]
    if not st then return 0.5 end
    local ok, fail = st.ok or 0, st.fail or 0
    return (ok + 1) / (ok + fail + 2)
end
local function mnote(m, good)
    if not CFG.LEARN_METHODS or (m ~= "same" and m ~= "open" and m ~= "any") then return end
    local st = S.mstat[m] or { ok = 0, fail = 0 }
    st.ok, st.fail = (st.ok or 0) * 0.9, (st.fail or 0) * 0.9   -- ผลเก่าค่อยๆ หมดน้ำหนัก
    if good then st.ok = st.ok + 1 else st.fail = st.fail + 1 end
    S.mstat[m] = st
    saveState()
end

-- โดนเตะ AFK ทั้งที่เปิดกันไว้ -> เพิ่มระดับกัน AFK (มีผลรอบหน้าหลังรีจอย) · IDLE_LEVEL ตั้งเอง = ไม่ปรับ
local function bumpIdleLevel()
    if not CFG.ANTI_IDLE or (type(CFG.IDLE_LEVEL) == "number" and CFG.IDLE_LEVEL >= 1) then return end
    local cur = S.idleLevel or 1
    if cur < 3 then
        S.idleLevel = cur + 1
        saveState()
        log("โดนเตะ AFK ทั้งที่เปิดกันไว้ -> เพิ่มระดับกัน AFK เป็น", S.idleLevel)
    else
        log("โดนเตะ AFK แม้ใช้ระดับกันสูงสุดแล้ว (เกมนี้อาจนับ AFK เอง)")
    end
end

-- ลำดับวิธีเข้า (กฎเดิมของ v3) แล้วขยับวิธีที่เคยสำเร็จบ่อยกว่าชัดเจนขึ้นมาก่อน
local function buildPlan(info, offMain)
    local plan = {}
    if CFG.TRY_SAME_SERVER and not info.nosame and game.JobId ~= "" and not offMain then plan[#plan + 1] = "same" end
    if offMain and CFG.FIND_OPEN_SERVER then plan[#plan + 1] = "open" end
    plan[#plan + 1] = "any"
    if (not offMain) and CFG.FIND_OPEN_SERVER then plan[#plan + 1] = "open" end
    if CFG.LEARN_METHODS then
        for i = 2, #plan do
            local j = i
            while j > 1 and mrate(plan[j]) > mrate(plan[j - 1]) + 0.15 do
                plan[j], plan[j - 1] = plan[j - 1], plan[j]
                j = j - 1
            end
        end
    end
    return plan
end

-- ติดลูป: เวลาพักรอบนี้ (เพิ่มเท่าตัวทุกครั้งที่ติดซ้ำ สูงสุด 30 นาที · ถ้าเกือบทั้งหมดเป็นโดนเตะ พักนานกว่านั้น)
local function loopCooldown()
    if not CFG.LOOP_BACKOFF then return CFG.LOOP_COOLDOWN, false end
    S.loopStreak = (S.loopStreak or 0) + 1
    local cd = math.min(1800, CFG.LOOP_COOLDOWN * (2 ^ (S.loopStreak - 1)))
    local kicks = 0
    for _, k in ipairs(S.recentK) do
        if k == "kick" then kicks = kicks + 1 end
    end
    local kickLoop = kicks >= 3 and kicks * 2 >= #S.recentK
    if kickLoop then cd = math.min(3600, cd * 2) end
    saveState()
    return math.floor(cd), kickLoop
end

-- หลังลองวิธีหนึ่งแล้วไม่สำเร็จ: ดูผลวาร์ปจริงแล้วจดไว้ว่าเซิร์ฟ/เป้าหมายไหนเข้าไม่ได้ จะได้ไม่ลองซ้ำ
local function afterAttempt(m, target, ok, online)
    local res, id = RT.tpResult, RT.lastTryId
    if m == "open" and id then
        if res == "GameFull" or res == "GameEnded" or res == "GameNotFound" or (ok and not RT.tpFailed and res ~= "IsTeleporting") then
            markBad(id)
            log("จำเซิร์ฟนี้ว่าเข้าไม่ได้ ไม่เลือกซ้ำ:", id:sub(1, 8))
        end
    end
    if m == "any" and (res == "Unauthorized" or res == "GameNotFound") and target ~= game.PlaceId then
        S.badTarget[tostring(target)] = os.time()
        saveState()
        log("เป้าหมาย", target, "เข้าไม่ได้ (" .. res .. ") ครั้งหน้าใช้แมพที่อยู่แทน")
    end
    if res == "Flooded" then
        RT.extraWait = 45
        log("วาร์ปถี่เกินไป (Flooded) พักเพิ่มก่อนลองใหม่")
    end
    if online then mnote(m, false) end
    RT.tpResult = nil
end

-- info = ผลจาก classify/mkInfo, opts.test = ปุ่มทดสอบ, opts.planned = รีจอยเองตั้งใจ (เช่น RAM สูง)
local function reconnect(info, opts)
    if RT.rejoining then return end
    opts = opts or {}
    info = info or mkInfo("unknown", "ไม่ทราบสาเหตุ")
    RT.rejoining = true
    local now = os.time()
    local why = whyText(info)
    S.disconnectAt = S.disconnectAt or now
    S.pending = opts.test and "test" or (opts.planned and "planned" or "drop")
    local pauseCd
    if S.pending == "drop" then
        S.drops = (S.drops or 0) + 1
        S.lastDisc = now
        S.lastReason = info.label
        table.insert(S.recent, now)
        table.insert(S.recentK, info.k or "?")
        pushEvent("หลุด", why)
        log("หลุดจากเกม:", why, (info.msg ~= "" and ("| " .. info.msg:sub(1, 60)) or ""))
        notify("Auto Rejoin: หลุดจากเกม (" .. why .. ") กำลังพยายามเข้าใหม่")
        if info.k == "idle" then bumpIdleLevel() end
        -- หลุดถี่ผิดปกติ (ติดลูป): พักก่อนแล้วค่อยลอง ไม่ยิง Teleport รัวๆ
        if recentCount() >= CFG.LOOP_LIMIT then
            local kickLoop
            pauseCd, kickLoop = loopCooldown()
            log("หลุดถี่ผิดปกติ (" .. #S.recent .. " ครั้งใน " .. span(CFG.LOOP_WINDOW) .. ") พัก " .. span(pauseCd)
                .. (kickLoop and " · โดนเตะซ้ำๆ" or ""))
            pushEvent("ติดลูป", "พัก " .. span(pauseCd))
            notify("Auto Rejoin: ติดลูป หลุด " .. #S.recent .. " ครั้งใน " .. span(CFG.LOOP_WINDOW) .. " พัก " .. span(pauseCd)
                .. (kickLoop and " (โดนเตะซ้ำๆ อาจมีระบบตรวจจับ ควรเข้ามาดู)" or "") .. " ก่อนลองใหม่")
        end
    else
        pushEvent(opts.test and "ทดสอบ" or "รีจอยเอง", why)
        log(opts.test and "ทดสอบ: จะวาร์ปจริงตามเป้าหมายรีจอย" or ("รีจอยเอง: " .. why))
    end

    -- สคิปฟาร์มที่อยากให้รันหลังรีจอย: ฝากไว้ในคิวของการวาร์ปครั้งถัดไป (ครั้งเดียวต่อการหลุด)
    if CFG.AFTER_REJOIN_FILE ~= "" and queue_on_teleport then
        queue_on_teleport('pcall(function() loadstring(readfile("' .. CFG.AFTER_REJOIN_FILE .. '"))() end)')
        log("ฝากสคิปฟาร์มไว้รันหลังรีจอย:", CFG.AFTER_REJOIN_FILE)
    end

    guard("reconnect", function()
        if pauseCd then
            local t0 = os.clock()
            while RT.auto and os.clock() - t0 < pauseCd do
                UI.set("หลุดถี่ พักก่อน", COL.warn, "ลองใหม่ใน " .. span(pauseCd - (os.clock() - t0)))
                task.wait(5)
            end
            pauseCd = nil
        end

        -- ลำดับวิธีเข้า: เซิร์ฟเดิม -> สุ่มเซิร์ฟ -> เซิร์ฟที่ว่าง แล้วสลับสุ่ม/ว่างต่อไป (เรียงใหม่ตามที่เคยสำเร็จบ่อย)
        -- แมตช์/เซิร์ฟส่วนตัว (ไม่ใช่หน้าหลักของเกม หรือเป็นเซิร์ฟส่วนตัว) วาร์ปกลับเซิร์ฟเดิมด้วย JobId ไม่ได้
        local offMain = (game.PrivateServerId ~= "") or (resolveTarget() ~= game.PlaceId)
        local reconnectFirst = CFG.CLICK_RECONNECT and offMain and CFG.REJOIN_PLACE_ID == 0
        local plan = buildPlan(info, offMain)
        log("แผนรีจอยรอบนี้:", reconnectFirst and "กดปุ่ม Reconnect ก่อน แล้ววาร์ป" or "วาร์ปตามลำดับ",
            "· ลำดับ:", table.concat(plan, ">"), "· PlaceId =", game.PlaceId,
            "· เซิร์ฟส่วนตัว =", tostring(game.PrivateServerId ~= ""))
        pcall(function()
            local _, _, found = findReconnectButton()
            if #found > 0 then log("ปุ่มบนหน้าต่างหลุด:", table.concat(found, " / ")) end
        end)

        local attempt = 0
        while true do
            if not RT.auto then
                log("ปิดรีจอยอัตโนมัติ หยุดพยายามเข้าใหม่")
                UI.set("ปิดรีจอยอยู่", COL.dim, "เปิดสวิตช์เพื่อเริ่มใหม่")
                RT.rejoining = false
                return
            end
            attempt = attempt + 1
            RT.tpResult, RT.lastTryId = nil, nil

            local online = waitOnline(CFG.ONLINE_WAIT)
            if not online and RT.auto then
                log("เช็คเน็ตไม่ผ่านนานเกิน", span(CFG.ONLINE_WAIT), "ลองสั่งเข้าเลย")
            end
            if online then flushOutbox() end

            -- แมตช์/เซิร์ฟส่วนตัว: กดปุ่ม Reconnect ของ Roblox ก่อน (เหมือนที่เรากดเอง) ไม่พาเข้าค่อยวาร์ปไปล็อบบี้
            if RT.auto and reconnectFirst then
                S.tryMethod, S.tryAt = "click", os.time()
                saveState()
                UI.set("หลุด! กดปุ่มเชื่อมต่อใหม่", COL.bad, "ครั้งที่ " .. attempt .. " · ปุ่ม Reconnect ของ Roblox")
                pressReconnect(CFG.RECONNECT_WAIT)
            end

            if RT.auto then
                local target, how = resolveTarget()
                local m = plan[attempt]
                if not m then m = (CFG.FIND_OPEN_SERVER and attempt % 2 == 1) and "open" or "any" end
                S.tryMethod, S.tryAt = m, os.time()
                saveState()
                local mlabel = (m == "same" and "เซิร์ฟเดิม") or (m == "open" and "เซิร์ฟที่ว่าง") or "เซิร์ฟสุ่ม"
                UI.set("หลุด! กำลังเข้าใหม่", COL.bad,
                    "ครั้งที่ " .. attempt .. " · " .. mlabel .. " · " .. target .. " (" .. how .. ")")
                RT.tpFailed = false
                local ok, err
                if m == "same" then
                    ok, err = pcall(function() TS:TeleportToPlaceInstance(game.PlaceId, game.JobId, lp) end)
                elseif m == "open" then
                    local id, why2 = findOpenServer(target)
                    if id then
                        RT.lastTryId = id
                        ok, err = pcall(function() TS:TeleportToPlaceInstance(target, id, lp) end)
                    else
                        m, mlabel = "any", "เซิร์ฟสุ่ม"
                        S.tryMethod = "any"
                        log("หาเซิร์ฟที่ว่างไม่ได้ (" .. tostring(why2) .. ") ใช้เซิร์ฟสุ่มแทน")
                        ok, err = pcall(function() TS:Teleport(target, lp) end)
                    end
                else
                    ok, err = pcall(function() TS:Teleport(target, lp) end)
                end
                log("เข้าใหม่ครั้งที่", attempt, mlabel .. ":", ok and "ส่งคำสั่งแล้ว" or tostring(err))

                -- รอให้วาร์ปเสร็จ (ถ้าสำเร็จสคิปนี้จะถูกปิดไปกับเซิร์ฟเดิม) ล้มเหลวหรือค้างเกิน STUCK_SECONDS ไปวิธีถัดไป
                local t0 = os.clock()
                while RT.auto and os.clock() - t0 < CFG.STUCK_SECONDS do
                    task.wait(1)
                    local waited = os.clock() - t0
                    if (RT.tpFailed or not ok) and waited >= 3 then break end
                end
                if RT.auto then
                    log(RT.tpFailed and "วาร์ปล้มเหลว" or ((not ok) and "สั่งวาร์ปไม่ได้" or "ค้างเกิน " .. CFG.STUCK_SECONDS .. " วิ"), "-> ไปวิธีถัดไป")
                    afterAttempt(m, target, ok, online)
                end

                -- วิธีสำรอง: กดปุ่ม Reconnect/Rejoin บนหน้าต่างแจ้งหลุด
                if RT.auto and CFG.CLICK_RECONNECT then
                    S.tryMethod, S.tryAt = "click", os.time()
                    saveState()
                    pressReconnect(20)
                end
            end

            if RT.auto then
                -- รอแบบสุ่มเวลา ±20% (หลายบัญชี/หลายเครื่องจะไม่แห่ลองพร้อมกันตอน Roblox ล่ม)
                local delay = math.min(CFG.RETRY_DELAY * attempt, 120)
                delay = math.floor(delay * (0.8 + math.random() * 0.4)) + (RT.extraWait or 0)
                RT.extraWait = nil
                UI.set("ยังเข้าไม่ได้ รอลองใหม่", COL.warn, "รออีก " .. delay .. " วิ (เน็ตอาจยังไม่กลับมา)")
                task.wait(delay)
            end
        end
    end)
end

-- หยุดรีจอย (บัญชีเข้าซ้ำ / โดนแบน) จนกว่าผู้ใช้แตะสวิตช์เพื่อเริ่มใหม่
local function halt(info)
    local why = whyText(info)
    RT.halted = info
    RT.rejoining = true
    pushEvent("หยุด", why)
    log("หยุดรีจอย:", why, (info.msg ~= "" and ("| " .. info.msg:sub(1, 80)) or ""))
    UI.set("หยุดรีจอย: " .. info.label, COL.bad, "แตะสวิตช์เพื่อเริ่มเฝ้าใหม่")
    if UI.setSwitch then UI.setSwitch(false) end
    notify("Auto Rejoin: หยุดรีจอย (" .. why .. ") ต้องเข้ามาตรวจเอง")
end

-- ===================== เริ่มทำงาน =====================
local function main()
    log("PlaceId =", game.PlaceId, "· GameId =", game.GameId)
    log("ตรวจหลุดหลายสัญญาณ:", CFG.SMART_DETECT and "เปิด" or "ปิด",
        "· ตัวเชื่อมเครือข่าย:", RT.hadRep and "เห็น (ใช้ตัดสินได้)" or "ไม่เห็น (ใช้วิธีเดิมของ v3)")
    if LEGACY then log("พบสคริปต์รุ่นเก่ายังรันอยู่ในเซิร์ฟนี้ อาจรีจอยซ้อนกันจนกว่าจะรีจอยรอบหน้า") end

    -- เช็ค executor
    local caps = {
        { "writefile", writefile }, { "readfile", readfile },
        { "queue_on_teleport", queue_on_teleport },
        { "request", reqFn() },
        { "firesignal", firesignal }, { "getconnections", getconnections },
    }
    local missing = {}
    for _, c in ipairs(caps) do
        if not c[2] then table.insert(missing, c[1]) end
    end
    local hasVU = pcall(function() game:GetService("VirtualUser") end)
    if not hasVU then table.insert(missing, "VirtualUser") end
    local coreOk = false
    pcall(function() coreOk = game:GetService("CoreGui"):FindFirstChild("RobloxPromptGui") ~= nil end)
    if not coreOk then table.insert(missing, "CoreGui(RobloxPromptGui)") end
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
        local kind = S.pending or "drop"
        S.disconnectAt = nil
        S.pending = nil
        if kind == "drop" then
            S.reconnects = S.reconnects + 1
            -- วิธีที่ลองล่าสุดก่อนสคริปต์นี้เริ่มใหม่ = วิธีที่พากลับมาได้ (ไม่นับถ้าเกิน 5 นาที เผื่อผู้ใช้กดรีจอยเอง)
            if S.tryMethod and S.tryAt and os.time() - S.tryAt <= 300 then mnote(S.tryMethod, true) end
        end
        S.tryMethod, S.tryAt = nil, nil
        pushEvent("เข้าใหม่", "หลุดไป " .. span(down))
        log("กลับเข้าเกมสำเร็จ หลุดไป", span(down))
        if kind == "drop" then
            notify("Auto Rejoin: กลับเข้าเกมได้แล้ว หลุดไป " .. span(down) .. " (รวม " .. S.reconnects .. " ครั้ง)")
        end
        UI.set("กลับเข้าเกมสำเร็จ", COL.ok, "หลุดไป " .. span(down) .. " · เฝ้าดูต่อ")
        flushOutbox()
    else
        UI.set(RT.auto and "เฝ้าดูการหลุดอยู่" or "ปิดรีจอยอยู่", RT.auto and COL.ok or COL.dim, "")
    end

    UI.act.test = function()
        reconnect(mkInfo("test", "ทดสอบ (กดปุ่มเอง)"), { test = true })
    end

    -- อัปเดต UI เป็นระยะ: ตอนย่ออยู่และจางแล้วห่างขึ้นเป็น 5 วิ ประหยัดเครื่อง
    guard("ui", function()
        while UI.gui and UI.gui.Parent do
            pcall(UI.refresh)
            task.wait((UI.expanded or not UI.dimmed) and 1 or 5)
        end
    end)

    -- กันโดนเตะเพราะ AFK: ระดับ 1 = VirtualUser · 2 = + กดเมาส์ขวาแบบคลาสสิก · 3 = + ขยับเมาส์ผ่าน VirtualInputManager และถี่ขึ้น
    -- ถ้ายังโดนเตะ AFK ทั้งที่เปิดอยู่ (IDLE_LEVEL = 0) จะเพิ่มระดับเองแล้วจำข้ามการวาร์ป
    if CFG.ANTI_IDLE then
        local lvl = CFG.IDLE_LEVEL
        if type(lvl) ~= "number" or lvl < 1 then lvl = S.idleLevel or 1 end
        lvl = math.clamp(math.floor(lvl), 1, 3)
        RT.idleLevel = lvl
        local INTERVAL = { 540, 300, 150 }
        local VU, VIM
        pcall(function() VU = game:GetService("VirtualUser") end)
        pcall(function() VIM = game:GetService("VirtualInputManager") end)
        log("กัน AFK ระดับ", lvl, "· ทุก", INTERVAL[lvl], "วิ · VirtualUser:", tostring(VU ~= nil), "· VirtualInputManager:", tostring(VIM ~= nil))
        local function poke()
            if VU then
                pcall(function() VU:CaptureController(); VU:ClickButton2(Vector2.new(0, 0)) end)
                if lvl >= 2 then
                    pcall(function()
                        local cam = workspace.CurrentCamera
                        local cf = cam and cam.CFrame or CFrame.new()
                        VU:Button2Down(Vector2.new(0, 0), cf)
                        task.wait(0.15)
                        VU:Button2Up(Vector2.new(0, 0), cf)
                    end)
                end
            end
            if VIM and (lvl >= 3 or not VU) then
                pcall(function()
                    local cam = workspace.CurrentCamera
                    local vs = cam and cam.ViewportSize or Vector2.new(800, 600)
                    VIM:SendMouseMoveEvent(vs.X * 0.5 + 1, vs.Y * 0.5 + 1, game)
                    task.wait(0.05)
                    VIM:SendMouseMoveEvent(vs.X * 0.5, vs.Y * 0.5, game)
                end)
            end
            RT.idleHits = (RT.idleHits or 0) + 1
        end
        guard("antiidle", function()
            if not RT.idleConn then   -- ต่อ Idled ครั้งเดียว (ถ้างานนี้พังแล้วเริ่มใหม่ จะไม่ต่อซ้ำ)
                RT.idleConn = lp.Idled:Connect(function()
                    poke()
                    log("กัน AFK (Idled) ระดับ", lvl)
                end)
            end
            while true do
                task.wait(INTERVAL[lvl])
                poke()
            end
        end)
    end

    -- เฝ้าดูว่าหลุดไหม + เกมค้าง (ไม่มีตัวละครนาน) + RAM สูง
    -- ตัดสินจากหลายสัญญาณ: หน้าต่างแจ้งหลุด + รหัส error + "ยังเชื่อมเซิร์ฟอยู่จริงไหม" + เกมกำลังวาร์ปเองไหม
    guard("watch", function()
        local downSince, noCharSince, deadSince = nil, nil, nil
        local softSig, softAt = nil, -1e9
        local lastRam, ramHits, lastFlush = 0, 0, 0
        while true do
            task.wait(2)
            if RT.auto and not RT.rejoining then
                local up, msg, viaPrompt, coreSeen = disconnectInfo()
                local st = CFG.SMART_DETECT and sessionState() or "unknown"
                -- ไม่มีหน้าต่างจริง มีแต่ข้อความเก่าค้างใน GuiService ขณะที่ยังเชื่อมเซิร์ฟอยู่ = ไม่ใช่การหลุด
                if up and not viaPrompt and coreSeen and st == "alive" then up = false end
                if up then
                    noCharSince, deadSince = nil, nil
                    local info = classify(msg)
                    if CFG.SMART_DETECT and info.soft and st == "alive" then
                        -- วาร์ป/เข้าเกมล้มเหลว แต่ยังอยู่ในเซิร์ฟเดิมดีๆ = ไม่ได้หลุด ไม่ต้องรีจอย แค่ปิดหน้าต่าง
                        downSince = nil
                        if softSig ~= msg or os.clock() - softAt > 60 then
                            softSig, softAt = msg, os.clock()
                            log("ข้าม:", whyText(info), "แต่ยังเชื่อมเซิร์ฟอยู่ (ไม่ใช่การหลุด)")
                            UI.set("เฝ้าดูการหลุดอยู่", COL.ok, "ข้ามหน้าต่าง: " .. info.label .. " (ยังเชื่อมอยู่)")
                            dismissPrompt()
                        end
                    else
                        downSince = downSince or os.clock()
                        -- หลักฐานว่าหลุดจริงแล้ว (ตัวเชื่อมเครือข่ายหาย) ไม่ต้องรอนาน
                        local need = (st == "dead") and math.min(2, CFG.CONFIRM_SECONDS) or CFG.CONFIRM_SECONDS
                        if os.clock() - downSince >= need then
                            downSince = nil
                            if info.stop then halt(info) else reconnect(info) end
                        end
                    end
                else
                    downSince = nil
                    local tpNow = tpRecent()
                    if CFG.SMART_DETECT and CFG.SILENT_SECONDS > 0 and st == "dead" and not tpNow then
                        -- หลุดจากเซิร์ฟจริงแต่ไม่มีหน้าต่างแจ้ง (เช่น executor เข้า CoreGui ไม่ได้ / เกมซ่อนหน้าต่าง)
                        noCharSince = nil
                        deadSince = deadSince or os.clock()
                        if os.clock() - deadSince >= CFG.SILENT_SECONDS then
                            deadSince = nil
                            log("ไม่มีหน้าต่างแจ้ง แต่หลุดจากเซิร์ฟแล้ว (ตัวเชื่อมเครือข่ายหาย)")
                            reconnect(mkInfo("silent", "หลุดเงียบ (ไม่มีหน้าต่างแจ้ง)"))
                        end
                    else
                        deadSince = nil

                        -- เกมค้าง: ไม่มีตัวละครนานผิดปกติ (ไม่นับช่วงที่เกมกำลังวาร์ป)
                        if CFG.NO_CHAR_SECONDS > 0 and os.clock() - T0 > 30 and not tpNow then
                            local ch = lp.Character
                            local alive = ch and ch:FindFirstChildOfClass("Humanoid") and ch:FindFirstChild("HumanoidRootPart")
                            if alive then
                                noCharSince = nil
                            else
                                noCharSince = noCharSince or os.clock()
                                if os.clock() - noCharSince >= CFG.NO_CHAR_SECONDS then
                                    noCharSince = nil
                                    reconnect(mkInfo("stuck", "เกมค้าง (ไม่มีตัวละคร)"))
                                end
                            end
                        else
                            noCharSince = nil
                        end

                        -- RAM สูงต่อเนื่อง: รีจอยก่อนเกมแครชเอง
                        if CFG.RAM_LIMIT_MB > 0 and os.clock() - lastRam >= 30 then
                            lastRam = os.clock()
                            local mem = 0
                            pcall(function() mem = game:GetService("Stats"):GetTotalMemoryUsageMb() end)
                            if mem > CFG.RAM_LIMIT_MB then ramHits = ramHits + 1 else ramHits = 0 end
                            if ramHits >= 3 and os.clock() - T0 >= CFG.RAM_MIN_UPTIME then
                                ramHits = 0
                                reconnect(mkInfo("ram", "RAM สูง " .. math.floor(mem) .. " MB"), { planned = true })
                            end
                        end
                    end
                end
            else
                downSince, noCharSince, deadSince, ramHits = nil, nil, nil, 0
            end

            -- งานเบ็ดเตล็ด: ส่ง webhook ที่ค้างในคิว · ล้างสถานะติดลูปเมื่ออยู่นิ่งนานพอ
            if #S.outbox > 0 and os.clock() - lastFlush >= 30 then
                lastFlush = os.clock()
                flushOutbox()
            end
            if (S.loopStreak or 0) > 0 and os.clock() - T0 > CFG.LOOP_WINDOW then
                S.loopStreak = 0
                saveState()
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
