--==========================================================================
--  RoundManager  —  VERSION PARCHEADA (01/09/2026)
--  Base: "RoundManager 01092026"
--
--  Se conserva tu cambio de setPlayerTeam(), que ahora escribe el atributo
--  RoundTeam junto con el Team para que no puedan desincronizarse.
--
--  Parches aplicados:
--    F-17 [MEDIO]  El "while true do" del final no tenia proteccion. Si
--                  getMaps(), prepareRound o un teleport lanzaban un error
--                  (un mapa borrado, un jugador que se fue a mitad del
--                  teleport), el hilo moria y el servidor se quedaba SIN
--                  RONDAS hasta que alguien lo reiniciara, sin mensaje
--                  claro de por que. Ahora el ciclo esta envuelto en pcall
--                  y se recupera solo.
--
--    F-18 [MEDIO]  roundPlayers no se limpiaba en PlayerRemoving: si un
--                  jugador se iba a mitad de ronda, su objeto Player
--                  quedaba retenido hasta el final de la ronda.
--
--    F-05          Los print de diagnostico pasan por dprint().
--
--  Extras (marcados [EXTRA]):
--    · broadcastState() llamaba a getMaps() —que a su vez llama a
--      getMapSource() con media docena de FindFirstChild y a veces un
--      GetChildren completo— UNA VEZ POR SEGUNDO durante toda la partida,
--      solo para construir el conteo de votos. Ahora hay un cache con
--      TTL corto.
--    · resetPlayerForLobby() hacia Health = 0 y LoadCharacter() casi en el
--      mismo frame, sin guard: dos llamadas seguidas podian cargar dos
--      personajes. Reusa el guard RoundCharacterLoading que ya existia.
--
--  [26/09/2026] Mapa Prision (con sus spawns Spawn_Prision) y modo de juego
--  Control (mantener el AreaObjetivo del mapa; ver la seccion CONTROL).
--==========================================================================

local DEBUG = false
local function dprint(...)
	if DEBUG then print(...) end
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local ServerStorage = game:GetService("ServerStorage")
local Teams = game:GetService("Teams")
local RunService = game:GetService("RunService")

