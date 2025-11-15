--[[
SCRIPT MADE BY GREEN

SUMMARY: Records player movement as compressed snapshots, logs and moderates chat messages using a local bad-word list and an external AI moderation API, then saves both movement and chat into a datastore as a ghost replay when the player leaves. Other players can later see "ghost replays" of past players.

NOTE: 4th Attempt for HiddenDevs Application. This version:
- Uses early returns and flat functions instead of deep nesting.
- Adds more comments for clarity.
- Fixes all undefined function calls and return-value mismatches.
- Ensures a single, self-contained server script with >200 lines of Luau code (excluding comments/blank lines).
]]

--<SPLIT>
-- SERVICES: single place to grab Roblox services used in this script
--<SPLIT>
local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local TextService = game:GetService("TextService")
local ServerScriptService = game:GetService("ServerScriptService")
local PhysicsService = game:GetService("PhysicsService")

--<SPLIT>
-- DATASTORES & CONSTANTS: configuration values and keys
--<SPLIT>
local DatastoreNames = require(ServerScriptService:WaitForChild("DatastoreNames"))
local BadWords = require(script:WaitForChild("BadWords"))

local MovementStore = DataStoreService:GetDataStore(DatastoreNames.MovementStore)
local GhostIndexKey = DatastoreNames.GhostIndexKey
local GhostCounterKey = DatastoreNames.GhostCounterKey

local RecordRate = 0.1
local PLAYER_COLLISION_GROUP = "PLAYERS"

local BotEndPoint = "https://gemini-api-n7dt.onrender.com"

--<SPLIT>
-- STATE CONTAINERS: in-memory tables to keep track of runtime data
--<SPLIT>
local ChatLogs = {}
local PlayerChatBuffer = {}
local ChatQueue = {}
local IsProcessingChat = false

--<SPLIT>
-- UTILITY: math helper functions and simple reusable logic
--<SPLIT>
local function round(numberValue, decimals)
	local precision = 10 ^ decimals
	local scaled = numberValue * precision
	local rounded = math.floor(scaled + 0.5)
	local result = rounded / precision
	return result
end

local function compressCFrame(cf)
	local position = cf.Position
	local rx, ry, rz = cf:ToEulerAnglesXYZ()

	local packed = {}
	packed.x = round(position.X, 2)
	packed.y = round(position.Y, 2)
	packed.z = round(position.Z, 2)
	packed.rx = round(rx, 3)
	packed.ry = round(ry, 3)
	packed.rz = round(rz, 3)

	return packed
end

local function ensurePlayerCollisionGroup()
	local ok, groups = pcall(function()
		return PhysicsService:GetCollisionGroups()
	end)

	if not ok or not groups then
		return
	end

	for _, group in ipairs(groups) do
		if group.name == PLAYER_COLLISION_GROUP then
			PhysicsService:CollisionGroupSetCollidable(PLAYER_COLLISION_GROUP, PLAYER_COLLISION_GROUP, false)
			return
		end
	end

	local created = pcall(function()
		PhysicsService:CreateCollisionGroup(PLAYER_COLLISION_GROUP)
	end)

	if created then
		PhysicsService:CollisionGroupSetCollidable(PLAYER_COLLISION_GROUP, PLAYER_COLLISION_GROUP, false)
	end
end

ensurePlayerCollisionGroup()

local function isMessageBanned(msg)
	if not msg or msg == "" then
		return false
	end

	local normalized = string.lower(msg)

	for _, word in ipairs(BadWords) do
		if normalized == word then
			return true
		end
	end

	return false
end

local function ensurePlayerLogTable(player)
	local logs = ChatLogs[player]

	if logs then
		return logs
	end

	logs = {}
	ChatLogs[player] = logs
	return logs
end

local function ensurePlayerBufferTable(player)
	local buffer = PlayerChatBuffer[player]

	if buffer then
		return buffer
	end

	buffer = {}
	PlayerChatBuffer[player] = buffer
	return buffer
end

--<SPLIT>
-- CHAT BUFFER: keep short rolling buffer for recent messages
--<SPLIT>
local function trimBufferToSize(buffer, maxSize)
	while #buffer > maxSize do
		table.remove(buffer, 1)
	end
end

local function appendToPlayerBuffer(player, filteredMessage)
	if filteredMessage == "" then
		return
	end

	local buffer = ensurePlayerBufferTable(player)
	table.insert(buffer, filteredMessage)

	local maxSize = 5
	trimBufferToSize(buffer, maxSize)
end

--<SPLIT>
-- MODERATION PROMPT BUILDING: construct full chat history prompt for AI
--<SPLIT>
local function appendAllChatLogsToPrompt(lines)
	table.insert(lines, "All Chat Logs:")

	for player, logs in pairs(ChatLogs) do
		local playerName = "UnknownPlayer"

		if player and player.Name then
			playerName = player.Name
		end

		for _, log in ipairs(logs) do
			local line = string.format("[%s]: %s", playerName, log.text)
			table.insert(lines, line)
		end
	end
