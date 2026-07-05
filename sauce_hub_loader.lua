-- ============================================================
-- SAUCEHUB - Universal Script Hub Loader + jnkie Key System
-- ============================================================
-- Users save ONE loadstring forever. On execute, this:
--   1. Loads the jnkie SDK (fail-secure if it can't).
--   2. Silently re-validates a saved key, OR shows a key GUI.
--   3. On a valid key, reads game.PlaceId and loadstrings the
--      matching script straight from GitHub raw.
--
-- To add a game: drop a `[PlaceId] = "raw url"` line in CONFIG.SCRIPTS.
-- ============================================================

--==============================================================
-- CONFIG - the only section you edit per release
--==============================================================
local CONFIG = {
    -- jnkie dashboard values (SAUCEHUB service, work.ink provider)
    JUNKIE_SERVICE    = "SAUCEHUB",
    JUNKIE_IDENTIFIER = "1145232",
    -- Provider NAME must match the jnkie dashboard exactly (GET /api/v2/providers).
    -- One combined provider whose checkpoint flow offers both work.ink and lootlabs,
    -- so a single Get Key link covers both.
    JUNKIE_PROVIDER   = "SAUCEHUB 24 HOUR KEY",

    -- Where a validated key is cached so users don't re-enter it.
    -- Still re-validated with jnkie every launch (HWID / expiry stay enforced).
    KEY_FILE          = "saucehub_key.txt",
    -- Local record of when this key was first redeemed + KEY_HOURS, so the
    -- in-script countdown has something to show (the jnkie API returns no expiry).
    EXPIRY_FILE       = "saucehub_key_expiry.txt",
    KEY_HOURS         = 24,
    MAX_ATTEMPTS      = 6,

    -- PlaceId -> raw GitHub URL of that game's script.
    -- Add one line per game. Push the (obfuscated) script to a GitHub repo
    -- and paste its raw.githubusercontent.com URL here.
    SCRIPTS = {
        -- Fight The Monsters: Restored
        [93079655337537] = "https://raw.githubusercontent.com/ZackrryY/sauce-hub/main/ftmr.lua",
    },

    HUB_NAME     = "SAUCE",
    HUB_SUBTITLE = "Key System",
}

--==============================================================
-- SERVICES
--==============================================================
local Players            = game:GetService("Players")
local UserInputService   = game:GetService("UserInputService")
local TweenService       = game:GetService("TweenService")
local StarterGui         = game:GetService("StarterGui")

local localPlayer = Players.LocalPlayer

--==============================================================
-- THEME (copied from the SAUCE main GUI so the key screen matches)
--==============================================================
local T = {
    background     = Color3.fromRGB(10, 10, 18),
    backgroundDark = Color3.fromRGB(6, 6, 12),
    surface        = Color3.fromRGB(18, 18, 30),
    accent         = Color3.fromRGB(120, 80, 255),
    accentDim      = Color3.fromRGB(80, 55, 180),
    text           = Color3.fromRGB(255, 255, 255),
    textDim        = Color3.fromRGB(180, 180, 200),
    textMuted      = Color3.fromRGB(120, 120, 150),
    inputBg        = Color3.fromRGB(12, 12, 22),
    success        = Color3.fromRGB(0, 255, 150),
    danger         = Color3.fromRGB(255, 50, 80),
    warning        = Color3.fromRGB(255, 200, 0),
}

--==============================================================
-- SMALL HELPERS
--==============================================================
local function notify(title, text)
    -- Roblox toast + console fallback so failures are never silent.
    pcall(function()
        StarterGui:SetCore("SendNotification", { Title = title, Text = text, Duration = 6 })
    end)
    warn(("[%s] %s"):format(title, text))
end

local function corner(parent, radius)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, radius or 8)
    c.Parent = parent
    return c
end

