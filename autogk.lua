-- Auto-GK • Built-in UI Version
-- Place this in a Gist as AutoGK.lua, then load with:
-- loadstring(game:HttpGet("YOUR_GIST_RAW_URL_HERE"))()

-- ═══════════════════════════════════════════════════════════
--  SERVICES & PLAYER
-- ═══════════════════════════════════════════════════════════

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local humanoidRootPart = character:WaitForChild("HumanoidRootPart")
local humanoid = character:WaitForChild("Humanoid")

-- ═══════════════════════════════════════════════════════════
--  SETTINGS TABLE
-- ═══════════════════════════════════════════════════════════

local Settings = {
    Enabled = false,

    PredictionTime = 5,
    MinBallSpeed = 50,
    CatchTolerance = 1,
    CenterTolerance = 1.5,
    ResetDelay = 0.5,
    ShootingDistance = 250,
    SimulationStep = 5,

    -- Reaction Time (ms)
    ReactionTimeMin = 150,
    ReactionTimeMax = 200,

    AutoJumpEnabled = false,
    JumpThreshold = 7,
    JumpCooldown = 1.5,
    JumpAnticipation = 0.3,

    AwayGoalPosX = 0,
    AwayGoalPosY = 5.3,
    AwayGoalPosZ = 350.8,
    AwayGoalSizeX = 6.4,
    AwayGoalSizeY = 9.6,
    AwayGoalSizeZ = 27.4,

    HomeGoalPosX = 0,
    HomeGoalPosY = 5.3,
    HomeGoalPosZ = -350.8,
    HomeGoalSizeX = 6.4,
    HomeGoalSizeY = 9.6,
    HomeGoalSizeZ = 27.4,

    CustomGravity = 100,
    AirDensity = 10,
    AirFriction = 7,
    AngularFriction = 40,
    CurvePower = 125,
    MinVelForCurve = 95,

    AutoCenterEnabled = false,
}

-- ═══════════════════════════════════════════════════════════
--  DERIVED GOAL TABLES
-- ═══════════════════════════════════════════════════════════

local AWAY_GOAL, HOME_GOAL

local function rebuildGoals()
    AWAY_GOAL = {
        Position = Vector3.new(Settings.AwayGoalPosX, Settings.AwayGoalPosY, Settings.AwayGoalPosZ),
        Size = Vector3.new(Settings.AwayGoalSizeX, Settings.AwayGoalSizeY, Settings.AwayGoalSizeZ),
        FrontZ = Settings.AwayGoalPosZ - (Settings.AwayGoalSizeX / 2),
        CenterX = Settings.AwayGoalPosX,
    }
    HOME_GOAL = {
        Position = Vector3.new(Settings.HomeGoalPosX, Settings.HomeGoalPosY, Settings.HomeGoalPosZ),
        Size = Vector3.new(Settings.HomeGoalSizeX, Settings.HomeGoalSizeY, Settings.HomeGoalSizeZ),
        FrontZ = Settings.HomeGoalPosZ + (Settings.HomeGoalSizeX / 2),
        CenterX = Settings.HomeGoalPosX,
    }
end

rebuildGoals()

-- ═══════════════════════════════════════════════════════════
--  STATE
-- ═══════════════════════════════════════════════════════════

local activeGoal = nil
local lastShotTime = 0
local lastJumpTime = 0
local wasSaving = false
local currentStatus = "OFF"
local currentImpactPoint = nil

local currentKeys = { A = false, D = false }

-- Reaction time state
local reactionPending = false
local reactionTargetBall = nil
local reactionStartTime = 0
local reactionDelay = 0
local reactionImpact = nil
local reactionTimeToImpact = nil

-- ═══════════════════════════════════════════════════════════
--  VIRTUAL INPUT
-- ═══════════════════════════════════════════════════════════

local function pressKey(keyCode)
    VirtualInputManager:SendKeyEvent(true, keyCode, false, game)
end

local function releaseKey(keyCode)
    VirtualInputManager:SendKeyEvent(false, keyCode, false, game)
end

local function setMovementKey(key, state)
    local keyCode
    if key == "A" then keyCode = Enum.KeyCode.A
    elseif key == "D" then keyCode = Enum.KeyCode.D
    end

    if currentKeys[key] ~= state then
        currentKeys[key] = state
        if state then
            pressKey(keyCode)
        else
            releaseKey(keyCode)
        end
    end
