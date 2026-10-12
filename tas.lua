--[[

  ▄▓▄▄    ▄    ▄▓▄▄         ▄▄▄▄    
▄▀▀███▓  ░░▓▄ ▀▀███▓     ▄▀▀▀▀█▓█▄▄▀
  ░░███▌ ░▐█▓▒ ░░███▌   ▓▄▄   ░▀▓▀  
   ░▐██▌  ██▓   ░▐██▌  ░░▀██▓▄      
    ░░░░▄░░░     ░░░▌    ░░█▀█▓▄    
    ░▒▒▒▒▒▀      ░▒▒  ▄▀   ░░░░░▌   
     ▓▓▓▀         ▓▌ ▐▓▄   ▄▒▒▒█    
    ▀▀           ▀    ▀█▓▓▓▒▒▀▀     

hi ]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")

local keybinds = {
	togglerecord = Enum.KeyCode.P,
	replay = Enum.KeyCode.L,
	checkpoint = Enum.KeyCode.F,
	returntocheckpoint = Enum.KeyCode.R,
	deletecheckpoint = Enum.KeyCode.V
}

local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()

local checkpoints = {}
local frames = {}

local recording = false
local replaying = false

local recordingTime = 0
local replayTime = 0
local replayIndex = 1

local function copyCFrame(cf)
	if not cf then
		return nil
	end

	local ok, result = pcall(function()
		local position = cf.Position
		local rotation = cf.Rotation

		if not position or not rotation then
			return nil
		end

		return CFrame.new(position) * rotation
	end)

	return ok and result or nil
end

local function copyVelocity(velocity)
	if not velocity then
		return nil
	end

	local ok, result = pcall(function()
		return velocity * 1
	end)

	return ok and result or velocity
end

local function lerpCFrame(a, b, alpha)
	if not a then
		return b
	end

	if not b then
		return a
	end

	alpha = math.max(0, math.min(1, alpha))

	local ok, result = pcall(function()
		return a:Lerp(b, alpha)
	end)

	if ok and result then
		return result
	end

	return a
end

local function setReplayCharacter(cf)
	if not cf then
		return
	end

	local ok = pcall(function()
		local rx, ry, rz = cf:ToOrientation()

		character.Position = cf.Position
		character.Orientation = Vector3.new(
			math.deg(rx),
			math.deg(ry),
			math.deg(rz)
		)
	end)

	if not ok then
		pcall(function()
			character:PivotTo(cf)
		end)
	end
end

local function createCheckpointMarker(characterCFrame)
	local marker = Instance.new("Part")

	marker.Name = "checkpoint"
	marker.Size = Vector3.new(0.35, 0.35, 0.35)
	marker.Anchored = true
	marker.CanCollide = false
	marker.Transparency = 0.5
	marker.Color = Color3.new(0, 0, 0)
	marker.CFrame = characterCFrame * CFrame.new(0, 2, 0)
	marker.Parent = Workspace

	pcall(function()
		marker.CanTouch = false
	end)

	pcall(function()
		marker.CanQuery = false
	end)

	return marker
end

local function clearCheckpointMarkers()
	for _, checkpoint in ipairs(checkpoints) do
		if checkpoint and checkpoint.marker then
			pcall(function()
				checkpoint.marker:Destroy()
			end)

			checkpoint.marker = nil
		end
	end
end

local function captureFrame()
	local ok, pivot = pcall(function()
		return character:GetPivot()
	end)

	if not ok then
		return nil
	end

	local characterCFrame = copyCFrame(pivot)

	if not characterCFrame then
		return nil
	end

	frames[#frames + 1] = {
		time = recordingTime,
		character = characterCFrame
	}

	return frames[#frames]
end

local function startRecording()
	clearCheckpointMarkers()
	table.clear(checkpoints)
	table.clear(frames)

	recording = true
	replaying = false

	recordingTime = 0
	replayTime = 0
	replayIndex = 1

	captureFrame()
end

local function stopRecording()
	recording = false

	clearCheckpointMarkers()
	table.clear(checkpoints)
end

local function createCheckpoint()
	if not recording then
		return
	end

	local ok, pivot = pcall(function()
		return character:GetPivot()
	end)

	if not ok then
		return
	end

	local characterCFrame = copyCFrame(pivot)

	if not characterCFrame then
		return
	end

	local okVelocity, velocity = pcall(function()
		return copyVelocity(character.Velocity)
	end)

	if not okVelocity then
		velocity = nil
	end

	checkpoints[#checkpoints + 1] = {
		frameIndex = #frames,
		time = recordingTime,
		character = characterCFrame,
		velocity = velocity,
		marker = createCheckpointMarker(characterCFrame)
	}
end

local function returnToCheckpoint()
	local checkpoint = checkpoints[#checkpoints]

	if not checkpoint then
		return
	end

	setReplayCharacter(checkpoint.character)

	while #frames > checkpoint.frameIndex do
		table.remove(frames)
	end

	recordingTime = checkpoint.time
	replayTime = 0
	replayIndex = 1

	if checkpoint.velocity then
		pcall(function()
			character.Velocity = copyVelocity(checkpoint.velocity)
		end)
	end
end

local function deleteCheckpoint()
	if #checkpoints == 0 then
		return
	end

	local checkpoint = checkpoints[#checkpoints]

	if checkpoint and checkpoint.marker then
		pcall(function()
			checkpoint.marker:Destroy()
		end)
	end

	table.remove(checkpoints)
end

local function startReplay()
	if #frames == 0 then
		return
	end

	recording = false
	replaying = true

	replayTime = 0
	replayIndex = 1

	setReplayCharacter(frames[1].character)
end

local function getReplayFrame()
	if #frames == 0 then
		return nil
	end

	if replayTime <= frames[1].time then
		return frames[1]
	end

	while
		replayIndex < #frames - 1
		and replayTime >= frames[replayIndex + 1].time
	do
		replayIndex += 1
	end

	local current = frames[replayIndex]
	local nextFrame = frames[replayIndex + 1]

	if not nextFrame then
		return current
	end

	local duration = nextFrame.time - current.time
	local alpha = 0

	if duration > 0 then
		alpha = (replayTime - current.time) / duration
	end

	alpha = math.max(0, math.min(1, alpha))

	return {
		character = lerpCFrame(
			current.character,
			nextFrame.character,
			alpha
		)
	}
end

local function updateReplay(dt)
	if not replaying then
		return nil
	end

	replayTime += dt

	if replayTime >= frames[#frames].time then
		replayTime = frames[#frames].time
		setReplayCharacter(frames[#frames].character)
		replaying = false

		return nil
	end

	return getReplayFrame()
end

RunService.Heartbeat:Connect(function(dt)
	if recording then
		recordingTime += dt
		captureFrame()
	end

	if replaying then
		local replayFrame = updateReplay(dt)

		if replayFrame and replayFrame.character then
			setReplayCharacter(replayFrame.character)
		end
	end
end)

UIS.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end

	if input.KeyCode == keybinds.togglerecord then
		if recording then
			stopRecording()
		else
			startRecording()
		end

	elseif input.KeyCode == keybinds.checkpoint then
		createCheckpoint()

	elseif input.KeyCode == keybinds.returntocheckpoint then
		returnToCheckpoint()

	elseif input.KeyCode == keybinds.deletecheckpoint then
		deleteCheckpoint()

	elseif input.KeyCode == keybinds.replay then
		if replaying then
			replaying = false
		else
			startReplay()
		end
	end
end)

print("yep yep good to go")
