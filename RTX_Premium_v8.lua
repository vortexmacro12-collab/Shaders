--[[
    RTX PREMIUM v8.0
    Client-side Roblox graphics controller (LocalScript or executor).
    Default menu key: B  (every key can be changed in the Keys tab)

    v8: rebuilt for stability and coverage
      * Smart DOF            - debounced focus, thin/decor objects ignored, indicator
      * Whole-map surfaces   - every part and mesh gets material-aware gloss, wet and snow looks,
                               streamed in with a time budget (no frame spikes)
      * Characters           - sheen on all characters, full-model mirrored copies on water/glass
      * Sky colour           - any colour via HSV / hex
      * Map recolour         - global palette, per material, click-to-pick part/model, Terrain colours
      * Freecam              - fly separately, character stays visible and still
      * Headlamp             - manual / auto in the dark
      * Puddles, dynamic weather, weather sounds (your ids), mist, underwater filter,
        neon + window glow, photo mode, camera breathing, per-map presets
      * Keys shown next to every feature and rebindable

    UNLOAD (System tab) restores everything this script changed.
]]

local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local ContextActionService = game:GetService("ContextActionService")
local StarterGui = game:GetService("StarterGui")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local VERSION = "8.0"
local GUI_NAME = "RTXPremiumV8"
local OVERLAY_NAME = "RTXPremiumV8_Overlay"
local OWNER_TAG = "RTXPremiumV8_"
local SAVE_FILE = "RTXPremium_v8.json"

--========================================================
-- Remove leftovers of previous versions / copies
--========================================================
for _, name in ipairs({ "RTXPremiumV5", "RTXPremiumV5_WeatherOverlay", "RTXPremiumV7", "RTXPremiumV7_Overlay", GUI_NAME, OVERLAY_NAME }) do
    local old = playerGui:FindFirstChild(name)
    if old then old:Destroy() end
end
for _, child in ipairs(Lighting:GetChildren()) do
    if string.match(child.Name, "^RTXPremiumV%d") then child:Destroy() end
end
for _, name in ipairs({ "RTXPremiumV7_World", OWNER_TAG .. "World" }) do
    local oldWorld = Workspace:FindFirstChild(name)
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
    master = true, quality = "High", autoQuality = true, profile = "Natural", autoPreset = true,

    -- look
    exposure = 0, contrast = 0, saturation = 0, warmth = 0,
    bloom = 1, rays = 1, vignette = 0.2, bars = false,

    -- sky / time
    sky = "Original", timeMode = "Game", clock = 14, cycleMinutes = 8, haze = 1,
    skyColorOn = false, skyH = 0.58, skyS = 0.6, skyV = 0.9, skyMix = 0.7,

    -- weather
    weather = "Clear", weatherIntensity = 0.75, wind = 0.35, lightning = true,
    wetLook = 0.7, ripples = true, puddles = true,
    autoWeather = false, autoWeatherMinutes = 6,
    mist = true, mistAmount = 0.5, underwater = true, underwaterStrength = 0.7,
    soundRain = "", soundThunder = "", soundVolume = 0.5,

    -- camera
    dof = true, dofMode = "Smart", dofFar = 0.45, dofNear = 0, aperture = 1,
    dofLimit = 400, dofSmooth = 6, dofManual = 60, dofIndicator = false,
    motionBlur = 0, autoExposure = 0.5, camBreath = false, camBreathAmt = 0.5,

    -- reflections
    gloss = true, glossStrength = 0.5, specBoost = 1, charSheen = 0.12,
    mirror = true, mirrorStrength = 0.6, mirrorProps = true,
    waterOn = false, waterReflect = 0.7, waterTransp = 0.35, waterWave = 0.25, waterSpeed = 10,
    waterTint = "Original",

    -- world
    mapPalette = "None", mapHue = 0, mapSat = 0, mapVal = 0, mapTerrain = true,
    matRules = "", matPick = "Concrete", pickH = 0.08, pickS = 0.8, pickV = 0.9,
    selMat = "Keep", selUseExtra = false, selTransp = 0, selRefl = 0,
    neonGlow = true, neonStrength = 0.7, windowGlow = true,

    -- tools
    lampMode = "Off", lampThreshold = 0.3, lampBright = 4, lampRange = 45, lampAngle = 70,
    lampShadows = false, lampFill = true, lampAim = "Camera", lampColor = "Warm",
    fcSpeed = 40, fcSmooth = 0.5, fcFov = 70,

    -- keys (KeyCode names, "None" = unbound)
    key_menu = "B", key_master = "RightShift", key_freecam = "V", key_lamp = "H", key_photo = "P",
    key_dof = "N", key_weather = "K", key_timeDown = "LeftBracket", key_timeUp = "RightBracket",
    key_pick = "G",
    key_fc_f = "W", key_fc_b = "S", key_fc_l = "A", key_fc_r = "D",
    key_fc_up = "Space", key_fc_down = "LeftShift", key_fc_fast = "LeftControl", key_fc_slow = "X",
}

local config = {}
for k, v in pairs(DEFAULTS) do config[k] = v end

local QUALITY = {
    Low =    { rain = 110, snow = 70,  ripples = 10, mapParts = 6000,   mirrorProps = 0,  mirrorHz = 30, dofRays = 3, lights = 0,  puddles = 6,  applyMs = 0.8 },
    Medium = { rain = 200, snow = 120, ripples = 18, mapParts = 15000,  mirrorProps = 16, mirrorHz = 45, dofRays = 5, lights = 8,  puddles = 14, applyMs = 1.2 },
    High =   { rain = 340, snow = 190, ripples = 26, mapParts = 40000,  mirrorProps = 40, mirrorHz = 60, dofRays = 9, lights = 16, puddles = 26, applyMs = 1.6 },
    Ultra =  { rain = 520, snow = 300, ripples = 34, mapParts = 100000, mirrorProps = 80, mirrorHz = 60, dofRays = 9, lights = 32, puddles = 40, applyMs = 2.2 },
}
local fpsScale = 1
local function Q() return QUALITY[config.quality] or QUALITY.High end

local PROFILES = {
    Natural =     { exposure = 0,     contrast = 0.02, saturation = 0.04, warmth = 0,    bloom = 0.8, rays = 0.8, vignette = 0.15, bars = false, dofFar = 0.35 },
    Cinematic =   { exposure = -0.05, contrast = 0.12, saturation = 0.02, warmth = 0.25, bloom = 1.2, rays = 1.1, vignette = 0.4,  bars = true,  dofFar = 0.65 },
    Vivid =       { exposure = 0.05,  contrast = 0.1,  saturation = 0.3,  warmth = 0.1,  bloom = 1.3, rays = 1.2, vignette = 0.1,  bars = false, dofFar = 0.4 },
    Clean =       { exposure = 0,     contrast = 0,    saturation = 0,    warmth = 0,    bloom = 0.4, rays = 0.4, vignette = 0,    bars = false, dofFar = 0.2 },
    Performance = { exposure = 0,     contrast = 0.02, saturation = 0.02, warmth = 0,    bloom = 0,   rays = 0,   vignette = 0,    bars = false, dofFar = 0,
                    quality = "Low", dof = false, mirror = false, motionBlur = 0, neonGlow = false, windowGlow = false, puddles = false, camBreath = false },
}

local PALETTES = {
    None   = { 0, 0, 0 },
    Noir   = { 0, -0.9, -0.05 },
    Autumn = { 0.05, 0.2, 0 },
    Cyber  = { -0.12, 0.35, 0 },
    Pastel = { 0, -0.3, 0.18 },
    Toxic  = { 0.22, 0.25, 0 },
    Dusk   = { -0.06, 0.1, -0.22 },
}

-- Shared runtime state between modules
local State = {
    flash = 0, wetness = 0, snowCover = 0, openness = 1, autoExpoAdd = 0,
    under = 0, overWater = false, mist = 0, frozen = false, freecam = false,
    focusDist = 60, sel = nil,
    toast = function() end, refreshUI = function() end,
}
local Mod = {}

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
-- Shared helpers
--========================================================
local HIDE = CFrame.new(0, -50000, 0)

local function isCharacterPart(p)
    local m = p:FindFirstAncestorOfClass("Model")
    return m ~= nil and m:FindFirstChildOfClass("Humanoid") ~= nil
end

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

local keyCodeCache = {}
local function keyCodeOf(name)
    local kc = keyCodeCache[name]
    if kc == nil then
        local ok, v = pcall(function() return Enum.KeyCode[name] end)
        kc = (ok and v) or false
        keyCodeCache[name] = kc
    end
    return kc or nil
end

local function keyDown(id)
    local kc = keyCodeOf(config["key_" .. id] or "None")
    return kc ~= nil and UserInputService:IsKeyDown(kc)
end

local function shiftHSV(c, dh, ds, dv)
    local h, s, v = c:ToHSV()
    return Color3.fromHSV((h + dh) % 1, clamp(s * (1 + ds), 0, 1), clamp(v * (1 + dv), 0, 1))
end

local function wrapDelta(a, b) -- shortest signed distance on a 24h circle
    local d = (b - a) % 24
    if d > 12 then d = d - 24 end
    return d
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
State.wx = wx

