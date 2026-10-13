--[[
    RTX PREMIUM v7.0
    Client-side Roblox graphics controller (LocalScript).
    Place in StarterPlayer > StarterPlayerScripts (or run client-side).
    Default menu key: B   (touch devices get a small floating button)

    What is new in v7:
      * Smart Depth of Field   - multi-ray focus, subject / cursor / smart modes,
                                 blur strength follows the focus distance
      * Real world weather     - rain, storm, snow and fog are 3D objects that fall on
                                 the map, stop on roofs, splash on surfaces. No screen overlay.
      * Wet / snowy surfaces   - materials get glossy and dark in rain, white in snow
      * Reflections            - material-aware gloss + true mirrored characters and props
                                 on water, glass and any translucent horizontal surface
      * 12 procedural skies    - atmosphere driven (no unverified asset ids), smooth blending,
                                 plus a smart day/night cycle
      * Camera                 - motion blur, auto exposure (indoor/outdoor), vignette, letterbox
      * New minimal UI         - sidebar tabs, switches, sliders, chips, toasts, auto quality

    UNLOAD (System tab) restores every property this script changed and
    removes only the objects it created.
]]

print("[RTX Premium] loading...")

local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local VERSION = "7.0"
local GUI_NAME = "RTXPremiumV7"
local OVERLAY_NAME = "RTXPremiumV7_Overlay"
local OWNER_TAG = "RTXPremiumV7_"
local SAVE_FILE = "RTXPremium_v7.json"

--========================================================
-- Remove leftovers of previous versions / copies
--========================================================
for _, name in ipairs({ GUI_NAME, OVERLAY_NAME, "RTXPremiumV5", "RTXPremiumV5_WeatherOverlay" }) do
    local old = playerGui:FindFirstChild(name)
    if old then old:Destroy() end
end
for _, child in ipairs(Lighting:GetChildren()) do
    if string.sub(child.Name, 1, 12) == "RTXPremiumV5" or string.sub(child.Name, 1, 12) == "RTXPremiumV7" then
        child:Destroy()
    end
end
do
    local oldWorld = Workspace:FindFirstChild(OWNER_TAG .. "World")
    if oldWorld then oldWorld:Destroy() end
end

--========================================================
-- Utilities
--========================================================
local C = Color3.fromRGB

local function clamp(x, a, b) return math.max(a, math.min(b, x)) end
local function lerp(a, b, t) return a + (b - a) * t end
local function damp(a, b, rate, dt) return a + (b - a) * (1 - math.exp(-rate * dt)) end
local function mulC(c, s) return Color3.new(clamp(c.R * s, 0, 1), clamp(c.G * s, 0, 1), clamp(c.B * s, 0, 1)) end
local function rand(a, b) return a + math.random() * (b - a) end

local connections = {}
local createdObjects = {}
local originals = setmetatable({}, { __mode = "k" })
local alive = true
local unloaded = false

