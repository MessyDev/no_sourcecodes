-- services (the usual!!!!)
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ServerStorage = game:GetService("ServerStorage")
local HttpService = game:GetService("HttpService")
local DataStoreService = game:GetService("DataStoreService")
local ChatService = game:GetService("Chat")
local TextService = game:GetService("TextService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local PhysicsService = game:GetService("PhysicsService")
local Debris = game:GetService("Debris")

-- sexy npc template
local GhostNPC = ServerStorage:WaitForChild("GhostNPC")

-- datastore containing players' movement recordings
local MovementStore = DataStoreService:GetDataStore(require(game:GetService("ServerScriptService"):WaitForChild("DatastoreNames")).MovementStore)

-- where we store the index of ghost recordings
local GhostIndexKey = require(game:GetService("ServerScriptService"):WaitForChild("DatastoreNames")).GhostIndexKey

-- RNG
local NewRandom = Random.new()


-- makes the npc strike a pose taken directly from the ghost recording
local function applySnapshotToNPC(npc, snapshot)
	for partName, data in pairs(snapshot) do
		local part = npc:FindFirstChild(partName) :: BasePart
		if part then
			-- recreate the CFrame
			local cf = CFrame.new(data.x, data.y, data.z)
				* CFrame.Angles(data.rx or 0, data.ry or 0, data.rz or 0)

			-- tween because smoothness better
			local tween = TweenService:Create(part, TweenInfo.new(0.1), { CFrame = cf }):Play()
			Debris:AddItem(tween,0.1) -- delete the tween or memory overload
		end
	end

	--walking sound or smth
	npc.Torso.Move:Play()
end


-- ghost chats exactly like the original player (roblox pls don't ban me)
local function replayChat(npc, chatLog)
	local humanoid = npc:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	local startTime = tick()

	-- roblox filtering requires a real player... so we uh... just pick the first random victim online (i hate this)
	local filteringPlayer = Players:GetPlayers()[1]
	if not filteringPlayer then return end
	
	--im also thinking of a risk: what if the player is 18+?????? idk how to check but ill see forums

	-- run chat playback on a separate thread so we don't freeze
	coroutine.wrap(function()
		for _, chat in ipairs(chatLog) do

			-- a delay for accurate timing
			local delay = chat.time - (tick() - startTime)
			if delay > 0 then task.wait(delay) end

			if npc and npc:FindFirstChild("Head") then
				local filteredText = chat.text

				-- bless this text through the holy TextService (TextService gods pls clean the msg)
				pcall(function()
					local result = TextService:FilterStringAsync(chat.text, filteringPlayer.UserId)
					filteredText = result:GetNonChatStringForBroadcastAsync()
				end)

				-- force the NPC to talk
				ChatService:Chat(npc.Head, filteredText, Enum.ChatColor.White)

				-- broadcast to clients chat if remote (fancy way of expression)
				local remote = ReplicatedStorage:FindFirstChild("REMOTE")
				if remote then
					remote:FireAllClients("["..humanoid.DisplayName.."]: "..filteredText)
				end

				-- play the chat sound effect
				if npc.Head:FindFirstChild("chat") then
					npc.Head.chat:Play()
				end
			end
		end
	end)()
end


-- fetches all stored ghost movement keys
-- aka ":bring all"
local function getAllMovementKeys()
	local success, indexData = pcall(function()
		return MovementStore:GetAsync(GhostIndexKey)
	end)

	if success and indexData then
		-- decode if it's a JSON string (datastore loves giving me a headache)
		if typeof(indexData) == "string" then
			local parsed = HttpService:JSONDecode(indexData)
			if typeof(parsed) == "table" then
				return parsed
			end
		elseif typeof(indexData) == "table" then
			return indexData
		end
	end

	-- nothing found, damn it
	return {}
end

-- sets collision groups so ghosts don't fling players
local function applyCollisionGroup(npc, groupName)
	for _, part in npc:GetDescendants() do
		if part:IsA("BasePart") then
			part.CollisionGroup = groupName
		end
	end
end


-- the big boy function! summons ghost, do the movements, say messages, then die
local function playGhostRecording(recordingData)
	-- clone the NPC
	local npc = GhostNPC:Clone()
	npc.Parent = workspace

	-- random torso color for classification purposes
	npc["Body Colors"].TorsoColor = BrickColor.Random()

	-- give it a username
	local humanoid = npc:FindFirstChildOfClass("Humanoid")
	humanoid.DisplayName = "BOT_"..NewRandom:NextInteger(1000,9999)

	-- make sure humanoid physics doesnt get in the way
	if humanoid then humanoid:ChangeState(Enum.HumanoidStateType.Physics) end

	-- so the ghost doesn't crash into the player and reenact bumper cars
	applyCollisionGroup(npc, "PLAYERS")

	-- split recording into movement & chat logs
	local movement = recordingData.movement
	local chatLog = recordingData.chat or {}

	-- let them speak
	replayChat(npc, chatLog)

	-- act out movement
	coroutine.wrap(function()
		for _, snapshot in ipairs(movement) do
			applySnapshotToNPC(npc, snapshot)
			task.wait(0.1) -- gotta match rate speed
		end

		-- after finishing its script, the ghost get destroyed
		npc:Destroy()

		-- randomly pick ANOTHER ghost
		local keys = getAllMovementKeys()
		if #keys > 0 then
			local nextKey = keys[NewRandom:NextInteger(1, #keys)]
			local success, json = pcall(function()
				return MovementStore:GetAsync(nextKey)
			end)

			if success and json then
				local newRecording = HttpService:JSONDecode(json)
				playGhostRecording(newRecording) -- recursion
			end
		end
	end)()
end


-- after 2 second, ghosts start spawning
task.delay(2, function()
	local keys = getAllMovementKeys()
	if #keys == 0 then return end -- no ghosts = boring ass map

	-- spawn between 5 and 10 random ghosts because why not
	for i = 1, NewRandom:NextInteger(5,10) do
		local key = keys[NewRandom:NextInteger(1, #keys)]
		local success, json = pcall(function()
			return MovementStore:GetAsync(key)
		end)

		if success and json then
			local recording = HttpService:JSONDecode(json)
			playGhostRecording(recording)
		end
	end
end)
