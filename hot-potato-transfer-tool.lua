--!nocheck
-- Hot Potato Guard v21 — Crazy + Last-Millisecond Targeted. Zero movement, touch-injection only.
-- https://www.roblox.com/games/72001091182267/Hot-Potato

------------------------------------------------------------
-- SERVICES
------------------------------------------------------------
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local TweenService      = game:GetService("TweenService")
local HttpService       = game:GetService("HttpService")
local SoundService      = game:GetService("SoundService")

local LocalPlayer = Players.LocalPlayer
local TARGET_PLACE = 72001091182267

------------------------------------------------------------
-- CONFIG (master switch + specific target + crazy)
------------------------------------------------------------
local DEFAULTS = { enabled = true, specific = false, targetId = 0, crazy = false, crazyInterval = 0.08, redirectRadius = 14, safety = true, safetyWindow = 1.6 }
local config = {}
for k, v in pairs(DEFAULTS) do config[k] = v end

local CFG_FILE = "hpg_config.json"
local HAS_FS = typeof(writefile) == "function" and typeof(readfile) == "function"

local function loadConfig()
    if not HAS_FS then return end
    local ok, data = pcall(readfile, CFG_FILE)
    if not ok or type(data) ~= "string" or data == "" then return end
    local ok2, t = pcall(function() return HttpService:JSONDecode(data) end)
    if not ok2 or type(t) ~= "table" then return end
    if type(t.enabled) == "boolean" then config.enabled = t.enabled end
    if type(t.specific) == "boolean" then config.specific = t.specific end
    if type(t.targetId) == "number" then config.targetId = t.targetId end
    if type(t.crazy) == "boolean" then config.crazy = t.crazy end
    if type(t.crazyInterval) == "number" then config.crazyInterval = math.clamp(t.crazyInterval, 0.02, 0.5) end
    if type(t.redirectRadius) == "number" then config.redirectRadius = math.clamp(t.redirectRadius, 5, 30) end
    if type(t.safety) == "boolean" then config.safety = t.safety end
    if type(t.safetyWindow) == "number" then config.safetyWindow = math.clamp(t.safetyWindow, 0.5, 5) end
end

local function saveConfig()
    if not HAS_FS then return end
    pcall(function() writefile(CFG_FILE, HttpService:JSONEncode(config)) end)
end

local BURST_AT = 3.5       -- countdown value that triggers the mega burst (only when NO specific target)

------------------------------------------------------------
-- STATE
------------------------------------------------------------
local state = {
    running = true,
    token = 0,
    tagged = false,
    shedding = false,
    vacating = false,
    vacateUsed = false,
    preFired = {},        -- pairs begun synchronously by a trigger
    preFireName = nil,
    lockedParts = {},
    conns = {},
    victimCD = {},
    hideSaved = {},
    pool = {},            -- cached eligible receivers (refreshed at ~20Hz)
    lastStrike = 0,
    lastCrazy = 0,
    crazyLastVictim = nil,
    rng = Random.new(),
    wasInRound = (LocalPlayer:GetAttribute("InRound") == true),
    deadSession = {},     -- userId -> true once they've died THIS ROUND (cleared on new round / respawn)
    walkPlayer = nil,     -- specific target we are walking toward (last resort)
    walkBaseWS = nil,
    stealUnlocked = false, -- true while roaming unlocked to steal the potato
    stats = { sheds = 0, denies = 0, totalTime = 0, lastHolder = "—", crazyFlips = 0 },
}

local GENV = (getgenv and getgenv()) or _G
local REGISTRY_KEY = "HPG_inst"

do
    local prev = GENV[REGISTRY_KEY]
    if typeof(prev) == "table" and typeof(prev.unload) == "function" then
        pcall(prev.unload)
    end
end

local function conn(signal, fn)
    local c = signal:Connect(fn)
    table.insert(state.conns, c)
    return c
end

------------------------------------------------------------
-- HELPERS
------------------------------------------------------------
local function mk(class, props)
    local inst = Instance.new(class)
    for k, v in pairs(props or {}) do inst[k] = v end
    return inst
end

local function corner(parent, radius)
    return mk("UICorner", { CornerRadius = UDim.new(0, radius), Parent = parent })
end

local function stroke(parent, color, thickness, transparency)
    return mk("UIStroke", {
        Color = color, Thickness = thickness or 1,
        Transparency = transparency or 0.4,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
        Parent = parent,
    })
end

local function grad(parent, c1, c2, rotation)
    return mk("UIGradient", {
        Color = ColorSequence.new(c1, c2),
        Rotation = rotation or 0,
        Parent = parent,
    })
end

local function isTaggedNow()
    return LocalPlayer:GetAttribute("IsTagged") == true
        or LocalPlayer:GetAttribute("TrainingTagged") == true
end

-- physical truth: the potato part sitting in my character (may arrive before
-- the IsTagged attribute does — this is the faster trigger)
local function potatoPresent()
    local char = LocalPlayer.Character
    if not char then return false end
    return char:FindFirstChild("TaggedPotato") ~= nil
        or char:FindFirstChild("TrainingPotato") ~= nil
end

local function tagContext()
    if LocalPlayer:GetAttribute("IsTagged") == true then return "round" end
    if LocalPlayer:GetAttribute("TrainingTagged") == true then return "train" end
    return nil
end

local POTATO_NAMES = { TaggedPotato = true, TrainingPotato = true, TagHitbox = true }

local function isPotatoAncestry(p)
    local cur = p
    local char = LocalPlayer.Character
    while cur and cur ~= char do
        if POTATO_NAMES[cur.Name] then return true end
        cur = cur.Parent
    end
    return false
end

local function potatoPartsOf(char)
    local out = {}
    if not char then return out end
    for _, n in ipairs({ "TaggedPotato", "TrainingPotato" }) do
        local p = char:FindFirstChild(n)
        if p then
            table.insert(out, p)
            local hb = p:FindFirstChild("TagHitbox")
            if hb then table.insert(out, hb) end
        end
    end
    return out
end

local function myHitboxParts()
    return potatoPartsOf(LocalPlayer.Character)
end

-- fast path: cached 3 main bodies per character. GetDescendants on every
-- strike was the single biggest cost in the hot path.
local _bodyCache = setmetatable({}, { __mode = "k" })
local function mainBodiesFast(p)
    local ch = p and p.Character
    if not ch then return {} end
    local cached = _bodyCache[ch]
    if cached then return cached end
    local out = {}
    local hrp = ch:FindFirstChild("HumanoidRootPart")
    local torso = ch:FindFirstChild("UpperTorso") or ch:FindFirstChild("Torso")
    local head = ch:FindFirstChild("Head")
    if hrp then table.insert(out, hrp) end
    if torso and torso ~= hrp then table.insert(out, torso) end
    if head and head ~= hrp then table.insert(out, head) end
    _bodyCache[ch] = out
    return out
end

------------------------------------------------------------
-- COLORS
------------------------------------------------------------
local COL = {
    bg      = Color3.fromRGB(12, 15, 20),
    panel   = Color3.fromRGB(17, 22, 30),
    card    = Color3.fromRGB(24, 30, 40),
    stroke  = Color3.fromRGB(45, 55, 70),
    off     = Color3.fromRGB(52, 61, 74),
    text    = Color3.fromRGB(233, 239, 246),
    sub     = Color3.fromRGB(138, 151, 165),
    dim     = Color3.fromRGB(95, 106, 120),
    accent  = Color3.fromRGB(255, 92, 56),
    accent2 = Color3.fromRGB(255, 166, 61),
    green   = Color3.fromRGB(52, 211, 153),
    red     = Color3.fromRGB(248, 113, 113),
    amber   = Color3.fromRGB(251, 191, 36),
    cyan    = Color3.fromRGB(56, 189, 248),
}

------------------------------------------------------------
-- GUI — dark, draggable, Right CTRL, status, unload, sliders
------------------------------------------------------------
loadConfig()

local guiContainer = (typeof(gethui) == "function" and gethui()) or LocalPlayer:WaitForChild("PlayerGui")

local screen = mk("ScreenGui", {
    Name = "HPG",
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    DisplayOrder = 9999,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    Parent = guiContainer,
})

local win = mk("CanvasGroup", {
    Name = "Window",
    Size = UDim2.fromOffset(400, 560),
    Position = UDim2.new(0.5, 0, 0.5, 0),
    AnchorPoint = Vector2.new(0.5, 0.5),
    BackgroundColor3 = COL.bg,
    BackgroundTransparency = 0.02,
    BorderSizePixel = 0,
    ClipsDescendants = true,
    GroupTransparency = 1,
    Parent = screen,
})
corner(win, 12)
stroke(win, COL.stroke, 1.2, 0.25)
local winScale = mk("UIScale", { Scale = 0.94, Parent = win })

local rim = mk("Frame", {
    Size = UDim2.new(1, -14, 0, 2),
    Position = UDim2.new(0, 7, 0, 0),
    BackgroundColor3 = COL.accent,
    BorderSizePixel = 0,
    Parent = win,
})
corner(rim, 2)
local rimGrad = grad(rim, COL.accent, COL.accent2, 0)

local header = mk("Frame", {
    Size = UDim2.new(1, 0, 0, 38),
    BackgroundTransparency = 1,
    Parent = win,
})

local logoBox = mk("Frame", {
    Size = UDim2.fromOffset(24, 24),
    Position = UDim2.fromOffset(12, 7),
    BackgroundColor3 = COL.accent,
    BorderSizePixel = 0,
    Parent = header,
})
corner(logoBox, 7)
grad(logoBox, COL.accent, COL.accent2, 25)
local logoIcon = mk("TextLabel", {
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    Text = "🥔",
    TextSize = 13,
    Font = Enum.Font.GothamBold,
    Parent = logoBox,
})

mk("TextLabel", {
    Size = UDim2.fromOffset(250, 16),
    Position = UDim2.fromOffset(44, 10),
    BackgroundTransparency = 1,
    Text = "HOT POTATO GUARD v21",
    TextColor3 = COL.text,
    TextSize = 13,
    Font = Enum.Font.GothamBold,
    TextXAlignment = Enum.TextXAlignment.Left,
    Parent = header,
})

local statusDot = mk("Frame", {
    Size = UDim2.fromOffset(9, 9),
    Position = UDim2.new(1, -24, 0, 14),
    BackgroundColor3 = COL.green,
    BorderSizePixel = 0,
    Parent = header,
})
corner(statusDot, 9)
local dotGlow = mk("Frame", {
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = COL.green,
    BackgroundTransparency = 0.75,
    BorderSizePixel = 0,
    ZIndex = 0,
    Parent = statusDot,
})
corner(dotGlow, 9)

-- master switch
local switch = mk("TextButton", {
    Name = "Switch",
    Size = UDim2.fromOffset(220, 52),
    Position = UDim2.new(0.5, -110, 0, 44),
    BackgroundColor3 = COL.off,
    BorderSizePixel = 0,
    Text = "",
    AutoButtonColor = false,
    Parent = win,
})
corner(switch, 26)
local switchStroke = stroke(switch, COL.stroke, 1.2, 0.4)
local switchGrad = grad(switch, COL.off, COL.off, 0)

local knob = mk("Frame", {
    Size = UDim2.fromOffset(44, 44),
    Position = UDim2.fromOffset(4, 4),
    BackgroundColor3 = Color3.fromRGB(228, 234, 241),
    BorderSizePixel = 0,
    Parent = switch,
})
corner(knob, 22)
mk("TextLabel", {
    Name = "KnobIcon",
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    Text = "🥔",
    TextSize = 17,
    Font = Enum.Font.GothamBold,
    Parent = knob,
})

local switchLabel = mk("TextLabel", {
    Size = UDim2.fromOffset(110, 46),
    Position = UDim2.fromOffset(62, 0),
    BackgroundTransparency = 1,
    Text = "ON",
    TextColor3 = Color3.fromRGB(255, 255, 255),
    TextSize = 15,
    Font = Enum.Font.GothamBold,
    TextXAlignment = Enum.TextXAlignment.Left,
    Parent = switch,
})