local function stroke(parent, color, thickness)
    local s = Instance.new("UIStroke")
    s.Color = color or T.accent
    s.Thickness = thickness or 1
    s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    s.LineJoinMode = Enum.LineJoinMode.Round
    s.Parent = parent
    return s
end

-- Executor-dependent globals are all guarded so a missing one degrades gracefully.
local function clip(text)
    if setclipboard then pcall(setclipboard, text) end
end

local function readKey()
    if isfile and readfile and isfile(CONFIG.KEY_FILE) then
        local ok, data = pcall(readfile, CONFIG.KEY_FILE)
        if ok and type(data) == "string" then return (data:gsub("%s", "")) end
    end
    return nil
end

local function writeKey(key)
    if writefile then pcall(writefile, CONFIG.KEY_FILE, key) end
end

local function clearKey()
    if delfile and isfile and isfile(CONFIG.KEY_FILE) then pcall(delfile, CONFIG.KEY_FILE) end
    if delfile and isfile and isfile(CONFIG.EXPIRY_FILE) then pcall(delfile, CONFIG.EXPIRY_FILE) end
end

-- Expiry is stored locally as a unix timestamp (os.time based) the first time a
-- key is redeemed. jnkie never sends one back, so this is our best estimate for
-- the countdown; it self-heals to now+KEY_HOURS if the file is ever missing.
local function readExpiry()
    if isfile and readfile and isfile(CONFIG.EXPIRY_FILE) then
        local ok, data = pcall(readfile, CONFIG.EXPIRY_FILE)
        if ok then
            local n = tonumber((tostring(data):gsub("%s", "")))
            if n then return n end
        end
    end
    return nil
end

local function writeExpiry(ts)
    if writefile then pcall(writefile, CONFIG.EXPIRY_FILE, tostring(ts)) end
end

local function getHWID()
    if gethwid then
        local ok, h = pcall(gethwid)
        if ok and h then return tostring(h) end
    end
    local ok, h = pcall(function()
        return game:GetService("RbxAnalyticsService"):GetClientId()
    end)
    if ok and h then return tostring(h) end
    return "UNKNOWN"
end

local function guiParent()
    -- Prefer protected containers so other scripts can't easily nuke the loader.
    if gethui then
        local ok, h = pcall(gethui)
        if ok and h then return h end
    end
    local ok, cg = pcall(function() return game:GetService("CoreGui") end)
    if ok and cg then return cg end
    return localPlayer:WaitForChild("PlayerGui")
end

local function friendly(code)
    local map = {
        KEY_INVALID      = "Invalid key. Check for typos or get a new one.",
        KEY_EXPIRED      = "Key expired. Grab a fresh one with Get Key.",
        HWID_MISMATCH    = "This key is locked to another device.",
        ALREADY_USED     = "Key already claimed on another HWID.",
        SERVICE_MISMATCH = "Key is for a different service.",
        ERROR            = "Server error. Try again in a moment.",
    }
    if type(code) == "string" and code:match("^http") then
        return "Rate limited. Wait a minute and retry."
    end
    return map[code] or ("Rejected: " .. tostring(code))
end

--==============================================================
-- LOAD jnkie SDK (fail-secure)
--==============================================================
local okLoad, Junkie = pcall(function()
    return loadstring(game:HttpGet("https://jnkie.com/sdk/library.lua"))()
end)

if not okLoad or type(Junkie) ~= "table" or type(Junkie.check_key) ~= "function" then
    notify(CONFIG.HUB_NAME, "Key server unavailable. Try again later.")
    return -- fail-secure: nothing runs without a working validator
end

Junkie.service    = CONFIG.JUNKIE_SERVICE
Junkie.identifier = CONFIG.JUNKIE_IDENTIFIER
Junkie.provider   = CONFIG.JUNKIE_PROVIDER

