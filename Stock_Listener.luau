-- Made by dev__vz

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Task = task
local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")

-- configs and secrets loaded from ServerScriptService so they're never exposed to the client
local ConfigsFolder = ServerScriptService:WaitForChild("Config")
local Secrets = require(ConfigsFolder:WaitForChild("SecretsAPI"))

local WORKER_URL = Secrets.WORKER_URL or "I can't put it there because of privacy :)"
local API_KEY = Secrets.WORKER_API_KEY or "Same"

local Packages = ServerScriptService:WaitForChild("Packages")
local Configs = ServerScriptService:WaitForChild("Config")
local Shared = ReplicatedStorage:WaitForChild("Shared")

-- SharedPackets exposes the RemoteEvent/RemoteFunction shared between server and client
-- Using Packet: https://www.bing.com/ck/a?!&&p=2546d8503434447c633cbe15524223a1f279bc73c931f6277549841bcaeb8a20JmltdHM9MTc3ODU0NDAwMA&ptn=3&ver=2&hsh=4&fclid=2aff427a-f848-6511-3eff-544df99564ca&psq=packet+devforum&u=a1aHR0cHM6Ly9kZXZmb3J1bS5yb2Jsb3guY29tL3QvcGFja2V0LW5ldHdvcmtpbmctbGlicmFyeS8zNTczOTA3
local SharedPackets = require(Shared.SharedPacket)
local notifyModule = require(ServerScriptService.Packages.NotifyClient)

local TimeToStockEvent = SharedPackets.TimeToStock
local StockChangedEvent = SharedPackets.StockChanged
local GetStockFunction = SharedPackets.GetStock
local BuyStockFunction = SharedPackets.BuyStock

local DataService = require(ServerScriptService.Services.ServerInitializer.Datastore.DataService)
local SeedStockTable = require(Configs.SeedStock)

local SEED_STOCK_NAME = "SeedStock"
local RESTOCK_INTERVAL = 300 -- fallback interval in seconds if the worker doesn't respond

-- debounce to avoid multiple restock notifications firing in quick succession
local lastRestockNotify = 0
local RESTOCK_NOTIFY_DEBOUNCE = 2

local PacksFolder = ServerStorage:FindFirstChild("Packs")
local BrainrotsFolder = ServerStorage:FindFirstChild("Brainrots")

-- current countdown to next restock, updated both via polling and via MessagingService
local currentCountdown = nil

-- cache of the merged global stock and the config received from the worker
local cachedMergedStock = nil
local cachedSeedCfg = nil
local cachedStockId = nil

-- ToolCache indexes Tools by name to avoid scanning BrainrotsFolder on every purchase
local ToolCache = {}

-- personalPool[stockName][userId] tracks remaining items per player
-- derived from global stock by subtracting purchases persisted in the datastore
local personalPool = {}

-- loop control flags
local _running = false
local _paused = false
local _loopThread = nil

-- pre-cache all Tools inside BrainrotsFolder at startup for O(1) lookup
local function IndexTools()
	if not BrainrotsFolder then return end
	for _, descendant in ipairs(BrainrotsFolder:GetDescendants()) do
		if descendant:IsA("Tool") then
			ToolCache[descendant.Name] = descendant
		end
	end
end
IndexTools()

-- deduplicates SeedStockTable in case there are entries with the same name
local function buildCombinedMetaList()
	local out = {}
	local seen = {}
	for _,meta in ipairs(SeedStockTable) do
		if meta and meta.name and not seen[meta.name] then
			table.insert(out, meta)
			seen[meta.name] = true
		end
	end
	return out
end

local CombinedStockTable = buildCombinedMetaList()

-- lookup set for fast membership check on the item catalog
local CombinedStockLookup = {}
for _,m in ipairs(CombinedStockTable) do CombinedStockLookup[m.name] = true end

local function findMetaByName(name)
	for _,m in ipairs(SeedStockTable) do
		if m.name == name then return m, SEED_STOCK_NAME end
	end
	return nil, nil
end

