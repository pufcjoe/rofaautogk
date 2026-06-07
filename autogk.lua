-- Auto-GK • Dollarware UI
-- loadstring(game:HttpGet("YOUR_GIST_RAW_URL_HERE"))()

-- ═══════════════════════════════════════════════════════════
--  SERVICES & PLAYER
-- ═══════════════════════════════════════════════════════════

local Players             = game:GetService("Players")
local RunService          = game:GetService("RunService")
local UserInputService    = game:GetService("UserInputService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local Workspace           = game:GetService("Workspace")

local player        = Players.LocalPlayer
local character     = player.Character or player.CharacterAdded:Wait()
local humanoidRootPart = character:WaitForChild("HumanoidRootPart")
local humanoid      = character:WaitForChild("Humanoid")

-- ═══════════════════════════════════════════════════════════
--  SETTINGS
-- ═══════════════════════════════════════════════════════════

local Settings = {
    Enabled          = false,
    PredictionTime   = 5,
    MinBallSpeed     = 50,
    CatchTolerance   = 1,
    CenterTolerance  = 1.5,
    ResetDelay       = 0.5,
    ShootingDistance = 250,
    SimulationStep   = 5,
    ReactionTimeMin  = 150,
    ReactionTimeMax  = 200,
    AutoJumpEnabled  = false,
    JumpThreshold    = 7,
    JumpCooldown     = 1.5,
    JumpAnticipation = 0.3,
    AwayGoalPosX=0,  AwayGoalPosY=5.3,  AwayGoalPosZ=350.8,
    AwayGoalSizeX=6.4, AwayGoalSizeY=9.6, AwayGoalSizeZ=27.4,
    HomeGoalPosX=0,  HomeGoalPosY=5.3,  HomeGoalPosZ=-350.8,
    HomeGoalSizeX=6.4, HomeGoalSizeY=9.6, HomeGoalSizeZ=27.4,
    CustomGravity=100, AirDensity=10, AirFriction=7,
    AngularFriction=40, CurvePower=125, MinVelForCurve=95,
    AutoCenterEnabled = false,
}

local Keybinds = {
    ToggleGK = Enum.KeyCode.RightBracket,
    ToggleUI = Enum.KeyCode.RightShift,
}

-- ═══════════════════════════════════════════════════════════
--  GOALS
-- ═══════════════════════════════════════════════════════════

local AWAY_GOAL, HOME_GOAL

local function rebuildGoals()
    AWAY_GOAL = {
        Position = Vector3.new(Settings.AwayGoalPosX, Settings.AwayGoalPosY, Settings.AwayGoalPosZ),
        Size     = Vector3.new(Settings.AwayGoalSizeX, Settings.AwayGoalSizeY, Settings.AwayGoalSizeZ),
        FrontZ   = Settings.AwayGoalPosZ - (Settings.AwayGoalSizeX / 2),
        CenterX  = Settings.AwayGoalPosX,
    }
    HOME_GOAL = {
        Position = Vector3.new(Settings.HomeGoalPosX, Settings.HomeGoalPosY, Settings.HomeGoalPosZ),
        Size     = Vector3.new(Settings.HomeGoalSizeX, Settings.HomeGoalSizeY, Settings.HomeGoalSizeZ),
        FrontZ   = Settings.HomeGoalPosZ + (Settings.HomeGoalSizeX / 2),
        CenterX  = Settings.HomeGoalPosX,
    }
end
rebuildGoals()

-- ═══════════════════════════════════════════════════════════
--  STATE
-- ═══════════════════════════════════════════════════════════

local activeGoal    = nil
local lastShotTime  = 0
local lastJumpTime  = 0
local wasSaving     = false
local currentStatus = "OFF"
local currentKeys   = { A = false, D = false }

local reactionPending = false
local reactionBall    = nil
local reactionEnd     = 0
local committedImpact = nil

-- ═══════════════════════════════════════════════════════════
--  VIRTUAL INPUT
-- ═══════════════════════════════════════════════════════════

local function pressKey(kc)   VirtualInputManager:SendKeyEvent(true,  kc, false, game) end
local function releaseKey(kc) VirtualInputManager:SendKeyEvent(false, kc, false, game) end

local function setMovementKey(key, state)
    local kc = key == "A" and Enum.KeyCode.A or Enum.KeyCode.D
    if currentKeys[key] ~= state then
        currentKeys[key] = state
        if state then pressKey(kc) else releaseKey(kc) end
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
        task.delay(0.1, function() releaseKey(Enum.KeyCode.Space) end)
    end
end

-- ═══════════════════════════════════════════════════════════
--  GOALKEEPER LOGIC
-- ═══════════════════════════════════════════════════════════

local function getRealPhysics()
    return {
        gravity         = Settings.CustomGravity,
        airDensity      = Settings.AirDensity / 100,
        airFriction     = Settings.AirFriction / 1000,
        angularFriction = Settings.AngularFriction / 1000,
        curvePower      = Settings.CurvePower,
        minVelForCurve  = Settings.MinVelForCurve,
        simStep         = Settings.SimulationStep / 1000,
    }
end

local function getNearestGoal()
    if not humanoidRootPart then return AWAY_GOAL end
    local pos = humanoidRootPart.Position
    local dA  = math.abs(pos.Z - AWAY_GOAL.Position.Z)
    local dH  = math.abs(pos.Z - HOME_GOAL.Position.Z)
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
            if speed > highestSpeed then highestSpeed = speed; bestBall = obj end
        end
    end
    return bestBall
end

local function simulateBallPhysicsStep(pos, vel, angularVel, dt, phys)
    local speed        = vel.Magnitude
    local gravityForce = Vector3.new(0, -phys.gravity, 0)
    local dragForce    = Vector3.zero
    if speed > 0.1 then
        dragForce = -vel.Unit * (phys.airFriction * speed * speed * phys.airDensity)
    end
    local curveForce = Vector3.zero
    if speed > phys.minVelForCurve and angularVel.Magnitude > 0.1 then
        curveForce = angularVel:Cross(vel) * (phys.curvePower / 10000)
    end
    local totalAccel = gravityForce + dragForce + curveForce
    local newVel     = vel + totalAccel * dt
    return pos + newVel * dt, newVel, angularVel * (1 - phys.angularFriction * dt)
end

local function isBallHeadingToGoal(ballPos, ballVel, goal)
    local goalZ  = goal.Position.Z
    local frontZ = goal.FrontZ
    if goalZ > 0 then
        if ballVel.Z <= 0 or ballPos.Z > frontZ then return false end
    else
        if ballVel.Z >= 0 or ballPos.Z < frontZ then return false end
    end
    return math.abs(ballPos.Z - frontZ) <= Settings.ShootingDistance
end

local function findGoalImpactPoint(startPos, startVel, startAngularVel, goal)
    local phys       = getRealPhysics()
    local pos, vel   = startPos, startVel
    local angularVel = startAngularVel or Vector3.zero
    local t, dt      = 0, phys.simStep
    local frontZ     = goal.FrontZ
    local halfW      = goal.Size.Z / 2

    while t < Settings.PredictionTime do
        local lastPos = pos
        pos, vel, angularVel = simulateBallPhysicsStep(pos, vel, angularVel, dt, phys)
        t += dt
        local crossed = goal.Position.Z > 0
            and (lastPos.Z < frontZ and pos.Z >= frontZ)
            or  (lastPos.Z > frontZ and pos.Z <= frontZ)
        if crossed then
            local ratio     = (frontZ - lastPos.Z) / (pos.Z - lastPos.Z)
            local intersect = lastPos:Lerp(pos, ratio)
            local finalY    = math.max(intersect.Y, 0.5)
            if math.abs(intersect.X) <= halfW + 5 then
                return Vector3.new(intersect.X, finalY, frontZ), t
            end
            return nil, nil
        end
        if pos.Y < 0.5 then
            if math.abs(vel.Z) > 1 then
                local ttg = (frontZ - pos.Z) / vel.Z
                if ttg > 0 and ttg < 5 then
                    local gi = Vector3.new(pos.X + vel.X * ttg, 0.5, frontZ)
                    if math.abs(gi.X) <= halfW + 5 then return gi, t + ttg end
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
    if goal.Position.Z > 0 then return diff < 0, diff > 0
    else                        return diff > 0, diff < 0 end
end

local function getMovementToCenter(playerX, goal)
    local diff = goal.CenterX - playerX
    if math.abs(diff) < Settings.CenterTolerance then return false, false end
    if goal.Position.Z > 0 then return diff < 0, diff > 0
    else                        return diff > 0, diff < 0 end
end

-- ═══════════════════════════════════════════════════════════
--  CHARACTER RESPAWN
-- ═══════════════════════════════════════════════════════════

local function fullReset()
    releaseAllKeys()
    wasSaving       = false
    reactionPending = false
    reactionBall    = nil
    committedImpact = nil
    currentStatus   = "OFF"
end

player.CharacterAdded:Connect(function(newChar)
    character        = newChar
    humanoidRootPart = character:WaitForChild("HumanoidRootPart")
    humanoid         = character:WaitForChild("Humanoid")
    fullReset()
end)

-- ═══════════════════════════════════════════════════════════
--  DOLLARWARE UI
-- ═══════════════════════════════════════════════════════════

local ui = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/topitbopit/dollarware/main/library.lua"
))()