--========================================================
-- ENVIRONMENT DIRECTOR: clock, sky, atmosphere, grade, weather blending
--========================================================
do
    local clockCur = Lighting.ClockTime
    local lastPassthrough = false
    local clockTouched = false
    local TEAL = C(30, 125, 145)

    local function restoreSome()
        for _, p in ipairs(LIGHT_PROPS) do
            if p ~= "ClockTime" then pcall(function() Lighting[p] = originals[Lighting][p] end) end
        end
        local A = originals[atmosphere]
        for _, p in ipairs(ATMO_PROPS) do pcall(function() atmosphere[p] = A[p] end) end
        local S = originals[sky]
        for _, p in ipairs(SKY_PROPS) do pcall(function() sky[p] = S[p] end) end
        if not hadAtmosphere then atmosphere.Density = 0 end
    end

    local function update(dt)
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

        -- weather blend
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
        State.flash = State.flash * math.exp(-7 * dt)
        local flash = State.flash

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

        -- mist (water + dawn) and underwater
        local dawn = math.max(0, 1 - math.abs(wrapDelta(clockCur, 6.3)) / 2.2)
        local mistT = config.mist and math.max(State.overWater and 0.8 or 0, dawn * 0.7) or 0
        State.mist = damp(State.mist, mistT, 0.6, dt)
        local mistAdd = State.mist * config.mistAmount * 0.16
        local u = (master and config.underwater) and State.under * config.underwaterStrength or 0
        local sc = (master and config.skyColorOn) and config.skyMix or 0
        local skyCol = Color3.fromHSV(config.skyH, config.skyS, config.skyV)

        -- post effects
        local tint = L.cTint
        local w = config.warmth * 0.08
        tint = Color3.new(clamp(tint.R * (1 + w), 0, 1), tint.G, clamp(tint.B * (1 - w), 0, 1))
        tint = tint:Lerp(C(205, 215, 230), g * 0.35)
        if u > 0.005 then tint = tint:Lerp(C(150, 225, 235), u * 0.6) end

        grade.Enabled = master
        grade.Brightness = L.cBri + flash * 0.16 - u * 0.04
        grade.Contrast = clamp(L.cCon + config.contrast - u * 0.05, -1, 1)
        grade.Saturation = clamp(L.cSat + config.saturation + wx.sat + u * 0.1, -1, 1)
        grade.TintColor = tint

        local bloomI = (L.bloom * (1 + g * 0.25) + flash * 0.35 + u * 0.2) * config.bloom
        bloomFx.Enabled = master and bloomI > 0.01
        bloomFx.Intensity = clamp(bloomI, 0, 3)
        bloomFx.Size = L.bloomSize
        bloomFx.Threshold = L.bloomTh

        local raysI = L.rays * config.rays * wx.rays * (1 - u)
        raysFx.Enabled = master and raysI > 0.005
        raysFx.Intensity = clamp(raysI, 0, 1)

        -- lighting / atmosphere (skipped when nothing changes the game's own look)
        local passthrough = (not master) or (config.sky == "Original" and dim < 0.002 and wx.fog < 0.002
            and math.abs(config.haze - 1) < 0.01 and math.abs(config.exposure) < 0.001
            and flash < 0.002 and State.autoExpoAdd < 0.002 and config.timeMode == "Game"
            and sc < 0.001 and State.mist * config.mistAmount < 0.005 and u < 0.005
            and math.abs(config.specBoost - 1) < 0.01)

        if passthrough then
            if not lastPassthrough then restoreSome() end
            lastPassthrough = true
            return
        end
        lastPassthrough = false

        local indoorMul = 1 - (1 - State.openness) * 0.45 * math.min(1, config.autoExposure * 2)
        local dimL = (1 - dim * 0.55) * (1 - u * 0.35)
        local amb = mulC(L.amb:Lerp(C(110, 115, 125), g * 0.5), (1 - dim * 0.35) * (1 - u * 0.3))
        local outAmb = mulC(L.outAmb:Lerp(C(130, 135, 145), g * 0.5), (1 - dim * 0.35) * (1 - u * 0.3))
        local shTop = L.shTop

        local aDen = (L.aDen + wx.fog + mistAdd) * config.haze * indoorMul
        local aCol = L.aCol:Lerp(wx.fogCol, g)
        local aDecay = L.aDecay:Lerp(mulC(wx.fogCol, 0.6), g)
        local aHaze = L.aHaze * (1 + g * 0.8) * config.haze
        local aGlare = L.aGlare * (1 - g)

        if sc > 0.001 then
            aCol = aCol:Lerp(skyCol, sc)
            aDecay = aDecay:Lerp(mulC(skyCol, 0.55), sc)
            aDen = math.max(aDen, 0.38 * sc + aDen * (1 - sc))
            aHaze = math.max(aHaze, 2.2 * sc)
            amb = amb:Lerp(mulC(skyCol, 0.4), sc * 0.35)
            shTop = shTop:Lerp(mulC(skyCol, 0.3), sc * 0.6)
        end
        if u > 0.005 then
            local wc = TEAL
            if terrain then wc = TEAL:Lerp(terrain.WaterColor, 0.35) end
            aDen = lerp(aDen, math.max(aDen, 0.85), u)
            aCol = aCol:Lerp(wc, u)
            aDecay = aDecay:Lerp(mulC(wc, 0.5), u)
            aHaze = lerp(aHaze, 6, u)
            aGlare = aGlare * (1 - u)
        end

        Lighting.Brightness = L.bright * dimL
        Lighting.ExposureCompensation = clamp(L.expo + config.exposure + State.autoExpoAdd + flash * 1.1, -5, 5)
        Lighting.Ambient = amb
        Lighting.OutdoorAmbient = outAmb
        Lighting.ColorShift_Top = shTop
        Lighting.ColorShift_Bottom = L.shBot
        Lighting.EnvironmentDiffuseScale = L.envD
        Lighting.EnvironmentSpecularScale = clamp(L.envS * config.specBoost, 0, 1)
        if config.timeMode ~= "Game" then
            Lighting.ClockTime = clockCur
            clockTouched = true
        end

        atmosphere.Density = clamp(aDen, 0, 1)
        atmosphere.Offset = L.aOff
        atmosphere.Color = aCol
        atmosphere.Decay = aDecay
        atmosphere.Glare = clamp(aGlare, 0, 10)
        atmosphere.Haze = clamp(aHaze, 0, 10)

        if config.sky ~= "Original" then
            sky.CelestialBodiesShown = true
            sky.StarCount = math.floor(L.stars)
        end
    end

    Mod.env = {
        update = update,
        clockTouched = function() return clockTouched end,
        clock = function() return clockCur end,
    }
end

--========================================================
-- WEATHER: real 3D rain/snow, ripples, puddles, lightning, sounds, auto weather
--========================================================
do
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

    -- puddles: dark glossy discs that grow on flat ground while it is wet
    local puddles = {}
    local function puddleHit(pos, normal, material)
        if not config.puddles or State.wetness < 0.4 or normal.Y < 0.97 then return end
        if material == Enum.Material.Water or math.random() > 0.08 then return end
        local maxN = math.floor(Q().puddles * fpsScale)
        local live = 0
        for _, pd in ipairs(puddles) do
            if pd.alive then
                live = live + 1
                if (pd.pos - pos).Magnitude < 7 then return end
            end
        end
        if live >= maxN then return end
        local pd
        for _, x in ipairs(puddles) do
            if not x.alive then pd = x break end
        end
        if not pd then
            local part = newPart(weatherFolder)
            part.Shape = Enum.PartType.Cylinder
            part.Material = Enum.Material.SmoothPlastic
            part.Color = C(18, 24, 32)
            part.Reflectance = 0.55
            part.Transparency = 1
            part.CFrame = HIDE
            pd = { part = part }
            puddles[#puddles + 1] = pd
        end
        pd.alive = true
        pd.pos = pos
        pd.w, pd.d = rand(3, 8), rand(3, 8)
        pd.scale = 0
        pd.last = -1
        pd.part.CFrame = CFrame.new(pos + Vector3.new(0, 0.04, 0)) * CFrame.Angles(0, rand(0, 6.28), 0) * CFrame.Angles(0, 0, math.rad(90))
    end

    local function updatePuddles(dt)
        local t = clamp((State.wetness - 0.3) / 0.45, 0, 1)
        if not config.master or not config.puddles then t = 0 end
        for _, pd in ipairs(puddles) do
            if pd.alive then
                pd.scale = damp(pd.scale, t, 0.5, dt)
                if t == 0 and pd.scale < 0.03 then
                    pd.alive = false
                    pd.part.CFrame = HIDE
                elseif math.abs(pd.scale - pd.last) > 0.01 then
                    pd.last = pd.scale
                    pd.part.Size = Vector3.new(0.05, pd.w * pd.scale + 0.01, pd.d * pd.scale + 0.01)
                    pd.part.Transparency = 1 - 0.72 * pd.scale
                end
            end
        end
    end

    -- drops
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

    -- sounds (only play when you paste your own ids)
    local rainSnd = new("Sound", { Name = "Rain", Looped = true, Volume = 0 }, worldFolder)
    local thunderSnd = new("Sound", { Name = "Thunder", Volume = 0.8 }, worldFolder)
    local lastRainId, lastThunderId = "", ""
    local function toAsset(s)
        local d = string.match(tostring(s or ""), "%d+")
        return d and ("rbxassetid://" .. d) or ""
    end

    -- lightning
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
        State.flash = 1
        task.delay(0.11, function() if alive then State.flash = math.max(State.flash, 0.75) end end)
        task.delay(0.3, function() folder:Destroy() end)
        task.delay(0.6 + dist / 400, function()
            if alive and thunderSnd.SoundId ~= "" then
                thunderSnd.Volume = config.soundVolume
                thunderSnd:Play()
            end
        end)
    end

    -- automatic weather
    local AUTO_PICKS = { { "Clear", 4 }, { "Rain", 3 }, { "Fog", 1.2 }, { "Storm", 1 }, { "Snow", 1 } }
    local autoT = 60
    local function autoWeather(dt)
        if not config.autoWeather then return end
        autoT = autoT - dt
        if autoT > 0 then return end
        autoT = config.autoWeatherMinutes * 60 * rand(0.7, 1.3)
        local total = 0
        for _, p in ipairs(AUTO_PICKS) do
            if p[1] ~= config.weather then total = total + p[2] end
        end
        local roll = math.random() * total
        for _, p in ipairs(AUTO_PICKS) do
            if p[1] ~= config.weather then
                roll = roll - p[2]
                if roll <= 0 then
                    config.weather = p[1]
                    State.refreshUI()
                    State.toast("Weather: " .. p[1])
                    return
                end
            end
        end
    end

    local function update(dt, realDt)
        if not camera then return end
        autoWeather(realDt)

        State.wetness = damp(State.wetness, wx.wet, wx.wet > State.wetness and 0.35 or 0.06, dt)
        State.snowCover = damp(State.snowCover, wx.snow, wx.snow > State.snowCover and 0.08 or 0.03, dt)

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

        if dt > 0 then
            for i = 1, rainN do
                local d = rainData[i]
                d.t = d.t + dt
                if d.t >= d.tEnd then
                    local h = d.hit
                    if h then
                        local isWater = h.Material == Enum.Material.Water
                        spawnRipple(h.Position, h.Normal, isWater)
                        puddleHit(h.Position, h.Normal, h.Material)
                    end
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
        end
        updatePuddles(dt)

        -- sounds
        local rid = toAsset(config.soundRain)
        if rid ~= lastRainId then
            lastRainId = rid
            rainSnd:Stop()
            rainSnd.SoundId = rid
        end
        local tid = toAsset(config.soundThunder)
        if tid ~= lastThunderId then
            lastThunderId = tid
            thunderSnd.SoundId = tid
        end
        local vol = (rid ~= "" and config.master) and config.soundVolume * clamp(wx.rain, 0, 1.3) * (0.3 + 0.7 * State.openness) or 0
        rainSnd.Volume = vol
        if vol > 0.01 then
            if not rainSnd.IsPlaying then rainSnd:Play() end
        elseif rainSnd.IsPlaying then
            rainSnd:Pause()
        end

        local def = WEATHER[config.weather]
        if dt > 0 and config.master and config.lightning and def and def.storm then
            boltCooldown = boltCooldown - dt
            if boltCooldown <= 0 then
                spawnBolt()
                boltCooldown = rand(5, 13)
            end
        end
    end

    Mod.weather = { update = update }
end

--========================================================
-- MAP SURFACES: every part and mesh (gloss, wet, snow, recolour), Terrain colours, characters
-- Parts are registered by streaming queues and processed with a per-frame time budget.
--========================================================
do
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
        [M.Cardboard] = 0, [M.Leather] = 0.1, [M.Neon] = 0, [M.ForceField] = 0,
    }
    local SNOW_COL = C(238, 244, 250)
    local TERRAIN_MATS = {
        "Grass", "LeafyGrass", "Sand", "Rock", "Slate", "Mud", "Ground", "Sandstone", "Basalt", "Snow", "Ice",
        "Glacier", "Limestone", "Pavement", "Asphalt", "Brick", "Cobblestone", "Concrete", "CrackedLava", "Salt", "WoodPlanks",
    }
    local NO_SNOW = { Snow = true, Ice = true, Glacier = true, CrackedLava = true }

    local reg, list = {}, {}
    local nearQ, nearH, nearT = {}, 1, 0
    local bgQ, bgH, bgT = {}, 1, 0
    local snap, snapI, snapDone = nil, 1, false
    local cursor, scanned, needScan = 1, 0, true
    local keyVer = 0
    local last = { w = -1, s = -1, g = false, gs = -1, wl = -1, cs = -1, h = 0, sa = 0, v = 0, m = true, rv = -1 }
    local overrides = {}
    local rules, rulesStr, rulesVer = {}, nil, 0
    local neonList, glassList = {}, {}
    local nextNear, nextClean = 0, 0
    local terrainOrig, terrainOK, terrainInit = {}, true, false
    local lastTerr = { w = -1, s = -1, h = 0, sa = 0, v = 0, rv = -1, m = true, t = true }
    local nextTerr = 0
    local picking = false

    local overlapMap = OverlapParams.new()
    overlapMap.FilterType = Enum.RaycastFilterType.Exclude
    overlapMap.FilterDescendantsInstances = { worldFolder }
    overlapMap.MaxParts = 4000

    local highlight = new("Highlight", {
        FillColor = C(125, 148, 255), OutlineColor = C(255, 255, 255), FillTransparency = 0.75,
        OutlineTransparency = 0, DepthMode = Enum.HighlightDepthMode.Occluded,
    }, worldFolder)

    local function darken(c, k) return Color3.new(c.R * k, c.G * k, c.B * k) end

    local function register(p, force)
        if reg[p] or not p.Parent then return nil end
        if p:IsA("Terrain") or p:IsDescendantOf(worldFolder) then return nil end
        if not force and #list >= Q().mapParts then return nil end
        local isChar = isCharacterPart(p)
        if not force and not isChar and p.Transparency >= 0.95 then return nil end
        local sa = p:FindFirstChildOfClass("SurfaceAppearance")
        local mat = p.Material
        local f = MAT_GLOSS[mat]
        if f == nil then f = 0.2 end
        local s = p.Size
        local e = {
            part = p, br = p.Reflectance, bc = p.Color, bm = mat, bt = p.Transparency, f = f,
            char = isChar, sa = sa, sac = sa and sa.Color or nil, ver = -1,
            top = (p.CFrame.UpVector.Y > 0.9 and s.Y <= math.max(s.X, s.Z)),
        }
        reg[p] = e
        list[#list + 1] = e
        if not isChar then
            if mat == M.Neon then
                neonList[#neonList + 1] = p
            elseif mat == M.Glass and math.min(s.X, s.Y, s.Z) < 1.5 and s.Magnitude > 3 then
                glassList[#glassList + 1] = p
            end
        end
        needScan = true
        scanned = 0
        return e
    end

    local function applyEntry(e, active)
        local p = e.part
        if e.char then
            local want = e.br
            if active and config.charSheen > 0.001 then want = math.max(want, config.charSheen) end
            p.Reflectance = want
            return
        end
        if not active then
            if e.sa then
                e.sa.Color = e.sac
            else
                p.Color = e.bc
                p.Reflectance = e.br
            end
            if p.Material ~= e.bm then p.Material = e.bm end
            if p.Transparency ~= e.bt then p.Transparency = e.bt end
            return
        end

        local ov = overrides[p]
        local col = e.bc
        local recolor = false
        if config.mapHue ~= 0 or config.mapSat ~= 0 or config.mapVal ~= 0 then
            col = shiftHSV(col, config.mapHue, config.mapSat, config.mapVal)
            recolor = true
        end
        local rule = rules[e.bm.Name]
        if rule then col = rule recolor = true end
        local mat, tr, refl, f = e.bm, e.bt, nil, e.f
        if ov then
            if ov.color then col = ov.color recolor = true end
            if ov.material then
                mat = ov.material
                f = MAT_GLOSS[mat] or 0.2
            end
            if ov.transp then tr = ov.transp end
            refl = ov.refl
        end
        if e.sa and not recolor then col = e.sac end

        local wet = State.wetness * config.wetLook
        local snow = State.snowCover
        if wet > 0.005 then col = darken(col, 1 - 0.28 * wet) end
        if e.top and snow > 0.01 then col = col:Lerp(SNOW_COL, snow * 0.55) end

        if refl == nil then
            refl = e.br
            if config.gloss then refl = math.max(refl, config.glossStrength * 0.42 * f) end
            refl = refl + wet * (0.16 + 0.3 * f)
            if e.top and snow > 0.01 then refl = refl * (1 - snow * 0.7) end
        end

        if e.sa then
            e.sa.Color = col
        else
            p.Color = col
            p.Reflectance = clamp(refl, 0, 0.9)
        end
        if p.Material ~= mat then p.Material = mat end
        if p.Transparency ~= tr then p.Transparency = tr end
    end

    local function parseRules()
        if config.matRules == rulesStr then return end
        rulesStr = config.matRules
        rules = {}
        for name, hex in string.gmatch(rulesStr, "(%a+)=(%x%x%x%x%x%x)") do
            rules[name] = Color3.fromHex(hex)
        end
        rulesVer = rulesVer + 1
    end

    local function serializeRules(t)
        local names = {}
        for n in pairs(t) do names[#names + 1] = n end
        table.sort(names)
        local out = {}
        for _, n in ipairs(names) do out[#out + 1] = n .. "=" .. t[n]:ToHex() end
        return table.concat(out, ";")
    end

    local function ruleHexTable()
        local t = {}
        for name, hex in string.gmatch(config.matRules, "(%a+)=(%x%x%x%x%x%x)") do t[name] = Color3.fromHex(hex) end
        return t
    end

    -- Terrain colours (wet, snow, palette, rules)
    local function initTerrain()
        terrainInit = true
        if not terrain then terrainOK = false return end
        for _, name in ipairs(TERRAIN_MATS) do
            local ok, c = pcall(function() return terrain:GetMaterialColor(Enum.Material[name]) end)
            if ok and c then terrainOrig[name] = c end
        end
    end

    local function applyTerrain()
        local active = config.master
        local grade = config.mapTerrain and (config.mapHue ~= 0 or config.mapSat ~= 0 or config.mapVal ~= 0)
        for _, name in ipairs(TERRAIN_MATS) do
            local orig = terrainOrig[name]
            if orig then
                local col = orig
                if active then
                    if grade then col = shiftHSV(col, config.mapHue, config.mapSat, config.mapVal) end
                    if rules[name] then col = rules[name] end
                    local wet = State.wetness * config.wetLook
                    if wet > 0.005 then col = darken(col, 1 - 0.22 * wet) end
                    if State.snowCover > 0.01 and not NO_SNOW[name] then col = col:Lerp(SNOW_COL, State.snowCover * 0.65) end
                end
                local ok = pcall(function() terrain:SetMaterialColor(Enum.Material[name], col) end)
                if not ok then terrainOK = false return end
            end
        end
    end

    local function update(dt)
        local q = Q()
        local active = config.master
        parseRules()

        local wB, sB = math.floor(State.wetness * 60), math.floor(State.snowCover * 60)
        if wB ~= last.w or sB ~= last.s or config.gloss ~= last.g or config.glossStrength ~= last.gs
            or config.wetLook ~= last.wl or config.charSheen ~= last.cs or config.mapHue ~= last.h
            or config.mapSat ~= last.sa or config.mapVal ~= last.v or active ~= last.m or rulesVer ~= last.rv then
            last.w, last.s, last.g, last.gs, last.wl, last.cs = wB, sB, config.gloss, config.glossStrength, config.wetLook, config.charSheen
            last.h, last.sa, last.v, last.m, last.rv = config.mapHue, config.mapSat, config.mapVal, active, rulesVer
            keyVer = keyVer + 1
            needScan = true
            scanned = 0
        end

        local t0 = os.clock()
        local budget = q.applyMs * 0.001 * math.max(fpsScale, 0.4)
        local now = t0

        if not snap and not snapDone then
            snap = Workspace:GetDescendants()
            snapI = 1
        end

        -- near scan: nearest parts are registered first
        if camera and now >= nextNear then
            nextNear = now + 2
            local found = Workspace:GetPartBoundsInRadius(camera.CFrame.Position, 320, overlapMap)
            for _, p in ipairs(found) do
                if reg[p] == nil then
                    nearT = nearT + 1
                    nearQ[nearT] = p
                end
            end
        end
        if now >= nextClean then
            nextClean = now + 4
            needScan = true
            scanned = 0
        end

        -- registration (45% of the budget)
        local regEnd = t0 + budget * 0.45
        local n = 0
        while nearH <= nearT do
            local p = nearQ[nearH]
            nearQ[nearH] = nil
            nearH = nearH + 1
            if p and p.Parent then register(p) end
            n = n + 1
            if n % 8 == 0 and os.clock() > regEnd then break end
        end
        if nearH > nearT then nearQ, nearH, nearT = {}, 1, 0 end

        while bgH <= bgT and os.clock() < regEnd do
            local p = bgQ[bgH]
            bgQ[bgH] = nil
            bgH = bgH + 1
            if p and p.Parent then register(p) end
        end
        if bgH > bgT then bgQ, bgH, bgT = {}, 1, 0 end

        if snap then
            n = 0
            while snapI <= #snap do
                local d = snap[snapI]
                snapI = snapI + 1
                if d:IsA("BasePart") then register(d) end
                n = n + 1
                if n % 16 == 0 and os.clock() > regEnd then break end
            end
            if snapI > #snap then
                snap = nil
                snapDone = true
            end
        end

        -- apply
        if needScan then
            local applyEnd = t0 + budget
            local count = #list
            n = 0
            while scanned < count and count > 0 do
                if cursor > count then cursor = 1 end
                local e = list[cursor]
                if e.dead or not e.part.Parent then
                    reg[e.part] = nil
                    list[cursor] = list[count]
                    list[count] = nil
                    count = count - 1
                else
                    if e.ver ~= keyVer then
                        applyEntry(e, active)
                        e.ver = keyVer
                    end
                    cursor = cursor + 1
                end
                scanned = scanned + 1
                n = n + 1
                if n % 16 == 0 and os.clock() > applyEnd then break end
            end
            if scanned >= count then needScan = false end
        end

        -- terrain
        if now >= nextTerr then
            nextTerr = now + 0.3
            if not terrainInit then initTerrain() end
            if terrainOK then
                local tOn = config.mapTerrain
                if wB ~= lastTerr.w or sB ~= lastTerr.s or config.mapHue ~= lastTerr.h or config.mapSat ~= lastTerr.sa
                    or config.mapVal ~= lastTerr.v or rulesVer ~= lastTerr.rv or active ~= lastTerr.m or tOn ~= lastTerr.t then
                    lastTerr.w, lastTerr.s, lastTerr.h, lastTerr.sa, lastTerr.v = wB, sB, config.mapHue, config.mapSat, config.mapVal
                    lastTerr.rv, lastTerr.m, lastTerr.t = rulesVer, active, tOn
                    applyTerrain()
                end
            end
        end
    end

    --------------------------------------------------------
    -- Streaming hooks
    --------------------------------------------------------
    connect(Workspace.DescendantAdded, function(d)
        if d:IsA("BasePart") then
            bgT = bgT + 1
            bgQ[bgT] = d
        end
    end)
    connect(Workspace.DescendantRemoving, function(d)
        local e = reg[d]
        if e then
            e.dead = true
            reg[d] = nil
        end
    end)

    --------------------------------------------------------
    -- Picking and manual recolour
    --------------------------------------------------------
    local function pickColor() return Color3.fromHSV(config.pickH, config.pickS, config.pickV) end

    local function selectionText()
        local s = State.sel
        if not s then return "Nothing selected" end
        if s.terrain then return "Terrain  ·  " .. s.mat.Name end
        local part = s.part
        if not part or not part.Parent then return "Nothing selected" end
        local m = part:FindFirstAncestorOfClass("Model")
        return part.Name .. "  ·  " .. part.Material.Name .. (m and ("   (model: " .. m.Name .. ")") or "")
    end

    local function startPick()
        picking = true
        State.toast("Click an object to select it  (Esc cancels)")
    end
    local function cancelPick() picking = false end

    local function handleClick()
        if not picking or not camera then return false end
        picking = false
        local loc = UserInputService:GetMouseLocation()
        local ray = camera:ViewportPointToRay(loc.X, loc.Y)
        local pp = newParams()
        pp.FilterDescendantsInstances = { worldFolder }
        local res = Workspace:Raycast(ray.Origin, ray.Direction * 3000, pp)
        if not res then
            State.toast("Nothing hit")
            return true
        end
        if res.Instance:IsA("Terrain") then
            State.sel = { terrain = true, mat = res.Material }
            highlight.Adornee = nil
        else
            State.sel = { part = res.Instance, mat = res.Material }
            highlight.Adornee = res.Instance
        end
        State.toast("Selected: " .. selectionText())
        State.refreshUI()
        return true
    end

    local function targetsFor(scope)
        local s = State.sel
        if not s or s.terrain or not s.part or not s.part.Parent then return {} end
        if scope == "model" then
            local m = s.part:FindFirstAncestorOfClass("Model")
            if m then
                local out = {}
                for _, d in ipairs(m:GetDescendants()) do
                    if d:IsA("BasePart") and #out < 2500 then out[#out + 1] = d end
                end
                return out
            end
        end
        return { s.part }
    end

    local function applyToSelection(scope)
        local s = State.sel
        if not s then State.toast("Pick an object first") return end
        local col = pickColor()
        if s.terrain then
            local t = ruleHexTable()
            t[s.mat.Name] = col
            config.matRules = serializeRules(t)
            State.toast("Terrain " .. s.mat.Name .. " recoloured")
            return
        end
        local count = 0
        for _, p in ipairs(targetsFor(scope)) do
            local e = reg[p] or register(p, true)
            if e then
                overrides[p] = {
                    color = col,
                    material = (config.selMat ~= "Keep") and Enum.Material[config.selMat] or nil,
                    transp = config.selUseExtra and config.selTransp or nil,
                    refl = config.selUseExtra and config.selRefl or nil,
                }
                e.ver = -1
                count = count + 1
            end
        end
        needScan = true
        scanned = 0
        State.toast(count .. " part(s) recoloured")
    end

    local function revertSelection(scope)
        local s = State.sel
        if not s then return end
        if s.terrain then
            local t = ruleHexTable()
            t[s.mat.Name] = nil
            config.matRules = serializeRules(t)
            return
        end
        for _, p in ipairs(targetsFor(scope)) do
            overrides[p] = nil
            local e = reg[p]
            if e then e.ver = -1 end
        end
        needScan = true
        scanned = 0
    end

    local function revertAllOverrides()
        for p in pairs(overrides) do
            local e = reg[p]
            if e then e.ver = -1 end
        end
        overrides = {}
        needScan = true
        scanned = 0
        State.toast("Part recolours cleared")
    end

    local function setRule(name)
        local t = ruleHexTable()
        t[name] = pickColor()
        config.matRules = serializeRules(t)
        State.toast("Rule set for " .. name)
    end
    local function removeRule(name)
        local t = ruleHexTable()
        t[name] = nil
        config.matRules = serializeRules(t)
    end
    local function clearRules()
        config.matRules = ""
        State.toast("Material rules cleared")
    end

    local function restoreAll()
        highlight.Adornee = nil
        for _, e in ipairs(list) do
            if e.part and e.part.Parent then
                pcall(function() applyEntry(e, false) end)
            end
        end
        if terrain and terrainInit then
            for name, c in pairs(terrainOrig) do
                pcall(function() terrain:SetMaterialColor(Enum.Material[name], c) end)
            end
        end
    end

    Mod.map = {
        update = update, restoreAll = restoreAll, startPick = startPick, cancelPick = cancelPick,
        isPicking = function() return picking end, handleClick = handleClick,
        applyToSelection = applyToSelection, revertSelection = revertSelection, revertAllOverrides = revertAllOverrides,
        setRule = setRule, removeRule = removeRule, clearRules = clearRules, selectionText = selectionText,
        neonList = neonList, glassList = glassList,
    }
end

--========================================================
-- WATER tuning (Terrain water, local only)
--========================================================
do
    local WATER_TINTS = {
        Aqua = C(40, 150, 170), Deep = C(8, 60, 90), Emerald = C(20, 120, 100),
        Lagoon = C(60, 190, 200), Murky = C(70, 85, 60),
    }
    local waterKey, waterT = "", 0

    local function update(dt)
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
    Mod.water = { update = update }
end

--========================================================
-- MIRROR REFLECTIONS: whole-model character copies + props on water / glass / translucent floors
-- (Roblox has no screen-space reflections; a mirrored copy is only visible through see-through surfaces.)
--========================================================
do
    local mirrorFolder = new("Folder", { Name = "Mirror" }, worldFolder)
    local propProxies = setmetatable({}, { __mode = "k" })
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

    local function stripClone(clone)
        for _, d in ipairs(clone:GetDescendants()) do
            if d:IsA("Script") or d:IsA("LocalScript") or d:IsA("ModuleScript") or d:IsA("JointInstance")
                or d:IsA("Constraint") or d:IsA("WeldConstraint") or d:IsA("BillboardGui") or d:IsA("SurfaceGui")
                or d:IsA("ParticleEmitter") or d:IsA("Sound") or d:IsA("Light") or d:IsA("ForceField")
                or d:IsA("Fire") or d:IsA("Smoke") or d:IsA("Sparkles") or d:IsA("Trail") or d:IsA("Beam")
                or d:IsA("Highlight") or d:IsA("SelectionBox") or d:IsA("Animator") or d:IsA("Attachment")
                or d:IsA("ProximityPrompt") or d:IsA("ClickDetector") then
                pcall(function() d:Destroy() end)
            end
        end
    end

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

    local function reflectedCF(cf, py)
        local pos, r, u = cf.Position, cf.RightVector, cf.UpVector
        return CFrame.fromMatrix(
            Vector3.new(pos.X, 2 * py - pos.Y, pos.Z),
            Vector3.new(-r.X, r.Y, -r.Z),
            Vector3.new(u.X, -u.Y, u.Z)
        )
    end

    local function pushMove(part, cf)
        mN = mN + 1
        mBP[mN] = part
        mBC[mN] = cf
    end

    local function collectParts(model)
        local out = {}
        for _, d in ipairs(model:GetDescendants()) do
            if d:IsA("BasePart") then out[#out + 1] = d end
        end
        return out
    end

    -- whole character clone (keeps clothes, body colours, accessories)
    local function buildCharMirror(char, info)
        local ok, clone = pcall(function() return char:Clone() end)
        if not ok or not clone then return false end
        local hum = clone:FindFirstChildOfClass("Humanoid")
        if hum then
            hum.RequiresNeck = false
            hum.BreakJointsOnDeath = false
            hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
            hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
        end
        stripClone(clone)
        local cp = collectParts(clone)
        for _, p in ipairs(cp) do
            p.Anchored = true
            p.CanCollide = false
            p.CanQuery = false
            p.CanTouch = false
            p.CastShadow = false
            p.Massless = true
            p.Reflectance = 0
        end
        clone.Name = "RTXMirror"
        clone.Parent = mirrorFolder
        info.clone = clone
        info.src = collectParts(char)
        info.proxy = cp
        info.alpha = -1
        return #info.src == #info.proxy
    end

    local function destroyCharMirror(info)
        if info.clone then
            pcall(function() info.clone:Destroy() end)
        end
        info.clone, info.src, info.proxy = nil, nil, nil
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

    local function addProp(src, py, alpha)
        if not src.Parent then return end
        local e = propProxies[src]
        if e == nil then
            local p = makeProxy(src)
            e = p and { part = p, a = -1 } or false
            propProxies[src] = e
        end
        if not e then return end
        e.frame = frameId
        pushMove(e.part, reflectedCF(src.CFrame, py))
        if math.abs(e.a - alpha) > 0.02 then
            e.a = alpha
            e.part.Transparency = 1 - (1 - src.Transparency) * alpha
        end
    end

    local function update(dt)
        local q = Q()
        mirrorAcc = mirrorAcc + dt
        if mirrorAcc < 1 / q.mirrorHz then return end
        mirrorAcc = 0
        frameId = frameId + 1
        mN = 0
        table.clear(mBP)
        table.clear(mBC)
        local now = os.clock()

        if config.master and config.mirror and camera then
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
                            info = { nextCheck = 0, nextPlane = 0, py = nil, str = 0, usedAt = now }
                            charCache[char] = info
                        end
                        if now >= info.nextPlane then
                            info.nextPlane = now + 0.12
                            info.py, info.str = detectPlane(char, root)
                        end
                        if plr == player then primary = info end

                        if info.py and camPos.Y > info.py + 0.2 then
                            info.usedAt = now
                            if now >= info.nextCheck then
                                info.nextCheck = now + 1.0
                                local n = 0
                                for _, d in ipairs(char:GetDescendants()) do
                                    if d:IsA("BasePart") then n = n + 1 end
                                end
                                if not info.clone or n ~= #info.src or not info.clone.Parent then
                                    destroyCharMirror(info)
                                    if not buildCharMirror(char, info) then destroyCharMirror(info) end
                                end
                            end
                            if info.clone then
                                local fade = clamp((90 - dist) / 40, 0, 1)
                                local alpha = clamp(config.mirrorStrength * info.str * 1.15 * fade, 0, 1)
                                local changed = math.abs(info.alpha - alpha) > 0.02
                                if changed then info.alpha = alpha end
                                local src, prx = info.src, info.proxy
                                for i = 1, #src do
                                    local s, p = src[i], prx[i]
                                    if s.Parent then
                                        pushMove(p, reflectedCF(s.CFrame, info.py))
                                        if changed then p.Transparency = 1 - (1 - s.Transparency) * alpha end
                                    end
                                end
                            end
                        elseif info.clone and now - info.usedAt > 2 then
                            destroyCharMirror(info)
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
                    for _, p in ipairs(propList) do addProp(p, primary.py, alpha) end
                end
            end
        else
            -- feature off: drop character copies
            for _, plr in ipairs(Players:GetPlayers()) do
                local info = plr.Character and charCache[plr.Character]
                if info and info.clone then destroyCharMirror(info) end
            end
        end

        if mN > 0 then Workspace:BulkMoveTo(mBP, mBC, Enum.BulkMoveMode.FireCFrameChanged) end

        for src, e in pairs(propProxies) do
            if e and e.frame ~= frameId then
                pcall(function() e.part:Destroy() end)
                propProxies[src] = nil
            end
        end
    end

    Mod.mirror = { update = update }
end

--========================================================
-- LIGHT GLOW: neon parts and (at night) windows get soft local lights
--========================================================
do
    local active = {}
    local t = 0

    local function clearAll()
        for p, l in pairs(active) do
            pcall(function() l:Destroy() end)
            active[p] = nil
        end
    end

    local function prune(arr)
        for i = #arr, 1, -1 do
            if not arr[i].Parent then
                arr[i] = arr[#arr]
                arr[#arr] = nil
            end
        end
    end

    local function update(dt)
        t = t - dt
        if t > 0 then return end
        t = 1
        local cap = config.master and math.floor(Q().lights * fpsScale) or 0
        if cap <= 0 or not (config.neonGlow or config.windowGlow) or not camera then
            clearAll()
            return
        end
        local clock = Lighting.ClockTime
        local day = (clock >= 6 and clock <= 18) and math.sin((clock - 6) / 12 * math.pi) or 0
        local night = 1 - clamp(day * 1.4, 0, 1)
        local camPos = camera.CFrame.Position

        local cands = {}
        if config.neonGlow then
            local arr = Mod.map.neonList
            prune(arr)
            for _, p in ipairs(arr) do
                local d = (p.Position - camPos).Magnitude
                if d < 120 and p.Transparency < 0.9 then cands[#cands + 1] = { p, d, true } end
            end
        end
        if config.windowGlow and night > 0.3 then
            local arr = Mod.map.glassList
            prune(arr)
            for _, p in ipairs(arr) do
                local d = (p.Position - camPos).Magnitude
                if d < 90 and p.Transparency < 0.9 then cands[#cands + 1] = { p, d, false } end
            end
        end
        table.sort(cands, function(a, b) return a[2] < b[2] end)

        local keep = {}
        for i = 1, math.min(cap, #cands) do
            local p, _, neon = cands[i][1], cands[i][2], cands[i][3]
            keep[p] = true
            local l = active[p]
            if not l then
                l = Instance.new("PointLight")
                l.Shadows = false
                l.Parent = p
                active[p] = l
            end
            if neon then
                l.Color = p.Color
                l.Range = 14
                l.Brightness = config.neonStrength * (0.5 + 0.5 * night) * 1.4
            else
                l.Color = C(255, 214, 150)
                l.Range = 12
                l.Brightness = config.neonStrength * night * 0.9
            end
        end
        for p, l in pairs(active) do
            if not keep[p] then
                pcall(function() l:Destroy() end)
                active[p] = nil
            end
        end
    end

    Mod.glow = { update = update, destroy = clearAll }
end

--========================================================
-- CAMERA: smart depth of field, motion blur, auto exposure, underwater / water detection
--========================================================
do
    local dofFocus, dofTarget, dofInit = 60, 60, false
    local pend, pendT = nil, 0
    local dofAcc, slowAcc = 0, 0
    local prevLook, mbSmooth = nil, 0
    local underTarget = false

    -- ray pattern: { x, y (fraction of viewport height), weight }
    local PATTERN = {
        { 0, 0, 3 },
        { -0.07, 0, 2 }, { 0.07, 0, 2 }, { 0, -0.07, 2 }, { 0, 0.07, 2 },
        { -0.14, -0.14, 1 }, { 0.14, -0.14, 1 }, { -0.14, 0.14, 1 }, { 0.14, 0.14, 1 },
    }
    local AE_DIRS = {
        Vector3.new(0, 1, 0), Vector3.new(0.7, 0.7, 0), Vector3.new(-0.7, 0.7, 0),
        Vector3.new(0, 0.7, 0.7), Vector3.new(0, 0.7, -0.7),
    }

    -- objects that must not steal the focus: invisible, thin small things, small decor without collision
    local function skipForFocus(inst)
        if not inst:IsA("BasePart") or inst:IsA("Terrain") then return false end
        if inst.Transparency >= 0.85 then return true end
        local s = inst.Size
        local mn, mx = math.min(s.X, s.Y, s.Z), math.max(s.X, s.Y, s.Z)
        if mn < 0.35 and mx < 8 then return true end
        if not inst.CanCollide and s.Magnitude < 5 then return true end
        return false
    end

    local function castFocus(origin, direction)
        local res
        for _ = 1, 5 do
            res = Workspace:Raycast(origin, direction, paramsDof)
            if not res then return nil end
            if skipForFocus(res.Instance) then
                paramsDof:AddToFilter(res.Instance)
            else
                return res
            end
        end
        return res
    end

    local function weightedPick(ds, ws, n, frac)
        local idx = {}
        for i = 1, n do idx[i] = i end
        table.sort(idx, function(a, b) return ds[a] < ds[b] end)
        local total = 0
        for i = 1, n do total = total + ws[i] end
        local acc = 0
        for k = 1, n do
            local i = idx[k]
            acc = acc + ws[i]
            if acc >= total * frac then return ds[i] end
        end
        return ds[idx[n]]
    end

    local function sampleFocus(rays)
        local vp = camera.ViewportSize
        local n = (rays >= 9 and 9) or (rays >= 5 and 5) or 3
        local ds, ws = {}, {}
        local centerD = config.dofLimit
        local count = 0
        for i = 1, n do
            local o = PATTERN[i]
            -- 3-ray mode uses centre + left/right only
            if n > 3 or i <= 3 then
                local ray = camera:ViewportPointToRay(vp.X * 0.5 + o[1] * vp.Y, vp.Y * 0.5 + o[2] * vp.Y)
                local res = castFocus(ray.Origin, ray.Direction * config.dofLimit)
                local d = math.max(res and res.Distance or config.dofLimit, 0.6)
                count = count + 1
                ds[count], ws[count] = d, o[3]
                if i == 1 then centerD = d end
            end
        end
        return weightedPick(ds, ws, count, 0.42), centerD
    end

    local function subjectDistance()
        local ch = player.Character
        local head = ch and ch:FindFirstChild("Head")
        if not head then return nil end
        local d = (camera.CFrame.Position - head.Position).Magnitude
        return d >= 3 and d or nil
    end

    -- debounce: a new focus distance has to persist before the focus moves
    local function consider(sample, dt)
        if not dofInit then
            dofInit = true
            dofTarget, dofFocus = sample, sample
            return
        end
        local ratio = math.abs(math.log(sample / dofTarget))
        if ratio < 0.12 then
            pend, pendT = nil, 0
            dofTarget = math.exp(lerp(math.log(dofTarget), math.log(sample), 0.3))
            return
        end
        if pend and math.abs(math.log(sample / pend)) < 0.15 then
            pendT = pendT + dt
        else
            pend, pendT = sample, 0
        end
        local delay = (sample < dofTarget * 0.6) and 0.1 or 0.18
        if pendT >= delay then
            dofTarget = pend
            pend, pendT = nil, 0
        end
    end

    local function checkUnderwater()
        if not terrain then return false end
        local pos = camera.CFrame.Position
        local ok, res = pcall(function()
            local region = Region3.new(pos - Vector3.new(2, 2, 2), pos + Vector3.new(2, 2, 2)):ExpandToGrid(4)
            local mats = terrain:ReadVoxels(region, 4)
            local min = region.CFrame.Position - region.Size / 2
            local ix = math.floor((pos.X - min.X) / 4) + 1
            local iy = math.floor((pos.Y - min.Y) / 4) + 1
            local iz = math.floor((pos.Z - min.Z) / 4) + 1
            local col = mats[ix] and mats[ix][iy]
            return col and col[iz] == Enum.Material.Water
        end)
        return ok and res == true
    end

    local function checkOverWater()
        local char = player.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if not root then return false end
        local res = Workspace:Raycast(root.Position + Vector3.new(0, 4, 0), Vector3.new(0, -120, 0), paramsGeneral)
        return res ~= nil and res.Material == Enum.Material.Water
    end

    local function update(dt)
        camera = Workspace.CurrentCamera
        if not camera then return end
        local master = config.master

        -- depth of field
        local dofOn = master and config.dof
        dofFx.Enabled = dofOn
        if dofOn then
            dofAcc = dofAcc + dt
            if dofAcc >= 0.05 then
                local step = dofAcc
                dofAcc = 0
                local mode = config.dofMode
                if mode == "Manual" then
                    dofInit = true
                    dofTarget = config.dofManual
                else
                    local f, c = sampleFocus(mode == "Smart" and Q().dofRays or 3)
                    local subj = subjectDistance()
                    local sample
                    if mode == "Cursor" then
                        sample = c
                    elseif mode == "Subject" then
                        sample = subj or c
                    else
                        sample = (subj and f > subj * 3.2) and subj or f
                    end
                    consider(sample, step)
                end
            end
            dofFocus = math.exp(damp(math.log(math.max(dofFocus, 0.5)), math.log(math.max(dofTarget, 0.5)), config.dofSmooth, dt))
            local ap = config.aperture
            local ap2 = math.sqrt(ap)
            State.focusDist = dofFocus
            dofFx.FocusDistance = dofFocus
            dofFx.InFocusRadius = clamp(dofFocus * 0.45 / ap + 4, 4, 220)
            dofFx.FarIntensity = clamp(config.dofFar * clamp(1.1 - dofFocus / 300, 0.25, 1) * ap2, 0, 0.85)
            dofFx.NearIntensity = clamp(config.dofNear * clamp((dofFocus - 8) / 60, 0, 1) * ap2, 0, 0.6)
        end

        -- slow checks (auto exposure, water)
        slowAcc = slowAcc + dt
        if slowAcc >= 0.15 then
            slowAcc = 0
            local needOpen = master and (config.autoExposure > 0 or config.lampMode == "Auto")
            if needOpen then
                local pos = camera.CFrame.Position
                local open = 0
                for _, dir in ipairs(AE_DIRS) do
                    if not Workspace:Raycast(pos, dir * 350, paramsGeneral) then open = open + 1 end
                end
                State.opennessT = open / #AE_DIRS
            else
                State.opennessT = 1
            end
            underTarget = master and config.underwater and checkUnderwater()
            State.overWater = master and config.mist and checkOverWater()
        end
        State.openness = damp(State.openness, State.opennessT or 1, 1.4, dt)
        State.autoExpoAdd = (master and config.autoExposure > 0) and (1 - State.openness) * config.autoExposure * 0.9 or 0
        State.under = damp(State.under, underTarget and 1 or 0, 5, dt)

        -- motion blur from camera rotation, plus underwater softness
        local look = camera.CFrame.LookVector
        if prevLook and dt > 0 then
            local ang = math.deg(math.acos(clamp(prevLook:Dot(look), -1, 1))) / dt
            mbSmooth = damp(mbSmooth, math.min(ang, 1500), 10, dt)
        end
        prevLook = look
        local bs = (master and config.motionBlur > 0) and clamp((mbSmooth - 35) / 20, 0, 1) * config.motionBlur * 9 or 0
        if master and config.underwater then bs = math.max(bs, State.under * config.underwaterStrength * 3.5) end
        blurFx.Size = bs
        blurFx.Enabled = bs > 0.15
    end

    Mod.cam = { update = update }
end

--========================================================
-- HEADLAMP (local light on the head, manual / auto)
--========================================================
do
    local LAMP_COLORS = {
        Warm = C(255, 226, 180), Cool = C(205, 225, 255), Amber = C(255, 180, 90),
        Red = C(255, 80, 80), Green = C(110, 255, 150), Blue = C(100, 150, 255),
    }
    local lampPart, spot, fill
    local level = 0
    local autoOn = false

    local function ensure()
        if lampPart and lampPart.Parent then return end
        lampPart = newPart(worldFolder)
        lampPart.Name = "Headlamp"
        lampPart.Transparency = 1
        lampPart.Size = Vector3.new(0.2, 0.2, 0.2)
        spot = Instance.new("SpotLight")
        spot.Face = Enum.NormalId.Front
        spot.Enabled = false
        spot.Parent = lampPart
        fill = Instance.new("PointLight")
        fill.Enabled = false
        fill.Parent = lampPart
    end

    local function sceneLight()
        local clock = Lighting.ClockTime
        local day = (clock >= 6 and clock <= 18) and math.sin((clock - 6) / 12 * math.pi) or 0
        local a, o = Lighting.Ambient, Lighting.OutdoorAmbient
        local lum = ((a.R * 0.3 + a.G * 0.59 + a.B * 0.11) + (o.R * 0.3 + o.G * 0.59 + o.B * 0.11)) * 0.5
        local br = clamp(Lighting.Brightness / 2.5, 0.2, 1.3)
        return clamp(day * br * (0.2 + 0.8 * State.openness) + lum * 0.35, 0, 1.5)
    end

    local function update(dt)
        local mode = config.lampMode
        local target = false
        if config.master and mode ~= "Off" then
            if mode == "On" then
                target = true
            else
                local l = sceneLight()
                if l < config.lampThreshold then
                    autoOn = true
                elseif l > config.lampThreshold * 1.35 then
                    autoOn = false
                end
                target = autoOn
            end
        end
        level = damp(level, target and 1 or 0, 6, dt)
        if level < 0.01 then
            if spot then spot.Enabled = false fill.Enabled = false end
            return
        end
        ensure()
        local char = player.Character
        local head = char and char:FindFirstChild("Head")
        if not head or not camera then
            spot.Enabled = false
            fill.Enabled = false
            return
        end
        local dir
        if config.lampAim == "Camera" and not State.freecam then
            dir = camera.CFrame.LookVector
        else
            dir = head.CFrame.LookVector
        end
        local from = head.Position + head.CFrame.UpVector * 0.25
        lampPart.CFrame = CFrame.lookAt(from + dir * 0.6, from + dir * 10)
        local col = LAMP_COLORS[config.lampColor] or LAMP_COLORS.Warm
        spot.Enabled = true
        spot.Color = col
        spot.Brightness = config.lampBright * level
        spot.Range = clamp(config.lampRange, 5, 60)
        spot.Angle = clamp(config.lampAngle, 10, 150)
        spot.Shadows = config.lampShadows
        fill.Enabled = config.lampFill
        fill.Color = col
        fill.Range = 14
        fill.Brightness = 0.5 * level * (config.lampBright / 4)
    end

    Mod.lamp = { update = update, colors = LAMP_COLORS }
end

--========================================================
-- FREECAM + camera breathing (runs right after the game's camera script)
--========================================================
do
    local active = false
    local pos, yaw, pitch, vel = Vector3.new(), 0, 0, Vector3.new()
    local savedType, savedFov, hum, savedWalk, savedJumpP, savedJumpH
    local charParts, charT = {}, 0
    local lastBase, lastSet = nil, nil
    local phase = 0
    local mouseLocked = false

    local FC_IDS = { "fc_f", "fc_b", "fc_l", "fc_r", "fc_up", "fc_down", "fc_fast", "fc_slow" }
    local function sink() return Enum.ContextActionResult.Sink end

    local function bindSink()
        local keys = {}
        for _, id in ipairs(FC_IDS) do
            local kc = keyCodeOf(config["key_" .. id] or "None")
            if kc then keys[#keys + 1] = kc end
        end
        if #keys > 0 then
            ContextActionService:BindActionAtPriority("RTXV8_FreecamSink", sink, false,
                Enum.ContextActionPriority.High.Value, table.unpack(keys))
        end
    end

    local function disable()
        if not active then return end
        active = false
        State.freecam = false
        pcall(function() ContextActionService:UnbindAction("RTXV8_FreecamSink") end)
        if mouseLocked then
            UserInputService.MouseBehavior = Enum.MouseBehavior.Default
            mouseLocked = false
        end
        local cam = Workspace.CurrentCamera
        if cam then
            local t = savedType
            if t == nil or t == Enum.CameraType.Scriptable then t = Enum.CameraType.Custom end
            cam.CameraType = t
            if savedFov then cam.FieldOfView = savedFov end
        end
        if hum and hum.Parent then
            if savedWalk then hum.WalkSpeed = savedWalk end
            if savedJumpP then hum.JumpPower = savedJumpP end
            if savedJumpH then hum.JumpHeight = savedJumpH end
        end
        hum = nil
        State.toast("Freecam off")
    end

    local function enable()
        if active then return end
        local cam = Workspace.CurrentCamera
        if not cam then return end
        camera = cam
        savedType, savedFov = cam.CameraType, cam.FieldOfView
        local cf = cam.CFrame
        pos = cf.Position
        local look = cf.LookVector
        yaw = math.atan2(-look.X, -look.Z)
        pitch = math.asin(clamp(look.Y, -1, 1))
        vel = Vector3.new()
        cam.CameraType = Enum.CameraType.Scriptable
        local char = player.Character
        hum = char and char:FindFirstChildOfClass("Humanoid")
        if hum then
            savedWalk, savedJumpP, savedJumpH = hum.WalkSpeed, hum.JumpPower, hum.JumpHeight
            hum.WalkSpeed = 0
            hum.JumpPower = 0
            hum.JumpHeight = 0
        end
        bindSink()
        active = true
        State.freecam = true
        State.toast("Freecam on")
    end

    local function toggle()
        if active then disable() else enable() end
    end

    local function onWheel(delta)
        if not active then return end
        config.fcSpeed = clamp(config.fcSpeed * (1 + delta * 0.12), 2, 400)
        State.refreshUI()
    end

    local function keepCharacterVisible(dt)
        charT = charT - dt
        local char = player.Character
        if charT <= 0 and char then
            charT = 0.5
            table.clear(charParts)
            for _, d in ipairs(char:GetDescendants()) do
                if d:IsA("BasePart") then charParts[#charParts + 1] = d end
            end
        end
        for _, p in ipairs(charParts) do
            if p.Parent then p.LocalTransparencyModifier = 0 end
        end
    end

    local function runFreecam(dt)
        local cam = Workspace.CurrentCamera
        if not cam then return end
        keepCharacterVisible(dt)

        if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) then
            UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
            mouseLocked = true
            local d = UserInputService:GetMouseDelta()
            yaw = yaw - d.X * 0.0032
            pitch = clamp(pitch - d.Y * 0.0032, -1.5, 1.5)
        elseif mouseLocked then
            UserInputService.MouseBehavior = Enum.MouseBehavior.Default
            mouseLocked = false
        end

        local rot = CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0)
        local dir = Vector3.new()
        if not UserInputService:GetFocusedTextBox() then
            if keyDown("fc_f") then dir = dir + rot.LookVector end
            if keyDown("fc_b") then dir = dir - rot.LookVector end
            if keyDown("fc_r") then dir = dir + rot.RightVector end
            if keyDown("fc_l") then dir = dir - rot.RightVector end
            if keyDown("fc_up") then dir = dir + Vector3.new(0, 1, 0) end
            if keyDown("fc_down") then dir = dir - Vector3.new(0, 1, 0) end
        end
        local speed = config.fcSpeed
        if keyDown("fc_fast") then speed = speed * 3 end
        if keyDown("fc_slow") then speed = speed * 0.25 end
        local targetVel = dir.Magnitude > 0 and dir.Unit * speed or Vector3.new()
        local tc = 0.02 + config.fcSmooth * 0.35
        vel = vel + (targetVel - vel) * (1 - math.exp(-dt / tc))
        pos = pos + vel * dt

        cam.CameraType = Enum.CameraType.Scriptable
        cam.CFrame = CFrame.new(pos) * rot
        cam.FieldOfView = config.fcFov
    end

    local function runBreath(dt)
        local cam = Workspace.CurrentCamera
        if not cam then return end
        local char = player.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        local h = char and char:FindFirstChildOfClass("Humanoid")
        if not (config.master and config.camBreath and root and h) then
            lastBase, lastSet = nil, nil
            return
        end
        local v = root.AssemblyLinearVelocity
        local speed = Vector3.new(v.X, 0, v.Z).Magnitude
        local k = config.camBreathAmt
        phase = phase + dt * (1.6 + speed * 0.18)
        local moving = clamp(speed / 14, 0, 1)
        local bobY = (math.sin(phase * 2) * 0.025 * moving + math.sin(phase * 0.7) * 0.006) * k
        local roll = math.sin(phase) * 0.004 * moving * k
        local offset = CFrame.new(0, bobY, 0) * CFrame.Angles(0, 0, roll)
        local base = cam.CFrame
        if lastSet and cam.CFrame == lastSet and lastBase then base = lastBase end
        lastBase = base
        lastSet = base * offset
        cam.CFrame = lastSet
    end

    local function post(dt)
        if active then
            runFreecam(dt)
        else
            runBreath(dt)
        end
    end

    Mod.freecam = {
        post = post, toggle = toggle, disable = disable, onWheel = onWheel,
        isActive = function() return active end,
    }
end

--========================================================
-- UI + input + main loop (own function: Luau allows 200 locals per function)
--========================================================
local okUI, errUI = pcall(function()

local T = {
    bg = C(14, 15, 18), chip = C(28, 30, 37), off = C(46, 49, 58), stroke = C(38, 40, 48),
    text = C(232, 234, 240), muted = C(124, 129, 145), accent = C(125, 148, 255),
    danger = C(255, 118, 118), dark = C(10, 10, 14),
}
local FONT_R = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Regular)
local FONT_M = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Medium)
local FONT_B = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold)

--------------------------------------------------------
-- Overlay: vignette, letterbox, HUD labels
--------------------------------------------------------
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

local function hudLabel(anchor, pos)
    local l = new("TextLabel", {
        AnchorPoint = anchor, Position = pos, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 26),
        BackgroundColor3 = T.bg, BackgroundTransparency = 0.25, TextColor3 = T.text, TextSize = 12,
        FontFace = FONT_M, Text = "", Visible = false, BorderSizePixel = 0,
    }, overlay)
    new("UICorner", { CornerRadius = UDim.new(1, 0) }, l)
    new("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14) }, l)
    return l
end
local freecamHud = hudLabel(Vector2.new(0, 1), UDim2.new(0, 16, 1, -16))
local focusHud = hudLabel(Vector2.new(1, 1), UDim2.new(1, -16, 1, -16))
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

--------------------------------------------------------
-- Menu window
--------------------------------------------------------
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
    Size = UDim2.fromOffset(740, 540), BackgroundColor3 = T.bg, BorderSizePixel = 0, GroupTransparency = 1,
}, gui)
new("UICorner", { CornerRadius = UDim.new(0, 16) }, root)
new("UIStroke", { Color = T.stroke, Thickness = 1 }, root)
local uiScale = new("UIScale", { Scale = 0.96 }, root)

local sidebar = new("Frame", { Size = UDim2.new(0, 176, 1, 0), BackgroundTransparency = 1 }, root)
new("Frame", { Size = UDim2.new(0, 1, 1, 0), Position = UDim2.new(1, -1, 0, 0), BackgroundColor3 = T.stroke, BorderSizePixel = 0 }, sidebar)
local brand = new("Frame", { Size = UDim2.new(1, 0, 0, 70), BackgroundTransparency = 1, Active = true }, sidebar)
label(brand, "RTX", 20, T.text, FONT_B, UDim2.new(1, -20, 0, 26), UDim2.fromOffset(22, 20))
label(brand, "PREMIUM  ·  v" .. VERSION, 10, T.muted, FONT_M, UDim2.new(1, -20, 0, 14), UDim2.fromOffset(22, 44))

local tabList = new("Frame", { Size = UDim2.new(1, 0, 1, -140), Position = UDim2.fromOffset(0, 76), BackgroundTransparency = 1 }, sidebar)
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

local controls = {}
local dynamics = {}
local function refreshControls()
    for _, fn in ipairs(controls) do fn() end
end
State.refreshUI = refreshControls

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
State.toast = toast

--------------------------------------------------------
-- Keys (names, display, rebinding)
--------------------------------------------------------
local KEYS = {
    { "menu", "Open / close menu", true }, { "master", "All effects on / off", true },
    { "freecam", "Freecam", true }, { "lamp", "Headlamp", true }, { "photo", "Photo mode", true },
    { "dof", "Depth of field", true }, { "weather", "Next weather", true },
    { "timeDown", "Time earlier", true }, { "timeUp", "Time later", true },
    { "pick", "Pick object to recolour", true },
    { "fc_f", "Freecam: forward", false }, { "fc_b", "Freecam: back", false },
    { "fc_l", "Freecam: left", false }, { "fc_r", "Freecam: right", false },
    { "fc_up", "Freecam: up", false }, { "fc_down", "Freecam: down", false },
    { "fc_fast", "Freecam: faster", false }, { "fc_slow", "Freecam: slower", false },
}
local PRESS_IDS = {}
for _, k in ipairs(KEYS) do
    if k[3] then PRESS_IDS[#PRESS_IDS + 1] = k[1] end
end

local KEY_SHORT = {
    LeftBracket = "[", RightBracket = "]", LeftShift = "LShift", RightShift = "RShift",
    LeftControl = "LCtrl", RightControl = "RCtrl", LeftAlt = "LAlt", RightAlt = "RAlt",
    Return = "Enter", Backspace = "Bksp", None = "—",
}
local function keyText(id)
    local n = config["key_" .. id] or "None"
    return KEY_SHORT[n] or n
end

local function startRebind(id)
    State.rebindId = id
    refreshControls()
end

local function keyBadge(parent, id, rightOffset)
    local b = new("TextButton", {
        AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, rightOffset, 0.5, 0),
        AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 22), BackgroundColor3 = T.chip,
        Text = "", TextSize = 11, TextColor3 = T.muted, FontFace = FONT_M, AutoButtonColor = false, BorderSizePixel = 0,
    }, parent)
    new("UICorner", { CornerRadius = UDim.new(0, 6) }, b)
    new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, b)
    b.Activated:Connect(function() startRebind(id) end)
    local function refresh()
        if State.rebindId == id then
            b.Text = "press a key…"
            b.TextColor3 = T.accent
        else
            b.Text = keyText(id)
            b.TextColor3 = T.muted
        end
    end
    controls[#controls + 1] = refresh
    refresh()
    return b
end

--------------------------------------------------------
-- Pages and builders
--------------------------------------------------------
local pages, tabButtons, orders = {}, {}, {}
local TABS = {
    { "Look", "Color, glow and frame" },
    { "Sky", "Time of day, atmosphere and sky colour" },
    { "Weather", "Rain, storm, snow, fog and sounds" },
    { "Camera", "Smart depth of field and lens" },
    { "Reflect", "Gloss, mirrors and water" },
    { "World", "Recolour the map, glow" },
    { "Tools", "Freecam, headlamp, photo mode" },
    { "Keys", "Click a key to rebind it" },
    { "System", "Quality and settings" },
}

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

local function info(page, fn)
    local r = row(page, 24)
    local l = label(r, "", 12, T.accent, FONT_M)
    dynamics[#dynamics + 1] = function() l.Text = fn() end
    l.Text = fn()
end

local function toggle(page, text, key, hint, onChange, keyId)
    local r = row(page, hint and 48 or 38)
    label(r, text, 13, T.text, FONT_M, UDim2.new(1, -110, 0, 20), UDim2.fromOffset(0, hint and 5 or 9))
    if hint then label(r, hint, 11, T.muted, FONT_R, UDim2.new(1, -110, 0, 14), UDim2.fromOffset(0, 26)) end
    local sw = new("Frame", {
        Size = UDim2.fromOffset(38, 20), Position = UDim2.new(1, -38, 0.5, -10), BackgroundColor3 = T.off, BorderSizePixel = 0,
    }, r)
    new("UICorner", { CornerRadius = UDim.new(1, 0) }, sw)
    local knob = new("Frame", {
        Size = UDim2.fromOffset(16, 16), Position = UDim2.new(0, 2, 0.5, -8), BackgroundColor3 = T.text, BorderSizePixel = 0,
    }, sw)
    new("UICorner", { CornerRadius = UDim.new(1, 0) }, knob)
    local hit = new("TextButton", { Size = UDim2.new(1, -120, 1, 0), BackgroundTransparency = 1, Text = "" }, r)
    local hit2 = new("TextButton", { Size = UDim2.fromOffset(60, 38), Position = UDim2.new(1, -60, 0.5, -19), BackgroundTransparency = 1, Text = "" }, r)
    local function refresh()
        local on = config[key]
        tween(sw, { BackgroundColor3 = on and T.accent or T.off }, 0.15)
        tween(knob, { Position = on and UDim2.new(1, -18, 0.5, -8) or UDim2.new(0, 2, 0.5, -8) }, 0.15)
    end
    local function flip()
        config[key] = not config[key]
        refresh()
        if onChange then onChange(config[key]) end
    end
    hit.Activated:Connect(flip)
    hit2.Activated:Connect(flip)
    if keyId then keyBadge(r, keyId, -50) end
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
        local b = new("TextButton", {
            AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 28), BackgroundColor3 = T.chip,
            Text = o.label, TextSize = 12, TextColor3 = T.text, FontFace = FONT_M, AutoButtonColor = false,
            BorderSizePixel = 0, RichText = true, LayoutOrder = i,
        }, holder)
        if o.color then
            b.Text = string.format('<font color="#%s">●</font>  %s', o.color:ToHex(), o.label)
        end
        new("UICorner", { CornerRadius = UDim.new(1, 0) }, b)
        new("UIPadding", { PaddingLeft = UDim.new(0, 13), PaddingRight = UDim.new(0, 13) }, b)
        buttons[o.id] = b
        b.Activated:Connect(function()
            config[key] = o.id
            if onChange then onChange(o.id) end
            refreshControls()
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

local function button(page, text, kind, cb, keyId)
    local r = row(page, 40)
    local b = new("TextButton", {
        Size = UDim2.new(1, 0, 0, 34), Position = UDim2.fromOffset(0, 3),
        BackgroundColor3 = kind == "accent" and T.accent or T.chip, Text = text, TextSize = 12,
        TextColor3 = kind == "accent" and T.dark or (kind == "danger" and T.danger or T.text),
        FontFace = FONT_M, AutoButtonColor = true, BorderSizePixel = 0,
    }, r)
    new("UICorner", { CornerRadius = UDim.new(0, 9) }, b)
    b.Activated:Connect(cb)
    if keyId then keyBadge(b, keyId, -10) end
    return b
end

local function textbox(page, text, key, placeholder)
    local r = row(page, 58)
    label(r, text, 13, T.text, FONT_M, UDim2.new(1, 0, 0, 20), UDim2.fromOffset(0, 2))
    local tb = new("TextBox", {
        Size = UDim2.new(1, 0, 0, 28), Position = UDim2.fromOffset(0, 26), BackgroundColor3 = T.chip,
        Text = tostring(config[key]), PlaceholderText = placeholder, PlaceholderColor3 = T.muted,
        TextColor3 = T.text, TextSize = 12, FontFace = FONT_M, ClearTextOnFocus = false,
        TextXAlignment = Enum.TextXAlignment.Left, BorderSizePixel = 0,
    }, r)
    new("UICorner", { CornerRadius = UDim.new(0, 8) }, tb)
    new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }, tb)
    tb.FocusLost:Connect(function() config[key] = tb.Text end)
    controls[#controls + 1] = function()
        if not tb:IsFocused() then tb.Text = tostring(config[key]) end
    end
end

local QUICK_COLORS = {
    C(255, 80, 80), C(255, 150, 60), C(255, 215, 80), C(120, 230, 120), C(70, 220, 200),
    C(80, 160, 255), C(130, 110, 255), C(210, 110, 255), C(255, 110, 190), C(235, 235, 240),
}

local function colorPicker(page, title, kh, ks, kv)
    local r = row(page, 44)
    label(r, title, 13, T.text, FONT_M, UDim2.new(1, -170, 0, 22), UDim2.fromOffset(0, 11))
    local swatch = new("Frame", {
        Size = UDim2.fromOffset(28, 28), Position = UDim2.new(1, -140, 0.5, -14), BackgroundColor3 = T.accent, BorderSizePixel = 0,
    }, r)
    new("UICorner", { CornerRadius = UDim.new(1, 0) }, swatch)
    local tb = new("TextBox", {
        Size = UDim2.fromOffset(104, 28), Position = UDim2.new(1, -104, 0.5, -14), BackgroundColor3 = T.chip,
        Text = "", TextColor3 = T.text, TextSize = 12, FontFace = FONT_M, ClearTextOnFocus = false, BorderSizePixel = 0,
    }, r)
    new("UICorner", { CornerRadius = UDim.new(0, 8) }, tb)
    tb.FocusLost:Connect(function()
        local hex = string.match(tb.Text, "^#?(%x%x%x%x%x%x)$")
        if hex then
            local h, s, v = Color3.fromHex(hex):ToHSV()
            config[kh], config[ks], config[kv] = h, s, v
        end
        refreshControls()
    end)
    controls[#controls + 1] = function()
        local c = Color3.fromHSV(config[kh], config[ks], config[kv])
        swatch.BackgroundColor3 = c
        if not tb:IsFocused() then tb.Text = "#" .. string.upper(c:ToHex()) end
    end
    slider(page, "Hue", kh, 0, 1, 2)
    slider(page, "Saturation", ks, 0, 1, 2)
    slider(page, "Brightness", kv, 0, 1, 2)
    local qr = row(page, 34)
    new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), VerticalAlignment = Enum.VerticalAlignment.Center }, qr)
    for _, col in ipairs(QUICK_COLORS) do
        local b = new("TextButton", { Size = UDim2.fromOffset(24, 24), BackgroundColor3 = col, Text = "", BorderSizePixel = 0 }, qr)
        new("UICorner", { CornerRadius = UDim.new(1, 0) }, b)
        b.Activated:Connect(function()
            local h, s, v = col:ToHSV()
            config[kh], config[ks], config[kv] = h, s, v
            refreshControls()
        end)
    end
    refreshControls()
end

local function opts(list)
    local out = {}
    for _, v in ipairs(list) do out[#out + 1] = { id = v, label = v } end
    return out
end

--------------------------------------------------------
-- Forward declarations used by tabs
--------------------------------------------------------
local unload, setMenu, togglePhoto, updateHint
local menuVisible = true
local baseScale = 1

--------------------------------------------------------
-- Save / load (executor file API only), per-map presets
--------------------------------------------------------
local canFile = typeof(writefile) == "function" and typeof(readfile) == "function" and typeof(isfile) == "function"
local placeKey = tostring(game.PlaceId)

local function copyConfig()
    local c = {}
    for k, v in pairs(config) do c[k] = v end
    return c
end
local function readStore()
    if not canFile then return nil end
    local ok, data = pcall(function()
        if isfile(SAVE_FILE) then return HttpService:JSONDecode(readfile(SAVE_FILE)) end
    end)
    if ok and type(data) == "table" then return data end
    return nil
end
local function writeStore(store)
    local ok = pcall(function() writefile(SAVE_FILE, HttpService:JSONEncode(store)) end)
    return ok
end
local function applyTable(tbl)
    for k, v in pairs(tbl) do
        if DEFAULTS[k] ~= nil and type(v) == type(DEFAULTS[k]) then config[k] = v end
    end
    refreshControls()
end
local function saveDefault()
    local store = readStore() or {}
    store.default = copyConfig()
    toast(writeStore(store) and "Saved as default" or "Could not save")
end
local function saveForMap()
    local store = readStore() or {}
    store.places = store.places or {}
    store.places[placeKey] = copyConfig()
    toast(writeStore(store) and "Saved for this map" or "Could not save")
end
local function loadSaved(silent)
    local store = readStore()
    if not store then
        if not silent then toast("No saved settings") end
        return
    end
    if type(store.default) == "table" then applyTable(store.default) end
    if config.autoPreset and type(store.places) == "table" and type(store.places[placeKey]) == "table" then
        applyTable(store.places[placeKey])
        if not silent then toast("Map preset loaded") end
    elseif not silent then
        toast("Settings loaded")
    end
end

--------------------------------------------------------
-- Tabs
--------------------------------------------------------
-- LOOK
do
    local p = pages.Look
    toggle(p, "Enable effects", "master", "Master switch for everything in this menu", function(on)
        toast(on and "Effects on" or "Effects off")
    end, "master")
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
    section(p, "Custom sky colour")
    toggle(p, "Recolour the sky", "skyColorOn", "Any colour through the atmosphere")
    colorPicker(p, "Sky colour", "skyH", "skyS", "skyV")
    slider(p, "Colour strength", "skyMix", 0, 1, 2)
    note(p, "The skybox texture itself cannot be recoloured in Roblox, the colour is built through the atmosphere. If it is too faint, raise strength or Haze. Time \"Game\" never touches the clock; use it in games with their own day/night cycle.")
end

-- WEATHER
do
    local p = pages.Weather
    chips(p, "Weather", "weather", opts(WEATHER_ORDER), function(id) toast("Weather: " .. id) end)
    toggle(p, "Dynamic weather", "autoWeather", "Changes by itself and blends smoothly", nil, nil)
    slider(p, "Change every (minutes)", "autoWeatherMinutes", 1, 30, 0)
    section(p, "Strength")
    slider(p, "Intensity", "weatherIntensity", 0.1, 1, 2)
    slider(p, "Wind", "wind", 0, 1, 2)
    section(p, "Details")
    toggle(p, "Lightning", "lightning", "Bolts and sky flashes during Storm")
    toggle(p, "Ripples", "ripples", "Rings where rain hits surfaces near you")
    toggle(p, "Puddles", "puddles", "Glossy puddles grow on flat ground in rain")
    slider(p, "Wet surface look", "wetLook", 0, 1, 2)
    toggle(p, "Mist", "mist", "Over water and at dawn")
    slider(p, "Mist amount", "mistAmount", 0, 1, 2)
    toggle(p, "Underwater filter", "underwater", "Colour, haze and softness below water")
    slider(p, "Underwater strength", "underwaterStrength", 0, 1, 2)
    section(p, "Sounds (your own ids)")
    textbox(p, "Rain loop sound id", "soundRain", "e.g. 123456789")
    textbox(p, "Thunder sound id", "soundThunder", "e.g. 123456789")
    slider(p, "Sound volume", "soundVolume", 0, 1, 2)
    note(p, "Rain and snow are real objects around the camera. They stop on roofs, splash on surfaces and are not drawn indoors. Terrain colours get wet and snowy too. Sounds only play after you paste an audio id from the Creator Store.")
end

-- CAMERA
do
    local p = pages.Camera
    toggle(p, "Depth of field", "dof", "Background blur that follows what you look at", nil, "dof")
    chips(p, "Focus mode", "dofMode", opts({ "Smart", "Cursor", "Subject", "Manual" }))
    slider(p, "Far blur", "dofFar", 0, 1, 2)
    slider(p, "Near blur", "dofNear", 0, 1, 2)
    slider(p, "Aperture", "aperture", 0.3, 2.5, 2)
    slider(p, "Focus speed", "dofSmooth", 2, 16, 1)
    slider(p, "Max focus distance", "dofLimit", 50, 1000, 0)
    slider(p, "Manual focus distance", "dofManual", 3, 500, 0)
    toggle(p, "Show focus distance", "dofIndicator")
    section(p, "Lens")
    slider(p, "Motion blur", "motionBlur", 0, 1, 2)
    slider(p, "Auto exposure", "autoExposure", 0, 1, 2)
    toggle(p, "Camera breathing", "camBreath", "Soft bob while walking and running")
    slider(p, "Breathing amount", "camBreathAmt", 0, 1, 2)
    note(p, "Smart focus measures several rays around the screen centre and favours the nearest object, but a new distance has to persist for a moment before the focus moves, so passing fences, leaves or transparent parts do not pull it. In third person your character stays sharp when you look at distant scenery.")
end

-- REFLECT
do
    local p = pages.Reflect
    toggle(p, "Surface gloss", "gloss", "Every part and mesh, material aware")
    slider(p, "Gloss strength", "glossStrength", 0, 1, 2)
    slider(p, "Environment reflections", "specBoost", 0, 1.5, 2)
    slider(p, "Character sheen", "charSheen", 0, 0.4, 2)
    section(p, "Mirror reflections")
    toggle(p, "Characters", "mirror", "Full-model mirrored copies on water, glass and translucent floors")
    toggle(p, "Props and objects", "mirrorProps", "Nearby parts are mirrored too")
    slider(p, "Mirror strength", "mirrorStrength", 0, 1, 2)
    section(p, "Water")
    toggle(p, "Enhance water", "waterOn")
    slider(p, "Reflectance", "waterReflect", 0, 1, 2)
    slider(p, "Transparency", "waterTransp", 0, 1, 2)
    slider(p, "Wave size", "waterWave", 0, 1, 2)
    slider(p, "Wave speed", "waterSpeed", 0, 30, 0)
    chips(p, "Water tint", "waterTint", opts({ "Original", "Aqua", "Deep", "Emerald", "Lagoon", "Murky" }))
    note(p, "Roblox has no screen-space reflections. Gloss makes every surface reflect the sky and sun. Objects with their own PBR textures keep their own material maps. Mirrored characters and props are only visible through see-through surfaces. Terrain itself cannot reflect, except water.")
end

-- WORLD
do
    local p = pages.World
    section(p, "Palette for the whole map")
    chips(p, nil, "mapPalette", opts({ "None", "Noir", "Autumn", "Cyber", "Pastel", "Toxic", "Dusk" }), function(id)
        local v = PALETTES[id]
        config.mapHue, config.mapSat, config.mapVal = v[1], v[2], v[3]
    end)
    local function custom() config.mapPalette = "Custom" refreshControls() end
    slider(p, "Hue shift", "mapHue", -0.5, 0.5, 2, custom)
    slider(p, "Saturation", "mapSat", -1, 1, 2, custom)
    slider(p, "Brightness", "mapVal", -0.5, 0.5, 2, custom)
    toggle(p, "Include Terrain", "mapTerrain", "Grass, sand, rock and other terrain materials")

    section(p, "Recolour colour")
    colorPicker(p, "Colour", "pickH", "pickS", "pickV")

    section(p, "By material")
    chips(p, "Material", "matPick", opts({ "Concrete", "Brick", "Wood", "WoodPlanks", "Metal", "Plastic", "SmoothPlastic",
        "Marble", "Granite", "Slate", "Cobblestone", "Asphalt", "Pavement", "Sand", "Grass", "Rock", "Ground", "Snow",
        "Ice", "Sandstone", "Basalt", "Limestone", "Mud", "LeafyGrass" }))
    button(p, "Apply colour to this material", "accent", function() Mod.map.setRule(config.matPick) end)
    button(p, "Remove rule for this material", "normal", function() Mod.map.removeRule(config.matPick) end)
    button(p, "Clear all material rules", "normal", function() Mod.map.clearRules() end)

    section(p, "Pick an object")
    button(p, "Pick object, then click it in the world", "accent", function()
        if Mod.map.isPicking() then Mod.map.cancelPick() else Mod.map.startPick() end
    end, "pick")
    info(p, function() return Mod.map.selectionText() end)
    chips(p, "Material for the object", "selMat", opts({ "Keep", "Plastic", "SmoothPlastic", "Metal", "Neon", "Glass", "Wood", "Concrete", "Marble", "Ice" }))
    toggle(p, "Also set transparency and reflectance", "selUseExtra")
    slider(p, "Transparency", "selTransp", 0, 1, 2)
    slider(p, "Reflectance", "selRefl", 0, 1, 2)
    button(p, "Recolour selected part", "normal", function() Mod.map.applyToSelection("part") end)
    button(p, "Recolour whole model", "normal", function() Mod.map.applyToSelection("model") end)
    button(p, "Revert selected part", "normal", function() Mod.map.revertSelection("part") end)
    button(p, "Revert selected model", "normal", function() Mod.map.revertSelection("model") end)
    button(p, "Clear all part recolours", "normal", function() Mod.map.revertAllOverrides() end)

    section(p, "Light glow")
    toggle(p, "Neon glow", "neonGlow", "Soft light around neon parts")
    slider(p, "Glow strength", "neonStrength", 0, 1.5, 2)
    toggle(p, "Window glow at night", "windowGlow", "Warm light behind glass windows")
    note(p, "Recolouring is local: only you see it. Parts that use SurfaceAppearance textures are tinted instead of repainted. Terrain colours change per material, so picking a terrain spot recolours that whole material.")
end

-- TOOLS
local lastLamp = "On"
do
    local p = pages.Tools
    section(p, "Freecam")
    button(p, "Toggle freecam", "accent", function() Mod.freecam.toggle() end, "freecam")
    slider(p, "Fly speed (mouse wheel too)", "fcSpeed", 2, 400, 0)
    slider(p, "Smoothness", "fcSmooth", 0, 1, 2)
    slider(p, "Field of view", "fcFov", 20, 110, 0)
    info(p, function()
        return string.format("Move %s%s%s%s   Up %s   Down %s   Fast %s   Slow %s   Look: hold right mouse",
            keyText("fc_f"), keyText("fc_l"), keyText("fc_b"), keyText("fc_r"),
            keyText("fc_up"), keyText("fc_down"), keyText("fc_fast"), keyText("fc_slow"))
    end)
    note(p, "Your character stays where it is and stays visible. Movement keys are blocked for the character while freecam is on. Freecam needs a keyboard and mouse.")

    section(p, "Headlamp")
    chips(p, "Mode", "lampMode", opts({ "Off", "On", "Auto" }))
    button(p, "Toggle headlamp", "normal", function()
        if config.lampMode ~= "Off" then
            lastLamp = config.lampMode
            config.lampMode = "Off"
        else
            config.lampMode = lastLamp
        end
        refreshControls()
    end, "lamp")
    chips(p, "Aim", "lampAim", opts({ "Camera", "Head" }))
    local lampColors = {}
    for _, name in ipairs({ "Warm", "Cool", "Amber", "Red", "Green", "Blue" }) do
        lampColors[#lampColors + 1] = { id = name, label = name, color = Mod.lamp.colors[name] }
    end
    chips(p, "Colour", "lampColor", lampColors)
    slider(p, "Brightness", "lampBright", 0.5, 10, 1)
    slider(p, "Range", "lampRange", 10, 60, 0)
    slider(p, "Beam angle", "lampAngle", 15, 140, 0)
    slider(p, "Auto turn-on darkness", "lampThreshold", 0.05, 0.8, 2)
    toggle(p, "Shadows", "lampShadows", "Prettier, but costs more")
    toggle(p, "Soft fill light", "lampFill", "A small glow around your head")
    note(p, "Auto mode turns the lamp on when the scene is dark: night time, covered places, or maps with low ambient light. It estimates darkness from the clock, how open the sky is above you and the map's ambient light.")

    section(p, "Photo mode")
    button(p, "Toggle photo mode", "normal", function() togglePhoto() end, "photo")
    note(p, "Hides the menu and Roblox interface and freezes time and weather. Combine with Freecam for screenshots.")
end

-- KEYS
do
    local p = pages.Keys
    for _, k in ipairs(KEYS) do
        local r = row(p, 36)
        label(r, k[2], 13, T.text, FONT_M, UDim2.new(1, -120, 1, 0))
        keyBadge(r, k[1], 0)
    end
    note(p, "Click a key, then press the new key. Backspace unbinds it, Esc cancels. If a key is already used, it moves to the new action. Keys are ignored while you type in chat.")
    button(p, "Reset all keys", "normal", function()
        for _, k in ipairs(KEYS) do config["key_" .. k[1]] = DEFAULTS["key_" .. k[1]] end
        State.rebindId = nil
        refreshControls()
        toast("Keys reset")
    end)
end

-- SYSTEM
do
    local p = pages.System
    chips(p, "Quality", "quality", opts({ "Low", "Medium", "High", "Ultra" }))
    toggle(p, "Auto quality", "autoQuality", "Lowers weather, mirror and map load when FPS drops")
    section(p, "Presets")
    toggle(p, "Load map preset automatically", "autoPreset", canFile and "Uses the settings saved for this map" or "Needs an executor with file access to save")
    if canFile then
        button(p, "Save for this map", "normal", saveForMap)
        button(p, "Save as default for all maps", "normal", saveDefault)
        button(p, "Load saved settings", "normal", function() loadSaved(false) end)
    end
    button(p, "Reset everything to defaults", "normal", function()
        for k, v in pairs(DEFAULTS) do config[k] = v end
        refreshControls()
        toast("Defaults restored")
    end)
    section(p, "Unload")
    button(p, "ANLOAD  /  restore the original look", "danger", function() unload() end)
end

--------------------------------------------------------
-- Window behaviour
--------------------------------------------------------
setMenu = function(v)
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
    if t == Enum.UserInputType.MouseWheel then
        Mod.freecam.onWheel(input.Position.Z)
        return
    end
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

if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
    local fab = new("TextButton", {
        Size = UDim2.fromOffset(42, 42), Position = UDim2.new(0, 14, 0.5, -21), BackgroundColor3 = T.bg,
        Text = "RTX", TextSize = 11, TextColor3 = T.text, FontFace = FONT_B, BorderSizePixel = 0,
    }, gui)
    new("UICorner", { CornerRadius = UDim.new(1, 0) }, fab)
    new("UIStroke", { Color = T.stroke, Thickness = 1 }, fab)
    fab.Activated:Connect(function() setMenu(not menuVisible) end)
end

--------------------------------------------------------
-- Photo mode
--------------------------------------------------------
local photoOn, savedCore = false, nil
togglePhoto = function()
    photoOn = not photoOn
    State.frozen = photoOn
    gui.Enabled = not photoOn
    pcall(function()
        if photoOn then
            savedCore = StarterGui:GetCoreGuiEnabled(Enum.CoreGuiType.All)
            StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, false)
        else
            StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, savedCore ~= false)
        end
    end)
    if not photoOn then toast("Photo mode off") end
end

--------------------------------------------------------
-- Key actions
--------------------------------------------------------
local Actions = {}
Actions.menu = function() setMenu(not menuVisible) end
Actions.master = function()
    config.master = not config.master
    refreshControls()
    toast(config.master and "Effects on" or "Effects off")
end
Actions.freecam = function() Mod.freecam.toggle() end
Actions.lamp = function()
    if config.lampMode ~= "Off" then
        lastLamp = config.lampMode
        config.lampMode = "Off"
    else
        config.lampMode = lastLamp
    end
    refreshControls()
    toast("Headlamp: " .. config.lampMode)
end
Actions.photo = function() togglePhoto() end
Actions.dof = function()
    config.dof = not config.dof
    refreshControls()
    toast(config.dof and "Depth of field on" or "Depth of field off")
end
Actions.weather = function()
    local idx = 1
    for i, n in ipairs(WEATHER_ORDER) do
        if n == config.weather then idx = i end
    end
    config.weather = WEATHER_ORDER[idx % #WEATHER_ORDER + 1]
    refreshControls()
    toast("Weather: " .. config.weather)
end
local function shiftTime(delta)
    if config.timeMode == "Game" then
        config.timeMode = "Manual"
        config.clock = Mod.env.clock()
    end
    config.clock = (config.clock + delta) % 24
    refreshControls()
    toast(string.format("Time %02d:%02d", math.floor(config.clock), math.floor((config.clock % 1) * 60)))
end
Actions.timeDown = function() shiftTime(-0.5) end
Actions.timeUp = function() shiftTime(0.5) end
Actions.pick = function()
    if Mod.map.isPicking() then Mod.map.cancelPick() else Mod.map.startPick() end
end

connect(UserInputService.InputBegan, function(input, processed)
    if unloaded then return end

    -- rebinding
    if State.rebindId then
        if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode ~= Enum.KeyCode.Unknown then
            local id = State.rebindId
            if input.KeyCode == Enum.KeyCode.Escape then
                State.rebindId = nil
            elseif input.KeyCode == Enum.KeyCode.Backspace then
                config["key_" .. id] = "None"
                State.rebindId = nil
            else
                local name = input.KeyCode.Name
                for _, k in ipairs(KEYS) do
                    if k[1] ~= id and config["key_" .. k[1]] == name then
                        config["key_" .. k[1]] = "None"
                        toast("Key moved from: " .. k[2])
                    end
                end
                config["key_" .. id] = name
                State.rebindId = nil
            end
            refreshControls()
            updateHint()
        end
        return
    end

    -- object picking
    if Mod.map.isPicking() then
        if input.KeyCode == Enum.KeyCode.Escape then
            Mod.map.cancelPick()
            toast("Pick cancelled")
            return
        end
        if input.UserInputType == Enum.UserInputType.MouseButton1 and not processed then
            Mod.map.handleClick()
            return
        end
    end

    if processed or UserInputService:GetFocusedTextBox() then return end
    if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
    local name = input.KeyCode.Name
    for _, id in ipairs(PRESS_IDS) do
        if config["key_" .. id] == name then
            local fn = Actions[id]
            if fn then fn() end
            return
        end
    end
end)

updateHint = function()
    hintLabel.Text = "[" .. keyText("menu") .. "]  toggle menu"
end

--------------------------------------------------------
-- Unload
--------------------------------------------------------
unload = function()
    if unloaded then return end
    unloaded = true
    alive = false

    pcall(function() RunService:UnbindFromRenderStep("RTXV8_Cam") end)
    for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
    table.clear(connections)

    pcall(function() Mod.freecam.disable() end)
    pcall(function()
        if photoOn then
            StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, savedCore ~= false)
        end
    end)
    pcall(function() Mod.map.restoreAll() end)
    pcall(function() Mod.glow.destroy() end)

    for obj, props in pairs(originals) do
        for prop, value in pairs(props) do
            if not (obj == Lighting and prop == "ClockTime" and not Mod.env.clockTouched()) then
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

--------------------------------------------------------
-- Main loop
--------------------------------------------------------
local fpsAvg, qTimer, filterTimer, fpsTimer, dynTimer = 60, 0, 0, 0, 0
local failed = {}

local function safe(name, fn, a)
    local ok, err = pcall(fn, a)
    if not ok and not failed[name] then
        failed[name] = true
        warn("[RTX Premium] " .. name .. " error: " .. tostring(err))
    end
end

connect(player.CharacterAdded, function()
    task.defer(refreshFilters)
    if Mod.freecam.isActive() then Mod.freecam.disable() end
end)

RunService:BindToRenderStep("RTXV8_Cam", Enum.RenderPriority.Camera.Value + 1, function(dt)
    if unloaded then return end
    safe("camera-post", Mod.freecam.post, dt)
end)

connect(RunService.RenderStepped, function(dt)
    if unloaded then return end
    dt = math.min(dt, 0.1)
    local sdt = State.frozen and 0 or dt

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
        local s = clamp(math.min(gui.AbsoluteSize.X / 780, gui.AbsoluteSize.Y / 580, 1), 0.5, 1)
        if math.abs(s - baseScale) > 0.01 then
            baseScale = s
            if menuVisible then uiScale.Scale = s end
        end
    end

    dynTimer = dynTimer - dt
    if dynTimer <= 0 then
        dynTimer = 0.3
        for _, fn in ipairs(dynamics) do fn() end
        local fcOn = State.freecam and not photoOn
        freecamHud.Visible = fcOn
        if fcOn then
            freecamHud.Text = string.format("FREECAM    %s%s%s%s move   %s up   %s down   wheel = speed   hold right mouse = look    [%s] exit",
                keyText("fc_f"), keyText("fc_l"), keyText("fc_b"), keyText("fc_r"),
                keyText("fc_up"), keyText("fc_down"), keyText("freecam"))
        end
        local showFocus = config.master and config.dof and config.dofIndicator and not photoOn
        focusHud.Visible = showFocus
        if showFocus then focusHud.Text = string.format("Focus  %.1f studs", State.focusDist) end
    end

    safe("camera", Mod.cam.update, dt)
    safe("environment", Mod.env.update, sdt)
    safe("weather", function() Mod.weather.update(sdt, dt) end)
    safe("map", Mod.map.update, dt)
    safe("mirror", Mod.mirror.update, dt)
    safe("water", Mod.water.update, dt)
    safe("glow", Mod.glow.update, dt)
    safe("lamp", Mod.lamp.update, dt)
    safe("overlay", updateOverlay, dt)
end)

--------------------------------------------------------
-- Start
--------------------------------------------------------
refreshFilters()
updateHint()
selectTab("Look")
loadSaved(true)
refreshControls()
do
    local s = clamp(math.min(gui.AbsoluteSize.X / 780, gui.AbsoluteSize.Y / 580, 1), 0.5, 1)
    baseScale = s
    uiScale.Scale = s * 0.96
end
setMenu(true)
toast("RTX Premium v" .. VERSION .. "  ·  press " .. keyText("menu") .. " for the menu")
print("[RTX Premium v" .. VERSION .. "] Ready. Press " .. keyText("menu") .. " to toggle the menu.")

end)
if not okUI then
    warn("[RTX Premium] failed to start: " .. tostring(errUI))
end
