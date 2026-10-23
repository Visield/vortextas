local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local player = game:GetService("Players").LocalPlayer

-- replace this to import stuff
local ImportData = nil

local character = player.Character

if not character then
    error("[tas] character not found")
end

local keybinds = {
    togglerecord = Enum.KeyCode.P,
    replay = Enum.KeyCode.L,
    checkpoint = Enum.KeyCode.F,
    returntocheckpoint = Enum.KeyCode.R,
    deletecheckpoint = Enum.KeyCode.V,
    pause = Enum.KeyCode.E,
    export = Enum.KeyCode.O,
}

local SETTINGS = {
    VelocitySamples = 3,
    NativeTestFrames = 3,
    MovementThreshold = 0.015,
    MaxDeltaTime = 0.1,
}

local checkpoints = {}
local frames = {}

local recording = false
local replaying = false
local paused = false
local pausedState = nil

local recordingTime = 0
local replayTime = 0
local replayIndex = 1

local previousPosition = nil
local velocitySamples = {}
local estimatedVelocity = Vector3.zero
local savedVelocity = Vector3.zero

local resumeTesting = false
local resumeFrames = 0
local resumeStartPosition = nil
local syntheticMovement = false
local pauseCFrame = nil

local playerGui = player:FindFirstChildOfClass("PlayerGui")

if not playerGui then
    playerGui = player:WaitForChild("PlayerGui")
end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "TASTextGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = playerGui

local stateLabel = Instance.new("TextLabel")
stateLabel.Name = "TASInfo"
stateLabel.AnchorPoint = Vector2.new(0, 1)
stateLabel.Position = UDim2.new(0, 10, 1, -10)
stateLabel.Size = UDim2.new(0, 300, 0, 140)
stateLabel.BackgroundTransparency = 1
stateLabel.Font = Enum.Font.Mono
stateLabel.TextSize = 14
stateLabel.TextColor3 = Color3.new(1, 1, 1)
stateLabel.TextXAlignment = Enum.TextXAlignment.Left
stateLabel.TextYAlignment = Enum.TextYAlignment.Bottom
stateLabel.TextWrapped = false
stateLabel.Parent = screenGui

local function updateGUI()
    local state

    if paused then
        state = "paused (recording)"
    elseif recording then
        state = "recording"
    elseif replaying then
        state = "replaying"
    else
        state = "idle"
    end

    stateLabel.Text =
        state .. "\n" ..
        "P = toggle record\n" ..
        "R = return to checkpoint\n" ..
        "V = delete last checkpoint\n" ..
        "F = create checkpoint\n" ..
        "E = pause/unpause (when recording)\n" ..
        "L = replay (uses ImportData if set)\n" ..
        "O = export to console"
end

local function getCFrame()
    local ok, cf = pcall(function()
        return character:GetPivot()
    end)

    if ok then
        return cf
    end

    return nil
end

local function getPosition()
    local cf = getCFrame()

    if cf then
        return cf.Position
    end

    local ok, position = pcall(function()
        return character.Position
    end)

    if ok then
        return position
    end

    return nil
end

local function setCFrame(cf)
    if not cf then
        return false
    end

    local ok = pcall(function()
        character:PivotTo(cf)
    end)

    if ok then
        return true
    end

    return pcall(function()
        character.Position = cf.Position
        character.Orientation = cf:ToOrientation()
    end)
end

local function setVelocity(velocity)
    return pcall(function()
        character.Velocity = velocity
    end)
end

local function zeroVelocity()
    setVelocity(Vector3.zero)
end

local function resetVelocitySamples(position, initialVelocity)
    previousPosition = position
    velocitySamples = {}
    estimatedVelocity = initialVelocity or Vector3.zero
end

local function addVelocitySample(velocity)
    table.insert(velocitySamples, velocity)

    while #velocitySamples > SETTINGS.VelocitySamples do
        table.remove(velocitySamples, 1)
    end

    local total = Vector3.zero

    for _, sample in ipairs(velocitySamples) do
        total = total + sample
    end

    estimatedVelocity = total / #velocitySamples
end

local function setCharacterState(state)
    if not state or not state.character then
        return
    end

    setCFrame(state.character)

    savedVelocity = state.velocity or Vector3.zero
    estimatedVelocity = savedVelocity

    setVelocity(savedVelocity)
    resetVelocitySamples(getPosition(), savedVelocity)
end

local function createMarker(cf)
    local marker = Instance.new("Part")

    marker.Name = "TASCheckpoint"
    marker.Shape = Enum.PartType.Ball
    marker.Size = Vector3.new(0.5, 0.5, 0.5)
    marker.Anchored = true
    marker.CanCollide = false
    marker.CanTouch = false
    marker.CanQuery = false
    marker.Transparency = replaying and 1 or 0.35
    marker.Position = cf.Position
    marker.Parent = Workspace

    return marker
end

local function updateMarkerVisibility(hidden)
    for _, checkpoint in ipairs(checkpoints) do
        if checkpoint.marker then
            checkpoint.marker.Transparency = hidden and 1 or 0.35
        end
    end