local win = ui.newWindow({
    text     = "Auto-GK",
    size     = Vector2.new(500, 370),
    position = UDim2.fromScale(0.3, 0.25),
    resize   = false,
})

local pageMain     = win:addMenu({ text = "Main"      })
local pageBehav    = win:addMenu({ text = "Behaviour" })
local pageReaction = win:addMenu({ text = "Reaction"  })
local pageJump     = win:addMenu({ text = "Jump"      })
local pageGoals    = win:addMenu({ text = "Goals"     })
local pagePhysics  = win:addMenu({ text = "Physics"   })
local pageKeys     = win:addMenu({ text = "Keybinds"  })

local function keyName(kc)
    local s = tostring(kc)
    return s:match("KeyCode%.(.+)") or s
end

-- ═══════════════════════════════════════════════════════════
--  MAIN PAGE
-- ═══════════════════════════════════════════════════════════

local secControl = pageMain:addSection({ text = "Control", side = "left"  })
local secStatus  = pageMain:addSection({ text = "Status",  side = "right" })

local enableToggle = secControl:addToggle({ text = "Auto-GK Enabled", state = false }, function(v)
    Settings.Enabled = v
    if not v then fullReset() end
end)

local statusLabel = secStatus:addLabel({ text = "○ OFF", dim = false })

