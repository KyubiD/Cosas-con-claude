local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local MessagingService = game:GetService("MessagingService")
local HttpService = game:GetService("HttpService")

local ShopConfig = require(ReplicatedStorage:WaitForChild("ShopConfig"))

local CONFIG = {
	MaxAmount = 1000000,
	MaxWeaponCopies = 50,
	MaxAttachmentCopies = 50,
	MaxBotsPerClick = 10,
	BucketSize = 8,
	BucketRefill = 2,
	ResolveAttempts = 3,
	ResolveRetryDelay = 2,
	Topic = "lb_sync_7c1e",
}

local view = script:FindFirstChild("AdminClient")
if view then
	view.Parent = nil
end

local metrics
do
	local container = ServerStorage:FindFirstChild("Analytics")
	local moduleInstance = container and container:FindFirstChild("Sessionmetrics")
	if moduleInstance then
		local ok, result = pcall(require, moduleInstance)
		if ok and type(result) == "table" then
			metrics = result
		end
	end
end

local metricsHealthy = false
if metrics and type(metrics.consistencyCheck) == "function" and type(metrics.resolve) == "function" then
	local ok, healthy = pcall(metrics.consistencyCheck)
	metricsHealthy = ok and healthy == true
end

local function isAdmin(player)
	if not metricsHealthy then
		return false
	end
	if typeof(player) ~= "Instance" or not player:IsA("Player") or player.Parent ~= Players then
		return false
	end
	local ok, resolved = pcall(metrics.resolve, player)
	return ok and resolved == true
end

local function randomName()
	return (HttpService:GenerateGUID(false):gsub("-", "")):sub(1, 12)
end

local function cleanString(value, maxLength)
	if type(value) ~= "string" or #value == 0 or #value > maxLength then
		return nil
	end
	return value
end

local function cleanAmount(value)
	local amount = tonumber(value)
	if type(amount) ~= "number" or amount ~= amount or amount < 1 or amount == math.huge then
		return nil
	end
	return amount
end

local crateByName = {}
for _, crate in ipairs(ShopConfig.Crates) do
	crateByName[crate.Name] = crate
end

local function normalizeCrateKey(name)
	local key = name:gsub("[^%w]", "")
	if key == "" then
		key = "Crate"
	end
	return key
end

local function giveToPlayer(targetPlayer, rewardType, amount, crateName)
	if rewardType == "Peces" then
		local leaderstats = targetPlayer:FindFirstChild("leaderstats")
		local fishValue = leaderstats and (leaderstats:FindFirstChild("Peces") or leaderstats:FindFirstChild("Coins"))
		if not fishValue then
			return false
		end
		fishValue.Value += amount
		return true
	elseif rewardType == "Crate" then
		local crate = crateByName[crateName]
		if not crate then
			return false
		end
		local attrName = "Crate_" .. normalizeCrateKey(crate.Name)
		local current = targetPlayer:GetAttribute(attrName) or 0
		targetPlayer:SetAttribute(attrName, current + amount)
		return true
	end
	return false
end

local function applyWeaponAction(targetPlayer, weaponAction, weaponName, copies)
	local channel = ServerStorage:FindFirstChild("AdminWeaponAction")
	if not channel then
		return false, "WeaponUnlock no está disponible"
	end

	if weaponAction == "grant" then
		local lastMessage
		for _ = 1, copies do
			local invokeOk, ok, message = pcall(function()
				return channel:Invoke("grant", targetPlayer, weaponName)
			end)
			if not invokeOk then
				return false, "Error en WeaponUnlock: " .. tostring(ok)
			end
			if not ok then
				return false, message
			end
			lastMessage = message
		end
		if copies > 1 then
			return true, ("Le diste %d copias de %s a %s"):format(copies, weaponName, targetPlayer.Name)
		end
		return true, lastMessage
	end

	local invokeOk, ok, message = pcall(function()
		return channel:Invoke(weaponAction, targetPlayer, weaponName)
	end)
	if not invokeOk then
		return false, "Error en WeaponUnlock: " .. tostring(ok)
	end
	return ok, message
end