end

local function releaseAllKeys()
    setMovementKey("A", false)
    setMovementKey("D", false)
end

local function triggerJump()
    local now = tick()
    if now - lastJumpTime < Settings.JumpCooldown then return end
    if humanoid and humanoid:GetState() == Enum.HumanoidStateType.Running then
        lastJumpTime = now
        pressKey(Enum.KeyCode.Space)
        task.delay(0.1, function()
            releaseKey(Enum.KeyCode.Space)
        end)
    end
end

-- ═══════════════════════════════════════════════════════════
--  GOALKEEPER LOGIC
-- ═══════════════════════════════════════════════════════════

local function getRealPhysics()
    return {
        gravity = Settings.CustomGravity,
        airDensity = Settings.AirDensity / 100,
        airFriction = Settings.AirFriction / 1000,
        angularFriction = Settings.AngularFriction / 1000,
        curvePower = Settings.CurvePower,
        minVelForCurve = Settings.MinVelForCurve,
        simStep = Settings.SimulationStep / 1000,
    }
end

local function getNearestGoal()
    if not humanoidRootPart then return AWAY_GOAL end
    local pos = humanoidRootPart.Position
    local dA = math.abs(pos.Z - AWAY_GOAL.Position.Z)
    local dH = math.abs(pos.Z - HOME_GOAL.Position.Z)
    return dA < dH and AWAY_GOAL or HOME_GOAL
end

local function isBall(part)
    if not part or not part:IsA("BasePart") then return false end
    return string.match(part.Name, "^Ball_%d+$") ~= nil
end

local function findActiveBall()
    local bestBall, highestSpeed = nil, Settings.MinBallSpeed
    for _, obj in pairs(Workspace:GetDescendants()) do
        if isBall(obj) then
            local speed = obj.AssemblyLinearVelocity.Magnitude
            if speed > highestSpeed then
                highestSpeed = speed
                bestBall = obj
            end
        end
    end
    return bestBall
end

local function simulateBallPhysicsStep(pos, vel, angularVel, dt, phys)
    local speed = vel.Magnitude
    local gravityForce = Vector3.new(0, -phys.gravity, 0)

    local dragForce = Vector3.zero
    if speed > 0.1 then
        local dragMag = phys.airFriction * speed * speed * phys.airDensity
        dragForce = -vel.Unit * dragMag
    end

    local curveForce = Vector3.zero
    if speed > phys.minVelForCurve and angularVel.Magnitude > 0.1 then
        curveForce = angularVel:Cross(vel) * (phys.curvePower / 10000)
    end

    local totalAccel = gravityForce + dragForce + curveForce
    local newVel = vel + totalAccel * dt
    local newPos = pos + newVel * dt
    local newAngular = angularVel * (1 - phys.angularFriction * dt)

    return newPos, newVel, newAngular
end

local function isBallHeadingToGoal(ballPos, ballVel, goal)
    local goalZ = goal.Position.Z
    local frontZ = goal.FrontZ

    if goalZ > 0 then
        if ballVel.Z <= 0 or ballPos.Z > frontZ then return false end
    else
        if ballVel.Z >= 0 or ballPos.Z < frontZ then return false end
    end

    return math.abs(ballPos.Z - frontZ) <= Settings.ShootingDistance
end

local function findGoalImpactPoint(startPos, startVel, startAngularVel, goal)
    local phys = getRealPhysics()
    local pos, vel = startPos, startVel
    local angularVel = startAngularVel or Vector3.zero
    local t, dt = 0, phys.simStep
    local frontZ = goal.FrontZ
    local goalHalfWidth = goal.Size.Z / 2

    while t < Settings.PredictionTime do
        local lastPos = pos
        pos, vel, angularVel = simulateBallPhysicsStep(pos, vel, angularVel, dt, phys)
        t += dt

        local crossed = false
        if goal.Position.Z > 0 then
            crossed = lastPos.Z < frontZ and pos.Z >= frontZ
        else
            crossed = lastPos.Z > frontZ and pos.Z <= frontZ
        end

        if crossed then
            local ratio = (frontZ - lastPos.Z) / (pos.Z - lastPos.Z)
            local intersect = lastPos:Lerp(pos, ratio)
            local finalY = math.max(intersect.Y, 0.5)

            if math.abs(intersect.X) <= goalHalfWidth + 5 then
                return Vector3.new(intersect.X, finalY, frontZ), t
            end
            return nil, nil
        end

        if pos.Y < 0.5 then
            if math.abs(vel.Z) > 1 then
                local ttg = (frontZ - pos.Z) / vel.Z
                if ttg > 0 and ttg < 5 then
                    local gi = Vector3.new(pos.X + vel.X * ttg, 0.5, frontZ)
                    if math.abs(gi.X) <= goalHalfWidth + 5 then return gi, t + ttg end
                end
            end
            return nil, nil
        end

        if vel.Magnitude < 1 then return nil, nil end
    end

    return nil, nil