-- ═══════════════════════════════════════════════════════════
--  BEHAVIOUR PAGE
-- ═══════════════════════════════════════════════════════════

local secDetect = pageBehav:addSection({ text = "Detection",   side = "left"  })
local secPos    = pageBehav:addSection({ text = "Positioning", side = "right" })

secDetect:addSlider({ text = "Min Ball Speed",      min=1,  max=300, step=1,   value=Settings.MinBallSpeed     }, function(v) Settings.MinBallSpeed     = v end)
secDetect:addSlider({ text = "Shoot Distance",      min=50, max=600, step=10,  value=Settings.ShootingDistance }, function(v) Settings.ShootingDistance = v end)
secDetect:addSlider({ text = "Prediction Time (s)", min=1,  max=15,  step=0.5, value=Settings.PredictionTime   }, function(v) Settings.PredictionTime   = v end)
secDetect:addSlider({ text = "Sim Step (x1000)",    min=1,  max=20,  step=1,   value=Settings.SimulationStep   }, function(v) Settings.SimulationStep   = v end)

secPos:addSlider({ text = "Catch Tolerance",  min=0, max=10, step=0.1, value=Settings.CatchTolerance  }, function(v) Settings.CatchTolerance  = v end)
secPos:addSlider({ text = "Center Tolerance", min=0, max=10, step=0.1, value=Settings.CenterTolerance }, function(v) Settings.CenterTolerance = v end)
secPos:addSlider({ text = "Reset Delay (s)",  min=0, max=5,  step=0.1, value=Settings.ResetDelay      }, function(v) Settings.ResetDelay      = v end)
secPos:addToggle({ text = "Auto-Center", state = false }, function(v) Settings.AutoCenterEnabled = v end)

-- ═══════════════════════════════════════════════════════════
--  REACTION PAGE
-- ═══════════════════════════════════════════════════════════

local secReact = pageReaction:addSection({ text = "Reaction Time", side = "left" })

secReact:addLabel({ text = "Delay before GK reacts (ms)", dim = true })
secReact:addSlider({ text = "Min Reaction (ms)", min=0, max=500, step=5, value=Settings.ReactionTimeMin }, function(v)
    Settings.ReactionTimeMin = math.min(v, Settings.ReactionTimeMax)
end)
secReact:addSlider({ text = "Max Reaction (ms)", min=0, max=500, step=5, value=Settings.ReactionTimeMax }, function(v)
    Settings.ReactionTimeMax = math.max(v, Settings.ReactionTimeMin)
end)