-- compares old and new maps to detect if at least one item increased in quantity (= restock happened)
local function detectRestock(oldMap, newMap)
	if type(newMap) ~= "table" then return false end
	if type(oldMap) ~= "table" then
		return false
	end
	for name, newAmt in pairs(newMap) do
		local oldAmt = tonumber(oldMap[name]) or 0
		if tonumber(newAmt) and tonumber(newAmt) > oldAmt then
			return true
		end
	end
	return false
end

local function notifyAllPlayers(message, seconds, tag)
	for _, plr in ipairs(Players:GetPlayers()) do
		pcall(function() notifyModule.Notify(plr, message, seconds, tag) end)
	end
end

-- builds the stock array to send to the client from the player's personal pool
local function buildFullStockFromPool(mergedPoolForPlayer, stockMetaList)
	local out = table.create(#stockMetaList)
	for _, meta in ipairs(stockMetaList) do
		local name = meta.name
		local remaining = 0
		if mergedPoolForPlayer and mergedPoolForPlayer[name] then remaining = mergedPoolForPlayer[name] end
		table.insert(out, {
			name = name,
			amount = remaining,
			Price = meta.Price,
			rarity = meta.rarity,
			PackContent = meta.PackContent
		})
	end
	return out
end

-- persists the player's purchases in the datastore along with the current stockId
-- the stockId is used to invalidate saved data if a restock happened in the meantime
local function saveLastPersonalStockForPlayer(player, saveTable)
	if not player or not player.UserId then return end
	saveTable = saveTable or {}
	saveTable._stockId = cachedStockId
	local ok, err = pcall(function()
		DataService.Set(player, "LastPersonalStock", saveTable or {})
	end)
	if not ok then
		warn("[StockSync] failed saving LastPersonalStock for player:", player.Name, tostring(err))
	end
end

local function readLastPersonalStockForPlayer(player)
	if not player then return nil end
	local ok, data = pcall(function() return DataService.Get(player, "LastPersonalStock") end)
	if ok and type(data) == "table" then
		return data
	end
	return {}
end

-- subtracts saved purchases from poolMap, but only if the stockId matches
-- if the stock changed (restock), the saved data is ignored and the pool starts full
local function applySavedPurchasesToPoolMap(poolMap, saved)
	if type(poolMap) ~= "table" or type(saved) ~= "table" then return end
	if cachedStockId == nil then return end
	local currentIdString = tostring(cachedStockId)
	local savedIdString = tostring(saved.stockId)
	if currentIdString ~= savedIdString then return end
	if type(saved.purchases) == "table" then
		for name, amount in pairs(saved.purchases) do
			local n = tonumber(amount) or 0
			if n > 0 and poolMap[name] ~= nil then
				local before = tonumber(poolMap[name]) or 0
				local newVal = math.max(0, before - n)
				poolMap[name] = newVal
			end
		end
	end
end

-- clones the Tool from cache or searches the BrainrotsFolder/rarity/name structure
-- and delivers it to the player's Backpack for the requested quantity
local function giveSeedToolToPlayer(player, meta, qty)
	if not meta then return end
	local toolTemplate = ToolCache[meta.name]
	if not toolTemplate then
		if BrainrotsFolder then
			local rarity = tostring(meta.rarity or "")
			local rarityFolder = BrainrotsFolder:FindFirstChild(rarity)
			if rarityFolder then
				toolTemplate = rarityFolder:FindFirstChild(meta.name)
				if toolTemplate and not toolTemplate:IsA("Tool") then
					toolTemplate = toolTemplate:FindFirstChildOfClass("Tool")
				end
			end
		end
		if toolTemplate and toolTemplate:IsA("Tool") then
			ToolCache[meta.name] = toolTemplate
		end
	end
	if not toolTemplate then return end
	local backpack = player:FindFirstChild("Backpack")
	if not backpack then return end
	pcall(function()
		local count = tonumber(qty) or 1
		for i = 1, count do
			local clone = toolTemplate:Clone()
			clone.Parent = backpack
		end
	end)
end

-- wrapper around HttpService:RequestAsync with fallback to GetAsync/PostAsync
-- handles x-api-key header and JSON body serialization
local function workerRequest(path, method, body)
	method = method or "GET"
	local url = WORKER_URL .. path
	local headers = { ["Content-Type"] = "application/json" }
	if API_KEY and API_KEY ~= "" then headers["x-api-key"] = API_KEY end
	local options = {
		Url = url,
		Method = method,
		Headers = headers,
		Timeout = 15
	}
	if body then
		if type(body) == "string" then
			options.Body = body
		else
			options.Body = HttpService:JSONEncode(body)
		end
	end
	local ok, res = pcall(function() return HttpService:RequestAsync(options) end)
	if not ok then
		-- RequestAsync unavailable (e.g. Studio without HTTP enabled): fall back to legacy methods
		if method == "GET" then
			local succ, bodyOrErr = pcall(function() return HttpService:GetAsync(url, true) end)
			if not succ then return false, ("Fallback GetAsync failed: "..tostring(bodyOrErr)) end
			return true, bodyOrErr
		else
			local succ, bodyOrErr = pcall(function()
				return HttpService:PostAsync(url, options.Body or "", Enum.HttpContentType.ApplicationJson, false)
			end)
			if not succ then return false, ("Fallback PostAsync failed: "..tostring(bodyOrErr)) end
			return true, bodyOrErr
		end
	end
	if type(res) == "table" then
		if not res.Success then
			return false, ("HTTP "..tostring(res.StatusCode).." - "..tostring(res.Body or res.body or "<no-body>"))
		end
		return true, (res.Body or res.body or "")
	else
		return true, tostring(res)
	end
end

-- converts the stock array [{name, amount}] returned by the worker into a map {name = amount}
local function arrayToMap(stockArray)
	local map = {}
	for _, entry in ipairs(stockArray or {}) do
		if entry and entry.name then
			map[entry.name] = tonumber(entry.amount) or 0
		end
	end
	return map
end

-- updates every connected player's personalPool with the new global stock,
-- then re-applies their previous purchases and FireAllClients the updated payload
local function applyMergedStockToPlayers(mergedMap)
	personalPool[SEED_STOCK_NAME] = personalPool[SEED_STOCK_NAME] or {}
	for _, player in ipairs(Players:GetPlayers()) do
		personalPool[SEED_STOCK_NAME][player.UserId] = table.clone(mergedMap)
	end
	for _, player in ipairs(Players:GetPlayers()) do
		local saved = readLastPersonalStockForPlayer(player)
		if type(saved) == "table" then
			local pool = personalPool[SEED_STOCK_NAME][player.UserId]
			if pool then
				applySavedPurchasesToPoolMap(pool, saved)
			end
		end
	end
	local payload = buildFullStockFromPool(mergedMap, CombinedStockTable)
	if StockChangedEvent then
		if StockChangedEvent.FireAllClients then
			pcall(function() StockChangedEvent:FireAllClients(payload) end)
		elseif StockChangedEvent.Fire then
			pcall(function() StockChangedEvent:Fire(payload) end)
		else
			warn("[StockSync] StockChangedEvent exists but no known fire method")
		end
	end
end

-- main polling function: GET /stock from the Cloudflare worker
-- if the stock doesn't exist on the worker yet, initializes it via POST /set-seed
-- updates cachedMergedStock, detects restocks and propagates timeToRestock to clients
local function fetchStockFromWorker()
	local ok, bodyOrErr = workerRequest("/stock?name="..HttpService:UrlEncode(SEED_STOCK_NAME), "GET")
	if not ok then
		if tostring(bodyOrErr):find("unknown stock") then
			-- first boot: the worker doesn't know this stock yet, so we create it
			local payload = {}
			payload[SEED_STOCK_NAME] = {
				stockItems = SeedStockTable,
				minItems = 1,
				maxItems = math.max(1, #SeedStockTable),
				RESTOCK_INTERVAL = RESTOCK_INTERVAL
			}
			local okSet, setRes = workerRequest("/set-seed", "POST", payload)
			if not okSet then
				return nil, ("set-seed failed: "..tostring(setRes))
			else
				local ok2, bodyOrErr2 = workerRequest("/stock?name="..HttpService:UrlEncode(SEED_STOCK_NAME), "GET")
				if not ok2 then
					return nil, bodyOrErr2
				else
					ok, bodyOrErr = ok2, bodyOrErr2
				end
			end
		else
			return nil, bodyOrErr
		end
	end
	local ok2, data = pcall(function() return HttpService:JSONDecode(bodyOrErr) end)
	if not ok2 then
		return nil, data
	end
	if type(data.stock) ~= "table" then
		return nil, "no stock"
	end
	local newMap = arrayToMap(data.stock)
	local wasRestock = detectRestock(cachedMergedStock, newMap)
	cachedMergedStock = newMap
	cachedSeedCfg = data.seedConfig
	if type(data.stockId) == "number" or type(data.stockId) == "string" then
		cachedStockId = data.stockId
	end
	applyMergedStockToPlayers(cachedMergedStock)
	if wasRestock and (tick() - lastRestockNotify) >= RESTOCK_NOTIFY_DEBOUNCE then
		lastRestockNotify = tick()
		notifyAllPlayers("The stock has been restocked!", 3)
	end
	local t = nil
	if data.timeToRestock ~= nil then
		t = tonumber(data.timeToRestock)
	end
	local secondsToSend = t or (cachedSeedCfg and cachedSeedCfg[SEED_STOCK_NAME] and tonumber(cachedSeedCfg[SEED_STOCK_NAME].RESTOCK_INTERVAL)) or 0
	pcall(function()
		if TimeToStockEvent and TimeToStockEvent.Fire then
			TimeToStockEvent:Fire({ [SEED_STOCK_NAME] = secondsToSend })
		else
			for _, plr in ipairs(Players:GetPlayers()) do
				pcall(function()
					if TimeToStockEvent and TimeToStockEvent.FireClient then
						TimeToStockEvent:FireClient(plr, { [SEED_STOCK_NAME] = secondsToSend })
					end
				end)
			end
		end
	end)
	return t, data
end

-- initializes a player's personal pool by copying the global stock
-- so each player starts with the same quantities as the global and reductions are per-player
local function initPersonalPoolForPlayerStock(stockName, userId, globalOverride)
	personalPool[stockName] = personalPool[stockName] or {}
	local global = globalOverride or cachedMergedStock or {}
	local map = {}
	for _, meta in ipairs(SeedStockTable) do
		map[meta.name] = 0
	end
	for name, amt in pairs(global) do
		map[name] = tonumber(amt) or 0
	end
	personalPool[stockName][userId] = map
	return map
end

-- merges per-stock pools into a single map for the client
local function getMergedPoolForPlayer(userId)
	local merged = {}
	for _, meta in ipairs(CombinedStockTable) do
		merged[meta.name] = 0
	end
	local s = personalPool[SEED_STOCK_NAME] and personalPool[SEED_STOCK_NAME][userId]
	if not s then
		s = initPersonalPoolForPlayerStock(SEED_STOCK_NAME, userId)
	end
	for k,v in pairs(s) do
		merged[k] = (merged[k] or 0) + (tonumber(v) or 0)
	end
	return merged
end

local function broadcastTimeToStock(seconds)
	local data = { [SEED_STOCK_NAME] = tonumber(seconds) or 0 }
	if TimeToStockEvent then
		if TimeToStockEvent.FireAllClients then
			pcall(function() TimeToStockEvent:FireAllClients(data) end)
		elseif TimeToStockEvent.Fire then
			pcall(function() TimeToStockEvent:Fire(data) end)
		end
	end
end

-- handler for messages arriving from MessagingService (topic "stock-updates")
-- the worker pushes updates in compact format {n, a} to stay within MessagingService payload limits
-- also handles admin add/remove commands and fetchFullFromWorker as a fallback
local function onStockMessage(message)
	local ok, data = pcall(function() return HttpService:JSONDecode(message.Data) end)
	if not ok then
		warn("[StockSync] invalid messaging payload")
		return
	end
	if type(data) ~= "table" then return end
	if data.stockName and data.stockName ~= SEED_STOCK_NAME then return end

	if data.compactStock and type(data.compactStock) == "table" then
		-- compact format: {n = name, a = amount} to fit within MessagingService size limits
		local mergedMap = {}
		for _, e in ipairs(data.compactStock) do
			if e and e.n then
				mergedMap[e.n] = tonumber(e.a) or 0
			end
		end
		if data.stockId then cachedStockId = data.stockId end
		local wasRestock = detectRestock(cachedMergedStock, mergedMap)
		cachedMergedStock = mergedMap
		applyMergedStockToPlayers(cachedMergedStock)
		if data.isRestock or (wasRestock and (tick() - lastRestockNotify) >= RESTOCK_NOTIFY_DEBOUNCE) then
			if data.action ~= "add" and data.action ~= "remove" then
				lastRestockNotify = tick()
				notifyAllPlayers("The stock has been restocked!", 3)
			end
		end

	elseif data.action == "add" and data.item then
		-- admin added an item: update local cache without a full refetch
		local itemName = data.item.name
		local itemAmount = tonumber(data.item.amount) or 1
		local msg = string.format("Admin added: %s x%d to stock!", itemName, itemAmount)
		for _, player in ipairs(Players:GetPlayers()) do
			notifyModule.Notify(player, msg, 3)
		end
		if cachedMergedStock then
			local currentAmt = cachedMergedStock[itemName] or 0
			cachedMergedStock[itemName] = currentAmt + itemAmount
			applyMergedStockToPlayers(cachedMergedStock)
		else
			data.fetchFullFromWorker = true
		end

	elseif data.action == "remove" and data.item then
		-- admin removed an item: zero out the quantity in the cache
		local itemName = data.item.name
		local msg = string.format("Admin removed: %s from stock!", itemName)
		for _, player in ipairs(Players:GetPlayers()) do
			notifyModule.Notify(player, msg, 3)
		end
		if cachedMergedStock and cachedMergedStock[itemName] then
			cachedMergedStock[itemName] = 0
			applyMergedStockToPlayers(cachedMergedStock)
		else
			data.fetchFullFromWorker = true
		end
	end

	-- if the cache was nil or inconsistent, full refetch as a safety net
	if data.fetchFullFromWorker then
		spawn(function()
			local path = "/stock?name=" .. HttpService:UrlEncode(SEED_STOCK_NAME)
			local ok2, bodyOrErr = workerRequest(path, "GET")
			if ok2 then
				local decodeOk, fullData = pcall(function() return HttpService:JSONDecode(bodyOrErr) end)
				if decodeOk and fullData.stock then
					cachedMergedStock = arrayToMap(fullData.stock)
					cachedStockId = fullData.stockId
					applyMergedStockToPlayers(cachedMergedStock)
				end
			end
		end)
	end

	if data.timeToRestock ~= nil then
		currentCountdown = tonumber(data.timeToRestock) or currentCountdown
		pcall(function() broadcastTimeToStock(currentCountdown) end)
	end
end

Players.PlayerAdded:Connect(function(player)
	local uId = player.UserId

	-- if the server doesn't have stock yet (first player of the session), fetch immediately
	if cachedMergedStock == nil or cachedStockId == nil then
		local ok, err = pcall(function() fetchStockFromWorker() end)
		if not ok then
			warn("[StockSync] initial fetchStockFromWorker failed in PlayerAdded: " .. tostring(err))
		end
	end

	-- init personal pool and restore previous purchases from the datastore
	if cachedMergedStock then
		initPersonalPoolForPlayerStock(SEED_STOCK_NAME, uId, cachedMergedStock)
	else
		initPersonalPoolForPlayerStock(SEED_STOCK_NAME, uId)
	end
	local saved = readLastPersonalStockForPlayer(player)
	if type(saved) == "table" then
		personalPool[SEED_STOCK_NAME] = personalPool[SEED_STOCK_NAME] or {}
		personalPool[SEED_STOCK_NAME][uId] = personalPool[SEED_STOCK_NAME][uId] or initPersonalPoolForPlayerStock(SEED_STOCK_NAME, uId, cachedMergedStock)
		applySavedPurchasesToPoolMap(personalPool[SEED_STOCK_NAME][uId], saved)
	end

	-- 1s delay to make sure the client finished loading before sending data
	task.delay(1, function()
		if player.Parent then
			local mergedPool = getMergedPoolForPlayer(uId)
			local clientStock = buildFullStockFromPool(mergedPool, CombinedStockTable)
			pcall(function()
				if StockChangedEvent and StockChangedEvent.FireClient then
					StockChangedEvent:FireClient(player, clientStock)
				end
				local sendSeconds = nil
				if currentCountdown ~= nil then
					sendSeconds = currentCountdown
				elseif cachedSeedCfg and cachedSeedCfg[SEED_STOCK_NAME] and cachedSeedCfg[SEED_STOCK_NAME].RESTOCK_INTERVAL then
					sendSeconds = tonumber(cachedSeedCfg[SEED_STOCK_NAME].RESTOCK_INTERVAL) or 0
				else
					sendSeconds = 0
				end
				if TimeToStockEvent and TimeToStockEvent.FireClient then
					TimeToStockEvent:FireClient(player, { [SEED_STOCK_NAME] = sendSeconds })
				end
			end)
		end
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	-- clean up the in-memory pool on disconnect; persisted data stays in the datastore
	local okSave, err = pcall(function()
		if personalPool[SEED_STOCK_NAME] and personalPool[SEED_STOCK_NAME][player.UserId] then
			personalPool[SEED_STOCK_NAME][player.UserId] = nil
		end
	end)
	if not okSave then
		warn("[StockSync] error cleaning personalPool for leaving player: "..tostring(err))
	end
end)

if GetStockFunction then
	GetStockFunction.OnServerInvoke = function(player, requestedStockName)
		requestedStockName = requestedStockName or "merged"
		if requestedStockName == SEED_STOCK_NAME then
			local pool = personalPool[requestedStockName] and personalPool[requestedStockName][player.UserId] or initPersonalPoolForPlayerStock(requestedStockName, player.UserId)
			local meta = SeedStockTable
			return buildFullStockFromPool(pool, meta)
		else
			local mergedPool = getMergedPoolForPlayer(player.UserId)
			return buildFullStockFromPool(mergedPool, CombinedStockTable)
		end
	end
end

if BuyStockFunction then
	BuyStockFunction.OnServerInvoke = function(player, purchase)
		if type(purchase) ~= "table" or type(purchase.name) ~= "string" then return false end
		local qty = tonumber(purchase.amount) or 1
		if qty <= 0 then
			notifyModule.Notify(player, "The seed is not in stock!", 3, "Error")
			return false
		end
		local meta, assumedStock = findMetaByName(purchase.name)
		if not meta then
			notifyModule.Notify(player, "The seed is not in stock!", 3, "Error")
			return false
		end
		local stockName = SEED_STOCK_NAME
		local uId = player.UserId
		local pool = personalPool[stockName] and personalPool[stockName][uId]
		if not pool then
			pool = initPersonalPoolForPlayerStock(stockName, uId)
		end

		-- server-side validation: check availability in the player's personal pool
		local remain = pool[purchase.name] or 0
		if remain <= 0 or qty > remain then
			notifyModule.Notify(player, "The seed is not in stock!", 3, "Error")
			return false
		end
		local pricePer = meta.Price or 0
		local totalPrice = pricePer * qty
		local coins = DataService.Get(player, "Money")
		if not coins or coins < totalPrice then
			notifyModule.Notify(player, "You don't have enough money!", 3, "")
			return false
		end

		-- transaction: deduct money, update local pool, deliver tool
		DataService.Remove(player, "Money", totalPrice)
		pool[purchase.name] = remain - qty
		local mergedPool = getMergedPoolForPlayer(uId)
		local clientStock = buildFullStockFromPool(mergedPool, CombinedStockTable)
		pcall(function()
			if StockChangedEvent and StockChangedEvent.FireClient then
				StockChangedEvent:FireClient(player, clientStock)
			end
		end)
		giveSeedToolToPlayer(player, meta, qty)
		notifyModule.Notify(player, "You succesfully bought: "..purchase.name, 3)

		-- update the purchase record in the datastore
		-- if the stockId changed (restock in the meantime), reset the record before saving
		local okRead, prev = pcall(function() return DataService.Get(player, "LastPersonalStock") end)
		local saved = (okRead and type(prev) == "table") and prev or {}
		if tostring(saved.stockId) ~= tostring(cachedStockId) then
			saved = { stockId = cachedStockId, purchases = {} }
		else
			saved.stockId = cachedStockId
			saved.purchases = saved.purchases or {}
		end
		local currentBought = saved.purchases[purchase.name] or 0
		saved.purchases[purchase.name] = currentBought + qty
		pcall(function() DataService.Set(player, "LastPersonalStock", saved) end)
		return true
	end
end

-- subscribe to the MessagingService topic to receive pushes from the Cloudflare worker
-- allows real-time updates without waiting for the polling loop
local succ, err = pcall(function()
	MessagingService:SubscribeAsync("stock-updates", function(msg) onStockMessage(msg) end)
end)
if not succ then
	warn("[StockSync] SubscribeAsync failed: " .. tostring(err))
end

local StockService = {}

-- polling loop: fetch every timeToRestock seconds, tick the client every second
-- handles _paused without killing the thread, useful for maintenance or debugging
local function runLoop()
	while _running do
		while _paused and _running do
			Task.wait(0.5)
		end
		if not _running then break end
		local t, dataOrErr
		local ok, err = pcall(function()
			t, dataOrErr = fetchStockFromWorker()
		end)
		if not ok then
			warn("[StockSync] fetchStockFromWorker crashed: " .. tostring(err))
			if cachedSeedCfg and cachedSeedCfg[SEED_STOCK_NAME] and cachedSeedCfg[SEED_STOCK_NAME].RESTOCK_INTERVAL then
				currentCountdown = tonumber(cachedSeedCfg[SEED_STOCK_NAME].RESTOCK_INTERVAL) or 30
			else
				currentCountdown = currentCountdown or 30
			end
		else
			if t == nil then
				warn("[StockSync] fetchStockFromWorker returned error: " .. tostring(dataOrErr))
				if cachedSeedCfg and cachedSeedCfg[SEED_STOCK_NAME] and cachedSeedCfg[SEED_STOCK_NAME].RESTOCK_INTERVAL then
					currentCountdown = tonumber(cachedSeedCfg[SEED_STOCK_NAME].RESTOCK_INTERVAL) or 30
				else
					currentCountdown = currentCountdown or 30
				end
			else
				currentCountdown = tonumber(t) or 0
			end
		end

		-- countdown with a broadcast every second until it expires
		while currentCountdown > 0 and _running do
			if not _paused then
				pcall(function()
					if TimeToStockEvent and TimeToStockEvent.Fire then
						TimeToStockEvent:Fire({ [SEED_STOCK_NAME] = currentCountdown })
					else
						for _, plr in ipairs(Players:GetPlayers()) do
							pcall(function()
								if TimeToStockEvent and TimeToStockEvent.FireClient then
									TimeToStockEvent:FireClient(plr, { [SEED_STOCK_NAME] = currentCountdown })
								end
							end)
						end
					end
				end)
				currentCountdown = math.max(0, currentCountdown - 1)
			end
			Task.wait(1)
		end
	end
end

function StockService.Start()
	if _running then return end
	_running = true
	_paused = false
	_loopThread = Task.spawn(runLoop)
end

function StockService.Stop()
	_running = false
	_paused = false
	if _loopThread then
		pcall(function() task.cancel(_loopThread) end)
		_loopThread = nil
	end
end

function StockService.Pause()
	if not _running then return end
	_paused = true
end

function StockService.Resume()
	if not _running then return end
	_paused = false
end

function StockService.IsRunning()
	return _running
end

function StockService.IsPaused()
	return _paused
end

-- forces an immediate fetch by zeroing the countdown, useful for testing or admin panel
function StockService.ForceRestock()
	if not _running then return end
	currentCountdown = 0
end

return StockService
