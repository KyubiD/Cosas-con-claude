--==========================================================================
--  AdminTeamControl  —  Script (ServerScriptService)  [03/10/2026]
--
--  Equipos desde el panel de admin (F4 > EQUIPOS), para jugadores y bots:
--    · FIJAR un equipo: queda guardado en el atributo ForcedTeam. Si esta
--      en la ronda se cambia YA; si no, entra a ese equipo la proxima vez
--      que entre (el RoundManager le da uno y aqui se corrige al instante).
--    · AUTO: le quita lo fijado (el RoundManager vuelve a repartir).
--  No toca el RoundManager: cambia el equipo igual que el (player.Team y
--  el atributo RoundTeam a la vez), asi que todo lo que lee el equipo
--  (danos entre equipos, bots, Control, marcadores) lo ve igual.
--
--  Reglas para no romper nada:
--    · Solo se aplica si ese equipo existe en la partida (Verde / Amarillo
--      solo con 4 equipos). Si no existe, queda fijado para despues.
--    · En FFA no hay equipos: se guarda, pero no se aplica.
--    · El lider del Guardian no se cambia (su equipo se quedaria sin lider).
--
--  ServerStorage.AdminTeamControl (BindableFunction), lo usa AdminServer:
--    Invoke("options")                          -> ok, msg, info
--    Invoke("set", { target = ..., team = ...}) -> ok, msg, info
--      target: nombre exacto, "*bots", "*players" o "*all"
--      team:   "Rojo", "Azul", "Verde", "Amarillo" o "Auto"
--==========================================================================

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Teams = game:GetService("Teams")

local ALL_TEAMS = { "Rojo", "Azul", "Verde", "Amarillo" }
local TEAM_SETS = {
	["2 Teams"] = { "Rojo", "Azul" },
	["4 Teams"] = { "Rojo", "Azul", "Verde", "Amarillo" },
}

local state = ReplicatedStorage:WaitForChild("RoundSystem"):WaitForChild("State")
local phaseValue = state:WaitForChild("Phase")
local modeValue = state:WaitForChild("WinningMode")

local Registry = nil
pcall(function()
	local botSystem = ServerStorage:WaitForChild("BotSystem", 10)
	Registry = botSystem and require(botSystem:WaitForChild("BotRegistry", 10)) or nil
end)

local function participants()
	if Registry and Registry.participants then
		local ok, list = pcall(Registry.participants)
		if ok and type(list) == "table" then return list end
	end
	return Players:GetPlayers()
end

local function isBot(participant)
	if Registry and Registry.isBot then
		local ok, result = pcall(Registry.isBot, participant)
		if ok then return result == true end
	end
	return not (typeof(participant) == "Instance" and participant:IsA("Player"))
end

local function inMatch()
	local phase = phaseValue.Value
	return phase == "Round" or phase == "Ready"
end

--  Equipos de la partida en curso (nil = FFA o no hay partida).
local function currentTeams()
	if not inMatch() then return nil end
	return TEAM_SETS[modeValue.Value]
end

local function validNow(teamName)
	local list = currentTeams()
	return list ~= nil and table.find(list, teamName) ~= nil
end

--  Cambia el equipo como lo hace el RoundManager (Team + RoundTeam juntos).
local function moveTo(participant, teamName)
	local team = Teams:FindFirstChild(teamName)
	if not team then return false, "No existe el equipo " .. teamName end
	if participant:GetAttribute("GuardianLeader") == true and participant:GetAttribute("RoundTeam") ~= teamName then
		return false, participant.Name .. " es lider del Guardian: no se cambia"
	end
	local ok, err = pcall(function()
		participant.Team = team
		participant.Neutral = false
		participant:SetAttribute("RoundTeam", teamName)
	end)
	if not ok then return false, tostring(err) end
	return true
end

--  Si tiene equipo fijado y el RoundManager le dio otro, se corrige.
local function enforce(participant)
	local forced = participant:GetAttribute("ForcedTeam")
	if type(forced) ~= "string" or forced == "" then return end
	local current = participant:GetAttribute("RoundTeam")
	if participant:GetAttribute("InRound") ~= true and not (current and current ~= "Lobby") then return end
	if current == forced or not validNow(forced) then return end
	moveTo(participant, forced)