-- ═══════════════════════════════════════════════════════════
--  JUMP PAGE
-- ═══════════════════════════════════════════════════════════

local secJump = pageJump:addSection({ text = "Auto-Jump", side = "left" })

secJump:addToggle({ text = "Enable Auto-Jump",   state = false }, function(v) Settings.AutoJumpEnabled  = v end)
secJump:addSlider({ text = "Jump Threshold (Y)", min=0, max=30, step=0.5,  value=Settings.JumpThreshold    }, function(v) Settings.JumpThreshold    = v end)
secJump:addSlider({ text = "Jump Cooldown (s)",  min=0, max=5,  step=0.1,  value=Settings.JumpCooldown     }, function(v) Settings.JumpCooldown     = v end)
secJump:addSlider({ text = "Anticipation (s)",   min=0, max=2,  step=0.05, value=Settings.JumpAnticipation }, function(v) Settings.JumpAnticipation = v end)

-- ═══════════════════════════════════════════════════════════
--  GOALS PAGE
-- ═══════════════════════════════════════════════════════════

local secAway = pageGoals:addSection({ text = "Away Goal", side = "left"  })
local secHome = pageGoals:addSection({ text = "Home Goal", side = "right" })

secAway:addSlider({ text = "Pos X", min=-50, max=50,  step=0.1, value=Settings.AwayGoalPosX  }, function(v) Settings.AwayGoalPosX  = v rebuildGoals() end)
secAway:addSlider({ text = "Pos Y", min=0,   max=30,  step=0.1, value=Settings.AwayGoalPosY  }, function(v) Settings.AwayGoalPosY  = v rebuildGoals() end)
secAway:addSlider({ text = "Pos Z", min=100, max=600, step=0.5, value=Settings.AwayGoalPosZ  }, function(v) Settings.AwayGoalPosZ  = v rebuildGoals() end)
secAway:addSlider({ text = "Width", min=5,   max=60,  step=0.1, value=Settings.AwayGoalSizeZ }, function(v) Settings.AwayGoalSizeZ = v rebuildGoals() end)
secAway:addSlider({ text = "Height",min=3,   max=30,  step=0.1, value=Settings.AwayGoalSizeY }, function(v) Settings.AwayGoalSizeY = v rebuildGoals() end)
secAway:addSlider({ text = "Depth", min=1,   max=20,  step=0.1, value=Settings.AwayGoalSizeX }, function(v) Settings.AwayGoalSizeX = v rebuildGoals() end)

secHome:addSlider({ text = "Pos X", min=-50,  max=50,   step=0.1, value=Settings.HomeGoalPosX  }, function(v) Settings.HomeGoalPosX  = v rebuildGoals() end)
secHome:addSlider({ text = "Pos Y", min=0,    max=30,   step=0.1, value=Settings.HomeGoalPosY  }, function(v) Settings.HomeGoalPosY  = v rebuildGoals() end)
secHome:addSlider({ text = "Pos Z", min=-600, max=-100, step=0.5, value=Settings.HomeGoalPosZ  }, function(v) Settings.HomeGoalPosZ  = v rebuildGoals() end)
secHome:addSlider({ text = "Width", min=5,    max=60,   step=0.1, value=Settings.HomeGoalSizeZ }, function(v) Settings.HomeGoalSizeZ = v rebuildGoals() end)
secHome:addSlider({ text = "Height",min=3,    max=30,   step=0.1, value=Settings.HomeGoalSizeY }, function(v) Settings.HomeGoalSizeY = v rebuildGoals() end)
secHome:addSlider({ text = "Depth", min=1,    max=20,   step=0.1, value=Settings.HomeGoalSizeX }, function(v) Settings.HomeGoalSizeX = v rebuildGoals() end)

-- ═══════════════════════════════════════════════════════════
--  PHYSICS PAGE
-- ═══════════════════════════════════════════════════════════

local secPhysL = pagePhysics:addSection({ text = "Forces",    side = "left"  })
local secPhysR = pagePhysics:addSection({ text = "Curveball", side = "right" })