end

local function getHorizontalMovement(targetX, playerX, goal)
    local diff = targetX - playerX
    if math.abs(diff) < Settings.CatchTolerance then return false, false end
    if goal.Position.Z > 0 then
        return diff < 0, diff > 0
    else
        return diff > 0, diff < 0
    end
end

local function getMovementToCenter(playerX, goal)
    local diff = goal.CenterX - playerX
    if math.abs(diff) < Settings.CenterTolerance then return false, false end
    if goal.Position.Z > 0 then
        return diff < 0, diff > 0
    else
        return diff > 0, diff < 0
    end
end

-- ═══════════════════════════════════════════════════════════
--  CHARACTER RESPAWN
-- ═══════════════════════════════════════════════════════════

player.CharacterAdded:Connect(function(newChar)
    character = newChar
    humanoidRootPart = character:WaitForChild("HumanoidRootPart")
    humanoid = character:WaitForChild("Humanoid")
    releaseAllKeys()
    wasSaving = false
    reactionPending = false
    reactionTargetBall = nil
end)

-- ═══════════════════════════════════════════════════════════
--  SIMPLE BUILT-IN UI
-- ═══════════════════════════════════════════════════════════

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "AutoGK_UI"
screenGui.ResetOnSpawn = false
screenGui.Parent = game:GetService("CoreGui")

local mainFrame = Instance.new("Frame")
mainFrame.Size = UDim2.new(0, 500, 0, 300)
mainFrame.Position = UDim2.new(0.5, -250, 0.5, -150)
mainFrame.BackgroundColor3 = Color3.fromRGB(26, 32, 58)
mainFrame.BorderSizePixel = 0
mainFrame.Parent = screenGui

local uiCorner = Instance.new("UICorner")
uiCorner.CornerRadius = UDim.new(0, 6)
uiCorner.Parent = mainFrame

local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, 30)
titleBar.BackgroundColor3 = Color3.fromRGB(38, 45, 71)
titleBar.BorderSizePixel = 0
titleBar.Parent = mainFrame

local titleLabel = Instance.new("TextLabel")
titleLabel.Size = UDim2.new(1, -60, 1, 0)
titleLabel.Position = UDim2.new(0, 10, 0, 0)
titleLabel.BackgroundTransparency = 1
titleLabel.Font = Enum.Font.GothamBold
titleLabel.TextSize = 16
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.TextColor3 = Color3.fromRGB(230, 230, 230)
titleLabel.Text = "Auto-GK | Goalkeeper Bot"
titleLabel.Parent = titleBar

local closeButton = Instance.new("TextButton")
closeButton.Size = UDim2.new(0, 50, 1, 0)
closeButton.Position = UDim2.new(1, -50, 0, 0)
closeButton.BackgroundTransparency = 1
closeButton.Font = Enum.Font.GothamBold
closeButton.TextSize = 16
closeButton.TextColor3 = Color3.fromRGB(200, 80, 80)
closeButton.Text = "X"
closeButton.Parent = titleBar

closeButton.MouseButton1Click:Connect(function()
    screenGui.Enabled = not screenGui.Enabled
end)

-- drag
do
    local dragging = false
    local dragStart, startPos

    titleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            dragStart = input.Position
            startPos = mainFrame.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
            local delta = input.Position - dragStart
            mainFrame.Position = UDim2.new(
                startPos.X.Scale,
                startPos.X.Offset + delta.X,
                startPos.Y.Scale,
                startPos.Y.Offset + delta.Y
            )
        end
    end)
end

