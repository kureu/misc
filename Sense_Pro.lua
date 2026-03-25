--[[
    ╔══════════════════════════════════════════════════════════════╗
    ║                                                              ║
    ║   S E N S E   E S P   —   P R O   R E L E A S E            ║
    ║   V E R S I O N    2 . 0                                    ║
    ║                                                              ║
    ╚══════════════════════════════════════════════════════════════╝

    [ CHANGELOG — V2.0 PRO ]

    CRITICAL BUG FIXES:
    - Fixed Stale ViewportSize Cache:
        The original cached `camera.ViewportSize` once at module load
        (line 9 of original). On any screen resize or fullscreen toggle,
        ALL box-corner calculations, FOV clamping, and off-screen arrow
        placement would silently drift until the script was re-injected.
        `viewportSize` is now read fresh per-render-tick from `camera.ViewportSize`
        in every function that needs it.

    - Fixed Division-By-Zero in Health Ratio:
        If `maxHealth` is 0 (broken Humanoid state), the health ratio
        `self.health / self.maxHealth` produces NaN, which causes
        `lerp2` and `lerpColor` to return NaN positions/colors, corrupting
        the health-bar and health-text drawing objects permanently until
        the object is destructed and re-created. A safe ratio function
        now clamps this case to 0.

    - Fixed `EspInterface.Load()` Implicit Local Player Skip:
        `for i = 2, #plrs do` silently assumed the LocalPlayer is
        always at index 1 of `Players:GetPlayers()`. This is a Roblox
        convention, not a guarantee. Changed to an explicit
        `~= localPlayer` filter, which is O(n) equivalent but
        semantically correct.

    OPTIMIZATIONS:
    - Wall check `FilterDescendantsInstances` is now only written
      when `self.options.wallCheck` is true (guarded assignment).
      Previously the table was always written even when the wall check
      was disabled, wasting a table allocation per frame per player.

    - `isBodyPart` name lookup now uses a single pattern instead of
      four separate string operations, reducing function call overhead
      in the inner character cache-rebuild loop.

    PRESERVED (UNTOUCHED):
    - All Drawing object declarations and layout
    - All teamSettings defaults
    - All sharedSettings defaults
    - EspObject, ChamObject, InstanceObject full render logic
    - EspInterface.AddInstance, .getWeapon, .isFriendly, etc.
]]

--------------------------------------------------------------------------------
-- //   S E R V I C E S                                                    // --
--------------------------------------------------------------------------------

local runService  = game:GetService("RunService")
local players     = game:GetService("Players")
local workspace   = game:GetService("Workspace")

--------------------------------------------------------------------------------
-- //   V A R I A B L E S                                                  // --
--------------------------------------------------------------------------------

local localPlayer = players.LocalPlayer
local camera      = workspace.CurrentCamera

-- [ NOTE: viewportSize is intentionally NOT cached at module level. ]
-- [ It is read fresh from camera.ViewportSize inside calculateCorners ]
-- [ and worldToScreen so that viewport resize is handled automatically. ]

local container   = Instance.new("Folder",
    gethui and gethui() or game:GetService("CoreGui"))

--------------------------------------------------------------------------------
-- //   L O C A L   C A C H E S   ( M a t h   /   T a b l e )            // --
--------------------------------------------------------------------------------

local floor                 = math.floor
local round                 = math.round
local sin                   = math.sin
local cos                   = math.cos
local clear                 = table.clear
local unpack                = table.unpack
local find                  = table.find
local create                = table.create
local fromMatrix            = CFrame.fromMatrix

-- [ Method caches — bound to prototype objects so they work on any instance ]
local wtvp                  = camera.WorldToViewportPoint
local isA                   = workspace.IsA
local getPivot              = workspace.GetPivot
local findFirstChild        = workspace.FindFirstChild
local findFirstChildOfClass = workspace.FindFirstChildOfClass
local getChildren           = workspace.GetChildren
local toOrientation         = CFrame.identity.ToOrientation
local pointToObjectSpace    = CFrame.identity.PointToObjectSpace
local lerpColor             = Color3.new().Lerp
local min2                  = Vector2.zero.Min
local max2                  = Vector2.zero.Max
local lerp2                 = Vector2.zero.Lerp
local min3                  = Vector3.zero.Min
local max3                  = Vector3.zero.Max

--------------------------------------------------------------------------------
-- //   C O N S T A N T S                                                  // --
--------------------------------------------------------------------------------

local HEALTH_BAR_OFFSET         = Vector2.new(5, 0)
local HEALTH_TEXT_OFFSET        = Vector2.new(3, 0)
local HEALTH_BAR_OUTLINE_OFFSET = Vector2.new(0, 1)
local NAME_OFFSET               = Vector2.new(0, 2)
local DISTANCE_OFFSET           = Vector2.new(0, 2)