end

local function deleteCheckpoint(index)
    local checkpoint = checkpoints[index]

    if checkpoint then
        if checkpoint.marker then
            checkpoint.marker:Destroy()
        end

        table.remove(checkpoints, index)
    end
end

local function startRecording()
    frames = {}
    recordingTime = 0
    replayTime = 0
    replayIndex = 1

    recording = true
    replaying = false
    paused = false
    pausedState = nil
    syntheticMovement = false
    resumeTesting = false

    updateMarkerVisibility(false)

    local cf = getCFrame()
    local position = getPosition()

    if cf then
        table.insert(frames, {
            time = 0,
            character = cf,
            velocity = estimatedVelocity,
        })
    end

    resetVelocitySamples(position, estimatedVelocity)
    updateGUI()
end

local function stopRecording()
    recording = false
    paused = false
    pausedState = nil
    updateGUI()
end

local function encodeFrames(sourceFrames)
    local lines = {"local ImportData = {"}

    for _, frame in ipairs(sourceFrames) do
        local components = { frame.character:GetComponents() }
        local velocity = frame.velocity or Vector3.zero
        local values = {}

        for _, value in ipairs(components) do
            values[#values + 1] = string.format("%.9g", value)
        end

        local cfText = table.concat(values, ", ")
        local velocityText = string.format("%.9g, %.9g, %.9g", velocity.X, velocity.Y, velocity.Z)
        local timeText = string.format("%.9g", frame.time or 0)

        lines[#lines + 1] = string.format("    {time = %s, cf = {%s}, v = {%s}},", timeText, cfText, velocityText)
    end

    lines[#lines + 1] = "}"
    return table.concat(lines, "\n")
end

local function decodeFrames(data)
    if type(data) ~= "table" then
        return nil, "ImportData must be a table."
    end

    local decoded = {}

    for i, frame in ipairs(data) do
        if type(frame) ~= "table" or type(frame.time) ~= "number" then
            return nil, "Frame " .. i .. " has an invalid time or frame table."
        end
        if type(frame.cf) ~= "table" or #frame.cf ~= 12 then
            return nil, "Frame " .. i .. " must have 12 CFrame components in cf."
        end
        if type(frame.v) ~= "table" or #frame.v ~= 3 then
            return nil, "Frame " .. i .. " must have 3 velocity components in v."
        end

        local components = {}
        for j = 1, 12 do
            if type(frame.cf[j]) ~= "number" then
                return nil, "Frame " .. i .. " has a non-numeric CFrame component."
            end
            components[j] = frame.cf[j]
        end
        for j = 1, 3 do
            if type(frame.v[j]) ~= "number" then
                return nil, "Frame " .. i .. " has a non-numeric velocity component."
            end
        end

        decoded[#decoded + 1] = {
            time = frame.time,
            character = CFrame.new(table.unpack(components)),
            velocity = Vector3.new(frame.v[1], frame.v[2], frame.v[3]),
        }
    end

    if #decoded == 0 then
        return nil, "ImportData contains no frames."
    end

    return decoded
end

local function importTable()
    if ImportData == nil then
        return false
    end

    local importedFrames, err = decodeFrames(ImportData)

    if not importedFrames then
        warn("[tas] Import failed: " .. tostring(err))
        return false
    end

    frames = importedFrames
    recordingTime = frames[#frames].time or 0
    replayTime = 0
    replayIndex = 1
    print("[tas] Imported " .. #frames .. " frames from ImportData.")
    return true
end

local function exportTAS()
    if recording then
        return
    end

    if #frames == 0 then
        warn("[tas] Nothing to export.")
        return
    end

    local ok, encoded = pcall(function()
        return encodeFrames(frames)
    end)

    if not ok then
        warn("[tas] Export failed: " .. tostring(encoded))
        return
    end

    print(encoded)
end

local function startReplay()
    if ImportData ~= nil then
        if not importTable() then
            return
        end
    end
    if #frames == 0 then
        return
    end

    recording = false
    replaying = true
    paused = false
    pausedState = nil

    replayTime = 0
    replayIndex = 1
    resumeTesting = false
    syntheticMovement = false

    updateMarkerVisibility(true)

    setCFrame(frames[1].character)

    savedVelocity = frames[1].velocity or Vector3.zero
    setVelocity(savedVelocity)

    resetVelocitySamples(getPosition(), savedVelocity)
    updateGUI()
end

local function stopReplay()
    replaying = false
    syntheticMovement = false
    resumeTesting = false

    updateMarkerVisibility(false)
    updateGUI()
end

local function placeCheckpoint()
    local cf = getCFrame()

    if not cf then
        return
    end

    table.insert(checkpoints, {
        character = cf,
        velocity = estimatedVelocity,
        frameIndex = #frames,
        time = recordingTime,
        marker = createMarker(cf),
    })
end

local function returnToCheckpoint()
    if #checkpoints == 0 then
        return
    end

    local checkpoint = checkpoints[#checkpoints]

    replaying = false
    paused = false
    pausedState = nil
    resumeTesting = false
    syntheticMovement = false

    updateMarkerVisibility(false)

    setCharacterState({
        character = checkpoint.character,
        velocity = checkpoint.velocity,
    })

    while #frames > checkpoint.frameIndex do
        table.remove(frames)
    end

    recordingTime = checkpoint.time
    replayTime = 0
    replayIndex = 1

    resetVelocitySamples(
        getPosition(),
        checkpoint.velocity or Vector3.zero
    )

    savedVelocity = checkpoint.velocity or Vector3.zero
    setVelocity(savedVelocity)

    updateGUI()
end

local function removeCheckpoint()
    if #checkpoints == 0 then
        return
    end

    deleteCheckpoint(#checkpoints)
end

local function pauseTAS()
    if not recording or replaying then
        return
    end

    local cf = getCFrame()
    local position = getPosition()

    if not cf or not position then
        return
    end

    savedVelocity = estimatedVelocity

    pauseCFrame = cf
    pausedState = {
        character = cf,
        velocity = savedVelocity,
    }

    paused = true
    resumeTesting = false
    syntheticMovement = false

    zeroVelocity()
    resetVelocitySamples(position, savedVelocity)
    updateGUI()
end

local function resumeTAS()
    if not paused then
        return
    end

    paused = false

    local state = pausedState
    pausedState = nil

    if state then
        setCFrame(state.character)
        savedVelocity = state.velocity or Vector3.zero
        setVelocity(savedVelocity)
    end

    local position = getPosition()
    resetVelocitySamples(position, savedVelocity)

    resumeTesting = true
    resumeFrames = 0
    resumeStartPosition = position

    updateGUI()
end

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then
        return
    end

    if input.KeyCode == keybinds.pause then
        if paused then
            resumeTAS()
        else
            pauseTAS()
        end

        return
    end

    if paused then
        return
    end

    if input.KeyCode == keybinds.togglerecord then
        if recording then
            stopRecording()
        else
            startRecording()
        end

    elseif input.KeyCode == keybinds.replay then
        if replaying then
            stopReplay()
        else
            startReplay()
        end

    elseif input.KeyCode == keybinds.checkpoint then
        placeCheckpoint()

    elseif input.KeyCode == keybinds.returntocheckpoint then
        returnToCheckpoint()

    elseif input.KeyCode == keybinds.deletecheckpoint then
        removeCheckpoint()
    elseif input.KeyCode == keybinds.export then
        if not recording then
            exportTAS()
        end
    end
end)

RunService.Heartbeat:Connect(function(dt)
    if not dt or dt <= 0 then
        return
    end

    local position = getPosition()

    if not position then
        return
    end

    if paused then
        if pauseCFrame then
            setCFrame(pauseCFrame)
        end

        zeroVelocity()
        previousPosition = getPosition()
        return
    end

    if replaying then
        replayTime = replayTime + dt

        while replayIndex < #frames
            and frames[replayIndex + 1].time <= replayTime do
            replayIndex = replayIndex + 1
        end

        local frame = frames[replayIndex]

        if frame then
            setCFrame(frame.character)

            savedVelocity = frame.velocity or Vector3.zero
            setVelocity(savedVelocity)

            resetVelocitySamples(
                getPosition(),
                savedVelocity
            )
        end

        if replayIndex >= #frames then
            stopReplay()
        end

        return
    end

    if resumeTesting then
        resumeFrames = resumeFrames + 1

        local displacement = Vector3.zero

        if resumeStartPosition then
            displacement = position - resumeStartPosition
        end

        if displacement.Magnitude >= SETTINGS.MovementThreshold then
            resumeTesting = false
            resetVelocitySamples(position, savedVelocity)

        elseif resumeFrames >= SETTINGS.NativeTestFrames then
            resumeTesting = false
            syntheticMovement = true
            resetVelocitySamples(position, savedVelocity)

        else
            setVelocity(savedVelocity)
            previousPosition = position
            return
        end
    end

    if syntheticMovement then
        local step = math.min(dt, SETTINGS.MaxDeltaTime)
        local cf = getCFrame()

        if cf then
            setCFrame(cf + savedVelocity * step)
            setVelocity(savedVelocity)
        end

        previousPosition = getPosition()

        if recording then
            recordingTime = recordingTime + dt

            local currentCF = getCFrame()

            if currentCF then
                table.insert(frames, {
                    time = recordingTime,
                    character = currentCF,
                    velocity = savedVelocity,
                })
            end
        end

        return
    end

    if previousPosition then
        local step = math.min(dt, SETTINGS.MaxDeltaTime)

        if step > 0 then
            local displacement = position - previousPosition
            local measuredVelocity = displacement / step

            addVelocitySample(measuredVelocity)
        end
    end

    previousPosition = position
    savedVelocity = estimatedVelocity


    if recording then
        recordingTime = recordingTime + dt

        local cf = getCFrame()

        if cf then
            table.insert(frames, {
                time = recordingTime,
                character = cf,
                velocity = estimatedVelocity,
            })
        end
    end
end)

resetVelocitySamples(getPosition())
updateGUI()