secPhysL:addSlider({ text = "Custom Gravity",       min=0, max=300, step=1, value=Settings.CustomGravity   }, function(v) Settings.CustomGravity   = v end)
secPhysL:addSlider({ text = "Air Density (x100)",   min=0, max=100, step=1, value=Settings.AirDensity      }, function(v) Settings.AirDensity      = v end)
secPhysL:addSlider({ text = "Air Friction (x1000)", min=0, max=50,  step=1, value=Settings.AirFriction     }, function(v) Settings.AirFriction     = v end)
secPhysL:addSlider({ text = "Ang Friction (x1000)", min=0, max=100, step=1, value=Settings.AngularFriction }, function(v) Settings.AngularFriction = v end)

secPhysR:addSlider({ text = "Curve Power",     min=0, max=500, step=5, value=Settings.CurvePower     }, function(v) Settings.CurvePower     = v end)
secPhysR:addSlider({ text = "Min Vel (Curve)", min=0, max=300, step=5, value=Settings.MinVelForCurve }, function(v) Settings.MinVelForCurve = v end)

-- ═══════════════════════════════════════════════════════════
--  KEYBINDS PAGE
-- ═══════════════════════════════════════════════════════════

local secKeybinds = pageKeys:addSection({ text = "Hotkeys", side = "left" })
secKeybinds:addLabel({ text = "Click a button to rebind it", dim = true })

local listeningFor = nil

local function makeKeybindButton(section, label, bindKey)
    local btn = section:addButton({
        text  = label .. "  [" .. keyName(Keybinds[bindKey]) .. "]",
        style = "large",
    })

    btn:bindToEvent("onClick", function()
        if listeningFor then return end
        listeningFor = bindKey

        btn.instances.label.Text       = label .. "  [press a key...]"
        btn.instances.label.TextColor3 = Color3.fromRGB(38, 233, 195)

        local conn
        conn = UserInputService.InputBegan:Connect(function(input, gp)
            if gp then return end
            if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
            conn:Disconnect()
            Keybinds[bindKey]              = input.KeyCode
            listeningFor                   = nil
            btn.instances.label.Text       = label .. "  [" .. keyName(input.KeyCode) .. "]"
            btn.instances.label.TextColor3 = Color3.fromRGB(255, 255, 255)
        end)
    end)

    return btn
end

makeKeybindButton(secKeybinds, "Toggle Auto-GK", "ToggleGK")
makeKeybindButton(secKeybinds, "Toggle UI",      "ToggleUI")

-- ═══════════════════════════════════════════════════════════
--  GLOBAL KEYBIND HANDLER
-- ═══════════════════════════════════════════════════════════

-- Find the Dollarware ScreenGui specifically by looking for its
-- root frame named '#main_frame', avoiding Roblox's own CoreGui ScreenGuis
local function getLibGui()
    for _, v in ipairs(game:GetService("CoreGui"):GetChildren()) do
        if v:IsA("ScreenGui") and v:FindFirstChild("#main_frame", true) then
            return v
        end
    end
end

UserInputService.InputBegan:Connect(function(input, gp)
    if gp then return end
    if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
    if listeningFor then return end

    if input.KeyCode == Keybinds.ToggleGK then
        Settings.Enabled = not Settings.Enabled
        if Settings.Enabled then
            enableToggle:enable()
        else
            enableToggle:disable()
            fullReset()
        end

    elseif input.KeyCode == Keybinds.ToggleUI then
        local g = getLibGui()
        if g then g.Enabled = not g.Enabled end
    end
end)

-- ═══════════════════════════════════════════════════════════
--  STATUS HELPER
-- ═══════════════════════════════════════════════════════════

local statusDots = {
    OFF        = "○",
    READY      = "●",
    REACTING   = "◎",
    SAVING     = "◉",
    POSITIONED = "◉",
    RESETTING  = "◎",
    CENTERING  = "◎",
}

local function setStatus(key)
    currentStatus = key
    statusLabel:setText((statusDots[key] or "●") .. " " .. key)
end

-- ═══════════════════════════════════════════════════════════
--  MAIN HEARTBEAT LOOP
-- ═══════════════════════════════════════════════════════════

local ticker = 0