end

local function appendNewestChatToPrompt(lines, player, filteredMessage)
	table.insert(lines, "")
	table.insert(lines, "Newest Chat:")

	local newestLine = string.format("[%s]: %s", player.Name, filteredMessage)
	table.insert(lines, newestLine)
end

local function buildModerationPrompt(player, filteredMessage)
	local lines = {}

	table.insert(lines, "Check the following chat logs for inappropriate behavior within Roblox's Terms Of Service and Privacy Policy.")
	table.insert(lines, "Respond ONLY in this format:")
	table.insert(lines, "|CLEAN:true|Reason:\"\"")
	table.insert(lines, "OR")
	table.insert(lines, "|CLEAN:false|Reason:\"<reason>\"")
	table.insert(lines, "")

	appendAllChatLogsToPrompt(lines)
	appendNewestChatToPrompt(lines, player, filteredMessage)

	local prompt = table.concat(lines, "\n")
	return prompt
end

--<SPLIT>
-- MODERATION API: send request and parse the response
--<SPLIT>
local function moderateMessage(prompt, playerName)
	local ok, response = pcall(function()
		return HttpService:PostAsync(
			BotEndPoint,
			HttpService:JSONEncode({
				prompt = prompt,
				instructions = "You are a VERY strict Roblox chat moderation bot. Follow the prompt format exactly."
			}),
			Enum.HttpContentType.ApplicationJson
		)
	end)

	if not ok or not response then
		warn("Moderation API failed for", playerName, response)
		return false, false, "API error"
	end

	local token = response:match("|CLEAN:(%a+)|")
	local reason = response:match('Reason:"(.-)"') or "Unknown"
	local isClean = (token == "true")

	return true, isClean, reason
end

--<SPLIT>
-- CHAT QUEUE: enqueue, dequeue, and process chat moderation jobs
--<SPLIT>
local function enqueueMessageForModeration(player, filteredMessage, timestamp)
	if not player or filteredMessage == "" then
		return
	end

	local chatData = {}
	chatData.player = player
	chatData.filtered = filteredMessage
	chatData.timestamp = timestamp

	table.insert(ChatQueue, chatData)
end

local function dequeueNextChat()
	if #ChatQueue == 0 then
		return nil
	end

	local chatData = table.remove(ChatQueue, 1)
	return chatData
end

local function shouldSkipChatData(chatData)
	if not chatData then
		return true
	end

	if not chatData.player then
		return true
	end

	return false
end

local function finalizeChatModeration(player, filteredMessage, timestamp, isFlagged)
	if not player then
		return
	end

	if not isFlagged then
		local logs = ensurePlayerLogTable(player)

		local entry = {}
		entry.text = filteredMessage
		entry.time = timestamp

		table.insert(logs, entry)
	else
		warn("Chat moderated for player:", player.Name)
	end
end

local function processNextChat()
	if IsProcessingChat then
		return
	end

	if #ChatQueue == 0 then
		return
	end

	IsProcessingChat = true

	local chatData = dequeueNextChat()

	if shouldSkipChatData(chatData) then
		IsProcessingChat = false
		task.spawn(processNextChat)
		return
	end

	local player = chatData.player
	local filteredMessage = chatData.filtered or ""
	local timestamp = chatData.timestamp or 0

	local isFlagged = isMessageBanned(filteredMessage)

	if not isFlagged then
		local prompt = buildModerationPrompt(player, filteredMessage)

		local success, isClean, reason = moderateMessage(prompt, player.Name)

		if not success then
			isFlagged = true
		elseif not isClean then
			isFlagged = true
			warn("Chat flagged by AI moderation. Reason:", reason)
		end
	end

	finalizeChatModeration(player, filteredMessage, timestamp, isFlagged)

	IsProcessingChat = false

	if #ChatQueue > 0 then
		task.spawn(processNextChat)
	end
end

--<SPLIT>
-- CHAT HANDLER: Roblox .Chatted connection and filtering
--<SPLIT>
local function filterPlayerMessage(player, message)
	if not player or not message then
		return ""
	end

	local success, result = pcall(function()
		local filterResult = TextService:FilterStringAsync(message, player.UserId)
		local nonChat = filterResult:GetNonChatStringForBroadcastAsync()
		return nonChat
	end)

	if success and result and result ~= "" then
		return result
	end

	return ""
end

local function handlePlayerChatted(player, message, startTime)
	if not player or not message then
		return
	end

	local now = os.clock()
	local timestamp = now - startTime

	local filteredMessage = filterPlayerMessage(player, message)
	if filteredMessage == "" then
		return
	end

	appendToPlayerBuffer(player, filteredMessage)
	enqueueMessageForModeration(player, filteredMessage, timestamp)

	task.spawn(processNextChat)