end

local watched = setmetatable({}, { __mode = "k" })
local function watch(participant)
	if watched[participant] or typeof(participant) ~= "Instance" and type(participant) ~= "table" then return end
	watched[participant] = true
	pcall(function()
		participant:GetAttributeChangedSignal("RoundTeam"):Connect(function()
			task.defer(enforce, participant)
		end)
		participant:GetAttributeChangedSignal("InRound"):Connect(function()
			task.defer(enforce, participant)
		end)
	end)
end

--  Jugadores y bots nuevos (los bots no disparan PlayerAdded).
Players.PlayerAdded:Connect(watch)
task.spawn(function()
	while true do
		for _, participant in ipairs(participants()) do watch(participant) end
		task.wait(2)
	end
end)

local function describe()
	local people = {}
	for _, participant in ipairs(participants()) do
		table.insert(people, {
			name = participant.Name,
			bot = isBot(participant),
			team = participant:GetAttribute("RoundTeam") or "",
			forced = participant:GetAttribute("ForcedTeam") or "",
			inRound = participant:GetAttribute("InRound") == true,
		})
	end
	table.sort(people, function(a, b)
		if a.bot ~= b.bot then return not a.bot end
		return a.name:lower() < b.name:lower()
	end)
	return {
		phase = phaseValue.Value,
		mode = inMatch() and modeValue.Value or "",
		teams = currentTeams() or {},
		people = people,
	}
end

local function targetsFor(target)
	local list = {}
	for _, participant in ipairs(participants()) do
		local bot = isBot(participant)
		if target == "*all" or (target == "*bots" and bot) or (target == "*players" and not bot)
			or (type(target) == "string" and participant.Name:lower() == target:lower()) then
			table.insert(list, participant)
		end
	end
	return list
end

local function setTeam(data)
	if type(data) ~= "table" then return false, "Datos invalidos" end
	local target, teamName = data.target, data.team
	if type(target) ~= "string" or target == "" then return false, "Elige a quien" end
	if teamName ~= "Auto" and not table.find(ALL_TEAMS, teamName) then return false, "Equipo invalido" end
	local list = targetsFor(target)
	if #list == 0 then return false, "No se encontro a " .. target end

	local moved, saved, failed, lastError = 0, 0, 0, nil
	for _, participant in ipairs(list) do
		if teamName == "Auto" then
			participant:SetAttribute("ForcedTeam", nil)
			saved += 1
		else
			participant:SetAttribute("ForcedTeam", teamName)
			watch(participant)
			saved += 1
			local inGame = participant:GetAttribute("InRound") == true
			if inGame and validNow(teamName) and participant:GetAttribute("RoundTeam") ~= teamName then
				local ok, err = moveTo(participant, teamName)
				if ok then moved += 1 else failed += 1; lastError = err end
			end
		end
	end

	local who = (#list == 1) and list[1].Name or (#list .. " participantes")
	if teamName == "Auto" then
		return true, who .. ": equipo automatico (lo reparte el RoundManager)"
	end
	local message = ("%s: fijado en %s"):format(who, teamName)
	if moved > 0 then message ..= (" · %d cambiado(s) ya"):format(moved) end
	if inMatch() and not currentTeams() then
		message ..= " · esta partida es FFA: se aplica en la proxima con equipos"
	elseif inMatch() and not validNow(teamName) then
		message ..= " · en esta partida no existe " .. teamName .. ": se aplica cuando haya 4 equipos"
	elseif not inMatch() then
		message ..= " · entra a ese equipo en la proxima partida"
	end
	if failed > 0 then message ..= (" · %d no: %s"):format(failed, tostring(lastError)) end
	return failed == 0 or moved > 0, message
end

local control = ServerStorage:FindFirstChild("AdminTeamControl")
if not control then
	control = Instance.new("BindableFunction")
	control.Name = "AdminTeamControl"
	control.Parent = ServerStorage
end
control.OnInvoke = function(action, data)
	if action == "options" then
		return true, "", describe()
	elseif action == "set" then
		local ok, message = setTeam(data)
		return ok, message, describe()
	end
	return false, "Accion desconocida: " .. tostring(action)
end
