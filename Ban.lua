-- Services
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

-- Configuration
local GITHUB_URL = "https://raw.githubusercontent.com/CompTactical/milsim-bans/refs/heads/main/BanList"
local REFRESH_INTERVAL = 3600 -- 3600 seconds = 1 hour

-- Local Cache (Remembers who this server has already processed to save API calls)
local userStateCache = {} -- Format: [userId] = "BANNED" or "UNBANNED"

-- Function to split arrays into chunks of 50 (Roblox BanAsync limit is 50 users per call)
local function chunkArray(array, chunkSize)
	local chunks = {}
	for i = 1, #array, chunkSize do
		local chunk = {}
		for j = i, math.min(i + chunkSize - 1, #array) do
			table.insert(chunk, array[j])
		end
		table.insert(chunks, chunk)
	end
	return chunks
end

-- Main function to fetch, parse, and execute bans
local function syncBanList()
	print("[BanSync] Fetching latest ban list from GitHub...")
	
	-- 1. Fetch the data from GitHub
	local success, result = pcall(function()
		return HttpService:GetAsync(GITHUB_URL, true) -- 'true' bypasses Roblox's internal cache
	end)

	if not success then
		warn("[BanSync] Failed to fetch ban list: " .. tostring(result))
		return
	end

	-- 2. Parse the text file
	local lines = string.split(result, "\n")
	local currentMode = "NONE"
	
	local bansDictionary = {}
	local unbansDictionary = {}

	for _, line in ipairs(lines) do
		-- Clean up the line (remove windows line endings (\r) and comments (#))
		line = string.gsub(line, "\r", "")
		local commentStart = string.find(line, "#")
		if commentStart then
			line = string.sub(line, 1, commentStart - 1)
		end
		line = string.match(line, "^%s*(.-)%s*$") -- Trim extra whitespace
		
		-- Skip empty lines
		if line == "" then continue end

		-- Check for section headers
		if line == "[BANS]" then
			currentMode = "BANS"
			continue
		elseif line == "[UNBANS]" then
			currentMode = "UNBANS"
			continue
		end

		-- Parse the UserId
		local userId = tonumber(line)
		if userId then
			if currentMode == "BANS" then
				bansDictionary[userId] = true
			elseif currentMode == "UNBANS" then
				unbansDictionary[userId] = true
			end
		end
	end

	-- 3. Resolve Conflicts (Unbans override Bans)
	for userId, _ in pairs(unbansDictionary) do
		if bansDictionary[userId] then
			bansDictionary[userId] = nil -- Remove from ban list if they are in the unban list
		end
	end

	-- 4. Compare against cache (Only get NEW or CHANGED states)
	local bansToExecute = {}
	local unbansToExecute = {}

	for userId in pairs(bansDictionary) do
		if userStateCache[userId] ~= "BANNED" then
			table.insert(bansToExecute, userId)
		end
	end

	for userId in pairs(unbansDictionary) do
		if userStateCache[userId] ~= "UNBANNED" then
			table.insert(unbansToExecute, userId)
		end
	end

	-- 5. Execute Bans (in chunks of 50)
	if #bansToExecute > 0 then
		local banChunks = chunkArray(bansToExecute, 50)
		for _, chunk in ipairs(banChunks) do
			
			local banConfig = {
				UserIds = chunk,
				Duration = -1,                  -- -1 explicitly makes the ban infinite/permanent
				ApplyToUniverse = true,         -- Bans them across ALL places/games in this universe
				ExcludeAltAccounts = false,     -- FALSE means it WILL ban their alt accounts too
				
				-- === REASON CONFIGURATION ===
				DisplayReason = "Persona Non Grata List - Roblox Milsim Community", -- What the player sees
				PrivateReason = "GitHub Sync: Persona Non Grata List",              -- What you see in logs
			}
			
			local banSuccess, banErr = pcall(function()
				Players:BanAsync(banConfig)
			end)
			
			if banSuccess then
				-- Save to cache so we don't ban them again next hour
				for _, id in ipairs(chunk) do
					userStateCache[id] = "BANNED"
				end
			else
				warn("[PNG] Failed to apply bans: " .. tostring(banErr))
			end
		end
		print("[PNG] Successfully processed " .. #bansToExecute .. " new/updated bans.")
	else
		print("[PNG] No new bans to process.")
	end

	-- 6. Execute Unbans (in chunks of 50)
	if #unbansToExecute > 0 then
		local unbanChunks = chunkArray(unbansToExecute, 50)
		for _, chunk in ipairs(unbanChunks) do
			local unbanConfig = {
				UserIds = chunk,
				ApplyToUniverse = true, -- Must match the universe setting used in the ban
			}

			local unbanSuccess, unbanErr = pcall(function()
				Players:UnbanAsync(unbanConfig)
			end)

			if unbanSuccess then
				-- Save to cache so we don't unban them again next hour
				for _, id in ipairs(chunk) do
					userStateCache[id] = "UNBANNED"
				end
			else
				warn("[PNG] Failed to apply unbans: " .. tostring(unbanErr))
			end
		end
		print("[PNG] Successfully processed " .. #unbansToExecute .. " new/updated unbans.")
	else
		print("[PNG] No new unbans to process.")
	end
end

-- Execute loop in a background thread
task.spawn(function()
	while true do
		syncBanList()
		-- Wait for 1 hour before fetching again
		task.wait(REFRESH_INTERVAL)
	end
end)