-- Tabs
local tabBar = Instance.new("Frame")
tabBar.Size = UDim2.new(0, 120, 1, -30)
tabBar.Position = UDim2.new(0, 0, 0, 30)
tabBar.BackgroundColor3 = Color3.fromRGB(38, 45, 71)
tabBar.BorderSizePixel = 0
tabBar.Parent = mainFrame

local tabList = Instance.new("UIListLayout")
tabList.FillDirection = Enum.FillDirection.Vertical
tabList.SortOrder = Enum.SortOrder.LayoutOrder
tabList.Padding = UDim.new(0, 4)
tabList.Parent = tabBar

local contentFrame = Instance.new("Frame")
contentFrame.Size = UDim2.new(1, -120, 1, -30)
contentFrame.Position = UDim2.new(0, 120, 0, 30)
contentFrame.BackgroundTransparency = 1
contentFrame.Parent = mainFrame

local pages = {}

local function createPage(name)
    local page = Instance.new("Frame")
    page.Name = name
    page.Size = UDim2.new(1, 0, 1, 0)
    page.BackgroundTransparency = 1
    page.Visible = false
    page.Parent = contentFrame

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Vertical
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 6)
    layout.Parent = page

    pages[name] = page
    return page
end

local function createTab(name)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, 0, 0, 28)
    btn.BackgroundColor3 = Color3.fromRGB(26, 32, 58)
    btn.BorderSizePixel = 0
    btn.Font = Enum.Font.Gotham
    btn.TextSize = 14
    btn.TextColor3 = Color3.fromRGB(220, 220, 220)
    btn.Text = name
    btn.Parent = tabBar

    btn.MouseButton1Click:Connect(function()
        for n, p in pairs(pages) do
            p.Visible = (n == name)
        end
        for _, other in ipairs(tabBar:GetChildren()) do
            if other:IsA("TextButton") then
                other.BackgroundColor3 = Color3.fromRGB(26, 32, 58)
            end
        end
        btn.BackgroundColor3 = Color3.fromRGB(60, 80, 140)
    end)

    return btn
end

local function createLabel(parent, text)
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -10, 0, 20)
    lbl.BackgroundTransparency = 1
    lbl.Font = Enum.Font.Gotham
    lbl.TextSize = 13
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.TextColor3 = Color3.fromRGB(230, 230, 230)
    lbl.Text = text
    lbl.Parent = parent
    return lbl
end

local function createToggle(parent, text, initial, callback)
    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(1, -10, 0, 24)
    frame.BackgroundTransparency = 1
    frame.Parent = parent

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -60, 1, 0)
    lbl.Position = UDim2.new(0, 0, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Font = Enum.Font.Gotham
    lbl.TextSize = 13
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.TextColor3 = Color3.fromRGB(230, 230, 230)
    lbl.Text = text
    lbl.Parent = frame

    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0, 50, 1, 0)
    btn.Position = UDim2.new(1, -50, 0, 0)
    btn.BackgroundColor3 = initial and Color3.fromRGB(80, 180, 80) or Color3.fromRGB(120, 40, 40)
    btn.BorderSizePixel = 0
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 12
    btn.TextColor3 = Color3.fromRGB(255, 255, 255)
    btn.Text = initial and "ON" or "OFF"
    btn.Parent = frame

    local state = initial

    btn.MouseButton1Click:Connect(function()
        state = not state
        btn.Text = state and "ON" or "OFF"
        btn.BackgroundColor3 = state and Color3.fromRGB(80, 180, 80) or Color3.fromRGB(120, 40, 40)
        if callback then callback(state) end
    end)

    return frame
end

local function createNumberBox(parent, labelText, defaultValue, callback)
    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(1, -10, 0, 24)
    frame.BackgroundTransparency = 1
    frame.Parent = parent

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -80, 1, 0)
    lbl.BackgroundTransparency = 1
    lbl.Font = Enum.Font.Gotham
    lbl.TextSize = 13
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.TextColor3 = Color3.fromRGB(230, 230, 230)
    lbl.Text = labelText
    lbl.Parent = frame

    local box = Instance.new("TextBox")
    box.Size = UDim2.new(0, 70, 1, 0)
    box.Position = UDim2.new(1, -70, 0, 0)
    box.BackgroundColor3 = Color3.fromRGB(40, 50, 80)
    box.BorderSizePixel = 0
    box.Font = Enum.Font.Gotham
    box.TextSize = 13
    box.TextColor3 = Color3.fromRGB(230, 230, 230)
    box.Text = tostring(defaultValue)
    box.ClearTextOnFocus = false
    box.Parent = frame

    box.FocusLost:Connect(function()
        local n = tonumber(box.Text)
        if n then
            if callback then callback(n) end
        else
            box.Text = tostring(defaultValue)
        end
    end)

    return frame