-- specific row
local specRow = mk("Frame", {
    Size = UDim2.new(1, -24, 0, 38),
    Position = UDim2.fromOffset(12, 102),
    BackgroundColor3 = COL.panel,
    BorderSizePixel = 0,
    Parent = win,
})
corner(specRow, 9)
stroke(specRow, COL.stroke, 1, 0.5)

mk("TextLabel", {
    Size = UDim2.fromOffset(90, 34),
    Position = UDim2.fromOffset(10, 0),
    BackgroundTransparency = 1,
    Text = "🎯 SPECIFIC",
    TextColor3 = COL.text,
    TextSize = 12,
    Font = Enum.Font.GothamBold,
    TextXAlignment = Enum.TextXAlignment.Left,
    Parent = specRow,
})

local targetLabel = mk("TextLabel", {
    Size = UDim2.new(1, -92, 0, 34),
    Position = UDim2.fromOffset(100, 0),
    BackgroundTransparency = 1,
    Text = "target: none",
    TextColor3 = COL.sub,
    TextSize = 11,
    Font = Enum.Font.GothamMedium,
    TextXAlignment = Enum.TextXAlignment.Right,
    TextTruncate = Enum.TextTruncate.AtEnd,
    Parent = specRow,
})

local specTrack = mk("TextButton", {
    Size = UDim2.fromOffset(46, 24),
    Position = UDim2.new(1, -56, 0.5, -12),
    BackgroundColor3 = COL.off,
    BorderSizePixel = 0,
    Text = "",
    AutoButtonColor = false,
    Parent = specRow,
})
corner(specTrack, 12)
local specStroke = stroke(specTrack, COL.stroke, 1.2, 0.4)
local specKnob = mk("Frame", {
    Size = UDim2.fromOffset(18, 18),
    Position = UDim2.fromOffset(3, 3),
    BackgroundColor3 = Color3.fromRGB(228, 234, 241),
    BorderSizePixel = 0,
    Parent = specTrack,
})
corner(specKnob, 9)

-- crazy row (random ping-pong, zero movement)
local crazyRow = mk("Frame", {
    Size = UDim2.new(1, -24, 0, 38),
    Position = UDim2.fromOffset(12, 146),
    BackgroundColor3 = COL.panel,
    BorderSizePixel = 0,
    Parent = win,
})
corner(crazyRow, 9)
stroke(crazyRow, COL.stroke, 1, 0.5)

mk("TextLabel", {
    Size = UDim2.fromOffset(110, 34),
    Position = UDim2.fromOffset(10, 0),
    BackgroundTransparency = 1,
    Text = "🤪 CRAZY",
    TextColor3 = COL.text,
    TextSize = 12,
    Font = Enum.Font.GothamBold,
    TextXAlignment = Enum.TextXAlignment.Left,
    Parent = crazyRow,
})

local crazyLabel = mk("TextLabel", {
    Size = UDim2.new(1, -92, 0, 34),
    Position = UDim2.fromOffset(110, 0),
    BackgroundTransparency = 1,
    Text = "random chaos",
    TextColor3 = COL.sub,
    TextSize = 11,
    Font = Enum.Font.GothamMedium,
    TextXAlignment = Enum.TextXAlignment.Right,
    TextTruncate = Enum.TextTruncate.AtEnd,
    Parent = crazyRow,
})

local crazyTrack = mk("TextButton", {
    Size = UDim2.fromOffset(46, 24),
    Position = UDim2.new(1, -56, 0.5, -12),
    BackgroundColor3 = COL.off,
    BorderSizePixel = 0,
    Text = "",
    AutoButtonColor = false,
    Parent = crazyRow,
})
corner(crazyTrack, 12)
local crazyStroke = stroke(crazyTrack, COL.stroke, 1.2, 0.4)
local crazyKnob = mk("Frame", {
    Size = UDim2.fromOffset(18, 18),
    Position = UDim2.fromOffset(3, 3),
    BackgroundColor3 = Color3.fromRGB(228, 234, 241),
    BorderSizePixel = 0,
    Parent = crazyTrack,
})
corner(crazyKnob, 9)

-- safety row: when ON, the script goes fully passive in the last N seconds
-- before the explosion so you never die from your own actions.
local safetyRow = mk("Frame", {
    Size = UDim2.new(1, -24, 0, 38),
    Position = UDim2.fromOffset(12, 190),
    BackgroundColor3 = COL.panel,
    BorderSizePixel = 0,
    Parent = win,
})
corner(safetyRow, 9)
stroke(safetyRow, COL.stroke, 1, 0.5)

mk("TextLabel", {
    Size = UDim2.fromOffset(90, 34),
    Position = UDim2.fromOffset(10, 0),
    BackgroundTransparency = 1,
    Text = "🛡 SAFETY",
    TextColor3 = COL.text,
    TextSize = 12,
    Font = Enum.Font.GothamBold,
    TextXAlignment = Enum.TextXAlignment.Left,
    Parent = safetyRow,
})

local safetyLabel = mk("TextLabel", {
    Size = UDim2.new(1, -92, 0, 34),
    Position = UDim2.fromOffset(100, 0),
    BackgroundTransparency = 1,
    Text = "passive before blast",
    TextColor3 = COL.sub,
    TextSize = 11,
    Font = Enum.Font.GothamMedium,
    TextXAlignment = Enum.TextXAlignment.Right,
    TextTruncate = Enum.TextTruncate.AtEnd,
    Parent = safetyRow,
})

local safetyTrack = mk("TextButton", {
    Size = UDim2.fromOffset(46, 24),
    Position = UDim2.new(1, -56, 0.5, -12),
    BackgroundColor3 = COL.off,
    BorderSizePixel = 0,
    Text = "",
    AutoButtonColor = false,
    Parent = safetyRow,
})
corner(safetyTrack, 12)
local safetyStroke = stroke(safetyTrack, COL.stroke, 1.2, 0.4)
local safetyKnob = mk("Frame", {
    Size = UDim2.fromOffset(18, 18),
    Position = UDim2.fromOffset(3, 3),
    BackgroundColor3 = Color3.fromRGB(228, 234, 241),
    BorderSizePixel = 0,
    Parent = safetyTrack,
})
corner(safetyKnob, 9)

local function paintSafety(animated)
    local on = config.safety == true
    local info = TweenInfo.new(animated and 0.16 or 0, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    TweenService:Create(safetyKnob, info, { Position = UDim2.fromOffset(on and 25 or 3, 3) }):Play()
    TweenService:Create(safetyTrack, info, {
        BackgroundColor3 = on and COL.green or COL.off,
    }):Play()
    TweenService:Create(safetyStroke, info, {
        Color = on and COL.green or COL.stroke,
        Transparency = on and 0.15 or 0.4,
    }):Play()
    safetyLabel.Text = on and ("passive last %.1fs"):format(config.safetyWindow) or "passive before blast"
    safetyLabel.TextColor3 = on and COL.green or COL.sub
end

safetyTrack.Activated:Connect(function()
    config.safety = not config.safety
    paintSafety(true)
    saveConfig()
    if config.safety then
        setStatus(("🛡 SAFETY ON — passive last %.1fs"):format(config.safetyWindow), "ok")
    else
        setStatus(config.enabled and "READY — touch denial armed" or "OFF — fully passive",
            config.enabled and "ok" or "idle")
    end
end)
paintSafety(false)

-- sliders: crazy speed + redirect radius + safety window (type a number or drag the bar)
local sliderRefresh = {}
local function createSlider(yPos, title, minV, maxV, getV, setV, fmt)
    local row = mk("Frame", {
        Size = UDim2.new(1, -24, 0, 36),
        Position = UDim2.fromOffset(12, yPos),
        BackgroundColor3 = COL.panel,
        BorderSizePixel = 0,
        Parent = win,
    })
    corner(row, 9)
    stroke(row, COL.stroke, 1, 0.5)
    mk("TextLabel", {
        Size = UDim2.fromOffset(96, 36),
        Position = UDim2.fromOffset(10, 0),
        BackgroundTransparency = 1,
        Text = title,
        TextColor3 = COL.sub,
        TextSize = 11,
        Font = Enum.Font.GothamBold,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = row,
    })
    local numBox = mk("TextBox", {
        Size = UDim2.fromOffset(52, 22),
        Position = UDim2.fromOffset(108, 7),
        BackgroundColor3 = COL.card,
        BorderSizePixel = 0,
        TextColor3 = COL.text,
        TextSize = 11,
        Font = Enum.Font.GothamBold,
        Text = fmt(getV()),
        ClearTextOnFocus = false,
        Parent = row,
    })
    corner(numBox, 6)
    stroke(numBox, COL.stroke, 1, 0.6)
    local bar = mk("Frame", {
        Size = UDim2.new(1, -176, 0, 14),
        Position = UDim2.fromOffset(168, 11),
        BackgroundColor3 = COL.card,
        BorderSizePixel = 0,
        Parent = row,
    })
    corner(bar, 7)
    stroke(bar, COL.stroke, 1, 0.6)
    local fill = mk("Frame", {
        Size = UDim2.fromScale(0.5, 1),
        BackgroundColor3 = COL.accent,
        BorderSizePixel = 0,
        Parent = bar,
    })
    corner(fill, 7)
    grad(fill, COL.accent, COL.accent2, 0)
    local handle = mk("Frame", {
        Size = UDim2.fromOffset(16, 22),
        Position = UDim2.new(0.5, -8, 0.5, -11),
        BackgroundColor3 = Color3.fromRGB(228, 234, 241),
        BorderSizePixel = 0,
        Parent = bar,
    })
    corner(handle, 8)
    local function refresh()
        local p = math.clamp((getV() - minV) / (maxV - minV), 0, 1)
        fill.Size = UDim2.new(p, 0, 1, 0)
        handle.Position = UDim2.new(p, -8, 0.5, -11)
        numBox.Text = fmt(getV())
    end
    table.insert(sliderRefresh, refresh)
    local function valueFromX(px)
        local abs = bar.AbsolutePosition
        local sz = bar.AbsoluteSize.X
        if sz <= 0 then return getV() end
        local p = math.clamp((px - abs.X) / sz, 0, 1)
        return minV + p * (maxV - minV)
    end
    local dragging = false
    local barBtn = mk("TextButton", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Text = "",
        AutoButtonColor = false,
        ZIndex = 5,
        Parent = bar,
    })
    barBtn.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            setV(valueFromX(input.Position.X))
            refresh()
        end
    end)
    do
        local downConn = conn(UserInputService.InputEnded, function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                dragging = false
            end
        end)
    end
    do
        local moveConn = conn(UserInputService.InputChanged, function(input)
            if not dragging then return end
            if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
                setV(valueFromX(input.Position.X))
                refresh()
            end
        end)
    end
    numBox.FocusLost:Connect(function(enter)
        if enter then
            local n = tonumber(numBox.Text)
            if n then setV(n) end
            refresh()
        end
    end)
    refresh()
    return refresh
end

-- fast ping-pong interval: 0.02s .. 0.50s (0.03s = laser-fast, 0.08s = very crazy)
createSlider(190, "⚡ FLIP SPEED", 0.02, 0.5,
    function() return config.crazyInterval end,
    function(v) config.crazyInterval = math.clamp(v, 0.02, 0.5) saveConfig() end,
    function(v) return string.format("%.2fs", v) end)

-- pre-contact redirect radius: 5 .. 30 studs
createSlider(232, "📏 REDIRECT", 5, 30,
    function() return config.redirectRadius end,
    function(v) config.redirectRadius = math.clamp(v, 5, 30) saveConfig() end,
    function(v) return string.format("%dst", math.floor(v)) end)

-- safety window: 0.5 .. 5.0 seconds before blast
createSlider(274, "🛡 SAFETY WINDOW", 0.5, 5.0,
    function() return config.safetyWindow end,
    function(v) config.safetyWindow = math.clamp(v, 0.5, 5.0) saveConfig() paintSafety(false) end,
    function(v) return string.format("%.1fs", v) end)