end

local function connectChatForPlayer(player, startTime)
	player.Chatted:Connect(function(message)
		handlePlayerChatted(player, message, startTime)
	end)
end

--<SPLIT>
-- MOVEMENT RECORDING: helper functions to capture player movement
--<SPLIT>
local function partChangedEnough(last, current)
	if not last then
		return true
	end

	local posDelta = (last.Position - current.Position).Magnitude

	local lx, ly, lz = last:ToEulerAnglesXYZ()
	local cx, cy, cz = current:ToEulerAnglesXYZ()
	local rotDelta = math.abs(lx - cx) + math.abs(ly - cy) + math.abs(lz - cz)

	if posDelta > 0.1 then
		return true
	end

	if rotDelta > 0.05 then
		return true
	end

	return false
end

local function captureCharacterSnapshot(character, lastSnapshot)
	if not character or not character.Parent then
		return nil, lastSnapshot
	end

	local snapshot = {}

	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CollisionGroup = PLAYER_COLLISION_GROUP

			local last = lastSnapshot[part.Name]
			local current = part.CFrame

			if partChangedEnough(last, current) then
				snapshot[part.Name] = compressCFrame(current)
				lastSnapshot[part.Name] = current
			end
		end
	end

	if next(snapshot) then
		return snapshot, lastSnapshot
	end

	return nil, lastSnapshot
end

local function shouldContinueRecording(player)
	if not player then
		return false
	end

	if not player:IsDescendantOf(Players) then
		return false
	end

	return true
end

local function startMovementRecordingForPlayer(player, recording)
	local lastSnapshot = {}

	while shouldContinueRecording(player) do
		local character = player.Character
		local snapshot

		snapshot, lastSnapshot = captureCharacterSnapshot(character, lastSnapshot)

		if snapshot then
			table.insert(recording, snapshot)
		end

		task.wait(RecordRate)
	end
end

--<SPLIT>
-- GHOST SAVING: encode movement + chat and write to datastore
--<SPLIT>
local function encodeGhostData(recording, chatLog)
	local payload = {}
	payload.movement = recording
	payload.chat = chatLog or {}

	local encoded = HttpService:JSONEncode(payload)
	return encoded
end

local function decodeIndexIfNeeded(indexValue)
	if typeof(indexValue) == "string" then
		local ok, decoded = pcall(function()
			return HttpService:JSONDecode(indexValue)
		end)

		if ok and decoded then
			return decoded
		end
	end

	if typeof(indexValue) == "table" then
		return indexValue
	end

	return {}
end

local function updateGhostIndexWithKey(ghostKey)
	local index = MovementStore:GetAsync(GhostIndexKey) or {}
	index = decodeIndexIfNeeded(index)

	table.insert(index, ghostKey)

	local encodedIndex = HttpService:JSONEncode(index)
	MovementStore:SetAsync(GhostIndexKey, encodedIndex)
end

local function saveGhostData(player, recording)
	if not player then
		return
	end

	if #recording == 0 then
		return
	end

	local successSave, errMessage = pcall(function()
		local counter = MovementStore:IncrementAsync(GhostCounterKey, 1)
		local ghostKey = "ghostkey_" .. counter

		local chatLog = ChatLogs[player] or {}
		local encoded = encodeGhostData(recording, chatLog)

		MovementStore:SetAsync(ghostKey, encoded)
		updateGhostIndexWithKey(ghostKey)
	end)

	if not successSave then
		warn("Recording save failed for", player.Name, errMessage)
	end
end

--<SPLIT>
-- CLEANUP: remove in-memory references when a player leaves
--<SPLIT>
local function cleanupStateForPlayer(player)
	ChatLogs[player] = nil
	PlayerChatBuffer[player] = nil
end

local function finalizePlayerRecording(player, recording)
	saveGhostData(player, recording)
	cleanupStateForPlayer(player)
end

--<SPLIT>
-- PLAYER LIFECYCLE: main entry point hooking into PlayerAdded
--<SPLIT>
local function waitForFirstCharacter(player, timeout)
	local total = 0
	local step = 0.1

	while total < timeout do
		if player.Character and player.Character.Parent then
			return player.Character
		end

		task.wait(step)
		total += step
	end

	return nil
end

local function handlePlayerAdded(player)
	local recording = {}
	local startTime = os.clock()

	ChatLogs[player] = {}
	PlayerChatBuffer[player] = {}

	connectChatForPlayer(player, startTime)

	task.spawn(function()
		local character = waitForFirstCharacter(player, 10)

		if not character then
			cleanupStateForPlayer(player)
			return
		end

		startMovementRecordingForPlayer(player, recording)
		finalizePlayerRecording(player, recording)
	end)
end

Players.PlayerAdded:Connect(handlePlayerAdded)