end

-- Tabs & Pages
local mainTabBtn    = createTab("Main")
local behaviourTabBtn = createTab("Behaviour")
local jumpTabBtn    = createTab("Jump")
local goalsTabBtn   = createTab("Goals")
local physicsTabBtn = createTab("Physics")

local mainPage      = createPage("Main")
local behaviourPage = createPage("Behaviour")
local jumpPage      = createPage("Jump")
local goalsPage     = createPage("Goals")
local physicsPage   = createPage("Physics")

-- Main Page
createToggle(mainPage, "Enable Auto-GK (T key)", Settings.Enabled, function(state)
    Settings.Enabled = state
    if not state then
        releaseAllKeys()
        wasSaving = false
        reactionPending = false
        reactionTargetBall = nil
        currentStatus = "OFF"
    end
end)

createLabel(mainPage, "RightShift = Show/Hide UI")

local statusLabel = createLabel(mainPage, "Status: OFF")

-- Behaviour Page
createNumberBox(behaviourPage, "Prediction Time (seconds)", Settings.PredictionTime, function(v)
    Settings.PredictionTime = math.clamp(v, 1, 15)
end)

createNumberBox(behaviourPage, "Min Ball Speed", Settings.MinBallSpeed, function(v)
    Settings.MinBallSpeed = math.max(5, v)
end)

createNumberBox(behaviourPage, "Max Shooting Distance", Settings.ShootingDistance, function(v)
    Settings.ShootingDistance = math.max(50, v)
end)

createNumberBox(behaviourPage, "Catch Tolerance (studs)", Settings.CatchTolerance, function(v)
    Settings.CatchTolerance = math.max(0, v)
end)

createNumberBox(behaviourPage, "Center Tolerance (studs)", Settings.CenterTolerance, function(v)
    Settings.CenterTolerance = math.max(0, v)
end)

createNumberBox(behaviourPage, "Reset Delay (seconds)", Settings.ResetDelay, function(v)
    Settings.ResetDelay = math.max(0, v)
end)

createNumberBox(behaviourPage, "Reaction Time Min (ms)", Settings.ReactionTimeMin, function(v)
    Settings.ReactionTimeMin = math.clamp(v, 0, Settings.ReactionTimeMax)
end)

createNumberBox(behaviourPage, "Reaction Time Max (ms)", Settings.ReactionTimeMax, function(v)
    Settings.ReactionTimeMax = math.max(Settings.ReactionTimeMin, v)
end)

createToggle(behaviourPage, "Auto-Center Enabled", Settings.AutoCenterEnabled, function(state)
    Settings.AutoCenterEnabled = state
end)

-- Jump Page
createToggle(jumpPage, "Enable Auto-Jump", Settings.AutoJumpEnabled, function(state)
    Settings.AutoJumpEnabled = state
end)

createNumberBox(jumpPage, "Jump Threshold (Y height)", Settings.JumpThreshold, function(v)
    Settings.JumpThreshold = math.max(0, v)
end)

createNumberBox(jumpPage, "Jump Cooldown (seconds)", Settings.JumpCooldown, function(v)
    Settings.JumpCooldown = math.max(0, v)
end)

createNumberBox(jumpPage, "Jump Anticipation (seconds)", Settings.JumpAnticipation, function(v)
    Settings.JumpAnticipation = math.max(0, v)
end)