--==============================================================
-- ROUTING - fetch + run the game-specific script after validation
--==============================================================
local function runGame(key)
    getgenv().SCRIPT_KEY = key -- exposed in case a game script wants it
    getgenv().SCRIPT_KEY_EXPIRES = readExpiry() -- unix ts for the in-script countdown

    local url = CONFIG.SCRIPTS[game.PlaceId]
    if not url then
        notify(CONFIG.HUB_NAME, "No script for this game yet (PlaceId " .. tostring(game.PlaceId) .. ").")
        return
    end

    -- Executor HttpGet / GitHub CDN can flake on large files, so retry a few times.
    local src
    for attempt = 1, 4 do
        local ok, res = pcall(function() return game:HttpGet(url) end)
        if ok and type(res) == "string" and #res >= 8 then
            src = res
            break
        end
        task.wait(1)
    end
    if not src then
        notify(CONFIG.HUB_NAME, "Failed to fetch the game script. Check your connection and retry.")
        return
    end

    local fn, compileErr = loadstring(src)
    if not fn then
        notify(CONFIG.HUB_NAME, "Compile error: " .. tostring(compileErr))
        return
    end

    local runOk, runErr = pcall(fn)
    if not runOk then
        notify(CONFIG.HUB_NAME, "Script error: " .. tostring(runErr))
    end
end

--==============================================================
-- SILENT RE-VALIDATION - skip the prompt if a saved key still checks out
--==============================================================
local saved = readKey()
if saved and saved ~= "" then
    local ok, res = pcall(Junkie.check_key, saved)
    if ok and type(res) == "table" and res.valid then
        -- Legacy keys saved before countdowns existed have no expiry file; seed one.
        if not readExpiry() then writeExpiry(os.time() + CONFIG.KEY_HOURS * 3600) end
        runGame(saved)
        return
    else
        clearKey() -- stale/expired/HWID-changed: force a fresh prompt
    end
end

--==============================================================
-- KEY GUI (matches SAUCE: purple accent, GothamBlack, shadow, rounded)
--==============================================================
local parent = guiParent()

local old = parent:FindFirstChild("SAUCEHUB_KEY")
if old then old:Destroy() end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "SAUCEHUB_KEY"
screenGui.ResetOnSpawn = false
screenGui.DisplayOrder = 9999
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Global
screenGui.IgnoreGuiInset = true
screenGui.Parent = parent

local main = Instance.new("Frame")
main.Size = UDim2.new(0, 440, 0, 276)
main.Position = UDim2.new(0.5, 0, 0.5, 0)
main.AnchorPoint = Vector2.new(0.5, 0.5)
main.BackgroundColor3 = T.background
main.BorderSizePixel = 0
main.Active = true
main.ZIndex = 9999
main.Parent = screenGui
corner(main, 12)
stroke(main, T.accent, 2)

-- Drop shadow behind the window
local shadow = Instance.new("ImageLabel")
shadow.Size = UDim2.new(1, 40, 1, 40)
shadow.Position = UDim2.new(0.5, 0, 0.5, 0)
shadow.AnchorPoint = Vector2.new(0.5, 0.5)
shadow.BackgroundTransparency = 1
shadow.Image = "rbxassetid://6015897843"
shadow.ImageColor3 = Color3.fromRGB(0, 0, 0)
shadow.ImageTransparency = 0.5
shadow.ScaleType = Enum.ScaleType.Slice
shadow.SliceCenter = Rect.new(49, 49, 450, 450)
shadow.ZIndex = 9998
shadow.Parent = main

-- Title bar
local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, 44)
titleBar.BackgroundColor3 = T.backgroundDark
titleBar.BorderSizePixel = 0
titleBar.ZIndex = 10000
titleBar.Parent = main
corner(titleBar, 12)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(0, 120, 1, 0)
title.Position = UDim2.new(0, 16, 0, 0)
title.BackgroundTransparency = 1
title.Text = CONFIG.HUB_NAME
title.TextColor3 = T.accent
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextSize = 18
title.Font = Enum.Font.GothamBlack
title.ZIndex = 10001
title.Parent = titleBar