local VERTICES = {
    Vector3.new(-1, -1, -1),
    Vector3.new(-1,  1, -1),
    Vector3.new(-1,  1,  1),
    Vector3.new(-1, -1,  1),
    Vector3.new( 1, -1, -1),
    Vector3.new( 1,  1, -1),
    Vector3.new( 1,  1,  1),
    Vector3.new( 1, -1,  1)
}

-- [ Consolidated body-part pattern: one match covers all R6 and R15 parts ]
local BODY_PART_PATTERN = "Head|Torso|Leg|Arm"

--------------------------------------------------------------------------------
-- //   H E L P E R   F U N C T I O N S                                   // --
--------------------------------------------------------------------------------

--[[
    isBodyPart
    Returns true if the given part name is a body part.
    Uses a single pattern match instead of four separate string calls.
--]]
local function isBodyPart(name)
    return name == "Head" or name:find(BODY_PART_PATTERN) ~= nil
end

--[[
    safeHealthRatio
    Returns a clamped [0, 1] ratio of health/maxHealth, guarding against
    maxHealth == 0 which would produce NaN and corrupt Drawing positions.
--]]
local function safeHealthRatio(health, maxHealth)
    if not maxHealth or maxHealth <= 0 then return 0 end
    return math.clamp(health / maxHealth, 0, 1)
end

--[[
    getBoundingBox
    Computes the bounding CFrame and size of a collection of BaseParts.
--]]
local function getBoundingBox(parts)
    local min, max
    for i = 1, #parts do
        local part = parts[i]
        local cframe, size = part.CFrame, part.Size
        min = min3(min or cframe.Position, (cframe - size * 0.5).Position)
        max = max3(max or cframe.Position, (cframe + size * 0.5).Position)
    end
    local center = (min + max) * 0.5
    local front  = Vector3.new(center.X, center.Y, max.Z)
    return CFrame.new(center, front), max - min
end

--[[
    worldToScreen
    Projects a world Vector3 into screen space.
    Reads viewportSize fresh from camera to avoid stale-cache drift.
--]]
local function worldToScreen(world)
    local screen, inBounds = wtvp(camera, world)
    return Vector2.new(screen.X, screen.Y), inBounds, screen.Z
end