-- Goals Page
createLabel(goalsPage, "Away Goal Position")
createNumberBox(goalsPage, "Away Pos X", Settings.AwayGoalPosX, function(v) Settings.AwayGoalPosX = v rebuildGoals() end)
createNumberBox(goalsPage, "Away Pos Y", Settings.AwayGoalPosY, function(v) Settings.AwayGoalPosY = v rebuildGoals() end)
createNumberBox(goalsPage, "Away Pos Z", Settings.AwayGoalPosZ, function(v) Settings.AwayGoalPosZ = v rebuildGoals() end)
createLabel(goalsPage, "Away Goal Size")
createNumberBox(goalsPage, "Away Size X (Depth)",  Settings.AwayGoalSizeX, function(v) Settings.AwayGoalSizeX = v rebuildGoals() end)
createNumberBox(goalsPage, "Away Size Y (Height)", Settings.AwayGoalSizeY, function(v) Settings.AwayGoalSizeY = v rebuildGoals() end)
createNumberBox(goalsPage, "Away Size Z (Width)",  Settings.AwayGoalSizeZ, function(v) Settings.AwayGoalSizeZ = v rebuildGoals() end)
createLabel(goalsPage, "Home Goal Position")
createNumberBox(goalsPage, "Home Pos X", Settings.HomeGoalPosX, function(v) Settings.HomeGoalPosX = v rebuildGoals() end)
createNumberBox(goalsPage, "Home Pos Y", Settings.HomeGoalPosY, function(v) Settings.HomeGoalPosY = v rebuildGoals() end)
createNumberBox(goalsPage, "Home Pos Z", Settings.HomeGoalPosZ, function(v) Settings.HomeGoalPosZ = v rebuildGoals() end)
createLabel(goalsPage, "Home Goal Size")
createNumberBox(goalsPage, "Home Size X (Depth)",  Settings.HomeGoalSizeX, function(v) Settings.HomeGoalSizeX = v rebuildGoals() end)
createNumberBox(goalsPage, "Home Size Y (Height)", Settings.HomeGoalSizeY, function(v) Settings.HomeGoalSizeY = v rebuildGoals() end)
createNumberBox(goalsPage, "Home Size Z (Width)",  Settings.HomeGoalSizeZ, function(v) Settings.HomeGoalSizeZ = v rebuildGoals() end)

-- Physics Page
createNumberBox(physicsPage, "Custom Gravity",           Settings.CustomGravity,     function(v) Settings.CustomGravity = v end)
createNumberBox(physicsPage, "Air Density (x100)",       Settings.AirDensity,        function(v) Settings.AirDensity = v end)
createNumberBox(physicsPage, "Air Friction (x1000)",     Settings.AirFriction,       function(v) Settings.AirFriction = v end)
createNumberBox(physicsPage, "Angular Friction (x1000)", Settings.AngularFriction,   function(v) Settings.AngularFriction = v end)
createNumberBox(physicsPage, "Curve Power",              Settings.CurvePower,        function(v) Settings.CurvePower = v end)
createNumberBox(physicsPage, "Min Vel for Curve",        Settings.MinVelForCurve,    function(v) Settings.MinVelForCurve = v end)
createNumberBox(physicsPage, "Simulation Step (x1000)",  Settings.SimulationStep,    function(v) Settings.SimulationStep = math.max(1, v) end)

-- Default visible tab
pages["Main"].Visible = true
mainTabBtn.BackgroundColor3 = Color3.fromRGB(60, 80, 140)

-- Keybinds
UserInputService.InputBegan:Connect(function(input, gp)
    if gp then return end
    if input.KeyCode == Enum.KeyCode.T then
        Settings.Enabled = not Settings.Enabled
        if not Settings.Enabled then
            releaseAllKeys()
            wasSaving = false
            reactionPending = false
            reactionTargetBall = nil
            currentStatus = "OFF"
        end
    elseif input.KeyCode == Enum.KeyCode.RightShift then
        screenGui.Enabled = not screenGui.Enabled
    end
end)

-- ═══════════════════════════════════════════════════════════
--  MAIN HEARTBEAT LOOP
-- ═══════════════════════════════════════════════════════════

local statusUpdateCounter = 0