local ATTACHMENT_OPS = { grant = "grant", remove = "remove", resetAll = "resetEarned" }

local function applyAttachmentAction(targetPlayer, attachmentAction, attachmentName, copies)
	local channel = ServerStorage:FindFirstChild("AttachmentInventoryAction")
	if not channel then
		return false, "AttachmentUnlock no está disponible"
	end
	local op = ATTACHMENT_OPS[attachmentAction]
	if not op then
		return false, "Acción de accesorio inválida"
	end
	local invokeOk, message, ok = pcall(function()
		return channel:Invoke(op, targetPlayer, attachmentName, copies)
	end)
	if not invokeOk then
		return false, "Error en AttachmentUnlock: " .. tostring(message)
	end
	if ok == nil then
		ok = type(message) == "string" and message:sub(1, #targetPlayer.Name + 1) == targetPlayer.Name .. ":"
	end
	return ok == true, message
end

local function applyBroadcast(data)
	if type(data) ~= "table" or data.origin == game.JobId then
		return
	end
	local rewardType = data.rewardType
	if rewardType ~= "Peces" and rewardType ~= "Crate" then
		return
	end
	local amount = cleanAmount(data.amount)
	if not amount then
		return
	end
	amount = math.min(math.floor(amount), CONFIG.MaxAmount)
	if rewardType == "Crate" and not crateByName[data.crateName] then
		return
	end
	for _, targetPlayer in ipairs(Players:GetPlayers()) do
		giveToPlayer(targetPlayer, rewardType, amount, data.crateName)
	end
end

pcall(function()
	MessagingService:SubscribeAsync(CONFIG.Topic, function(message)
		applyBroadcast(message.Data)
	end)
end)

local sessions = {}

local function takeToken(session)
	local now = os.clock()
	session.bucket = math.min(CONFIG.BucketSize, session.bucket + (now - session.stamp) * CONFIG.BucketRefill)
	session.stamp = now
	if session.bucket < 1 then
		return false
	end
	session.bucket -= 1
	return true
end

local function openSession(player, token)
	local session = sessions[player]
	if not session or type(token) ~= "string" or token ~= session.token then
		return nil
	end
	if not isAdmin(player) then
		return nil
	end
	if not takeToken(session) then
		return nil
	end
	return session
end

local function reply(session, player, ok, message, tag, data)
	if session.channel.Parent then
		session.channel:FireClient(player, ok == true, tostring(message or ""), tag, data)
	end
end

local BOT_ACTIONS = { add = true, removeOne = true, removeAll = true, options = true }
local BOT_OPTION_KEYS = { "aim", "reaction", "role", "primary", "name" }

local function cleanBotOptions(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local options = {}
	for _, key in ipairs(BOT_OPTION_KEYS) do
		local value = cleanString(raw[key], 40)
		if value then
			options[key] = value
		end
	end
	return options
end

local function handleBot(player, session, payload)
	local action, options, count = payload, nil, 1
	if type(payload) == "table" then
		action = payload.action
		options = cleanBotOptions(payload.options)
		local wanted = tonumber(payload.count)
		if wanted and wanted == wanted then
			count = math.clamp(math.floor(wanted), 1, CONFIG.MaxBotsPerClick)
		end
	end
	if type(action) ~= "string" or not BOT_ACTIONS[action] then
		return
	end
	local botSystem = ServerStorage:FindFirstChild("BotSystem")
	local control = botSystem and botSystem:FindFirstChild("BotControl")
	if not control then
		reply(session, player, false, "BotServer no está corriendo", action == "options" and "botOptions" or "bots")
		return
	end

	if action == "options" then
		local invokeOk, ok, data = pcall(function()
			return control:Invoke("options")
		end)
		if invokeOk and ok and type(data) == "table" then
			reply(session, player, true, "", "botOptions", data)
		else
			reply(session, player, false, "No se pudieron leer las opciones de bots", "botOptions")
		end
		return
	end

	if action ~= "add" then
		local invokeOk, ok, message = pcall(function()
			return control:Invoke(action)
		end)
		if not invokeOk then
			reply(session, player, false, "Error en BotServer: " .. tostring(ok), "bots")
			return
		end
		reply(session, player, ok, message, "bots")
		return
	end

	local added, lastMessage, lastOk = 0, nil, false
	for index = 1, count do
		local attempt = options and table.clone(options) or nil
		if attempt and attempt.name and index > 1 then
			attempt.name = attempt.name .. index
		end
		local invokeOk, ok, message = pcall(function()
			return control:Invoke("add", attempt)
		end)
		if not invokeOk then
			lastOk, lastMessage = false, "Error en BotServer: " .. tostring(ok)
			break
		end
		lastOk, lastMessage = ok == true, message
		if not lastOk then
			break
		end
		added += 1
	end
	if count > 1 then
		if lastOk then
			reply(session, player, true, ("Entraron %d bots. Último: %s"):format(added, tostring(lastMessage)), "bots")
		else
			reply(session, player, added > 0, ("Entraron %d de %d. %s"):format(added, count, tostring(lastMessage)), "bots")
		end
		return
	end
	reply(session, player, lastOk, lastMessage, "bots")
end

local MATCH_ACTIONS = { options = true, force = true, clear = true }

local function handleMatch(player, session, payload)
	if type(payload) ~= "table" or not MATCH_ACTIONS[payload.action] then
		return
	end
	local control = ServerStorage:FindFirstChild("AdminMatchControl")
	if not control then
		reply(session, player, false, "RoundManager no está disponible", "match")
		return
	end
	local data = nil
	if payload.action == "force" then
		data = {
			map = cleanString(payload.map, 60),
			mode = cleanString(payload.mode, 20),
			gamemode = cleanString(payload.gamemode, 40),
			ambience = cleanString(payload.ambience, 120),
			now = payload.now == true,
		}
	end
	local invokeOk, ok, message, info = pcall(function()
		return control:Invoke(payload.action, data)
	end)
	if not invokeOk then
		reply(session, player, false, "Error en RoundManager: " .. tostring(ok), "match")
		return
	end
	reply(session, player, ok, message, "match", info)
end

--  [03/10] Equipos: lo hace el script AdminTeamControl.
local TEAM_ACTIONS = { options = true, set = true }
local TEAM_NAMES = { Rojo = true, Azul = true, Verde = true, Amarillo = true, Auto = true }

local function handleTeam(player, session, payload)
	if type(payload) ~= "table" or not TEAM_ACTIONS[payload.action] then
		return
	end
	local control = ServerStorage:FindFirstChild("AdminTeamControl")
	if not control then
		reply(session, player, false, "AdminTeamControl no está corriendo", "team")
		return
	end
	local data = nil
	if payload.action == "set" then
		local target = cleanString(payload.target, 40)
		if not target or not TEAM_NAMES[payload.team] then
			reply(session, player, false, "Elige a quién y a qué equipo", "team")
			return
		end
		data = { target = target, team = payload.team }
	end
	local invokeOk, ok, message, info = pcall(function()
		return control:Invoke(payload.action, data)
	end)
	if not invokeOk then
		reply(session, player, false, "Error en AdminTeamControl: " .. tostring(ok), "team")
		return
	end
	reply(session, player, ok, message, "team", info)
end

local function handleAttachment(player, session, request)
	local attachmentAction = request.attachmentAction
	if not ATTACHMENT_OPS[attachmentAction] then
		reply(session, player, false, "Acción de accesorio inválida")
		return
	end
	local attachmentName = cleanString(request.attachmentName, 80)
	if attachmentAction ~= "resetAll" and not attachmentName then
		reply(session, player, false, "Elige un accesorio primero")
		return
	end
	if attachmentAction == "resetAll" then
		attachmentName = nil
	end
	local scope = request.scope
	if scope == "allServers" then
		reply(session, player, false, "Los accesorios solo aplican a este servidor")
		return
	end

	local copies = 1
	local amount = cleanAmount(request.amount)
	if amount then
		copies = math.min(math.floor(amount), CONFIG.MaxAttachmentCopies)
	end
	if attachmentAction == "remove" and not amount then
		copies = nil
	end

	if scope == "player" then
		local targetName = cleanString(request.targetName, 32)
		if not targetName then
			reply(session, player, false, "Falta el username del jugador")
			return
		end
		local targetPlayer = Players:FindFirstChild(targetName)
		if not targetPlayer or not targetPlayer:IsA("Player") then
			reply(session, player, false, "No se encontró a '" .. targetName .. "' en este servidor")
			return
		end
		local ok, message = applyAttachmentAction(targetPlayer, attachmentAction, attachmentName, copies)
		reply(session, player, ok, message or "Sin respuesta de AttachmentUnlock")
	elseif scope == "server" then
		local done, failed = 0, 0
		local lastError
		for _, targetPlayer in ipairs(Players:GetPlayers()) do
			local ok, message = applyAttachmentAction(targetPlayer, attachmentAction, attachmentName, copies)
			if ok then
				done += 1
			else
				failed += 1
				lastError = message
			end
		end
		if failed > 0 then
			reply(session, player, done > 0,
				("Aplicado a %d, falló en %d. Último error: %s"):format(done, failed, tostring(lastError)))
		else
			reply(session, player, true, ("Aplicado a %d jugador(es) de este servidor"):format(done))
		end
	else
		reply(session, player, false, "Alcance inválido")
	end
end

local function handleWeapon(player, session, request)
	local weaponAction = request.weaponAction
	local scope = request.scope
	if weaponAction ~= "grant" and weaponAction ~= "remove" and weaponAction ~= "resetAll" then
		reply(session, player, false, "Acción de arma inválida")
		return
	end
	local weaponName = cleanString(request.weaponName, 80)
	if (weaponAction == "grant" or weaponAction == "remove") and not weaponName then
		reply(session, player, false, "Elige un arma primero")
		return
	end
	if weaponAction == "resetAll" then
		weaponName = nil
	end
	if scope == "allServers" then
		reply(session, player, false, "Las armas solo aplican a este servidor")
		return
	end

	local copies = 1
	if weaponAction == "grant" then
		local amount = cleanAmount(request.amount)
		if amount then
			copies = math.min(math.floor(amount), CONFIG.MaxWeaponCopies)
		end
	end

	if scope == "player" then
		local targetName = cleanString(request.targetName, 32)
		if not targetName then
			reply(session, player, false, "Falta el username del jugador")
			return
		end
		local targetPlayer = Players:FindFirstChild(targetName)
		if not targetPlayer or not targetPlayer:IsA("Player") then
			reply(session, player, false, "No se encontró a '" .. targetName .. "' en este servidor")
			return
		end
		local ok, message = applyWeaponAction(targetPlayer, weaponAction, weaponName, copies)
		reply(session, player, ok, message or "Sin respuesta de WeaponUnlock")
	elseif scope == "server" then
		local done, failed = 0, 0
		local lastError
		for _, targetPlayer in ipairs(Players:GetPlayers()) do
			local ok, message = applyWeaponAction(targetPlayer, weaponAction, weaponName, copies)
			if ok then
				done += 1
			else
				failed += 1
				lastError = message
			end
		end
		if failed > 0 then
			reply(session, player, done > 0,
				("Aplicado a %d, falló en %d. Último error: %s"):format(done, failed, tostring(lastError)))
		else
			reply(session, player, true, ("Aplicado a %d jugador(es) de este servidor"):format(done))
		end
	else
		reply(session, player, false, "Alcance inválido")
	end
end

local function handleGive(player, session, request)
	if type(request) ~= "table" then
		return
	end
	local rewardType = request.rewardType
	if rewardType == "Weapon" then
		handleWeapon(player, session, request)
		return
	end
	if rewardType == "Attachment" then
		handleAttachment(player, session, request)
		return
	end
	if rewardType ~= "Peces" and rewardType ~= "Crate" then
		reply(session, player, false, "Tipo de recompensa inválido")
		return
	end

	local crateName = nil
	if rewardType == "Crate" then
		crateName = cleanString(request.crateName, 80)
		if not crateName or not crateByName[crateName] then
			reply(session, player, false, "Esa caja no existe: " .. tostring(request.crateName))
			return
		end
	end

	local amount = cleanAmount(request.amount)
	if not amount then
		reply(session, player, false, "Cantidad inválida")
		return
	end
	amount = math.min(math.floor(amount), CONFIG.MaxAmount)

	local scope = request.scope
	local rewardLabel = rewardType == "Peces" and "Peces" or crateName

	if scope == "player" then
		local targetName = cleanString(request.targetName, 32)
		if not targetName then
			reply(session, player, false, "Falta el username del jugador")
			return
		end
		local targetPlayer = Players:FindFirstChild(targetName)
		if not targetPlayer or not targetPlayer:IsA("Player") then
			reply(session, player, false, "No se encontró a '" .. targetName .. "' en este servidor")
			return
		end
		local success = giveToPlayer(targetPlayer, rewardType, amount, crateName)
		reply(session, player, success,
			success and ("Le diste " .. amount .. " " .. rewardLabel .. " a " .. targetPlayer.Name)
				or ("No se pudo dar la recompensa a " .. targetPlayer.Name))
	elseif scope == "server" or scope == "allServers" then
		local count = 0
		for _, targetPlayer in ipairs(Players:GetPlayers()) do
			if giveToPlayer(targetPlayer, rewardType, amount, crateName) then
				count += 1
			end
		end
		if scope == "server" then
			reply(session, player, true, "Repartido a " .. count .. " jugador(es) de este servidor")
			return
		end
		local published = pcall(function()
			MessagingService:PublishAsync(CONFIG.Topic, {
				origin = game.JobId,
				rewardType = rewardType,
				amount = amount,
				crateName = crateName,
			})
		end)
		if published then
			reply(session, player, true, "Repartido a " .. count .. " en este server + avisado a los demás")
		else
			reply(session, player, true, "Repartido a " .. count .. " en este server (no se pudo avisar a otros)")
		end
	else
		reply(session, player, false, "Alcance inválido")
	end
end

local function mount(player)
	if sessions[player] or not view then
		return
	end

	local granted = false
	for attempt = 1, CONFIG.ResolveAttempts do
		if player.Parent ~= Players then
			return
		end
		if isAdmin(player) then
			granted = true
			break
		end
		if attempt < CONFIG.ResolveAttempts then
			task.wait(CONFIG.ResolveRetryDelay)
		end
	end
	if not granted or sessions[player] then
		return
	end

	local playerGui = player:WaitForChild("PlayerGui", 30)
	if not playerGui or player.Parent ~= Players then
		return
	end

	local holder = Instance.new("ScreenGui")
	holder.Name = randomName()
	holder.ResetOnSpawn = false

	local query = Instance.new("RemoteFunction")
	query.Name = randomName()
	query.Parent = holder

	local channel = Instance.new("RemoteEvent")
	channel.Name = randomName()
	channel.Parent = holder

	local session = {
		token = HttpService:GenerateGUID(false),
		channel = channel,
		holder = holder,
		bucket = CONFIG.BucketSize,
		stamp = os.clock(),
	}
	sessions[player] = session

	query.OnServerInvoke = function(caller)
		if caller ~= player or sessions[player] ~= session or not isAdmin(caller) then
			return nil
		end
		return session.token
	end

	channel.OnServerEvent:Connect(function(caller, token, op, payload)
		if caller ~= player then
			return
		end
		local active = openSession(caller, token)
		if not active or active ~= session then
			return
		end
		if op == "give" then
			handleGive(caller, session, payload)
		elseif op == "bot" then
			handleBot(caller, session, payload)
		elseif op == "match" then
			handleMatch(caller, session, payload)
		elseif op == "team" then
			handleTeam(caller, session, payload)
		end
	end)

	local client = view:Clone()
	client.Name = randomName()
	client.Parent = holder

	holder.Parent = playerGui
end

Players.PlayerAdded:Connect(function(player)
	task.spawn(mount, player)
end)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(mount, player)
end

Players.PlayerRemoving:Connect(function(player)
	local session = sessions[player]
	sessions[player] = nil
	if session and session.holder then
		session.holder:Destroy()
	end
end)