--==========================================================================
--  [BOTS 23/09/2026] JUGADORES FALSOS
--
--  Los bots (ServerStorage.BotSystem) son "proxies" que se comportan como
--  un Player: tienen Name, UserId, Team, Character, atributos... Asi que
--  este script les aplica EXACTAMENTE las mismas reglas que a cualquiera
--  (equipos, vidas, eliminacion, Guardian, duelo) sin codigo aparte.
--
--  Lo unico que cambia: donde las reglas de la partida recorrian
--  Players:GetPlayers(), ahora recorren participants() = jugadores + bots.
--  Donde de verdad importa que haya personas ("no queda nadie en el
--  servidor") se sigue usando Players:GetPlayers().
--==========================================================================
local Bots = nil
pcall(function()
	local botSystem = ServerStorage:WaitForChild("BotSystem", 5)
	Bots = botSystem and require(botSystem:WaitForChild("BotRegistry", 5)) or nil
end)
if not Bots then
	warn("[RoundManager] No se encontro BotSystem.BotRegistry: los bots no van a entrar a las rondas")
end

local function participants()
	if Bots then return Bots.participants() end
	return Players:GetPlayers()
end

local function isBot(player)
	return Bots ~= nil and Bots.isBot(player)
end

local system = ReplicatedStorage:WaitForChild("RoundSystem")
local state = system:WaitForChild("State")
local voteEvent = system:WaitForChild("Vote")
local playEvent = system:WaitForChild("Play")
local leaveEvent = system:WaitForChild("LeaveRound")
local stateChanged = system:WaitForChild("StateChanged")
local loadoutRemotes = ReplicatedStorage:WaitForChild("Remotes")
local forceEquipRoundLoadout = loadoutRemotes:WaitForChild("ForceEquipRoundLoadout")

local workspaceMaps = Workspace:FindFirstChild("Maps")
local serverMaps = ServerStorage:FindFirstChild("Maps")
local lobby = Workspace:WaitForChild("Lobby")
local lobbySpawns = lobby:WaitForChild("Spawns")
local lobbySpawn = lobbySpawns:WaitForChild("LobbySpawn")
local lobbyPlatform = lobby:FindFirstChild("LobbyPlatform", true)

local VOTE_DURATION = 15
local ROUND_DURATION = 300
local modes = {"FFA", "2 Teams", "4 Teams"}

--==========================================================================
--  [12/09/2026] BOLETA DE MAPAS + PANELES NUEVOS
--
--  MAPAS: aunque haya N mapas instalados, en cada votacion solo se ofrecen
--  MAP_BALLOT_SIZE, sorteados al azar. El sorteo vive ACA y no en el
--  cliente: si cada jugador barajara su propia terna estarian votando
--  listas distintas y los conteos no cuadrarian con nada.
--
--  AMBIENTES: misma logica de boleta. Las reglas de cada uno viven en el
--  modulo AmbienceConfig y las aplica AmbienceServer; aca solo esta la
--  lista de los que se pueden votar.
--
--  El ganador de cada categoria queda en los atributos WinningGamemode y
--  WinningAmbience del folder State, que es de donde los leen los demas
--  sistemas (AmbienceServer, MatchStatsServer, el marcador).
--==========================================================================
local MAP_BALLOT_SIZE = 3

--  Igual que los mapas: aunque haya 15 ambientes registrados, en cada
--  votacion solo se ofrecen 3 sorteados.
local AMBIENCE_BALLOT_SIZE = 3

--  [22/09/2026 Ejecucion] La lista y las reglas salen de GamemodeConfig.
--  Si el modulo faltara, queda el respaldo de abajo (Arcade + Eliminacion).
local gamemodes = {"Arcade", "Eliminacion"}

--  Las claves van SIN acentos a proposito: viajan como nombre de opcion
--  en los votos y como valor del atributo WinningAmbience, y ahi los
--  acentos ya nos mordieron antes. El nombre bonito se pone en
--  AmbienceConfig.Presets[clave].Label.
--  Cada clave tiene que existir en AmbienceConfig.Presets. Son 15, y en
--  cada votacion se sortean AMBIENCE_BALLOT_SIZE de estas.
--  La lista NO se escribe aca. AmbienceConfig genera las combinaciones
--  (3 horas x 4 climas x con/sin niebla = 24) y exporta AmbienceConfig.Keys
--  ya ordenada. Copiarlas a mano era pedir que se desincronicen: una clave
--  mal escrita se vota igual pero despues no aplica ningun ambiente.
--
--  Con pcall porque el RoundManager tiene que arrancar aunque falte el
--  modulo; en ese caso el panel de AMBIENTE queda vacio y nada mas.
local ambiences = {}
local DEFAULT_AMBIENCE = nil
--  [22/09/2026] Especiales (Ventisca): no van en la lista normal. En cada
--  votacion tiran su BallotChance y, si sale, uno de ellos reemplaza a
--  una de las 3 opciones sorteadas. Nunca mas de un especial por boleta.
local specialAmbiences = {}			-- { { chance = 0.25, keys = {...} } }
--  [22/09] Que mapas admite cada especial: [clave] = { maps, fallback }
--  (va colgado de la misma tabla para no sumar locals al chunk).
specialAmbiences.byKey = {}
do
	local ok, config = pcall(function()
		return require(ReplicatedStorage:WaitForChild("AmbienceConfig", 10))
	end)
	if ok and config then
		ambiences = config.Keys or {}
		DEFAULT_AMBIENCE = config.Default
		--  [22/09 Huracan] Grupos: cada especial solo y cada combo (Huracan +
		--  Ventisca). Vienen ordenados con los combos primero, asi el combo
		--  tira su dado antes que los sueltos. Mapas y respaldo salen de
		--  specialFor, que ya junta los de un combo (mapas = los que admiten
		--  todos).
		for _, group in ipairs(config.SpecialGroups or {}) do
			if #group.keys > 0 then
				table.insert(specialAmbiences, { chance = tonumber(group.chance) or 0, keys = group.keys })
				local merged = config.specialFor(group.keys[1])
				for _, key in ipairs(group.keys) do
					specialAmbiences.byKey[key] = {
						maps = merged and merged.Maps,
						fallback = (merged and merged.FallbackAmbience) or config.Default,
					}
				end
			end
		end
	else
		warn("[RoundManager] Falta AmbienceConfig: el panel de AMBIENTE va a salir vacio")
	end
end

--==========================================================================
--  [12/09/2026] REGLAS POR MODO DE JUEGO
--
--  Lives = 0 significa vidas infinitas (el respawn normal de Roblox).
--  Lives = 2 es la vida con la que entras + UN respawn: a la segunda
--  muerte quedas fuera hasta que termine la ronda.
--
--  Las vidas se llevan en una tabla del servidor (roundLives), NO en un
--  atributo suelto: si solo estuvieran en el atributo, salir con M y
--  volver a entrar te las resetearia.
--==========================================================================
--  [26/09/2026] CONTROL: reglas de respaldo (las de verdad estan en
--  GamemodeConfig.Modes.Control; estas solo se usan si el modulo no lo
--  trae). El resto de la seccion esta mas abajo.
local Control = { part = nil, scores = {}, saved = nil }
Control.DEFAULT_RULES = {
	Label = "Control",
	Duration = 600,				-- 10 min
	Lives = 0,					-- reaparicion normal
	JoinWindow = 0,
	ForceTeams = "2 Teams",		-- por equipos: si la votacion dio FFA, 2 equipos
	RequiresPart = "AreaObjetivo",	-- sin esta pieza en el mapa se juega Arcade
	Control = {
		PointsPerSecond = 1,	-- por cada jugador de ventaja dentro del area
		ScoreLimit = 0,			-- > 0: gana el primero que llega (0 = solo tiempo)
	},
}

--  [22/09/2026] Las reglas viven ahora en ReplicatedStorage.GamemodeConfig
--  (las lee tambien DownedServer para Ejecucion). Esta tabla es solo el
--  respaldo por si el modulo no carga.
local GAMEMODE_RULES = {
	Arcade = {
		Duration = 300,
		Lives = 0,
		EndWhenOneLeft = false,
		JoinWindow = 0,
	},
	Eliminacion = {
		Duration = 900,
		Lives = 2,
		EndWhenOneLeft = true,
		EliminationDelay = 4.5,
		GraceSeconds = 15,
		JoinWindow = 15,
		MinPlayers = 2,
	},
}
local DEFAULT_GAMEMODE = "Arcade"
do
	local ok, config = pcall(function()
		return require(ReplicatedStorage:WaitForChild("GamemodeConfig", 10))
	end)
	if ok and type(config) == "table" and type(config.Modes) == "table" then
		GAMEMODE_RULES = config.Modes
		DEFAULT_GAMEMODE = config.Default or DEFAULT_GAMEMODE
		if type(config.Order) == "table" and #config.Order > 0 then
			gamemodes = config.Order
		end
	else
		warn("[RoundManager] Falta GamemodeConfig: solo Arcade y Eliminacion con reglas de respaldo")
	end
end
--  [26/09] Control entra a la lista de modos aunque GamemodeConfig todavia
--  no lo tenga (la tabla del modulo es la misma para todos los scripts del
--  servidor, asi DownedServer / CorpseServer / BotServer tambien lo ven).
if not GAMEMODE_RULES.Control then GAMEMODE_RULES.Control = Control.DEFAULT_RULES end
if not table.find(gamemodes, "Control") then table.insert(gamemodes, "Control") end

local function rulesFor(name)
	return GAMEMODE_RULES[name] or GAMEMODE_RULES[DEFAULT_GAMEMODE]
end

--  Duracion de la ronda segun el modo (Eliminacion/Ejecucion = 15 min).
local function roundDurationFor(name)
	return tonumber(rulesFor(name).Duration) or ROUND_DURATION
end
local mapAliases = {
	Casa = "Führer house",
	Subterraneo = "Metro",
	Plaza = "Plaza",
	Brutalist = "Brutalist",
	TestMap = "TestMap",
	Prision = "Prision",		-- [26/09]
}
local forcedMapNames = {
	Metro = "Subterraneo",
	Plaza = "Plaza",
	Brutalist = "Brutalist",
	["Führer house"] = "Casa",
	TestMap = "TestMap",
	Prision = "Prision",		-- [26/09]
}
local phase = "Lobby"
local mapVotes = {}
local modeVotes = {}
local gamemodeVotes = {}
local ambienceVotes = {}
local mapBallot = {}
local ambienceBallot = {}
local currentMap
local currentMode
local currentGamemode = DEFAULT_GAMEMODE
local roundLives = {}					-- [userId] = vidas que le quedan
local eliminatedPlayers = {}			-- [userId] = true
local peakRoundPlayers = 0				-- maximo de gente que hubo en la ronda
local activeRoundSpawns = {}
local roundPlayers = {}
local pendingMapName
local pendingModeName
local pendingGamemodeName
--  [22/09] Ventana de entrada: os.clock() en que se cierra el JOIN para
--  los que no entraron a ESTA ronda. 0 = sin limite (Arcade).
local joinClosesClock = 0
--  [22/09 Duelo por vidas] Reapariciones compartidas por equipo:
--  lives[equipo] = las que le quedan; lastTeam[userId] = equipo con el que
--  jugo esta ronda (para volver al mismo si sale con M). Una sola tabla
--  para no sumar locals.
local TeamLifePool = { lives = {}, lastTeam = {} }
--  [22/09] Boleta de MODOS DE JUEGO: como los mapas, en cada votacion se
--  ofrecen solo GAMEMODE_BALLOT_SIZE sorteados de todos los de la lista.
local GAMEMODE_BALLOT_SIZE = 3
local gamemodeBallot = {}

--==========================================================================
--  [22/09/2026] GUARDIAN
--
--  leaders[equipo] = Player lider; alive[equipo] = true (vivo), false
--  (cayo o se fue) o nil (todavia no se eligio). token invalida la
--  eleccion programada de una ronda anterior.
--
--  Se publica en State: GuardianLeader_<Equipo> (UserId), GuardianAlive_
--  <Equipo> y TeamStanding_<Equipo> (para el podio). Y en cada jugador:
--  GuardianLeader (el cliente lo marca con Highlight) y RestrictedSlots
--  (LoadoutServer no le entrega esos slots).
--==========================================================================
local Guardian = { leaders = {}, alive = {}, picked = false, token = 0 }

function Guardian.stripRestricted(player)
	local text = player:GetAttribute("RestrictedSlots")
	if type(text) ~= "string" or text == "" then return end
	local blocked = {}
	for slot in string.gmatch(text, "[^,]+") do blocked[slot] = true end
	for _, container in ipairs({ player:FindFirstChildOfClass("Backpack"), player.Character }) do
		if container then
			for _, item in ipairs(container:GetChildren()) do
				if item:IsA("Tool") and blocked[item:GetAttribute("WeaponCategory")] then
					item:Destroy()
				end
			end
		end
	end
end

function Guardian.publish()
	for _, teamName in ipairs({ "Rojo", "Azul", "Verde", "Amarillo" }) do
		local leader = Guardian.leaders[teamName]
		state:SetAttribute("GuardianLeader_" .. teamName, leader and leader.UserId or nil)
		state:SetAttribute("GuardianAlive_" .. teamName, Guardian.alive[teamName])
	end
end

function Guardian.reset()
	Guardian.leaders = {}
	Guardian.alive = {}
	Guardian.picked = false
	Guardian.token += 1
	for _, teamName in ipairs({ "Rojo", "Azul", "Verde", "Amarillo" }) do
		state:SetAttribute("TeamStanding_" .. teamName, nil)
	end
	Guardian.publish()
	for _, player in ipairs(participants()) do
		player:SetAttribute("GuardianLeader", nil)
		player:SetAttribute("RestrictedSlots", nil)
	end
end

--  El lider recupera su loadout completo (armas largas incluidas).
function Guardian.setLeader(teamName, player)
	Guardian.leaders[teamName] = player
	Guardian.alive[teamName] = true
	player:SetAttribute("GuardianLeader", true)
	player:SetAttribute("RestrictedSlots", nil)
	Guardian.publish()
	task.defer(function()
		--  [BOTS 23/09] El bot no tiene loadout: lee RestrictedSlots solo.
		if player.Parent and player:GetAttribute("InRound") == true and not isBot(player) then
			forceEquipRoundLoadout:Fire(player)
		end
	end)
	dprint("[RoundManager] Guardian:", player.Name, "es el lider de", teamName)
end

local teamByName = {}
for _, teamName in ipairs({"Lobby", "Neutral", "Rojo", "Azul", "Verde", "Amarillo"}) do
	local team = Teams:FindFirstChild(teamName)
	if team and team:IsA("Team") then
		teamByName[teamName] = team
	else
		warn("[RoundManager] Equipo no encontrado: " .. teamName)
	end
end

local function setPlayerTeam(player, teamName)
	local team = teamByName[teamName]
	if not team then return false end
	player.Team = team
	player.Neutral = false
	-- Fuente unica de verdad: el atributo SIEMPRE viaja con el Team.
	-- Asi no hay forma de desincronizarlos por olvido al agregar
	-- autobalanceo, comandos de admin o cambio manual de equipo.
	player:SetAttribute("RoundTeam", teamName ~= "Lobby" and teamName or nil)
	return true
end

local function getRoundTeamNames(modeName)
	if modeName == "2 Teams" then
		return {"Rojo", "Azul"}
	elseif modeName == "4 Teams" then
		return {"Rojo", "Azul", "Verde", "Amarillo"}
	end
	return {"Neutral"}
end

local function getBalancedRoundTeam(modeName, excludedPlayer)
	local availableTeams = getRoundTeamNames(modeName)
	local counts = {}
	for _, teamName in ipairs(availableTeams) do counts[teamName] = 0 end
	for _, player in ipairs(participants()) do
		if player ~= excludedPlayer and roundPlayers[player] == true then
			local teamName = player:GetAttribute("RoundTeam")
			if counts[teamName] ~= nil then counts[teamName] += 1 end
		end
	end
	local selectedTeam = availableTeams[1]
	for _, teamName in ipairs(availableTeams) do
		if counts[teamName] < counts[selectedTeam] then selectedTeam = teamName end
	end
	return selectedTeam
end

--==========================================================================
--  [22/09/2026] DUELO POR VIDAS: reapariciones compartidas por equipo
--
--  Se publican en State como TeamLives_<Equipo> (y TeamLivesMax) para que
--  los lean el reloj de la partida (StartMenu), el marcador y el podio
--  (MatchStatsServer). Se limpian al arrancar el ciclo siguiente, NO al
--  terminar la ronda: el podio los lee justo despues de que termina.
--==========================================================================
local function teamLivesPerTeam(name)
	return tonumber(rulesFor(name or currentGamemode).TeamLives) or 0
end

local function publishTeamLives()
	for _, teamName in ipairs({"Rojo", "Azul", "Verde", "Amarillo"}) do
		state:SetAttribute("TeamLives_" .. teamName, TeamLifePool.lives[teamName])
	end
end

local function resetTeamLives(active)
	TeamLifePool.lives = {}
	TeamLifePool.lastTeam = {}
	local per = active and teamLivesPerTeam() or 0
	if per > 0 then
		for _, teamName in ipairs(getRoundTeamNames(currentMode)) do
			if teamName ~= "Neutral" then TeamLifePool.lives[teamName] = per end
		end
	end
	state:SetAttribute("TeamLivesMax", per > 0 and per or nil)
	publishTeamLives()
end

--  Equipo mas chico de los que todavia tienen reapariciones (nil si no
--  queda ninguno: no tiene sentido meter a alguien a un equipo muerto).
local function pickTeamWithLives(excludedPlayer)
	local counts = {}
	for teamName, pool in pairs(TeamLifePool.lives) do
		if pool > 0 then counts[teamName] = 0 end
	end
	for _, other in ipairs(participants()) do
		if other ~= excludedPlayer and roundPlayers[other] == true then
			local teamName = other:GetAttribute("RoundTeam")
			if counts[teamName] ~= nil then counts[teamName] += 1 end
		end
	end
	local best = nil
	for _, teamName in ipairs(getRoundTeamNames(currentMode)) do
		if counts[teamName] ~= nil and (best == nil or counts[teamName] < counts[best]) then
			best = teamName
		end
	end
	return best
end

local function assignRoundTeams(modeName)
	local players = participants()
	table.sort(players, function(a, b) return a.UserId < b.UserId end)
	for _, player in ipairs(players) do
		local selectedTeam = getBalancedRoundTeam(modeName, player)
		setPlayerTeam(player, selectedTeam)
		roundPlayers[player] = true
	end
end

local function displayMapName(name)
	for displayName, internalName in pairs(mapAliases) do
		if name == internalName then return displayName end
	end
	return name
end

local function getMapSource()
	if ServerStorage:FindFirstChild("Metro") or ServerStorage:FindFirstChild("Plaza") or ServerStorage:FindFirstChild("Brutalist") or ServerStorage:FindFirstChild("TestMap") or ServerStorage:FindFirstChild("Prision") then
		return ServerStorage
	end
	if serverMaps and (serverMaps:FindFirstChild("Metro") or serverMaps:FindFirstChild("Plaza") or serverMaps:FindFirstChild("Brutalist") or serverMaps:FindFirstChild("TestMap") or serverMaps:FindFirstChild("Prision")) then
		return serverMaps
	end
	if workspaceMaps then
		for _, name in ipairs({"Führer house", "Metro", "Brutalist", "Plaza", "TestMap", "Prision"}) do
			if workspaceMaps:FindFirstChild(name) then return workspaceMaps end
		end
		if workspaceMaps:FindFirstChild("Map_1") then return workspaceMaps end
	end
	if Workspace:FindFirstChild("Führer house") or Workspace:FindFirstChild("Metro") or Workspace:FindFirstChild("Brutalist") or Workspace:FindFirstChild("Plaza") or Workspace:FindFirstChild("TestMap") or Workspace:FindFirstChild("Prision") then
		return Workspace
	end
	return serverMaps or workspaceMaps
end

local function scanMaps()
	local source = getMapSource()
	local result = {}
	if not source then return result end
	for _, name in ipairs({"Führer house", "Metro", "Brutalist", "Plaza", "TestMap", "Prision"}) do
		if source:FindFirstChild(name) then table.insert(result, name) end
	end
	if #result == 0 then
		for _, map in ipairs(source:GetChildren()) do
			if (map:IsA("Folder") or map:IsA("Model")) and map.Name ~= "Spawns" and map.Name ~= "Lobby" then
				table.insert(result, map.Name)
			end
		end
	end
	table.sort(result)
	return result
end

--  [EXTRA] getMaps() se llamaba desde broadcastState() una vez por segundo
--  durante toda la partida, y cada llamada rehace getMapSource() entero.
--  La lista de mapas no cambia en mitad de una ronda: cache con TTL corto.
local mapsCache = nil
local mapsCacheAt = 0
local MAPS_CACHE_TTL = 5

local function getMaps(forceRefresh)
	local now = os.clock()
	if forceRefresh or not mapsCache or (now - mapsCacheAt) > MAPS_CACHE_TTL then
		mapsCache = scanMaps()
		mapsCacheAt = now
	end
	return mapsCache
end

--  Baraja una COPIA y se queda con los primeros `size`. Siempre copia:
--  scanMaps() devuelve la misma tabla del cache en cada llamada, y
--  barajarla ahi adentro la dejaria revuelta para todos.
local function pickBallot(pool, size)
	local shuffled = table.clone(pool)
	for i = #shuffled, 2, -1 do
		local j = math.random(1, i)
		shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
	end
	local picked = {}
	for i = 1, math.min(size, #shuffled) do
		picked[i] = shuffled[i]
	end
	table.sort(picked)
	return picked
end

local function rollMapBallot()
	mapBallot = pickBallot(getMaps(true), MAP_BALLOT_SIZE)
	return mapBallot
end

local function rollAmbienceBallot()
	ambienceBallot = pickBallot(ambiences, AMBIENCE_BALLOT_SIZE)

	--  Especiales: el primero que gane su tirada entra y listo.
	if #ambienceBallot > 0 then
		for _, special in ipairs(specialAmbiences) do
			if math.random() < special.chance then
				local key = special.keys[math.random(1, #special.keys)]
				ambienceBallot[math.random(1, #ambienceBallot)] = key
				table.sort(ambienceBallot)
				dprint("[RoundManager] Salio ambiente especial en la boleta:", key)
				break
			end
		end
	end
	return ambienceBallot
end

--  La boleta vigente. Si todavia no se sorteo ninguna (arranque en frio,
--  un broadcast antes del primer ciclo) se sortea una al vuelo.
local function getMapBallot()
	if #mapBallot == 0 then rollMapBallot() end
	return mapBallot
end

local function getAmbienceBallot()
	if #ambienceBallot == 0 then rollAmbienceBallot() end
	return ambienceBallot
end

--  [22/09] Terna de modos de juego (3 al azar, como los mapas).
local function rollGamemodeBallot()
	gamemodeBallot = pickBallot(gamemodes, GAMEMODE_BALLOT_SIZE)
	return gamemodeBallot
end

local function getGamemodeBallot()
	if #gamemodeBallot == 0 then rollGamemodeBallot() end
	return gamemodeBallot
end

local function getMap(name)
	local source = getMapSource()
	return source and source:FindFirstChild(name) or nil
end

local function getVoteCounts(votes, options)
	local counts = {}
	for _, option in ipairs(options) do counts[option] = 0 end
	for _, choice in pairs(votes) do
		if counts[choice] ~= nil then counts[choice] += 1 end
	end
	return counts
end

local function broadcastState(timeLeft)
	local mapOptions = getMapBallot()		-- solo los 3 sorteados, no todos
	local displayedMapCounts = {}
	local internalMapCounts = getVoteCounts(mapVotes, mapOptions)
	for _, mapName in ipairs(mapOptions) do
		local displayName = forcedMapNames[mapName] or displayMapName(mapName)
		displayedMapCounts[displayName] = internalMapCounts[mapName] or 0
	end
	stateChanged:FireAllClients(
		phase,
		timeLeft,
		state.WinningMap.Value,
		state.WinningMode.Value,
		state.PlayUnlocked.Value,
		displayedMapCounts,
		getVoteCounts(modeVotes, modes),
		#participants(),						-- [BOTS 23/09] los bots cuentan como gente
		getVoteCounts(gamemodeVotes, getGamemodeBallot()),	-- solo los 3 sorteados
		getVoteCounts(ambienceVotes, getAmbienceBallot())
	)
end

local function setState(nextPhase, timeLeft, mapName, modeName, unlocked)
	phase = nextPhase
	state.Phase.Value = nextPhase
	state.TimeLeft.Value = timeLeft
	if mapName ~= nil then state.WinningMap.Value = mapName end
	if modeName ~= nil then state.WinningMode.Value = modeName end
	state.PlayUnlocked.Value = unlocked == true
	broadcastState(timeLeft)
end

local clearPlayerTools

local function preparePlayerForRound(player)
	roundPlayers[player] = true
	local roundTeam = player:GetAttribute("RoundTeam")
	if not roundTeam or not teamByName[roundTeam] then
		local availableTeams = getRoundTeamNames(currentMode)
		roundTeam = availableTeams[((player.UserId - 1) % #availableTeams) + 1]
	end
	setPlayerTeam(player, roundTeam)
	TeamLifePool.lastTeam[player.UserId] = roundTeam		-- [22/09 Duelo por vidas]

	--  [22/09 Guardian] Antes de CanUseRoundTools = true (que es lo que
	--  dispara el equipado): el que no es lider no recibe armas largas. Si
	--  su equipo se quedo sin lider porque no habia nadie al elegir, el
	--  primero que llega lo es.
	local guardianRules = rulesFor(currentGamemode).Guardian
	if guardianRules then
		local isLeader = Guardian.leaders[roundTeam] == player and Guardian.alive[roundTeam] == true
		if not isLeader then
			player:SetAttribute("RestrictedSlots", guardianRules.RestrictedSlots)
			Guardian.stripRestricted(player)
			if Guardian.picked and Guardian.alive[roundTeam] == nil then
				Guardian.setLeader(roundTeam, player)
			end
		end
	end
	player:SetAttribute("CanUseRoundTools", false)
	clearPlayerTools(player)
	player.RespawnLocation = nil
	player:SetAttribute("InRound", true)
	player:SetAttribute("CanUseRoundTools", true)
	--  [22/09] Ya forma parte de ESTA ronda: aunque salga con M puede volver
	--  despues de que se cierre la entrada (con las vidas que le queden).
	player:SetAttribute("RoundJoined", true)

	--  Vidas del modo. Solo se asignan la primera vez que entra en ESTA
	--  ronda; si vuelve a entrar conserva las que le quedaban.
	local lives = rulesFor(currentGamemode).Lives or 0
	if roundLives[player.UserId] == nil then
		roundLives[player.UserId] = lives
	end
	player:SetAttribute("RoundLives", roundLives[player.UserId])

	local inRoundNow = 0
	for _, other in ipairs(participants()) do
		if other:GetAttribute("InRound") == true then inRoundNow += 1 end
	end
	if inRoundNow > peakRoundPlayers then peakRoundPlayers = inRoundNow end
end

clearPlayerTools = function(player)
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		for _, item in ipairs(backpack:GetChildren()) do
			if item:IsA("Tool") then item:Destroy() end
		end
	end
	local character = player.Character
	if character then
		for _, item in ipairs(character:GetChildren()) do
			if item:IsA("Tool") then item:Destroy() end
		end
	end
end

local function clearAllTools()
	for _, player in ipairs(Players:GetPlayers()) do clearPlayerTools(player) end
end

local function ensureLobbyPlatform()
	if not lobbyPlatform or not lobbyPlatform:IsA("BasePart") then
		warn("[RoundManager] LobbyPlatform no encontrada")
		return
	end
	lobbyPlatform.Anchored = true
	lobbyPlatform.CanCollide = true
	lobbyPlatform.CanTouch = false
end

local function enforceLobbyTools(player)
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack and not backpack:GetAttribute("RoundToolGuard") then
		backpack:SetAttribute("RoundToolGuard", true)
		backpack.ChildAdded:Connect(function(child)
			if player:GetAttribute("InRound") ~= true and child:IsA("Tool") then child:Destroy() end
		end)
	end
	local character = player.Character
	if character and not character:GetAttribute("RoundToolGuard") then
		character:SetAttribute("RoundToolGuard", true)
		character.ChildAdded:Connect(function(child)
			if player:GetAttribute("InRound") ~= true and child:IsA("Tool") then child:Destroy() end
		end)
	end
	if phase ~= "Round" then clearPlayerTools(player) end
end

local function getMapBasePosition(map)
	if map:IsA("Model") then return map:GetPivot().Position end
	for _, item in ipairs(map:GetDescendants()) do
		if item:IsA("BasePart") then return item.Position end
	end
	return lobbySpawn.Position
end

local function getDesignedMapSpawns(map)
	local prefix = map.Name == "Führer house" and "Spawn_Casa" or map.Name == "Metro" and "Spawn_Subterraneo" or map.Name == "Brutalist" and "Spawn_Brutalist" or (map.Name == "Brutalist" or map.Name == "Plaza") and "Spawn_Plaza" or map.Name == "TestMap" and "Spawn_TestMap"
		or map.Name == "Prision" and "Spawn_Prision" or nil		-- [26/09]
	if not prefix then return {} end
	local parts = {}
	for _, item in ipairs(map:GetDescendants()) do
		if item:IsA("BasePart") and (item.Name == prefix or item.Name:match("^" .. prefix .. "_%d+$")) then
			table.insert(parts, item)
		end
	end
	table.sort(parts, function(a, b) return a.Name < b.Name end)
	return parts
end

local function ensureMapSpawns(map)
	local designedSpawns = getDesignedMapSpawns(map)
	if #designedSpawns > 0 then return designedSpawns end
	local spawns = map:FindFirstChild("Spawns")
	if not spawns then
		spawns = Instance.new("Folder")
		spawns.Name = "Spawns"
		spawns.Parent = map
	end
	local mapKey = map.Name:gsub("[^%w]", "_")
	local prefix = "Spawn_" .. mapKey .. "_"
	local parts = {}
	for _, item in ipairs(spawns:GetChildren()) do
		if item:IsA("BasePart") then
			if not item.Name:match("^Spawn_") then
				item.Name = prefix .. item.Name
			elseif not item.Name:match("^" .. prefix) then
				item.Name = prefix .. item.Name:gsub("^Spawn_", "")
			end
			table.insert(parts, item)
		end
	end
	table.sort(parts, function(a, b) return a.Name < b.Name end)
	local base = getMapBasePosition(map)
	for index = #parts + 1, 4 do
		local pad = Instance.new("Part")
		pad.Name = prefix .. index
		pad.Size = Vector3.new(5, 1, 5)
		pad.Position = base + Vector3.new((index - 1) * 6, 4, 0)
		pad.Anchored = true
		pad.CanCollide = false
		pad.CanTouch = false
		pad.Transparency = 1
		pad.Parent = spawns
		table.insert(parts, pad)
	end
	return parts
end

local function teleportPlayer(player, target)
	local character = player.Character
	if character and character.Parent then
		character:PivotTo(target.CFrame + Vector3.new(0, 4, 0))
	end
end

-- Mata y recarga el personaje del jugador para limpiar estado de combate
-- (sangrado, vida baja, "Injured", ragdoll, etc.) antes de volver al lobby.
local function resetPlayerForLobby(player)
	-- [EXTRA] Sin este guard, dos llamadas seguidas (por ejemplo el fin de
	-- ronda pisando una salida manual con M) podian disparar dos
	-- LoadCharacter casi simultaneos.
	if player:GetAttribute("RoundCharacterLoading") == true then return end
	player:SetAttribute("RoundCharacterLoading", true)

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		humanoid.Health = 0
	end
	task.spawn(function()
		if player.Parent then
			local success, errorMessage = pcall(function()
				player:LoadCharacter()
			end)
			if not success then
				warn("[RoundManager] No se pudo recargar el personaje de " .. player.Name .. " al volver al lobby: " .. tostring(errorMessage))
			end
			if player.Parent then
				teleportPlayer(player, lobbySpawn)
			end
		end
		if player.Parent then player:SetAttribute("RoundCharacterLoading", false) end
	end)
end

local function sendToLobby(player)
	-- Se evalua ANTES de limpiar el atributo, para saber si el jugador venia
	-- de estar realmente en una ronda (por M o porque la ronda termino).
	local wasInRound = player:GetAttribute("InRound") == true

	roundPlayers[player] = nil
	setPlayerTeam(player, "Lobby")	-- ya deja RoundTeam en nil
	player:SetAttribute("InRound", false)
	player:SetAttribute("CanUseRoundTools", false)
	player.RespawnLocation = nil
	enforceLobbyTools(player)

	if wasInRound then
		resetPlayerForLobby(player)
	else
		teleportPlayer(player, lobbySpawn)
	end
end

--==========================================================================
--  [F-39] CANAL RoundControl  (para TradeServer)
--
--  Si arrancas un trade en plena partida, el juego te manda al lobby: no
--  queremos gente parada en el mapa con el panel abierto, ni que alguien
--  se meta en un trade para quedar invulnerable mientras negocia.
--
--  LeaveRound es un RemoteEvent, y un RemoteEvent NO se puede disparar
--  desde el servidor hacia si mismo. Asi que se expone un BindableFunction
--  en ServerStorage, mismo patron que AdminWeaponAction y
--  TradeInventoryAction: RoundManager sigue siendo el unico que decide
--  quien entra y sale de una ronda.
--==========================================================================
local roundControl = ServerStorage:FindFirstChild("RoundControl")
if not roundControl then
	roundControl = Instance.new("BindableFunction")
	roundControl.Name = "RoundControl"
	roundControl.Parent = ServerStorage
end

roundControl.OnInvoke = function(op, player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false, "Jugador invalido"
	end

	if op == "isInRound" then
		return player:GetAttribute("InRound") == true

	elseif op == "sendToLobby" then
		if player:GetAttribute("InRound") ~= true then
			return false, "No estaba en una ronda"
		end
		dprint("[RoundManager]", player.Name, "sacado de la ronda por RoundControl")
		sendToLobby(player)
		return true, "Enviado al lobby"
	end

	return false, "Operacion desconocida: " .. tostring(op)
end

--==========================================================================
--  [F-41] ELECCION DE SPAWN
--
--  Antes:  activeRoundSpawns[((player.UserId - 1) % #activeRoundSpawns) + 1]
--  O sea, fijo por UserId. Siempre aparecias en el MISMO punto del mismo
--  mapa, y no miraba equipos: un companero podia caer del otro lado del
--  mapa mientras un rival te aparecia al lado.
--
--  Ahora, en orden:
--    1. Se descartan los spawns usados en los ultimos segundos, para que
--       dos jugadores que reaparecen juntos no se apilen en el mismo punto.
--    2. Se descartan los que tienen un rival vivo demasiado cerca (salvo
--       que no quede ninguno; mejor un spawn peligroso que ninguno).
--    3. Si el modo TIENE equipos y hay companeros vivos, se elige el spawn
--       mas cercano a un companero. Los que quedan a distancia parecida se
--       sortean, asi no se apila siempre todo el equipo en el mismo lado.
--    4. Si no hay equipos, o estas solo, se elige al azar entre los que
--       sobrevivieron a los filtros.
--
--  Los spawns siguen siendo GENERALES: no hay pools por equipo, es la
--  misma lista para todos.
--==========================================================================
local SPAWN_ENEMY_DANGER = 45     -- studs: rival mas cerca que esto = spawn descartado
local SPAWN_TIE_TOLERANCE = 20    -- studs: spawns "igual de buenos" se sortean
local SPAWN_REUSE_COOLDOWN = 4    -- segundos que un spawn queda marcado como usado

local spawnRandom = Random.new()

--  Claves debiles: si un mapa se descarga, sus spawns no quedan retenidos
--  por esta tabla. Es exactamente la clase de fuga que arreglamos en F-18.
local spawnLastUsed = setmetatable({}, {__mode = "k"})

local function hasTeams()
	return #getRoundTeamNames(currentMode) > 1
end

--  Posicion de un jugador solo si esta VIVO. Un cadaver no cuenta como
--  companero: no tiene sentido reaparecer al lado de alguien muerto.
local function livingRootPosition(player)
	local character = player.Character
	if not character or not character.Parent then return nil end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return nil end
	local root = character:FindFirstChild("HumanoidRootPart")
	return root and root.Position or nil
end

local function gatherLivingPositions(excludedPlayer)
	local mates, enemies = {}, {}
	local myTeam = excludedPlayer:GetAttribute("RoundTeam")
	local teamsMatter = hasTeams()

	for other in pairs(roundPlayers) do
		if other ~= excludedPlayer and other.Parent and other:GetAttribute("InRound") == true then
			local position = livingRootPosition(other)
			if position then
				--  Sin equipos todos comparten "Neutral": ahi NADIE es companero,
				--  o en free for all spawnearia el server entero en un rincon.
				if teamsMatter and myTeam and other:GetAttribute("RoundTeam") == myTeam then
					table.insert(mates, position)
				else
					table.insert(enemies, position)
				end
			end
		end
	end
	return mates, enemies
end

local function nearestDistance(position, positions)
	local best = math.huge
	for _, other in ipairs(positions) do
		local distance = (other - position).Magnitude
		if distance < best then best = distance end
	end
	return best
end

local function chooseSpawn(player)
	if #activeRoundSpawns == 0 then return nil end

	local now = os.clock()
	local all, fresh = {}, {}
	for _, spawn in ipairs(activeRoundSpawns) do
		if spawn and spawn.Parent then
			table.insert(all, spawn)
			local usedAt = spawnLastUsed[spawn]
			if not usedAt or now - usedAt > SPAWN_REUSE_COOLDOWN then
				table.insert(fresh, spawn)
			end
		end
	end

	--  1. Preferimos los que no se usaron recien, pero si TODOS estan en
	--  cooldown volvemos a la lista completa en vez de no spawnear.
	local pool = #fresh > 0 and fresh or all
	if #pool == 0 then return nil end

	local mates, enemies = gatherLivingPositions(player)

	--  2. Fuera los que tienen un rival encima
	if #enemies > 0 then
		local safe = {}
		for _, spawn in ipairs(pool) do
			if nearestDistance(spawn.Position, enemies) > SPAWN_ENEMY_DANGER then
				table.insert(safe, spawn)
			end
		end
		if #safe > 0 then pool = safe end
	end

	--  4. Sin companeros vivos (o modo sin equipos): puro azar
	if #mates == 0 then
		return pool[spawnRandom:NextInteger(1, #pool)]
	end

	--  3. Con companeros: el mas cercano, sorteando entre los parecidos
	local best = math.huge
	local distances = {}
	for index, spawn in ipairs(pool) do
		local distance = nearestDistance(spawn.Position, mates)
		distances[index] = distance
		if distance < best then best = distance end
	end

	local tied = {}
	for index, spawn in ipairs(pool) do
		if distances[index] <= best + SPAWN_TIE_TOLERANCE then
			table.insert(tied, spawn)
		end
	end
	return tied[spawnRandom:NextInteger(1, #tied)]
end

local function sendToRoundSpawn(player)
	if phase ~= "Round" or player:GetAttribute("InRound") ~= true or not roundPlayers[player] or #activeRoundSpawns == 0 then return end
	local spawn = chooseSpawn(player)
	if spawn and spawn.Parent then
		spawnLastUsed[spawn] = os.clock()
		teleportPlayer(player, spawn)
	end
end

-- Dispara el BindableEvent ForceEquipRoundLoadout (dos veces: inmediato +
-- 0.25s despues) para que el jugador reciba su equipo aunque su personaje
-- siga vivo y no se vuelva a disparar CharacterAdded.
local function requestRoundLoadout(player)
	--  [BOTS 23/09] Las armas del bot las maneja BotServer.
	if isBot(player) then return end
	task.defer(function()
		if player.Parent and roundPlayers[player] == true and phase == "Round" and player:GetAttribute("InRound") == true then
			forceEquipRoundLoadout:Fire(player)
		end
	end)
	task.delay(0.25, function()
		if player.Parent and roundPlayers[player] == true and phase == "Round" and player:GetAttribute("InRound") == true then
			forceEquipRoundLoadout:Fire(player)
		end
	end)
end

local function ensureRoundCharacter(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if character and character.Parent and humanoid and humanoid.Health > 0 then return end
	if player:GetAttribute("RoundCharacterLoading") == true then return end
	player:SetAttribute("RoundCharacterLoading", true)
	task.spawn(function()
		if player.Parent then
			local success, errorMessage = pcall(function()
				player:LoadCharacter()
			end)
			if not success then
				warn("[RoundManager] No se pudo cargar el personaje de " .. player.Name .. ": " .. tostring(errorMessage))
			end
		end
		if player.Parent then player:SetAttribute("RoundCharacterLoading", false) end
	end)
end

--==========================================================================
--  ELIMINACION
--
--  El handler de Humanoid.Died NO manda al jugador al lobby en el acto:
--  espera EliminationDelay para que la killcam alcance a mostrarse, y de
--  paso deja que MatchStatsServer (que tambien escucha Died) cuente la
--  muerte antes de que InRound pase a false.
--==========================================================================
local function eliminatePlayer(player)
	--  sendToLobby deja InRound en false, asi que eso mismo sirve de
	--  "ya se ejecuto" y no hace falta otra bandera.
	if player:GetAttribute("InRound") ~= true then return end
	eliminatedPlayers[player.UserId] = true
	player:SetAttribute("Eliminated", true)
	player:SetAttribute("RoundLives", 0)
	sendToLobby(player)
	dprint("[RoundManager]", player.Name, "quedo eliminado de la ronda")
end

--  [22/09 Guardian] Como esta en pie un equipo: 2 = conserva al lider,
--  1 = sin lider pero con gente, 0 = fuera. Tambien cuantos siguen.
function Guardian.teamStatus(teamName)
	local members = 0
	for _, other in ipairs(participants()) do
		if other:GetAttribute("InRound") == true and other:GetAttribute("RoundTeam") == teamName
			and not eliminatedPlayers[other.UserId] then
			members += 1
		end
	end
	local standing = 0
	if Guardian.alive[teamName] == true then
		standing = 2
	elseif members > 0 then
		standing = 1
	end
	return standing, members
end

--  Para el podio al acabarse el tiempo (MatchStatsServer lo lee).
function Guardian.publishStandings()
	for _, teamName in ipairs(getRoundTeamNames(currentMode)) do
		if teamName ~= "Neutral" then
			local standing, members = Guardian.teamStatus(teamName)
			state:SetAttribute("TeamStanding_" .. teamName, standing * 1000 + members)
		end
	end
end

--  Cayo (o se fue) el lider: ese equipo ya no reaparece. Los que estaban
--  muertos esperando para volver quedan eliminados en este momento.
--  [23/09] El lider tampoco vuelve a entrar, ni aunque se haya ido al
--  menu vivo: queda eliminado hasta la siguiente ronda.
function Guardian.leaderLost(teamName)
	if Guardian.alive[teamName] ~= true then return end
	Guardian.alive[teamName] = false
	local oldLeader = Guardian.leaders[teamName]
	if oldLeader and oldLeader.Parent then
		oldLeader:SetAttribute("GuardianLeader", nil)
	end
	Guardian.publish()
	local rules = rulesFor(currentGamemode)
	for _, other in ipairs(participants()) do
		if other:GetAttribute("InRound") == true and other:GetAttribute("RoundTeam") == teamName
			and not eliminatedPlayers[other.UserId] then
			local humanoid = other.Character and other.Character:FindFirstChildOfClass("Humanoid")
			if not humanoid or humanoid.Health <= 0 then
				eliminatedPlayers[other.UserId] = true
				other:SetAttribute("Eliminated", true)
				task.delay(rules.EliminationDelay or 4, function()
					if not other.Parent or phase ~= "Round" then return end
					if other:GetAttribute("InRound") ~= true then return end
					eliminatePlayer(other)
				end)
			end
		end
	end
	--  [23/09] Si se fue vivo (M), el bucle de arriba no lo toco: se marca
	--  aqui. joinActiveRound ya rechaza a los eliminados.
	if oldLeader and oldLeader.Parent and not eliminatedPlayers[oldLeader.UserId] then
		eliminatedPlayers[oldLeader.UserId] = true
		oldLeader:SetAttribute("Eliminated", true)
	end
	Guardian.publishStandings()
	dprint("[RoundManager] Guardian: cayo el lider de", teamName)
end

--  A los PickDelay segundos: un lider al azar por equipo, prefiriendo a
--  los que estan vivos en ese momento.
function Guardian.pickLeaders()
	Guardian.picked = true
	for _, teamName in ipairs(getRoundTeamNames(currentMode)) do
		if teamName ~= "Neutral" and not Guardian.leaders[teamName] then
			local alive, any = {}, {}
			for _, other in ipairs(participants()) do
				if other:GetAttribute("InRound") == true and other:GetAttribute("RoundTeam") == teamName
					and not eliminatedPlayers[other.UserId] then
					table.insert(any, other)
					local humanoid = other.Character and other.Character:FindFirstChildOfClass("Humanoid")
					if humanoid and humanoid.Health > 0 then table.insert(alive, other) end
				end
			end
			local pool = #alive > 0 and alive or any
			if #pool > 0 then
				Guardian.setLeader(teamName, pool[math.random(1, #pool)])
			end
		end
	end
	Guardian.publishStandings()
end

--==========================================================================
--  [26/09/2026] CONTROL: mantener el AreaObjetivo
--
--  Solo en mapas con una pieza "AreaObjetivo" (hoy: Prision). Cada segundo
--  se cuenta quien esta parado en el area (vivo, en la ronda, no abatido;
--  jugadores y bots igual) y cada enemigo anula a uno:
--    · el equipo con mas gente suma (los suyos - los de todos los demas)
--      puntos por segundo: 2 Rojo + 1 Azul = Rojo suma 1;
--    · si nadie supera a los demas (1 contra 1, 2 contra 2, 2 contra 1+1)
--      el punto queda en disputa: nadie suma y el area toma la mezcla de
--      los colores de los que estan adentro.
--  Gana el equipo con mas puntos al acabarse el tiempo (o el primero en
--  llegar a ScoreLimit, si esta puesto).
--  Se publica en State: ControlScore_<Equipo>, ControlHolder (equipo que
--  suma, "Disputa" o "") y ControlArea (ObjectValue con la pieza: BotServer
--  lo usa para que los bots jueguen el punto). Al terminar: ControlWinner y
--  TeamStanding_<Equipo> = puntos (para el podio).
--==========================================================================
Control.TEAMS = { "Rojo", "Azul", "Verde", "Amarillo" }

function Control.teamColor(teamName)
	local team = teamByName[teamName]
	return team and team.TeamColor.Color or Color3.fromRGB(200, 200, 200)
end

--  El eje de la pieza que apunta hacia arriba (1 = X, 2 = Y, 3 = Z).
function Control.upAxis(cframe)
	local x, y, z = math.abs(cframe.RightVector.Y), math.abs(cframe.UpVector.Y), math.abs(cframe.LookVector.Y)
	if x >= y and x >= z then return 1 end
	return y >= z and 2 or 3
end

--  Un punto (la raiz de un personaje) dentro del area: la huella de la
--  pieza (caja, o circulo si es una bola / un cilindro parado) y en altura
--  desde su base hasta 8 studs arriba de su tapa (una pieza fina en el piso
--  cuenta como toda la zona que tiene encima).
function Control.contains(part, position)
	local cframe, half = part.CFrame, part.Size / 2
	local local3 = cframe:PointToObjectSpace(position)
	local coords = { local3.X, local3.Y, local3.Z }
	local halves = { half.X, half.Y, half.Z }
	local up = Control.upAxis(cframe)
	local a, b = up == 1 and 2 or 1, up == 3 and 2 or 3
	local top = halves[up]
	local dy = position.Y - cframe.Position.Y
	if dy < -top - 1 or dy > top + 8 then return false end
	local round = part:IsA("Part") and (part.Shape == Enum.PartType.Ball or (part.Shape == Enum.PartType.Cylinder and up == 1))
	if round then
		local radius = math.min(halves[a], halves[b])
		return coords[a] * coords[a] + coords[b] * coords[b] <= radius * radius
	end
	return math.abs(coords[a]) <= halves[a] and math.abs(coords[b]) <= halves[b]
end

--  Quien suma: counts[equipo] = jugadores dentro. Devuelve (equipo, puntos
--  de ventaja), ("Disputa", 0) o (nil, 0) si no hay nadie.
function Control.resolve(counts)
	local total, best, bestTeam = 0, 0, nil
	for teamName, count in pairs(counts) do
		total += count
		if count > best then best, bestTeam = count, teamName end
	end
	if total == 0 then return nil, 0 end
	local margin = best - (total - best)
	if margin > 0 then return bestTeam, margin end
	return "Disputa", 0
end

function Control.publish(holder)
	for _, teamName in ipairs(Control.TEAMS) do
		state:SetAttribute("ControlScore_" .. teamName, Control.scores[teamName])
	end
	state:SetAttribute("ControlHolder", holder)
	local label = Control.label
	if label and label.Parent then
		local parts = {}
		for _, teamName in ipairs(Control.TEAMS) do
			local score = Control.scores[teamName]
			if score then
				table.insert(parts, string.format('<font color="#%s">%s %d</font>', Control.teamColor(teamName):ToHex(), teamName, score))
			end
		end
		local status = holder == "Disputa" and "EN DISPUTA" or holder and holder ~= "" and ("DOMINA " .. string.upper(holder)) or "LIBRE"
		label.Text = "<b>CONTROL · " .. status .. "</b>\n" .. table.concat(parts, "   ")
	end
end

--  Arranca con la ronda: marcador en 0 para cada equipo, el area a la vista
--  (con su marcador flotante) y la pieza publicada para los bots.
function Control.start(map)
	Control.stop(true)
	local part = map and map:FindFirstChild("AreaObjetivo", true)
	if not part or not part:IsA("BasePart") then
		warn("[RoundManager] Control sin AreaObjetivo en " .. tostring(map and map.Name))
		return
	end
	Control.part = part
	Control.saved = { Color = part.Color, Transparency = part.Transparency }
	part.Transparency = math.min(part.Transparency, 0.6)
	for _, teamName in ipairs(getRoundTeamNames(currentMode)) do
		if teamName ~= "Neutral" then Control.scores[teamName] = 0 end
	end

	local board = Instance.new("BillboardGui")
	board.Name = "ControlMarcador"
	board.Size = UDim2.fromOffset(260, 56)
	board.StudsOffsetWorldSpace = Vector3.new(0, part.Size.Y / 2 + 9, 0)
	board.AlwaysOnTop = true
	board.MaxDistance = 1000
	board.LightInfluence = 0
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = Color3.new(0, 0, 0)
	label.BackgroundTransparency = 0.45
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextScaled = true
	label.RichText = true
	label.Font = Enum.Font.GothamBold
	label.Parent = board
	board.Parent = part
	Control.board, Control.label = board, label

	--  Mezcla de colores cuando esta en disputa: franjas en la cara de arriba.
	local up = Control.upAxis(part.CFrame)
	local vector = up == 1 and part.CFrame.RightVector or up == 2 and part.CFrame.UpVector or part.CFrame.LookVector
	local faces = { { Enum.NormalId.Right, Enum.NormalId.Left }, { Enum.NormalId.Top, Enum.NormalId.Bottom }, { Enum.NormalId.Front, Enum.NormalId.Back } }
	local surface = Instance.new("SurfaceGui")
	surface.Name = "ControlMezcla"
	surface.Face = vector.Y >= 0 and faces[up][1] or faces[up][2]
	surface.LightInfluence = 0
	surface.Enabled = false
	local stripes = Instance.new("Frame")
	stripes.Size = UDim2.fromScale(1, 1)
	stripes.BorderSizePixel = 0
	stripes.BackgroundColor3 = Color3.new(1, 1, 1)
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 45
	gradient.Parent = stripes
	stripes.Parent = surface
	surface.Parent = part
	Control.surface, Control.gradient = surface, gradient

	local value = state:FindFirstChild("ControlArea")
	if not value then
		value = Instance.new("ObjectValue")
		value.Name = "ControlArea"
		value.Parent = state
	end
	value.Value = part
	state:SetAttribute("ControlWinner", nil)
	Control.publish("")
	dprint("[RoundManager] Control: area", part:GetFullName())
end

--  Cada segundo de la ronda.
function Control.tick(rules)
	local part = Control.part
	if not part or not part.Parent then return end
	local counts = {}
	for _, player in ipairs(participants()) do
		local teamName = player:GetAttribute("RoundTeam")
		if player:GetAttribute("InRound") == true and not eliminatedPlayers[player.UserId]
			and teamName and Control.scores[teamName] ~= nil then
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if humanoid and humanoid.Health > 0 and root and (character:GetAttribute("DownedState") or "") == ""
				and Control.contains(part, root.Position) then
				counts[teamName] = (counts[teamName] or 0) + 1
			end
		end
	end
	local holder, margin = Control.resolve(counts)
	local perSecond = (type(rules.Control) == "table" and tonumber(rules.Control.PointsPerSecond)) or 1
	if margin > 0 then
		Control.scores[holder] += margin * perSecond
	end

	--  Color: el del que suma; en disputa, la mezcla de los que estan.
	local color = Control.saved.Color
	local present = {}
	for _, teamName in ipairs(Control.TEAMS) do
		if counts[teamName] then table.insert(present, teamName) end
	end
	if holder == "Disputa" then
		local r, g, b = 0, 0, 0
		for _, teamName in ipairs(present) do
			local teamColor = Control.teamColor(teamName)
			r, g, b = r + teamColor.R, g + teamColor.G, b + teamColor.B
		end
		color = Color3.new(r / #present, g / #present, b / #present)
		local keys = {}
		for index, teamName in ipairs(present) do
			local teamColor = Control.teamColor(teamName)
			local from, to = (index - 1) / #present, index / #present
			table.insert(keys, ColorSequenceKeypoint.new(from, teamColor))
			table.insert(keys, ColorSequenceKeypoint.new(math.max(to - 0.001, from), teamColor))
		end
		keys[#keys] = ColorSequenceKeypoint.new(1, Control.teamColor(present[#present]))
		if Control.gradient then Control.gradient.Color = ColorSequence.new(keys) end
	elseif holder then
		color = Control.teamColor(holder)
	end
	part.Color = color
	if Control.surface then Control.surface.Enabled = holder == "Disputa" end
	Control.publish(holder or "")
end

--  Ya gano alguien por puntos (si hay ScoreLimit).
function Control.limitReached(rules)
	local limit = type(rules.Control) == "table" and tonumber(rules.Control.ScoreLimit) or 0
	if not limit or limit <= 0 then return false end
	for _, score in pairs(Control.scores) do
		if score >= limit then return true end
	end
	return false
end

--  Fin de la ronda: ganador y podio. Los puntos quedan publicados hasta el
--  ciclo siguiente (el podio los lee justo despues).
function Control.finish()
	local winner, best, tie = nil, -1, false
	for teamName, score in pairs(Control.scores) do
		state:SetAttribute("TeamStanding_" .. teamName, score)
		if score > best then
			winner, best, tie = teamName, score, false
		elseif score == best then
			tie = true
		end
	end
	state:SetAttribute("ControlWinner", winner and not tie and winner or "Empate")
	dprint("[RoundManager] Control: termina | ganador", winner, tie and "(empate)" or "")
	Control.stop(false)
end

--  Deja la pieza como estaba. clearScores: tambien borra el marcador.
function Control.stop(clearScores)
	local part = Control.part
	if part and Control.saved then
		part.Color = Control.saved.Color
		part.Transparency = Control.saved.Transparency
	end
	if Control.board then Control.board:Destroy() end
	if Control.surface then Control.surface:Destroy() end
	Control.part, Control.saved, Control.board, Control.label, Control.surface, Control.gradient = nil, nil, nil, nil, nil, nil
	local value = state:FindFirstChild("ControlArea")
	if value then value.Value = nil end
	state:SetAttribute("ControlHolder", nil)
	if clearScores then
		Control.scores = {}
		for _, teamName in ipairs(Control.TEAMS) do
			state:SetAttribute("ControlScore_" .. teamName, nil)
		end
		state:SetAttribute("ControlWinner", nil)
	end
end

local function onRoundDeath(player)
	if phase ~= "Round" then return end
	if player:GetAttribute("InRound") ~= true then return end

	local rules = rulesFor(currentGamemode)

	--  [22/09 Guardian] Espera minima para volver (tambien via menu).
	if rules.RespawnDelay then
		player:SetAttribute("RespawnReadyAt", Workspace:GetServerTimeNow() + rules.RespawnDelay)
	end

	--  [22/09 Guardian] Con el lider vivo (o sin elegir todavia) se
	--  reaparece. Si el que murio ES el lider, o el lider ya habia caido,
	--  se acabo para ese jugador.
	if rules.Guardian then
		local teamName = player:GetAttribute("RoundTeam")
		if Guardian.leaders[teamName] == player then
			Guardian.leaderLost(teamName)		-- lo elimina a el y a los muertos de su equipo
			return
		end
		if Guardian.alive[teamName] == false then
			eliminatedPlayers[player.UserId] = true
			player:SetAttribute("Eliminated", true)
			task.delay(rules.EliminationDelay or 4, function()
				if not player.Parent or phase ~= "Round" then return end
				if player:GetAttribute("InRound") ~= true then return end
				eliminatePlayer(player)
			end)
			Guardian.publishStandings()
		end
		return
	end

	--  [22/09 Duelo por vidas] Cada muerte gasta UNA reaparicion del
	--  EQUIPO. Si ya no le quedan, el que muere queda eliminado (killcam y
	--  al menu, igual que en Eliminacion).
	if (tonumber(rules.TeamLives) or 0) > 0 then
		local teamName = player:GetAttribute("RoundTeam")
		local pool = TeamLifePool.lives[teamName]
		if pool and pool > 0 then
			TeamLifePool.lives[teamName] = pool - 1
			publishTeamLives()
			dprint("[RoundManager]", player.Name, "murio |", teamName, "le quedan", pool - 1, "reapariciones")
			return
		end
		eliminatedPlayers[player.UserId] = true
		player:SetAttribute("Eliminated", true)
		task.delay(rules.EliminationDelay or 4, function()
			if not player.Parent or phase ~= "Round" then return end
			if player:GetAttribute("InRound") ~= true then return end
			eliminatePlayer(player)
		end)
		return
	end

	local maxLives = rules.Lives or 0
	if maxLives <= 0 then return end				-- Arcade: vidas infinitas

	local left = (roundLives[player.UserId] or maxLives) - 1
	roundLives[player.UserId] = left
	player:SetAttribute("RoundLives", math.max(0, left))
	dprint("[RoundManager]", player.Name, "murio | vidas restantes:", left)

	if left > 0 then return end

	--  Se marca YA, antes del delay de la killcam. Si no, el respawn
	--  automatico de Roblox (RespawnTime, 5s por defecto) podria meterlo de
	--  vuelta al mapa en el hueco: joinActiveRound rechaza a los marcados y
	--  handlePlayerForCurrentPhase lo manda al lobby en el acto.
	eliminatedPlayers[player.UserId] = true
	player:SetAttribute("Eliminated", true)

	task.delay(rules.EliminationDelay or 4, function()
		if not player.Parent then return end
		if phase ~= "Round" then return end
		if player:GetAttribute("InRound") ~= true then return end
		eliminatePlayer(player)
	end)
end

--  Corta la ronda cuando ya no queda con quien pelear.
local function shouldEndRoundEarly(elapsed)
	local rules = rulesFor(currentGamemode)

	--  [22/09 Guardian] Gana el ultimo equipo en pie, con o sin lider.
	if rules.Guardian then
		if elapsed < (rules.GraceSeconds or 10) then return false end
		if peakRoundPlayers < 2 then return false end
		local standingTeams = 0
		for _, teamName in ipairs(getRoundTeamNames(currentMode)) do
			if teamName ~= "Neutral" and Guardian.teamStatus(teamName) > 0 then
				standingTeams += 1
			end
		end
		return standingTeams <= 1
	end

	--  [22/09 Duelo por vidas] Un equipo sigue en pie mientras le queden
	--  reapariciones O tenga a alguien vivo en el mapa. Cuando queda uno
	--  solo en pie, gano.
	if (tonumber(rules.TeamLives) or 0) > 0 then
		if elapsed < (rules.GraceSeconds or 10) then return false end
		if peakRoundPlayers < 2 then return false end
		local standing = 0
		for teamName, pool in pairs(TeamLifePool.lives) do
			local alive = pool > 0
			if not alive then
				for _, other in ipairs(participants()) do
					if other:GetAttribute("InRound") == true
						and other:GetAttribute("RoundTeam") == teamName
						and not eliminatedPlayers[other.UserId] then
						alive = true
						break
					end
				end
			end
			if alive then standing += 1 end
		end
		return standing <= 1
	end

	--  [26/09 Control] Solo termina antes si alguien llego al limite de puntos.
	if rules.Control then return Control.limitReached(rules) end

	if not rules.EndWhenOneLeft then return false end
	if elapsed < (rules.GraceSeconds or 10) then return false end
	if peakRoundPlayers < 2 then return false end

	local survivors = 0
	local teamsAlive = {}
	for _, player in ipairs(participants()) do
		if player:GetAttribute("InRound") == true then
			survivors += 1
			local teamName = player:GetAttribute("RoundTeam")
			if teamName then teamsAlive[teamName] = true end
		end
	end

	if currentMode ~= "FFA" then
		local count = 0
		for _ in pairs(teamsAlive) do count += 1 end
		return count <= 1
	end
	return survivors <= 1
end

--  [22/09] ¿Sigue abierta la entrada para alguien que todavia NO entro a
--  esta ronda? Los que ya entraron (roundLives puesto) siempre pueden volver.
local function joinWindowOpenFor(player)
	if roundLives[player.UserId] ~= nil then return true end
	if joinClosesClock <= 0 then return true end
	return os.clock() < joinClosesClock
end

local function joinActiveRound(player)
	if phase ~= "Round" or not currentMap or not player.Parent or #activeRoundSpawns == 0 then return false end
	--  Un eliminado no vuelve a entrar hasta la ronda siguiente.
	if eliminatedPlayers[player.UserId] then return false end
	--  Eliminacion/Ejecucion: pasados los 15 s del arranque ya no entra
	--  nadie nuevo; espera a que termine la partida.
	if not joinWindowOpenFor(player) then
		dprint("[RoundManager]", player.Name, "llego tarde: entrada cerrada")
		return false
	end
	if roundPlayers[player] == true and player:GetAttribute("InRound") == true then
		sendToRoundSpawn(player)
		ensureRoundCharacter(player)
		requestRoundLoadout(player)
		return true
	end
	--  [22/09 Guardian] Volver desde el menu tambien respeta la espera de
	--  reaparicion: si no, ir al menu y darle JOIN se la saltaba.
	local readyAt = tonumber(player:GetAttribute("RespawnReadyAt"))
	if readyAt and Workspace:GetServerTimeNow() < readyAt then
		dprint("[RoundManager]", player.Name, "todavia no puede volver (espera de reaparicion)")
		return false
	end
	local roundTeam
	if teamLivesPerTeam() > 0 then
		--  [22/09 Duelo por vidas] El que ya jugo esta ronda vuelve a SU
		--  equipo, y volver (tras salir con M) gasta una reaparicion: es un
		--  cuerpo nuevo con toda la vida. El que entra por primera vez va al
		--  equipo mas chico de los que todavia tienen reapariciones.
		local lastTeam = TeamLifePool.lastTeam[player.UserId]
		if lastTeam then
			local pool = TeamLifePool.lives[lastTeam] or 0
			if pool <= 0 then
				dprint("[RoundManager]", player.Name, "no puede volver:", lastTeam, "sin reapariciones")
				return false
			end
			TeamLifePool.lives[lastTeam] = pool - 1
			publishTeamLives()
			roundTeam = lastTeam
		else
			roundTeam = pickTeamWithLives(player)
			if not roundTeam then return false end
		end
	else
		roundTeam = getBalancedRoundTeam(currentMode, player)
	end
	player:SetAttribute("RoundTeam", roundTeam)
	preparePlayerForRound(player)
	ensureRoundCharacter(player)
	sendToRoundSpawn(player)
	requestRoundLoadout(player)
	dprint("[RoundManager]", player.Name, "entro a la ronda activa")
	return true
end

local function chooseWinner(votes, options)
	if #options == 0 then return nil end
	local counts = getVoteCounts(votes, options)
	local totalVotes = 0
	for _, count in pairs(counts) do totalVotes += count end
	if totalVotes == 0 then
		return options[math.random(1, #options)]
	end
	local best = options[1]
	for _, option in ipairs(options) do
		if counts[option] > counts[best] then best = option end
	end
	return best
end

local function prepareRound(mapName, modeName)
	local map = getMap(mapName)
	if not map then
		warn("[RoundManager] Mapa no encontrado al preparar: " .. tostring(mapName))
		return false
	end
	activeRoundSpawns = ensureMapSpawns(map)
	return true
end

local function startRound(mapName, modeName, firstPlayer)
	currentMap = getMap(mapName)
	currentMode = modeName
	currentGamemode = pendingGamemodeName or DEFAULT_GAMEMODE
	roundLives = {}
	eliminatedPlayers = {}
	peakRoundPlayers = 0
	for _, other in ipairs(participants()) do
		other:SetAttribute("Eliminated", false)
		other:SetAttribute("RoundJoined", false)
	end
	dprint("[RoundManager] Arranca ronda | modo de juego:", currentGamemode)
	if not currentMap or not firstPlayer or not firstPlayer.Parent then
		warn("[RoundManager] No se pudo iniciar la ronda: mapa o jugador invalido")
		return false
	end
	activeRoundSpawns = ensureMapSpawns(currentMap)
	roundPlayers = {}
	resetTeamLives(true)			-- [22/09 Duelo por vidas] 50 por equipo
	--  [22/09 Guardian] Estado limpio, espera de reaparicion del modo, y
	--  la eleccion de lideres a los PickDelay segundos.
	Guardian.reset()
	--  [26/09] Control: marcador y area del mapa.
	if rulesFor(currentGamemode).Control then
		Control.start(currentMap)
	else
		Control.stop(true)
	end
	state:SetAttribute("ModeRespawnDelay", rulesFor(currentGamemode).RespawnDelay)
	local guardianRules = rulesFor(currentGamemode).Guardian
	if guardianRules then
		local token = Guardian.token
		task.delay(guardianRules.PickDelay or 5, function()
			if Guardian.token ~= token or phase ~= "Round" then return end
			Guardian.pickLeaders()
		end)
	end

	--  [22/09] Modo activo + ventana de entrada, publicados en State para
	--  que los lean DownedServer (reglas de Ejecucion) y el menu (JOIN).
	local rules = rulesFor(currentGamemode)
	local joinWindow = tonumber(rules.JoinWindow) or 0
	joinClosesClock = joinWindow > 0 and (os.clock() + joinWindow) or 0
	state:SetAttribute("ActiveGamemode", currentGamemode)
	state:SetAttribute("JoinClosesAt", joinWindow > 0 and (Workspace:GetServerTimeNow() + joinWindow) or 0)

	setState("Ready", 0, mapName, modeName, false)
	local roundTeam = getBalancedRoundTeam(modeName, firstPlayer)
	firstPlayer:SetAttribute("RoundTeam", roundTeam)
	preparePlayerForRound(firstPlayer)
	setState("Round", roundDurationFor(currentGamemode), mapName, modeName, false)
	ensureRoundCharacter(firstPlayer)
	sendToRoundSpawn(firstPlayer)
	requestRoundLoadout(firstPlayer)
	dprint("[RoundManager]", firstPlayer.Name, "inicio y entro a la ronda")
	return true
end

voteEvent.OnServerEvent:Connect(function(player, voteType, option)
	if phase ~= "Voting" or type(option) ~= "string" then return end
	local userId = player.UserId
	local changed = false
	if voteType == "Map" then
		--  Solo se acepta un mapa que este en la boleta de esta votacion.
		for _, name in ipairs(getMapBallot()) do
			if (forcedMapNames[name] or displayMapName(name)) == option or name == option then
				if mapVotes[userId] ~= name then
					mapVotes[userId] = name
					changed = true
				end
				break
			end
		end
	elseif voteType == "Mode" then
		for _, name in ipairs(modes) do
			if name == option then
				if modeVotes[userId] ~= name then
					modeVotes[userId] = name
					changed = true
				end
				break
			end
		end
	elseif voteType == "Gamemode" then
		--  Solo se acepta un modo que este en la terna de esta votacion.
		for _, name in ipairs(getGamemodeBallot()) do
			if name == option then
				if gamemodeVotes[userId] ~= name then
					gamemodeVotes[userId] = name
					changed = true
				end
				break
			end
		end
	elseif voteType == "Ambience" then
		--  Solo los 3 sorteados para esta votacion.
		for _, name in ipairs(getAmbienceBallot()) do
			if name == option then
				if ambienceVotes[userId] ~= name then
					ambienceVotes[userId] = name
					changed = true
				end
				break
			end
		end
	end
	if changed then broadcastState(state.TimeLeft.Value) end
end)

playEvent.OnServerEvent:Connect(function(player)
	if not player or not player.Parent or player:GetAttribute("InRound") == true then return end
	if eliminatedPlayers[player.UserId] then return end
	if phase == "Round" then
		joinActiveRound(player)
		return
	end
	if phase == "Lobby" and state.PlayUnlocked.Value and pendingMapName and pendingModeName then
		if startRound(pendingMapName, pendingModeName, player) then
			pendingMapName = nil
			pendingModeName = nil
		end
	end
end)

leaveEvent.OnServerEvent:Connect(function(player)
	if phase ~= "Round" or roundPlayers[player] ~= true then return end
	dprint("[RoundManager]", player.Name, "abandono la ronda")
	--  [22/09 Guardian] Salir al menu vivo tambien arranca la espera de
	--  reaparicion (muerto ya la tiene corriendo desde que murio). Y si el
	--  que se va es el lider, su equipo lo pierde como si hubiera caido.
	local rules = rulesFor(currentGamemode)
	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if rules.RespawnDelay and humanoid and humanoid.Health > 0 then
		player:SetAttribute("RespawnReadyAt", Workspace:GetServerTimeNow() + rules.RespawnDelay)
	end
	if rules.Guardian then
		local teamName = player:GetAttribute("RoundTeam")
		if Guardian.leaders[teamName] == player then Guardian.leaderLost(teamName) end
	end
	sendToLobby(player)
end)

--  [BOTS 23/09] Misma limpieza para un jugador que se desconecta y para un
--  bot que se quita desde el panel de admin.
local function onParticipantRemoving(player)
	--  [22/09 Guardian] El lider que se desconecta cuenta como caido.
	if phase == "Round" and rulesFor(currentGamemode).Guardian then
		local teamName = player:GetAttribute("RoundTeam")
		if teamName and Guardian.leaders[teamName] == player then
			pcall(Guardian.leaderLost, teamName)
		end
	end
	mapVotes[player.UserId] = nil
	modeVotes[player.UserId] = nil
	gamemodeVotes[player.UserId] = nil
	ambienceVotes[player.UserId] = nil
	roundLives[player.UserId] = nil
	eliminatedPlayers[player.UserId] = nil
	roundPlayers[player] = nil		-- [F-18] sin esto retiene el objeto Player
	if phase == "Voting" then broadcastState(state.TimeLeft.Value) end
end

Players.PlayerRemoving:Connect(onParticipantRemoving)

local function handlePlayerForCurrentPhase(player)
	if not player.Parent then return end
	if phase == "Round" then
		if player:GetAttribute("InRound") == true then
			if not joinActiveRound(player) then sendToLobby(player) end
		else
			sendToLobby(player)
		end
	else
		sendToLobby(player)
	end
end

local function setupPlayer(player)
	local function hookDeath(character)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if not humanoid then return end
		local fired = false
		humanoid.Died:Connect(function()
			if fired then return end
			fired = true
			onRoundDeath(player)
		end)
	end

	player.CharacterAdded:Connect(function(character)
		hookDeath(character)
		task.defer(function()
			handlePlayerForCurrentPhase(player)
		end)
	end)
	if player.Character then hookDeath(player.Character) end
	task.defer(function()
		handlePlayerForCurrentPhase(player)
	end)
end

Players.PlayerAdded:Connect(setupPlayer)
for _, player in ipairs(Players:GetPlayers()) do
	setupPlayer(player)
end

--  [BOTS 23/09] Un bot nuevo pasa por EXACTAMENTE el mismo setupPlayer que
--  un jugador que entra al servidor. BotServer usa estos ganchos para
--  "darle a JUGAR" y para saber donde estan los spawns.
if Bots then
	Bots.Round.Phase = function()
		return phase
	end
	Bots.Round.Join = function(bot)
		if not isBot(bot) or not bot.Parent then return false end
		if phase ~= "Round" or bot:GetAttribute("InRound") == true then return false end
		if eliminatedPlayers[bot.UserId] then return false end
		return joinActiveRound(bot)
	end
	Bots.Round.Spawns = function()
		return activeRoundSpawns
	end
	Bots.Round.Removing = function(bot)
		onParticipantRemoving(bot)
	end
	Bots.Added:Connect(function(bot)
		setupPlayer(bot)
		if phase == "Voting" or phase == "Lobby" then broadcastState(state.TimeLeft.Value) end
	end)
	for _, bot in ipairs(Bots.list()) do
		setupPlayer(bot)
	end
end

ensureLobbyPlatform()

--==========================================================================
--  [F-17] CICLO DE RONDA
--
--  El cuerpo del while paso a ser esta funcion para poder envolverlo en un
--  pcall. Ojo: el "continue" original se convirtio en "return", que hace
--  exactamente lo mismo aca (saltar al siguiente ciclo).
--==========================================================================
local function runRoundCycle()
	mapVotes = {}
	modeVotes = {}
	gamemodeVotes = {}
	ambienceVotes = {}
	roundLives = {}
	eliminatedPlayers = {}
	peakRoundPlayers = 0
	joinClosesClock = 0
	state:SetAttribute("ActiveGamemode", "")
	state:SetAttribute("JoinClosesAt", 0)
	resetTeamLives(false)			-- [22/09] se limpian las del duelo anterior
	Guardian.reset()				-- [22/09] y el Guardian
	Control.stop(true)				-- [26/09] y el marcador de Control
	state:SetAttribute("ModeRespawnDelay", nil)
	for _, player in ipairs(participants()) do
		player:SetAttribute("RespawnReadyAt", nil)
	end
	for _, player in ipairs(participants()) do
		player:SetAttribute("Eliminated", false)
		player:SetAttribute("RoundLives", 0)
		player:SetAttribute("RoundJoined", false)
		sendToLobby(player)
	end
	setState("Lobby", 0, "", "", false)
	task.wait(1)

	local maps = getMaps(true)	-- refresco forzado: arranca un ciclo nuevo
	if #maps == 0 then
		warn("[RoundManager] No hay mapas disponibles para votar")
		task.wait(5)
		return
	end

	--  Ternas nuevas para esta votacion.
	local ballot = rollMapBallot()
	local ambienceOptions = rollAmbienceBallot()
	local gamemodeOptions = rollGamemodeBallot()		-- [22/09] 3 modos al azar
	dprint("[RoundManager] Boleta de modos:", table.concat(gamemodeOptions, ", "))
	dprint("[RoundManager] Boleta de mapas:", table.concat(ballot, ", "))
	dprint("[RoundManager] Boleta de ambientes:", table.concat(ambienceOptions, ", "))

	setState("Voting", VOTE_DURATION, "", "", false)
	for remaining = VOTE_DURATION, 1, -1 do
		for _, player in ipairs(Players:GetPlayers()) do enforceLobbyTools(player) end
		state.TimeLeft.Value = remaining
		broadcastState(remaining)
		task.wait(1)
	end

	local winningMap = chooseWinner(mapVotes, ballot)
	local winningMode = chooseWinner(modeVotes, modes)
	local winningGamemode = chooseWinner(gamemodeVotes, gamemodeOptions) or DEFAULT_GAMEMODE
	--  [26/09] Un modo que necesita una pieza del mapa (Control: AreaObjetivo)
	--  no se juega en un mapa que no la tiene: esa partida va en Arcade.
	local requiredPart = rulesFor(winningGamemode).RequiresPart
	if requiredPart then
		local map = winningMap and getMap(winningMap)
		if not (map and map:FindFirstChild(requiredPart, true)) then
			dprint("[RoundManager]", winningGamemode, "no se juega en", winningMap, "-> Arcade")
			winningGamemode = GAMEMODE_RULES.Arcade and "Arcade" or DEFAULT_GAMEMODE
		end
	end
	state:SetAttribute("WinningGamemode", winningGamemode)
	--  [22/09 Duelo por equipos] Un modo que exige equipos no se juega en
	--  FFA: si la votacion de EQUIPOS dio FFA pasa a ForceTeams (2 equipos).
	--  Si salio 2 o 4 equipos, se respeta lo votado.
	local forcedTeams = rulesFor(winningGamemode).ForceTeams
	if forcedTeams and winningMode == "FFA" then
		dprint("[RoundManager]", winningGamemode, "no va en FFA -> se juega en", forcedTeams)
		winningMode = forcedTeams
	end
	local winningAmbience = chooseWinner(ambienceVotes, ambienceOptions) or DEFAULT_AMBIENCE or ""
	--  [22/09] Gano un ambiente especial pero el mapa ganador no lo admite
	--  (ej. Ventisca en el Metro): esa partida va con el de respaldo.
	local specialRule = specialAmbiences.byKey[winningAmbience]
	if specialRule and specialRule.maps and not specialRule.maps[winningMap] then
		dprint("[RoundManager]", winningAmbience, "no se juega en", winningMap, "-> queda", specialRule.fallback)
		winningAmbience = specialRule.fallback or DEFAULT_AMBIENCE or ""
	end
	state:SetAttribute("WinningAmbience", winningAmbience)
	pendingMapName = winningMap
	pendingModeName = winningMode
	pendingGamemodeName = winningGamemode
	dprint("[RoundManager] Ganadores: mapa =", winningMap, "modo =", winningMode, "| juego =", winningGamemode, "| ambiente =", winningAmbience)

	if not prepareRound(winningMap, winningMode) then
		pendingMapName = nil
		pendingModeName = nil
		pendingGamemodeName = nil
		setState("Lobby", 0, "", "", false)
		task.wait(2)
		return					-- [F-17] antes era "continue"
	end

	setState("Lobby", 0, winningMap, winningMode, true)
	for _, player in ipairs(participants()) do sendToLobby(player) end
	repeat
		task.wait(0.5)
	until phase ~= "Lobby" or not state.PlayUnlocked.Value or not pendingMapName or not pendingModeName or #Players:GetPlayers() == 0

	if phase == "Round" then
		local duration = roundDurationFor(currentGamemode)
		local rules = rulesFor(currentGamemode)
		local joinWindow = tonumber(rules.JoinWindow) or 0
		local minPlayers = tonumber(rules.MinPlayers) or 0
		local joinChecked = joinWindow <= 0
		for remaining = duration, 1, -1 do
			if #Players:GetPlayers() == 0 then break end
			local elapsed = duration - remaining

			--  [22/09] Se cerro la entrada: si no llego a juntarse gente
			--  suficiente, la ronda no tiene sentido (15 min solo y el resto
			--  del server bloqueado). Se cancela y se vuelve a votar.
			if not joinChecked and elapsed >= joinWindow then
				joinChecked = true
				if minPlayers > 1 and peakRoundPlayers < minPlayers and not RunService:IsStudio() then
					dprint("[RoundManager] Ronda cancelada: al cerrarse la entrada solo habia", peakRoundPlayers, "jugador(es)")
					break
				end
			end

			if rules.Control then Control.tick(rules) end		-- [26/09] 1 vez por segundo
			if shouldEndRoundEarly(elapsed) then
				dprint("[RoundManager] Ronda cortada: ya no queda con quien pelear")
				break
			end
			if rules.Guardian then Guardian.publishStandings() end	-- [22/09] para el podio
			state.TimeLeft.Value = remaining
			broadcastState(remaining)
			task.wait(1)
		end
		if rules.Control then Control.finish() end		-- [26/09] ganador y podio
	end
end

while true do
	local ok, err = pcall(runRoundCycle)

	if not ok then
		-- Antes esto mataba el hilo y el servidor se quedaba sin rondas
		-- para siempre, en silencio.
		warn("[RoundManager] El ciclo de ronda fallo: " .. tostring(err))
		pendingMapName = nil
		pendingModeName = nil
		task.wait(3)
	end

	-- Cierre del ciclo (corre haya fallado o no)
	pcall(function()
		setState("Lobby", 0, currentMap and currentMap.Name or "", currentMode or "", false)
		for _, player in ipairs(participants()) do sendToLobby(player) end
	end)
	activeRoundSpawns = {}
	roundPlayers = {}
	roundLives = {}
	eliminatedPlayers = {}
	peakRoundPlayers = 0
	joinClosesClock = 0
	pcall(Control.stop, false)		-- [26/09] el area vuelve a como estaba
	pcall(function()
		state:SetAttribute("ActiveGamemode", "")
		state:SetAttribute("JoinClosesAt", 0)
		for _, player in ipairs(participants()) do
			player:SetAttribute("Eliminated", false)
			player:SetAttribute("RoundJoined", false)
		end
	end)
	task.wait(2)
end
