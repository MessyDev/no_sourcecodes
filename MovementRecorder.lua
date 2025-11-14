--lazy ahh commenting

-- service (obviously)
local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local TextService = game:GetService("TextService")

-- the safest (totally) datastore that stores movement recordings & chat logs
local MovementStore = DataStoreService:GetDataStore(require(game:GetService("ServerScriptService"):WaitForChild("DatastoreNames")).MovementStore)

-- a rate where player movement snapshots get recorded (in seconds btw)
local RecordRate = 0.1

-- stores logs of ALL chat messages per-player (used only for AI context)
local ChatLogs = {}
-- temporary buffer of recent messages per-player (used only for context)
local PlayerChatBuffer = {}
-- a wait list for messages that are waiting for moderation
local ChatQueue = {}
-- stop multiple chat mods happening at once
local IsProcessingChat = false

-- THE NAUGHTY LIST!
local BadWords = require(script.BadWords)

-- the keys: index list & counter for ghost replaying stuff
local GhostIndexKey = require(game:GetService("ServerScriptService"):WaitForChild("DatastoreNames")).GhostIndexKey
local GhostCounterKey = require(game:GetService("ServerScriptService"):WaitForChild("DatastoreNames")).GhostCounterKey

-- automod bot API endpoint
local BotEndPoint = "https://gemini-api-n7dt.onrender.com"

-- rounds a number to a certain number of decimal places
local function round(n, decimals)
	local m = 10^decimals
	return math.floor(n * m + 0.5) / m
end

-- converts a CFrame into a compressed table for datastore storage
-- saves only position (rounded) and euler rotations (radians)
local function compressCFrame(cf)
	local pos = cf.Position
	local rx, ry, rz = cf:ToEulerAnglesXYZ()

	return {
		x = round(pos.X, 2),
		y = round(pos.Y, 2),
		z = round(pos.Z, 2),
		rx = round(rx, 3),
		ry = round(ry, 3),
		rz = round(rz, 3)
	}
end

-- checks if a string matches ANY word in the naughty bad boy list
-- ts is an exact match check-or-not substring
local function hasBadWord(msg)
	for _, word in ipairs(BadWords) do
		if msg:lower() == word then
			return true
		end
	end
	return false
end

-- processes the next message in ChatQueue using the following:
-- 1! a simple bad-word check
-- 2! external moderation API
-- savemessage if clean, rejects if not
local function processNextChat()
	-- if already processing or queue is empty, stop
	if IsProcessingChat or #ChatQueue == 0 then return end
	IsProcessingChat = true

	-- take oldest message from queue
	local chatData = table.remove(ChatQueue, 1)
	local player = chatData.player
	local filtered = chatData.filtered
	local timestamp = chatData.timestamp

	-- first check local bad word list
	local moderationResult = hasBadWord(filtered)

	-- builded moderation prompt for external API since i dont trust roblox
	-- full chat history so AI can judge correctly
	local prompt = "Check the following chat logs for inappropriate behavior within Roblox's Terms Of Service and Privacy Policy. Respond ONLY in this format:\n|CLEAN:true|Reason:\"\"\nOR\n|CLEAN:false|Reason:\"<reason>\"\n\nAll Chat Logs:\n"

	for p, logs in pairs(ChatLogs) do
		for _, log in ipairs(logs) do
			prompt = prompt .. string.format("[%s]: %s\n", p.Name, log.text)
		end
	end

	-- add newest message at bottom
	prompt = prompt .. string.format("\nNewest Chat:\n[%s]: %s\n", player.Name, filtered)
	print("prompt: ", prompt)

	-- send to moderation API if bad-word function check is clean
	if not moderationResult then
		local success, response = pcall(function()
			return HttpService:PostAsync(
				BotEndPoint,
				HttpService:JSONEncode({
					prompt = prompt,
					instructions = "You are a VERY strict moderation bot. Follow the format, and do not allow any form of profanity or insults into the database. Make sure you read all the chatlogs to see what the user is trying to say."
				}),
				Enum.HttpContentType.ApplicationJson
			)
		end)

		if success then
			-- check  whether "|CLEAN:true|" or "|CLEAN:false|"
			local isClean = string.match(response, "|CLEAN:(%a+)|")

			if isClean ~= "true" then
				-- message is unsafe
				moderationResult = true
				local reason = string.match(response, 'Reason:"(.-)"') or "Unknown"
				warn("chat flagged! reason:", reason)
			end
		else
			-- api failed: automatically treat message as unsafe
			warn("moderation API failed for user named ", player.Name, response)
			moderationResult = true
		end
	end

	-- final moderation result
	if not moderationResult then
		-- save cleaned message into the log
		table.insert(ChatLogs[player], { text = filtered, time = timestamp })
	else
		-- flagged = do not store
		warn("chat modded player:", player.Name)
	end

	-- process next chat automatically
	IsProcessingChat = false
	task.spawn(processNextChat)