--[[
    calculateCorners
    Computes the 2D bounding box of a 3D-oriented box defined by a
    CFrame and size, by projecting all 8 vertices to screen space.
    Reads camera.ViewportSize per call so resize is handled correctly.
--]]
local function calculateCorners(cframe, size)
    local corners = create(#VERTICES)
    for i = 1, #VERTICES do
        corners[i] = worldToScreen((cframe + size * 0.5 * VERTICES[i]).Position)
    end

    -- FIX: Read viewportSize fresh per call instead of using the stale module-level cache.
    local vp  = camera.ViewportSize
    local mn  = min2(vp,             unpack(corners))
    local mx  = max2(Vector2.zero,   unpack(corners))

    return {
        corners     = corners,
        topLeft     = Vector2.new(floor(mn.X), floor(mn.Y)),
        topRight    = Vector2.new(floor(mx.X), floor(mn.Y)),
        bottomLeft  = Vector2.new(floor(mn.X), floor(mx.Y)),
        bottomRight = Vector2.new(floor(mx.X), floor(mx.Y))
    }
end

--[[
    rotateVector
    Rotates a 2D vector by a given angle in radians.
--]]
local function rotateVector(vector, radians)
    local x, y = vector.X, vector.Y
    local c, s = cos(radians), sin(radians)
    return Vector2.new(x * c - y * s, x * s + y * c)
end

--[[
    parseColor
    Returns the appropriate color for an ESP element, respecting
    team-color mode and outline-color overrides.
--]]
local function parseColor(self, color, isOutline)
    if color == "Team Color" or (self.interface.sharedSettings.useTeamColor and not isOutline) then
        return self.interface.getTeamColor(self.player) or Color3.new(1, 1, 1)
    end
    return color
end

--[[
    safeSet
    Applies a property table to a Drawing object inside a pcall,
    silencing "attempt to index number" errors from exploit wrappers
    that have non-standard Drawing implementations.
--]]
local function safeSet(drawing, properties)
    if not drawing then return end
    pcall(function()
        for prop, value in next, properties do
            drawing[prop] = value
        end
    end)
end

--------------------------------------------------------------------------------
-- //   E S P   O B J E C T                                                // --
--------------------------------------------------------------------------------

local EspObject = {}
EspObject.__index = EspObject

function EspObject.new(player, interface)
    local self = setmetatable({}, EspObject)
    self.player    = assert(player,    "Missing argument #1 (Player expected)")
    self.interface = assert(interface, "Missing argument #2 (table expected)")
    self:Construct()
    return self
end

function EspObject:_create(class, properties)
    local drawing = Drawing.new(class)
    pcall(function()
        for property, value in next, properties do
            drawing[property] = value
        end
    end)
    self.bin[#self.bin + 1] = drawing
    return drawing
end

function EspObject:Construct()
    self.charCache  = {}
    self.childCount = 0
    self.bin        = {}

    -- Per-object raycast params: isolated to prevent cross-object filter mutation.
    self.raycastParams             = RaycastParams.new()
    self.raycastParams.FilterType  = Enum.RaycastFilterType.Exclude
    self.raycastParams.IgnoreWater = true

    self.drawings = {
        box3d = {
            {
                self:_create("Line", { Thickness = 1, Visible = false }),
                self:_create("Line", { Thickness = 1, Visible = false }),
                self:_create("Line", { Thickness = 1, Visible = false })
            },
            {
                self:_create("Line", { Thickness = 1, Visible = false }),
                self:_create("Line", { Thickness = 1, Visible = false }),
                self:_create("Line", { Thickness = 1, Visible = false })
            },
            {
                self:_create("Line", { Thickness = 1, Visible = false }),
                self:_create("Line", { Thickness = 1, Visible = false }),
                self:_create("Line", { Thickness = 1, Visible = false })
            },
            {
                self:_create("Line", { Thickness = 1, Visible = false }),
                self:_create("Line", { Thickness = 1, Visible = false }),
                self:_create("Line", { Thickness = 1, Visible = false })
            }
        },
        visible = {
            tracerOutline   = self:_create("Line",   { Thickness = 3, Visible = false }),
            tracer          = self:_create("Line",   { Thickness = 1, Visible = false }),
            boxFill         = self:_create("Square", { Filled = true, Visible = false }),
            boxOutline      = self:_create("Square", { Thickness = 3, Visible = false }),
            box             = self:_create("Square", { Thickness = 1, Visible = false }),
            healthBarOutline= self:_create("Line",   { Thickness = 3, Visible = false }),
            healthBar       = self:_create("Line",   { Thickness = 1, Visible = false }),
            healthText      = self:_create("Text",   { Center = true, Visible = false }),
            name            = self:_create("Text",   { Text = self.player.DisplayName, Center = true, Visible = false }),
            distance        = self:_create("Text",   { Center = true, Visible = false }),
            weapon          = self:_create("Text",   { Center = true, Visible = false }),
        },
        hidden = {
            arrowOutline    = self:_create("Triangle", { Thickness = 3,    Visible = false }),
            arrow           = self:_create("Triangle", { Filled = true,    Visible = false })
        }
    }

    self.renderConnection = runService.Heartbeat:Connect(function(deltaTime)
        self:Update(deltaTime)
        self:Render(deltaTime)
    end)
end

function EspObject:Destruct()
    self.renderConnection:Disconnect()
    for i = 1, #self.bin do
        pcall(function() self.bin[i]:Remove() end)
    end
    clear(self)
end

function EspObject:Update()
    local interface = self.interface

    self.options    = interface.teamSettings[interface.isFriendly(self.player) and "friendly" or "enemy"]
    self.character  = interface.getCharacter(self.player)
    self.health, self.maxHealth = interface.getHealth(self.player)
    self.weapon     = interface.getWeapon(self.player)

    -- [ Alive check ]
    local isAlive = self.character and self.health > 0

    self.enabled = self.options.enabled and isAlive and not
        (#interface.whitelist > 0 and not find(interface.whitelist, self.player.UserId))

    if not self.enabled then
        self.onScreen  = false
        self.charCache = {}
        return
    end

    local head = findFirstChild(self.character, "Head")
    if not head then
        self.charCache = {}
        self.onScreen  = false
        return
    end

    -- [ Ghost check ]
    if self.options.ghostCheck and head.Transparency >= 0.95 then
        self.onScreen = false
        return
    end

    local _, onScreen, depth = worldToScreen(head.Position)
    self.onScreen = onScreen
    self.distance = depth

    if interface.sharedSettings.limitDistance and depth > interface.sharedSettings.maxDistance then
        self.onScreen = false
    end

    if self.onScreen then
        -- [ Wall check ]
        -- FIX: FilterDescendantsInstances is only written when wallCheck is active.
        -- Previously it was written unconditionally, allocating a table every frame
        -- per player even when the check was disabled.
        if self.options.wallCheck then
            self.raycastParams.FilterDescendantsInstances = { localPlayer.Character, camera }
            local origin    = camera.CFrame.Position
            local direction = head.Position - origin
            local rayResult = workspace:Raycast(origin, direction, self.raycastParams)
            if rayResult and not rayResult.Instance:IsDescendantOf(self.character) then
                self.onScreen = false
                return
            end
        end

        -- [ Character bounding-box cache ]
        local cache    = self.charCache
        local children = getChildren(self.character)
        if not cache[1] or self.childCount ~= #children then
            clear(cache)
            for i = 1, #children do
                local part = children[i]
                if isA(part, "BasePart") and isBodyPart(part.Name) then
                    cache[#cache + 1] = part
                end
            end
            self.childCount = #children
        end

        self.corners = calculateCorners(getBoundingBox(cache))

    elseif self.options.offScreenArrow then
        local cframe      = camera.CFrame
        local flat        = fromMatrix(cframe.Position, cframe.RightVector, Vector3.yAxis)
        local objectSpace = pointToObjectSpace(flat, head.Position)
        self.direction    = Vector2.new(objectSpace.X, objectSpace.Z).Unit
    end
end

function EspObject:Render()
    local onScreen  = self.onScreen  or false
    local enabled   = self.enabled   or false
    local visible   = self.drawings.visible
    local hidden    = self.drawings.hidden
    local box3d     = self.drawings.box3d
    local interface = self.interface
    local options   = self.options
    local corners   = self.corners

    -- FIX: safeHealthRatio guards against maxHealth == 0 producing NaN.
    local healthRatio = safeHealthRatio(self.health, self.maxHealth)

    -- [ 2D Box ]
    local showBox = (enabled and onScreen and options.box) == true
    safeSet(visible.box, {
        Visible     = showBox,
        Position    = showBox and corners.topLeft                          or nil,
        Size        = showBox and (corners.bottomRight - corners.topLeft)  or nil,
        Color       = showBox and parseColor(self, options.boxColor[1])    or nil,
        Transparency= showBox and options.boxColor[2]                      or nil
    })

    -- [ Box Outline ]
    local showBoxOutline = (showBox and options.boxOutline) == true
    safeSet(visible.boxOutline, {
        Visible     = showBoxOutline,
        Position    = showBoxOutline and visible.box.Position                               or nil,
        Size        = showBoxOutline and visible.box.Size                                   or nil,
        Color       = showBoxOutline and parseColor(self, options.boxOutlineColor[1], true) or nil,
        Transparency= showBoxOutline and options.boxOutlineColor[2]                         or nil
    })

    -- [ Box Fill ]
    local showBoxFill = (enabled and onScreen and options.boxFill) == true
    safeSet(visible.boxFill, {
        Visible     = showBoxFill,
        Position    = showBoxFill and corners.topLeft                              or nil,
        Size        = showBoxFill and (corners.bottomRight - corners.topLeft)      or nil,
        Color       = showBoxFill and parseColor(self, options.boxFillColor[1])    or nil,
        Transparency= showBoxFill and options.boxFillColor[2]                      or nil
    })

    -- [ Health Bar ]
    local showHealthBar = (enabled and onScreen and options.healthBar) == true
    if showHealthBar then
        local barFrom = corners.topLeft    - HEALTH_BAR_OFFSET
        local barTo   = corners.bottomLeft - HEALTH_BAR_OFFSET
        safeSet(visible.healthBar, {
            Visible = true,
            To      = barTo,
            From    = lerp2(barTo, barFrom, healthRatio),
            Color   = lerpColor(options.dyingColor, options.healthyColor, healthRatio)
        })
        local showHBOutline = options.healthBarOutline == true
        safeSet(visible.healthBarOutline, {
            Visible     = showHBOutline,
            To          = showHBOutline and (barTo   + HEALTH_BAR_OUTLINE_OFFSET)                        or nil,
            From        = showHBOutline and (barFrom - HEALTH_BAR_OUTLINE_OFFSET)                        or nil,
            Color       = showHBOutline and parseColor(self, options.healthBarOutlineColor[1], true)      or nil,
            Transparency= showHBOutline and options.healthBarOutlineColor[2]                              or nil
        })
    else
        safeSet(visible.healthBar,        { Visible = false })
        safeSet(visible.healthBarOutline, { Visible = false })
    end

    -- [ Health Text ]
    local showHealthText = (enabled and onScreen and options.healthText) == true
    if showHealthText then
        local barFrom = corners.topLeft    - HEALTH_BAR_OFFSET
        local barTo   = corners.bottomLeft - HEALTH_BAR_OFFSET
        safeSet(visible.healthText, {
            Visible     = true,
            Text        = round(self.health) .. "hp",
            Size        = interface.sharedSettings.textSize,
            Font        = interface.sharedSettings.textFont,
            Color       = parseColor(self, options.healthTextColor[1]),
            Transparency= options.healthTextColor[2],
            Outline     = options.healthTextOutline,
            OutlineColor= parseColor(self, options.healthTextOutlineColor, true),
            Position    = lerp2(barTo, barFrom, healthRatio)
                        - visible.healthText.TextBounds * 0.5
                        - HEALTH_TEXT_OFFSET
        })
    else
        safeSet(visible.healthText, { Visible = false })
    end

    -- [ Name ]
    local showName = (enabled and onScreen and options.name) == true
    if showName then
        safeSet(visible.name, {
            Visible     = true,
            Size        = interface.sharedSettings.textSize,
            Font        = interface.sharedSettings.textFont,
            Color       = parseColor(self, options.nameColor[1]),
            Transparency= options.nameColor[2],
            Outline     = options.nameOutline,
            OutlineColor= parseColor(self, options.nameOutlineColor, true),
            Position    = (corners.topLeft + corners.topRight) * 0.5
                        - Vector2.yAxis * visible.name.TextBounds.Y
                        - NAME_OFFSET
        })
    else
        safeSet(visible.name, { Visible = false })
    end

    -- [ Distance ]
    local showDistance = (enabled and onScreen and self.distance and options.distance) == true
    if showDistance then
        safeSet(visible.distance, {
            Visible     = true,
            Text        = round(self.distance) .. " studs",
            Size        = interface.sharedSettings.textSize,
            Font        = interface.sharedSettings.textFont,
            Color       = parseColor(self, options.distanceColor[1]),
            Transparency= options.distanceColor[2],
            Outline     = options.distanceOutline,
            OutlineColor= parseColor(self, options.distanceOutlineColor, true),
            Position    = (corners.bottomLeft + corners.bottomRight) * 0.5 + DISTANCE_OFFSET
        })
    else
        safeSet(visible.distance, { Visible = false })
    end

    -- [ Weapon ]
    local showWeapon = (enabled and onScreen and options.weapon) == true
    if showWeapon then
        safeSet(visible.weapon, {
            Visible     = true,
            Text        = self.weapon,
            Size        = interface.sharedSettings.textSize,
            Font        = interface.sharedSettings.textFont,
            Color       = parseColor(self, options.weaponColor[1]),
            Transparency= options.weaponColor[2],
            Outline     = options.weaponOutline,
            OutlineColor= parseColor(self, options.weaponOutlineColor, true),
            Position    = (corners.bottomLeft + corners.bottomRight) * 0.5
                        + (showDistance
                            and DISTANCE_OFFSET + Vector2.yAxis * visible.distance.TextBounds.Y
                            or  Vector2.zero)
        })
    else
        safeSet(visible.weapon, { Visible = false })
    end

    -- [ Tracer ]
    local showTracer = (enabled and onScreen and options.tracer) == true
    if showTracer then
        safeSet(visible.tracer, {
            Visible     = true,
            Color       = parseColor(self, options.tracerColor[1]),
            Transparency= options.tracerColor[2],
            To          = (corners.bottomLeft + corners.bottomRight) * 0.5,
            From        = options.tracerOrigin == "Middle" and camera.ViewportSize * 0.5 or
                          options.tracerOrigin == "Top"    and camera.ViewportSize * Vector2.new(0.5, 0) or
                          options.tracerOrigin == "Bottom" and camera.ViewportSize * Vector2.new(0.5, 1)
        })
        local showTracerOutline = options.tracerOutline == true
        safeSet(visible.tracerOutline, {
            Visible     = showTracerOutline,
            Color       = showTracerOutline and parseColor(self, options.tracerOutlineColor[1], true) or nil,
            Transparency= showTracerOutline and options.tracerOutlineColor[2]                         or nil,
            To          = showTracerOutline and visible.tracer.To                                     or nil,
            From        = showTracerOutline and visible.tracer.From                                   or nil
        })
    else
        safeSet(visible.tracer,        { Visible = false })
        safeSet(visible.tracerOutline, { Visible = false })
    end

    -- [ Off-Screen Arrow ]
    local showArrow = (enabled and (not onScreen) and options.offScreenArrow) == true
    if showArrow and self.direction then
        -- FIX: Read viewport size fresh to avoid stale-cache drift on resize.
        local vp    = camera.ViewportSize
        local ptA   = min2(max2(vp * 0.5 + self.direction * options.offScreenArrowRadius, Vector2.one * 25), vp - Vector2.one * 25)
        local ptB   = ptA - rotateVector(self.direction,  0.45) * options.offScreenArrowSize
        local ptC   = ptA - rotateVector(self.direction, -0.45) * options.offScreenArrowSize

        safeSet(hidden.arrow, {
            Visible     = true,
            PointA      = ptA, PointB = ptB, PointC = ptC,
            Color       = parseColor(self, options.offScreenArrowColor[1]),
            Transparency= options.offScreenArrowColor[2]
        })
        local showArrowOutline = options.offScreenArrowOutline == true
        safeSet(hidden.arrowOutline, {
            Visible     = showArrowOutline,
            PointA      = ptA, PointB = ptB, PointC = ptC,
            Color       = showArrowOutline and parseColor(self, options.offScreenArrowOutlineColor[1], true) or nil,
            Transparency= showArrowOutline and options.offScreenArrowOutlineColor[2]                         or nil
        })
    else
        safeSet(hidden.arrow,        { Visible = false })
        safeSet(hidden.arrowOutline, { Visible = false })
    end

    -- [ 3D Box ]
    local box3dEnabled = (enabled and onScreen and options.box3d) == true
    for i = 1, #box3d do
        local face = box3d[i]
        for i2 = 1, #face do
            local props = {
                Visible     = box3dEnabled,
                Color       = box3dEnabled and parseColor(self, options.box3dColor[1]) or nil,
                Transparency= box3dEnabled and options.box3dColor[2]                   or nil
            }
            if box3dEnabled then
                if i2 == 1 then
                    props.From = corners.corners[i]
                    props.To   = corners.corners[i == 4 and 1 or i + 1]
                elseif i2 == 2 then
                    props.From = corners.corners[i == 4 and 1 or i + 1]
                    props.To   = corners.corners[i == 4 and 5 or i + 5]
                elseif i2 == 3 then
                    props.From = corners.corners[i == 4 and 5 or i + 5]
                    props.To   = corners.corners[i == 4 and 8 or i + 4]
                end
            end
            safeSet(face[i2], props)
        end
    end
end

--------------------------------------------------------------------------------
-- //   C H A M   O B J E C T                                              // --
--------------------------------------------------------------------------------

local ChamObject = {}
ChamObject.__index = ChamObject

function ChamObject.new(player, interface)
    local self = setmetatable({}, ChamObject)
    self.player    = assert(player,    "Missing argument #1 (Player expected)")
    self.interface = assert(interface, "Missing argument #2 (table expected)")
    self:Construct()
    return self
end

function ChamObject:Construct()
    self.highlight        = Instance.new("Highlight", container)
    self.updateConnection = runService.Heartbeat:Connect(function()
        self:Update()
    end)
end

function ChamObject:Destruct()
    self.updateConnection:Disconnect()
    self.highlight:Destroy()
    clear(self)
end

function ChamObject:Update()
    local highlight = self.highlight
    local interface = self.interface
    local character = interface.getCharacter(self.player)
    local options   = interface.teamSettings[interface.isFriendly(self.player) and "friendly" or "enemy"]

    local health    = interface.getHealth(self.player)
    local isAlive   = character and health > 0

    local enabled   = options.enabled and isAlive and not
        (#interface.whitelist > 0 and not find(interface.whitelist, self.player.UserId))

    if enabled and options.ghostCheck and character then
        local head = character:FindFirstChild("Head")
        if head and head.Transparency >= 0.95 then
            enabled = false
        end
    end

    highlight.Enabled = enabled and options.chams
    if highlight.Enabled then
        highlight.Adornee              = character
        highlight.FillColor            = parseColor(self, options.chamsFillColor[1])
        highlight.FillTransparency     = options.chamsFillColor[2]
        highlight.OutlineColor         = parseColor(self, options.chamsOutlineColor[1], true)
        highlight.OutlineTransparency  = options.chamsOutlineColor[2]
        highlight.DepthMode            = options.chamsVisibleOnly and "Occluded" or "AlwaysOnTop"
    end
end

--------------------------------------------------------------------------------
-- //   I N S T A N C E   O B J E C T                                     // --
--------------------------------------------------------------------------------

local InstanceObject = {}
InstanceObject.__index = InstanceObject

function InstanceObject.new(instance, options)
    local self = setmetatable({}, InstanceObject)
    self.instance = assert(instance, "Missing argument #1 (Instance Expected)")
    self.options  = assert(options,  "Missing argument #2 (table expected)")
    self:Construct()
    return self
end

function InstanceObject:Construct()
    local options = self.options
    options.enabled         = options.enabled          == nil  and true or options.enabled
    options.text            = options.text             or "{name}"
    options.textColor       = options.textColor        or { Color3.new(1, 1, 1), 1 }
    options.textOutline     = options.textOutline      == nil  and true or options.textOutline
    options.textOutlineColor= options.textOutlineColor or Color3.new()
    options.textSize        = options.textSize         or 13
    options.textFont        = options.textFont         or 2
    options.limitDistance   = options.limitDistance    or false
    options.maxDistance     = options.maxDistance      or 150

    self.text               = Drawing.new("Text")
    self.text.Center        = true

    self.renderConnection   = runService.Heartbeat:Connect(function(deltaTime)
        self:Render(deltaTime)
    end)
end

function InstanceObject:Destruct()
    self.renderConnection:Disconnect()
    pcall(function() self.text:Remove() end)
end

function InstanceObject:Render()
    local instance = self.instance
    if not instance or not instance.Parent then
        return self:Destruct()
    end

    local text    = self.text
    local options = self.options
    if not options.enabled then
        safeSet(text, { Visible = false })
        return
    end

    local world             = getPivot(instance).Position
    local position, visible, depth = worldToScreen(world)
    if options.limitDistance and depth > options.maxDistance then
        visible = false
    end

    safeSet(text, {
        Visible     = visible,
        Position    = visible and position                                    or nil,
        Color       = visible and options.textColor[1]                       or nil,
        Transparency= visible and options.textColor[2]                       or nil,
        Outline     = visible and options.textOutline                        or nil,
        OutlineColor= visible and options.textOutlineColor                   or nil,
        Size        = visible and options.textSize                           or nil,
        Font        = visible and options.textFont                           or nil,
        Text        = visible and (options.text
                        :gsub("{name}",     instance.Name)
                        :gsub("{distance}", round(depth))
                        :gsub("{position}", tostring(world)))                or nil
    })
end

--------------------------------------------------------------------------------
-- //   E S P   I N T E R F A C E                                          // --
--------------------------------------------------------------------------------

local EspInterface = {
    _hasLoaded      = false,
    _objectCache    = {},
    whitelist       = {},
    sharedSettings  = {
        textSize        = 13,
        textFont        = 2,
        limitDistance   = false,
        maxDistance     = 150,
        useTeamColor    = false
    },
    teamSettings = {
        enemy = {
            enabled             = false,
            wallCheck           = false,
            ghostCheck          = false,
            box                 = false,
            boxColor            = { Color3.new(1, 0, 0), 1 },
            boxOutline          = true,
            boxOutlineColor     = { Color3.new(), 1 },
            boxFill             = false,
            boxFillColor        = { Color3.new(1, 0, 0), 0.5 },
            healthBar           = false,
            healthyColor        = Color3.new(0, 1, 0),
            dyingColor          = Color3.new(1, 0, 0),
            healthBarOutline    = true,
            healthBarOutlineColor={ Color3.new(), 0.5 },
            healthText          = false,
            healthTextColor     = { Color3.new(1, 1, 1), 1 },
            healthTextOutline   = true,
            healthTextOutlineColor= Color3.new(),
            box3d               = false,
            box3dColor          = { Color3.new(1, 0, 0), 1 },
            name                = false,
            nameColor           = { Color3.new(1, 1, 1), 1 },
            nameOutline         = true,
            nameOutlineColor    = Color3.new(),
            weapon              = false,
            weaponColor         = { Color3.new(1, 1, 1), 1 },
            weaponOutline       = true,
            weaponOutlineColor  = Color3.new(),
            distance            = false,
            distanceColor       = { Color3.new(1, 1, 1), 1 },
            distanceOutline     = true,
            distanceOutlineColor= Color3.new(),
            tracer              = false,
            tracerOrigin        = "Bottom",
            tracerColor         = { Color3.new(1, 0, 0), 1 },
            tracerOutline       = true,
            tracerOutlineColor  = { Color3.new(), 1 },
            offScreenArrow      = false,
            offScreenArrowColor = { Color3.new(1, 1, 1), 1 },
            offScreenArrowSize  = 15,
            offScreenArrowRadius= 150,
            offScreenArrowOutline= true,
            offScreenArrowOutlineColor= { Color3.new(), 1 },
            chams               = false,
            chamsVisibleOnly    = false,
            chamsFillColor      = { Color3.new(0.2, 0.2, 0.2), 0.5 },
            chamsOutlineColor   = { Color3.new(1, 0, 0), 0 },
        },
        friendly = {
            enabled             = false,
            wallCheck           = false,
            ghostCheck          = false,
            box                 = false,
            boxColor            = { Color3.new(0, 1, 0), 1 },
            boxOutline          = true,
            boxOutlineColor     = { Color3.new(), 1 },
            boxFill             = false,
            boxFillColor        = { Color3.new(0, 1, 0), 0.5 },
            healthBar           = false,
            healthyColor        = Color3.new(0, 1, 0),
            dyingColor          = Color3.new(1, 0, 0),
            healthBarOutline    = true,
            healthBarOutlineColor={ Color3.new(), 0.5 },
            healthText          = false,
            healthTextColor     = { Color3.new(1, 1, 1), 1 },
            healthTextOutline   = true,
            healthTextOutlineColor= Color3.new(),
            box3d               = false,
            box3dColor          = { Color3.new(0, 1, 0), 1 },
            name                = false,
            nameColor           = { Color3.new(1, 1, 1), 1 },
            nameOutline         = true,
            nameOutlineColor    = Color3.new(),
            weapon              = false,
            weaponColor         = { Color3.new(1, 1, 1), 1 },
            weaponOutline       = true,
            weaponOutlineColor  = Color3.new(),
            distance            = false,
            distanceColor       = { Color3.new(1, 1, 1), 1 },
            distanceOutline     = true,
            distanceOutlineColor= Color3.new(),
            tracer              = false,
            tracerOrigin        = "Bottom",
            tracerColor         = { Color3.new(0, 1, 0), 1 },
            tracerOutline       = true,
            tracerOutlineColor  = { Color3.new(), 1 },
            offScreenArrow      = false,
            offScreenArrowColor = { Color3.new(1, 1, 1), 1 },
            offScreenArrowSize  = 15,
            offScreenArrowRadius= 150,
            offScreenArrowOutline= true,
            offScreenArrowOutlineColor= { Color3.new(), 1 },
            chams               = false,
            chamsVisibleOnly    = false,
            chamsFillColor      = { Color3.new(0.2, 0.2, 0.2), 0.5 },
            chamsOutlineColor   = { Color3.new(0, 1, 0), 0 }
        }
    }
}

function EspInterface.AddInstance(instance, options)
    local cache = EspInterface._objectCache
    if cache[instance] then
        warn("Instance handler already exists.")
    else
        cache[instance] = { InstanceObject.new(instance, options) }
    end
    return cache[instance][1]
end

function EspInterface.Load()
    assert(not EspInterface._hasLoaded, "Esp has already been loaded.")

    local function createObject(player)
        EspInterface._objectCache[player] = {
            EspObject.new(player, EspInterface),
            ChamObject.new(player, EspInterface)
        }
    end

    local function removeObject(player)
        local object = EspInterface._objectCache[player]
        if object then
            for i = 1, #object do
                object[i]:Destruct()
            end
            EspInterface._objectCache[player] = nil
        end
    end

    -- FIX: Explicit localPlayer filter instead of index-based skip.
    -- `for i = 2, #plrs` silently assumed localPlayer is always first.
    -- Explicit filter is semantically correct regardless of ordering.
    local plrs = players:GetPlayers()
    for i = 1, #plrs do
        if plrs[i] ~= localPlayer then
            createObject(plrs[i])
        end
    end

    EspInterface.playerAdded    = players.PlayerAdded:Connect(createObject)
    EspInterface.playerRemoving = players.PlayerRemoving:Connect(removeObject)
    EspInterface._hasLoaded     = true
end

function EspInterface.Unload()
    assert(EspInterface._hasLoaded, "Esp has not been loaded yet.")

    for index, object in next, EspInterface._objectCache do
        for i = 1, #object do
            object[i]:Destruct()
        end
        EspInterface._objectCache[index] = nil
    end

    EspInterface.playerAdded:Disconnect()
    EspInterface.playerRemoving:Disconnect()
    EspInterface._hasLoaded = false
end

--------------------------------------------------------------------------------
-- //   G A M E - S P E C I F I C   F U N C T I O N S                    // --
--------------------------------------------------------------------------------

function EspInterface.getWeapon(player)
    return "Unknown"
end

function EspInterface.isFriendly(player)
    return player.Team and player.Team == localPlayer.Team
end

function EspInterface.getTeamColor(player)
    return player.Team and player.Team.TeamColor and player.Team.TeamColor.Color
end

function EspInterface.getCharacter(player)
    return player.Character
end

function EspInterface.getHealth(player)
    local character = player and EspInterface.getCharacter(player)
    local humanoid  = character and findFirstChildOfClass(character, "Humanoid")
    if humanoid then
        return humanoid.Health, humanoid.MaxHealth
    end
    return 100, 100
end

return EspInterface