-- push the picker down to make room for the safety slider
-- (keep listFrame size consistent)
-- player picker list (live: join / lobby / round / holder / dead flipped instantly)
local listFrame = mk("ScrollingFrame", {
    Name = "Picker",
    Size = UDim2.new(1, -24, 0, 158),
    Position = UDim2.fromOffset(12, 316),
    BackgroundColor3 = COL.panel,
    BackgroundTransparency = 0.4,
    BorderSizePixel = 0,
    ScrollBarThickness = 4,
    ScrollBarImageColor3 = COL.stroke,
    ScrollBarImageTransparency = 0.2,
    CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollingDirection = Enum.ScrollingDirection.Y,
    Parent = win,
})
corner(listFrame, 9)
stroke(listFrame, COL.stroke, 1, 0.5)

local _listLayout = mk("UIListLayout", {
    Padding = UDim.new(0, 3),
    SortOrder = Enum.SortOrder.LayoutOrder,
    Parent = listFrame,
})
local _listPad = mk("UIPadding", {
    PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6),
    PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6),
    Parent = listFrame,
})

local listEmpty = mk("TextLabel", {
    Size = UDim2.new(1, -12, 0, 24),
    Position = UDim2.fromOffset(6, 6),
    BackgroundTransparency = 1,
    Text = "no players yet…",
    TextColor3 = COL.dim,
    TextSize = 11,
    Font = Enum.Font.GothamMedium,
    TextXAlignment = Enum.TextXAlignment.Center,
    Parent = listFrame,
})

local statusLabel = mk("TextLabel", {
    Size = UDim2.new(1, -24, 0, 16),
    Position = UDim2.fromOffset(12, 438),
    BackgroundTransparency = 1,
    Text = "booting…",
    TextColor3 = COL.text,
    TextSize = 11,
    Font = Enum.Font.GothamMedium,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd,
    Parent = win,
})

local footer = mk("Frame", {
    Size = UDim2.new(1, -24, 0, 30),
    Position = UDim2.fromOffset(12, 458),
    BackgroundColor3 = COL.panel,
    BorderSizePixel = 0,
    Parent = win,
})
corner(footer, 8)
stroke(footer, COL.stroke, 1, 0.5)

local statsLabel = mk("TextLabel", {
    Size = UDim2.new(1, -110, 1, 0),
    Position = UDim2.fromOffset(10, 0),
    BackgroundTransparency = 1,
    Text = "PASS 0 · DENY 0",
    TextColor3 = COL.sub,
    TextSize = 10,
    Font = Enum.Font.GothamMedium,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd,
    Parent = footer,
})

local unloadBtn = mk("TextButton", {
    Size = UDim2.fromOffset(82, 22),
    Position = UDim2.new(1, -90, 0.5, -11),
    BackgroundColor3 = COL.red,
    BorderSizePixel = 0,
    Text = "UNLOAD",
    TextColor3 = Color3.fromRGB(255, 245, 245),
    TextSize = 10,
    Font = Enum.Font.GothamBold,
    AutoButtonColor = false,
    Parent = footer,
})
corner(unloadBtn, 7)
grad(unloadBtn, Color3.fromRGB(224, 86, 86), Color3.fromRGB(190, 54, 54), 25)

------------------------------------------------------------
-- STATUS / SWITCHES
------------------------------------------------------------
local lockCharacter, unlockAll, restorePotato, stopWalk, vacateValve -- forward declarations

local _lastStatusText, _lastStatusKind
local function setStatus(text, kind)
    if text == _lastStatusText and kind == _lastStatusKind then return end
    _lastStatusText, _lastStatusKind = text, kind
    statusLabel.Text = text or ""
    local color = COL.green
    if kind == "warn" then color = COL.amber
    elseif kind == "bad" then color = COL.red
    elseif kind == "info" then color = COL.cyan
    elseif kind == "idle" then color = COL.sub end
    statusDot.BackgroundColor3 = color
    dotGlow.BackgroundColor3 = color
    TweenService:Create(statusDot, TweenInfo.new(0.12, Enum.EasingStyle.Back), {
        Size = UDim2.fromOffset(13, 13),
    }):Play()
    TweenService:Create(statusDot, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Size = UDim2.fromOffset(9, 9),
    }):Play()
end

local function refreshStats()
    local avg = ""
    if state.stats.sheds > 0 then
        avg = string.format(" · %.2fs", state.stats.totalTime / state.stats.sheds)
    end
    statsLabel.Text = string.format("PASS %d · DENY %d · CRAZY %d%s",
        state.stats.sheds, state.stats.denies, state.stats.crazyFlips, avg)
end

task.spawn(function()
    while state.running do
        TweenService:Create(dotGlow, TweenInfo.new(0.9, Enum.EasingStyle.Sine), {
            BackgroundTransparency = 0.45,
        }):Play()
        task.wait(0.9)
        TweenService:Create(dotGlow, TweenInfo.new(0.9, Enum.EasingStyle.Sine), {
            BackgroundTransparency = 0.85,
        }):Play()
        task.wait(0.9)
    end
end)

task.spawn(function()
    while state.running do
        TweenService:Create(logoIcon, TweenInfo.new(1.6, Enum.EasingStyle.Sine), {
            Position = UDim2.fromOffset(0, -1),
        }):Play()
        task.wait(1.6)
        TweenService:Create(logoIcon, TweenInfo.new(1.6, Enum.EasingStyle.Sine), {
            Position = UDim2.fromOffset(0, 1),
        }):Play()
        task.wait(1.6)
    end
end)

conn(RunService.RenderStepped, function()
    rimGrad.Offset = Vector2.new((os.clock() * 0.08) % 1, 0)
end)

local uiVisible = true
local function setVisible(v, instant)
    uiVisible = v
    if v then
        win.Visible = true
        if instant then
            win.GroupTransparency = 0
            winScale.Scale = 1
        else
            TweenService:Create(win, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                GroupTransparency = 0,
            }):Play()
            TweenService:Create(winScale, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
                Scale = 1,
            }):Play()
        end
    else
        local t1 = TweenService:Create(win, TweenInfo.new(0.13), { GroupTransparency = 1 })
        local t2 = TweenService:Create(winScale, TweenInfo.new(0.13), { Scale = 0.96 })
        t1:Play(); t2:Play()
        t1.Completed:Connect(function()
            if not uiVisible then win.Visible = false end
        end)
    end
end

local dragging = false
local dragStart, startPos
header.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        if win.AnchorPoint.X ~= 0 then
            local ap = win.AbsolutePosition
            win.AnchorPoint = Vector2.new(0, 0)
            win.Position = UDim2.fromOffset(ap.X, ap.Y)
        end
        dragging = true
        dragStart = input.Position
        startPos = win.AbsolutePosition
    end
end)
conn(UserInputService.InputChanged, function(input)
    if not dragging then return end
    if input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch then
        -- deliberately unclamped: the panel can be dragged anywhere,
        -- including mostly / fully off the edge of the screen
        local delta = input.Position - dragStart
        win.Position = UDim2.fromOffset(startPos.X + delta.X, startPos.Y + delta.Y)
    end
end)
conn(UserInputService.InputEnded, function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        dragging = false
    end
end)

conn(UserInputService.InputBegan, function(input)
    if input.KeyCode == Enum.KeyCode.RightControl then
        setVisible(not uiVisible)
    end
end)