RunService.Heartbeat:Connect(function()
    if not Settings.Enabled then
        statusUpdateCounter += 1
        if statusUpdateCounter % 30 == 0 then
            statusLabel.Text = "Status: OFF"
        end
        return
    end

    if not character or not character.Parent then
        character = player.Character
        if not character then return end
        humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
        humanoid = character:FindFirstChild("Humanoid")
        if not humanoidRootPart or not humanoid then return end
    end

    activeGoal = getNearestGoal()
    local ball = findActiveBall()
    local playerPos = humanoidRootPart.Position
    local now = tick()

    -- ── If we're in the reaction window, just show REACTING and wait ──
    if reactionPending then
        -- Cancel reaction if the ball is gone or no longer a threat
        if not ball or not reactionTargetBall or not reactionTargetBall.Parent
            or not isBallHeadingToGoal(reactionTargetBall.Position, reactionTargetBall.AssemblyLinearVelocity, activeGoal) then
            reactionPending = false
            reactionTargetBall = nil
        elseif (now - reactionStartTime) >= reactionDelay then
            -- Reaction window elapsed — commit to the save
            reactionPending = false
            local impact = reactionImpact
            local timeToImpact = reactionTimeToImpact

            if impact then
                currentImpactPoint = impact
                local a, d = getHorizontalMovement(impact.X, playerPos.X, activeGoal)
                setMovementKey("A", a)
                setMovementKey("D", d)

                if Settings.AutoJumpEnabled and impact.Y > Settings.JumpThreshold then
                    if timeToImpact and timeToImpact <= Settings.JumpAnticipation + 0.5 then
                        triggerJump()
                    end
                end

                lastShotTime = now
                wasSaving = true
                currentStatus = (a or d) and "SAVING" or "POSITIONED"

                if Settings.AutoJumpEnabled and impact.Y > Settings.JumpThreshold then
                    currentStatus = currentStatus .. " [JUMP Y:" .. string.format("%.1f", impact.Y) .. "]"
                end
            end
        else
            -- Still waiting out reaction time
            currentStatus = "REACTING"
            statusUpdateCounter += 1
            if statusUpdateCounter % 10 == 0 then
                statusLabel.Text = "Status: " .. currentStatus
            end
            return
        end
    end

    -- ── Normal detection ──
    if ball then
        local bPos = ball.Position
        local bVel = ball.AssemblyLinearVelocity
        local bAng = ball.AssemblyAngularVelocity

        if isBallHeadingToGoal(bPos, bVel, activeGoal) then
            local impact, timeToImpact = findGoalImpactPoint(bPos, bVel, bAng, activeGoal)
            if impact then
                -- Only start a new reaction window if this is a new threat
                if not wasSaving and not reactionPending then
                    reactionPending = true
                    reactionTargetBall = ball
                    reactionStartTime = now
                    reactionDelay = math.random(Settings.ReactionTimeMin, Settings.ReactionTimeMax) / 1000
                    reactionImpact = impact
                    reactionTimeToImpact = timeToImpact
                    currentStatus = "REACTING"
                elseif wasSaving then
                    -- Already saving — keep tracking updated impact
                    currentImpactPoint = impact
                    local a, d = getHorizontalMovement(impact.X, playerPos.X, activeGoal)
                    setMovementKey("A", a)
                    setMovementKey("D", d)

                    if Settings.AutoJumpEnabled and impact.Y > Settings.JumpThreshold then
                        if timeToImpact and timeToImpact <= Settings.JumpAnticipation + 0.5 then
                            triggerJump()
                        end
                    end

                    lastShotTime = now
                    currentStatus = (a or d) and "SAVING" or "POSITIONED"

                    if Settings.AutoJumpEnabled and impact.Y > Settings.JumpThreshold then
                        currentStatus = currentStatus .. " [JUMP Y:" .. string.format("%.1f", impact.Y) .. "]"
                    end
                end

                statusUpdateCounter += 1
                if statusUpdateCounter % 10 == 0 then
                    statusLabel.Text = "Status: " .. currentStatus
                end
                return
            end
        end
    end

    currentImpactPoint = nil

    if wasSaving and (now - lastShotTime) > Settings.ResetDelay then
        if Settings.AutoCenterEnabled then
            local a, d = getMovementToCenter(playerPos.X, activeGoal)
            setMovementKey("A", a)
            setMovementKey("D", d)
            if a or d then
                currentStatus = "RESETTING"
            else
                wasSaving = false
                releaseAllKeys()
                currentStatus = "READY"
            end
        else
            wasSaving = false
            releaseAllKeys()
            currentStatus = "READY"
        end
    elseif not wasSaving then
        if Settings.AutoCenterEnabled then
            local a, d = getMovementToCenter(playerPos.X, activeGoal)
            setMovementKey("A", a)
            setMovementKey("D", d)
            if a or d then
                currentStatus = "CENTERING"
            else
                releaseAllKeys()
                currentStatus = "READY"
            end
        else
            releaseAllKeys()
            currentStatus = "READY"
        end
    end

    statusUpdateCounter += 1
    if statusUpdateCounter % 10 == 0 then
        statusLabel.Text = "Status: " .. currentStatus
    end
end)