local function connect(signal, fn)
    local c = signal:Connect(fn)
    connections[#connections + 1] = c
    return c
end

local function remember(object, property)
    local per = originals[object]
    if not per then
        per = {}
        originals[object] = per
    end
    if per[property] == nil then
        local ok, value = pcall(function() return object[property] end)
        if ok then per[property] = value end
    end
end

local function rememberAll(object, list)
    for _, p in ipairs(list) do remember(object, p) end
end

local function makeOwned(className, name, parent)
    local obj = Instance.new(className)
    obj.Name = name
    obj.Parent = parent
    createdObjects[#createdObjects + 1] = obj
    return obj
end

local function new(class, props, parent)
    local o = Instance.new(class)
    if props then
        for k, v in pairs(props) do o[k] = v end
    end
    if parent then o.Parent = parent end
    return o
end

local function tween(obj, props, t, style)
    local tw = TweenService:Create(obj, TweenInfo.new(t or 0.15, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props)
    tw:Play()
    return tw
end

--========================================================
-- Config
--========================================================
local DEFAULTS = {
    master = true,
    quality = "High",
    autoQuality = true,
    profile = "Natural",

    -- look
    exposure = 0, contrast = 0, saturation = 0, warmth = 0,
    bloom = 1, rays = 1, vignette = 0.2, bars = false,

    -- sky / time
    sky = "Original", timeMode = "Game", clock = 14, cycleMinutes = 8, haze = 1,

    -- weather
    weather = "Clear", weatherIntensity = 0.75, wind = 0.35, lightning = true,
    wetLook = 0.7, ripples = true,

    -- camera
    dof = true, dofMode = "Smart", dofFar = 0.45, dofNear = 0.2, aperture = 1,
    dofLimit = 400, dofSmooth = 8, dofManual = 60,
    motionBlur = 0, autoExposure = 0.5,

    -- reflections
    gloss = true, glossStrength = 0.5, glossRadius = 140,
    mirror = true, mirrorStrength = 0.6, mirrorProps = true,
    waterOn = false, waterReflect = 0.7, waterTransp = 0.35, waterWave = 0.25, waterSpeed = 10,
    waterTint = "Original",
}

local config = {}
for k, v in pairs(DEFAULTS) do config[k] = v end

local menuKey = Enum.KeyCode.B

local QUALITY = {
    Low =    { rain = 110, snow = 70,  ripples = 10, glossParts = 350,  mirrorProps = 0,  mirrorHz = 30, dofRays = 1 },
    Medium = { rain = 200, snow = 120, ripples = 18, glossParts = 800,  mirrorProps = 16, mirrorHz = 45, dofRays = 3 },
    High =   { rain = 340, snow = 190, ripples = 26, glossParts = 1500, mirrorProps = 40, mirrorHz = 60, dofRays = 5 },
    Ultra =  { rain = 520, snow = 300, ripples = 34, glossParts = 2600, mirrorProps = 80, mirrorHz = 60, dofRays = 5 },
}
local fpsScale = 1

local PROFILES = {
    Natural =     { exposure = 0,     contrast = 0.02, saturation = 0.04, warmth = 0,    bloom = 0.8, rays = 0.8, vignette = 0.15, bars = false, dofFar = 0.35, dofNear = 0.15 },
    Cinematic =   { exposure = -0.05, contrast = 0.12, saturation = 0.02, warmth = 0.25, bloom = 1.2, rays = 1.1, vignette = 0.4,  bars = true,  dofFar = 0.7,  dofNear = 0.3 },
    Vivid =       { exposure = 0.05,  contrast = 0.1,  saturation = 0.3,  warmth = 0.1,  bloom = 1.3, rays = 1.2, vignette = 0.1,  bars = false, dofFar = 0.4,  dofNear = 0.15 },
    Clean =       { exposure = 0,     contrast = 0,    saturation = 0,    warmth = 0,    bloom = 0.4, rays = 0.4, vignette = 0,    bars = false, dofFar = 0.2,  dofNear = 0.05 },
    Performance = { exposure = 0,     contrast = 0.02, saturation = 0.02, warmth = 0,    bloom = 0,   rays = 0,   vignette = 0,    bars = false, dofFar = 0,    dofNear = 0, quality = "Low", dof = false, mirror = false, motionBlur = 0 },
}

--========================================================
-- Snapshot original state
--========================================================
local LIGHT_PROPS = {
    "Ambient", "OutdoorAmbient", "Brightness", "ClockTime", "ExposureCompensation",
    "EnvironmentDiffuseScale", "EnvironmentSpecularScale", "ColorShift_Top", "ColorShift_Bottom",
}
rememberAll(Lighting, LIGHT_PROPS)

local terrain = Workspace:FindFirstChildOfClass("Terrain")
local WATER_PROPS = { "WaterColor", "WaterReflectance", "WaterTransparency", "WaterWaveSize", "WaterWaveSpeed" }
if terrain then rememberAll(terrain, WATER_PROPS) end

-- Atmosphere: take over the game's own one (tracked), otherwise create ours.
local ATMO_PROPS = { "Density", "Offset", "Color", "Decay", "Glare", "Haze" }
local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
local hadAtmosphere = atmosphere ~= nil
if atmosphere then
    rememberAll(atmosphere, ATMO_PROPS)
else
    atmosphere = makeOwned("Atmosphere", OWNER_TAG .. "Atmosphere", Lighting)
    atmosphere.Density = 0
    atmosphere.Offset = 0.25
    atmosphere.Color = C(190, 210, 240)
    atmosphere.Decay = C(110, 130, 160)
    atmosphere.Glare = 0
    atmosphere.Haze = 0
    rememberAll(atmosphere, ATMO_PROPS)
end

-- Sky: track the game's one (stars / celestial bodies only) or create ours.
local SKY_PROPS = { "StarCount", "CelestialBodiesShown" }
local sky = Lighting:FindFirstChildOfClass("Sky")
if sky then
    rememberAll(sky, SKY_PROPS)
else
    sky = makeOwned("Sky", OWNER_TAG .. "Sky", Lighting)
    rememberAll(sky, SKY_PROPS)
end

--========================================================
-- Owned post effects (the game's own effects are never touched)
--========================================================
local grade = makeOwned("ColorCorrectionEffect", OWNER_TAG .. "Grade", Lighting)
local bloomFx = makeOwned("BloomEffect", OWNER_TAG .. "Bloom", Lighting)
local raysFx = makeOwned("SunRaysEffect", OWNER_TAG .. "Rays", Lighting)
local dofFx = makeOwned("DepthOfFieldEffect", OWNER_TAG .. "DOF", Lighting)
local blurFx = makeOwned("BlurEffect", OWNER_TAG .. "MotionBlur", Lighting)
raysFx.Spread = 0.8
dofFx.Enabled = false
blurFx.Size = 0
blurFx.Enabled = false

--========================================================
-- World container + raycast helpers
--========================================================
local worldFolder = makeOwned("Folder", OWNER_TAG .. "World", Workspace)
local camera = Workspace.CurrentCamera

local function newParams()
    local p = RaycastParams.new()
    p.FilterType = Enum.RaycastFilterType.Exclude
    p.IgnoreWater = false
    return p
end

local paramsGeneral = newParams() -- rain, auto exposure (all characters excluded)
local paramsDof = newParams()     -- focus rays (local character excluded)
local paramsMirror = newParams()

local function refreshFilters()
    camera = Workspace.CurrentCamera
    local general = { worldFolder }
    if camera then general[#general + 1] = camera end
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr.Character then general[#general + 1] = plr.Character end
    end
    paramsGeneral.FilterDescendantsInstances = general

    local dof = { worldFolder }
    if camera then dof[#dof + 1] = camera end
    if player.Character then dof[#dof + 1] = player.Character end
    paramsDof.FilterDescendantsInstances = dof
end

-- Cast that skips invisible helper parts (kill bricks, trigger volumes ...).
local function castVisible(params, origin, direction)
    local result
    for _ = 1, 4 do
        result = Workspace:Raycast(origin, direction, params)
        if not result then return nil end
        local inst = result.Instance
        if inst:IsA("BasePart") and not inst:IsA("Terrain") and inst.Transparency >= 0.9 then
            params:AddToFilter(inst)
        else
            return result
        end
    end
    return result
end

--========================================================
-- LOOKS: procedural skies (atmosphere driven, no asset ids)
--========================================================
local LOOK_DEFAULT = {
    clock = 13, bright = 3, expo = 0,
    amb = C(70, 72, 82), outAmb = C(120, 128, 145), shTop = C(0, 0, 0), shBot = C(0, 0, 0),
    envD = 1, envS = 1,
    aDen = 0.3, aOff = 0.25, aCol = C(190, 210, 240), aDecay = C(110, 130, 160), aGlare = 0, aHaze = 1.5,
    cBri = 0, cCon = 0.06, cSat = 0.1, cTint = C(255, 252, 246),
    bloom = 0.25, bloomSize = 24, bloomTh = 1.0, rays = 0.08, stars = 3000,
}

local function makeLook(t)
    for k, v in pairs(LOOK_DEFAULT) do
        if t[k] == nil then t[k] = v end
    end
    return t
end

local SKY_ORDER = { "ClearDay", "GoldenHour", "Sunset", "BlueHour", "Night", "Overcast", "FoggyDawn", "NeonDusk", "Alien", "Desert", "Arctic" }
local SKIES = {
    ClearDay = { name = "Clear Day", dot = C(120, 190, 255), look = makeLook({}) },
    GoldenHour = { name = "Golden Hour", dot = C(255, 190, 110), look = makeLook({
        clock = 17.3, bright = 2.6, amb = C(90, 75, 70), outAmb = C(150, 120, 105), shTop = C(40, 22, 8),
        aDen = 0.35, aOff = 0.2, aCol = C(255, 205, 150), aDecay = C(200, 120, 70), aGlare = 0.6, aHaze = 2.2,
        cCon = 0.1, cSat = 0.2, cTint = C(255, 236, 215), bloom = 0.35, bloomTh = 0.95, rays = 0.18 }) },
    Sunset = { name = "Sunset", dot = C(255, 120, 100), look = makeLook({
        clock = 18.3, bright = 2.2, amb = C(95, 70, 85), outAmb = C(140, 95, 110), shTop = C(50, 18, 18),
        aDen = 0.4, aOff = 0.1, aCol = C(255, 150, 110), aDecay = C(170, 70, 80), aGlare = 1.0, aHaze = 2.8,
        cCon = 0.12, cSat = 0.25, cTint = C(255, 225, 225), bloom = 0.4, bloomTh = 0.9, rays = 0.22 }) },
    BlueHour = { name = "Blue Hour", dot = C(110, 130, 210), look = makeLook({
        clock = 19.2, bright = 1.2, amb = C(55, 65, 100), outAmb = C(80, 95, 145), shTop = C(8, 12, 30),
        aDen = 0.38, aOff = 0.05, aCol = C(120, 140, 200), aDecay = C(60, 70, 140), aHaze = 2,
        cCon = 0.1, cSat = 0.15, cTint = C(225, 235, 255), bloom = 0.35, rays = 0.05, stars = 3500 }) },
    Night = { name = "Night", dot = C(40, 50, 100), look = makeLook({
        clock = 0, bright = 1, amb = C(30, 38, 60), outAmb = C(45, 55, 85), shTop = C(0, 0, 10),
        aDen = 0.3, aOff = 0, aCol = C(35, 45, 80), aDecay = C(15, 20, 45), aHaze = 1,
        cCon = 0.1, cSat = -0.03, cTint = C(215, 228, 255), bloom = 0.45, bloomTh = 0.9, rays = 0, stars = 6000 }) },
    Overcast = { name = "Overcast", dot = C(160, 168, 180), look = makeLook({
        clock = 12, bright = 1.6, amb = C(95, 100, 110), outAmb = C(130, 135, 145), envS = 0.7,
        aDen = 0.55, aOff = 0.1, aCol = C(170, 178, 190), aDecay = C(130, 138, 150), aHaze = 3,
        cCon = -0.02, cSat = -0.15, cTint = C(240, 244, 250), bloom = 0.15, rays = 0 }) },
    FoggyDawn = { name = "Foggy Dawn", dot = C(215, 200, 205), look = makeLook({
        clock = 6.3, bright = 1.8, amb = C(85, 85, 95), outAmb = C(125, 120, 130),
        aDen = 0.75, aOff = 0, aCol = C(200, 195, 205), aDecay = C(160, 150, 160), aHaze = 4,
        cSat = -0.08, cTint = C(255, 240, 235), bloom = 0.35, rays = 0.1 }) },
    NeonDusk = { name = "Neon Dusk", dot = C(255, 80, 200), look = makeLook({
        clock = 19, bright = 1.4, amb = C(90, 50, 120), outAmb = C(120, 60, 150), shTop = C(60, 10, 50),
        aDen = 0.45, aOff = 0.1, aCol = C(255, 90, 200), aDecay = C(80, 40, 160), aGlare = 0.8, aHaze = 2.5,
        cCon = 0.18, cSat = 0.35, cTint = C(255, 225, 255), bloom = 0.6, bloomSize = 40, bloomTh = 0.8, rays = 0.1, stars = 4000 }) },
    Alien = { name = "Alien", dot = C(120, 255, 190), look = makeLook({
        clock = 15, bright = 2.2, amb = C(60, 100, 90), outAmb = C(90, 150, 130), shTop = C(0, 30, 20),
        aDen = 0.4, aOff = 0.15, aCol = C(140, 255, 200), aDecay = C(60, 120, 160), aHaze = 2,
        cSat = 0.3, cTint = C(230, 255, 245), bloom = 0.35 }) },
    Desert = { name = "Desert Haze", dot = C(240, 205, 150), look = makeLook({
        clock = 14, bright = 3.2, amb = C(110, 95, 75), outAmb = C(170, 145, 110), shTop = C(30, 20, 5),
        aDen = 0.5, aOff = 0.2, aCol = C(240, 210, 160), aDecay = C(190, 150, 95), aGlare = 0.3, aHaze = 3.2,
        cCon = 0.1, cSat = 0.05, cTint = C(255, 240, 215), bloom = 0.3, rays = 0.12 }) },
    Arctic = { name = "Arctic", dot = C(205, 230, 255), look = makeLook({
        clock = 11, bright = 3, amb = C(100, 115, 135), outAmb = C(160, 180, 205),
        aDen = 0.35, aOff = 0.3, aCol = C(215, 232, 255), aDecay = C(150, 175, 210), aHaze = 1.6,
        cCon = 0.08, cSat = -0.05, cTint = C(235, 245, 255), bloom = 0.3 }) },
}

-- Smart day/night cycle: keyframes interpolated by clock time.
local AUTO_KEYS = {
    { 0, "Night" }, { 4.8, "Night" }, { 5.6, "BlueHour" }, { 6.6, "GoldenHour" }, { 9.5, "ClearDay" },
    { 15, "ClearDay" }, { 17.2, "GoldenHour" }, { 18.2, "Sunset" }, { 19, "BlueHour" }, { 20.5, "Night" }, { 24, "Night" },
}

local function blendInto(dst, a, b, t)
    for k, v in pairs(a) do
        local w = b[k]
        if typeof(v) == "Color3" then
            dst[k] = v:Lerp(w, t)
        else
            dst[k] = v + (w - v) * t
        end
    end
end

local autoLook = makeLook({})
local function computeAuto(clockTime)
    local c = clockTime % 24
    for i = 1, #AUTO_KEYS - 1 do
        local k1, k2 = AUTO_KEYS[i], AUTO_KEYS[i + 1]
        if c >= k1[1] and c <= k2[1] then
            local t = (c - k1[1]) / math.max(k2[1] - k1[1], 0.001)
            t = t * t * (3 - 2 * t)
            blendInto(autoLook, SKIES[k1[2]].look, SKIES[k2[2]].look, t)
            return autoLook
        end
    end
    return SKIES.ClearDay.look
end

-- Look built from the game's own lighting (the "Original" sky).
local origLook = makeLook({})
do
    local L = originals[Lighting]
    local A = originals[atmosphere]
    local S = originals[sky]
    origLook.clock = L.ClockTime or 14
    origLook.bright = L.Brightness or 3
    origLook.expo = L.ExposureCompensation or 0
    origLook.amb = L.Ambient or origLook.amb
    origLook.outAmb = L.OutdoorAmbient or origLook.outAmb
    origLook.shTop = L.ColorShift_Top or C(0, 0, 0)
    origLook.shBot = L.ColorShift_Bottom or C(0, 0, 0)
    origLook.envD = L.EnvironmentDiffuseScale or 1
    origLook.envS = L.EnvironmentSpecularScale or 1
    if hadAtmosphere then
        origLook.aDen = A.Density or 0
        origLook.aOff = A.Offset or 0
        origLook.aCol = A.Color or origLook.aCol
        origLook.aDecay = A.Decay or origLook.aDecay
        origLook.aGlare = A.Glare or 0
        origLook.aHaze = A.Haze or 0
    else
        origLook.aDen = 0
        origLook.aHaze = 0
    end
    origLook.cBri, origLook.cCon, origLook.cSat = 0, 0, 0
    origLook.cTint = C(255, 255, 255)
    origLook.bloom, origLook.rays = 0, 0
    origLook.stars = (S and S.StarCount) or 3000
end

local curLook = makeLook({})
for k, v in pairs(origLook) do curLook[k] = v end

--========================================================
-- Weather definitions (values at intensity 1)
--========================================================
local WEATHER = {
    Clear = { dim = 0,    gray = 0,    fog = 0,    rays = 1,    sat = 0,     wet = 0, rain = 0,    snow = 0, wind = 1,   fogCol = C(200, 208, 220) },
    Rain  = { dim = 0.38, gray = 0.55, fog = 0.22, rays = 0.15, sat = -0.12, wet = 1, rain = 1,    snow = 0, wind = 1.2, fogCol = C(150, 160, 175) },
    Storm = { dim = 0.65, gray = 0.7,  fog = 0.3,  rays = 0,    sat = -0.2,  wet = 1, rain = 1.35, snow = 0, wind = 2.2, fogCol = C(90, 98, 115), storm = true },
    Snow  = { dim = 0.2,  gray = 0.45, fog = 0.28, rays = 0.4,  sat = -0.18, wet = 0, rain = 0,    snow = 1, wind = 0.8, fogCol = C(225, 232, 242) },
    Fog   = { dim = 0.15, gray = 0.6,  fog = 0.55, rays = 0.2,  sat = -0.1,  wet = 0, rain = 0,    snow = 0, wind = 0.4, fogCol = C(205, 210, 218) },
}
local WEATHER_ORDER = { "Clear", "Rain", "Storm", "Snow", "Fog" }

local wx = { dim = 0, gray = 0, fog = 0, rays = 1, sat = 0, wet = 0, rain = 0, snow = 0, wind = 1, fogCol = C(200, 208, 220) }
local flash = 0

--========================================================
-- Environment state (clock, auto exposure, frame data)
--========================================================
local clockCur = Lighting.ClockTime
local autoOpen = 1
local autoExpoAdd = 0
local lastPassthrough = false
local clockTouched = false
local masterApplied = true

local function wrapDelta(a, b) -- shortest signed distance on a 24h circle
    local d = (b - a) % 24
    if d > 12 then d = d - 24 end
    return d
end

local function updateEnvironment(dt)
    local master = config.master

    -- clock
    if config.timeMode == "Cycle" then
        config.clock = (config.clock + dt * 24 / (math.max(config.cycleMinutes, 0.5) * 60)) % 24
        clockCur = config.clock
    elseif config.timeMode == "Manual" then
        local d = wrapDelta(clockCur, config.clock)
        clockCur = (clockCur + d * (1 - math.exp(-3 * dt))) % 24
    else
        clockCur = Lighting.ClockTime
    end

    -- weather state
    local def = WEATHER[config.weather] or WEATHER.Clear
    local s = master and config.weatherIntensity or 0
    local rate = 0.7
    wx.dim = damp(wx.dim, def.dim * s, rate, dt)
    wx.gray = damp(wx.gray, def.gray * s, rate, dt)
    wx.fog = damp(wx.fog, def.fog * s, rate, dt)
    wx.rays = damp(wx.rays, lerp(1, def.rays, s), rate, dt)
    wx.sat = damp(wx.sat, def.sat * s, rate, dt)
    wx.wet = damp(wx.wet, def.wet * s, rate, dt)
    wx.rain = damp(wx.rain, master and def.rain * s or 0, 0.9, dt)
    wx.snow = damp(wx.snow, master and def.snow * s or 0, 0.9, dt)
    wx.wind = damp(wx.wind, def.wind, 0.5, dt)
    wx.fogCol = wx.fogCol:Lerp(def.fogCol, 1 - math.exp(-rate * dt))
    flash = flash * math.exp(-7 * dt)

    -- target look
    local target
    if config.sky == "Original" then
        target = origLook
    elseif config.sky == "Auto" then
        target = computeAuto(clockCur)
    else
        target = SKIES[config.sky] and SKIES[config.sky].look or origLook
    end
    blendInto(curLook, curLook, target, 1 - math.exp(-1.8 * dt))

    local L = curLook
    local g, dim = wx.gray, wx.dim

    -- Post effects
    local tint = L.cTint
    local w = config.warmth * 0.08
    tint = Color3.new(clamp(tint.R * (1 + w), 0, 1), tint.G, clamp(tint.B * (1 - w), 0, 1))
    tint = tint:Lerp(C(205, 215, 230), g * 0.35)

    grade.Enabled = master
    grade.Brightness = L.cBri + flash * 0.16
    grade.Contrast = clamp(L.cCon + config.contrast, -1, 1)
    grade.Saturation = clamp(L.cSat + config.saturation + wx.sat, -1, 1)
    grade.TintColor = tint

    local bloomI = (L.bloom * (1 + g * 0.25) + flash * 0.35) * config.bloom
    bloomFx.Enabled = master and bloomI > 0.01
    bloomFx.Intensity = clamp(bloomI, 0, 3)
    bloomFx.Size = L.bloomSize
    bloomFx.Threshold = L.bloomTh

    local raysI = L.rays * config.rays * wx.rays
    raysFx.Enabled = master and raysI > 0.005
    raysFx.Intensity = clamp(raysI, 0, 1)

    -- Lighting / atmosphere (skipped completely when nothing changes the game's look)
    local passthrough = (not master) or (config.sky == "Original" and dim < 0.002 and wx.fog < 0.002
        and math.abs(config.haze - 1) < 0.01 and math.abs(config.exposure) < 0.001
        and flash < 0.002 and autoExpoAdd < 0.002 and config.timeMode == "Game")

    if passthrough then
        if not lastPassthrough then
            for _, p in ipairs(LIGHT_PROPS) do
                if p ~= "ClockTime" then pcall(function() Lighting[p] = originals[Lighting][p] end) end
            end
            local A = originals[atmosphere]
            for _, p in ipairs(ATMO_PROPS) do pcall(function() atmosphere[p] = A[p] end) end
            local S = originals[sky]
            for _, p in ipairs(SKY_PROPS) do pcall(function() sky[p] = S[p] end) end
            if not hadAtmosphere then atmosphere.Density = 0 end
        end
        lastPassthrough = true
        return
    end
    lastPassthrough = false

    local indoorMul = 1 - (1 - autoOpen) * 0.45 * math.min(1, config.autoExposure * 2)
    local dimL = 1 - dim * 0.55
    Lighting.Brightness = L.bright * dimL
    Lighting.ExposureCompensation = clamp(L.expo + config.exposure + autoExpoAdd + flash * 1.1, -5, 5)
    Lighting.Ambient = mulC(L.amb:Lerp(C(110, 115, 125), g * 0.5), 1 - dim * 0.35)
    Lighting.OutdoorAmbient = mulC(L.outAmb:Lerp(C(130, 135, 145), g * 0.5), 1 - dim * 0.35)
    Lighting.ColorShift_Top = L.shTop
    Lighting.ColorShift_Bottom = L.shBot
    Lighting.EnvironmentDiffuseScale = L.envD
    Lighting.EnvironmentSpecularScale = L.envS
    if config.timeMode ~= "Game" then
        Lighting.ClockTime = clockCur
        clockTouched = true
    end

    atmosphere.Density = clamp((L.aDen + wx.fog) * config.haze * indoorMul, 0, 1)
    atmosphere.Offset = L.aOff
    atmosphere.Color = L.aCol:Lerp(wx.fogCol, g)
    atmosphere.Decay = L.aDecay:Lerp(mulC(wx.fogCol, 0.6), g)
    atmosphere.Glare = clamp(L.aGlare * (1 - g), 0, 10)
    atmosphere.Haze = clamp(L.aHaze * (1 + g * 0.8) * config.haze, 0, 10)

    if config.sky ~= "Original" then
        sky.CelestialBodiesShown = true
        sky.StarCount = math.floor(L.stars)
    end
end

local function restoreLighting()
    for _, p in ipairs(LIGHT_PROPS) do
        pcall(function() Lighting[p] = originals[Lighting][p] end)
    end
    local A = originals[atmosphere]
    for _, p in ipairs(ATMO_PROPS) do pcall(function() atmosphere[p] = A[p] end) end
    local S = originals[sky]
    for _, p in ipairs(SKY_PROPS) do pcall(function() sky[p] = S[p] end) end
end

--========================================================
-- Shared helpers
--========================================================
local function Q() return QUALITY[config.quality] or QUALITY.High end

local function isCharacterPart(p)
    local m = p:FindFirstAncestorOfClass("Model")
    return m ~= nil and m:FindFirstChildOfClass("Humanoid") ~= nil
end

local HIDE = CFrame.new(0, -50000, 0)

local function newPart(parent)
    local p = Instance.new("Part")
    p.Anchored = true
    p.CanCollide = false
    p.CanQuery = false
    p.CanTouch = false
    p.CastShadow = false
    p.Massless = true
    p.TopSurface = Enum.SurfaceType.Smooth
    p.BottomSurface = Enum.SurfaceType.Smooth
    p.Parent = parent
    return p
end

--========================================================
-- WORLD WEATHER: real 3D rain / snow that collides with the map
--========================================================
local weatherFolder = new("Folder", { Name = "Weather" }, worldFolder)
local windAngle = rand(0, 6.28)
local windVec = Vector3.new(0, 0, 0)
local wCam, wFlat = Vector3.new(0, 0, 0), Vector3.new(0, 0, 1)

local rainPool, rainData, rainParts, rainCFs = {}, {}, {}, {}
local snowPool, snowData, snowParts, snowCFs = {}, {}, {}, {}
local ROT_RAIN = CFrame.Angles(math.rad(90), 0, 0)

local function makeDropPart(isSnow)
    local p = newPart(weatherFolder)
    p.Material = Enum.Material.Neon
    if isSnow then
        p.Size = Vector3.new(0.16, 0.16, 0.16)
        p.Color = C(245, 248, 255)
        p.Transparency = 0.1
    else
        p.Size = Vector3.new(0.05, 1.7, 0.05)
        p.Color = C(190, 210, 235)
        p.Transparency = 0.5
    end
    p.CFrame = HIDE
    return p
end

-- ripples (flat rings drawn with a SurfaceGui, no textures needed)
local ripplePool = {}
local rippleCursor = 0

local function makeRipple()
    local p = newPart(weatherFolder)
    p.Transparency = 1
    p.Size = Vector3.new(1, 0.02, 1)
    p.CFrame = HIDE
    local sg = new("SurfaceGui", {
        Face = Enum.NormalId.Top,
        SizingMode = Enum.SurfaceGuiSizingMode.FixedSize,
        CanvasSize = Vector2.new(128, 128),
        LightInfluence = 0,
        Adornee = p,
    }, p)
    local f = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 }, sg)
    new("UICorner", { CornerRadius = UDim.new(1, 0) }, f)
    local stroke = new("UIStroke", { Color = C(228, 238, 252), Thickness = 5, Transparency = 1 }, f)
    return { part = p, stroke = stroke, t = 0, dur = 1, size = 1, active = false }
end

local function spawnRipple(pos, normal, big)
    if normal.Y < 0.7 or not config.ripples then return end
    if (pos - wCam).Magnitude > 38 then return end
    local limit = math.floor(Q().ripples * fpsScale)
    if limit < 1 then return end
    rippleCursor = rippleCursor % limit + 1
    local r = ripplePool[rippleCursor]
    if not r then
        r = makeRipple()
        ripplePool[rippleCursor] = r
    end
    r.t = 0
    r.dur = rand(0.45, 0.85)
    r.size = big and rand(2.4, 3.6) or rand(0.9, 1.7)
    r.active = true
    r.part.CFrame = CFrame.new(pos + Vector3.new(0, 0.05, 0))
end

local function respawnDrop(d, isSnow, initial)
    local r = math.sqrt(math.random()) * (isSnow and 48 or 58)
    local a = math.random() * 6.2832
    local cx = wCam.X + wFlat.X * 20 + math.cos(a) * r
    local cz = wCam.Z + wFlat.Z * 20 + math.sin(a) * r
    local start, vel, dist
    if isSnow then
        start = Vector3.new(cx, wCam.Y + 26 + math.random() * 6, cz)
        vel = Vector3.new(windVec.X * 0.5, -(4 + math.random() * 3), windVec.Z * 0.5)
        dist = 70
    else
        start = Vector3.new(cx, wCam.Y + 40 + math.random() * 14, cz)
        vel = Vector3.new(windVec.X, -(105 + math.random() * 30), windVec.Z)
        dist = 150
    end
    local unit = vel.Unit
    local res = castVisible(paramsGeneral, start, unit * dist)
    d.pos, d.vel, d.unit = start, vel, unit
    d.hit = res
    d.tEnd = (res and res.Distance or dist) / vel.Magnitude
    d.t = initial and math.random() * d.tEnd or 0
    d.ph = math.random() * 6.28
end

local function syncPool(pool, data, bp, bc, n, isSnow)
    local cur = #bp
    while cur < n do
        cur = cur + 1
        local part = pool[cur]
        if not part then
            part = makeDropPart(isSnow)
            pool[cur] = part
            data[cur] = {}
        end
        bp[cur] = part
        bc[cur] = HIDE
        respawnDrop(data[cur], isSnow, true)
    end
    while cur > n do
        pool[cur].CFrame = HIDE
        bp[cur] = nil
        bc[cur] = nil
        cur = cur - 1
    end
end

-- lightning bolt made from neon segments, plus a sky flash
local boltCooldown = rand(4, 9)
local function spawnBolt()
    if not camera then return end
    local cp = camera.CFrame.Position
    local ang, dist = rand(0, 6.28), rand(240, 460)
    local base = Vector3.new(cp.X + math.cos(ang) * dist, cp.Y - 30, cp.Z + math.sin(ang) * dist)
    local top = base + Vector3.new(rand(-40, 40), 360, rand(-40, 40))
    local pts = { top }
    local segs = 16
    for i = 1, segs - 1 do
        pts[#pts + 1] = top:Lerp(base, i / segs) + Vector3.new(rand(-18, 18), 0, rand(-18, 18))
    end
    pts[#pts + 1] = base
    local folder = new("Folder", { Name = "Bolt" }, weatherFolder)
    for i = 1, #pts - 1 do
        local a0, a1 = pts[i], pts[i + 1]
        local th = lerp(3, 1.2, i / segs)
        local seg = newPart(folder)
        seg.Material = Enum.Material.Neon
        seg.Color = C(215, 225, 255)
        seg.Size = Vector3.new(th, th, (a1 - a0).Magnitude)
        seg.CFrame = CFrame.lookAt((a0 + a1) / 2, a1)
    end
    flash = 1
    task.delay(0.11, function() if alive then flash = math.max(flash, 0.75) end end)
    task.delay(0.3, function() folder:Destroy() end)
end

local function updateWeather(dt)
    if not camera then return end
    local cf = camera.CFrame
    wCam = cf.Position
    local flat = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
    wFlat = flat.Magnitude > 0.01 and flat.Unit or wFlat

    windAngle = windAngle + dt * 0.05
    local ws = config.wind * wx.wind * 22
    windVec = Vector3.new(math.cos(windAngle) * ws, 0, math.sin(windAngle) * ws)

    local q = Q()
    local rainN = (config.master and wx.rain > 0.02) and math.floor(q.rain * fpsScale * wx.rain) or 0
    local snowN = (config.master and wx.snow > 0.02) and math.floor(q.snow * fpsScale * wx.snow) or 0
    syncPool(rainPool, rainData, rainParts, rainCFs, rainN, false)
    syncPool(snowPool, snowData, snowParts, snowCFs, snowN, true)

    for i = 1, rainN do
        local d = rainData[i]
        d.t = d.t + dt
        if d.t >= d.tEnd then
            local h = d.hit
            if h then spawnRipple(h.Position, h.Normal, h.Material == Enum.Material.Water) end
            respawnDrop(d, false, false)
        end
        local p = d.pos + d.vel * d.t - d.unit * 0.85
        rainCFs[i] = CFrame.lookAt(p, p + d.vel) * ROT_RAIN
    end
    if rainN > 0 then Workspace:BulkMoveTo(rainParts, rainCFs, Enum.BulkMoveMode.FireCFrameChanged) end

    for i = 1, snowN do
        local d = snowData[i]
        d.t = d.t + dt
        if d.t >= d.tEnd then respawnDrop(d, true, false) end
        local p = d.pos + d.vel * d.t
        p = p + Vector3.new(math.sin(d.t * 1.3 + d.ph) * 0.7, 0, math.cos(d.t * 1.1 + d.ph) * 0.7)
        snowCFs[i] = CFrame.new(p)
    end
    if snowN > 0 then Workspace:BulkMoveTo(snowParts, snowCFs, Enum.BulkMoveMode.FireCFrameChanged) end

    for _, r in ipairs(ripplePool) do
        if r.active then
            r.t = r.t + dt
            local k = r.t / r.dur
            if k >= 1 then
                r.active = false
                r.part.CFrame = HIDE
            else
                local sz = lerp(0.2, r.size, 1 - (1 - k) * (1 - k))
                r.part.Size = Vector3.new(sz, 0.02, sz)
                r.stroke.Transparency = 0.2 + 0.8 * k
            end
        end
    end

    local def = WEATHER[config.weather]
    if config.master and config.lightning and def and def.storm then
        boltCooldown = boltCooldown - dt
        if boltCooldown <= 0 then
            spawnBolt()
            boltCooldown = rand(5, 13)
        end
    end
end

--========================================================
-- WET / SNOWY / GLOSSY SURFACES (material aware)
--========================================================
local M = Enum.Material
local MAT_GLOSS = {
    [M.Metal] = 0.85, [M.DiamondPlate] = 0.9, [M.CorrodedMetal] = 0.45, [M.Foil] = 1,
    [M.Marble] = 0.8, [M.Granite] = 0.65, [M.Concrete] = 0.35, [M.Slate] = 0.35,
    [M.Pavement] = 0.4, [M.Asphalt] = 0.3, [M.Brick] = 0.2, [M.Cobblestone] = 0.3,
    [M.Ice] = 0.9, [M.Glass] = 0.8, [M.Plastic] = 0.35, [M.SmoothPlastic] = 0.45,
    [M.Wood] = 0.15, [M.WoodPlanks] = 0.15, [M.Grass] = 0.05, [M.LeafyGrass] = 0.05,
    [M.Sand] = 0.05, [M.Sandstone] = 0.1, [M.Rock] = 0.2, [M.Basalt] = 0.25,
    [M.Limestone] = 0.25, [M.Salt] = 0.2, [M.Mud] = 0.1, [M.Ground] = 0.05,
    [M.Plaster] = 0.2, [M.Rubber] = 0.1, [M.CeramicTiles] = 0.7, [M.ClayRoofTiles] = 0.2,
    [M.RoofShingles] = 0.15, [M.Pebble] = 0.15, [M.Snow] = 0, [M.Fabric] = 0, [M.Carpet] = 0,
    [M.Cardboard] = 0, [M.Leather] = 0.1,
}

local wetness, snowCover = 0, 0
local glossList, glossSet = {}, {}
local glossCursor, glossScanT = 1, 0
local SNOW_COL = C(238, 244, 250)

local overlapGloss = OverlapParams.new()
overlapGloss.FilterType = Enum.RaycastFilterType.Exclude
overlapGloss.FilterDescendantsInstances = { worldFolder }

local function restoreEntry(e)
    pcall(function()
        if e.part.Parent then
            e.part.Reflectance = e.br
            e.part.Color = e.bc
        end
    end)
end

local function restoreAllGloss()
    for i = #glossList, 1, -1 do restoreEntry(glossList[i]) end
    glossList, glossSet = {}, {}
    glossCursor = 1
end

local function applyEntry(e)
    local p = e.part
    if not p.Parent then return end
    local refl = e.br
    if config.gloss then refl = math.max(refl, config.glossStrength * 0.42 * e.f) end
    refl = refl + wetness * config.wetLook * (0.16 + 0.3 * e.f)
    local dark = 1 - 0.28 * wetness * config.wetLook
    local col = e.bc
    col = Color3.new(col.R * dark, col.G * dark, col.B * dark)
    if e.top and snowCover > 0.01 then
        col = col:Lerp(SNOW_COL, snowCover * 0.55)
        refl = refl * (1 - snowCover * 0.7)
    end
    p.Reflectance = clamp(refl, 0, 0.9)
    p.Color = col
end

local function scanGloss()
    local cap = math.floor(Q().glossParts * fpsScale)
    local pos = camera.CFrame.Position
    local radius = config.glossRadius

    local i = 1
    while i <= #glossList do
        local e = glossList[i]
        if (not e.part.Parent) or (e.part.Position - pos).Magnitude > radius * 1.35 or i > cap then
            restoreEntry(e)
            glossSet[e.part] = nil
            glossList[i] = glossList[#glossList]
            glossList[#glossList] = nil
        else
            i = i + 1
        end
    end

    overlapGloss.MaxParts = cap
    local parts = Workspace:GetPartBoundsInRadius(pos, radius, overlapGloss)
    for _, p in ipairs(parts) do
        if #glossList >= cap then break end
        if not glossSet[p] and p.Transparency < 0.9 then
            local f = MAT_GLOSS[p.Material]
            local s = p.Size
            if f and s.X * s.Y * s.Z > 0.8 and not isCharacterPart(p) then
                local e = {
                    part = p, br = p.Reflectance, bc = p.Color, f = f, ver = -1,
                    top = p.CFrame.UpVector.Y > 0.9 and s.Y <= math.max(s.X, s.Z),
                }
                glossList[#glossList + 1] = e
                glossSet[p] = e
            end
        end
    end
end

local function updateGloss(dt)
    wetness = damp(wetness, wx.wet, wx.wet > wetness and 0.35 or 0.06, dt)
    snowCover = damp(snowCover, wx.snow, wx.snow > snowCover and 0.08 or 0.03, dt)

    local need = config.master and (config.gloss or wetness > 0.01 or snowCover > 0.01)
    if not need then
        if #glossList > 0 then restoreAllGloss() end
        return
    end

    glossScanT = glossScanT - dt
    if glossScanT <= 0 then
        glossScanT = 1.2
        scanGloss()
    end

    local key = math.floor(wetness * 60) * 100003 + math.floor(snowCover * 60) * 1009
        + (config.gloss and 1 or 0) + math.floor(config.glossStrength * 100) * 3
        + math.floor(config.wetLook * 100) * 307
    local n = #glossList
    for _ = 1, math.min(n, 220) do
        if glossCursor > n then glossCursor = 1 end
        local e = glossList[glossCursor]
        glossCursor = glossCursor + 1
        if e.ver ~= key then
            applyEntry(e)
            e.ver = key
        end
    end
end

--========================================================
-- WATER tuning (Terrain water, local only)
--========================================================
local WATER_TINTS = {
    Aqua = C(40, 150, 170), Deep = C(8, 60, 90), Emerald = C(20, 120, 100),
    Lagoon = C(60, 190, 200), Murky = C(70, 85, 60),
}
local waterKey = ""
local waterT = 0

local function updateWater(dt)
    if not terrain then return end
    waterT = waterT - dt
    if waterT > 0 then return end
    waterT = 0.25
    local on = config.master and config.waterOn
    local key = tostring(on) .. config.waterReflect .. config.waterTransp .. config.waterWave
        .. config.waterSpeed .. config.waterTint
    if key == waterKey then return end
    waterKey = key
    local o = originals[terrain]
    if on then
        terrain.WaterReflectance = config.waterReflect
        terrain.WaterTransparency = config.waterTransp
        terrain.WaterWaveSize = config.waterWave
        terrain.WaterWaveSpeed = config.waterSpeed
        terrain.WaterColor = WATER_TINTS[config.waterTint] or o.WaterColor
    else
        for _, p in ipairs(WATER_PROPS) do
            if o[p] ~= nil then terrain[p] = o[p] end
        end
    end
end

--========================================================
-- MIRROR REFLECTIONS (characters + props on water / glass / translucent floors)
-- Roblox has no screen-space reflections. Real mirrored copies are only visible
-- through translucent surfaces, so they are used on exactly those.
--========================================================
local mirrorFolder = new("Folder", { Name = "Mirror" }, worldFolder)
local proxies = setmetatable({}, { __mode = "k" })
local charCache = setmetatable({}, { __mode = "k" })
local propList = {}
local frameId = 0
local mirrorAcc, nextPropScan = 0, 0
local mBP, mBC = {}, {}
local mN = 0

local overlapProps = OverlapParams.new()
overlapProps.FilterType = Enum.RaycastFilterType.Exclude
overlapProps.FilterDescendantsInstances = { worldFolder }
overlapProps.MaxParts = 300

local function makeProxy(src)
    local ok, clone = pcall(function() return src:Clone() end)
    if not ok or not clone then return nil end
    for _, d in ipairs(clone:GetDescendants()) do
        if not (d:IsA("DataModelMesh") or d:IsA("SurfaceAppearance") or d:IsA("Decal") or d:IsA("Texture")) then
            pcall(function() d:Destroy() end)
        end
    end
    clone.Anchored = true
    clone.CanCollide = false
    clone.CanQuery = false
    clone.CanTouch = false
    clone.CastShadow = false
    clone.Massless = true
    clone.Reflectance = 0
    clone.Parent = mirrorFolder
    return clone
end

local function addMirror(src, py, alpha)
    if not src.Parent then return end
    local e = proxies[src]
    if e == nil then
        local p = makeProxy(src)
        e = p and { part = p, a = -1 } or false
        proxies[src] = e
    end
    if not e then return end
    e.frame = frameId

    local cf = src.CFrame
    local pos, r, u = cf.Position, cf.RightVector, cf.UpVector
    mN = mN + 1
    mBP[mN] = e.part
    mBC[mN] = CFrame.fromMatrix(
        Vector3.new(pos.X, 2 * py - pos.Y, pos.Z),
        Vector3.new(-r.X, r.Y, -r.Z),
        Vector3.new(u.X, -u.Y, u.Z)
    )
    if math.abs(e.a - alpha) > 0.02 then
        e.a = alpha
        e.part.Transparency = 1 - (1 - src.Transparency) * alpha
    end
end

local function detectPlane(char, root)
    paramsMirror.FilterDescendantsInstances = { char, worldFolder, camera }
    local res = Workspace:Raycast(root.Position + Vector3.new(0, 4, 0), Vector3.new(0, -90, 0), paramsMirror)
    if not res then return nil, 0 end
    if res.Material == Enum.Material.Water then return res.Position.Y, 1 end
    local inst = res.Instance
    if inst:IsA("BasePart") and not inst:IsA("Terrain") and res.Normal.Y > 0.9 then
        local t = inst.Transparency
        if t >= 0.15 and t <= 0.97 then return res.Position.Y, 0.85 end
    end
    return nil, 0
end

local function updateMirror(dt)
    local q = Q()
    mirrorAcc = mirrorAcc + dt
    if mirrorAcc < 1 / q.mirrorHz then return end
    mirrorAcc = 0
    frameId = frameId + 1
    mN = 0
    table.clear(mBP)
    table.clear(mBC)

    if config.master and config.mirror and camera then
        local now = os.clock()
        local camPos = camera.CFrame.Position
        local primary
        local used = 0

        for _, plr in ipairs(Players:GetPlayers()) do
            local char = plr.Character
            local root = char and char:FindFirstChild("HumanoidRootPart")
            if root and used < 8 then
                local dist = (root.Position - camPos).Magnitude
                if plr == player or dist < 90 then
                    used = used + 1
                    local info = charCache[char]
                    if not info then
                        info = { parts = {}, nextList = 0, nextPlane = 0, py = nil, str = 0 }
                        charCache[char] = info
                    end
                    if now >= info.nextList then
                        info.nextList = now + 1.2
                        table.clear(info.parts)
                        for _, d in ipairs(char:GetDescendants()) do
                            if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" and d.Transparency < 0.95 then
                                info.parts[#info.parts + 1] = d
                            end
                        end
                    end
                    if now >= info.nextPlane then
                        info.nextPlane = now + 0.12
                        info.py, info.str = detectPlane(char, root)
                    end
                    if plr == player then primary = info end
                    if info.py and camPos.Y > info.py + 0.2 then
                        local fade = clamp((90 - dist) / 40, 0, 1)
                        local alpha = clamp(config.mirrorStrength * info.str * 1.15 * fade, 0, 1)
                        if alpha > 0.03 then
                            for _, p in ipairs(info.parts) do addMirror(p, info.py, alpha) end
                        end
                    end
                end
            end
        end

        -- props, only on the plane under the local character
        local cap = math.floor(q.mirrorProps * fpsScale)
        if config.mirrorProps and cap > 0 and primary and primary.py and camPos.Y > primary.py + 0.2 then
            if now >= nextPropScan then
                nextPropScan = now + 0.6
                local py = primary.py
                local found = Workspace:GetPartBoundsInBox(
                    CFrame.new(camPos.X, py + 35, camPos.Z), Vector3.new(120, 80, 120), overlapProps)
                local list = {}
                for _, p in ipairs(found) do
                    if p.Transparency < 0.9 then
                        local s = p.Size
                        local bottom = p.Position.Y - s.Y / 2
                        if s.Magnitude < 70 and not (s.X * s.Z > 900 and s.Y < 8) and bottom > py - 1.5
                            and not isCharacterPart(p) then
                            list[#list + 1] = { p, (p.Position - camPos).Magnitude }
                        end
                    end
                end
                table.sort(list, function(a, b) return a[2] < b[2] end)
                table.clear(propList)
                for i = 1, math.min(cap, #list) do propList[i] = list[i][1] end
            end
            local alpha = clamp(config.mirrorStrength * primary.str * 0.9, 0, 1)
            if alpha > 0.03 then
                for _, p in ipairs(propList) do addMirror(p, primary.py, alpha) end
            end
        end
    end

    if mN > 0 then Workspace:BulkMoveTo(mBP, mBC, Enum.BulkMoveMode.FireCFrameChanged) end

    for src, e in pairs(proxies) do
        if e and e.frame ~= frameId then
            pcall(function() e.part:Destroy() end)
            proxies[src] = nil
        end
    end
end

--========================================================
-- CAMERA: smart depth of field, motion blur, auto exposure
--========================================================
local dofFocus, dofTarget = 60, 60
local dofAcc, aeAcc, aeTarget = 0, 0, 1
local prevLook, mbSmooth = nil, 0
local DOF_OFFS = { { 0, 0, 3 }, { -0.14, 0, 1 }, { 0.14, 0, 1 }, { 0, -0.14, 1 }, { 0, 0.14, 1 } }
local AE_DIRS = {
    Vector3.new(0, 1, 0), Vector3.new(0.7, 0.7, 0), Vector3.new(-0.7, 0.7, 0),
    Vector3.new(0, 0.7, 0.7), Vector3.new(0, 0.7, -0.7),
}

local function focusSample(rays)
    local vp = camera.ViewportSize
    local n = (rays >= 5 and 5) or (rays >= 3 and 3) or 1
    local sumW, sumInv, centerD = 0, 0, config.dofLimit
    for i = 1, n do
        local o = DOF_OFFS[i]
        local ray = camera:ViewportPointToRay(vp.X * 0.5 + o[1] * vp.Y, vp.Y * 0.5 + o[2] * vp.Y)
        local res = castVisible(paramsDof, ray.Origin, ray.Direction * config.dofLimit)
        local d = math.max(res and res.Distance or config.dofLimit, 0.6)
        if i == 1 then centerD = d end
        sumW = sumW + o[3]
        sumInv = sumInv + o[3] / d
    end
    return sumW / sumInv, centerD
end

local function subjectDistance()
    local ch = player.Character
    local head = ch and ch:FindFirstChild("Head")
    if not head then return nil end
    local d = (camera.CFrame.Position - head.Position).Magnitude
    return d >= 3 and d or nil
end

local function updateCamera(dt)
    camera = Workspace.CurrentCamera
    if not camera then return end
    local master = config.master

    -- Depth of field
    local dofOn = master and config.dof
    dofFx.Enabled = dofOn
    if dofOn then
        dofAcc = dofAcc + dt
        if dofAcc >= 0.05 then
            dofAcc = 0
            local mode = config.dofMode
            if mode == "Manual" then
                dofTarget = config.dofManual
            else
                local f, c = focusSample(mode == "Smart" and Q().dofRays or 1)
                local subj = subjectDistance()
                if mode == "Cursor" then
                    dofTarget = c
                elseif mode == "Subject" then
                    dofTarget = subj or c
                else -- Smart: nearest-weighted focus, subject stays sharp against distant backgrounds
                    dofTarget = (subj and f > subj * 3.2) and subj or f
                end
            end
        end
        local lf = damp(math.log(math.max(dofFocus, 0.5)), math.log(math.max(dofTarget, 0.5)), config.dofSmooth, dt)
        dofFocus = math.exp(lf)
        local ap = config.aperture
        local ap2 = math.sqrt(ap)
        dofFx.FocusDistance = dofFocus
        dofFx.InFocusRadius = clamp(dofFocus * 0.28 / ap + 1.5, 1.5, 150)
        dofFx.FarIntensity = clamp(config.dofFar * clamp(1.15 - dofFocus / 260, 0.18, 1) * ap2, 0, 1)
        dofFx.NearIntensity = clamp(config.dofNear * clamp((dofFocus - 6) / 50, 0, 1) * ap2, 0, 1)
    end

    -- Motion blur driven by camera rotation speed
    local look = camera.CFrame.LookVector
    if prevLook and dt > 0 then
        local ang = math.deg(math.acos(clamp(prevLook:Dot(look), -1, 1))) / dt
        mbSmooth = damp(mbSmooth, math.min(ang, 1500), 10, dt)
    end
    prevLook = look
    local bs = (master and config.motionBlur > 0) and clamp((mbSmooth - 35) / 20, 0, 1) * config.motionBlur * 9 or 0
    blurFx.Size = bs
    blurFx.Enabled = bs > 0.15

    -- Auto exposure: how open is the sky above the camera?
    aeAcc = aeAcc + dt
    if aeAcc >= 0.12 then
        aeAcc = 0
        if master and config.autoExposure > 0 then
            local pos = camera.CFrame.Position
            local open = 0
            for _, dir in ipairs(AE_DIRS) do
                if not Workspace:Raycast(pos, dir * 350, paramsGeneral) then open = open + 1 end
            end
            aeTarget = open / #AE_DIRS
        else
            aeTarget = 1
        end
    end
    autoOpen = damp(autoOpen, aeTarget, 1.4, dt)
    autoExpoAdd = (master and config.autoExposure > 0) and (1 - autoOpen) * config.autoExposure * 0.9 or 0
end

-- UI and main loop live in their own function: Luau allows only 200 locals per function.
local okUI, errUI = pcall(function()

--========================================================
-- OVERLAY: vignette + letterbox bars
--========================================================
local overlay = new("ScreenGui", {
    Name = OVERLAY_NAME, ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 5,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, playerGui)
createdObjects[#createdObjects + 1] = overlay

local function vigEdge(pos, size, rot)
    local f = new("Frame", {
        Position = pos, Size = size, BackgroundColor3 = Color3.new(0, 0, 0),
        BorderSizePixel = 0, Active = false, Visible = false,
    }, overlay)
    return { frame = f, grad = new("UIGradient", { Rotation = rot }, f) }
end
local vigEdges = {
    vigEdge(UDim2.fromScale(0, 0), UDim2.fromScale(0.2, 1), 0),
    vigEdge(UDim2.fromScale(0.8, 0), UDim2.fromScale(0.2, 1), 180),
    vigEdge(UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.28), 90),
    vigEdge(UDim2.fromScale(0, 0.72), UDim2.fromScale(1, 0.28), 270),
}
local barTop = new("Frame", { Size = UDim2.fromScale(1, 0), BackgroundColor3 = Color3.new(0, 0, 0), BorderSizePixel = 0 }, overlay)
local barBottom = new("Frame", {
    AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.fromScale(1, 0),
    BackgroundColor3 = Color3.new(0, 0, 0), BorderSizePixel = 0,
}, overlay)
local barsAlpha, lastVig = 0, -1

local function updateOverlay(dt)
    local v = config.master and config.vignette or 0
    if math.abs(v - lastVig) > 0.005 then
        lastVig = v
        local seq = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 1 - clamp(v, 0, 1) * 0.85),
            NumberSequenceKeypoint.new(1, 1),
        })
        for _, e in ipairs(vigEdges) do
            e.grad.Transparency = seq
            e.frame.Visible = v > 0.01
        end
    end
    barsAlpha = damp(barsAlpha, (config.master and config.bars) and 1 or 0, 7, dt)
    local h = 0.115 * barsAlpha
    barTop.Size = UDim2.fromScale(1, h)
    barBottom.Size = UDim2.fromScale(1, h)
end

--========================================================
-- UI  (minimal, dark, one accent colour)
--========================================================
local T = {
    bg = C(14, 15, 18), chip = C(28, 30, 37), off = C(46, 49, 58), stroke = C(38, 40, 48),
    text = C(232, 234, 240), muted = C(124, 129, 145), accent = C(125, 148, 255),
    danger = C(255, 118, 118), dark = C(10, 10, 14),
}
local FONT_R = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Regular)
local FONT_M = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Medium)
local FONT_B = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold)

local gui = new("ScreenGui", {
    Name = GUI_NAME, ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 100,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, playerGui)

local function label(parent, text, size, color, font, sz, pos, align)
    return new("TextLabel", {
        BackgroundTransparency = 1, Text = text, TextSize = size, TextColor3 = color, FontFace = font,
        Size = sz or UDim2.new(1, 0, 1, 0), Position = pos or UDim2.new(),
        TextXAlignment = align or Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
    }, parent)
end

local root = new("CanvasGroup", {
    Name = "Window", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(680, 470), BackgroundColor3 = T.bg, BorderSizePixel = 0, GroupTransparency = 1,
}, gui)
new("UICorner", { CornerRadius = UDim.new(0, 16) }, root)
new("UIStroke", { Color = T.stroke, Thickness = 1 }, root)
local uiScale = new("UIScale", { Scale = 0.96 }, root)

local sidebar = new("Frame", { Size = UDim2.new(0, 176, 1, 0), BackgroundTransparency = 1 }, root)
new("Frame", { Size = UDim2.new(0, 1, 1, 0), Position = UDim2.new(1, -1, 0, 0), BackgroundColor3 = T.stroke, BorderSizePixel = 0 }, sidebar)
local brand = new("Frame", { Size = UDim2.new(1, 0, 0, 70), BackgroundTransparency = 1, Active = true }, sidebar)
label(brand, "RTX", 20, T.text, FONT_B, UDim2.new(1, -20, 0, 26), UDim2.fromOffset(22, 20))
label(brand, "PREMIUM  ·  v" .. VERSION, 10, T.muted, FONT_M, UDim2.new(1, -20, 0, 14), UDim2.fromOffset(22, 44))

local tabList = new("Frame", { Size = UDim2.new(1, 0, 1, -130), Position = UDim2.fromOffset(0, 76), BackgroundTransparency = 1 }, sidebar)
new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, tabList)
new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }, tabList)

local fpsLabel = label(sidebar, "", 11, T.muted, FONT_M, UDim2.new(1, -40, 0, 16), UDim2.new(0, 22, 1, -52))
local hintLabel = label(sidebar, "", 11, T.muted, FONT_R, UDim2.new(1, -40, 0, 16), UDim2.new(0, 22, 1, -32))

local content = new("Frame", { Size = UDim2.new(1, -176, 1, 0), Position = UDim2.fromOffset(176, 0), BackgroundTransparency = 1 }, root)
local header = new("Frame", { Size = UDim2.new(1, 0, 0, 70), BackgroundTransparency = 1, Active = true }, content)
local titleLabel = label(header, "", 20, T.text, FONT_B, UDim2.new(1, -90, 0, 26), UDim2.fromOffset(24, 18))
local subLabel = label(header, "", 12, T.muted, FONT_R, UDim2.new(1, -90, 0, 16), UDim2.fromOffset(24, 44))
local closeBtn = new("TextButton", {
    Size = UDim2.fromOffset(30, 30), Position = UDim2.new(1, -46, 0, 20), BackgroundColor3 = T.chip,
    Text = "✕", TextSize = 12, TextColor3 = T.muted, FontFace = FONT_B, AutoButtonColor = true, BorderSizePixel = 0,
}, header)
new("UICorner", { CornerRadius = UDim.new(1, 0) }, closeBtn)

-- control registry (everything reads/writes `config`, so save/load/reset is trivial)
local controls = {}
local function refreshControls()
    for _, fn in ipairs(controls) do fn() end
end

-- toast
local toastLabel = new("TextLabel", {
    AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -30), AutomaticSize = Enum.AutomaticSize.X,
    Size = UDim2.fromOffset(0, 34), BackgroundColor3 = T.chip, BackgroundTransparency = 1,
    TextTransparency = 1, Text = "", TextSize = 13, TextColor3 = T.text, FontFace = FONT_M, BorderSizePixel = 0,
}, gui)
new("UICorner", { CornerRadius = UDim.new(1, 0) }, toastLabel)
new("UIPadding", { PaddingLeft = UDim.new(0, 18), PaddingRight = UDim.new(0, 18) }, toastLabel)
local toastId = 0
local function toast(msg)
    toastId = toastId + 1
    local id = toastId
    toastLabel.Text = msg
    tween(toastLabel, { BackgroundTransparency = 0.05, TextTransparency = 0 }, 0.15)
    task.delay(1.8, function()
        if toastId == id and toastLabel.Parent then
            tween(toastLabel, { BackgroundTransparency = 1, TextTransparency = 1 }, 0.3)
        end
    end)
end

-- pages
local pages, tabButtons, orders = {}, {}, {}
local TABS = {
    { "Look", "Color, glow and frame" },
    { "Sky", "Time of day and atmosphere" },
    { "Weather", "Rain, storm, snow and fog on the map" },
    { "Camera", "Smart depth of field and lens" },
    { "Reflect", "Gloss, mirrors and water" },
    { "System", "Quality and settings" },
}
local currentTab

local function newPage()
    local sf = new("ScrollingFrame", {
        Size = UDim2.new(1, 0, 1, -70), Position = UDim2.fromOffset(0, 70), BackgroundTransparency = 1,
        BorderSizePixel = 0, ScrollBarThickness = 3, ScrollBarImageColor3 = T.off,
        AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(), Visible = false,
        ScrollingDirection = Enum.ScrollingDirection.Y,
    }, content)
    new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, sf)
    new("UIPadding", {
        PaddingLeft = UDim.new(0, 24), PaddingRight = UDim.new(0, 24),
        PaddingTop = UDim.new(0, 2), PaddingBottom = UDim.new(0, 24),
    }, sf)
    orders[sf] = 0
    return sf
end

local function nextOrder(page)
    orders[page] = orders[page] + 1
    return orders[page]
end

local function row(page, h)
    return new("Frame", { Size = UDim2.new(1, 0, 0, h), BackgroundTransparency = 1, LayoutOrder = nextOrder(page) }, page)
end

local function selectTab(name)
    currentTab = name
    for _, t in ipairs(TABS) do
        local on = t[1] == name
        pages[t[1]].Visible = on
        local b = tabButtons[t[1]]
        tween(b.btn, { BackgroundTransparency = on and 0 or 1 }, 0.15)
        b.btn.TextColor3 = on and T.text or T.muted
        b.bar.Visible = on
        if on then
            titleLabel.Text = t[1]
            subLabel.Text = t[2]
        end
    end
end

for i, t in ipairs(TABS) do
    pages[t[1]] = newPage()
    local btn = new("TextButton", {
        Size = UDim2.new(1, 0, 0, 34), BackgroundColor3 = T.chip, BackgroundTransparency = 1, Text = t[1],
        TextSize = 13, TextColor3 = T.muted, FontFace = FONT_M, TextXAlignment = Enum.TextXAlignment.Left,
        AutoButtonColor = false, BorderSizePixel = 0, LayoutOrder = i,
    }, tabList)
    new("UICorner", { CornerRadius = UDim.new(0, 8) }, btn)
    new("UIPadding", { PaddingLeft = UDim.new(0, 16) }, btn)
    local bar = new("Frame", {
        Size = UDim2.fromOffset(3, 14), Position = UDim2.new(0, -10, 0.5, -7), BackgroundColor3 = T.accent,
        BorderSizePixel = 0, Visible = false,
    }, btn)
    new("UICorner", { CornerRadius = UDim.new(1, 0) }, bar)
    tabButtons[t[1]] = { btn = btn, bar = bar }
    btn.Activated:Connect(function() selectTab(t[1]) end)
end

-- slider drag state is global (one InputChanged for all sliders)
local activeSlider = nil

local function section(page, text)
    local r = row(page, 34)
    label(r, string.upper(text), 10, T.muted, FONT_B, UDim2.new(1, 0, 0, 14), UDim2.new(0, 0, 1, -16))
end

local function note(page, text)
    local l = new("TextLabel", {
        Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1,
        Text = text, TextSize = 11, TextColor3 = T.muted, FontFace = FONT_R, TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
        LayoutOrder = nextOrder(page),
    }, page)
    new("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4) }, l)
end

local function toggle(page, text, key, hint, onChange)
    local r = row(page, hint and 48 or 38)
    label(r, text, 13, T.text, FONT_M, UDim2.new(1, -60, 0, 20), UDim2.fromOffset(0, hint and 5 or 9))
    if hint then label(r, hint, 11, T.muted, FONT_R, UDim2.new(1, -60, 0, 14), UDim2.fromOffset(0, 26)) end
    local sw = new("Frame", {
        Size = UDim2.fromOffset(38, 20), Position = UDim2.new(1, -38, 0.5, -10), BackgroundColor3 = T.off, BorderSizePixel = 0,
    }, r)
    new("UICorner", { CornerRadius = UDim.new(1, 0) }, sw)
    local knob = new("Frame", {
        Size = UDim2.fromOffset(16, 16), Position = UDim2.new(0, 2, 0.5, -8), BackgroundColor3 = T.text, BorderSizePixel = 0,
    }, sw)
    new("UICorner", { CornerRadius = UDim.new(1, 0) }, knob)
    local hit = new("TextButton", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "" }, r)
    local function refresh()
        local on = config[key]
        tween(sw, { BackgroundColor3 = on and T.accent or T.off }, 0.15)
        tween(knob, { Position = on and UDim2.new(1, -18, 0.5, -8) or UDim2.new(0, 2, 0.5, -8) }, 0.15)
    end
    hit.Activated:Connect(function()
        config[key] = not config[key]
        refresh()
        if onChange then onChange(config[key]) end
    end)
    controls[#controls + 1] = refresh
    refresh()
end

local function slider(page, text, key, mn, mx, dec, onChange)
    local r = row(page, 48)
    label(r, text, 13, T.text, FONT_M, UDim2.new(1, -70, 0, 22), UDim2.fromOffset(0, 2))
    local val = label(r, "", 12, T.muted, FONT_M, UDim2.fromOffset(70, 22), UDim2.new(1, -70, 0, 2), Enum.TextXAlignment.Right)
    local track = new("Frame", {
        Size = UDim2.new(1, 0, 0, 4), Position = UDim2.fromOffset(0, 33), BackgroundColor3 = T.off, BorderSizePixel = 0,
    }, r)
    new("UICorner", { CornerRadius = UDim.new(1, 0) }, track)
    local fill = new("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = T.accent, BorderSizePixel = 0 }, track)
    new("UICorner", { CornerRadius = UDim.new(1, 0) }, fill)
    local knob = new("Frame", {
        Size = UDim2.fromOffset(12, 12), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5),
        BackgroundColor3 = T.text, BorderSizePixel = 0,
    }, track)
    new("UICorner", { CornerRadius = UDim.new(1, 0) }, knob)
    local hit = new("TextButton", {
        Size = UDim2.new(1, 0, 0, 28), Position = UDim2.fromOffset(0, 21), BackgroundTransparency = 1, Text = "",
    }, r)

    local function show()
        local v = config[key]
        local pct = clamp((v - mn) / (mx - mn), 0, 1)
        fill.Size = UDim2.fromScale(pct, 1)
        knob.Position = UDim2.fromScale(pct, 0.5)
        val.Text = string.format("%." .. dec .. "f", v)
    end
    local function setX(x)
        local pct = clamp((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
        local m = 10 ^ dec
        local v = math.floor((mn + pct * (mx - mn)) * m + 0.5) / m
        config[key] = v
        show()
        if onChange then onChange(v) end
    end
    hit.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            activeSlider = setX
            setX(input.Position.X)
        end
    end)
    controls[#controls + 1] = show
    show()
end

local function chips(page, text, key, options, onChange)
    local holderRow = new("Frame", {
        Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1,
        LayoutOrder = nextOrder(page),
    }, page)
    new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, holderRow)
    if text then
        local l = label(holderRow, text, 13, T.text, FONT_M, UDim2.new(1, 0, 0, 20))
        l.LayoutOrder = 1
    end
    local holder = new("Frame", {
        Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = 2,
    }, holderRow)
    new("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal, Wraps = true, Padding = UDim.new(0, 6),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, holder)
    new("UIPadding", { PaddingBottom = UDim.new(0, 6) }, holder)

    local buttons = {}
    for i, o in ipairs(options) do
        local txt = o.label
        local b = new("TextButton", {
            AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 28), BackgroundColor3 = T.chip,
            Text = txt, TextSize = 12, TextColor3 = T.text, FontFace = FONT_M, AutoButtonColor = false,
            BorderSizePixel = 0, RichText = true, LayoutOrder = i,
        }, holder)
        if o.color then
            b.Text = string.format('<font color="#%s">●</font>  %s', o.color:ToHex(), txt)
        end
        new("UICorner", { CornerRadius = UDim.new(1, 0) }, b)
        new("UIPadding", { PaddingLeft = UDim.new(0, 13), PaddingRight = UDim.new(0, 13) }, b)
        buttons[o.id] = b
        b.Activated:Connect(function()
            config[key] = o.id
            if onChange then onChange(o.id) end
            for _, fn in ipairs(controls) do fn() end
        end)
    end
    local function refresh()
        for id, b in pairs(buttons) do
            local on = config[key] == id
            tween(b, { BackgroundColor3 = on and T.accent or T.chip }, 0.12)
            b.TextColor3 = on and T.dark or T.text
        end
    end
    controls[#controls + 1] = refresh
    refresh()
end

local function button(page, text, kind, cb)
    local r = row(page, 40)
    local b = new("TextButton", {
        Size = UDim2.new(1, 0, 0, 34), Position = UDim2.fromOffset(0, 3),
        BackgroundColor3 = kind == "accent" and T.accent or T.chip, Text = text, TextSize = 12,
        TextColor3 = kind == "accent" and T.dark or (kind == "danger" and T.danger or T.text),
        FontFace = FONT_M, AutoButtonColor = true, BorderSizePixel = 0,
    }, r)
    new("UICorner", { CornerRadius = UDim.new(0, 9) }, b)
    b.Activated:Connect(cb)
    return b
end

--========================================================
-- Save / load / reset
--========================================================
local canFile = typeof(writefile) == "function" and typeof(readfile) == "function" and typeof(isfile) == "function"

local function saveConfig()
    if not canFile then return end
    local ok = pcall(function() writefile(SAVE_FILE, HttpService:JSONEncode(config)) end)
    toast(ok and "Settings saved" or "Could not save settings")
end

local function loadConfig(silent)
    if not canFile then return end
    local ok, data = pcall(function()
        if isfile(SAVE_FILE) then return HttpService:JSONDecode(readfile(SAVE_FILE)) end
    end)
    if ok and type(data) == "table" then
        for k, v in pairs(data) do
            if DEFAULTS[k] ~= nil and type(v) == type(DEFAULTS[k]) then config[k] = v end
        end
        refreshControls()
        if not silent then toast("Settings loaded") end
    elseif not silent then
        toast("No saved settings found")
    end
end

--========================================================
-- Tabs content
--========================================================
local function opts(list)
    local out = {}
    for _, v in ipairs(list) do out[#out + 1] = { id = v, label = v } end
    return out
end

-- LOOK
do
    local p = pages.Look
    toggle(p, "Enable effects", "master", "Master switch for everything in this menu", function(on)
        toast(on and "Effects on" or "Effects off")
    end)
    section(p, "Profile")
    chips(p, nil, "profile", opts({ "Natural", "Cinematic", "Vivid", "Clean", "Performance" }), function(id)
        for k, v in pairs(PROFILES[id]) do config[k] = v end
        toast("Profile: " .. id)
    end)
    section(p, "Color")
    slider(p, "Exposure", "exposure", -1, 1, 2)
    slider(p, "Contrast", "contrast", -0.5, 0.5, 2)
    slider(p, "Saturation", "saturation", -0.5, 0.8, 2)
    slider(p, "Warmth", "warmth", -1, 1, 2)
    section(p, "Glow")
    slider(p, "Bloom", "bloom", 0, 2, 2)
    slider(p, "Sun rays", "rays", 0, 2, 2)
    section(p, "Frame")
    slider(p, "Vignette", "vignette", 0, 1, 2)
    toggle(p, "Cinematic bars", "bars")
end

-- SKY
do
    local p = pages.Sky
    local skyOpts = { { id = "Original", label = "Original" }, { id = "Auto", label = "Auto cycle", color = C(255, 255, 255) } }
    for _, id in ipairs(SKY_ORDER) do
        skyOpts[#skyOpts + 1] = { id = id, label = SKIES[id].name, color = SKIES[id].dot }
    end
    chips(p, "Sky", "sky", skyOpts, function(id)
        if id ~= "Original" and config.timeMode == "Game" then config.timeMode = "Manual" end
        if SKIES[id] and config.timeMode == "Manual" then config.clock = SKIES[id].look.clock end
        toast("Sky: " .. (SKIES[id] and SKIES[id].name or id))
    end)
    section(p, "Time")
    chips(p, nil, "timeMode", opts({ "Game", "Manual", "Cycle" }))
    slider(p, "Clock time", "clock", 0, 24, 1)
    slider(p, "Day length (minutes)", "cycleMinutes", 1, 60, 0)
    section(p, "Atmosphere")
    slider(p, "Haze / fog amount", "haze", 0, 2, 2)
    note(p, "Original keeps the game's own lighting. Time \"Game\" never touches the clock, use it in games with their own day/night cycle. Auto cycle blends all skies by clock time; set Time to Cycle to watch it move.")
end

-- WEATHER
do
    local p = pages.Weather
    chips(p, "Weather", "weather", opts(WEATHER_ORDER), function(id) toast("Weather: " .. id) end)
    section(p, "Strength")
    slider(p, "Intensity", "weatherIntensity", 0.1, 1, 2)
    slider(p, "Wind", "wind", 0, 1, 2)
    section(p, "Details")
    toggle(p, "Lightning", "lightning", "Bolts and sky flashes during Storm")
    toggle(p, "Ripples", "ripples", "Rings where rain hits surfaces near you")
    slider(p, "Wet surface look", "wetLook", 0, 1, 2)
    note(p, "Rain and snow are real objects around the camera. They stop on roofs and ceilings, splash on surfaces and are not drawn indoors. Terrain (grass, sand) cannot be re-lit from a client script, only parts get wet or snowy. No sounds are included on purpose, because unverified sound ids would break.")
end

-- CAMERA
do
    local p = pages.Camera
    toggle(p, "Depth of field", "dof", "Background blur that follows what you look at")
    chips(p, "Focus mode", "dofMode", opts({ "Smart", "Cursor", "Subject", "Manual" }))
    slider(p, "Far blur", "dofFar", 0, 1, 2)
    slider(p, "Near blur", "dofNear", 0, 1, 2)
    slider(p, "Aperture", "aperture", 0.3, 2.5, 2)
    slider(p, "Focus speed", "dofSmooth", 2, 16, 1)
    slider(p, "Max focus distance", "dofLimit", 50, 1000, 0)
    slider(p, "Manual focus distance", "dofManual", 3, 500, 0)
    section(p, "Lens")
    slider(p, "Motion blur", "motionBlur", 0, 1, 2)
    slider(p, "Auto exposure", "autoExposure", 0, 1, 2)
    note(p, "Smart focus samples several rays around the screen centre and favours the nearest object. In third person your character stays sharp when you look at distant scenery. Far blur gets stronger the closer you focus.")
end

-- REFLECT
do
    local p = pages.Reflect
    toggle(p, "Surface gloss", "gloss", "Material aware sky and sun reflections on parts")
    slider(p, "Gloss strength", "glossStrength", 0, 1, 2)
    slider(p, "Gloss radius", "glossRadius", 40, 300, 0)
    section(p, "Mirror reflections")
    toggle(p, "Characters", "mirror", "Real mirrored copies on water, glass and translucent floors")
    toggle(p, "Props and objects", "mirrorProps", "Nearby parts are mirrored too")
    slider(p, "Mirror strength", "mirrorStrength", 0, 1, 2)
    section(p, "Water")
    toggle(p, "Enhance water", "waterOn")
    slider(p, "Reflectance", "waterReflect", 0, 1, 2)
    slider(p, "Transparency", "waterTransp", 0, 1, 2)
    slider(p, "Wave size", "waterWave", 0, 1, 2)
    slider(p, "Wave speed", "waterSpeed", 0, 30, 0)
    chips(p, "Water tint", "waterTint", opts({ "Original", "Aqua", "Deep", "Emerald", "Lagoon", "Murky" }))
    note(p, "Roblox has no screen-space reflections. A mirrored image is only visible through something see-through, so characters and props reflect on terrain water, glass and translucent horizontal parts. Opaque floors get material gloss that mirrors the sky and sun instead.")
end

-- SYSTEM
local keyButton
local rebinding = false
local unload -- assigned below
do
    local p = pages.System
    chips(p, "Quality", "quality", opts({ "Low", "Medium", "High", "Ultra" }))
    toggle(p, "Auto quality", "autoQuality", "Lowers weather and mirror load when FPS drops")
    section(p, "Controls")
    keyButton = button(p, "Menu key: B   (click to rebind)", "normal", function()
        rebinding = true
        keyButton.Text = "Press a key..."
    end)
    section(p, "Profiles")
    if canFile then
        button(p, "Save settings", "normal", saveConfig)
        button(p, "Load settings", "normal", function() loadConfig(false) end)
    end
    button(p, "Reset everything to defaults", "normal", function()
        for k, v in pairs(DEFAULTS) do config[k] = v end
        refreshControls()
        toast("Defaults restored")
    end)
    section(p, "Unload")
    button(p, "ANLOAD  /  restore the original look", "danger", function() unload() end)
end

--========================================================
-- Window behaviour: open/close, drag, keys, mobile button
--========================================================
local menuVisible = true
local baseScale = 1

local function setMenu(v)
    menuVisible = v
    if v then
        root.Visible = true
        tween(root, { GroupTransparency = 0 }, 0.2)
        tween(uiScale, { Scale = baseScale }, 0.2)
    else
        tween(root, { GroupTransparency = 1 }, 0.15)
        tween(uiScale, { Scale = baseScale * 0.96 }, 0.15)
        task.delay(0.17, function()
            if not menuVisible and root.Parent then root.Visible = false end
        end)
    end
end

closeBtn.Activated:Connect(function() setMenu(false) end)

local dragging, dragStart, startPos = false, nil, nil
local function bindDrag(frame)
    frame.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = root.Position
        end
    end)
end
bindDrag(header)
bindDrag(brand)

connect(UserInputService.InputChanged, function(input)
    local t = input.UserInputType
    if t ~= Enum.UserInputType.MouseMovement and t ~= Enum.UserInputType.Touch then return end
    if activeSlider then activeSlider(input.Position.X) end
    if dragging then
        local d = input.Position - dragStart
        root.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
    end
end)

connect(UserInputService.InputEnded, function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = false
        activeSlider = nil
    end
end)

local function updateHint()
    hintLabel.Text = "[" .. menuKey.Name .. "]  toggle menu"
end

connect(UserInputService.InputBegan, function(input, processed)
    if unloaded then return end
    if rebinding then
        if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode ~= Enum.KeyCode.Unknown then
            menuKey = input.KeyCode
            rebinding = false
            keyButton.Text = "Menu key: " .. menuKey.Name .. "   (click to rebind)"
            updateHint()
            toast("Menu key: " .. menuKey.Name)
        end
        return
    end
    if processed then return end
    if input.KeyCode == menuKey then setMenu(not menuVisible) end
end)

if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
    local fab = new("TextButton", {
        Size = UDim2.fromOffset(42, 42), Position = UDim2.new(0, 14, 0.5, -21), BackgroundColor3 = T.bg,
        Text = "RTX", TextSize = 11, TextColor3 = T.text, FontFace = FONT_B, BorderSizePixel = 0,
    }, gui)
    new("UICorner", { CornerRadius = UDim.new(1, 0) }, fab)
    new("UIStroke", { Color = T.stroke, Thickness = 1 }, fab)
    fab.Activated:Connect(function() setMenu(not menuVisible) end)
end

--========================================================
-- Unload: restore everything this script touched
--========================================================
unload = function()
    if unloaded then return end
    unloaded = true
    alive = false

    for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
    table.clear(connections)

    restoreAllGloss()

    for obj, props in pairs(originals) do
        for prop, value in pairs(props) do
            if not (obj == Lighting and prop == "ClockTime" and not clockTouched) then
                pcall(function() obj[prop] = value end)
            end
        end
    end

    for _, obj in ipairs(createdObjects) do
        pcall(function() obj:Destroy() end)
    end
    pcall(function() gui:Destroy() end)
    print("[RTX Premium v" .. VERSION .. "] Unloaded. Original values restored.")
end

--========================================================
-- Main loop
--========================================================
local fpsAvg, qTimer, filterTimer, fpsTimer = 60, 0, 0, 0
local failed = {}

local function safe(name, fn, dt)
    local ok, err = pcall(fn, dt)
    if not ok and not failed[name] then
        failed[name] = true
        warn("[RTX Premium] " .. name .. " error: " .. tostring(err))
    end
end

connect(player.CharacterAdded, function() task.defer(refreshFilters) end)

connect(RunService.RenderStepped, function(dt)
    if unloaded then return end
    dt = math.min(dt, 0.1)

    fpsAvg = damp(fpsAvg, 1 / math.max(dt, 0.001), 3, dt)

    filterTimer = filterTimer - dt
    if filterTimer <= 0 then
        filterTimer = 1
        refreshFilters()
    end

    qTimer = qTimer + dt
    if qTimer >= 1.5 then
        qTimer = 0
        if config.autoQuality then
            if fpsAvg < 38 then
                fpsScale = math.max(0.35, fpsScale - 0.12)
            elseif fpsAvg > 55 then
                fpsScale = math.min(1, fpsScale + 0.06)
            end
        else
            fpsScale = 1
        end
    end

    fpsTimer = fpsTimer - dt
    if fpsTimer <= 0 then
        fpsTimer = 0.5
        fpsLabel.Text = string.format("%d FPS", math.floor(fpsAvg + 0.5))
        local s = clamp(math.min(gui.AbsoluteSize.X / 720, gui.AbsoluteSize.Y / 520, 1), 0.5, 1)
        if math.abs(s - baseScale) > 0.01 then
            baseScale = s
            if menuVisible then uiScale.Scale = s end
        end
    end

    safe("camera", updateCamera, dt)
    safe("environment", updateEnvironment, dt)
    safe("weather", updateWeather, dt)
    safe("surfaces", updateGloss, dt)
    safe("mirror", updateMirror, dt)
    safe("water", updateWater, dt)
    safe("overlay", updateOverlay, dt)
end)

--========================================================
-- Start
--========================================================
refreshFilters()
updateHint()
selectTab("Look")
loadConfig(true)
refreshControls()
do
    local s = clamp(math.min(gui.AbsoluteSize.X / 720, gui.AbsoluteSize.Y / 520, 1), 0.5, 1)
    baseScale = s
    uiScale.Scale = s * 0.96
end
setMenu(true)
toast("RTX Premium v" .. VERSION .. "  ·  press " .. menuKey.Name .. " for the menu")
print("[RTX Premium v" .. VERSION .. "] Ready. Press " .. menuKey.Name .. " to toggle the menu.")

end)
if not okUI then
    warn("[RTX Premium] failed to start: " .. tostring(errUI))
end