end

-- is fired when a player joins the game
-- what it currently handles:
-- chat logging, filtering, moderation
-- player recorded and turned into ghosts
Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Wait()

	local recording = {} -- stores movement snapshots
	local startTime = tick() -- used for timestamping chat
	ChatLogs[player] = {} -- chat history for moderation
	PlayerChatBuffer[player] = {} -- recent chat buffer (unused except for storage)

	-- CHAT HANDLING
	player.Chatted:Connect(function(msg)
		local timestamp = tick() - startTime
		local filtered = ""

		-- use roblox text filter
		pcall(function()
			local result = TextService:FilterStringAsync(msg, player.UserId)
			filtered = result:GetNonChatStringForBroadcastAsync()
		end)

		-- keep short rollin buffer (max 5 messages)
		table.insert(PlayerChatBuffer[player], filtered)
		if #PlayerChatBuffer[player] > 5 then
			table.remove(PlayerChatBuffer[player], 1)
		end

		-- add to moderation queue (the N incident got me termed so this is important)
		table.insert(ChatQueue, {
			player = player,
			filtered = filtered,
			timestamp = timestamp
		})

		-- start processing (if not already)
		task.spawn(processNextChat)
	end)

	-- MOVEMENT RECORDING
	-- saves player movement snapshots to be played back as ghosts
	local lastSnapshot = {}

	while player:IsDescendantOf(Players) do
		pcall(function()
			local char = player.Character
			if char.Parent then
				local snapshot = {}

				for _, part in ipairs(char:GetDescendants()) do
					if part:IsA("BasePart") then
						-- ensures player collision settings are PLAYERS so a NPC doesnt bump into players and mess up recordings
						part.CollisionGroup = "PLAYERS"

						local last = lastSnapshot[part.Name]
						local current = part.CFrame

						-- if first time seeing part, save IMMEDIETLY! (cant spell cuz im too tired)
						if not last then
							snapshot[part.Name] = compressCFrame(current)
							lastSnapshot[part.Name] = current
						else
							-- check if part actually moved/rotated significantly
							local posDelta = (last.Position - current.Position).Magnitude

							local lrX, lrY, lrZ = last:ToEulerAnglesXYZ()
							local crX, crY, crZ = current:ToEulerAnglesXYZ()
							local rotDelta = math.abs(lrX - crX) + math.abs(lrY - crY) + math.abs(lrZ - crZ)

							-- only save if the movement/rotation is large enough
							if posDelta > 0.1 or rotDelta > 0.05 then
								snapshot[part.Name] = compressCFrame(current)
								lastSnapshot[part.Name] = current
							end
						end
					end
				end

				-- if anything has changed, it will add snapshot to recording
				if next(snapshot) then
					table.insert(recording, snapshot)
				end
			end
		end)

		task.wait(RecordRate)
	end

	-- SAVE DATA WHEN PLAYER LEAVES!!!!
	-- it saves player's movement + chat logs to the datastore as a "ghost"
	local successSave, err = pcall(function()
		-- increment ghost counter to generate unique ghost key :3
		local counter = MovementStore:IncrementAsync(GhostCounterKey, 1)
		local ghostKey = "ghostkey_" .. counter

		-- package data as JSON
		local data = HttpService:JSONEncode({
			movement = recording,
			chat = ChatLogs[player] or {}
		})

		-- save ghost data
		MovementStore:SetAsync(ghostKey, data)

		-- update ghost index
		local index = MovementStore:GetAsync(GhostIndexKey) or {}
		if typeof(index) == "string" then
			index = HttpService:JSONDecode(index)
		end

		table.insert(index, ghostKey)
		MovementStore:SetAsync(GhostIndexKey, HttpService:JSONEncode(index))
	end)

	if not successSave then
		warn("Recording save failed for", player.Name, err)
	end

	-- cleanup memory
	ChatLogs[player] = nil
	PlayerChatBuffer[player] = nil
end)