RunService.Heartbeat:Connect(function()
    ticker += 1

    if not Settings.Enabled then
        if ticker % 30 == 0 then setStatus("OFF") end
        return
    end

    if not character or not character.Parent then
        character        = player.Character
        if not character then return end
        humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
        humanoid         = character:FindFirstChild("Humanoid")
        if not humanoidRootPart or not humanoid then return end
    end

    activeGoal = getNearestGoal()
    local ball      = findActiveBall()
    local playerPos = humanoidRootPart.Position
    local now       = tick()

    -- ── REACTION WINDOW ───────────────────────────────────
    if reactionPending then
        local stillValid = reactionBall
            and reactionBall.Parent
            and reactionBall.AssemblyLinearVelocity.Magnitude >= Settings.MinBallSpeed
            and isBallHeadingToGoal(reactionBall.Position, reactionBall.AssemblyLinearVelocity, activeGoal)

        if not stillValid then
            reactionPending = false
            reactionBall    = nil
            committedImpact = nil
            releaseAllKeys()
            wasSaving = false
            if ticker % 10 == 0 then setStatus("READY") end
        elseif now >= reactionEnd then
            reactionPending = false
            local impact, timeToImpact = findGoalImpactPoint(
                reactionBall.Position,
                reactionBall.AssemblyLinearVelocity,
                reactionBall.AssemblyAngularVelocity,
                activeGoal)

            if impact then
                committedImpact = impact
                local a, d = getHorizontalMovement(impact.X, playerPos.X, activeGoal)
                setMovementKey("A", a)
                setMovementKey("D", d)
                if Settings.AutoJumpEnabled and impact.Y > Settings.JumpThreshold then
                    if timeToImpact and timeToImpact <= Settings.JumpAnticipation + 0.5 then
                        triggerJump()
                    end
                end
                lastShotTime = now
                wasSaving    = true
                if ticker % 10 == 0 then setStatus((a or d) and "SAVING" or "POSITIONED") end
            else
                releaseAllKeys()
                wasSaving = false
                if ticker % 10 == 0 then setStatus("READY") end
            end
            reactionBall = nil
        else
            if ticker % 10 == 0 then setStatus("REACTING") end
            return
        end
    end

    -- ── DETECTION ─────────────────────────────────────────
    if ball then
        local bPos = ball.Position
        local bVel = ball.AssemblyLinearVelocity
        local bAng = ball.AssemblyAngularVelocity

        if isBallHeadingToGoal(bPos, bVel, activeGoal) then
            if not wasSaving and not reactionPending then
                reactionPending = true
                reactionBall    = ball
                reactionEnd     = now + math.random(Settings.ReactionTimeMin, Settings.ReactionTimeMax) / 1000
                if ticker % 10 == 0 then setStatus("REACTING") end
                return

            elseif wasSaving and committedImpact then
                local a, d = getHorizontalMovement(committedImpact.X, playerPos.X, activeGoal)
                setMovementKey("A", a)
                setMovementKey("D", d)
                if Settings.AutoJumpEnabled and committedImpact.Y > Settings.JumpThreshold then
                    local _, tti = findGoalImpactPoint(bPos, bVel, bAng, activeGoal)
                    if tti and tti <= Settings.JumpAnticipation + 0.5 then triggerJump() end
                end
                lastShotTime = now
                if ticker % 10 == 0 then setStatus((a or d) and "SAVING" or "POSITIONED") end
                return
            end
        end
    end

    -- ── IDLE / RESET ──────────────────────────────────────
    committedImpact = nil

    if wasSaving and (now - lastShotTime) > Settings.ResetDelay then
        if Settings.AutoCenterEnabled then
            local a, d = getMovementToCenter(playerPos.X, activeGoal)
            setMovementKey("A", a)
            setMovementKey("D", d)
            if a or d then
                if ticker % 10 == 0 then setStatus("RESETTING") end
            else
                wasSaving = false; releaseAllKeys()
                if ticker % 10 == 0 then setStatus("READY") end
            end
        else
            wasSaving = false; releaseAllKeys()
            if ticker % 10 == 0 then setStatus("READY") end
        end
    elseif not wasSaving then
        if Settings.AutoCenterEnabled then
            local a, d = getMovementToCenter(playerPos.X, activeGoal)
            setMovementKey("A", a)
            setMovementKey("D", d)
            if ticker % 10 == 0 then setStatus((a or d) and "CENTERING" or "READY") end
        else
            releaseAllKeys()
            if ticker % 10 == 0 then setStatus("READY") end
        end
    end
end)