local subtitle = Instance.new("TextLabel")
subtitle.Size = UDim2.new(0, 200, 1, 0)
subtitle.Position = UDim2.new(0, 86, 0, 0)
subtitle.BackgroundTransparency = 1
subtitle.Text = CONFIG.HUB_SUBTITLE
subtitle.TextColor3 = T.textMuted
subtitle.TextXAlignment = Enum.TextXAlignment.Left
subtitle.TextSize = 13
subtitle.Font = Enum.Font.Gotham
subtitle.ZIndex = 10001
subtitle.Parent = titleBar

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 28, 0, 28)
closeBtn.Position = UDim2.new(1, -36, 0, 8)
closeBtn.BackgroundColor3 = T.surface
closeBtn.Text = "X"
closeBtn.TextColor3 = T.textDim
closeBtn.TextSize = 14
closeBtn.Font = Enum.Font.GothamBold
closeBtn.AutoButtonColor = false
closeBtn.ZIndex = 10001
closeBtn.Parent = titleBar
corner(closeBtn, 6)
closeBtn.MouseEnter:Connect(function() closeBtn.BackgroundColor3 = T.danger end)
closeBtn.MouseLeave:Connect(function() closeBtn.BackgroundColor3 = T.surface end)
closeBtn.MouseButton1Click:Connect(function() screenGui:Destroy() end)

-- Body: description
local desc = Instance.new("TextLabel")
desc.Size = UDim2.new(1, -40, 0, 38)
desc.Position = UDim2.new(0, 20, 0, 54)
desc.BackgroundTransparency = 1
desc.Text = "Click Get Key, complete the checkpoint, then paste your key below and hit Redeem."
desc.TextColor3 = T.textDim
desc.TextWrapped = true
desc.TextXAlignment = Enum.TextXAlignment.Left
desc.TextYAlignment = Enum.TextYAlignment.Top
desc.TextSize = 13
desc.Font = Enum.Font.Gotham
desc.ZIndex = 10001
desc.Parent = main

-- Key input
local keyBox = Instance.new("TextBox")
keyBox.Size = UDim2.new(1, -40, 0, 42)
keyBox.Position = UDim2.new(0, 20, 0, 96)
keyBox.BackgroundColor3 = T.inputBg
keyBox.Text = ""
keyBox.PlaceholderText = "Paste your key here"
keyBox.PlaceholderColor3 = T.textMuted
keyBox.TextColor3 = T.text
keyBox.TextSize = 14
keyBox.Font = Enum.Font.Gotham
keyBox.ClearTextOnFocus = false
keyBox.ZIndex = 10001
keyBox.Parent = main
corner(keyBox, 8)
stroke(keyBox, T.accentDim, 1)

-- Status line
local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -40, 0, 20)
status.Position = UDim2.new(0, 20, 0, 146)
status.BackgroundTransparency = 1
status.Text = "Waiting for your key..."
status.TextColor3 = T.textMuted
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextTruncate = Enum.TextTruncate.AtEnd
status.TextSize = 13
status.Font = Enum.Font.GothamBold
status.ZIndex = 10001
status.Parent = main

local function setStatus(text, color)
    status.Text = text
    status.TextColor3 = color or T.textMuted
end

-- Buttons
local function makeButton(text, pos, size, bg, textSize)
    local b = Instance.new("TextButton")
    b.Size = size
    b.Position = pos
    b.BackgroundColor3 = bg
    b.Text = text
    b.TextColor3 = T.text
    b.TextSize = textSize or 15
    b.Font = Enum.Font.GothamBold
    b.AutoButtonColor = false
    b.ZIndex = 10001
    b.Parent = main
    corner(b, 8)
    local base = bg
    b.MouseEnter:Connect(function()
        TweenService:Create(b, TweenInfo.new(0.15), { BackgroundColor3 = T.accent }):Play()
    end)
    b.MouseLeave:Connect(function()
        TweenService:Create(b, TweenInfo.new(0.15), { BackgroundColor3 = base }):Play()
    end)
    return b