-- master switch
local function paintSwitch(animated)
    local on = config.enabled == true
    local info = TweenInfo.new(animated and 0.18 or 0, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    TweenService:Create(knob, info, { Position = UDim2.fromOffset(on and 172 or 4, 4) }):Play()
    TweenService:Create(switch, info, {
        BackgroundColor3 = on and COL.accent or COL.off,
    }):Play()
    TweenService:Create(switchStroke, info, {
        Color = on and COL.accent2 or COL.stroke,
        Transparency = on and 0.15 or 0.4,
    }):Play()
    switchGrad.Color = ColorSequence.new(on and COL.accent or COL.off, on and COL.accent2 or COL.off)
    switchLabel.Text = on and "ON" or "OFF"
    switchLabel.TextXAlignment = on and Enum.TextXAlignment.Left or Enum.TextXAlignment.Right
    switchLabel.Position = on and UDim2.fromOffset(58, 0) or UDim2.fromOffset(0, 0)
end

-- specific switch
local function paintSpecific(animated)
    local on = config.specific == true
    local info = TweenInfo.new(animated and 0.16 or 0, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    TweenService:Create(specKnob, info, { Position = UDim2.fromOffset(on and 25 or 3, 3) }):Play()
    TweenService:Create(specTrack, info, {
        BackgroundColor3 = on and COL.accent or COL.off,
    }):Play()
    TweenService:Create(specStroke, info, {
        Color = on and COL.accent2 or COL.stroke,
        Transparency = on and 0.15 or 0.4,
    }):Play()
end

local function paintCrazy(animated)
    local on = config.crazy == true
    local info = TweenInfo.new(animated and 0.16 or 0, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    TweenService:Create(crazyKnob, info, { Position = UDim2.fromOffset(on and 25 or 3, 3) }):Play()
    TweenService:Create(crazyTrack, info, {
        BackgroundColor3 = on and COL.accent or COL.off,
    }):Play()
    TweenService:Create(crazyStroke, info, {
        Color = on and COL.accent2 or COL.stroke,
        Transparency = on and 0.15 or 0.4,
    }):Play()
    crazyLabel.Text = on and "random chaos ON" or "random chaos"
    crazyLabel.TextColor3 = on and COL.accent2 or COL.sub
end

local function onDisabled()
    setStatus("OFF — fully passive", "idle")
    unlockAll()
    restorePotato()
    stopWalk()
    if #state.preFired > 0 then
        for _, pr in ipairs(state.preFired) do
            pcall(firetouchinterest, pr[1], pr[2], true)
            pcall(firetouchinterest, pr[2], pr[1], true)
        end
        table.clear(state.preFired)
    end
end

local function onEnabled()
    lockCharacter()
    setStatus("READY — touch denial armed", "ok")
end

switch.Activated:Connect(function()
    config.enabled = not config.enabled
    paintSwitch(true)
    saveConfig()
    if config.enabled then
        onEnabled()
    else
        onDisabled()
    end
end)
paintSwitch(false)

specTrack.Activated:Connect(function()
    config.specific = not config.specific
    paintSpecific(true)
    saveConfig()
    if config.specific then
        setStatus("SPECIFIC ON — pick your target below", "info")
    else
        setStatus(config.enabled and "READY — touch denial armed" or "OFF — fully passive",
            config.enabled and "ok" or "idle")
    end
end)
paintSpecific(false)

crazyTrack.Activated:Connect(function()
    config.crazy = not config.crazy
    paintCrazy(true)
    saveConfig()
    if config.crazy then
        setStatus("🤪 CRAZY ON — random ping-pong, zero movement", "info")
    else
        setStatus(config.enabled and "READY — touch denial armed" or "OFF — fully passive",
            config.enabled and "ok" or "idle")
    end
end)
paintCrazy(false)

-- keep slider readouts in sync when config loads
do
    task.defer(function()
        task.wait(0.3)
        for _, fn in ipairs(sliderRefresh) do pcall(fn) end
    end)
end

------------------------------------------------------------
-- TOUCH LOCK
------------------------------------------------------------
lockCharacter = function()
    if not config.enabled or not state.running then return end
    local char = LocalPlayer.Character
    if not char then return end
    for _, d in ipairs(char:GetDescendants()) do
        if d:IsA("BasePart") and not isPotatoAncestry(d) then
            if d.CanTouch then
                state.lockedParts[d] = true
                pcall(function() d.CanTouch = false end)
            end
        end
    end
end

unlockAll = function()
    for part in pairs(state.lockedParts) do
        if part.Parent then
            pcall(function() part.CanTouch = true end)
        end
    end
    table.clear(state.lockedParts)
end

conn(LocalPlayer.CharacterAdded, function()
    unlockAll()
    task.wait(0.4)
    lockCharacter()
    -- instant lock for any part added afterwards
end)
do
    local function bindLockDesc(char)
        if not char then return end
        conn(char.DescendantAdded, function(d)
            if not state.running or not config.enabled then return end
            if state.stealUnlocked then return end
            if d:IsA("BasePart") and not isPotatoAncestry(d) and d.CanTouch then
                state.lockedParts[d] = true
                pcall(function() d.CanTouch = false end)
            end
        end)
    end
    if LocalPlayer.Character then bindLockDesc(LocalPlayer.Character) end
    conn(LocalPlayer.CharacterAdded, bindLockDesc)
end
conn(LocalPlayer.CharacterRemoving, function()
    unlockAll()
end)

do
    local sweepAcc = 0
    conn(RunService.Heartbeat, function(dt)
        if not state.running then return end
        sweepAcc += dt
        if sweepAcc < 0.25 then return end
        sweepAcc = 0
        if config.enabled and not state.stealUnlocked then
            lockCharacter()
        end
    end)
end


------------------------------------------------------------
-- VISUAL GUARD (presentation of the brief hold)
------------------------------------------------------------
local function hidePotato()
    local char = LocalPlayer.Character
    if not char then return end
    for _, n in ipairs({ "TaggedPotato", "TrainingPotato" }) do
        local p = char:FindFirstChild(n)
        if p then
            if p:IsA("BasePart") then
                state.hideSaved[p] = p.Transparency
                p.Transparency = 1
            end
            for _, d in ipairs(p:GetDescendants()) do
                if d:IsA("BasePart") then
                    state.hideSaved[d] = d.Transparency
                    d.Transparency = 1
                elseif d:IsA("BillboardGui") or d:IsA("SurfaceGui") then
                    state.hideSaved[d] = d.Enabled
                    d.Enabled = false
                elseif d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam") then
                    state.hideSaved[d] = d.Enabled
                    d.Enabled = false
                elseif d:IsA("Highlight") then
                    state.hideSaved[d] = d.Enabled
                    d.Enabled = false
                end
            end
        end
    end
    for _, d in ipairs(char:GetDescendants()) do
        if d:IsA("Highlight") and state.hideSaved[d] == nil then
            state.hideSaved[d] = d.Enabled
            d.Enabled = false
        end
    end
    local beep = SoundService:FindFirstChild("PotatoCountdownBeep")
    if beep and beep:IsA("Sound") then
        beep.Volume = 0
        beep:Stop()
    end
end

restorePotato = function()
    for inst, v in pairs(state.hideSaved) do
        if inst.Parent then
            pcall(function()
                if typeof(v) == "boolean" then
                    inst.Enabled = v
                else
                    inst.Transparency = v
                end
            end)
        end
    end
    table.clear(state.hideSaved)
    local beep = SoundService:FindFirstChild("PotatoCountdownBeep")
    if beep and beep:IsA("Sound") then
        beep.Volume = 0.7
    end
end

conn(SoundService.DescendantAdded, function(d)
    if state.tagged and d:IsA("Sound") and d.Name == "PotatoCountdownBeep" then
        d.Volume = 0
        d:Stop()
    end
end)

conn(RunService.RenderStepped, function()
    if not state.running then return end
    if state.tagged then
        local char = LocalPlayer.Character
        if char then
            local torso = char:FindFirstChild("Torso")
            local shoulder = torso and torso:FindFirstChild("Right Shoulder")
            if shoulder and shoulder:IsA("Motor6D") and shoulder.Transform ~= CFrame.identity then
                shoulder.Transform = CFrame.identity
            end
        end
        local beep = SoundService:FindFirstChild("PotatoCountdownBeep")
        if beep and beep:IsA("Sound") and beep.Volume > 0 then
            beep.Volume = 0
        end
    end
end)

local namecallOld
if typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function" then
    pcall(function()
        namecallOld = hookmetamethod(game, "__namecall", function(self, ...)
            if state.running and state.tagged
                and typeof(self) == "Instance" and self.Name == "PotatoCountdownBeep" then
                local method = getnamecallmethod()
                if method == "Play" or method == "Resume" then
                    return nil
                end
            end
            return namecallOld(self, ...)
        end)
    end)
end

------------------------------------------------------------
-- TARGETING + TOUCH INJECTION PRIMITIVES
------------------------------------------------------------
local function playerEligible(p)
    if p == LocalPlayer then return false end
    if state.deadSession[p.UserId] then return false end
    if p:GetAttribute("IsTagged") == true or p:GetAttribute("TrainingTagged") == true then
        return false
    end
    local ch = p.Character
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    return ch ~= nil and hum ~= nil and hum.Health > 0
end

local function refreshPool()
    -- cached receiver list: in-round (+in-training when that is your context),
    -- alive, not AFK preferred, nearest first. Refreshed at ~3Hz so the hot
    -- path (the tag callback) never has to scan the whole player list.
    local ctx = tagContext()
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    local myPos = hrp and hrp.Position or Vector3.zero
    local list = {}
    local now = os.clock()
    for _, p in ipairs(Players:GetPlayers()) do
        if playerEligible(p) then
            local inCtx
            if ctx == "train" then
                inCtx = p:GetAttribute("InTraining") == true
            elseif ctx == "round" then
                inCtx = p:GetAttribute("InRound") == true and p:GetAttribute("InFinalDuel") ~= true
            else
                inCtx = p:GetAttribute("InRound") == true
            end
            local victimStamp = state.victimCD[p]
            local cooled = (not victimStamp) or (now - victimStamp) > 6
            local phrp = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
            table.insert(list, {
                plr = p,
                dist = phrp and (phrp.Position - myPos).Magnitude or 1e9,
                ctxOk = inCtx == true,
                afk = p:GetAttribute("IsAFK") == true,
                cooled = cooled,
            })
        end
    end
    table.sort(list, function(a, b)
        local sa = (a.ctxOk and 0 or 2) + (a.afk and 1 or 0) + (a.cooled and 0 or 4)
        local sb = (b.ctxOk and 0 or 2) + (b.afk and 1 or 0) + (b.cooled and 0 or 4)
        if sa ~= sb then return sa < sb end
        return a.dist < b.dist
    end)
    state.pool = list
end

local function specificPlayer()
    if not config.specific or config.targetId == 0 then return nil end
    for _, entry in ipairs(state.pool) do
        if entry.plr.UserId == config.targetId then
            return entry.plr
        end
    end
    local p = Players:GetPlayerByUserId(config.targetId)
    if p and playerEligible(p) and p:GetAttribute("InRound") == true then
        return p
    end
    return nil
end
local function entriesFromPlayers(players, maxN)
    local out = {}
    for i, p in ipairs(players) do
        if i > maxN then break end
        local bodies = mainBodiesFast(p)
        if #bodies > 0 then
            table.insert(out, { plr = p, bodies = bodies })
        end
    end
    return out
end

local function allBodiesFast(p)
    local ch = p and p.Character
    if not ch then return {} end
    local out = {}
    for _, d in ipairs(ch:GetDescendants()) do
        if d:IsA("BasePart") then
            table.insert(out, d)
        end
    end
    if #out == 0 then
        return mainBodiesFast(p)
    end
    return out
end

local function entriesFromPlayersAll(players, maxN)
    local out = {}
    for i, p in ipairs(players) do
        if i > maxN then break end
        local bodies = allBodiesFast(p)
        if #bodies > 0 then
            table.insert(out, { plr = p, bodies = bodies })
        end
    end
    return out
end

local function poolPlayers(maxN)
    local out = {}
    for i, entry in ipairs(state.pool) do
        if i > maxN then break end
        table.insert(out, entry.plr)
    end
    return out
end

local function buildPairs(sources, entries)
    local pairsList = {}
    for _, e in ipairs(entries) do
        for _, src in ipairs(sources) do
            if src and src.Parent then
                for _, dst in ipairs(e.bodies) do
                    if dst and dst.Parent then
                        table.insert(pairsList, { src, dst })
                    end
                end
            end
        end
    end
    return pairsList
end

local function beginPairs(pairsList)
    for _, pr in ipairs(pairsList) do
        pcall(firetouchinterest, pr[1], pr[2], false)
        pcall(firetouchinterest, pr[2], pr[1], false)
    end
end

local function endPairs(pairsList)
    for _, pr in ipairs(pairsList) do
        pcall(firetouchinterest, pr[1], pr[2], true)
        pcall(firetouchinterest, pr[2], pr[1], true)
    end
end

local function injectCycle(sources, entries)
    local pairsList = buildPairs(sources, entries)
    if #pairsList == 0 then return false end
    beginPairs(pairsList)
    RunService.Heartbeat:Wait()
    endPairs(pairsList)
    return true
end

-- specific-target pulse: holds the touch across two physics steps and re-arms
-- it, so the server cannot miss it because it arrived mid-step. Slower than a
-- single cycle, but it is the shot that actually lands on OUR player.
local function injectCycleSpecific(sources, entries)
    local pairsList = buildPairs(sources, entries)
    if #pairsList == 0 then return false end
    beginPairs(pairsList)
    RunService.Heartbeat:Wait()
    beginPairs(pairsList)
    RunService.Heartbeat:Wait()
    endPairs(pairsList)
    return true
end


-- pure injection build: no walking, no movement, no CFrame writes.
-- stopWalk is kept as a harmless no-op for the shared cleanup paths.
stopWalk = function()
    state.walkPlayer = nil
    state.walkBaseWS = nil
end

------------------------------------------------------------
-- DEATH TRACKING — per-round, auto-revived on respawn / new round
------------------------------------------------------------
local buildPicker -- forward declaration (defined with the picker below)

local function hookDeaths(p)
    if p == LocalPlayer then return end
    local function bind(char)
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if hum then
            conn(hum.Died, function()
                state.deadSession[p.UserId] = true
                if config.targetId == p.UserId then
                    config.targetId = 0
                    saveConfig()
                    setStatus(("TARGET DIED — %s is out this round"):format(p.Name), "warn")
                end
                buildPicker()
            end)
        end
    end
    if p.Character then bind(p.Character) end
    conn(p.CharacterAdded, function(char)
        -- respawn = alive again (new round / lobby return). This is what stops
        -- the list from staying stuck on "died" after the next round starts.
        if state.deadSession[p.UserId] then
            state.deadSession[p.UserId] = nil
        end
        state.victimCD[p] = nil
        bind(char)
        task.defer(buildPicker)
        task.defer(function() pcall(refreshPool) end)
    end)
    -- the instant a player enters a round again, they are alive again
    conn(p:GetAttributeChangedSignal("InRound"), function()
        if p:GetAttribute("InRound") == true then
            if state.deadSession[p.UserId] then state.deadSession[p.UserId] = nil end
            state.victimCD[p] = nil
        end
        task.defer(buildPicker)
    end)
    conn(p:GetAttributeChangedSignal("InTraining"), function()
        if p:GetAttribute("InTraining") == true then
            if state.deadSession[p.UserId] then state.deadSession[p.UserId] = nil end
            state.victimCD[p] = nil
        end
        task.defer(buildPicker)
    end)
    conn(p:GetAttributeChangedSignal("InFinalDuel"), function()
        task.defer(buildPicker)
    end)
    conn(p:GetAttributeChangedSignal("IsTagged"), function()
        task.defer(buildPicker)
    end)
    conn(p:GetAttributeChangedSignal("TrainingTagged"), function()
        task.defer(buildPicker)
    end)
end

-- global new-round reset: when WE enter a round, everyone alive again
conn(LocalPlayer:GetAttributeChangedSignal("InRound"), function()
    local now = LocalPlayer:GetAttribute("InRound") == true
    if now and not state.wasInRound then
        table.clear(state.deadSession)
        table.clear(state.victimCD)
        state.vacateUsed = false
        pcall(refreshPool)
        task.defer(buildPicker)
        setStatus("NEW ROUND — list reset, all alive", "ok")
    elseif not now and state.wasInRound then
        -- left the round (died / back to lobby): list must empty instantly
        task.defer(buildPicker)
    end
    state.wasInRound = now
end)

-- my own training state flips the list context too (round <-> training)
conn(LocalPlayer:GetAttributeChangedSignal("InTraining"), function()
    task.defer(buildPicker)
end)

------------------------------------------------------------
-- PICKER LIST (round-only: active in my round + alive, live add/remove)
------------------------------------------------------------
local pickerButtons = {} -- userId -> button

local function updateTargetLabel()
    local target = specificPlayer()
    if config.targetId == 0 then
        targetLabel.Text = "target: none"
    elseif target then
        targetLabel.Text = "target: " .. target.Name
    else
        targetLabel.Text = "target: (not in round)"
    end
    targetLabel.TextColor3 = target and COL.accent2 or COL.sub
end

buildPicker = function()
    -- ROUND-ONLY filter: only players active in MY round/training and alive.
    -- My own context decides the pool: training pros see training players,
    -- round players see round players. Lobby players never show.
    local myInTraining = LocalPlayer:GetAttribute("InTraining") == true
    local myInRound = LocalPlayer:GetAttribute("InRound") == true
    local function isVisible(p)
        if p == LocalPlayer then return false end
        if state.deadSession[p.UserId] then return false end
        if myInTraining then
            if p:GetAttribute("InTraining") ~= true then return false end
        else
            if not myInRound then return false end
            if p:GetAttribute("InRound") ~= true then return false end
            if p:GetAttribute("InFinalDuel") == true then return false end
        end
        local ch = p.Character
        local hum = ch and ch:FindFirstChildOfClass("Humanoid")
        if not (ch and hum and hum.Health > 0) then return false end
        return true
    end

    -- drop buttons for anyone who left the server OR left my round / died
    for userId, item in pairs(pickerButtons) do
        local p = Players:GetPlayerByUserId(userId)
        if not p or p == LocalPlayer or not isVisible(p) then
            item.root:Destroy()
            pickerButtons[userId] = nil
        end
    end

    -- collect only visible players: joiners appear the instant their
    -- InRound/InTraining attribute replicates and they spawn alive.
    local shown = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if isVisible(p) then
            table.insert(shown, p)
        end
    end
    table.sort(shown, function(a, b)
        local aHas = a:GetAttribute("IsTagged") == true or a:GetAttribute("TrainingTagged") == true
        local bHas = b:GetAttribute("IsTagged") == true or b:GetAttribute("TrainingTagged") == true
        if aHas ~= bHas then return aHas end
        return a.Name < b.Name
    end)
    listEmpty.Visible = #shown == 0
    if #shown == 0 then
        if myInTraining then
            listEmpty.Text = "no one in training yet…"
        elseif myInRound then
            listEmpty.Text = "no one in your round yet…"
        else
            listEmpty.Text = "not in a round yet…"
        end
    end

    local order = 0
    for _, p in ipairs(shown) do
        order += 1
        local item = pickerButtons[p.UserId]
        if not item then
            local root = mk("Frame", {
                Size = UDim2.new(1, -4, 0, 40),
                BackgroundColor3 = COL.card,
                BorderSizePixel = 0,
                Parent = listFrame,
            })
            corner(root, 9)
            local _rootStroke = stroke(root, COL.stroke, 1, 0.5)
            local ring = mk("Frame", {
                Size = UDim2.fromScale(1, 1),
                BackgroundColor3 = COL.accent,
                BackgroundTransparency = 1,
                BorderSizePixel = 0,
                Parent = root,
            })
            corner(ring, 9)
            local ringStroke = stroke(ring, COL.accent2, 1.5, 1)

            local avatarWrap = mk("Frame", {
                Size = UDim2.fromOffset(30, 30),
                Position = UDim2.fromOffset(3, 3),
                BackgroundColor3 = COL.panel,
                BorderSizePixel = 0,
                Parent = root,
            })
            corner(avatarWrap, 15)
            stroke(avatarWrap, COL.stroke, 1, 0.35)
            -- letter fallback: visible instantly, replaced by the headshot when it loads
            mk("TextLabel", {
                Size = UDim2.fromScale(1, 1),
                BackgroundTransparency = 1,
                Text = string.upper(string.sub(p.Name, 1, 1)),
                TextColor3 = COL.accent2,
                TextSize = 13,
                Font = Enum.Font.GothamBold,
                Parent = avatarWrap,
            })
            local avatar = mk("ImageLabel", {
                Size = UDim2.fromScale(1, 1),
                BackgroundTransparency = 1,
                BorderSizePixel = 0,
                Image = "",
                ScaleType = Enum.ScaleType.Crop,
                Parent = avatarWrap,
            })
            corner(avatar, 15)
            pcall(function()
                avatar.Image = Players:GetUserThumbnailFromUserId(
                    p.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
            end)

            local nameLabel = mk("TextLabel", {
                Size = UDim2.new(1, -52, 0, 16),
                Position = UDim2.fromOffset(38, 3),
                BackgroundTransparency = 1,
                Text = p.Name,
                TextColor3 = COL.text,
                TextSize = 12,
                Font = Enum.Font.GothamBold,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
                Parent = root,
            })
            local subLabel = mk("TextLabel", {
                Size = UDim2.new(1, -52, 0, 13),
                Position = UDim2.fromOffset(38, 19),
                BackgroundTransparency = 1,
                Text = "in round",
                TextColor3 = COL.sub,
                TextSize = 10,
                Font = Enum.Font.GothamMedium,
                TextXAlignment = Enum.TextXAlignment.Left,
                Parent = root,
            })

            local hit = mk("TextButton", {
                Size = UDim2.fromScale(1, 1),
                BackgroundTransparency = 1,
                Text = "",
                AutoButtonColor = false,
                Parent = root,
            })
            local uid = p.UserId
            hit.Activated:Connect(function()
                if state.deadSession[uid] then
                    setStatus("that player left your round — pick someone active", "warn")
                    return
                end
                if config.targetId == uid then
                    config.targetId = 0
                else
                    config.targetId = uid
                end
                saveConfig()
                buildPicker()
                local t = specificPlayer()
                if config.targetId ~= 0 and t then
                    setStatus(("TARGET LOCKED → %s"):format(t.Name), "info")
                end
            end)
            item = { root = root, ringStroke = ringStroke, nameLabel = nameLabel, subLabel = subLabel }
            pickerButtons[p.UserId] = item
        end
        item.root.LayoutOrder = order
        local isSel = config.targetId == p.UserId
        local has = p:GetAttribute("IsTagged") == true or p:GetAttribute("TrainingTagged") == true
        -- every shown row is already in-round + alive (filtered above),
        -- so the only paint states are holder vs. active player
        local key = (isSel and "S" or "-") .. (has and "H" or "-") .. (myInTraining and "T" or "R")
        if item._key ~= key then
            item._key = key
            item.nameLabel.Text = p.Name
            item.nameLabel.TextColor3 = has and COL.red or COL.text
            if has then
                item.subLabel.Text = "holding the potato"
                item.subLabel.TextColor3 = COL.red
            elseif myInTraining then
                item.subLabel.Text = "in training"
                item.subLabel.TextColor3 = COL.sub
            else
                item.subLabel.Text = "in round"
                item.subLabel.TextColor3 = COL.sub
            end
            item.root.BackgroundTransparency = 0
            TweenService:Create(item.root, TweenInfo.new(0.15), {
                BackgroundColor3 = isSel and Color3.fromRGB(56, 40, 28) or COL.card,
            }):Play()
            TweenService:Create(item.ringStroke, TweenInfo.new(0.15), {
                Transparency = isSel and 0.05 or 1,
            }):Play()
        end
        item.root.Visible = true
    end

    updateTargetLabel()
end

-- keep the list honest: only my round's alive players. Joins / round flips /
-- holder changes / deaths / leaves / restarts update instantly, never stale.
-- 50ms poll + instant attribute signals + join/leave hooks = always current.
do
    local acc = 0
    conn(RunService.Heartbeat, function(dt)
        if not state.running then return end
        acc += dt
        if acc < 0.05 then return end
        acc = 0
        buildPicker()
    end)
end
conn(Players.PlayerAdded, function(p)
    hookDeaths(p)
    task.defer(buildPicker)
end)
conn(Players.PlayerRemoving, function()
    task.defer(buildPicker)
end)
for _, p in ipairs(Players:GetPlayers()) do
    hookDeaths(p)
end
buildPicker()

------------------------------------------------------------
-- SHED ENGINE (inject only — nothing moves)
------------------------------------------------------------
local startShed

local function runShed()
    if state.shedding then return end
    state.shedding = true
    state.token += 1
    local token = state.token
    local t0 = os.clock()

    task.spawn(function()
        -- close out the pairs fired synchronously by a trigger
        if #state.preFired > 0 then
            RunService.Heartbeat:Wait()
            endPairs(state.preFired)
            table.clear(state.preFired)
        end

        local attempted = {}
        local lastName, lastPlr = nil, nil
        local deadline = t0 + 12

        while token == state.token and (isTaggedNow() or potatoPresent()) and os.clock() < deadline do
            local countdownVal = tonumber(LocalPlayer:GetAttribute("PotatoCountdown")) or 99
            -- SAFETY: in the danger window we SHED as fast as possible to the
            -- FARTHEST eligible player (so the potato travels max distance away
            -- from us before the blast). We also fire the vacate valve as backup.
            -- Never go idle.
            if config.safety and countdownVal <= (config.safetyWindow or 1.6) then
                setStatus(("🛡 SAFETY — %.1fs left, flinging to farthest"):format(countdownVal), "warn")
                pcall(function() if typeof(vacateValve) == "function" then vacateValve() end end)
                -- build a farthest-first pick list instead of nearest
                local farPool = {}
                for _, entry in ipairs(state.pool) do
                    if entry.plr ~= LocalPlayer then table.insert(farPool, entry) end
                end
                table.sort(farPool, function(a, b) return a.dist > b.dist end)
                local farPicks = {}
                for i, entry in ipairs(farPool) do
                    if i > 8 then break end
                    table.insert(farPicks, entry.plr)
                end
                if #farPicks == 0 then
                    -- fallback: any eligible player, farthest by position
                    local all = {}
                    for _, p in ipairs(Players:GetPlayers()) do
                        if p ~= LocalPlayer and playerEligible(p) then
                            local phrp = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
                            local d = phrp and (phrp.Position - (LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart") and LocalPlayer.Character.HumanoidRootPart.Position or Vector3.zero)).Magnitude or 0
                            table.insert(all, { p = p, d = d })
                        end
                    end
                    table.sort(all, function(a, b) return a.d > b.d end)
                    for i, e in ipairs(all) do
                        if i > 8 then break end
                        table.insert(farPicks, e.p)
                    end
                end
                if #farPicks > 0 then
                    local entries = entriesFromPlayers(farPicks, 8)
                    local sources = myHitboxParts()
                    if #sources > 0 and #entries > 0 then
                        local holdPairs = buildPairs(sources, entries)
                        if #holdPairs > 0 then
                            beginPairs(holdPairs)
                            for _ = 1, 4 do
                                if not (isTaggedNow() or potatoPresent()) then break end
                                RunService.Heartbeat:Wait()
                            end
                            endPairs(holdPairs)
                        end
                    end
                    state.stats.sheds += 1
                    state.stats.lastHolder = farPicks[1].Name
                    refreshStats()
                    if not (isTaggedNow() or potatoPresent()) then
                        setStatus(("SHED OK → %s (farthest)"):format(farPicks[1].Name), "ok")
                    end
                end
                task.wait(config.crazyInterval)
                continue
            end
            local urgent = countdownVal <= BURST_AT

            refreshPool()
            local picks
            local sp = specificPlayer()
            local isCrazy = config.crazy == true

            if isCrazy then
                -- CRAZY SHED: random victim every cycle (zero movement)
                -- DEATH FIX: countdown inherited across passes. At <=2.0s,
                -- stop random and EMERGENCY broadcast to everyone.
                if countdownVal <= 2.0 then
                    local every = {}
                    for _, entry in ipairs(state.pool) do
                        if entry.plr ~= LocalPlayer then table.insert(every, entry.plr) end
                    end
                    if #every == 0 then
                        for _, p in ipairs(Players:GetPlayers()) do
                            if p ~= LocalPlayer and playerEligible(p) and (p:GetAttribute("InRound") == true or p:GetAttribute("InTraining") == true) then
                                table.insert(every, p)
                            end
                        end
                    end
                    if #every > 0 then
                        picks = entriesFromPlayersAll(every, 8)
                        setStatus("🤪 EMERGENCY <2s — broadcasting", "bad")
                    else
                        picks = nil
                        setStatus("LAST SECOND — no safe target, vacating…", "bad")
                        pcall(function() if typeof(vacateValve) == "function" then vacateValve() end end)
                    end
                else
                    local victims = {}
                    for _, entry in ipairs(state.pool) do
                        if entry.plr ~= LocalPlayer then table.insert(victims, entry.plr) end
                    end
                    -- fallback scan if pool empty (new joiners / edge timing)
                    if #victims == 0 then
                        for _, p in ipairs(Players:GetPlayers()) do
                            if p ~= LocalPlayer and playerEligible(p) and (p:GetAttribute("InRound") == true or p:GetAttribute("InTraining") == true) then
                                table.insert(victims, p)
                            end
                        end
                    end
                    local victim
                    if #victims == 1 then
                        victim = victims[1]
                    elseif #victims > 1 then
                        for _ = 1, 10 do
                            victim = victims[state.rng:NextInteger(1, #victims)]
                            if victim ~= state.crazyLastVictim then break end
                            victim = nil
                        end
                        victim = victim or victims[state.rng:NextInteger(1, #victims)]
                    end
                    if victim then
                        state.crazyLastVictim = victim
                        picks = entriesFromPlayers({ victim }, 1)
                        setStatus(("TAGGED — 🤪 CRAZY → %s…"):format(victim.Name), "warn")
                    end
                end
            elseif sp then
                -- SPECIFIC MODE — EXCLUSIVE at 0.0s too. No burst hijack in the
                -- last millisecond: the targeted player lands it, nobody else.
                -- (Previously countdown<=1.5 fell through to a burst that could
                -- hand it to a backup instead of the target. Removed.)
                picks = entriesFromPlayers({ sp }, 1)
                if countdownVal <= 1.0 then
                    setStatus(("LAST SECOND — forcing it to %s…"):format(sp.Name), "bad")
                else
                    setStatus(("TAGGED — sending it to %s…"):format(sp.Name), "warn")
                end
            elseif urgent then
                -- mega burst: only when NO specific target is set
                local everyone = {}
                if sp then table.insert(everyone, sp) end
                for _, entry in ipairs(state.pool) do
                    if entry.plr ~= sp then
                        table.insert(everyone, entry.plr)
                    end
                end
                picks = entriesFromPlayers(everyone, 8)
                setStatus(("TAGGED — MEGA BURST → %d targets"):format(#picks), "warn")
            else
                local players = poolPlayers(8)
                local pick
                for _, p in ipairs(players) do
                    if not attempted[p] then
                        pick = p
                        break
                    end
                end
                pick = pick or players[1]
                if pick then
                    attempted[pick] = true
                    picks = entriesFromPlayers({ pick }, 1)
                    setStatus(("TAGGED — instant handoff → %s…"):format(pick.Name), "warn")
                end
            end

            if picks and #picks > 0 then
                lastName, lastPlr = picks[1].plr.Name, picks[1].plr
                -- ATOMIC HOLD: 6-frame continuous touch (stronger than 4).
                -- The server physics step sees one solid touch, not a blip.
                local isTargeted = (sp ~= nil and not isCrazy)
                local holdPairs = buildPairs(myHitboxParts(), picks)
                if #holdPairs > 0 then
                    beginPairs(holdPairs)
                    for _ = 1, 6 do
                        if not (isTaggedNow() or potatoPresent()) then break end
                        RunService.Heartbeat:Wait()
                        -- re-arm mid-hold so a lapsed begin can't go stale
                        if _ == 3 and (isTaggedNow() or potatoPresent()) then
                            beginPairs(holdPairs)
                        end
                    end
                    if isTaggedNow() or potatoPresent() then
                        beginPairs(holdPairs)
                        RunService.Heartbeat:Wait()
                    end
                    endPairs(holdPairs)
                end
                -- last-millisecond targeted triple-pulse: if the countdown is
                -- about to hit 0 and we still hold it, slam the SAME target
                -- two more times back-to-back before the server ticks 0.
                if isTargeted and countdownVal <= 1.0 and (isTaggedNow() or potatoPresent()) then
                    local sp2 = specificPlayer()
                    if sp2 then
                        local src = myHitboxParts()
                        local tp = entriesFromPlayers({ sp2 }, 1)
                        if #src > 0 and #tp > 0 then
                            injectCycleSpecific(src, tp)
                            if isTaggedNow() or potatoPresent() then
                                injectCycleSpecific(src, tp)
                            end
                        end
                    end
                end
            else
                setStatus("TAGGED — nobody to pass to yet…", "warn")
            end

            RunService.Heartbeat:Wait()
        end

        stopWalk()

        if not isTaggedNow() and not potatoPresent() then
            local dt = os.clock() - t0
            state.stats.sheds += 1
            state.stats.totalTime += dt
            state.stats.lastHolder = lastName or "—"
            if lastPlr then
                state.victimCD[lastPlr] = os.clock()
            end
            setStatus(("SHED OK → %s · %.2fs"):format(lastName or "?", dt), "ok")
            refreshStats()
        else
            setStatus("TAG HELD — hammering injections…", "bad")
            local emDeadline = os.clock() + 2
            while token == state.token and (isTaggedNow() or potatoPresent()) and os.clock() < emDeadline do
                refreshPool()
                local countdownVal = tonumber(LocalPlayer:GetAttribute("PotatoCountdown")) or 99
                local sp = specificPlayer()
                local picks
                if config.crazy then
                    local victims = {}
                    for _, entry in ipairs(state.pool) do
                        if entry.plr ~= LocalPlayer then table.insert(victims, entry.plr) end
                    end
                    if #victims == 0 then
                        for _, p in ipairs(Players:GetPlayers()) do
                            if playerEligible(p) and (p:GetAttribute("InRound") == true or p:GetAttribute("InTraining") == true) then
                                table.insert(victims, p)
                            end
                        end
                    end
                    local victim = #victims > 0 and victims[state.rng:NextInteger(1, #victims)] or nil
                    if victim then
                        picks = entriesFromPlayers({ victim }, 1)
                        if #picks > 0 then
                            injectCycle(myHitboxParts(), picks)
                            lastName = victim.Name
                        end
                    end
                elseif sp then
                    -- last-second emergency stays targeted-only, even at 0.0s
                    picks = entriesFromPlayers({ sp }, 1)
                    if #picks > 0 then
                        injectCycleSpecific(myHitboxParts(), picks)
                        lastName = sp.Name
                    end
                else
                    local everyone = {}
                    if sp then table.insert(everyone, sp) end
                    for _, entry in ipairs(state.pool) do
                        if entry.plr ~= sp then
                            table.insert(everyone, entry.plr)
                        end
                    end
                    picks = entriesFromPlayers(everyone, 8)
                    if #picks > 0 then
                        injectCycle(myHitboxParts(), picks)
                        lastName = picks[1].plr.Name
                    end
                end
                if not isTaggedNow() and not potatoPresent() then
                    state.stats.sheds += 1
                    state.stats.lastHolder = lastName or "—"
                    setStatus(("SHED OK (late burst) → %s"):format(state.stats.lastHolder), "ok")
                    refreshStats()
                    break
                end
                RunService.Heartbeat:Wait()
            end
        end

        state.shedding = false
        if isTaggedNow() or potatoPresent() then
            task.defer(runShed)
        end
    end)
end

startShed = function()
    if not config.enabled then return end
    if state.shedding then return end
    if not (isTaggedNow() or potatoPresent()) then return end
    runShed()
end

-- the strike: fires immediately, in whatever event we are currently in.
-- Uses the cached pool so this costs ~nothing — no player-list scans here.
-- Debounced: the attribute / ChildAdded / per-frame triggers can all fire
-- within one frame, and ending the previous pulse before it completes a
-- physics step makes the whole touch invisible to the server.
local function safetyActive()
    if not config.safety then return false end
    local cd = tonumber(LocalPlayer:GetAttribute("PotatoCountdown"))
    if cd == nil then return false end
    return cd <= (config.safetyWindow or 1.6)
end

local function strike()
    if not config.enabled or not state.running then return end
    -- always allow the initial fast pass when tagged; safety only blocks
    -- incoming/steal/redirect actions, never the shed we need to survive.
    local now = os.clock()
    if now - state.lastStrike < 0.008 then return end -- ~120Hz cap: one strike per frame max
    state.lastStrike = now

    if #state.preFired > 0 then
        endPairs(state.preFired)
        table.clear(state.preFired)
    end

    local sources = myHitboxParts()
    if #sources == 0 then return end

    local picks
    local sp = specificPlayer()
    if config.crazy then
        local victims = poolPlayers(8)
        if #victims == 0 then
            for _, p in ipairs(Players:GetPlayers()) do
                if playerEligible(p) and (p:GetAttribute("InRound") == true or p:GetAttribute("InTraining") == true) then
                    table.insert(victims, p)
                end
            end
        end
        local victim = #victims > 0 and victims[state.rng:NextInteger(1, #victims)] or nil
        if victim then
            picks = entriesFromPlayers({ victim }, 1)
            state.preFireName = victim.Name
        else
            picks = entriesFromPlayers(poolPlayers(4), 4)
            state.preFireName = picks[1] and picks[1].plr.Name or nil
        end
    elseif sp then
        picks = entriesFromPlayers({ sp }, 1)
        state.preFireName = sp.Name
    else
        picks = entriesFromPlayers(poolPlayers(4), 4)
        state.preFireName = picks[1] and picks[1].plr.Name or nil
    end
    local pairsList = buildPairs(sources, picks)
    if #pairsList > 0 then
        state.preFired = pairsList
        beginPairs(pairsList)
    end
end

------------------------------------------------------------
-- TRIGGERS (two independent, both same-frame)
------------------------------------------------------------
local function onTaggedChanged()
    local t = isTaggedNow()
    state.tagged = t
    if t then
        hidePotato()
        if config.enabled then
            if state.stealUnlocked then
                state.stealUnlocked = false
                lockCharacter()
            end
            stopWalk()
            strike()
            startShed()
        else
            setStatus("TAGGED — switch is OFF", "bad")
        end
    else
        restorePotato()
        stopWalk()
        state.vacateUsed = false
        if not state.shedding and config.enabled then
            setStatus("clear — watching", "idle")
        end
    end
end

conn(LocalPlayer:GetAttributeChangedSignal("IsTagged"), onTaggedChanged)
conn(LocalPlayer:GetAttributeChangedSignal("TrainingTagged"), onTaggedChanged)

-- per-frame physical watch: if the potato part is in my character, the tag is
-- live, whatever the attribute still says. This is the fastest possible signal.
do
    local acc = 0
    conn(RunService.RenderStepped, function(dt)
        if not state.running or not config.enabled then return end
        acc += dt
        if acc < 1 / 240 then return end -- RenderStepped can fire >120Hz; 240Hz cap is plenty
        acc = 0
        local present = potatoPresent()
        if present and not state.tagged then
            state.tagged = true
            hidePotato()
            if state.stealUnlocked then
                state.stealUnlocked = false
                lockCharacter()
            end
            stopWalk()
            strike()
            startShed()
        elseif not present and state.tagged and not isTaggedNow() then
            state.tagged = false
            restorePotato()
            if not state.shedding then
                setStatus("clear — watching", "idle")
            end
        end
    end)
end

do
    local charConn = nil
    local function bindChar(char)
        if charConn then charConn:Disconnect() end
        charConn = conn(char.ChildAdded, function(c)
            if c.Name == "TaggedPotato" or c.Name == "TrainingPotato" then
                if isTaggedNow() == false then
                    state.tagged = true
                end
                hidePotato()
                if config.enabled then
                    strike()
                    startShed()
                end
            end
        end)
    end
    if LocalPlayer.Character then bindChar(LocalPlayer.Character) end
    conn(LocalPlayer.CharacterAdded, bindChar)
end

refreshPool()
if isTaggedNow() or potatoPresent() then
    onTaggedChanged()
end

------------------------------------------------------------
-- PRE-CONTACT REDIRECT + close-call detector
------------------------------------------------------------
local redirectAcc = 0
local lastRedirectMsg = 0
local contactEpisode = nil

conn(RunService.Heartbeat, function(dt)
    if not state.running or not config.enabled then return end
    if safetyActive() then
        -- still try to shed while holding, but no redirect spam
        if isTaggedNow() or potatoPresent() then
            -- handled by runShed / strike already
        end
        return
    end
    redirectAcc += dt
    if redirectAcc < 0.05 then return end
    redirectAcc = 0

    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    local tagged = isTaggedNow() or potatoPresent()

    local holder, holderHRP
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and p:GetAttribute("IsTagged") == true then
            local ch = p.Character
            local phrp = ch and ch:FindFirstChild("HumanoidRootPart")
            local phum = ch and ch:FindFirstChildOfClass("Humanoid")
            if phrp and phum and phum.Health > 0 then
                holder, holderHRP = p, phrp
                break
            end
        end
    end

    if not hrp or tagged or not holder or LocalPlayer:GetAttribute("InRound") ~= true then
        if contactEpisode then
            if contactEpisode.approached and not tagged then
                state.stats.denies += 1
                setStatus(("TOUCH DENIED — %s could not tag you"):format(contactEpisode.holder.Name), "ok")
                refreshStats()
            end
            contactEpisode = nil
        end
        return
    end

    local dist = (hrp.Position - holderHRP.Position).Magnitude

    if dist < 7 then
        if not contactEpisode or contactEpisode.holder ~= holder then
            contactEpisode = { holder = holder, approached = true }
        end
    end

    if dist <= config.redirectRadius then
        -- specific target goes first, then the rest of the pool behind them
        local redirectTargets = {}
        local sp = specificPlayer()
        if sp and sp ~= holder then
            table.insert(redirectTargets, sp)
        end
        for _, entry in ipairs(state.pool) do
            if entry.plr ~= holder and entry.plr ~= sp then
                table.insert(redirectTargets, entry.plr)
            end
        end
        if #redirectTargets > 0 then
            local sources = potatoPartsOf(holder.Character)
            -- in specific mode the holder's potato is pushed ONLY to our target
            local picks
            if sp and sp ~= holder then
                picks = entriesFromPlayers({ sp }, 1)
            else
                picks = entriesFromPlayers(redirectTargets, 3)
            end
            if #sources > 0 and #picks > 0 then
                injectCycle(sources, picks)
                if os.clock() - lastRedirectMsg > 3 then
                    lastRedirectMsg = os.clock()
                    local toName = picks[1].plr.Name
                    setStatus(config.specific and ("PRE-REDIRECT → %s"):format(toName)
                        or ("PRE-REDIRECT — pushing the potato off %s"):format(holder.Name), "info")
                end
            end
        end
    end
end)

-- keep the receiver cache fresh so strikes never scan the player list (20Hz)
do
    local acc = 0
    conn(RunService.Heartbeat, function(dt)
        if not state.running then return end
        acc += dt
        if acc < 0.05 then return end
        acc = 0
        refreshPool()
    end)
end

------------------------------------------------------------
-- CRAZY MODE — random ping-pong, zero movement, laser-fast (<1s per hop)
-- 2-step working path (direct holder->victim is IGNORED by server,
-- neither part owned by us): (1) steal: OUR body -> holderPotato,
-- (2) shed: OUR potato -> random victim. Crazy repeats this so it
-- feels like re-picking Specific every flip (0.02-0.08s, well <1s).
-- DEATH FIX: countdown is INHERITED across passes. Stealing a
-- 1s countdown means YOU die in 1s. So:
--  - Only steal when holderCD > 2.0s (safe to inherit). If holder
--    is about to explode, DON'T steal — let them blow up.
--  - When YOU hold with <=2.0s, STOP random and EMERGENCY
--    broadcast to ALL victims + vacate valve. Never sit holding.
--  - If no victims while YOU hold, vacate instead of waiting.
------------------------------------------------------------
do
    task.spawn(function()
        local lastMsg = 0
        while state.running do
            if not config.enabled or not config.crazy then
                if state.stealUnlocked then
                    state.stealUnlocked = false
                    pcall(lockCharacter)
                end
                task.wait(0.05)
            else
                -- find current holder (us or anyone else)
                local holder = nil
                local holderCD = 99
                if isTaggedNow() or potatoPresent() then
                    holder = LocalPlayer
                    holderCD = tonumber(LocalPlayer:GetAttribute("PotatoCountdown")) or 99
                else
                    for _, p in ipairs(Players:GetPlayers()) do
                        if p:GetAttribute("IsTagged") == true or p:GetAttribute("TrainingTagged") == true then
                            local ch = p.Character
                            local hum = ch and ch:FindFirstChildOfClass("Humanoid")
                            if ch and hum and hum.Health > 0 then
                                holder = p
                                holderCD = tonumber(p:GetAttribute("PotatoCountdown")) or 99
                                break
                            end
                        end
                    end
                end

                if not holder then
                    lastMsg = 0
                    if state.stealUnlocked then
                        state.stealUnlocked = false
                        pcall(lockCharacter)
                    end
                    task.wait(config.crazyInterval)
                elseif holder == LocalPlayer then
                    -- WE HOLD: emergency if low, otherwise shed to random
                    -- SAFETY: in the danger window we still SHED fast (broadcast to
            -- everyone) so we don't die — that's the whole point. We just
            -- stop STEALING. Vacate fires as a backup.
            if holderCD <= 2.0 or safetyActive() then
                        -- EMERGENCY: broadcast to EVERYONE + vacate. No pause.
                        if state.stealUnlocked then
                            state.stealUnlocked = false
                            pcall(lockCharacter)
                        end
                        if os.clock() - lastMsg > 0.3 then
                            lastMsg = os.clock()
                            setStatus("🤪 EMERGENCY — <2s, broadcasting + vacate", "bad")
                            print("[HPG Crazy] EMERGENCY broadcast")
                        end
                        local everyone = {}
                        for _, p in ipairs(Players:GetPlayers()) do
                            if p ~= LocalPlayer and playerEligible(p) then
                                if p:GetAttribute("InRound") == true or p:GetAttribute("InTraining") == true then
                                    table.insert(everyone, p)
                                end
                            end
                        end
                        if #everyone > 0 then
                            local sources = myHitboxParts()
                            local entries = entriesFromPlayersAll(everyone, 8)
                            if #sources > 0 and #entries > 0 then
                                injectCycleSpecific(sources, entries)
                                if isTaggedNow() or potatoPresent() then
                                    injectCycleSpecific(sources, entries)
                                end
                            end
                            -- if still holding, also try vacate valve
                            if isTaggedNow() or potatoPresent() then
                                pcall(function() if typeof(vacateValve) == "function" then vacateValve() end end)
                            end
                        else
                            -- no victims at all: vacate so we don't die
                            pcall(function() if typeof(vacateValve) == "function" then vacateValve() end end)
                            local sources = myHitboxParts()
                            if #sources > 0 then
                                -- last ditch: touch every player (even lobby) so someone gets it
                                local all = {}
                                for _, p in ipairs(Players:GetPlayers()) do
                                    if p ~= LocalPlayer and playerEligible(p) then table.insert(all, p) end
                                end
                                local entries = entriesFromPlayersAll(all, 12)
                                if #entries > 0 then injectCycleSpecific(sources, entries) end
                            end
                        end
                        task.wait(config.crazyInterval)
                    else
                        -- safe to shed to ONE random victim
                        if state.stealUnlocked then
                            state.stealUnlocked = false
                            pcall(lockCharacter)
                        end
                        local victims = {}
                        for _, p in ipairs(Players:GetPlayers()) do
                            if p ~= LocalPlayer and playerEligible(p) then
                                if p:GetAttribute("InRound") == true or p:GetAttribute("InTraining") == true then
                                    table.insert(victims, p)
                                end
                            end
                        end
                        if #victims == 0 then
                            if os.clock() - lastMsg > 0.5 then
                                lastMsg = os.clock()
                                setStatus("🤪 CRAZY — no victims, vacating", "warn")
                            end
                            pcall(function() if typeof(vacateValve) == "function" then vacateValve() end end)
                            task.wait(config.crazyInterval)
                        else
                            local victim
                            if #victims == 1 then
                                victim = victims[1]
                            else
                                for _ = 1, 10 do
                                    victim = victims[state.rng:NextInteger(1, #victims)]
                                    if victim ~= state.crazyLastVictim then break end
                                    victim = nil
                                end
                                victim = victim or victims[state.rng:NextInteger(1, #victims)]
                            end
                            state.crazyLastVictim = victim
                            local sources = myHitboxParts()
                            local entries = #sources > 0 and entriesFromPlayersAll({ victim }, 1) or {}
                            if #sources > 0 and #entries > 0 then
                                injectCycleSpecific(sources, entries)
                                state.lastCrazy = os.clock()
                                state.stats.crazyFlips += 1
                                if state.stats.crazyFlips % 5 == 0 then refreshStats() end
                                if os.clock() - lastMsg > 0.25 then
                                    lastMsg = os.clock()
                                    setStatus(("🤪 CRAZY %s → %s (%d flips)"):format(holder.Name, victim.Name, state.stats.crazyFlips), "info")
                                    print(string.format("[HPG Crazy] %s -> %s", holder.Name, victim.Name))
                                end
                            end
                            task.wait(config.crazyInterval)
                        end
                    end
                else
                    -- SAFETY: stop stealing in the danger window, but still shed
                    -- (the branch above already handles the emergency broadcast)
                    -- HOLDER IS SOMEONE ELSE: only steal if SAFE (>2s left)
                    if holderCD <= 2.0 then
                        -- do NOT steal — we'd inherit a dying countdown.
                        -- Just try direct (harmless if ignored) or wait.
                        if state.stealUnlocked then
                            state.stealUnlocked = false
                            pcall(lockCharacter)
                        end
                        if os.clock() - lastMsg > 0.5 then
                            lastMsg = os.clock()
                            setStatus("🤪 CRAZY — waiting (holder <2s, not stealing)", "warn")
                        end
                        task.wait(config.crazyInterval)
                    else
                        local victims = {}
                        for _, p in ipairs(Players:GetPlayers()) do
                            if p ~= holder and p ~= LocalPlayer and playerEligible(p) then
                                if p:GetAttribute("InRound") == true or p:GetAttribute("InTraining") == true then
                                    table.insert(victims, p)
                                end
                            end
                        end
                        if #victims == 0 then
                            if os.clock() - lastMsg > 0.5 then
                                lastMsg = os.clock()
                                setStatus("🤪 CRAZY — no victims in round", "warn")
                            end
                            if state.stealUnlocked then
                                state.stealUnlocked = false
                                pcall(lockCharacter)
                            end
                            task.wait(config.crazyInterval)
                        else
                            local victim
                            if #victims == 1 then
                                victim = victims[1]
                            else
                                for _ = 1, 10 do
                                    victim = victims[state.rng:NextInteger(1, #victims)]
                                    if victim ~= state.crazyLastVictim then break end
                                    victim = nil
                                end
                                victim = victim or victims[state.rng:NextInteger(1, #victims)]
                            end
                            state.crazyLastVictim = victim
                            -- STEAL step fused with direct attempt:
                            -- myBodies->holderPotato (we own source, seen)
                            -- + holderPotato->victim (if server accepts direct)
                            if not state.stealUnlocked then
                                pcall(unlockAll)
                                state.stealUnlocked = true
                            end
                            local myBodies = mainBodiesFast(LocalPlayer)
                            local holderPotato = potatoPartsOf(holder.Character)
                            if #myBodies > 0 and #holderPotato > 0 then
                                local directEntries = entriesFromPlayersAll({ victim }, 1)
                                local allPairs = {}
                                for _, pr in ipairs(buildPairs(holderPotato, directEntries)) do
                                    table.insert(allPairs, pr)
                                end
                                local stealEntries = { { plr = holder, bodies = holderPotato } }
                                for _, pr in ipairs(buildPairs(myBodies, stealEntries)) do
                                    table.insert(allPairs, pr)
                                end
                                if #allPairs > 0 then
                                    -- fast <1s pulse: 2 heartbeats, re-armed
                                    beginPairs(allPairs)
                                    RunService.Heartbeat:Wait()
                                    beginPairs(allPairs)
                                    RunService.Heartbeat:Wait()
                                    endPairs(allPairs)
                                    state.lastCrazy = os.clock()
                                    state.stats.crazyFlips += 1
                                    if state.stats.crazyFlips % 5 == 0 then refreshStats() end
                                    if os.clock() - lastMsg > 0.25 then
                                        lastMsg = os.clock()
                                        setStatus(("🤪 CRAZY %s → %s (%d flips)"):format(holder.Name, victim.Name, state.stats.crazyFlips), "info")
                                        print(string.format("[HPG Crazy steal] %s -> %s (via us)", holder.Name, victim.Name))
                                    end
                                end
                            end
                            task.wait(config.crazyInterval)
                        end
                    end
                end
            end
        end
    end)
end

------------------------------------------------------------
-- FORCE STEAL (Specific mode): whoever holds it, it goes to the target.
-- Fires the holder's own hitbox into our chosen player every physics frame.
-- No waiting for us to be tagged. No movement. 1-frame touch cycles.
------------------------------------------------------------
do
    conn(RunService.Heartbeat, function()
        if not state.running or not config.enabled or not config.specific or config.crazy then return end
        -- safety: never force-steal in the danger window, but still shed
        -- (runShed handles the actual pass when we hold it).
        local target = specificPlayer()
        if not target then return end
        if target:GetAttribute("IsTagged") == true then return end -- already has it; done

        -- who holds it right now? (could be Player Z, or could be us)
        local holder
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= target and p:GetAttribute("IsTagged") == true then
                holder = p
                break
            end
        end
        if not holder then
            if state.stealUnlocked then
                state.stealUnlocked = false
                lockCharacter()
                stopWalk()
            end
            return
        end

        -- collect BOTH shots first, then one begin / one wait / one end.
        -- Previously each shot did its own begin-wait-end (4 frames total).
        local allPairs = {}

        -- 1) direct attempt: holder's hitbox into our target (cheapest shot)
        local sources = potatoPartsOf(holder.Character)
        local bodies = mainBodiesFast(target)
        if #sources > 0 and #bodies > 0 then
            local entries = { { plr = target, bodies = bodies } }
            for _, pr in ipairs(buildPairs(sources, entries)) do
                table.insert(allPairs, pr)
            end
        end

        -- 2) steal chain: our OWN body is the touch source (we own it, so the
        --    server always sees it). Touch their hitbox from here — no walking.
        --    Touch lock would bounce the touch off, so it is dropped for the steal.
        if holder ~= LocalPlayer and not potatoPresent() then
            if not state.stealUnlocked then
                unlockAll()
                state.stealUnlocked = true
            end
            local myBodies = mainBodiesFast(LocalPlayer)
            local holderPotato = potatoPartsOf(holder.Character)
            for _, src in ipairs(myBodies) do
                for _, dst in ipairs(holderPotato) do
                    table.insert(allPairs, { src, dst })
                end
            end
        end

        if #allPairs > 0 then
            beginPairs(allPairs)
            RunService.Heartbeat:Wait()
            endPairs(allPairs)
        end

        if os.clock() - lastRedirectMsg > 3 then
            lastRedirectMsg = os.clock()
            setStatus(("FORCE → %s (from %s)"):format(target.Name, holder.Name), "info")
        end
    end)
end

------------------------------------------------------------
-- INVINCIBLE (layered: ForceField + health lock + vacate valve)
------------------------------------------------------------
local netModule = nil
local afkClient = nil
local function getNet()
    if netModule then return netModule end
    pcall(function()
        local shared = ReplicatedStorage:FindFirstChild("Shared")
        local mods = shared and shared:FindFirstChild("Modules")
        local net = mods and mods:FindFirstChild("Net")
        if net then netModule = require(net) end
    end)
    return netModule
end

local function fireSetAfk()
    local net = getNet()
    if not net then return false end
    if not afkClient then
        pcall(function() afkClient = net.client("AFK") end)
    end
    if not afkClient then return false end
    local ok = pcall(function() afkClient:fire("SetAfkMode") end)
    return ok
end

-- ForceField + health lock: blocks the damage itself, every frame.
conn(RunService.RenderStepped, function()
    if not state.running or not config.enabled then return end
    local char = LocalPlayer.Character
    if not char then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return end
    if not char:FindFirstChildOfClass("ForceField") then
        pcall(function()
            local ff = Instance.new("ForceField")
            ff.Visible = false
            ff.Parent = char
        end)
    end
    if hum.Health < hum.MaxHealth then
        pcall(function() hum.Health = hum.MaxHealth end)
    end
end)

-- Vacate valve: at the last 1.6s of a held countdown, fire the game's own
-- AFK toggle. The server ejects holders from the round state, which drops
-- the potato server-side (observed live) — the explosion finds nobody.
vacateValve = function()
    if state.vacating or state.vacateUsed or not config.enabled then return end
    state.vacating = true
    state.vacateUsed = true
    task.spawn(function()
        setStatus("LAST SECOND — vacating via the game's own round-exit…", "bad")
        if LocalPlayer:GetAttribute("IsAFK") ~= true then
            fireSetAfk()
        end
        local t = os.clock() + 1.0
        while os.clock() < t and isTaggedNow() do
            task.wait(0.05)
        end
        task.wait(0.1)
        for _ = 1, 3 do
            if LocalPlayer:GetAttribute("IsAFK") ~= true then break end
            fireSetAfk()
            task.wait(0.5)
        end
        state.vacating = false
    end)
end

conn(LocalPlayer:GetAttributeChangedSignal("PotatoCountdown"), function()
    local v = tonumber(LocalPlayer:GetAttribute("PotatoCountdown"))
    if not config.enabled or not v then return end
    if isTaggedNow() or potatoPresent() then
        if v <= 1.6 then
            vacateValve()
        end
        -- SAFETY: stand down entirely in the danger window
        if config.safety and v <= (config.safetyWindow or 1.6) then return end
        -- LAST-MILLISECOND: targeted triple-pulse even at ~0.0s
        if v <= 0.8 and config.specific and not config.crazy then
            local sp = specificPlayer()
            if sp then
                local src = myHitboxParts()
                local tp = entriesFromPlayers({ sp }, 1)
                if #src > 0 and #tp > 0 then
                    task.spawn(function()
                        injectCycleSpecific(src, tp)
                        if isTaggedNow() or potatoPresent() then
                            injectCycleSpecific(src, tp)
                        end
                        if isTaggedNow() or potatoPresent() then
                            injectCycleSpecific(src, tp)
                        end
                    end)
                    setStatus(("LAST MILLISECOND → %s"):format(sp.Name), "bad")
                end
            end
        end
    end
end)

-- watchdog: catch the valve case even if the shed loop has ended (50ms for last-second)
do
    local acc = 0
    local lastPulse = 0
    conn(RunService.Heartbeat, function(dt)
        if not state.running or not config.enabled then return end
        acc += dt
        if acc < 0.05 then return end
        acc = 0
        if isTaggedNow() or potatoPresent() then
            local cdVal = tonumber(LocalPlayer:GetAttribute("PotatoCountdown"))
            if cdVal and cdVal <= 1.6 then
                vacateValve()
            end
            if cdVal and cdVal <= 0.8 and config.specific and not config.crazy and os.clock() - lastPulse > 0.15 then
                lastPulse = os.clock()
                local sp = specificPlayer()
                if sp then
                    local src = myHitboxParts()
                    local tp = entriesFromPlayers({ sp }, 1)
                    if #src > 0 and #tp > 0 then
                        task.spawn(function()
                            injectCycleSpecific(src, tp)
                        end)
                    end
                end
            end
        end
    end)
end


-- anti-AFK: flip the game's own toggle back off (never fights the vacate valve)
local afkCooldown = 0
local function fixAfk()
    if not config.enabled or not state.running or state.vacating then return end
    if LocalPlayer:GetAttribute("IsAFK") ~= true then return end
    if os.clock() - afkCooldown < 6 then return end
    afkCooldown = os.clock()
    task.spawn(function()
        if state.vacating then return end
        fireSetAfk()
        task.wait(0.6)
        if LocalPlayer:GetAttribute("IsAFK") == true then
            setStatus("AFK flag resisted — will retry", "warn")
        else
            setStatus("AFK OFF", "ok")
        end
    end)
end
conn(LocalPlayer:GetAttributeChangedSignal("IsAFK"), function()
    if LocalPlayer:GetAttribute("IsAFK") == true then fixAfk() end
end)
if LocalPlayer:GetAttribute("IsAFK") == true then
    fixAfk()
end

------------------------------------------------------------
-- UNLOAD
------------------------------------------------------------
local function unload()
    if not state.running then return end
    state.running = false
    state.token += 1

    if isTaggedNow() or potatoPresent() then
        pcall(function()
            refreshPool()
            local everyone = {}
            local sp = specificPlayer()
            if sp then table.insert(everyone, sp) end
            for _, entry in ipairs(state.pool) do
                if entry.plr ~= sp then
                    table.insert(everyone, entry.plr)
                end
            end
            local picks = entriesFromPlayers(everyone, 8)
            local sources = myHitboxParts()
            if #sources > 0 and #picks > 0 then
                local pairsList = buildPairs(sources, picks)
                beginPairs(pairsList)
                endPairs(pairsList)
            end
        end)
    end

    for _, c in ipairs(state.conns) do
        pcall(function() c:Disconnect() end)
    end
    table.clear(state.conns)

    pcall(stopWalk)
    pcall(unlockAll)
    pcall(restorePotato)
    pcall(function()
        local char = LocalPlayer.Character
        local ff = char and char:FindFirstChildOfClass("ForceField")
        if ff then ff:Destroy() end
    end)
    if namecallOld and typeof(hookmetamethod) == "function" then
        pcall(function() hookmetamethod(game, "__namecall", namecallOld) end)
    end
    pcall(function() screen:Destroy() end)
    GENV[REGISTRY_KEY] = nil
    print("[HotPotatoGuard v21] unloaded — every change reverted")
end

unloadBtn.Activated:Connect(unload)
GENV[REGISTRY_KEY] = { unload = unload }

------------------------------------------------------------
-- INIT
------------------------------------------------------------
setVisible(true, true)
refreshStats()
for _, fn in ipairs(sliderRefresh) do pcall(fn) end
if game.PlaceId == TARGET_PLACE then
    if config.enabled then
        if config.crazy then
            setStatus("🤪 CRAZY READY — random ping-pong", "info")
        elseif config.specific then
            setStatus("READY — specific armed", "ok")
        else
            setStatus("READY — touch denial armed", "ok")
        end
    else
        setStatus("OFF — fully passive", "idle")
    end
else
    setStatus("READY — attribute mode (place mismatch)", "info")
end
if config.enabled then
    lockCharacter()
end
print("[HotPotatoGuard] v21 loaded · RightCtrl hides · UNLOAD reverts everything")