end

-- One combined provider (work.ink + lootlabs in its checkpoint flow), so a single
-- Get Key button is all we need, beside Redeem.
local getKeyBtn = makeButton("Get Key",
    UDim2.new(0, 20, 0, 176), UDim2.new(0.5, -26, 0, 42), T.accentDim)
local redeemBtn = makeButton("Redeem",
    UDim2.new(0.5, 6, 0, 176), UDim2.new(0.5, -26, 0, 42), T.accent)

-- Footer / attempts
local footer = Instance.new("TextLabel")
footer.Size = UDim2.new(1, -40, 0, 16)
footer.Position = UDim2.new(0, 20, 0, 228)
footer.BackgroundTransparency = 1
footer.Text = "SAUCEHUB - key bound to your HWID"
footer.TextColor3 = T.textMuted
footer.TextXAlignment = Enum.TextXAlignment.Left
footer.TextSize = 11
footer.Font = Enum.Font.Gotham
footer.ZIndex = 10001
footer.Parent = main

--==============================================================
-- DRAGGING
--==============================================================
do
    local dragging, dragStart, startPos = false, nil, nil
    titleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = main.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            main.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
end

--==============================================================
-- BUTTON LOGIC
--==============================================================
local fetchingLink = false
getKeyBtn.MouseButton1Click:Connect(function()
    if fetchingLink then return end
    fetchingLink = true
    setStatus("Fetching your key link...", T.warning)
    task.spawn(function()
        -- get_key_link returns (link, errReason); keep the reason so a failure is
        -- never opaque (a wrong provider name reads as "Provider not found", etc).
        local ok, link, reason = pcall(Junkie.get_key_link, CONFIG.JUNKIE_PROVIDER)
        fetchingLink = false
        if ok and type(link) == "string" and #link > 0 then
            clip(link)
            setStatus("Link copied! Complete it, then paste your key.", T.success)
        else
            local why = (type(link) == "string" and link)
                or (type(reason) == "string" and reason)
                or (not ok and tostring(link)) or "no link"
            if type(why) == "string" and why:find("429") then
                why = "rate limited, wait a minute"
            end
            setStatus("Get Key failed: " .. tostring(why):sub(1, 55), T.danger)
        end
    end)
end)

local attempts = 0
local busy = false

local function doRedeem()
    if busy then return end
    local key = keyBox.Text:gsub("%s", "")
    if key == "" then
        setStatus("Enter a key first.", T.danger)
        return
    end
    if attempts >= CONFIG.MAX_ATTEMPTS then
        setStatus("Too many attempts. Reload the script.", T.danger)
        return
    end

    busy = true
    attempts = attempts + 1
    setStatus("Checking...", T.warning)

    task.spawn(function()
        local ok, res = pcall(Junkie.check_key, key)
        busy = false

        if not ok or type(res) ~= "table" then
            setStatus("Network error. Try again.", T.danger)
            return
        end

        if res.valid then
            writeKey(key)
            -- Fresh redeem only happens when no valid cached key existed, so start
            -- a clean 24h window now.
            writeExpiry(os.time() + CONFIG.KEY_HOURS * 3600)
            setStatus("Key valid! Loading...", T.success)
            task.wait(0.4)
            screenGui:Destroy()
            runGame(key)
            return
        end

        local code = res.message or res.error or "KEY_INVALID"
        if code == "HWID_BANNED" then
            localPlayer:Kick("You are hardware-banned.")
            return
        end
        setStatus(friendly(code), T.danger)
        if attempts >= CONFIG.MAX_ATTEMPTS then
            setStatus("Too many attempts. Reload the script.", T.danger)
            redeemBtn.AutoButtonColor = false
        end
    end)
end

redeemBtn.MouseButton1Click:Connect(doRedeem)
keyBox.FocusLost:Connect(function(enterPressed)
    if enterPressed then doRedeem() end
end)
