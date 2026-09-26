--==========================================================================
--  BotServer  —  ServerScriptService  (23/09/2026)
--
--  Jugadores falsos para que el servidor se sienta con mas gente. Cada bot:
--    · entra a la partida como un jugador que acaba de llegar: el
--      RoundManager decide su equipo, sus vidas, cuando queda eliminado,
--      si es lider en Guardian... (ver BotRegistry: el bot es un "proxy"
--      que se comporta como un Player para el codigo que ya existe)
--    · usa las armas iniciales (SCAR-H, Ithaca-37, Glock 26) con su
--      ACS_Settings real y cambia entre ellas segun distancia y municion
--    · dispara por el MISMO calculo de dano que un jugador
--      (_G.ACS_CalculateDMG: equipos, abatido, chaleco, caida por distancia)
--    · tiene un preset de punteria y otro de reaccion sacados al azar
--      (BotConfig.AimPresets / ReactionPresets)
--    · se mueve por cualquier mapa con PathfindingService
--
--  Se controla desde el panel de admin (F4 > BOTS) a traves del
--  BindableFunction ServerStorage.BotSystem.BotControl:
--      BotControl:Invoke("add")        -> ok, mensaje
--      BotControl:Invoke("removeOne")  -> ok, mensaje
--      BotControl:Invoke("removeAll")  -> ok, mensaje
--      BotControl:Invoke("count")      -> ok, numero
--
--  IA v2 (25/09/2026): movimiento y combate mas humanos.
--    · parkour: salta obstaculos, se trepa a bordes y cruza huecos; esquiva
--      a otros personajes y sigue un camino recto cuando puede (sin zigzag)
--    · caminos: tres agentes (normal, con saltos, angosto), plan B directo
--      cuando no hay camino, y un presupuesto global de calculos por segundo
--    · oido: disparos (con paredes que amortiguan), pasos de quien corre,
--      balas que le pasan cerca, y "focos de combate" que se oyen de lejos
--    · pelea: prioriza a quien le dispara, se cubre para recargar o si lo
--      superan en numero, remata al debil, busca donde deberia estar el
--      enemigo que perdio de vista, y los climas ya no lo paralizan
--    · optimizado: filtros cacheados, menos red (cuello / giro), LOD de
--      decisiones lejos de jugadores reales
--  Ajustes en Tac.AI (se pueden pisar desde BotConfig.AI).
--
--  IA v3 (26/09/2026): edificios, puertas y memoria del mapa.
--    · puertas: las abre desde cerca, espera quieto a que abran, cruza por
--      el medio del marco, rodea la hoja si queda en el paso, nunca cierra
--      una abierta, y una que no abre pasa a ser pared (otra ruta)
--    · memoria compartida: lo que un bot no pudo alcanzar lo saben todos
--      (no vuelven a ir ni gastan caminos ahi); se reinicia en cada ronda
--    · lugares altos sin camino: busca un borde que se pueda trepar y sube
--    · posiciones: revisa todos los pisos (ventanas del segundo piso,
--      azoteas, muros bajos, colinas) y elige por vista, cobertura para
--      asomarse, altura, techo y distancia de su arma
--    · pelea a distancia: va a un lugar para asomarse (de pie dispara,
--      agachado se tapa); espera abajo al que se subio donde no se llega
--    · colinas: una ladera no es pared ni un hueco para saltar
--
--  PENDIENTE: killcam siguiendo al bot.
--==========================================================================
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")
local Debris = game:GetService("Debris")
local StarterPlayer = game:GetService("StarterPlayer")
local TweenService = game:GetService("TweenService")

local BotSystem = ServerStorage:WaitForChild("BotSystem")
local Config = require(BotSystem:WaitForChild("BotConfig"))
local Registry = require(BotSystem:WaitForChild("BotRegistry"))

local Engine = ReplicatedStorage:WaitForChild("ACS_Engine")
local Evt = Engine:WaitForChild("Events")
local Mods = Engine:WaitForChild("Modules")
local GunModels = Engine:WaitForChild("GunModels")
local GunStorage = ReplicatedStorage:WaitForChild("GunStorage")
local ACS_Workspace = workspace:WaitForChild("ACS_WorkSpace")
local Ultil = require(Mods:WaitForChild("Utilities"))
local Ragdoll = require(Mods:WaitForChild("Ragdoll"))

local gameRules = {}
do
	local ok, rules = pcall(function()
		return require(Engine:WaitForChild("GameRules"):WaitForChild("Config"))
	end)
	if ok and type(rules) == "table" then gameRules = rules end
end

local WALK_SPEED = tonumber(gameRules.NormalWalkSpeed) or 16
local RUN_SPEED = tonumber(gameRules.RunWalkSpeed) or 24
local JUMP_POWER = tonumber(gameRules.JumpPower) or 25

local roundState = ReplicatedStorage:WaitForChild("RoundSystem"):WaitForChild("State")

local GamemodeConfig = nil
pcall(function()
	GamemodeConfig = require(ReplicatedStorage:WaitForChild("GamemodeConfig", 10))
end)

--  [fase 2] Velocidades y tolerancias del abatido (las mismas que usa
--  DownedClient con un jugador).
local DownedConfig = {}
pcall(function()
	DownedConfig = require(ReplicatedStorage:WaitForChild("DownedConfig", 10))
end)

--  [fase 3] Para saber si hay ventarron (el clima especial lo publica en
--  State.WinningAmbience y AmbienceConfig dice que especial es).
local AmbienceConfig = nil
pcall(function()
	AmbienceConfig = require(ReplicatedStorage:WaitForChild("AmbienceConfig", 10))
end)
local CROUCH_SPEED = tonumber(gameRules.CrouchWalkSpeed) or 8

local killFeedEvent = nil
task.spawn(function()
	local folder = ReplicatedStorage:WaitForChild("KillcamUtils", 30)
	killFeedEvent = folder and folder:WaitForChild("KillFeed", 30)
end)

local function dprint(...)
	if Config.Debug then print("[Bots]", ...) end
end

--  [tacticas 23/09] Tipos de IA, cobertura, barrida, brazos, lamparas y la
--  recompensa por baja. Todo cuelga de esta tabla (se llena mas abajo, en
--  la seccion TACTICAS) para no sumar locals al script, que ya tiene muchos.
local Tac = {}

--  [IA v2] Ajustes de la IA nueva. Cualquier clave se puede pisar desde
--  BotConfig.AI (por ejemplo AI = { MantleMaxHeight = 0 } apaga el trepar).
Tac.AI = {
	--  Caminos
	PathBudget = 14,			-- calculos de camino por segundo entre TODOS los bots
	PathBurst = 10,				-- cuantos se pueden gastar de golpe
	PathOverdraw = 3,			-- extra que pueden pedir prestado los urgentes (pelea, cubrirse)
	RepathMinMove = 6,			-- si el destino se movio menos que esto, no recalcula
	TightAgent = true,			-- tercer intento con un agente angosto (pasillos, puertas chicas)
	SmoothEvery = 0.25,			-- cada cuanto intenta saltarse puntos del camino (camino recto)
	SmoothLookahead = 3,		-- cuantos puntos adelante mira
	DirectRange = 80,			-- sin camino: va derecho si el destino esta a menos de esto
	DirectTime = 6,				-- cuanto dura ese intento directo
	--  Parkour
	ParkourEvery = 0.1,
	ProbeAhead = 2.8,			-- distancia a la que mira obstaculos delante
	MantleMaxHeight = 6.5,		-- bordes hasta esta altura se trepan (0 = nunca)
	GapMax = 8,					-- huecos hasta este largo se saltan (0 = nunca)
	JumpCooldown = 0.55,
	JumpLoopLimit = 5,			-- saltos en el mismo lugar antes de rendirse con esa ruta
	BlockedSpotTime = 20,		-- s que recuerda un lugar donde no pudo subir
	--  Encerrado (queriendo ir a algun lado sin avanzar)
	ConfinedTime = 10,			-- s casi sin moverse antes de explorar para salir
	ConfinedRadius = 8,			-- "casi sin moverse" = no se alejo mas que esto
	WindowEscapeAfter = 2,		-- exploraciones fallidas antes de romper una ventana y salir por ahi
	--  Oido
	NoiseThrottle = 0.2,		-- un mismo tirador avisa como mucho cada tanto
	WallMuffle = 0.55,			-- a traves de paredes el disparo se oye a esta fraccion
	FootstepRange = 42,			-- pasos corriendo; caminando se oyen a ~45 % de esto
	WhizRadius = 7,				-- una bala que pasa a menos de esto la "siente"
	SuppressTime = 1.1,			-- tras una bala cerca apunta peor este rato
	SuppressError = 1.6,		-- grados extra de error estando suprimido
	HotspotRange = 480,			-- de tan lejos se oye un tiroteo
	HotspotLife = 22,			-- segundos que tarda en "enfriarse" un foco de combate
	HotspotMerge = 45,
	HotspotChance = 0.85,		-- paseando, prob. de ir hacia el tiroteo que oye
	QuietHunt = 12,				-- s sin oir nada antes de ir "a donde suele haber gente"
	--  Pelea
	AttackerPriority = 25,		-- cuanto prefiere a quien le acaba de disparar
	ZoneTargetPriority = 45,	-- [26/09] Control: cuanto prefiere al enemigo parado en el area
	OutnumberedHealth = 0.65,	-- con 2+ enemigos a la vista y menos vida que esto: cubrirse
	ReloadCoverRange = 45,		-- recargando con un enemigo a menos de esto: buscar cobertura
	PushChance = 0.55,			-- prob. de ir a rematar a un enemigo con poca vida
	CombatJumpChance = 0.1,		-- salto al moverse de lado de cerca
	CombatCrouchChance = 0.3,	-- agacharse un momento al plantarse a disparar
	--  Climas
	WeatherTolerance = 8,		-- s a la intemperie antes de buscar techo
	FloodTolerance = 4,			-- s en el agua antes de buscar un lugar alto
	WeatherPanicHealth = 0.45,	-- con menos vida que esto busca techo enseguida
	WeatherFightRange = 70,		-- con un enemigo a menos de esto, pelea en vez de resguardarse
	--  Rendimiento
	LodDistance = 260,			-- sin jugadores reales a esta distancia piensa mas lento
	LodFactor = 0.5,
	--  [IA v3] Puertas
	DoorWaitMax = 2.2,			-- s esperando que una puerta abra antes de reintentar / darla por cerrada
	DoorLockedTime = 60,		-- s que una puerta que no abre es pared para los caminos
	--  [IA v3] Memoria del mapa (la comparten todos los bots)
	MemoryTime = 90,			-- s que se recuerda un lugar inalcanzable (el doble si vuelve a fallar)
	MemoryMax = 300,
	--  [IA v3] Lugares altos sin camino
	ClimbSearch = 12,			-- studs alrededor del destino donde buscar un borde para trepar
	--  [IA v3] Posiciones
	SmartPositions = true,		-- defensiva / estratega / camper eligen puesto mirando todos los pisos
	PeekChance = 0.55,			-- peleando de lejos al descubierto: prob. de ir a un lugar para asomarse
	PeekMinDistance = 22,		-- mas cerca que esto se pelea moviendose
	PeekRange = 22,				-- studs a la redonda donde buscar ese lugar
	OverwatchChance = 0.35,		-- yendo a un tiroteo lejano: prob. de ir a un lugar alto que lo vea
}
if type(Config.AI) == "table" then
	for key, value in pairs(Config.AI) do Tac.AI[key] = value end
end
Tac.noiseAt = setmetatable({}, { __mode = "k" })	-- [tirador] = ultimo aviso de ruido
Tac.hotspots = {}									-- focos de combate { pos, at, heat }
Tac.partCache = setmetatable({}, { __mode = "k" })	-- [personaje] = piezas del cuerpo

--==========================================================================
--  UTILIDADES
--==========================================================================
local function rangeNumber(rng, pair)
	return rng:NextNumber(pair[1], pair[2])
end

local function randomFrom(list, rng)
	if not list or #list == 0 then return nil end
	return list[rng:NextInteger(1, #list)]
end

local function pickWeighted(list, rng)
	local total = 0
	for _, item in ipairs(list) do total += (item.Weight or 1) end
	local roll = rng:NextNumber(0, total)
	for _, item in ipairs(list) do
		roll -= (item.Weight or 1)
		if roll <= 0 then return item end
	end
	return list[#list]
end

--  Normal estandar (Box-Muller): la mayoria de los tiros caen cerca del
--  punto apuntado y unos pocos se van lejos, como con una persona.
local function gaussian(rng)
	local u1 = math.max(rng:NextNumber(), 1e-6)
	local u2 = rng:NextNumber()
	return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
end

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

--==========================================================================
--  REGLAS DE LA PARTIDA (leidas del estado que publica el RoundManager)
--==========================================================================
local function currentPhase()
	local hook = Registry.Round.Phase
	if hook then
		local ok, phase = pcall(hook)
		if ok and phase then return phase end
	end
	local phaseValue = roundState:FindFirstChild("Phase")
	return phaseValue and phaseValue.Value or "Lobby"
end

--  [IA v2] Se consulta en cada par de participantes: cacheado medio segundo.
local function isFFA()
	local now = os.clock()
	if Tac.ffaAt and now - Tac.ffaAt < 0.5 then return Tac.ffa end
	local mode = roundState:FindFirstChild("WinningMode")
	Tac.ffa = mode ~= nil and mode.Value == "FFA"
	Tac.ffaAt = now
	return Tac.ffa
end

local function executionActive()
	local name = roundState:GetAttribute("ActiveGamemode")
	local modes = GamemodeConfig and GamemodeConfig.Modes
	local mode = modes and name and modes[name]
	return type(mode) == "table" and mode.Execution ~= nil
end

--  [fase 2] En Ejecucion a un abatido solo se le remata de cerca (o a la
--  cabeza). Distancia (studs, de raiz a raiz) a la que hay que llegar.
local function executionReach()
	local name = roundState:GetAttribute("ActiveGamemode")
	local modes = GamemodeConfig and GamemodeConfig.Modes
	local mode = modes and name and modes[name]
	local rules = type(mode) == "table" and mode.Execution
	if type(rules) ~= "table" then return math.huge end
	local studsPerMeter = (GamemodeConfig and GamemodeConfig.STUDS_PER_METER) or 3.5714
	return (rules.RangeMeters or 1) * studsPerMeter + (rules.ToleranceStuds or 0) - 0.4
end

local function isDownedCharacter(character)
	return character ~= nil and (character:GetAttribute("DownedState") or "") ~= ""
end

local function teamOf(participant)
	local roundTeam = participant:GetAttribute("RoundTeam")
	if type(roundTeam) == "string" and roundTeam ~= "" then return roundTeam end
	local team = participant.Team
	return team and team.Name or nil
end

local function areEnemies(a, b)
	if a == b then return false end
	local teamA, teamB = teamOf(a), teamOf(b)
	if teamA == "Lobby" or teamB == "Lobby" then return false end
	if isFFA() then return true end
	if not teamA or not teamB then return true end
	if teamA == "Neutral" or teamB == "Neutral" then return true end
	return teamA ~= teamB
end

--==========================================================================
--  NOMBRES
--==========================================================================
local usedNames = {}
local nextUserId = -1000

local function nameTaken(name)
	local key = string.lower(name)
	if usedNames[key] then return true end
	for _, player in ipairs(Players:GetPlayers()) do
		if string.lower(player.Name) == key then return true end
	end
	return false
end

local function generateName(rng)
	local N = Config.Names
	for _ = 1, 40 do
		local first = randomFrom(N.First, rng) or "Player"
		local word = randomFrom(N.Words, rng) or "Gamer"
		local word2 = randomFrom(N.Words, rng) or "Pro"
		local tag = randomFrom(N.Tags, rng) or "GG"
		local style = rng:NextInteger(1, 8)
		local name
		if style == 1 then
			name = first .. "_" .. word
		elseif style == 2 then
			name = word .. word2 .. rng:NextInteger(1, 999)
		elseif style == 3 then
			name = "xX" .. word .. "Xx"
		elseif style == 4 then
			name = first .. rng:NextInteger(2005, 2016)
		elseif style == 5 then
			name = string.lower(first) .. "_" .. string.lower(word) .. rng:NextInteger(1, 99)
		elseif style == 6 then
			name = word .. "_" .. tag
		elseif style == 7 then
			name = "The" .. word .. first
		else
			name = first .. word .. rng:NextInteger(1, 9999)
		end
		name = name:gsub("[^%w_]", "")
		if #name >= 3 and #name <= 20 and not nameTaken(name) then
			return name
		end
	end
	return "Player" .. rng:NextInteger(10000, 99999)
end

--==========================================================================
--  AVATAR
--==========================================================================
local DEFAULT_ANIMS = {
	idle = "rbxassetid://507766388",
	walk = "rbxassetid://913402848",
	run = "rbxassetid://913376220",
	jump = "rbxassetid://507765000",
	fall = "rbxassetid://507767968",
	climb = "rbxassetid://507765644",
	swim = "rbxassetid://913384386",
	swimidle = "rbxassetid://913389285",
}

local function buildDescription(rng)
	local A = Config.Avatar
	local desc = Instance.new("HumanoidDescription")
	if A.Classic and #A.Classic > 0 and rng:NextNumber() < (A.ClassicChance or 0) then
		local colors = randomFrom(A.Classic, rng)
		desc.HeadColor = colors.Head
		desc.LeftArmColor = colors.Head
		desc.RightArmColor = colors.Head
		desc.TorsoColor = colors.Torso
		desc.LeftLegColor = colors.Legs
		desc.RightLegColor = colors.Legs
	else
		local skin = randomFrom(A.SkinTones, rng) or Color3.fromRGB(234, 184, 146)
		desc.HeadColor = skin
		desc.LeftArmColor = skin
		desc.RightArmColor = skin
		desc.TorsoColor = skin
		desc.LeftLegColor = skin
		desc.RightLegColor = skin
		desc.Shirt = randomFrom(A.Shirts, rng) or 0
		desc.Pants = randomFrom(A.Pants, rng) or 0
	end
	local face = randomFrom(A.Faces, rng)
	if face then desc.Face = face end
	if rng:NextNumber() < (A.HairChance or 0) then
		local hair = randomFrom(A.Hair, rng)
		if hair then desc.HairAccessory = tostring(hair) end
	end
	return desc
end

local function readAnimationIds(model)
	local ids = table.clone(DEFAULT_ANIMS)
	local animate = model:FindFirstChild("Animate")
	if animate then
		for key in pairs(DEFAULT_ANIMS) do
			local holder = animate:FindFirstChild(key)
			local animation = holder and holder:FindFirstChildOfClass("Animation")
			if animation and animation.AnimationId ~= "" then
				ids[key] = animation.AnimationId
			end
		end
		--  El Animate es un LocalScript: en un NPC no corre. Las animaciones
		--  las maneja este script desde el servidor (updateAnimation).
		animate:Destroy()
	end
	return ids
end

local function buildTemplate(rng)
	for attempt = 1, 3 do
		local desc = attempt < 3 and buildDescription(rng) or Instance.new("HumanoidDescription")
		local ok, model = pcall(function()
			return Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R15)
		end)
		if ok and model then
			return model, readAnimationIds(model)
		end
		warn("[Bots] No se pudo armar el avatar (intento " .. attempt .. "): " .. tostring(model))
	end
	return nil, table.clone(DEFAULT_ANIMS)
end

--==========================================================================
--  ARMAS
--==========================================================================
local weaponCache = {}

local function getWeaponInfo(name)
	local cached = weaponCache[name]
	if cached ~= nil then return cached or nil end

	local tool = GunStorage:FindFirstChild(name)
	local cfg = Config.Weapons[name]
	local model = GunModels:FindFirstChild(name)
	local settingsModule = tool and tool:FindFirstChild("ACS_Settings")
	local animModule = tool and tool:FindFirstChild("ACS_Animations")
	if not (tool and cfg and model and settingsModule) then
		warn("[Bots] Arma no disponible para bots: " .. tostring(name))
		weaponCache[name] = false
		return nil
	end

	local okS, data = pcall(require, settingsModule)
	if not okS or type(data) ~= "table" then
		warn("[Bots] El ACS_Settings de " .. name .. " no cargo: " .. tostring(data))
		weaponCache[name] = false
		return nil
	end
	local anim = {}
	if animModule then
		local okA, result = pcall(require, animModule)
		if okA and type(result) == "table" then anim = result end
	end

	local info = {
		name = name,
		tool = tool,
		data = data,
		anim = anim,
		cfg = cfg,
		model = model,
		magSize = math.max(1, tonumber(data.Ammo) or 10),
		reserve = math.max(0, tonumber(data.StoredAmmo) or 0),
		pellets = math.max(1, tonumber(data.Bullets) or 1),
		interval = 60 / math.max(1, tonumber(data.ShootRate) or 600),
	}
	weaponCache[name] = info
	return info
end

--  Mismos valores por defecto que el ModTable del ACS_Framework (arma sin
--  accesorios). CalculateDMG lee DamageMod / minDamageMod; el cliente lee
--  MuzzleVelocity y la perforacion para dibujar la bala.
local MOD_TABLE = {
	camRecoilMod = { RecoilTilt = 1, RecoilUp = 1, RecoilLeft = 1, RecoilRight = 1 },
	gunRecoilMod = { RecoilUp = 1, RecoilTilt = 1, RecoilLeft = 1, RecoilRight = 1 },
	ZoomValue = 70, Zoom2Value = 70, AimRM = 1, SpreadRM = 1,
	DamageMod = 1, minDamageMod = 1,
	MinRecoilPower = 1, MaxRecoilPower = 1, RecoilPowerStepAmount = 1,
	MinSpread = 1, MaxSpread = 1, AimInaccuracyStepAmount = 1, AimInaccuracyDecrease = 1,
	WalkMult = 1, adsTime = 1, MuzzleVelocity = 1, MoveSpeedMult = 1, JumpPowerMult = 1,
	AmmoType = "", BurnRatio = 0, RicochetBounces = 0, RicochetEnergy = 0.8,
	PenetrateHumanoids = false, PenetrateWalls = 0, PenetrationDamageKeep = 1, WallDamageKeep = 1,
}

--  [brazos 23/09] Codos y munecas originales del R15 (parte, motor).
Tac.armJoints = {
	{ "RightLowerArm", "RightElbow" }, { "RightHand", "RightWrist" },
	{ "LeftLowerArm", "LeftElbow" }, { "LeftHand", "LeftWrist" },
}

local function clearWeaponRig(character)
	for _, obj in ipairs(character:GetChildren()) do
		if obj.Name == "AnimBase" or obj:GetAttribute("ACS_ServerGun") then
			obj:Destroy()
		end
	end
	local rightUpper = character:FindFirstChild("RightUpperArm")
	local rightShoulder = rightUpper and rightUpper:FindFirstChild("RightShoulder")
	if rightShoulder then rightShoulder.Enabled = true end
	local leftUpper = character:FindFirstChild("LeftUpperArm")
	local leftShoulder = leftUpper and leftUpper:FindFirstChild("LeftShoulder")
	if leftShoulder then leftShoulder.Enabled = true end
	--  [brazos 23/09] Codos y munecas originales de vuelta (ver mountWeapon).
	for _, pair in ipairs(Tac.armJoints) do
		local part = character:FindFirstChild(pair[1])
		local joint = part and part:FindFirstChild(pair[2])
		if joint then joint.Enabled = true end
	end
end

local function newMotor(name, part0, part1, c0, parent, className)
	local motor = Instance.new(className or "Motor6D")
	motor.Name = name
	motor.Part0 = part0
	motor.Part1 = part1
	if c0 then motor.C0 = c0 end
	motor.Parent = parent
	return motor
end

--  Mismo rig de tercera persona que arma ACS_Server (Equip Mode 1) para un
--  jugador: brazos pegados a un AnimBase soldado a la cabeza y el modelo
--  del arma ("S" .. nombre) en la mano derecha. Asi el bot se ve igual que
--  cualquiera, y el ACS_EventHandler de los clientes encuentra el Muzzle
--  para el fogonazo y el sonido.
local function mountWeapon(state, info)
	local character = state.character
	clearWeaponRig(character)
	state.gunModel = nil
	state.muzzle = nil

	local head = character:FindFirstChild("Head")
	local RA = character:FindFirstChild("RightUpperArm")
	local LA = character:FindFirstChild("LeftUpperArm")
	local RLA = character:FindFirstChild("RightLowerArm")
	local LLA = character:FindFirstChild("LeftLowerArm")
	local RH = character:FindFirstChild("RightHand")
	local LH = character:FindFirstChild("LeftHand")
	local rightShoulder = RA and RA:FindFirstChild("RightShoulder")
	local leftShoulder = LA and LA:FindFirstChild("LeftShoulder")
	if not (head and RA and LA and RLA and LLA and RH and LH and rightShoulder and leftShoulder) then
		return false
	end

	local anim = info.anim
	local function cf(key)
		local value = anim[key]
		return typeof(value) == "CFrame" and value or CFrame.new()
	end

	local animBase = Instance.new("Part")
	animBase.Name = "AnimBase"
	animBase.CanCollide = false
	animBase.CanTouch = false
	animBase.CanQuery = false
	animBase.Transparency = 1
	animBase.Massless = true
	animBase.Size = Vector3.new(0.1, 0.1, 0.1)
	animBase.Parent = character

	newMotor("AnimBaseW", head, animBase, nil, animBase)
	--  [brazos 23/09] Los brazos van con Weld, no con Motor6D. El Animator
	--  aplica cada pose de la animacion al Motor6D cuya Part1 tiene ese
	--  nombre: RLAW (Part1 = RightUpperArm) recibia la rotacion del hombro y
	--  RHW (Part1 = RightLowerArm) la del codo, y el arma quedaba colgando.
	--  Un Weld no lo toca ninguna animacion y tiene el mismo C0 que ACS
	--  usa para las poses (apuntar, correr).
	newMotor("RAW", RA, animBase, cf("SV_RightArmPos"), animBase, "Weld")
	rightShoulder.Enabled = false
	newMotor("RLAW", RLA, RA, CFrame.new(0, RA.Size.Y / 2, 0) * cf("SV_RightElbowPos"), animBase, "Weld")
	newMotor("RHW", RH, RLA, CFrame.new(0, RLA.Size.Y / 2, 0) * cf("SV_RightWristPos"), animBase, "Weld")
	newMotor("LAW", LA, animBase, cf("SV_LeftArmPos"), animBase, "Weld")
	leftShoulder.Enabled = false
	newMotor("LLAW", LLA, LA, CFrame.new(0, LA.Size.Y / 2, 0) * cf("SV_LeftElbowPos"), animBase, "Weld")
	newMotor("LHW", LH, LLA, CFrame.new(0, LLA.Size.Y / 2, 0) * cf("SV_LeftWristPos"), animBase, "Weld")

	--  [brazos 23/09] Las animaciones de caminar / correr / reposo de
	--  Roblox siguen doblando los codos y las munecas ORIGINALES, y como
	--  conviven con los de ACS (RLAW, RHW, LLAW, LHW) el arma quedaba
	--  colgando: 45-50 grados hacia abajo y a la altura de la cadera. Se
	--  apagan igual que los hombros; asi los brazos quedan en la pose de
	--  ACS y las piernas siguen caminando normal. El ragdoll del abatido
	--  y clearWeaponRig los vuelven a encender.
	for _, pair in ipairs(Tac.armJoints) do
		local part = character:FindFirstChild(pair[1])
		local joint = part and part:FindFirstChild(pair[2])
		if joint then joint.Enabled = false end
	end

	local gun = info.model:Clone()
	gun.Name = "S" .. info.name
	gun:SetAttribute("ACS_ServerGun", true)
	--  (los Nodes se quitan mas abajo: antes sirven para montar la lampara)
	for _, part in ipairs(gun:GetDescendants()) do
		if part.Name == "SightMark" then part:Destroy() end
	end
	local handle = gun:FindFirstChild("Handle")
	if not handle then
		gun:Destroy()
		return false
	end
	for _, part in ipairs(gun:GetDescendants()) do
		if part:IsA("BasePart") and part ~= handle then
			Ultil.WeldComplex(handle, part, part.Name)
		end
	end
	local handleWeld = Instance.new("Motor6D")
	handleWeld.Name = "Handle"
	handleWeld.Part0 = RH
	handleWeld.Part1 = handle
	handleWeld.C1 = cf("SV_GunPos"):Inverse()
	handleWeld.Parent = handle

	--  [tacticas] De noche todas sus armas llevan la lampara encendida.
	if Config.Night and Config.Night.Flashlights ~= false and Tac.isNight and Tac.isNight() then
		local ok, err = pcall(Tac.addFlashlight, gun, handle)
		if not ok then warn("[Bots] No se pudo montar la lampara: " .. tostring(err)) end
	end
	local nodes = gun:FindFirstChild("Nodes")
	if nodes then nodes:Destroy() end
	for _, part in ipairs(gun:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = false
			part.CanCollide = false
			part.CanTouch = false
			part.Massless = true
		end
	end
	gun.Parent = character

	state.gunModel = gun
	state.muzzle = handle:FindFirstChild("Muzzle")
	state.armPose = "idle"		-- el rig recien montado queda en la pose normal
	return true
end

--==========================================================================
--  ESTADO
--==========================================================================
local metas = {}			-- [bot] = datos que sobreviven a morir (presets, avatar)
local brains = {}			-- [bot] = estado del cuerpo actual (se rehace en cada vida)

local lobbySpawnPart = nil
do
	local lobby = workspace:FindFirstChild("Lobby")
	local spawns = lobby and lobby:FindFirstChild("Spawns")
	lobbySpawnPart = spawns and spawns:FindFirstChild("LobbySpawn")
end

local losParams = RaycastParams.new()
losParams.FilterType = Enum.RaycastFilterType.Exclude
losParams.IgnoreWater = true

local bulletParams = RaycastParams.new()
bulletParams.FilterType = Enum.RaycastFilterType.Exclude
bulletParams.IgnoreWater = true

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.IgnoreWater = false

local function isAlive(state)
	return state and not state.dead and state.character.Parent ~= nil and state.humanoid.Health > 0
end

--  Una pieza que no es pared de verdad: invisible y sin colision (spawns,
--  zonas, triggers). Las balas y la vista la atraviesan.
local function isSeeThrough(part)
	if part.Parent and part.Parent:IsA("Accessory") then return true end
	-- [VIDRIO 24/09] A traves de una ventana se ve y se dispara.
	if part:GetAttribute("VidrioRompible") == true then return true end
	return part.CanCollide == false and part.Transparency >= 0.9
end

local function characterFromPart(part)
	local model = part:FindFirstAncestorOfClass("Model")
	while model do
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid then return model, humanoid end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil, nil
end

--  1 = cabeza, 2 = torso, 3 = extremidades (igual que el cliente de ACS).
local function bodyPartCode(part)
	local name = part.Name
	if name == "Head" then return 1 end
	if name == "UpperTorso" or name == "LowerTorso" or name == "Torso" or name == "HumanoidRootPart" then
		return 2
	end
	return 3
end

local BODY_PART_NAMES = { "cabeza", "pecho", "pierna" }

--==========================================================================
--  PERCEPCION
--==========================================================================
local function canSee(state, fromPos, entry)
	local filter = { state.character, ACS_Workspace }
	for _, part in ipairs({ entry.head, entry.torso }) do
		if part and part.Parent then
			local from = fromPos
			local remaining = part.Position - from
			for _ = 1, 3 do
				losParams.FilterDescendantsInstances = filter
				local result = workspace:Raycast(from, remaining, losParams)
				if not result or result.Instance:IsDescendantOf(entry.character) then
					return true
				end
				if not isSeeThrough(result.Instance) then break end
				table.insert(filter, result.Instance)
				remaining = part.Position - result.Position
				from = result.Position
			end
		end
	end
	return false
end

local function describeTarget(participant, character, myPos)
	--  [IA v2] Cada bot describe a cada participante varias veces por
	--  segundo: las piezas del cuerpo se buscan una vez por personaje.
	local parts = Tac.partCache[character]
	if not parts or not parts.root.Parent or not parts.humanoid.Parent or not parts.head.Parent then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local root = character:FindFirstChild("HumanoidRootPart")
		if not humanoid or not root then return nil end
		local head = character:FindFirstChild("Head")
		parts = { humanoid = humanoid, root = root, head = head,
			torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso") or root }
		--  Sin cabeza todavia (cargando): no se guarda, se vuelve a buscar.
		Tac.partCache[character] = head and parts or nil
	end
	local humanoid, root = parts.humanoid, parts.root
	if humanoid.Health <= 0 then return nil end
	return {
		participant = participant,
		character = character,
		humanoid = humanoid,
		root = root,
		head = parts.head,
		torso = parts.torso,
		dist = (root.Position - myPos).Magnitude,
		downed = (character:GetAttribute("DownedState") or "") ~= "",
		shielded = character:FindFirstChildOfClass("ForceField") ~= nil,
	}
end

local function gatherEnemies(state, maxDistance)
	--  [IA v2] La lista completa (sin limite de distancia) la piden varias
	--  tacticas en la misma vuelta de decisiones: se calcula una vez.
	local full = maxDistance == math.huge
	if full and state.allEnemiesTick == state.thinkTick and state.allEnemies then
		return state.allEnemies
	end
	local list = {}
	local me = state.bot
	local myPos = state.root.Position
	for _, participant in ipairs(Registry.participants()) do
		if participant ~= me and participant:GetAttribute("InRound") == true and areEnemies(me, participant) then
			local character = participant.Character
			if character and character.Parent then
				local entry = describeTarget(participant, character, myPos)
				if entry and entry.dist <= maxDistance then
					table.insert(list, entry)
				end
			end
		end
	end
	table.sort(list, function(a, b) return a.dist < b.dist end)
	if full then
		state.allEnemies = list
		state.allEnemiesTick = state.thinkTick
	end
	return list
end

--  Decide a quien ve el bot y actualiza el modelo de punteria.
local function perceive(state, now, dt)
	local P = Config.Perception
	local aim, react = state.aim, state.react
	local headPos = state.head.Position
	local look = flat(state.root.CFrame.LookVector)
	look = look.Magnitude > 0.01 and look.Unit or Vector3.new(0, 0, -1)
	local cosHalf = math.cos(math.rad(P.FOV / 2))
	local currentChar = state.target and state.target.character
	local AI = Tac.AI
	--  [IA v2] Quien le acaba de pegar es la amenaza real.
	local attacker = state.lastAttacker and now - (state.lastAttackerAt or -100) < 4 and state.lastAttacker or nil
	local order = Tac.currentOrder and Tac.currentOrder(state, now)

	local enemies = gatherEnemies(state, state.viewDistance or P.ViewDistance)
	local best, bestScore = nil, nil
	local checks, seen = 0, 0
	local zone = Tac.controlZone and Tac.controlZone()		-- [26/09] Control
	for _, entry in ipairs(enemies) do
		if checks >= 5 then break end
		local toEnemy = flat(entry.root.Position - headPos)
		local inCone = toEnemy.Magnitude < 0.5 or look:Dot(toEnemy.Unit) >= cosHalf
		local isCurrent = entry.character == currentChar and (now - state.lastSeenAt) < 1.5
		--  [IA v2] El que le disparo se busca aunque este fuera del cono.
		local isAttacker = attacker ~= nil and entry.participant == attacker
		--  [26/09] Control: el que esta parado en el area se busca aunque
		--  este fuera del cono (el area avisa: cambia de color).
		local inZone = zone ~= nil and Tac.inZone(zone, entry.root.Position, 0)
		if inCone or isCurrent or isAttacker or inZone or entry.dist <= P.CloseAwareness then
			checks += 1
			if canSee(state, headPos, entry) then
				seen += 1
				local score = entry.dist
				if isCurrent then score -= 30 end
				if isAttacker then score -= AI.AttackerPriority end
				if inZone then score -= AI.ZoneTargetPriority end		-- [26/09] primero el del area
				--  [23/09 noche] Un abatido cerca se remata ya (antes quedaba
				--  muy abajo en la lista y se le pasaba de lado).
				if entry.downed then score += (entry.dist < 30 and 8 or 60) end
				--  [24/09] El objetivo que marco el Lider del equipo va primero.
				if order and order.focus == entry.participant then score -= order.focusBonus end
				if entry.shielded then score += 45 end
				--  [IA v2] Al que le queda poca vida, y al que le esta apuntando.
				score -= (1 - entry.humanoid.Health / math.max(entry.humanoid.MaxHealth, 1)) * 15
				local theirLook = entry.root.CFrame.LookVector
				local toMe = state.root.Position - entry.root.Position
				if entry.dist < 90 and toMe.Magnitude > 0.1 and theirLook:Dot(toMe.Unit) > 0.975 then
					score -= 10
				end
				if not best or score < bestScore then
					best, bestScore = entry, score
				end
			end
		end
	end
	state.visibleCount = seen

	if best then
		local sameAsBefore = currentChar == best.character
		local isNew = not sameAsBefore or not state.visible
		if isNew then
			--  Lo acaba de descubrir (o reaparecio de detras de algo): tiempo
			--  de reaccion antes del primer tiro y punteria "en frio".
			local reaction = rangeNumber(state.rng, react.Reaction)
			local firstError = aim.FirstShotError * state.rng:NextNumber(0.85, 1.2)
			if sameAsBefore and (now - state.lastSeenAt) < 2.5 then
				reaction *= 0.55
				state.errorDeg = math.max(state.errorDeg, firstError * 0.6)
			else
				state.errorDeg = firstError
				state.headAim = state.rng:NextNumber() < aim.HeadChance
			end
			state.reactReadyAt = now + reaction
			state.burstLeft = 0
		else
			--  Siguiendolo: el error cae hacia el "asentado" del preset.
			state.errorDeg = aim.SettledError + (state.errorDeg - aim.SettledError) * math.exp(-aim.TrackRate * dt)
		end
		state.target = best
		state.visible = true
		state.lastSeenAt = now
		state.lastSeenPos = best.root.Position
		state.lastSeenVel = flat(best.root.AssemblyLinearVelocity)
		state.searchPos = nil
		state.noise = nil
		--  [tacticas] Aviso al equipo: "hay uno aqui".
		if Tac.reportIntel then Tac.reportIntel(state, best, now) end
	else
		--  [IA v2] Lo acaba de perder de vista: adonde iba corriendo.
		if state.visible and state.target and Tac.predictSearch then Tac.predictSearch(state, now) end
		state.visible = false
		--  [IA v2] Sin nadie a la vista, escucha pasos.
		if Tac.listenFootsteps and now >= (state.nextFootstepAt or 0) then
			state.nextFootstepAt = now + 0.3
			Tac.listenFootsteps(state, now, enemies)
		end
		local target = state.target
		if target then
			local gone = not target.character.Parent or target.humanoid.Health <= 0
				or target.participant:GetAttribute("InRound") ~= true
			if gone or (now - state.lastSeenAt) > P.MemorySeconds then
				state.target = nil
			end
		end
		state.errorDeg = math.min(aim.FirstShotError, state.errorDeg + dt * 1.5)
	end
end

--  Un disparo (o un golpe) que el bot escucha / siente.
local function notifyNoise(position, source, strength)
	local now = os.clock()
	local AI = Tac.AI
	--  [IA v2] Una rafaga son muchos disparos seguidos del mismo lugar: basta
	--  con avisar cada NoiseThrottle segundos (ahorra CPU con muchos bots).
	if source then
		local last = Tac.noiseAt[source]
		if last and now - last < AI.NoiseThrottle then return end
		Tac.noiseAt[source] = now
	end
	--  Foco de combate: se oye de mucho mas lejos (ver Tac.pickHotspot).
	if Tac.recordCombat then Tac.recordCombat(position, now) end
	local range = Config.Perception.HearingRange * (strength or 1)
	local ear = position + Vector3.new(0, 1.5, 0)
	for _, state in pairs(brains) do
		if isAlive(state) and state.bot ~= source and not state.visible
			and (not source or areEnemies(state.bot, source)) then
			local distance = (state.root.Position - position).Magnitude
			local heard = distance <= range
			local muffled = false
			--  [IA v2] De lejos, una pared en medio lo amortigua.
			if heard and distance > range * AI.WallMuffle then
				losParams.FilterDescendantsInstances = Tac.worldFilter()
				local hit = workspace:Raycast(ear, state.head.Position - ear, losParams)
				if hit and not isSeeThrough(hit.Instance) then
					heard, muffled = false, true
				end
			end
			if heard then
				local fuzz = math.clamp(distance * 0.12, 2, 25) * (muffled and 1.5 or 1)
				local offset = Vector3.new(state.rng:NextNumber(-1, 1), 0, state.rng:NextNumber(-1, 1)) * fuzz
				state.noise = { pos = position + offset, at = now }
				state.lookAt = position
				state.lookUntil = now + state.rng:NextNumber(1.2, 2.2)
				--  [IA v2] Lo que oye tambien lo sabe su equipo (menos fiable que verlo).
				if Tac.shareHeard then Tac.shareHeard(state, state.noise.pos, now) end
			end
		end
	end
end

--==========================================================================
--  ARMAS DEL BOT
--==========================================================================
local function allowedWeapons(state)
	local blocked = {}
	local text = state.bot:GetAttribute("RestrictedSlots")
	if type(text) == "string" then
		for slot in string.gmatch(text, "[^,]+") do blocked[slot] = true end
	end
	local list = {}
	for _, name in ipairs(state.meta.loadout or Config.Loadout) do
		local weapon = state.weapons[name]
		if weapon and not blocked[weapon.info.cfg.Slot] then
			table.insert(list, name)
		end
	end
	return list
end

local function hasAmmo(weapon)
	return weapon ~= nil and (weapon.mag > 0 or weapon.reserve > 0)
end

local function findRole(state, allowed, role)
	for _, name in ipairs(allowed) do
		if state.weapons[name].info.cfg.Role == role then return name end
	end
	return nil
end

local function chooseWeapon(state, now)
	local allowed = allowedWeapons(state)
	if #allowed == 0 then return nil end
	local isAllowed = {}
	for _, name in ipairs(allowed) do isAllowed[name] = true end

	local current = state.current
	local target = state.target
	if target and state.visible then
		local dist = (target.root.Position - state.root.Position).Magnitude
		local shotgun = findRole(state, allowed, "Shotgun")
		--  [tacticas] La principal puede ser rifle, subfusil, tirador o francotirador.
		local rifle = findRole(state, allowed, "Rifle") or findRole(state, allowed, "SMG")
			or findRole(state, allowed, "DMR") or findRole(state, allowed, "Sniper")
		local pistol = findRole(state, allowed, "Pistol")
		local function loaded(name) return name and state.weapons[name].mag > 0 end

		if shotgun and dist <= Config.ShotgunRange and hasAmmo(state.weapons[shotgun]) then return shotgun end
		--  Histeresis: con la escopeta en la mano no la suelta por un paso atras.
		if shotgun and current == shotgun and dist <= Config.ShotgunRange * 1.6 and loaded(shotgun) then return shotgun end
		--  [tacticas] Francotirador con alguien encima: mejor la pistola.
		if rifle and state.weapons[rifle].info.cfg.Role == "Sniper" and dist < (Config.SniperMinRange or 25)
			and pistol and loaded(pistol) then
			return pistol
		end
		if rifle and loaded(rifle) then return rifle end
		if pistol and dist <= Config.PistolSwapRange and loaded(pistol) then return pistol end
		if current and isAllowed[current] and hasAmmo(state.weapons[current]) then return current end
		for _, name in ipairs(allowed) do
			if hasAmmo(state.weapons[name]) then return name end
		end
		return current
	end

	--  Sin enemigos a la vista: despues de un rato vuelve al arma principal.
	if (now - state.lastSeenAt) >= Config.CalmReloadAfter then
		for _, name in ipairs(allowed) do
			if hasAmmo(state.weapons[name]) then return name end
		end
	end
	if current and isAllowed[current] then return current end
	return allowed[1]
end

local function equipWeapon(state, name, now)
	local weapon = state.weapons[name]
	if not weapon then return end
	state.current = name
	state.reload = nil
	state.burstLeft = 0
	state.equipUntil = now + weapon.info.cfg.EquipTime * state.rng:NextNumber(0.9, 1.25)
	state.lastSwitchAt = now
	mountWeapon(state, weapon.info)
	state.bot:SetAttribute("BotWeapon", name)
end

local function startReload(state, now)
	local weapon = state.weapons[state.current]
	if not weapon or weapon.reserve <= 0 or weapon.mag >= weapon.info.magSize then return end
	local cfg = weapon.info.cfg
	if cfg.ReloadPerShell then
		state.reload = { kind = "shell", nextAt = now + (cfg.ReloadStart or 0.4) + cfg.ReloadPerShell }
	else
		state.reload = { kind = "mag", doneAt = now + (cfg.ReloadTime or 2) * state.rng:NextNumber(0.9, 1.15) }
	end
end

local function updateReload(state, now)
	local reload = state.reload
	if not reload then return end
	local weapon = state.weapons[state.current]
	if not weapon then state.reload = nil return end
	if reload.kind == "mag" then
		if now >= reload.doneAt then
			local take = math.min(weapon.info.magSize - weapon.mag, weapon.reserve)
			weapon.mag += take
			weapon.reserve -= take
			state.reload = nil
		end
	elseif now >= reload.nextAt then
		if weapon.mag < weapon.info.magSize and weapon.reserve > 0 then
			weapon.mag += 1
			weapon.reserve -= 1
			reload.nextAt = now + weapon.info.cfg.ReloadPerShell
			--  Cartucho a cartucho: con alguien encima deja de cargar y dispara.
			if state.visible and state.target and weapon.mag >= 2 then
				local dist = (state.target.root.Position - state.root.Position).Magnitude
				if dist < weapon.info.cfg.IdealMax * 1.5 then state.reload = nil end
			end
		else
			state.reload = nil
		end
	end
end

--==========================================================================
--  DISPARO
--==========================================================================
local function sendHitEffect(result, data)
	local position = result.Position
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and (root.Position - position).Magnitude <= 600 then
			Evt.HitEffect:FireClient(player, nil, position, result.Instance, result.Normal, result.Material, data)
		end
	end
end

local function castBullet(state, origin, direction, range)
	local filter = { state.character, ACS_Workspace }
	local from = origin
	local remaining = range
	for _ = 1, 4 do
		bulletParams.FilterDescendantsInstances = filter
		local result = workspace:Raycast(from, direction * remaining, bulletParams)
		if not result then return nil end
		-- [VIDRIO 24/09] La bala del bot agrieta/revienta la ventana y sigue.
		if _G.LL_GlassHit and result.Instance:GetAttribute("VidrioRompible") == true then
			pcall(_G.LL_GlassHit, result.Instance, result.Position, direction, "Bot")
		end
		if not isSeeThrough(result.Instance) then return result end
		local skip = result.Instance
		if skip.Parent and skip.Parent:IsA("Accessory") then skip = skip.Parent end
		table.insert(filter, skip)
		remaining -= (result.Position - from).Magnitude
		from = result.Position
		if remaining <= 0 then return nil end
	end
	return nil
end

local function applyHit(state, weapon, result, origin)
	local info = weapon.info
	sendHitEffect(result, info.data)

	local character, humanoid = characterFromPart(result.Instance)
	if not character or character == state.character or humanoid.Health <= 0 then return end

	--  Mismo gate de equipos que todo el ACS (fuego amigo, Lobby...).
	if type(_G.ACS_CanDamage) == "function" then
		local ok, allowed = pcall(_G.ACS_CanDamage, state.character, humanoid)
		if ok and allowed == false then return end
	end

	local code = bodyPartCode(result.Instance)
	local partName = BODY_PART_NAMES[code]
	local distance = (result.Position - origin).Magnitude
	local identity = Registry.identityOf(state.bot)

	--  Lo mismo que deja Damage() de ACS antes de calcular: killfeed,
	--  killcam, marcador (autopsia) y Peces leen estos datos.
	humanoid:SetAttribute("ACS_KillKillerUserId", state.bot.UserId)
	humanoid:SetAttribute("ACS_KillWeapon", info.name)
	humanoid:SetAttribute("ACS_KillBodyPart", partName)
	humanoid:SetAttribute("ACS_KillDistanceStuds", distance)
	if identity then
		local creator = Instance.new("ObjectValue")
		creator.Name = "creator"
		creator.Value = identity
		creator.Parent = humanoid
		Debris:AddItem(creator, 3)
	end
	local weaponTag = Instance.new("StringValue")
	weaponTag.Name = "weaponUsed"
	weaponTag.Value = info.name
	weaponTag.Parent = humanoid
	Debris:AddItem(weaponTag, 3)
	local partTag = Instance.new("StringValue")
	partTag.Name = "lastHitBodyPart"
	partTag.Value = partName
	partTag.Parent = humanoid
	Debris:AddItem(partTag, 3)

	if type(_G.ACS_CalculateDMG) == "function" then
		local ok, err = pcall(_G.ACS_CalculateDMG, state.character, humanoid, distance, code, info.data, MOD_TABLE, info.tool)
		if not ok then warn("[Bots] CalculateDMG fallo: " .. tostring(err)) end
		--  [tacticas] Igual que un jugador: matar da vida y regeneracion.
		if humanoid.Health <= 0 and Tac.onKill then Tac.onKill(state) end
	else
		local range = code == 1 and info.data.HeadDamage or code == 2 and info.data.TorsoDamage or info.data.LimbDamage
		humanoid:TakeDamage(math.random(range[1], range[2]))
	end
end

local function removeProtection(state)
	if state.forceField then
		state.forceField:Destroy()
		state.forceField = nil
	end
end

local function fireShot(state, weapon, aimPart, now)
	local info = weapon.info
	local cfg = info.cfg
	local aim = state.aim
	local rng = state.rng

	local origin = (state.muzzle and state.muzzle.Parent) and state.muzzle.WorldPosition or state.head.Position
	--  Pegado a una pared el cano puede quedar del otro lado: se tira desde
	--  la cabeza, como hace el cliente de ACS con su camara.
	losParams.FilterDescendantsInstances = { state.character, ACS_Workspace }
	if workspace:Raycast(state.head.Position, origin - state.head.Position, losParams) then
		origin = state.head.Position
	end

	local toTarget = aimPart.Position - origin
	if toTarget.Magnitude < 0.1 then return end
	local baseDir = toTarget.Unit

	--  ERROR TOTAL (grados) = punteria actual + objetivo corriendo de lado +
	--  el bot caminando + retroceso acumulado que no controla.
	local velocity = state.target.root.AssemblyLinearVelocity
	local lateral = (velocity - baseDir * velocity:Dot(baseDir)).Magnitude
	local selfMoving = flat(state.root.AssemblyLinearVelocity).Magnitude > 3
	local errorDeg = state.errorDeg * (cfg.ErrorScale or 1)
		+ lateral * aim.MoveError
		+ (selfMoving and aim.SelfMoveError or 0)
		+ state.recoil * cfg.RecoilDeg * (1 - aim.RecoilControl)
		+ ((state.downed ~= "") and (Config.Downed and Config.Downed.ProneAimPenalty or 0) or 0)
		--  [IA v2] Con balas pasandole cerca apunta peor (supresion).
		+ ((state.suppressedUntil and now < state.suppressedUntil) and Tac.AI.SuppressError or 0)
	local sigma = math.rad(errorDeg * 0.6)
	local aimFrame = CFrame.lookAt(origin, origin + baseDir)
		* CFrame.Angles(gaussian(rng) * sigma, gaussian(rng) * sigma, 0)

	weapon.mag -= 1
	state.recoil = math.min(state.recoil + 1, 14)
	state.lastShotAt = now
	removeProtection(state)

	--  Sonido y fogonazo en todos los clientes (salen del Muzzle del modelo
	--  "S" .. arma, igual que el de un jugador).
	local shooter = { Name = state.bot.Name, Character = state.character }
	Evt.Atirar:FireAllClients(shooter, { Name = info.name }, false, false, nil)

	local range = cfg.MaxRange * 1.4
	local pelletSigma = math.rad((cfg.PelletSpread or 0) * 0.6)
	local tracers = 0
	local reach = nil
	for _ = 1, info.pellets do
		local frame = aimFrame
		if pelletSigma > 0 then
			frame = aimFrame * CFrame.Angles(gaussian(rng) * pelletSigma, gaussian(rng) * pelletSigma, 0)
		end
		local direction = frame.LookVector
		if tracers < 3 then
			tracers += 1
			Evt.ServerBullet:FireAllClients(shooter, origin, direction, info.data, MOD_TABLE)
		end
		local result = castBullet(state, origin, direction, range)
		if result then applyHit(state, weapon, result, origin) end
		reach = reach or (result and (result.Position - origin).Magnitude or range)
	end

	--  [IA v2] Los bots enemigos por donde paso la bala la "sienten".
	if Tac.bulletWhiz then Tac.bulletWhiz(state.bot, origin, aimFrame.LookVector, reach or range, now, Tac.AI.WhizRadius) end
	notifyNoise(origin, state.bot, 1)
end

local function updateFire(state, now)
	if state.reload or now < state.equipUntil then return end
	--  [24/09] Levantando a alguien YA NO tiene las manos ocupadas: puede
	--  disparar a un enemigo que este en un angulo que le deje seguir
	--  levantando (Tac.reviveFacing decide hacia donde mira).
	--  [23/09 noche] Sigiloso acercandose sin ser visto / lider que no quiere
	--  delatarse: no dispara todavia.
	if state.holdFire then return end
	--  [fase 2] Abatido solo dispara si ya saco la pistola (arrastrandose).
	if state.downed ~= "" and not state.proneArmed then return end
	--  [fase 2] Aturdido (bate cargado, rayo del huracan): no puede disparar.
	if (tonumber(state.humanoid:GetAttribute("Status_Stun")) or 0) > 0 then return end
	local target = state.target
	if not (target and state.visible) then
		state.burstLeft = 0
		return
	end
	if now < state.reactReadyAt or now < state.nextShotAt then return end

	local weapon = state.weapons[state.current]
	if not weapon or weapon.mag <= 0 then return end
	local info = weapon.info
	local cfg = info.cfg

	local aimPart = (state.headAim and target.head) or target.torso
	if not aimPart or not aimPart.Parent then aimPart = target.root end
	local toTarget = aimPart.Position - state.head.Position
	if toTarget.Magnitude > cfg.MaxRange then return end

	--  [fase 2] Ejecucion: a un abatido se le remata pegado a el o a la
	--  cabeza. [23/09 noche] De lejos ya no se queda mirando: apunta a la
	--  cabeza (el cuerpo no le hace nada) mientras se acerca.
	if executionActive() and isDownedCharacter(target.character)
		and (target.root.Position - state.root.Position).Magnitude > executionReach() then
		if not target.head or not target.head.Parent then return end
		aimPart = target.head
	end

	--  Solo dispara si ya esta mirando mas o menos hacia el objetivo.
	local look = flat(state.root.CFrame.LookVector)
	local toFlat = flat(toTarget)
	if look.Magnitude > 0.01 and toFlat.Magnitude > 1 then
		local dot = math.clamp(look.Unit:Dot(toFlat.Unit), -1, 1)
		if math.deg(math.acos(dot)) > state.react.AimCone then return end
	end

	local aim = state.aim
	if cfg.FireMode == "Auto" then
		if state.burstLeft <= 0 then
			if now < state.pauseUntil then return end
			state.burstLeft = state.rng:NextInteger(aim.Burst[1], aim.Burst[2])
			state.headAim = state.rng:NextNumber() < aim.HeadChance
		end
	end

	--  [tacticas] Con mira (francotirador): apunta un momento antes de cada
	--  tiro. Los de reaccion rapida apuntan mas rapido.
	if cfg.AimTime then
		if state.aimSettleFor ~= target.character then
			state.aimSettleFor = target.character
			state.aimSettleAt = now + rangeNumber(state.rng, cfg.AimTime) * math.sqrt(12 / math.max(state.react.TurnSpeed, 1))
			return
		end
		if now < state.aimSettleAt then return end
	end

	fireShot(state, weapon, aimPart, now)
	if cfg.AimTime then state.aimSettleFor = nil end

	if cfg.FireMode == "Auto" then
		state.burstLeft -= 1
		if state.burstLeft <= 0 then
			state.pauseUntil = now + rangeNumber(state.rng, aim.Pause)
		end
		state.nextShotAt = now + info.interval
	elseif cfg.FireMode == "Semi" then
		state.nextShotAt = now + math.max(info.interval, rangeNumber(state.rng, aim.SemiDelay) * (cfg.SemiScale or 1))
	else
		--  Pump (escopeta) o Bolt (cerrojo del francotirador).
		state.nextShotAt = now + (cfg.BoltTime or cfg.PumpTime or 0.9) * state.rng:NextNumber(0.9, 1.15)
	end
end

--==========================================================================
--  MOVIMIENTO
--==========================================================================
local function stopWalking(state)
	state.waypoints = nil
	state.moveMode = "hold"
	state.directGoal = nil
	state.detour = nil
	state.humanoid:MoveTo(state.root.Position)
	state.humanoid:Move(Vector3.zero)
end

local function requestPath(state, goal, kind)
	local now = os.clock()
	state.lastWantMoveAt = now		-- [IA v2] quiere ir a algun lado (ver Tac.checkConfined)
	--  [IA v2] Explorando para salir de un encierro: que termine primero.
	if state.exploreUntil and now < state.exploreUntil then return end
	if state.pathBusy then return end
	--  Un objetivo inalcanzable (arriba de un techo) no debe pedir 8 caminos
	--  por segundo.
	if now - state.lastRepath < 0.45 then return end
	--  [IA v2] Destino donde hace poco no pudo subir: fallado sin calcular,
	--  asi la tactica que lo pidio elige otro (en vez de volver a la pared).
	--  [IA v3] ...o que la memoria del mapa (compartida) da por inalcanzable.
	if Tac.nearBlocked(state, goal) or Tac.isUnreachable(goal) then
		state.lastRepath = now
		state.pathFails += 1
		return
	end
	--  [IA v2] El destino casi no se movio y el camino actual sigue en pie:
	--  se sigue usando (es lo que mas CPU ahorra con muchos bots).
	if state.moveMode == "path" and state.waypoints and state.pathGoal and state.pathKind == kind
		and (goal - state.pathGoal).Magnitude < Tac.AI.RepathMinMove then
		state.lastRepath = now
		return
	end
	--  [IA v2] Ya va derecho hacia ese mismo punto (plan B sin camino).
	if state.moveMode == "direct" and state.directGoal and now < (state.directUntil or 0)
		and (goal - state.directGoal).Magnitude < 8 then
		return
	end
	--  [IA v3] Subiendo a un lugar alto sin camino: primero al pie del borde
	--  (nil = esta trepando ahora mismo).
	local target = Tac.climbTarget(state, now, goal)
	if not target then return end
	--  [IA v2] Presupuesto global: si se acabo, se reintenta en la proxima vuelta.
	if not Tac.takePathToken(kind) then return end
	state.pathBusy = true
	state.pathKind = kind
	state.lastRepath = now
	local startPos = state.root.Position
	task.spawn(function()
		local waypoints, usedPath = nil, nil
		local from, to = startPos, target
		local nudged = 0
		local trusted = true		-- [IA v3] fallas "limpias" (NoPath): cuentan para la memoria
		for attempt, path in ipairs(Tac.pathOrder(state, startPos, target)) do
			--  [IA v2] Los reintentos con otro agente pueden pedir prestado: si
			--  no, con varios bots fallando se agotaba el presupuesto y el agente
			--  angosto (el que pasa por puertas y escaleras) no llegaba a probarse.
			if attempt > 1 and not Tac.takePathToken(kind, true) then break end
			local ok = pcall(function() path:ComputeAsync(from, to) end)
			local status = ok and path.Status
			--  [IA v2] Inicio o destino dentro de una pieza (pegado a una pared,
			--  un punto de sonido metido en un muro): se corre el punto y reintenta.
			if (status == Enum.PathStatus.FailStartNotEmpty or status == Enum.PathStatus.FailFinishNotEmpty)
				and nudged < 2 and Tac.takePathToken(kind, true) then
				nudged += 1
				if status == Enum.PathStatus.FailStartNotEmpty then
					from = Tac.freePoint(state, from) or from
				else
					to = Tac.freePoint(state, to) or to
				end
				ok = pcall(function() path:ComputeAsync(from, to) end)
				status = ok and path.Status
			end
			if status == Enum.PathStatus.Success then
				waypoints = path:GetWaypoints()
				usedPath = path
				break
			end
			if not ok or status == Enum.PathStatus.FailStartNotEmpty then trusted = false end
		end
		state.pathBusy = false
		if not isAlive(state) then return end
		if waypoints and #waypoints >= 2 then
			state.waypoints = waypoints
			state.activePath = usedPath
			--  [IA v2] El agente que funciono se prueba primero la proxima vez.
			state.goodPath, state.goodPathAt = usedPath, os.clock()
			state.lastPathOkAt = os.clock()
			state.wpIndex = 2
			--  [IA v2] Mientras se calculaba siguio caminando: no volver atras
			--  a puntos que ya paso.
			local here = state.root.Position
			while state.wpIndex < #waypoints and flat(waypoints[state.wpIndex].Position - here).Magnitude < 3 do
				state.wpIndex += 1
			end
			state.moveMode = "path"
			state.pathGoal = goal
			state.pathFails = 0
			state.lastMoveTarget = nil
			state.directGoal = nil
			state.detour = nil
		else
			state.pathFails += 1
			state.waypoints = nil
			state.pathGoal = nil
			--  [IA v3] Mas alto: plan para trepar; si no, a la memoria del mapa.
			if Tac.onPathFailed then Tac.onPathFailed(state, goal, target, startPos, trusted) end
			--  [IA v2] Sin camino: si esta cerca, va derecho y el parkour resuelve.
			if Tac.directFallback and not state.climbPlan then Tac.directFallback(state, goal) end
		end
	end)
end

--  Hay piso cerca debajo de ese punto (a la altura de la cadera). El rayo
--  es corto a proposito: una caida de mas de ~2.5 studs (el hueco entre el
--  anden y el tren del Metro, un balcon) cuenta como "no hay piso".
local function groundBelow(position)
	local result = workspace:Raycast(position + Vector3.new(0, 2, 0), Vector3.new(0, -7.5, 0), groundParams)
	return result ~= nil
end

--  Moverse de lado (o hacia atras) sin caerse de un borde ni meterse en una
--  pared. Si los dos lados estan tapados, se queda quieto.
local function startStrafe(state, now, direction, duration)
	groundParams.FilterDescendantsInstances = { state.character }
	losParams.FilterDescendantsInstances = { state.character, ACS_Workspace }
	local function free(dir)
		if workspace:Raycast(state.root.Position, dir * 5, losParams) then return false end
		return groundBelow(state.root.Position + dir * 4)
	end
	local dir = flat(direction)
	if dir.Magnitude < 0.01 then return end
	dir = dir.Unit
	if not free(dir) then
		dir = -dir
		if not free(dir) then
			stopWalking(state)
			return
		end
	end
	state.waypoints = nil
	state.directGoal = nil
	state.detour = nil
	state.humanoid:MoveTo(state.root.Position)
	state.moveMode = "strafe"
	state.strafeDir = dir
	state.strafeUntil = now + (duration or rangeNumber(state.rng, Config.Movement.StrafeTime))
end

local function stepMovement(state, now)
	local humanoid, root = state.humanoid, state.root
	--  [IA v2] Un desvio corto (esquivar a alguien, rodear una pared) manda
	--  sobre el camino un momento.
	local detour = state.detour
	if detour then
		if now < detour.untilT and (state.moveMode == "path" or state.moveMode == "direct") then
			if state.lastMoveTarget ~= detour.pos then
				humanoid:MoveTo(detour.pos)
				state.lastMoveTarget = detour.pos
				state.lastMoveToAt = now
			end
			return
		end
		state.detour = nil
		state.lastMoveTarget = nil
		if state.moveMode == "direct" and state.directGoal then
			humanoid:MoveTo(state.directGoal)
			state.lastMoveToAt = now
		end
	end
	if state.moveMode == "path" and state.waypoints then
		--  [IA v2] Camino recto: se salta puntos cuando hay paso libre.
		if Tac.smoothPath then Tac.smoothPath(state, now) end
		local waypoint = state.waypoints[state.wpIndex]
		if waypoint then
			local delta = waypoint.Position - root.Position
			--  [23/09 noche] Nadando, un punto que quedo abajo (el piso inundado)
			--  cuenta como alcanzado: si no, el bot se quedaba dando vueltas en la
			--  superficie encima de un punto al que nunca "llegaba".
			local swimming = humanoid:GetState() == Enum.HumanoidStateType.Swimming
			--  [IA v3] A su altura (desde los pies): uno del piso de arriba o de
			--  abajo no cuenta como alcanzado aunque este justo encima / debajo.
			local rise = waypoint.Position.Y - (root.Position.Y - humanoid.HipHeight - root.Size.Y * 0.5)
			if flat(delta).Magnitude < 2.4 and ((rise < 3.5 and rise > -6) or (swimming and delta.Y < 0)) then
				state.wpIndex += 1
				waypoint = state.waypoints[state.wpIndex]
			end
		end
		if not waypoint then
			state.waypoints = nil
			state.moveMode = "hold"
			state.arrivedAt = now
			humanoid:MoveTo(root.Position)
			--  [IA v3] Llego: ese lugar se puede alcanzar (se borra de la memoria).
			if state.pathGoal and (state.pathGoal - root.Position).Magnitude < 7 then Tac.markReached(state.pathGoal) end
			return
		end
		--  [fase 3] Con ventarron a la intemperie, saltar te manda a volar.
		--  [IA v2] Salta al llegar al punto de salto, no desde lejos (antes
		--  iba saltando todo el tramo). Los bordes altos los trepa el parkour.
		if waypoint.Action == Enum.PathWaypointAction.Jump and humanoid.FloorMaterial ~= Enum.Material.Air
			and not state.galeExposed and now >= (state.nextJumpAt or 0)
			and flat(waypoint.Position - root.Position).Magnitude < 4.5 and Tac.noteJump(state, now) then
			humanoid.Jump = true
			state.nextJumpAt = now + Tac.AI.JumpCooldown
		end
		if state.lastMoveTarget ~= waypoint.Position or now - state.lastMoveToAt > 1.5 then
			humanoid:MoveTo(waypoint.Position)
			--  Los waypoints estan sobre el navmesh: es un buen "punto seguro"
			--  para volver si se atora en un hueco.
			if state.lastMoveTarget then state.safePos = state.lastMoveTarget end
			state.lastMoveTarget = waypoint.Position
			state.lastMoveToAt = now
		end
	elseif state.moveMode == "direct" and state.directGoal then
		--  [IA v2] Plan B sin camino: derecho al destino.
		local goal = state.directGoal
		if (humanoid.WalkToPoint - goal).Magnitude > 1 then
			--  Otra parte del cerebro ya lo mando a otro lado.
			state.directGoal = nil
		elseif now > (state.directUntil or 0)
			or (flat(goal - root.Position).Magnitude < 2.5 and math.abs(goal.Y - root.Position.Y) < 5) then
			state.directGoal = nil
			state.moveMode = "hold"
			state.arrivedAt = now
			humanoid:MoveTo(root.Position)
		elseif now - state.lastMoveToAt > 2 then
			humanoid:MoveTo(goal)
			state.lastMoveToAt = now
		end
	elseif state.moveMode == "strafe" then
		if now >= state.strafeUntil then
			state.moveMode = "hold"
			humanoid:Move(Vector3.zero)
		else
			humanoid:Move(state.strafeDir)
		end
	end
end

--  Atorado "en el aire" (metido en una rendija, entre dos piezas): no toca
--  piso, asi que Humanoid.Jump no sirve. Primero un salto forzado; si sigue
--  ahi, vuelve al ultimo punto seguro de su camino.
local function checkWedged(state, now)
	local humanoid, root = state.humanoid, state.root
	local velocity = root.AssemblyLinearVelocity
	local airborne = humanoid.FloorMaterial == Enum.Material.Air
		and humanoid:GetState() == Enum.HumanoidStateType.Freefall
	if not airborne or math.abs(velocity.Y) > 3 then
		state.wedgedSince = nil
		if not airborne then state.groundPos = root.Position end
		return
	end
	state.wedgedSince = state.wedgedSince or now
	local stuckFor = now - state.wedgedSince
	if stuckFor > 3 then
		local safe = state.safePos or state.groundPos or state.spawnPos
		if safe then
			state.character:PivotTo(CFrame.new(safe + Vector3.new(0, 3.5, 0)) * root.CFrame.Rotation)
			root.AssemblyLinearVelocity = Vector3.zero
		end
		state.wedgedSince = nil
		state.waypoints = nil
		state.moveMode = "hold"
		state.nextRoamAt = now + 0.5
	elseif stuckFor > 1.2 and now - (state.lastHop or 0) > 0.8 then
		state.lastHop = now
		local angle = state.rng:NextNumber(0, math.pi * 2)
		local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
		humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
		root.AssemblyLinearVelocity = dir * 12 + Vector3.new(0, 42, 0)
	end
end

--  Si lleva rato sin avanzar: salta; si sigue igual, cambia de plan.
local function checkStuck(state, now)
	checkWedged(state, now)
	local M = Config.Movement
	--  [IA v3] Esperando que abra una puerta no esta atorado (no le salta encima).
	local moving = (state.moveMode == "path" or state.moveMode == "strafe" or state.moveMode == "direct") and not state.doorPass
	if not moving or (state.root.Position - state.progressPos).Magnitude > 1.5 then
		state.progressPos = state.root.Position
		state.progressAt = now
		return
	end
	local stuckFor = now - state.progressAt
	if stuckFor > M.StuckGiveUp then
		state.progressAt = now
		--  [IA v2] Segunda vez que se atasca yendo al mismo destino: ese
		--  destino no se alcanza (el camino dice que si, el cuerpo no puede).
		if Tac.noteStuck(state, now) then return end
		state.pathFails += 1
		state.nextRoamAt = now
		--  [IA v2] El proximo camino se prueba primero con saltos y angosto.
		state.preferJumpUntil = now + 10
		state.preferTightUntil = now + 10
		local side = state.root.CFrame.RightVector * (state.rng:NextNumber() < 0.5 and -1 or 1)
		startStrafe(state, now, side, 0.8)
	elseif stuckFor > M.StuckJump and Tac.tryNearbyDoor and Tac.tryNearbyDoor(state, now) then
		--  [23/09 noche] Atorado junto a una puerta cerrada: la abre.
		state.progressAt = now
	elseif stuckFor > M.StuckJump and now - state.lastJump > 0.9 and not state.galeExposed then
		state.lastJump = now
		if Tac.noteJump(state, now) then state.humanoid.Jump = true end
	end
end

local function pickRoamGoal(state)
	local M = Config.Movement
	local rng = state.rng
	local now = os.clock()
	--  [IA v2] Primero, hacia el tiroteo que se oye (como un jugador que va
	--  "a donde suenan los tiros"), con un error que crece con la distancia.
	if Tac.pickHotspot and rng:NextNumber() < Tac.AI.HotspotChance then
		local spot = Tac.pickHotspot(state, now)
		if spot then
			--  [IA v3] A veces, en vez de meterse en el medio, un lugar alto o con
			--  cobertura desde donde se ve el tiroteo.
			if rng:NextNumber() < Tac.AI.OverwatchChance and (spot.pos - state.root.Position).Magnitude > 70 then
				local vantage = Tac.findOverwatch(state, spot.pos)
				if vantage then return vantage end
			end
			local fuzz = math.clamp((spot.pos - state.root.Position).Magnitude * 0.06, 4, 30)
			return spot.pos + Vector3.new(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1)) * fuzz
		end
	end
	local huntBias = (state.meta.role and state.meta.role.HuntBias) or M.HuntBias
	--  [IA v2] "Saber" por donde anda la gente solo si hace rato que no se
	--  oye nada: con tiros sonando, se guia por el oido.
	local quiet = now - (Tac.lastCombatAt or -100) > Tac.AI.QuietHunt
	if quiet and rng:NextNumber() < huntBias then
		--  Un jugador sabe mas o menos por donde anda la gente: va hacia la
		--  zona de un enemigo, con error.
		local enemies = gatherEnemies(state, math.huge)
		if #enemies > 0 then
			local entry = enemies[rng:NextInteger(1, math.min(#enemies, 3))]
			local noise = Vector3.new(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1)) * M.HuntNoise
			if state.pathFails >= 2 then noise = Vector3.zero end
			return entry.root.Position + noise
		end
	end
	local hook = Registry.Round.Spawns
	local spawns = hook and hook()
	if type(spawns) == "table" and #spawns > 0 then
		local spawn = spawns[rng:NextInteger(1, #spawns)]
		if spawn and spawn.Parent then
			return spawn.Position + Vector3.new(rng:NextNumber(-10, 10), 0, rng:NextNumber(-10, 10))
		end
	end
	return state.root.Position + Vector3.new(rng:NextNumber(-60, 60), 0, rng:NextNumber(-60, 60))
end

--==========================================================================
--  CEREBRO
--==========================================================================
--==========================================================================
--  AGACHARSE Y VENTARRON (fase 3)
--
--  Con ventarron, estar de pie a la intemperie llena la barra de
--  resistencia y te manda a volar; saltar afuera tambien. Un jugador se
--  agacha: el bot hace lo mismo, con la MISMA postura que ACS le pone a un
--  jugador agachado (Evt.Stance, Stance 1) y el atributo ACS_Stance que lee
--  ClimaEspecialServer.
--==========================================================================
local STANCE_JOINTS = {
	{ part = "LowerTorso", joint = "Root" },
	{ part = "UpperTorso", joint = "Waist" },
	{ part = "RightUpperLeg", joint = "RightHip" },
	{ part = "LeftUpperLeg", joint = "LeftHip" },
	{ part = "RightLowerLeg", joint = "RightKnee" },
	{ part = "LeftLowerLeg", joint = "LeftKnee" },
}
local STANCE_TWEEN = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function cancelStanceTweens(state)
	for _, tween in pairs(state.stanceTweens or {}) do
		tween:Cancel()
	end
	state.stanceTweens = {}
end

--  0 = de pie, 1 = agachado.
local function setStance(state, stance)
	if state.stance == stance or state.downed ~= "" then return end
	local character, humanoid = state.character, state.humanoid
	local motors = {}
	for _, entry in ipairs(STANCE_JOINTS) do
		local part = character:FindFirstChild(entry.part)
		local motor = part and part:FindFirstChild(entry.joint)
		if not motor then return end
		motors[entry.joint] = motor
	end
	if not state.restC0 then
		state.restC0 = {}
		for name, motor in pairs(motors) do state.restC0[name] = motor.C0 end
	end

	state.stance = stance
	character:SetAttribute("ACS_Stance", stance)

	local targets = state.restC0
	local lowerTorso = character.LowerTorso
	local rightUpperLeg, leftUpperLeg = character.RightUpperLeg, character.LeftUpperLeg
	if stance == 3 then
		--  Barrida, entrada (ACS_Server, Stance 3).
		targets = {
			Root = CFrame.new(0, -humanoid.HipHeight / 1.15, 0.12) * CFrame.Angles(math.rad(30), math.rad(18), math.rad(5)),
			Waist = CFrame.new(0, lowerTorso.Size.Y / 2.5, 0) * CFrame.Angles(math.rad(-16), math.rad(-9), math.rad(-3)),
			RightHip = CFrame.new(rightUpperLeg.Size.X / 2, -lowerTorso.Size.Y / 2, 0) * CFrame.Angles(math.rad(42), 0, math.rad(-8)),
			RightKnee = CFrame.new(0, -rightUpperLeg.Size.Y / 2.6, 0) * CFrame.Angles(math.rad(-50), 0, 0),
			LeftHip = CFrame.new(-leftUpperLeg.Size.X / 2, -lowerTorso.Size.Y / 2, 0) * CFrame.Angles(math.rad(10), 0, math.rad(12)),
			LeftKnee = CFrame.new(0, -leftUpperLeg.Size.Y / 2.6, 0) * CFrame.Angles(math.rad(-96), 0, 0),
		}
	elseif stance == 4 then
		--  Barrida, asentada (ACS_Server, Stance 4).
		targets = {
			Root = CFrame.new(0, -humanoid.HipHeight / 0.93, 0.4) * CFrame.Angles(math.rad(56), math.rad(34), math.rad(11)),
			Waist = CFrame.new(0, lowerTorso.Size.Y / 2.5, 0) * CFrame.Angles(math.rad(-26), math.rad(-16), math.rad(-7)),
			RightHip = CFrame.new(rightUpperLeg.Size.X / 2, -lowerTorso.Size.Y / 2, 0) * CFrame.Angles(math.rad(34), 0, math.rad(-14)),
			RightKnee = CFrame.new(0, -rightUpperLeg.Size.Y / 2.6, 0) * CFrame.Angles(math.rad(-6), 0, 0),
			LeftHip = CFrame.new(-leftUpperLeg.Size.X / 2, -lowerTorso.Size.Y / 2, 0) * CFrame.Angles(math.rad(-8), 0, math.rad(18)),
			LeftKnee = CFrame.new(0, -leftUpperLeg.Size.Y / 2.6, 0) * CFrame.Angles(math.rad(-122), 0, 0),
		}
	end
	if stance == 1 then
		local lower = character.LowerTorso
		local rightLeg, leftLeg = character.RightUpperLeg, character.LeftUpperLeg
		--  Mismos numeros que ACS_Server (Evt.Stance, Stance 1, sin lean).
		targets = {
			Root = CFrame.new(0, -humanoid.HipHeight / 1.05, 0),
			Waist = CFrame.new(0, lower.Size.Y / 2.5, 0),
			RightHip = CFrame.new(rightLeg.Size.X / 2, -lower.Size.Y / 2, 0),
			LeftHip = CFrame.new(-leftLeg.Size.X / 2, -lower.Size.Y / 2, 0) * CFrame.Angles(math.rad(75), 0, 0),
			RightKnee = CFrame.new(0, -rightLeg.Size.Y / 2, 0) * CFrame.Angles(math.rad(-90), 0, 0),
			LeftKnee = CFrame.new(0, -leftLeg.Size.Y / 3.5, 0) * CFrame.Angles(math.rad(-60), 0, 0),
		}
	end

	cancelStanceTweens(state)
	for name, motor in pairs(motors) do
		local goal = targets[name]
		if goal then
			local tween = TweenService:Create(motor, STANCE_TWEEN, { C0 = goal })
			state.stanceTweens[name] = tween
			tween:Play()
		end
	end
end

local function galeActive()
	if not AmbienceConfig or type(AmbienceConfig.specialFor) ~= "function" then return false end
	if currentPhase() ~= "Round" then return false end
	local ok, special = pcall(AmbienceConfig.specialFor, roundState:GetAttribute("WinningAmbience"))
	return ok and type(special) == "table" and special.Gale ~= nil
end

--  Cielo abierto encima de la cabeza, con el mismo criterio que el clima:
--  hojas, piezas sin colision, invisibles, bordes de ForceField y
--  personajes no son techo.
local skyParams = RaycastParams.new()
skyParams.FilterType = Enum.RaycastFilterType.Exclude
skyParams.IgnoreWater = true

local function isUnderSky(state)
	local filter = { ACS_Workspace }
	for _, participant in ipairs(Registry.participants()) do
		if participant.Character then table.insert(filter, participant.Character) end
	end
	local from = state.head.Position
	for _ = 1, 8 do
		skyParams.FilterDescendantsInstances = filter
		local result = workspace:Raycast(from, Vector3.new(0, 250, 0), skyParams)
		if not result then return true end
		local part = result.Instance
		local ignorable = part ~= workspace.Terrain and (not part.CanCollide or part.Transparency >= 0.9
			or part.Material == Enum.Material.ForceField or part.Name == "LimiteMapa")
		if not ignorable then return false end
		table.insert(filter, part)
		from = result.Position
	end
	return false
end

--  Cada vuelta de decisiones: agachado a la intemperie con ventarron.
local function updateWindStance(state, now)
	if now >= (state.nextSkyCheck or 0) then
		state.nextSkyCheck = now + 0.5
		local exposed = galeActive() and isUnderSky(state)
		if exposed and not state.galeExposed then
			--  Tarda lo que tarde en reaccionar, como un jugador que ve la barra.
			state.crouchAt = now + rangeNumber(state.rng, state.react.Reaction)
		end
		state.galeExposed = exposed
	end
	--  [tacticas] Tambien se agacha en cobertura, en su puesto o apuntando
	--  quieto con francotirador. La barrida manda su propia postura.
	local wantCrouch = (state.galeExposed and now >= (state.crouchAt or 0))
		or (Tac.wantsCrouch and Tac.wantsCrouch(state, now))
	if not state.slide then
		setStance(state, wantCrouch and 1 or 0)
	end
	if state.stance == 1 and state.humanoid.WalkSpeed > CROUCH_SPEED then
		state.humanoid.WalkSpeed = CROUCH_SPEED
	end
end

--==========================================================================
--  LEVANTAR COMPANEROS (fase 2)
--==========================================================================
local function reviveTarget(state)
	local fn = _G.Downed_RevivingWho
	return fn and fn(state.bot) or nil
end

--  El companero abatido (bot o jugador) mas cercano que se puede levantar.
--  En FFA / Neutral no se levanta a nadie: todos son rivales.
local function findDownedTeammate(state)
	local R = Config.Revive
	if not R or not R.Enabled or isFFA() then return nil end
	local myTeam = teamOf(state.bot)
	if not myTeam or myTeam == "Neutral" or myTeam == "Lobby" then return nil end
	--  [IA v2] Casi siempre no hay nadie en el suelo: esa respuesta se
	--  recuerda medio segundo en vez de recorrer a todos en cada vuelta.
	local clock = os.clock()
	if state.noDownedUntil and clock < state.noDownedUntil then return nil end
	local best, bestDist = nil, math.huge
	for _, participant in ipairs(Registry.participants()) do
		if participant ~= state.bot and participant:GetAttribute("InRound") == true
			and teamOf(participant) == myTeam then
			local character = participant.Character
			local downed = character and character:GetAttribute("DownedState")
			--  [24/09] Uno al que no se pudo llegar (sin camino) se ignora un rato.
			local ignoredUntil = state.reviveIgnore and state.reviveIgnore[participant]
			if (downed == "Crawl" or downed == "Prone") and not (ignoredUntil and os.clock() < ignoredUntil) then
				local entry = describeTarget(participant, character, state.root.Position)
				local searchRange = R.SearchRange * ((state.meta.role and state.meta.role.ReviveRangeMult) or 1)
				if entry and entry.dist <= searchRange and entry.dist < bestDist then
					best, bestDist = entry, entry.dist
				end
			end
		end
	end
	if not best then state.noDownedUntil = clock + 0.5 end
	return best, bestDist
end

--==========================================================================
--  CEREBRO
--==========================================================================
local function decideMovement(state, now)
	local M = Config.Movement
	local humanoid = state.humanoid
	local target = state.target
	local weapon = state.weapons[state.current]
	local cfg = weapon and weapon.info.cfg or Config.Weapons[Config.Loadout[1]]
	state.holdFire = false		-- [23/09 noche] se vuelve a decidir en cada vuelta
	state.sneakClose = false

	--  [24/09] Levantando a alguien: quieto (agachado si hay peligro), y si
	--  ve a un enemigo en un angulo que le deja seguir levantando, le dispara
	--  mientras tanto, como puede hacer un jugador. Solo suelta al caido si
	--  un enemigo se le echa encima por un lado que no puede cubrir.
	local reviving = reviveTarget(state)
	if reviving then
		local vChar = reviving.Character
		local vRoot = vChar and vChar:FindFirstChild("HumanoidRootPart")
		if not vRoot or not isDownedCharacter(vChar) then
			if _G.Downed_StopRevive then _G.Downed_StopRevive(state.bot) end
			state.reviveFace, state.reviveShooting = nil, false
		else
			local face, shooting, abort = Tac.reviveFacing(state, vRoot.Position)
			if abort then
				if _G.Downed_StopRevive then _G.Downed_StopRevive(state.bot) end
				state.reviveFace, state.reviveShooting = nil, false
			else
				if shooting and not state.reviveShooting then
					dprint(state.bot.Name, "levanta disparando")
				end
				state.reviveFace, state.reviveShooting = face, shooting
				if state.moveMode ~= "hold" then stopWalking(state) end
				return
			end
		end
	else
		state.reviveFace, state.reviveShooting = nil, false
	end

	--  [23/09 noche] Climas especiales: techo o lugar alto antes que nada
	--  (salvo que tenga a alguien encima).
	if Tac.weatherSafety and Tac.weatherSafety(state, now) then return end

	--  [23/09 noche] Lider en Guardian: si muere, su equipo ya no reaparece.
	--  Juega a no morir: atras, escondido, y solo pelea si se le acercan.
	if Tac.isLeader and Tac.isLeader(state) then
		Tac.leaderMove(state, now)
		return
	end

	--  [24/09] Apoyo: levantar al caido mas cercano va antes que cubrirse o
	--  pelear (salvo que tenga a un enemigo encima). Levanta disparando.
	if state.meta.role and state.meta.role.Kind == "Apoyo" then
		local enemyOnTop = target and state.visible
			and (target.root.Position - state.root.Position).Magnitude < ((Config.Revive and Config.Revive.AbortClose) or 18)
		if not enemyOnTop and Tac.seekRevive(state, now) then return end
	end

	--  [tacticas] Con poca vida: a cubrirse (o sigue escondido).
	if Tac.updateCover and Tac.updateCover(state, now) then return end
	--  [IA v3] En su lugar para asomarse (o yendo a el).
	if Tac.updatePeek and Tac.updatePeek(state, now) then return end

	if target and state.visible then
		local dist = (target.root.Position - state.root.Position).Magnitude
		local reloading = state.reload ~= nil or not weapon or weapon.mag <= 0
		humanoid.WalkSpeed = M.CombatSpeed

		--  [fase 2] Ejecucion: para rematar a un abatido hay que pegarse.
		if executionActive() and isDownedCharacter(target.character) and not reloading then
			local reach = executionReach()
			humanoid.WalkSpeed = WALK_SPEED
			if dist > 14 then
				if state.pathKind ~= "chase" or not state.waypoints or now - state.lastRepath > M.RepathMoving then
					requestPath(state, target.root.Position, "chase")
				end
			elseif dist > reach - 0.5 then
				if state.moveMode ~= "direct" or now - state.lastMoveToAt > 0.3 then
					state.waypoints = nil
					state.moveMode = "direct"
					humanoid:MoveTo(target.root.Position)
					state.lastMoveToAt = now
				end
			elseif state.moveMode ~= "hold" then
				stopWalking(state)
			end
			return
		end

		--  [26/09] Control: sumar puntos es estar en el area (adentro no sale
		--  a perseguir; de afuera va hacia ella disparando).
		if not reloading and Tac.fightForZone and Tac.fightForZone(state, now, dist) then return end

		--  [23/09 noche] Sigiloso: si la presa no lo ha visto y todavia esta
		--  lejos, no dispara (se delataria): sigue acercandose por la espalda.
		local myRole = state.meta.role
		if myRole and myRole.Kind == "Sigiloso" and not reloading then
			local theirLook = flat(target.root.CFrame.LookVector)
			local toMe = flat(state.root.Position - target.root.Position)
			local watchingMe = theirLook.Magnitude > 0.1 and toMe.Magnitude > 0.1 and theirLook.Unit:Dot(toMe.Unit) > 0.5
			local recentlyHit = state.lastDamageAt and now - state.lastDamageAt < 3
			if dist > (myRole.HoldFireRange or 40) and not watchingMe and not recentlyHit then
				state.holdFire = true
				state.sneakClose = dist < (myRole.CrouchRange or 45)
				local back = theirLook.Magnitude > 0.1 and theirLook.Unit or Vector3.zero
				Tac.goTo(state, now, target.root.Position - back * 14, "sneak", state.sneakClose and CROUCH_SPEED or WALK_SPEED, 1.5)
				return
			end
		end

		--  [24/09] Corredora: mantiene la distancia (huye en zigzag si se le
		--  acercan). Camper: dispara desde su punto; si todavia va en camino,
		--  sigue avanzando hacia el mientras dispara.
		if myRole and myRole.Kind == "Corredora" and not reloading then
			if Tac.kite(state, now, target, dist) then return end
		end
		if myRole and myRole.Kind == "Camper" and state.perch and not reloading
			and dist >= (myRole.CloseFight or 15) then
			if not state.perch.arrived then
				Tac.goTo(state, now, state.perch.pos, "perch", WALK_SPEED, 3)
				return
			end
			if dist <= cfg.MaxRange then
				if state.moveMode ~= "hold" then stopWalking(state) end
				return
			end
		end

		--  [tacticas] Distancias segun el arma y el tipo de IA. El que esta en
		--  su puesto (defensiva, angulo del estratega) o trae francotirador no
		--  persigue: se queda y dispara desde ahi.
		--  [23/09 noche] Con clima peligroso y a resguardo, no sale a buscarlo:
		--  le dispara desde donde esta.
		--  [IA v2] Solo si ya esta herido: sano, pelea como siempre.
		local healthFrac = humanoid.Health / math.max(humanoid.MaxHealth, 1)
		if not reloading and dist <= cfg.MaxRange and Tac.hazards(now)
			and healthFrac < Tac.AI.WeatherPanicHealth
			and not state.skyExposed and not state.inWater
			and not (state.noShelterUntil and now < state.noShelterUntil) then
			if state.moveMode ~= "hold" then stopWalking(state) end
			return
		end

		local role = state.meta.role
		local rangeMult = (role and role.RangeMult) or 1
		local idealMin, idealMax = cfg.IdealMin * rangeMult, cfg.IdealMax * rangeMult
		local atPost = (state.hold and state.hold.arrived) or (state.watch and state.watch.arrived)
			or (state.perch and state.perch.arrived)
		--  [IA v3] Al descubierto a media / larga distancia: un lugar cerca para
		--  asomarse (ventana, muro bajo, cresta) en vez de quedarse parado. El
		--  francotirador tambien (es el que mas lo aprovecha).
		if not atPost and not reloading and Tac.considerPeek and Tac.considerPeek(state, now, target, dist) and Tac.updatePeek(state, now) then
			return
		end
		local posted = atPost or cfg.Role == "Sniper"
		if posted and not reloading and dist <= cfg.MaxRange then
			if state.moveMode ~= "hold" then stopWalking(state) end
			return
		end

		--  [IA v2] Enemigo debil (poca vida, o un bot recargando): a rematarlo.
		local targetBrain = brains[target.participant]
		local targetWeak = target.humanoid.Health / math.max(target.humanoid.MaxHealth, 1) < 0.35
			or (targetBrain ~= nil and targetBrain.reload ~= nil)
		if targetWeak and not reloading and healthFrac > 0.5 and dist > 10 then
			if not state.pushDecidedFor or state.pushDecidedFor ~= target.character or now > (state.pushUntil or 0) then
				state.pushDecidedFor = target.character
				state.pushUntil = now + 2.5
				state.pushing = state.rng:NextNumber() < Tac.AI.PushChance
			end
			if state.pushing and state.pathFails < 3 then
				humanoid.WalkSpeed = RUN_SPEED
				requestPath(state, target.root.Position, "chase")
				return
			end
		end

		if reloading and dist < 60 then
			--  [IA v2] Recargando con alguien cerca: primero, una cobertura
			--  cerca para recargar tranquilo (Tac.updateCover la maneja).
			if dist < Tac.AI.ReloadCoverRange and Tac.tryReloadCover and Tac.tryReloadCover(state, now, target) then
				return
			end
			--  Recargando con alguien cerca: se aleja de lado/atras.
			if state.moveMode ~= "strafe" or now >= state.strafeUntil then
				local away = flat(state.root.Position - target.root.Position)
				local side = state.root.CFrame.RightVector * (state.rng:NextNumber() < 0.5 and -1 or 1)
				humanoid.WalkSpeed = WALK_SPEED
				startStrafe(state, now, (away.Magnitude > 0.1 and away.Unit or side) + side, 0.9)
			end
		elseif dist > idealMax * 1.15 then
			--  Muy lejos para el arma que tiene: se acerca.
			if dist > idealMax * 2 then humanoid.WalkSpeed = WALK_SPEED end
			--  [IA v2] No hay forma de llegar (en un techo, un balcon): se queda
			--  disparando desde donde esta y reintenta cada tanto.
			if state.pathFails >= 3 and now - state.lastRepath < 5 then
				if state.moveMode == "path" or state.moveMode == "direct" then stopWalking(state) end
			elseif state.pathKind ~= "chase" or not state.waypoints or now - state.lastRepath > M.RepathMoving then
				requestPath(state, target.root.Position, "chase")
			end
		elseif dist < idealMin then
			--  Demasiado cerca (rifle contra alguien pegado): da un paso atras.
			if state.moveMode ~= "strafe" or now >= state.strafeUntil then
				local away = flat(state.root.Position - target.root.Position)
				local side = state.root.CFrame.RightVector * (state.rng:NextNumber() < 0.5 and -0.6 or 0.6)
				startStrafe(state, now, (away.Magnitude > 0.1 and away.Unit or side) + side, 0.7)
			end
		elseif now >= state.nextDecisionAt then
			--  En su rango: se mueve de lado o se planta, segun el preset.
			state.nextDecisionAt = now + rangeNumber(state.rng, M.StrafeTime)
			if state.rng:NextNumber() < state.aim.StrafeChance + ((state.meta.role and state.meta.role.StrafeBonus) or 0) then
				--  [IA v2] ADAD como un jugador: si ya iba de lado, cambia de lado.
				local sign = state.rng:NextNumber() < 0.5 and -1 or 1
				if state.moveMode == "strafe" and state.strafeDir then
					sign = state.strafeDir:Dot(state.root.CFrame.RightVector) > 0 and -1 or 1
				end
				startStrafe(state, now, state.root.CFrame.RightVector * sign)
				--  [IA v2] De cerca, a veces salta mientras se mueve de lado.
				if dist < 30 and not state.galeExposed and state.rng:NextNumber() < Tac.AI.CombatJumpChance
					and humanoid.FloorMaterial ~= Enum.Material.Air then
					humanoid.Jump = true
				end
			else
				stopWalking(state)
				--  [IA v2] Plantado a disparar: a veces se agacha un momento.
				if state.rng:NextNumber() < Tac.AI.CombatCrouchChance then
					state.crouchUntil = now + state.rng:NextNumber(0.7, 1.6)
				end
			end
		end
		return
	end

	--  [fase 2 / 24/09] Un companero en el suelo: ir a levantarlo (antes que
	--  perseguir a nadie), desde una posicion razonable.
	if Tac.seekRevive(state, now) then return end

	--  [26/09] Control: al area y a quedarse adentro.
	if Tac.playObjective and Tac.playObjective(state, now) then return end

	--  [IA v3] Esperando abajo al que se subio donde no se puede llegar.
	if Tac.ambushStep and Tac.ambushStep(state, now) then return end

	--  [24/09] Ordenes del Lider del equipo (bot de tipo Lider).
	if Tac.followOrders and Tac.followOrders(state, now) then return end

	--  [tacticas] Lo que hace cada tipo de IA cuando no esta peleando.
	if Tac.roleBehavior and Tac.roleBehavior(state, now) then return end

	if target and state.lastSeenPos then
		--  Lo perdio de vista: va a donde lo vio por ultima vez.
		--  [IA v2] ...o a donde iba corriendo (Tac.predictSearch), apuntando
		--  hacia alla mientras se acerca, como alguien que "pre-apunta".
		local goal = state.searchPos or state.lastSeenPos
		local distToLast = flat(goal - state.root.Position).Magnitude
		humanoid.WalkSpeed = distToLast > 40 and RUN_SPEED or WALK_SPEED
		if distToLast < M.ArriveDistance + 1 or state.pathFails >= 3 then
			--  [IA v3] No se puede llegar hasta donde se fue (mas arriba): lo espera
			--  desde un lugar que lo vea, en vez de rendirse.
			if state.pathFails >= 3 and goal.Y - state.root.Position.Y > 3 and Tac.startAmbush and Tac.startAmbush(state, now, goal) then
				state.pathFails = 0
				return
			end
			state.target = nil
			state.pathFails = 0
			--  Mira hacia donde se fue; si no se sabe, a un costado.
			local vel = state.lastSeenVel
			if vel and vel.Magnitude > 2 then
				state.lookAt = goal + vel.Unit * 25
			else
				state.lookAt = state.root.Position + state.root.CFrame.RightVector * (state.rng:NextNumber() < 0.5 and -20 or 20)
			end
			state.lookUntil = now + 1.4
			state.searchPos = nil
			stopWalking(state)
		else
			if distToLast < 45 then
				state.lookAt = goal + Vector3.new(0, 2, 0)
				state.lookUntil = now + 0.5
			end
			if state.pathKind ~= "search" or (not state.waypoints and not state.pathBusy) or now - state.lastRepath > M.RepathMoving * 2 then
				requestPath(state, Tac.weatherGoal(state, goal, now, true), "search")
			end
		end
		return
	end

	if state.noise and now - state.noise.at < 8 then
		--  Escucho algo: va a ver.
		local distToNoise = flat(state.noise.pos - state.root.Position).Magnitude
		--  [IA v2] De lejos corre; cerca camina apuntando hacia el ruido.
		humanoid.WalkSpeed = distToNoise > 45 and RUN_SPEED or WALK_SPEED
		if distToNoise < M.ArriveDistance + 2 or state.pathFails >= 3 then
			state.noise = nil
			state.pathFails = 0
		else
			if distToNoise < 45 then
				state.lookAt = state.noise.pos + Vector3.new(0, 2, 0)
				state.lookUntil = now + 0.5
			end
			if state.pathKind ~= "noise" or (not state.waypoints and not state.pathBusy) then
				requestPath(state, Tac.weatherGoal(state, state.noise.pos, now, true), "noise")
			end
		end
		return
	end
	state.noise = nil

	--  Paseando / buscando pelea.
	humanoid.WalkSpeed = state.roamRun and RUN_SPEED or WALK_SPEED
	local idle = not state.waypoints and not state.pathBusy and state.moveMode ~= "strafe"
		and not (state.moveMode == "direct" and state.directGoal)		-- [IA v2] yendo derecho (plan B)
	if (idle and now >= state.nextRoamAt) or (state.pathKind == "roam" and state.waypoints and now - state.lastRepath > M.RepathRoam * 3) then
		state.nextRoamAt = now + state.rng:NextNumber(0.3, 1.5)
		state.roamRun = state.rng:NextNumber() < ((state.meta.role and state.meta.role.RunChance) or 0.7)
		--  [23/09 noche] Con clima peligroso, solo a destinos seguros.
		local roamGoal = pickRoamGoal(state)
		--  [IA v3] Uno que ya se sabe inalcanzable: otro.
		for _ = 1, 2 do
			if roamGoal and Tac.isUnreachable(roamGoal) then roamGoal = pickRoamGoal(state) end
		end
		if Tac.safeRoamGoal then roamGoal = Tac.safeRoamGoal(state, roamGoal, now) end
		if roamGoal then requestPath(state, roamGoal, "roam") end
	elseif idle and state.pathFails >= 4 then
		--  No encuentra camino a nada: un par de pasos al azar para despegarse.
		state.pathFails = 0
		local dir = Vector3.new(state.rng:NextNumber(-1, 1), 0, state.rng:NextNumber(-1, 1))
		startStrafe(state, now, dir, 1)
	end
end

local function think(state, now, dt)
	state.thinkTick += 1
	if Tac.updateLod then Tac.updateLod(state, now) end		-- [IA v2] piensa mas lento lejos de jugadores
	perceive(state, now, dt)

	--  Arma
	local wanted = chooseWeapon(state, now)
	if wanted and wanted ~= state.current and now - state.lastSwitchAt > 0.8 then
		equipWeapon(state, wanted, now)
	end

	--  Recarga
	local weapon = state.weapons[state.current]
	if weapon and not state.reload and now >= state.equipUntil then
		if weapon.mag <= 0 and weapon.reserve > 0 then
			startReload(state, now)
		elseif not state.visible and (now - state.lastSeenAt) > Config.CalmReloadAfter
			and weapon.mag < weapon.info.magSize * 0.75 and weapon.reserve > 0 then
			startReload(state, now)
		end
	end

	decideMovement(state, now)
	updateWindStance(state, now)		-- [fase 3] ventarron (y ahora cualquier razon para agacharse)
	if Tac.maybeSlide then Tac.maybeSlide(state, now) end		-- [tacticas] barrida
	if Tac.updateArmPose then Tac.updateArmPose(state) end		-- [tacticas] brazos: apuntar / correr
	if Tac.checkDoors then Tac.checkDoors(state, now) end		-- [23/09 noche] abrir puertas
	if Tac.leaderTick then Tac.leaderTick(state, now) end		-- [24/09] el Lider da ordenes (aunque este peleando)
	if Tac.checkConfined then Tac.checkConfined(state, now) end		-- [IA v2] encerrado: explorar / ventana
	checkStuck(state, now)
end

--==========================================================================
--  CUERPO: mirar, cuello, animaciones, proteccion
--==========================================================================
local function updateFacing(state, now, dt)
	local humanoid, root = state.humanoid, state.root
	local facePos, pitchPos = nil, nil
	local target = state.target
	if state.reviveFace then
		--  Levantando a alguien: mira al caido o, si lo puede cubrir desde ahi,
		--  al enemigo al que le esta disparando (siguiendolo en vivo).
		facePos = state.reviveFace
		if state.reviveShooting and target and state.visible then
			facePos = target.root.Position
			local aimPart = (state.headAim and target.head) or target.torso or target.root
			pitchPos = aimPart and aimPart.Position or facePos
		end
	elseif target and state.visible then
		facePos = target.root.Position
		local aimPart = (state.headAim and target.head) or target.torso or target.root
		pitchPos = aimPart and aimPart.Position or facePos
	elseif target and state.lastSeenPos and now - state.lastSeenAt < 1.2 then
		facePos = state.lastSeenPos
	elseif state.lookAt and now < state.lookUntil then
		facePos = state.lookAt
	end

	--  [IA v2] Cada propiedad que se cambia viaja por red a todos los
	--  clientes: solo se escribe cuando de verdad cambio.
	if facePos then
		local dir = flat(facePos - root.Position)
		if dir.Magnitude > 0.3 then
			local unit = dir.Unit
			if not state.alignDir or state.alignDir:Dot(unit) < 0.9998 then
				state.align.CFrame = CFrame.lookAt(Vector3.zero, unit)
				state.alignDir = unit
			end
		end
		if not state.align.Enabled then state.align.Enabled = true end
		if humanoid.AutoRotate then humanoid.AutoRotate = false end
	else
		if state.align.Enabled then state.align.Enabled = false end
		if not humanoid.AutoRotate then humanoid.AutoRotate = true end
	end

	--  Cuello: el AnimBase (brazos + arma) va soldado a la cabeza, asi que
	--  inclinarla es apuntar arriba/abajo.
	--  [fase 2] Abatido el cuello es de DownedServer (postura en el suelo).
	if state.neck and state.downed == "" then
		local pitch = 0
		if pitchPos then
			local d = pitchPos - state.head.Position
			pitch = math.atan2(d.Y, math.max(flat(d).Magnitude, 0.1))
		end
		pitch = math.clamp(pitch, -1.1, 1.1)
		state.pitch += (pitch - state.pitch) * math.min(1, dt * 12)
		if not state.sentPitch or math.abs(state.pitch - state.sentPitch) > 0.01 then
			state.neck.C0 = state.neckBase * CFrame.Angles(state.pitch, 0, 0)
			state.sentPitch = state.pitch
		end
	end
end

local function playAnimation(state, key, speed)
	if state.animKey ~= key then
		if state.animTrack then state.animTrack:Stop(0.2) end
		local track = state.tracks[key]
		if track then track:Play(0.2) end
		state.animTrack = track
		state.animKey = key
		state.animSpeed = nil
	end
	if state.animTrack and speed and (not state.animSpeed or math.abs(speed - state.animSpeed) > 0.08) then
		state.animTrack:AdjustSpeed(speed)
		state.animSpeed = speed
	end
end

local function updateAnimation(state)
	local S = Enum.HumanoidStateType
	local humanoidState = state.humanoid:GetState()
	local speed = flat(state.root.AssemblyLinearVelocity).Magnitude
	--  [IA v2] Trepando un borde (parkour): animacion de trepar.
	if state.climbAnimUntil and os.clock() < state.climbAnimUntil then
		playAnimation(state, "climb", 1.6)
	elseif humanoidState == S.Freefall then
		playAnimation(state, "fall")
	elseif humanoidState == S.Jumping then
		playAnimation(state, "jump")
	elseif humanoidState == S.Climbing then
		playAnimation(state, "climb")
	elseif humanoidState == S.Swimming then
		playAnimation(state, speed > 1 and "swim" or "swimidle")
	elseif speed > 19 then
		playAnimation(state, "run", speed / 20)
	elseif speed > 0.8 then
		playAnimation(state, "walk", math.max(speed / 14, 0.5))
	else
		playAnimation(state, "idle", 1)
	end
end

local function updateProtection(state, now)
	if not state.forceField then return end
	local S = Config.SpawnProtection
	if now > state.protectedUntil or (state.root.Position - state.spawnPos).Magnitude > S.MoveStuds then
		removeProtection(state)
	end
end

--==========================================================================
--  ABATIDO (fase 2)
--
--  DownedServer lleva el estado del bot abatido exactamente igual que el
--  de un jugador: vida, desangrado, posturas, animaciones, forcejeo, quien
--  lo tumbo, revivir. Lo que en un jugador hace DownedClient (el dueno de
--  la fisica de su Humanoid: PlatformStand, apoyarlo en el suelo, sujetar
--  la altura, la velocidad de arrastre) aqui lo hace el servidor, que es
--  el dueno del cuerpo del bot. Mismos pasos, mismos valores (DownedConfig).
--==========================================================================
local downedParams = RaycastParams.new()
downedParams.FilterType = Enum.RaycastFilterType.Exclude

local function findGroundY(state)
	local reference = state.character:FindFirstChild("LowerTorso") or state.root
	downedParams.FilterDescendantsInstances = { state.character, ACS_Workspace }
	local hit = workspace:Raycast(reference.Position + Vector3.new(0, 6, 0), Vector3.new(0, -200, 0), downedParams)
	if hit then return hit.Position.Y end
	return state.character:GetAttribute("DownedGroundY")
end

--  Un salto brusco en la lectura del suelo (una junta entre MeshParts) no
--  se cree a la primera; si insiste 5 vueltas, era un escalon de verdad.
local function stableGroundY(state)
	local groundY = findGroundY(state)
	if not groundY then return nil end
	local tolerance = DownedConfig.GroundJumpTolerance or 3
	if state.lastGroundY and math.abs(groundY - state.lastGroundY) > tolerance then
		state.groundSuspect = (state.groundSuspect or 0) + 1
		if state.groundSuspect < 5 then return state.lastGroundY end
	end
	state.groundSuspect = 0
	state.lastGroundY = groundY
	return groundY
end

--  Enderezar (solo giro horizontal) y apoyar la raiz en el suelo.
local function placeOnGround(state)
	local humanoid, root = state.humanoid, state.root
	local look = flat(root.CFrame.LookVector)
	look = look.Magnitude > 0.01 and look.Unit or Vector3.new(0, 0, -1)
	local position = root.Position
	local groundY = findGroundY(state)
	if groundY then
		position = Vector3.new(position.X, groundY + humanoid.HipHeight + root.Size.Y * 0.5 + 0.05, position.Z)
	end
	root.CFrame = CFrame.lookAt(position, position + look)
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
end

local function stopLocomotion(state)
	if state.animTrack then
		pcall(function() state.animTrack:Stop(0.15) end)
	end
	state.animTrack = nil
	state.animKey = nil
end

--  Se llama cada vez que DownedServer cambia el atributo DownedState.
local function applyDownedState(state)
	if state.dead then return end
	local newState = state.character:GetAttribute("DownedState") or ""
	local previous = state.downed or ""
	if newState == previous then return end
	state.downed = newState
	state.lastGroundY = nil
	state.groundSuspect = 0

	local humanoid = state.humanoid
	local S = Enum.HumanoidStateType
	local now = os.clock()

	if newState == "" then
		--  Se levanto (solo o porque lo revivieron).
		for _, humanoidState in ipairs({ S.Jumping, S.Climbing, S.GettingUp, S.FallingDown, S.Freefall }) do
			humanoid:SetStateEnabled(humanoidState, true)
		end
		humanoid.PlatformStand = false
		humanoid.AutoRotate = true
		if previous == "Ragdoll" then placeOnGround(state) end
		humanoid:ChangeState(S.GettingUp)
		humanoid.UseJumpPower = true
		humanoid.JumpPower = JUMP_POWER
		humanoid.WalkSpeed = WALK_SPEED
		state.proneArmed = false
		state.reload = nil
		state.waypoints = nil
		state.moveMode = "hold"
		state.progressPos = state.root.Position
		state.progressAt = now
		--  El ragdoll le quito el rig del arma: la vuelve a sacar.
		local weapon = state.current and state.weapons[state.current]
		if weapon then
			mountWeapon(state, weapon.info)
			state.equipUntil = now + weapon.info.cfg.EquipTime
		end
		dprint(state.bot.Name, "se levanto")
		return
	end

	--  Cae, o cambia de postura en el suelo: suelta todo lo que hacia.
	if _G.Downed_StopRevive then _G.Downed_StopRevive(state.bot) end
	state.reviveFace = nil
	state.waypoints = nil
	state.moveMode = "hold"
	state.burstLeft = 0
	humanoid:Move(Vector3.zero)
	humanoid:MoveTo(state.root.Position)
	state.align.Enabled = false
	stopLocomotion(state)
	--  [fase 3] La postura del cuerpo ahora es de DownedServer: se suelta la
	--  de agachado sin tocar los joints (el guarda la de pie para revivir).
	cancelStanceTweens(state)
	state.stance = 0
	state.slide = nil
	state.cover = nil
	state.character:SetAttribute("ACS_Stance", 0)
	humanoid:SetStateEnabled(S.Jumping, false)
	humanoid:SetStateEnabled(S.Climbing, false)

	if newState == "Ragdoll" then
		state.reload = nil
		state.downedSince = now
		humanoid:SetStateEnabled(S.GettingUp, false)
		humanoid:SetStateEnabled(S.FallingDown, false)
		humanoid.AutoRotate = false
		humanoid.PlatformStand = true
		humanoid:ChangeState(S.Physics)
		dprint(state.bot.Name, "abatido")
		return
	end

	if previous == "Ragdoll" then
		humanoid:SetStateEnabled(S.GettingUp, true)
		humanoid:SetStateEnabled(S.FallingDown, true)
		humanoid.PlatformStand = false
		humanoid.AutoRotate = true
		placeOnGround(state)
		humanoid:ChangeState(S.GettingUp)
		--  Repasos, como DownedClient: los motores se vuelven a soldar un
		--  instante despues y la primera medida del suelo puede salir mal.
		for _, delay in ipairs({ 0.2, 0.6 }) do
			task.delay(delay, function()
				if state.dead or state.downed == "" or state.downed == "Ragdoll" then return end
				local humanoidState = humanoid:GetState()
				if humanoidState == S.Physics or humanoidState == S.FallingDown or humanoidState == S.Ragdoll then
					humanoid.PlatformStand = false
					humanoid:ChangeState(S.Running)
				end
				placeOnGround(state)
			end)
		end
		--  Tarda un poco en "darse cuenta" antes de empezar a forcejear.
		state.nextStrugglePress = now + rangeNumber(state.rng, state.react.Reaction) + 0.3
	end
	if DownedConfig.PreventFreefallWhileDowned ~= false then
		humanoid:SetStateEnabled(S.Freefall, false)
		humanoid:SetStateEnabled(S.FallingDown, false)
	end
end

--  Cada frame estando en el suelo (lo que hace el bucle de DownedClient).
local function enforceDowned(state, now, dt)
	local humanoid, root = state.humanoid, state.root
	local S = Enum.HumanoidStateType
	if state.downed == "Ragdoll" then
		if not humanoid.PlatformStand then
			humanoid.PlatformStand = true
			humanoid.AutoRotate = false
			humanoid:ChangeState(S.Physics)
		end
		if humanoid.WalkSpeed ~= 0 then humanoid.WalkSpeed = 0 end
		if humanoid.JumpPower ~= 0 then humanoid.JumpPower = 0 end
		return
	end

	if humanoid.PlatformStand then
		humanoid.PlatformStand = false
		humanoid.AutoRotate = true
	end
	local humanoidState = humanoid:GetState()
	if (humanoidState == S.Physics or humanoidState == S.Ragdoll) and now - (state.lastStateFix or 0) > 0.25 then
		state.lastStateFix = now
		humanoid:ChangeState(S.GettingUp)
	end

	--  Sujecion vertical: abatido no colisiona ningun miembro, asi que solo
	--  lo sostiene el Humanoid. Se le corrige la altura poco a poco.
	if DownedConfig.HoldHeightWhileDowned ~= false then
		local groundY = stableGroundY(state)
		if groundY then
			local wanted = groundY + humanoid.HipHeight + root.Size.Y * 0.5
			local dy = wanted - root.Position.Y
			if math.abs(dy) > 0.02 and math.abs(dy) < 12 then
				local alpha = math.clamp((DownedConfig.HoldHeightSpeed or 12) * dt, 0, 1)
				root.CFrame = root.CFrame + Vector3.new(0, dy * alpha, 0)
			end
			local velocity = root.AssemblyLinearVelocity
			if math.abs(velocity.Y) > 0.01 then
				root.AssemblyLinearVelocity = Vector3.new(velocity.X, 0, velocity.Z)
			end
		end
	end
	if humanoidState == S.Freefall then
		state.downedFall = (state.downedFall or 0) + dt
		if state.downedFall > 0.35 then
			state.downedFall = 0
			placeOnGround(state)
		end
	else
		state.downedFall = 0
	end

	local speed = DownedConfig.CrawlWalkSpeed or 6
	if state.downed == "Prone" then
		speed = DownedConfig.ProneWalkSpeed or 3.5
		if state.character:GetAttribute("DownedArmed") and DownedConfig.CanMoveWhileArmed ~= true then
			speed = 0
		end
	end
	if humanoid.WalkSpeed ~= speed then humanoid.WalkSpeed = speed end
	if humanoid.JumpPower ~= 0 then humanoid.JumpPower = 0 end
	if humanoid.Jump then humanoid.Jump = false end
end

--  Companero de pie mas cercano (para arrastrarse hacia el).
local function nearestHelper(state)
	if isFFA() then return nil end
	local myTeam = teamOf(state.bot)
	if not myTeam or myTeam == "Neutral" or myTeam == "Lobby" then return nil end
	local best, bestDist = nil, math.huge
	for _, participant in ipairs(Registry.participants()) do
		if participant ~= state.bot and participant:GetAttribute("InRound") == true
			and teamOf(participant) == myTeam then
			local character = participant.Character
			if character and not isDownedCharacter(character) then
				local entry = describeTarget(participant, character, state.root.Position)
				if entry and entry.dist < bestDist then
					best, bestDist = entry, entry.dist
				end
			end
		end
	end
	return best, bestDist
end

--  Decisiones estando en el suelo.
local function thinkDowned(state, now, dt)
	local D = Config.Downed or {}
	if state.downed == "Ragdoll" then return end
	state.thinkTick += 1
	perceive(state, now, dt)

	--  Arrastrandose (ya sin intentos): saca la pistola y pelea desde ahi.
	if state.downed == "Prone" and D.ShootWhileProne ~= false and not state.proneArmed then
		local pistol = nil
		for _, name in ipairs(state.meta.loadout or Config.Loadout) do
			local weapon = state.weapons[name]
			if weapon and weapon.info.cfg.Role == "Pistol" and hasAmmo(weapon) then pistol = name end
		end
		if pistol and _G.Downed_SetArmed and _G.Downed_SetArmed(state.bot, true) then
			state.proneArmed = true
			state.current = pistol
			state.reload = nil
			state.bot:SetAttribute("BotWeapon", pistol)
			mountWeapon(state, state.weapons[pistol].info)
			state.equipUntil = now + 0.9
		end
	end

	if state.proneArmed then
		--  Con la pistola en la mano no se mueve: recarga y dispara.
		if state.moveMode ~= "hold" then stopWalking(state) end
		local weapon = state.weapons[state.current]
		if weapon and not state.reload and weapon.mag <= 0 and weapon.reserve > 0 then
			startReload(state, now)
		end
		return
	end

	--  Hay un companero de pie cerca: se arrastra hacia el y espera que lo
	--  levante (un rato; si no viene nadie, forcejea igual).
	local helper, helperDist = nearestHelper(state)
	local waiting = helper and helperDist <= (D.WaitForTeammateRange or 45)
		and (now - (state.downedSince or now)) < (D.WaitForTeammateMax or 14)
	if waiting then
		if helperDist > 6 then
			if (not state.waypoints and not state.pathBusy) or now - state.lastRepath > 2 then
				requestPath(state, helper.root.Position, "crawl")
			end
		elseif state.moveMode ~= "hold" then
			stopWalking(state)
		end
		return
	end

	if state.downed == "Crawl" then
		--  Nadie viene: forcejear para levantarse solo. Moverse corta la
		--  barra, asi que se queda quieto.
		if state.moveMode ~= "hold" then stopWalking(state) end
		if now >= (state.nextStrugglePress or 0) then
			state.nextStrugglePress = now + rangeNumber(state.rng, D.StrugglePress or { 0.1, 0.17 })
			if _G.Downed_BotStruggle then _G.Downed_BotStruggle(state.bot) end
		end
	elseif helper and ((not state.waypoints and not state.pathBusy) or now - state.lastRepath > 2.5) then
		--  Arrastrandose sin pistola: igual se acerca al companero mas cercano.
		requestPath(state, helper.root.Position, "crawl")
	end
end

--==========================================================================
--  CICLO
--==========================================================================
--==========================================================================
--  TACTICAS  (23/09/2026, tarde)
--
--  Tipos de IA (BotConfig.Roles), cobertura con poca vida, barrida, poses
--  de brazos (apuntar / correr), lamparas de noche, recompensa por baja y
--  el aviso "vi a uno aqui" entre bots del mismo equipo.
--  Todo cuelga de la tabla Tac (declarada arriba) para no sumar locals.
--==========================================================================
Tac.params = RaycastParams.new()
Tac.params.FilterType = Enum.RaycastFilterType.Exclude
Tac.params.IgnoreWater = true
Tac.intelByTeam = {}
Tac.armTween = TweenInfo.new(0.25, Enum.EasingStyle.Sine)
do
	local attModels = Engine:FindFirstChild("AttModels")
	Tac.flashlightModel = attModels and attModels:FindFirstChild("Flashlight") or nil
end

--  El mundo sin personajes ni las balas de ACS (para buscar cobertura,
--  puestos y angulos).
--  [IA v2] Se pedia cientos de veces por segundo (armando la lista cada
--  vez): ahora se arma como mucho cada 0.15 s y se comparte. NO modificar
--  la tabla que devuelve (usar table.clone si hace falta agregarle cosas).
--  Tambien quita los cadaveres (workspace.Cuerpos): no son paredes.
function Tac.worldFilter()
	local now = os.clock()
	if Tac.filterCache and now - Tac.filterAt < 0.15 then return Tac.filterCache end
	local filter = { ACS_Workspace }
	for _, participant in ipairs(Registry.participants()) do
		local character = participant.Character
		if character then table.insert(filter, character) end
	end
	local corpses = workspace:FindFirstChild("Cuerpos")
	if corpses then table.insert(filter, corpses) end
	Tac.filterCache, Tac.filterAt = filter, now
	return filter
end

--  [23/09 noche] Con clima peligroso, un destino a la intemperie / en el
--  agua se cambia por uno seguro cerca de el (se recuerda mientras el
--  destino no cambie). Si no hay ninguno, se queda donde esta.
--  [IA v2] urgent = va a pelear (ruido, persecucion, avisos): ahi el clima
--  no le cambia el destino, salvo que ya este herido.
function Tac.weatherGoal(state, goal, now, urgent)
	if not goal or not Tac.hazards(now) then return goal end
	if urgent and state.humanoid.Health / math.max(state.humanoid.MaxHealth, 1) >= Tac.AI.WeatherPanicHealth then
		return goal
	end
	--  No hay donde resguardarse cerca: juega normal.
	if state.noShelterUntil and now < state.noShelterUntil then return goal end
	if state.weatherGoalFrom and (state.weatherGoalFrom - goal).Magnitude < 4 then
		return state.weatherGoalTo
	end
	local adjusted = Tac.safeRoamGoal(state, goal, now) or state.root.Position
	state.weatherGoalFrom = goal
	state.weatherGoalTo = adjusted
	return adjusted
end

--  [IA v2] Destinos "de pelea": el clima no los cambia y, si se acabo el
--  presupuesto de caminos, pueden pedir prestado.
Tac.combatKinds = {
	chase = true, search = true, noise = true, intel = true, support = true, order = true,
	sneak = true, flee = true, cover = true, revive = true, crawl = true, leadercover = true,
	zone = true,		-- [26/09] Control: ir al area
}

--  Ir a un punto, recalculando el camino cada 'every' segundos.
function Tac.goTo(state, now, goal, kind, speed, every)
	if kind ~= "safe" then goal = Tac.weatherGoal(state, goal, now, Tac.combatKinds[kind]) end
	state.humanoid.WalkSpeed = speed
	if state.pathKind ~= kind or (not state.waypoints and not state.pathBusy) or now - state.lastRepath > (every or 2) then
		requestPath(state, goal, kind)
	end
end

--==========================================================================
--  IA v2: CAMINOS, PARKOUR, OIDO (25/09/2026)
--==========================================================================
--  Rayos del movimiento: ignoran piezas sin colision (zonas, triggers) y el
--  agua (un charco no es piso para saltarse puntos del camino).
Tac.moveParams = RaycastParams.new()
Tac.moveParams.FilterType = Enum.RaycastFilterType.Exclude
Tac.moveParams.IgnoreWater = true
Tac.moveParams.RespectCanCollide = true
--  Personajes delante (para esquivarlos).
Tac.bumpParams = RaycastParams.new()
Tac.bumpParams.FilterType = Enum.RaycastFilterType.Exclude
Tac.bumpParams.IgnoreWater = true
--  Techo encima (clima): aparte para no pisar el filtro de quien lo llama.
Tac.shelterParams = RaycastParams.new()
Tac.shelterParams.FilterType = Enum.RaycastFilterType.Exclude
Tac.shelterParams.IgnoreWater = true

--  Tercer agente: angosto, para pasillos y puertas chicas.
Tac.tightAgent = { AgentRadius = 1.1, AgentHeight = 5, AgentCanJump = true, AgentCanClimb = true,
	WaypointSpacing = 4, Costs = { Water = 6 } }
Tac.tightWalkAgent = { AgentRadius = 1.1, AgentHeight = 5, AgentCanJump = false, AgentCanClimb = true,
	WaypointSpacing = 4, Costs = { Water = 6 } }

-- --------------------------------------------------------------------------
--  Presupuesto de caminos (entre todos los bots). Se recarga en Heartbeat.
-- --------------------------------------------------------------------------
Tac.pathTokens = Tac.AI.PathBurst

function Tac.takePathToken(kind, retry)
	local floor = (retry or Tac.combatKinds[kind]) and (1 - Tac.AI.PathOverdraw) or 1
	if Tac.pathTokens < floor then return false end
	Tac.pathTokens -= 1
	return true
end

--  En que orden probar los agentes. Si el destino esta mas alto (o se acaba
--  de atorar) primero el que salta; si se atoro, primero el angosto.
function Tac.pathOrder(state, startPos, goal)
	local now = os.clock()
	local tight = Tac.AI.TightAgent
	if tight then
		state.pathTight = state.pathTight or PathfindingService:CreatePath(Tac.tightAgent)
		state.pathTightWalk = state.pathTightWalk or PathfindingService:CreatePath(Tac.tightWalkAgent)
	end
	--  Acaba de rendirse con un salto que no le daba: solo caminos sin saltar
	--  (tambien el angosto: por ahi suele estar la salida real).
	if state.noJumpPathUntil and now < state.noJumpPathUntil then
		return tight and { state.pathTightWalk, state.path } or { state.path }
	end
	local list
	if goal.Y - startPos.Y > 4 or (state.preferJumpUntil and now < state.preferJumpUntil) then
		list = { state.pathJump, state.path }
	else
		list = { state.path, state.pathJump }
	end
	if tight then
		if state.preferTightUntil and now < state.preferTightUntil then
			table.insert(list, 1, state.pathTight)
		else
			table.insert(list, state.pathTight)
		end
	end
	--  El que funciono hace poco, primero (en un edificio con puertas chicas
	--  el angosto sirve siempre; asi no se gastan dos calculos fallidos antes).
	local good = state.goodPath
	if good and now - (state.goodPathAt or -100) < 30 then
		for i, path in ipairs(list) do
			if path == good then
				table.remove(list, i)
				table.insert(list, 1, good)
				break
			end
		end
	end
	return list
end

--  Un punto libre cerca (para cuando el inicio o el destino del camino cae
--  dentro de una pieza): sube un poco y prueba alrededor.
Tac.overlap = OverlapParams.new()
Tac.overlap.FilterType = Enum.RaycastFilterType.Exclude
Tac.overlap.RespectCanCollide = true
function Tac.freePoint(state, pos)
	local params = Tac.moveParams
	local filter = Tac.worldFilter()
	params.FilterDescendantsInstances = filter
	Tac.overlap.FilterDescendantsInstances = filter
	for _, offset in ipairs({ Vector3.new(0, 2, 0), Vector3.new(2.5, 1, 0), Vector3.new(-2.5, 1, 0), Vector3.new(0, 1, 2.5), Vector3.new(0, 1, -2.5) }) do
		local candidate = pos + offset
		local floor = workspace:Raycast(candidate, Vector3.new(0, -6, 0), params)
		if floor then
			local point = Vector3.new(candidate.X, floor.Position.Y + 2.5, candidate.Z)
			if #workspace:GetPartBoundsInRadius(point, 1, Tac.overlap) == 0 then return point end
		end
	end
	return nil
end

--  Sin camino posible (pieza rara, navmesh roto, destino sobre algo): si
--  esta cerca, va derecho; el parkour y el anti-atasco hacen el resto.
function Tac.directFallback(state, goal)
	local AI = Tac.AI
	if state.moveMode == "strafe" then return end
	--  Peleando, el movimiento lo decide el combate (salvo que fuera a perseguir).
	if state.visible and state.pathKind ~= "chase" then return end
	local root = state.root
	local delta = goal - root.Position
	if flat(delta).Magnitude > AI.DirectRange or delta.Y > AI.MantleMaxHeight + 3 then return end
	--  Ya se rindio aca hace poco: no insistir.
	if Tac.nearBlocked(state, root.Position) or Tac.nearBlocked(state, goal) then return end
	--  Una pared mas alta de lo que puede trepar en el medio: ni lo intenta
	--  (si no, se quedaba contra la pared saltando).
	local feetY = root.Position.Y - state.humanoid.HipHeight - root.Size.Y * 0.5
	local from = Vector3.new(root.Position.X, feetY + math.max(AI.MantleMaxHeight, 3.5) + 1, root.Position.Z)
	Tac.moveParams.FilterDescendantsInstances = Tac.worldFilter()
	if workspace:Raycast(from, Vector3.new(goal.X, from.Y, goal.Z) - from, Tac.moveParams) then return end
	local now = os.clock()
	state.waypoints = nil
	state.moveMode = "direct"
	state.directGoal = goal
	state.directUntil = now + AI.DirectTime
	state.detour = nil
	state.lastMoveTarget = nil
	state.humanoid:MoveTo(goal)
	state.lastMoveToAt = now
end

--  Lugares donde se rindio de subir (se recuerdan BlockedSpotTime segundos).
function Tac.nearBlocked(state, pos)
	local list = state.blockedSpots
	if not list then return false end
	local now = os.clock()
	for i = #list, 1, -1 do
		local spot = list[i]
		if now > spot.untilT then
			table.remove(list, i)
		elseif flat(spot.pos - pos).Magnitude < 6 then
			return true
		end
	end
	return false
end

--  Se atasco (sin avanzar StuckGiveUp segundos). true si fue la segunda vez
--  yendo al mismo destino y se rindio con el.
function Tac.noteStuck(state, now)
	if state.moveMode ~= "path" and state.moveMode ~= "direct" then return false end
	local goal = state.pathGoal or state.directGoal
	if not goal then return false end
	local last = state.stuckGoal
	if last and (last.pos - goal).Magnitude < 8 and now - last.at < 25 then
		last.count += 1
		last.at = now
	else
		state.stuckGoal = { pos = goal, count = 1, at = now }
	end
	if state.stuckGoal.count >= 2 then
		Tac.abandonRoute(state, now)
		return true
	end
	return false
end

--  Cuantas veces salto (o trepo) ya en este mismo lugar, hace poco.
function Tac.jumpsHere(state, now)
	local spot = state.jumpSpot
	if spot and now - spot.lastAt < 4 and flat(state.root.Position - spot.pos).Magnitude < 3 then
		return spot.count
	end
	return 0
end

--  Anota un salto. Si ya van JumpLoopLimit en el mismo lugar (un borde que
--  el camino da por bueno pero no le alcanza el salto), se rinde con esa
--  ruta y devuelve false: el que llama no salta.
function Tac.noteJump(state, now)
	local count = Tac.jumpsHere(state, now) + 1
	if count == 1 then
		state.jumpSpot = { pos = state.root.Position, count = 1, lastAt = now }
	else
		state.jumpSpot.count = count
		state.jumpSpot.lastAt = now
	end
	if count >= Tac.AI.JumpLoopLimit then
		state.jumpSpot = nil
		Tac.abandonRoute(state, now)
		return false
	end
	return true
end

--  No hay forma de pasar por aca: recuerda el lugar, calcula los proximos
--  caminos sin saltos, da por fallado el destino (cada tactica elige otro)
--  y se aleja un paso de la pared.
function Tac.abandonRoute(state, now)
	local here = state.root.Position
	state.blockedSpots = state.blockedSpots or {}
	table.insert(state.blockedSpots, { pos = here, untilT = now + Tac.AI.BlockedSpotTime })
	--  El destino tambien: requestPath lo da por fallado sin calcular.
	local goal = state.pathGoal or state.directGoal
	if goal then
		table.insert(state.blockedSpots, { pos = goal, untilT = now + Tac.AI.BlockedSpotTime })
		--  [IA v3] Y a la memoria compartida; no volver a planear trepar ahi ya.
		Tac.markUnreachable(goal, 1, "atascado")
		state.noClimbFor, state.noClimbUntil = goal, now + 20
	end
	state.climbPlan, state.climbing = nil, nil
	while #state.blockedSpots > 10 do table.remove(state.blockedSpots, 1) end
	state.stuckGoal = nil
	state.noJumpPathUntil = now + 12
	state.preferJumpUntil = nil
	state.pathFails += 3
	state.nextRoamAt = now
	state.lastRepath = now
	state.mantle, state.boost = nil, nil
	local away = -flat(state.humanoid.MoveDirection)
	if away.Magnitude < 0.3 then away = -flat(state.root.CFrame.LookVector) end
	if away.Magnitude < 0.3 then away = Vector3.new(1, 0, 0) end
	startStrafe(state, now, away.Unit + state.root.CFrame.RightVector * (state.rng:NextNumber() < 0.5 and -0.5 or 0.5), 0.7)
	dprint(state.bot.Name, "no puede subir por aca: cambia de ruta")
end

-- --------------------------------------------------------------------------
--  Encerrado: quiere ir a algun lado (pide caminos) pero hace rato que no
--  se aleja de donde esta (un cuarto de segundo piso con la salida angosta,
--  un navmesh roto). Explora hacia el lado mas abierto; si ni asi, como
--  ultimo recurso rompe una ventana cercana y sale por ahi.
-- --------------------------------------------------------------------------
function Tac.checkConfined(state, now)
	local AI = Tac.AI
	local here = state.root.Position
	--  Salio de verdad del encierro (lejos de donde empezo a explorar): listo.
	if state.confinedAt and ((here - state.confinedAt).Magnitude > 30 or now - state.confinedSince > 90) then
		state.confinedAt, state.escapes = nil, 0
	end
	if not state.anchorPos or (here - state.anchorPos).Magnitude > AI.ConfinedRadius then
		state.anchorPos, state.anchorAt = here, now
		return
	end
	--  Quieto a proposito (peleando, en su puesto, cubriendose, levantando a
	--  alguien) o sin querer ir a ningun lado: no cuenta.
	local wantsToMove = now - (state.lastWantMoveAt or -100) < 3
	if state.visible or state.reviveFace or not wantsToMove then
		state.anchorAt = now
		return
	end
	--  La primera vez espera ConfinedTime; si ya estaba explorando, menos.
	--  Encerrado = casi no se movio, o hace rato que ningun camino le sale
	--  (dando vueltas dentro de un cuarto grande sigue estando encerrado).
	local waitFor = state.confinedAt and AI.ConfinedTime * 0.5 or AI.ConfinedTime
	local stayed = now - state.anchorAt >= waitFor
	local noPaths = now - (state.lastPathOkAt or now) >= waitFor * 1.5
	if not (stayed or noPaths) then return end
	state.anchorAt = now
	state.lastPathOkAt = now
	if not state.confinedAt then state.confinedAt, state.confinedSince = here, now end
	state.escapes = (state.escapes or 0) + 1
	--  Lo que aprendio de este lugar quizas es lo que lo tiene encerrado.
	state.blockedSpots = nil
	state.noJumpPathUntil = nil
	state.preferTightUntil = now + 25
	state.pathFails = 0
	if state.escapes > AI.WindowEscapeAfter and Tac.windowEscape(state, now) then return end
	Tac.explore(state, now)
end

--  Hacia donde hay mas lugar para caminar (sin pared y con piso).
function Tac.openDirection(state, minDistance)
	local root, humanoid = state.root, state.humanoid
	local feetY = root.Position.Y - humanoid.HipHeight - root.Size.Y * 0.5
	local params = Tac.moveParams
	params.FilterDescendantsInstances = Tac.worldFilter()
	local best, bestScore, bestDist = nil, nil, 0
	local offset = state.rng:NextNumber(0, math.pi * 2)
	for i = 0, 31 do
		local angle = offset + i * math.pi / 16		-- 32 rumbos: una puerta angosta no se escapa
		local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local from = Vector3.new(root.Position.X, feetY + 1.5, root.Position.Z)
		local hit = workspace:Raycast(from, dir * 30, params)
		local free = hit and (hit.Position - from).Magnitude or 30
		--  Piso a lo largo (se puede bajar escalones, no caer de un balcon).
		local reach = 0
		for d = 3, free - 1, 3 do
			local floor = workspace:Raycast(from + dir * d, Vector3.new(0, -5.5, 0), params)
			if not floor then break end
			reach = d
		end
		--  Un poco de azar y castigo a volver por donde ya exploro.
		local score = reach * state.rng:NextNumber(0.85, 1.15)
		if state.lastExploreDir and dir:Dot(state.lastExploreDir) > 0.7 then score *= 0.5 end
		if reach >= (minDistance or 5) and (not bestScore or score > bestScore) then
			best, bestScore, bestDist = dir, score, reach
		end
	end
	return best, bestDist
end

function Tac.explore(state, now)
	local dir, reach = Tac.openDirection(state, 5)
	if not dir then
		dprint(state.bot.Name, "encerrado y sin salida a la vista")
		return false
	end
	state.lastExploreDir = dir
	local goal = state.root.Position + dir * math.min(reach, 22)
	state.waypoints = nil
	state.detour = nil
	state.moveMode = "direct"
	state.directGoal = goal
	state.directUntil = now + 4
	state.exploreUntil = now + 3.5
	state.lastMoveTarget = nil
	state.humanoid.WalkSpeed = WALK_SPEED
	state.humanoid:MoveTo(goal)
	state.lastMoveToAt = now
	dprint(state.bot.Name, "encerrado: explora para salir")
	return true
end

--  Ultimo recurso: una ventana cerca (con vidrio rompible, o ya abierta /
--  rota) por la que quepa una persona, con un marco que se pueda trepar y
--  aire del otro lado. Si tiene vidrio lo rompe; despues sale por ahi (el
--  parkour trepa el marco y del otro lado cae).
function Tac.windowEscape(state, now)
	local root, humanoid = state.root, state.humanoid
	local feetY = root.Position.Y - humanoid.HipHeight - root.Size.Y * 0.5
	local base = Vector3.new(root.Position.X, feetY, root.Position.Z)
	local maxSill = math.max(Tac.AI.MantleMaxHeight, 3)
	local params = Tac.moveParams
	local filter = Tac.worldFilter()
	params.FilterDescendantsInstances = filter
	local chestFrom = base + Vector3.new(0, 3.8, 0)
	for i = 0, 31 do
		local angle = i * math.pi / 16
		local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local chest = workspace:Raycast(chestFrom, dir * 14, params)
		local glass = chest and chest.Instance:GetAttribute("VidrioRompible") == true and chest.Instance or nil
		local distance = nil
		if glass then
			distance = (chest.Position - chestFrom).Magnitude
		elseif not chest then
			--  Pecho libre pero rodillas no: un marco de ventana abierta.
			local knee = workspace:Raycast(base + Vector3.new(0, 1.2, 0), dir * 14, params)
			if knee then distance = (knee.Position - (base + Vector3.new(0, 1.2, 0))).Magnitude end
		end
		if distance then
			local plane = base + dir * (distance + 0.3)
			local ignore = table.clone(filter)
			if glass then table.insert(ignore, glass) end
			params.FilterDescendantsInstances = ignore
			local sillHit = workspace:Raycast(plane + Vector3.new(0, 3.8, 0), Vector3.new(0, -4.3, 0), params)
			local sill = sillHit and sillHit.Position.Y - feetY or 0
			local roomAbove = sillHit and not workspace:Raycast(sillHit.Position + Vector3.new(0, 0.2, 0), Vector3.new(0, 4.8, 0), params)
			local air = not workspace:Raycast(plane + dir * 1.2 + Vector3.new(0, 3.8, 0), dir * 6, params)
			params.FilterDescendantsInstances = filter
			if sill > 0.5 and sill <= maxSill and roomAbove and air then
				if glass then
					local glassHit = _G.LL_GlassHit
					if type(glassHit) ~= "function" then return false end
					for _ = 1, 3 do
						if not glass.Parent or not glass.CanCollide then break end
						pcall(glassHit, glass, chest.Position, dir, "Bot")
					end
					if glass.Parent and glass.CanCollide then return false end
				end
				local goal = plane + dir * 8
				state.waypoints = nil
				state.detour = nil
				state.moveMode = "direct"
				state.directGoal = Vector3.new(goal.X, root.Position.Y, goal.Z)
				state.directUntil = now + 5
				state.exploreUntil = now + 4.5
				state.lastMoveTarget = nil
				state.lookAt, state.lookUntil = goal, now + 1.5
				humanoid:MoveTo(state.directGoal)
				state.lastMoveToAt = now
				dprint(state.bot.Name, glass and "encerrado: rompe una ventana y sale por ahi" or "encerrado: sale por una ventana")
				return true
			end
		end
	end
	return false
end

--  A donde esta caminando ahora mismo.
function Tac.moveGoal(state)
	if state.detour then return state.detour.pos end
	local mode = state.moveMode
	if mode == "path" and state.waypoints then
		local waypoint = state.waypoints[state.wpIndex]
		return waypoint and waypoint.Position
	elseif mode == "direct" then
		return state.humanoid.WalkToPoint
	elseif mode == "strafe" and state.strafeDir then
		return state.root.Position + state.strafeDir * 6
	end
	return nil
end

--  Se puede ir caminando en linea recta de A a B: sin paredes (a lo ancho
--  del cuerpo y a la altura de la cabeza) y con piso todo el tramo.
function Tac.walkLineClear(fromPos, feetY, target, params)
	local a = Vector3.new(fromPos.X, feetY + 1.4, fromPos.Z)
	local b = Vector3.new(target.X, target.Y + 1.4, target.Z)
	local delta = b - a
	local length = delta.Magnitude
	if length < 0.5 then return true end
	local side = Vector3.new(-delta.Z, 0, delta.X)
	if side.Magnitude < 0.01 then return false end
	--  [IA v3] Con el ancho del cuerpo y un poco mas: a 0.9 rozaba el marco de
	--  las puertas y se quedaba trabado en la esquina.
	side = side.Unit * 1.25
	if workspace:Raycast(a + side, delta, params) or workspace:Raycast(a - side, delta, params) then return false end
	if workspace:Raycast(a + Vector3.new(0, 2.6, 0), delta, params) then return false end
	local steps = math.clamp(math.floor(length / 4), 1, 4)
	for i = 1, steps do
		local point = a + delta * (i / (steps + 1))
		local floor = workspace:Raycast(point, Vector3.new(0, -3.4, 0), params)
		if not floor or floor.Normal.Y < 0.6 then return false end
	end
	return true
end

--  Camino recto: el navmesh da puntos cada 4-5 studs con curvas de mas
--  (el tipico zigzag de NPC). Si hay paso libre a un punto mas adelante, se
--  salta los del medio. Nunca se salta un punto de salto.
function Tac.smoothPath(state, now)
	local AI = Tac.AI
	if now < (state.nextSmoothAt or 0) then return end
	state.nextSmoothAt = now + AI.SmoothEvery
	local waypoints, index = state.waypoints, state.wpIndex
	if not waypoints or index >= #waypoints then return end
	local humanoid, root = state.humanoid, state.root
	if humanoid.FloorMaterial == Enum.Material.Air then return end
	local WALK = Enum.PathWaypointAction.Walk
	local limit = index
	for i = index, math.min(index + AI.SmoothLookahead, #waypoints) do
		if waypoints[i].Action ~= WALK then break end
		limit = i
	end
	if limit <= index then return end
	local feetY = root.Position.Y - humanoid.HipHeight - root.Size.Y * 0.5
	local params = Tac.moveParams
	params.FilterDescendantsInstances = Tac.worldFilter()
	for skip = limit, index + 1, -1 do
		local target = waypoints[skip].Position
		if math.abs(target.Y - feetY) < 1.5 and Tac.walkLineClear(root.Position, feetY, target, params) then
			state.wpIndex = skip
			state.lastMoveTarget = nil
			return
		end
	end
end

--  Otro personaje justo delante: un paso al costado (el lado contrario a el).
function Tac.bumpCheck(state, now, dir)
	if state.detour then return true end
	local params = Tac.bumpParams
	params.FilterDescendantsInstances = { state.character, ACS_Workspace }
	local hit = workspace:Raycast(state.root.Position, dir * 3.2, params)
	if not hit then return false end
	local other = characterFromPart(hit.Instance)
	if not other or other == state.character then return false end
	--  Al que va a rematar / levantar (en el suelo) o a su objetivo no se lo esquiva.
	if isDownedCharacter(other) or (state.target and state.target.character == other) then return false end
	local otherRoot = other:FindFirstChild("HumanoidRootPart")
	if not otherRoot then return false end
	local perp = Vector3.new(-dir.Z, 0, dir.X)
	local away = perp:Dot(otherRoot.Position - state.root.Position) > 0 and -perp or perp
	state.detour = { pos = state.root.Position + away * 3.5 + dir * 2.5, untilT = now + 0.55 }
	return true
end

--  Pared que no se puede trepar. De lado: cambia de lado. Yendo derecho
--  (sin camino): prueba a rodearla. Con camino, el navmesh ya la rodea.
function Tac.avoidWall(state, now, dir, base, params)
	if state.moveMode == "strafe" then
		if state.strafeDir and state.strafeDir:Dot(dir) > 0.5 then state.strafeDir = -state.strafeDir end
		return
	end
	--  Solo en el plan B (directGoal): los "direct" de rematar / levantar /
	--  clima son tramos cortos que ya apuntan a donde tienen que ir.
	if state.moveMode ~= "direct" or not state.directGoal or state.detour then return end
	groundParams.FilterDescendantsInstances = { state.character }
	local from = base + Vector3.new(0, 1.2, 0)
	for _, angle in ipairs({ 40, -40, 75, -75, 110, -110 }) do
		local side = CFrame.Angles(0, math.rad(angle), 0):VectorToWorldSpace(dir)
		if not workspace:Raycast(from, side * 6, params) then
			local spot = state.root.Position + side * 6
			if groundBelow(spot) then
				state.detour = { pos = spot, untilT = now + 0.8 }
				return
			end
		end
	end
end

--  Trepar un borde (mantle): impulso justo para que el cuerpo pase por
--  encima del borde; al pasarlo, Tac.parkour lo empuja hacia adelante.
function Tac.startMantle(state, now, dir, topY, ledge)
	local humanoid, root = state.humanoid, state.root
	local rise = ledge - humanoid.HipHeight + 1.5
	local vy = math.sqrt(2 * workspace.Gravity * math.max(rise, 1)) * 1.1
	root.AssemblyLinearVelocity = dir * 1.5 + Vector3.new(0, vy, 0)
	state.boost = { vy = vy, t0 = now }
	state.mantle = { dir = dir, topY = topY, untilT = now + 0.9 }
	state.nextMantleAt = now + 1.1
	state.nextJumpAt = now + 0.6
	state.climbAnimUntil = now + 0.45
	dprint(state.bot.Name, string.format("trepa un borde de %.1f studs", ledge))
end

--  Un hueco delante (sin piso) y el destino sigue a su altura del otro lado:
--  salta con el impulso justo para caer en el piso de enfrente.
function Tac.tryLeap(state, now, dir, base, goal, params)
	local AI = Tac.AI
	local humanoid, root = state.humanoid, state.root
	local feetY = base.Y
	if workspace:Raycast(base + dir * 3 + Vector3.new(0, 1.5, 0), Vector3.new(0, -4.8, 0), params) then return end
	--  [IA v3] Bajada de una colina (el piso sigue, en pendiente) o un escalon
	--  que se baja caminando: no es un hueco.
	local deep = workspace:Raycast(base + dir * 3 + Vector3.new(0, 1.5, 0), Vector3.new(0, -12, 0), params)
	if deep and (deep.Normal.Y < 0.95 or feetY - deep.Position.Y <= 4.8) then return end
	--  Destino mas abajo: es una bajada a proposito (balcon, escalera rota).
	if goal.Y < feetY - 3 or flat(goal - root.Position).Magnitude < 3 then return end
	if now < (state.nextJumpAt or 0) then return end
	for distance = 4.5, AI.GapMax + 1, 1.5 do
		local spot = base + dir * distance
		local land = workspace:Raycast(spot + Vector3.new(0, 4, 0), Vector3.new(0, -8, 0), params)
		if land then
			local rise = land.Position.Y - feetY
			if land.Normal.Y < 0.6 or rise > 2.5 or rise < -2.5 then return end
			if workspace:Raycast(base + Vector3.new(0, 3, 0), dir * (distance + 1), params) then return end
			local speed = math.max(humanoid.WalkSpeed, RUN_SPEED)
			local flight = (distance + 1.2) / speed
			local vy = math.max(rise / flight + workspace.Gravity * flight * 0.5, humanoid.JumpPower)
			humanoid.WalkSpeed = speed
			root.AssemblyLinearVelocity = dir * speed + Vector3.new(0, vy, 0)
			state.boost = { vy = vy, t0 = now }
			state.nextJumpAt = now + 0.9
			dprint(state.bot.Name, string.format("salta un hueco de %.1f studs", distance))
			return
		end
	end
end

--  Cada frame (con limite ParkourEvery): obstaculos y huecos delante.
function Tac.parkour(state, now)
	local AI = Tac.AI
	local humanoid, root = state.humanoid, state.root
	--  Impulso recien dado (trepar / saltar un hueco): si el Humanoid lo
	--  freno en el primer instante (se "pega" al piso), se repone.
	local boost = state.boost
	if boost then
		local elapsed = now - boost.t0
		if elapsed > 0.12 then
			state.boost = nil
		else
			local expected = boost.vy - workspace.Gravity * elapsed
			local velocity = root.AssemblyLinearVelocity
			if expected > 0 and velocity.Y < expected * 0.7 then
				root.AssemblyLinearVelocity = Vector3.new(velocity.X, expected, velocity.Z)
			end
		end
	end
	--  Trepando: en cuanto el cuerpo pasa el borde, adelante.
	local mantle = state.mantle
	if mantle then
		if now > mantle.untilT then
			state.mantle = nil
		else
			if root.Position.Y - root.Size.Y * 0.5 > mantle.topY + 0.2 then
				local velocity = root.AssemblyLinearVelocity
				root.AssemblyLinearVelocity = Vector3.new(mantle.dir.X * 14, math.max(velocity.Y, 2), mantle.dir.Z * 14)
				state.mantle = nil
			end
			return
		end
	end
	if now < (state.nextParkourAt or 0) then return end
	state.nextParkourAt = now + AI.ParkourEvery
	local mode = state.moveMode
	local S = Enum.HumanoidStateType
	local humanoidState = humanoid:GetState()
	if (mode ~= "path" and mode ~= "direct" and mode ~= "strafe")
		or state.downed ~= "" or state.slide or state.galeExposed
		or humanoid.FloorMaterial == Enum.Material.Air
		or humanoidState == S.Swimming or humanoidState == S.Climbing
		or humanoidState == S.Jumping or humanoidState == S.Freefall then
		state.slowSince = nil
		return
	end

	local goal = Tac.moveGoal(state)
	local dir = flat(humanoid.MoveDirection)
	if dir.Magnitude < 0.3 and goal then dir = flat(goal - root.Position) end
	if dir.Magnitude < 0.3 then return end
	dir = dir.Unit

	if (mode == "path" or state.directGoal) and Tac.bumpCheck(state, now, dir) then return end
	--  Aca ya se rindio hace poco: no vuelve a saltar contra la misma pared.
	if Tac.nearBlocked(state, root.Position) then return end

	local hip = humanoid.HipHeight
	local feetY = root.Position.Y - hip - root.Size.Y * 0.5
	local base = Vector3.new(root.Position.X, feetY, root.Position.Z)
	local params = Tac.moveParams
	params.FilterDescendantsInstances = Tac.worldFilter()
	local ahead = dir * AI.ProbeAhead

	--  Frenado de verdad (no un instante al arrancar).
	if flat(root.AssemblyLinearVelocity).Magnitude < humanoid.WalkSpeed * 0.45 then
		state.slowSince = state.slowSince or now
	else
		state.slowSince = nil
	end
	local blocked = state.slowSince ~= nil and now - state.slowSince > 0.35

	local low = workspace:Raycast(base + Vector3.new(0, 0.9, 0), ahead, params)
	--  [IA v3] Una ladera empinada (colina de terreno, rampa) se sube caminando:
	--  no es pared salvo que de verdad lo frene.
	if low and low.Normal.Y >= 0.3 and low.Normal.Y < 0.6 and not blocked then return end
	if low and low.Normal.Y < 0.6 and not (Tac.doorParts and Tac.doorParts[low.Instance]) then
		--  Con camino, solo si el camino sube por ahi o si lo esta frenando
		--  (no se sube a cada caja que roza).
		local pathWantsUp = goal ~= nil and goal.Y > feetY + hip * 0.8
		if mode == "path" and not blocked and not pathWantsUp then return end

		local jumpHeight = (humanoid.JumpPower ^ 2) / (2 * workspace.Gravity)
		local canJump = hip + jumpHeight - 0.3
		local maxUp = math.max(AI.MantleMaxHeight, canJump)
		--  Altura del obstaculo: rayos hacia adelante cada vez mas altos hasta
		--  que uno pasa libre (empezar desde arriba fallaba bajo techo).
		local clearAt = nil
		local height = 0.9
		while height < maxUp + 0.8 do
			height += 1.2
			if not workspace:Raycast(base + Vector3.new(0, height, 0), ahead + dir * 0.8, params) then
				clearAt = height
				break
			end
		end
		local ledge, topY = nil, nil
		if clearAt then
			local over = low.Position + dir * 0.2
			local top = workspace:Raycast(Vector3.new(over.X, feetY + clearAt, over.Z), Vector3.new(0, -(clearAt + 0.2), 0), params)
			if top and top.Normal.Y > 0.6 then
				topY = top.Position.Y
				ledge = topY - feetY
				--  Sin lugar para pararse arriba (debajo de una mesa): no.
				if workspace:Raycast(top.Position + Vector3.new(0, 0.2, 0), Vector3.new(0, 4.8, 0), params) then
					ledge = nil
				end
			end
		end
		if ledge and ledge <= hip * 0.8 then return end		-- el Humanoid lo sube solo
		--  Si ya salto dos veces aca y no paso, el salto normal no le alcanza:
		--  trepa con impulso (si el borde no es demasiado alto).
		local canMantle = ledge ~= nil and ledge <= AI.MantleMaxHeight
		if ledge and ledge <= canJump and not (canMantle and Tac.jumpsHere(state, now) >= 2) then
			if now >= (state.nextJumpAt or 0) and Tac.noteJump(state, now) then
				humanoid.Jump = true
				state.nextJumpAt = now + AI.JumpCooldown
			end
			return
		end
		if canMantle and now >= (state.nextMantleAt or 0)
			and (mode ~= "strafe" or blocked)
			and not workspace:Raycast(root.Position, Vector3.new(0, ledge + 1, 0), params) then
			if Tac.noteJump(state, now) then Tac.startMantle(state, now, dir, topY, ledge) end
			return
		end
		Tac.avoidWall(state, now, dir, base, params)
		return
	end

	if not low and mode ~= "strafe" and AI.GapMax > 0 and goal then
		Tac.tryLeap(state, now, dir, base, goal, params)
	end
end

-- --------------------------------------------------------------------------
--  Oido: focos de combate, pasos, balas que pasan cerca
-- --------------------------------------------------------------------------
--  Cada disparo (bot o jugador) calienta un foco. Los focos se "oyen" desde
--  muy lejos (HotspotRange) aunque el disparo individual no llegue al bot.
function Tac.recordCombat(pos, now)
	local AI = Tac.AI
	Tac.lastCombatAt = now
	local list = Tac.hotspots
	for _, spot in ipairs(list) do
		if (spot.pos - pos).Magnitude < AI.HotspotMerge then
			spot.heat = math.min(spot.heat * math.exp(-(now - spot.at) / AI.HotspotLife) + 1, 40)
			spot.pos = spot.pos:Lerp(pos, 0.25)
			spot.at = now
			return
		end
	end
	if #list >= 24 then
		local oldest = 1
		for i, spot in ipairs(list) do
			if spot.at < list[oldest].at then oldest = i end
		end
		table.remove(list, oldest)
	end
	table.insert(list, { pos = pos, at = now, heat = 1 })
end

--  El tiroteo que mas "suena" desde aca: caliente, reciente y no muy lejos.
function Tac.pickHotspot(state, now)
	local AI = Tac.AI
	local myPos = state.root.Position
	local list = Tac.hotspots
	local best, bestScore = nil, nil
	for i = #list, 1, -1 do
		local spot = list[i]
		local age = now - spot.at
		if age > AI.HotspotLife * 2 then
			table.remove(list, i)
		else
			local distance = (spot.pos - myPos).Magnitude
			if distance > 30 and distance <= AI.HotspotRange then
				local score = spot.heat * math.exp(-age / AI.HotspotLife) / (1 + distance / 120)
				if not bestScore or score > bestScore then best, bestScore = spot, score end
			end
		end
	end
	return best
end

--  Lo que un bot oye lo sabe su equipo, pero un avistamiento reciente vale mas.
function Tac.shareHeard(state, pos, now)
	local team = Tac.teamKey(state)
	if not team then return end
	local current = Tac.intelByTeam[team]
	if current and not current.heard and now - current.at < 3 then return end
	Tac.intelByTeam[team] = { pos = pos, at = now, heard = true }
end

--  Pasos: el que corre se oye; el que camina, solo de cerca; agachado o
--  quieto, nada.
function Tac.listenFootsteps(state, now, enemies)
	local AI = Tac.AI
	if state.noise and now - state.noise.at < 1.5 then return end
	for _, entry in ipairs(enemies) do
		if entry.dist > AI.FootstepRange then break end
		local speed = flat(entry.root.AssemblyLinearVelocity).Magnitude
		local range = 0
		if speed > 18 then
			range = AI.FootstepRange
		elseif speed > 7 and entry.character:GetAttribute("ACS_Stance") ~= 1 then
			range = AI.FootstepRange * 0.45
		end
		if entry.dist <= range then
			local fuzz = math.clamp(entry.dist * 0.1, 1.5, 6)
			local offset = Vector3.new(state.rng:NextNumber(-1, 1), 0, state.rng:NextNumber(-1, 1)) * fuzz
			state.noise = { pos = entry.root.Position + offset, at = now }
			state.lookAt = state.noise.pos
			state.lookUntil = now + state.rng:NextNumber(0.8, 1.5)
			return
		end
	end
end

--  Una bala que le pasa cerca: sabe de donde vino y apunta peor un momento.
function Tac.bulletWhiz(shooter, origin, dir, reach, now, radius)
	local AI = Tac.AI
	for _, other in pairs(brains) do
		if other.bot ~= shooter and not other.dead and other.head and other.head.Parent
			and areEnemies(other.bot, shooter) then
			local rel = other.head.Position - origin
			local along = rel:Dot(dir)
			if along > 3 and along < reach + 2 and (rel - dir * along).Magnitude < radius then
				other.suppressedUntil = now + AI.SuppressTime
				if not other.visible then
					other.noise = { pos = origin, at = now }
					other.lookAt = origin
					other.lookUntil = now + 1.6
				end
			end
		end
	end
end

--  Lo perdio de vista corriendo: lo busca un poco mas alla, en la direccion
--  en que iba (sin atravesar paredes).
function Tac.predictSearch(state, now)
	local from, velocity = state.lastSeenPos, state.lastSeenVel
	if not from or not velocity or velocity.Magnitude < 4 then
		state.searchPos = nil
		return
	end
	local guess = from + velocity * 1.2
	local params = Tac.moveParams
	params.FilterDescendantsInstances = Tac.worldFilter()
	local up = Vector3.new(0, 1.5, 0)
	local hit = workspace:Raycast(from + up, guess - from, params)
	if hit then guess = hit.Position - (guess - from).Unit * 2 - up end
	state.searchPos = guess
end

--  Recargando con un enemigo cerca: una cobertura a pocos pasos.
function Tac.tryReloadCover(state, now, target)
	if state.cover then return true end
	if now < (state.nextReloadCoverAt or 0) then return false end
	state.nextReloadCoverAt = now + 3
	local spot = Tac.findCover(state, target.root.Position, 2)
	if not spot or flat(spot - state.root.Position).Magnitude > 16 then return false end
	if not Tac.zoneCoverOk(state, spot, "reload") then return false end		-- [26/09] Control
	state.cover = { pos = spot, threat = target.root.Position, arrived = false, untilT = now + 6, reason = "reload" }
	state.hold, state.watch = nil, nil
	dprint(state.bot.Name, "se cubre para recargar")
	return Tac.updateCover(state, now)
end

--  [26/09] Control: el punto va primero. Cubrirse solo DENTRO del area
--  (para recargar o si lo superan en numero). Muy herido y ya afuera, si
--  puede ir a cubrirse donde sea; adentro aguanta el punto.
function Tac.zoneCoverOk(state, spot, reason)
	local zone = Tac.controlZone and Tac.controlZone()
	if not zone then return true end
	if Tac.inZone(zone, spot + Vector3.new(0, 3, 0), 0.5) then return true end
	return reason == "health" and not Tac.inZone(zone, state.root.Position, 0.5)
end

--  Lejos de todo jugador real y sin pelea: piensa a menor ritmo (nadie lo
--  esta mirando). Se reevalua cada segundo.
function Tac.updateLod(state, now)
	if now < (state.nextLodAt or 0) then return end
	state.nextLodAt = now + 1
	if state.target or (state.noise and now - state.noise.at < 8) then
		state.lod = 1
		return
	end
	local AI = Tac.AI
	local pos = state.root.Position
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and (root.Position - pos).Magnitude < AI.LodDistance then
			state.lod = 1
			return
		end
	end
	state.lod = AI.LodFactor
end

-- --------------------------------------------------------------------------
--  Noche: lampara encendida en todas sus armas
-- --------------------------------------------------------------------------
function Tac.isNight()
	local key = roundState:GetAttribute("WinningAmbience")
	return type(key) == "string" and string.sub(key, 1, 5) == "Noche"
end

--  El mismo accesorio que usa un jugador (AttModels.Flashlight). Va en el
--  nodo UnderBarrel como lo monta ACS; las armas sin nodos (AK-47, Ithaca,
--  Glock) la llevan bajo el cano, apuntando hacia donde apunta el arma.
--  Se llama con el arma todavia sin emparentar (espacio de la plantilla).
function Tac.addFlashlight(gun, handle)
	local template = Tac.flashlightModel
	if not template or not template.PrimaryPart then return nil end
	local lamp = template:Clone()
	lamp.Name = "BotFlashlight"
	local main = lamp.PrimaryPart
	local flashPoint = lamp:FindFirstChild("FlashPoint")
	local nodes = gun:FindFirstChild("Nodes")
	local node = nodes and (nodes:FindFirstChild("UnderBarrel") or nodes:FindFirstChild("Other"))
	lamp.Parent = gun
	if node and node:IsA("BasePart") then
		lamp:SetPrimaryPartCFrame(node.CFrame)
	else
		local muzzle = handle:FindFirstChild("Muzzle")
		local tip = muzzle and muzzle.WorldPosition or handle.Position
		local barrel = tip - handle.Position
		barrel = barrel.Magnitude > 0.1 and barrel.Unit or handle.CFrame.LookVector
		local position = tip - barrel * 0.6 - handle.CFrame.UpVector * 0.2
		--  Que la cara frontal del FlashPoint (de donde sale la luz) mire
		--  a lo largo del cano.
		local relative = main.CFrame:ToObjectSpace(flashPoint and flashPoint.CFrame or main.CFrame)
		lamp:SetPrimaryPartCFrame(CFrame.lookAt(position, position + barrel) * relative:Inverse())
	end
	for _, part in ipairs(lamp:GetDescendants()) do
		if part:IsA("BasePart") then
			Ultil.Weld(handle, part)
			part.Anchored = false
			part.CanCollide = false
			part.CanTouch = false
			part.CanQuery = false
			part.Massless = true
		end
	end
	local light = flashPoint and flashPoint:FindFirstChildOfClass("SpotLight")
	if light then light.Enabled = true end
	return lamp
end

-- --------------------------------------------------------------------------
--  Brazos: las mismas poses que ACS le pone a un jugador en tercera persona
--  (Evt.GunStance): apuntando (RightAim/LeftAim) y corriendo (Sprint).
-- --------------------------------------------------------------------------
function Tac.setArmPose(state, pose)
	if state.armPose == pose then return end
	local weapon = state.weapons[state.current]
	local animBase = state.character:FindFirstChild("AnimBase")
	local rightWeld = animBase and animBase:FindFirstChild("RAW")
	local leftWeld = animBase and animBase:FindFirstChild("LAW")
	if not (weapon and rightWeld and leftWeld) then return end
	local anim = weapon.info.anim
	local right, left = anim.SV_RightArmPos, anim.SV_LeftArmPos
	if pose == "aim" then
		right, left = anim.RightAim or right, anim.LeftAim or left
	elseif pose == "sprint" then
		right, left = anim.RightSprint or right, anim.LeftSprint or left
	end
	if typeof(right) ~= "CFrame" or typeof(left) ~= "CFrame" then return end
	state.armPose = pose
	TweenService:Create(rightWeld, Tac.armTween, { C0 = right }):Play()
	TweenService:Create(leftWeld, Tac.armTween, { C0 = left }):Play()
end

function Tac.updateArmPose(state)
	if state.downed ~= "" then return end
	local pose = "idle"
	if state.slide then
		pose = "idle"
	elseif state.target and state.visible and not state.reload then
		pose = "aim"
	elseif state.humanoid.WalkSpeed >= RUN_SPEED - 1 and flat(state.root.AssemblyLinearVelocity).Magnitude > 14 then
		pose = "sprint"
	end
	Tac.setArmPose(state, pose)
end

-- --------------------------------------------------------------------------
--  Bajas y vida (mismas reglas que el script regen de los jugadores)
-- --------------------------------------------------------------------------
function Tac.onKill(state)
	local R = Config.KillReward
	if not R or state.dead then return end
	local humanoid = state.humanoid
	if state.downed == "" and humanoid.Health > 0 then
		humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + (R.Health or 25))
	end
	state.meta.regenPoints = (state.meta.regenPoints or 0) + (R.RegenPoints or 20)
end

function Tac.regenTick(now)
	local R = Config.KillReward
	if not R then return end
	for _, state in pairs(brains) do
		local meta = state.meta
		if not state.dead and (meta.regenPoints or 0) > 0 and now >= (meta.nextRegenAt or 0) then
			meta.nextRegenAt = now + (R.RegenInterval or 4)
			meta.regenPoints -= 1
			local humanoid = state.humanoid
			if state.downed == "" and humanoid.Health > 0 and humanoid.Health < humanoid.MaxHealth then
				humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + 1)
			end
		end
	end
end

-- --------------------------------------------------------------------------
--  Equipo: companeros y avisos ("vi a uno aqui")
-- --------------------------------------------------------------------------
function Tac.teamKey(state)
	if isFFA() then return nil end
	local team = teamOf(state.bot)
	if not team or team == "Neutral" or team == "Lobby" then return nil end
	return team
end

function Tac.reportIntel(state, entry, now)
	local team = Tac.teamKey(state)
	if team then
		Tac.intelByTeam[team] = { pos = entry.root.Position, at = now }
		--  [24/09] Historial de avistamientos del equipo (lo usa el Lider para
		--  saber por donde vienen). Uno por enemigo por segundo como mucho.
		local list = Tac.sightings[team]
		if not list then
			list = {}
			Tac.sightings[team] = list
		end
		local lastSeen = Tac.sightingAt[entry.participant]
		if not lastSeen or now - lastSeen > 1 then
			Tac.sightingAt[entry.participant] = now
			table.insert(list, { pos = entry.root.Position, at = now, participant = entry.participant })
			if #list > 80 then table.remove(list, 1) end
		end
	end
end

function Tac.intel(state, now)
	local team = Tac.teamKey(state)
	local intel = team and Tac.intelByTeam[team]
	if intel and now - intel.at <= (Config.TeamIntelTime or 8) then return intel end
	return nil
end

--  Companeros de pie y en ronda, del mas cercano al mas lejano.
function Tac.teammates(state)
	local team = Tac.teamKey(state)
	local list = {}
	if not team then return list end
	for _, participant in ipairs(Registry.participants()) do
		if participant ~= state.bot and participant:GetAttribute("InRound") == true and teamOf(participant) == team then
			local character = participant.Character
			if character and not isDownedCharacter(character) then
				local entry = describeTarget(participant, character, state.root.Position)
				if entry then table.insert(list, entry) end
			end
		end
	end
	table.sort(list, function(a, b) return a.dist < b.dist end)
	return list
end

-- --------------------------------------------------------------------------
--  Cobertura con poca vida
-- --------------------------------------------------------------------------
--  Un punto cercano donde, agachado, el enemigo no lo ve. Prueba anillos de
--  7, 14, 21 y 28 studs y se queda con el mas cercano que sirva.
function Tac.findCover(state, threatPos, maxRing)
	local origin = state.root.Position
	local threatEye = threatPos + Vector3.new(0, 1.5, 0)
	Tac.params.FilterDescendantsInstances = Tac.worldFilter()
	for ring = 1, maxRing or 4 do
		local radius = ring * 7
		local best, bestScore = nil, nil
		for i = 0, 11 do
			local angle = i * (math.pi / 6) + state.rng:NextNumber(-0.2, 0.2)
			local probe = origin + Vector3.new(math.cos(angle) * radius, 4, math.sin(angle) * radius)
			local ground = workspace:Raycast(probe, Vector3.new(0, -12, 0), Tac.params)
			if ground and ground.Normal.Y > 0.7 and not Tac.isUnreachable(ground.Position) then
				local spot = ground.Position
				local crouchHead = spot + Vector3.new(0, 2.4, 0)
				local toSpot = crouchHead - threatEye
				local hit = workspace:Raycast(threatEye, toSpot, Tac.params)
				if hit and (hit.Position - crouchHead).Magnitude > 1.2 and not isSeeThrough(hit.Instance) then
					local score = (spot - threatPos).Magnitude * 0.3
					if not bestScore or score > bestScore then best, bestScore = spot, score end
				end
			end
		end
		if best then return best end
	end
	return nil
end

--  true si la cobertura se hizo cargo del movimiento en esta vuelta.
function Tac.updateCover(state, now)
	local role = state.meta.role
	if not role then return false end
	local humanoid = state.humanoid
	local health = humanoid.Health / math.max(humanoid.MaxHealth, 1)
	local cover = state.cover

	if cover then
		local target = state.target
		local enemyClose = target and state.visible and (target.root.Position - state.root.Position).Magnitude < 10
		--  [IA v2] Cada motivo de cubrirse tiene su forma de terminar.
		local recovered = health >= (role.CoverHealth or 0.35) + 0.2
		if cover.reason == "reload" then
			local weapon = state.weapons[state.current]
			recovered = not state.reload and weapon ~= nil and weapon.mag >= weapon.info.magSize * 0.6
		elseif cover.reason == "outnumbered" then
			recovered = cover.arrived and now > (cover.minT or math.huge)
		end
		if now > cover.untilT or recovered or enemyClose then
			state.cover = nil
			state.nextCoverTry = now + 6
			return false
		end
		local dist = flat(cover.pos - state.root.Position).Magnitude
		if not cover.arrived and dist > 3 then
			Tac.goTo(state, now, cover.pos, "cover", RUN_SPEED, 4)
			if state.pathFails >= 2 then
				state.cover = nil
				state.pathFails = 0
				state.nextCoverTry = now + 3
				return false
			end
			return true
		end
		if not cover.arrived then
			cover.arrived = true
			cover.untilT = now + rangeNumber(state.rng, (Config.Cover and Config.Cover.StayTime) or { 8, 14 })
			cover.minT = now + state.rng:NextNumber(2.5, 4.5)
		end
		if state.moveMode ~= "hold" then stopWalking(state) end
		if not (target and state.visible) then
			state.lookAt = cover.threat
			state.lookUntil = now + 0.5
		end
		--  Aprovecha para recargar a cubierto.
		local weapon = state.weapons[state.current]
		if weapon and not state.reload and weapon.mag < weapon.info.magSize and weapon.reserve > 0 then
			startReload(state, now)
		end
		return true
	end

	--  [IA v2] Tambien se cubre si lo superan en numero y ya esta tocado.
	local lowHealth = health <= (role.CoverHealth or 0.35)
	local outnumbered = (state.visibleCount or 0) >= 2 and health < Tac.AI.OutnumberedHealth
	if not (lowHealth or outnumbered) or now < (state.nextCoverTry or 0) then return false end
	local threat = nil
	if state.target and state.visible then
		threat = state.target.root.Position
	elseif state.lastSeenPos and now - state.lastSeenAt < 4 then
		threat = state.lastSeenPos
	elseif state.lastDamagePos and state.lastDamageAt and now - state.lastDamageAt < 3 then
		threat = state.lastDamagePos
	end
	if not threat then return false end
	state.nextCoverTry = now + 3
	local spot = Tac.findCover(state, threat)
	if not spot then return false end
	if not Tac.zoneCoverOk(state, spot, lowHealth and "health" or "outnumbered") then return false end		-- [26/09] Control
	state.cover = { pos = spot, threat = threat, arrived = false, untilT = now + 12,
		reason = lowHealth and "health" or "outnumbered" }
	state.hold, state.watch = nil, nil
	dprint(state.bot.Name, lowHealth and "se va a cubrir" or "lo superan en numero: se cubre")
	return true
end

-- --------------------------------------------------------------------------
--  Agacharse (lo decide updateWindStance junto con el ventarron)
-- --------------------------------------------------------------------------
function Tac.wantsCrouch(state, now)
	if state.peek and state.peek.arrived then return Tac.postCrouch(state, state.peek, now) end		-- [IA v3]
	if state.cover and state.cover.arrived then return true end
	if state.crouchUntil and now < state.crouchUntil then return true end		-- [IA v2] agacharse en pelea
	--  [24/09] Levantando a alguien con peligro cerca: agachado.
	if state.reviveFace and ((state.target and state.visible) or (state.lastDamageAt and now - state.lastDamageAt < 4)) then
		return true
	end
	--  [IA v3] Un puesto para asomarse: de pie (agachado no ve), salvo recargando.
	if state.hold and state.hold.arrived then return Tac.postCrouch(state, state.hold, now) end
	if state.watch and state.watch.arrived then return Tac.postCrouch(state, state.watch, now) end
	if state.ambush and state.ambush.arrived then return Tac.postCrouch(state, state.ambush, now) end
	--  [23/09 noche] Sigiloso cerca de su presa, lider en su puesto.
	if state.sneakClose then return true end
	if state.perch and state.perch.arrived then return Tac.postCrouch(state, state.perch, now) end		-- [24/09] camper en su punto
	if state.leaderSpot and state.leaderSpot.arrived then return true end
	if state.leaderCover and state.leaderCover.arrived then return true end
	--  Tirador quieto apuntando: agachado, como haria una persona.
	local weapon = state.weapons[state.current]
	if weapon and state.target and state.visible and state.moveMode == "hold" then
		local role = weapon.info.cfg.Role
		if role == "Sniper" or role == "DMR" then return true end
	end
	return false
end

-- --------------------------------------------------------------------------
--  Barrida (misma postura que ACS: Stance 3 y luego 4)
-- --------------------------------------------------------------------------
function Tac.maybeSlide(state, now)
	local role = state.meta.role
	local M = Config.Movement
	if not role or state.slide or state.downed ~= "" or state.galeExposed or state.stance ~= 0 then return end
	if now < (state.nextSlideAt or 0) then return end
	local humanoid, root = state.humanoid, state.root
	local velocity = flat(root.AssemblyLinearVelocity)
	if velocity.Magnitude < 17 or humanoid.FloorMaterial == Enum.Material.Air then return end

	--  Que tan buen momento es: entrando a una pelea, corriendo a cubrirse,
	--  empujando hacia un enemigo, o corriendo sin mas.
	local moment = 0.06
	if state.target and state.visible then
		moment = 1
	elseif state.cover and not state.cover.arrived then
		moment = 0.8
	elseif state.pathKind == "chase" or state.pathKind == "intel" or state.pathKind == "support" then
		moment = 0.35
	end
	state.nextSlideAt = now + 0.6
	if state.rng:NextNumber() > (role.SlideChance or 0.2) * moment then return end

	local dir = velocity.Unit
	Tac.params.FilterDescendantsInstances = Tac.worldFilter()
	if workspace:Raycast(root.Position - Vector3.new(0, 1.5, 0), dir * 12, Tac.params) then return end
	groundParams.FilterDescendantsInstances = { state.character }
	if not groundBelow(root.Position + dir * 10) then return end

	state.slide = {
		dir = dir, start = now, phase2 = now + 0.22,
		finish = now + (M.SlideTime or 0.85), speed = M.SlideSpeed or 34,
	}
	state.nextSlideAt = now + rangeNumber(state.rng, M.SlideCooldown or { 4, 8 })
	humanoid:MoveTo(root.Position)
	setStance(state, 3)
	dprint(state.bot.Name, "se barre")
end

--  Cada frame mientras dura. Devuelve true si la barrida movio el cuerpo.
function Tac.updateSlide(state, now)
	local slide = state.slide
	if not slide then return false end
	if now >= slide.finish or state.downed ~= "" then
		state.slide = nil
		setStance(state, 0)
		state.humanoid:Move(Vector3.zero)
		state.lastMoveTarget = nil		-- que stepMovement vuelva a mandar el MoveTo
		return false
	end
	if now >= slide.phase2 and state.stance ~= 4 then setStance(state, 4) end
	local t = (now - slide.start) / math.max(slide.finish - slide.start, 0.01)
	state.humanoid.WalkSpeed = slide.speed * (1 - t * 0.6)
	state.humanoid:Move(slide.dir)
	return true
end

-- --------------------------------------------------------------------------
--  Puestos, angulos y flanqueos
-- --------------------------------------------------------------------------
--  Defensiva: un lugar con algo de pared alrededor y vista abierta hacia
--  donde andan los enemigos.
function Tac.findHoldSpot(state)
	local rng = state.rng
	local origin = state.root.Position
	local enemies = gatherEnemies(state, math.huge)
	local enemyCenter = nil
	if #enemies > 0 then
		local sum = Vector3.zero
		for _, entry in ipairs(enemies) do sum += entry.root.Position end
		enemyCenter = sum / #enemies
	end
	local center = enemyCenter and origin:Lerp(enemyCenter, 0.35) or origin
	Tac.params.FilterDescendantsInstances = Tac.worldFilter()
	local best, bestScore = nil, nil
	for _ = 1, 16 do
		local angle = rng:NextNumber(0, math.pi * 2)
		local radius = rng:NextNumber(6, 45)
		local probe = Vector3.new(center.X + math.cos(angle) * radius, origin.Y + 6, center.Z + math.sin(angle) * radius)
		local ground = workspace:Raycast(probe, Vector3.new(0, -18, 0), Tac.params)
		if ground and ground.Normal.Y > 0.7 and not Tac.isUnreachable(ground.Position) then
			local spot = ground.Position
			local eye = spot + Vector3.new(0, 2.6, 0)
			--  Nada justo encima (debajo de una mesa no se campea).
			if not workspace:Raycast(spot + Vector3.new(0, 0.5, 0), Vector3.new(0, 4, 0), Tac.params) then
				local face = enemyCenter and flat(enemyCenter - spot) or Vector3.new(math.cos(angle), 0, math.sin(angle))
				face = face.Magnitude > 1 and face.Unit or Vector3.new(1, 0, 0)
				local walls = 0
				for k = 0, 7 do
					local a = k * math.pi / 4
					if workspace:Raycast(eye - Vector3.new(0, 1.2, 0), Vector3.new(math.cos(a), 0, math.sin(a)) * 6, Tac.params) then
						walls += 1
					end
				end
				local view = workspace:Raycast(eye, face * 80, Tac.params)
				local viewDist = view and (view.Position - eye).Magnitude or 80
				if walls >= 1 and walls <= 6 and viewDist >= 18 and Tac.climateOk(spot) then
					local score = walls * 6 + viewDist * 0.5 - (spot - origin).Magnitude * 0.15
					if not bestScore or score > bestScore then
						best, bestScore = { pos = spot, face = spot + face * 40 }, score
					end
				end
			end
		end
	end
	return best
end

--  Estratega: un punto cerca desde donde se VE el lugar del ruido, con
--  algo de cobertura al lado.
function Tac.findWatchSpot(state, target)
	local origin = state.root.Position
	Tac.params.FilterDescendantsInstances = Tac.worldFilter()
	local best, bestScore = nil, nil
	for _ = 1, 14 do
		local angle = state.rng:NextNumber(0, math.pi * 2)
		local radius = state.rng:NextNumber(6, 26)
		local probe = origin + Vector3.new(math.cos(angle) * radius, 4, math.sin(angle) * radius)
		local ground = workspace:Raycast(probe, Vector3.new(0, -12, 0), Tac.params)
		if ground and ground.Normal.Y > 0.7 then
			local eye = ground.Position + Vector3.new(0, 2.6, 0)
			local toTarget = (target + Vector3.new(0, 2, 0)) - eye
			local hit = workspace:Raycast(eye, toTarget, Tac.params)
			local seesIt = not hit or (hit.Position - eye).Magnitude > toTarget.Magnitude * 0.85
			if seesIt then
				local walls = 0
				for k = 0, 5 do
					local a = k * math.pi / 3
					if workspace:Raycast(eye - Vector3.new(0, 1, 0), Vector3.new(math.cos(a), 0, math.sin(a)) * 5, Tac.params) then
						walls += 1
					end
				end
				local score = walls * 4 - radius * 0.3 + math.min(toTarget.Magnitude, 80) * 0.1
				if not bestScore or score > bestScore then best, bestScore = ground.Position, score end
			end
		end
	end
	return best
end

--  Un punto al costado del objetivo, para llegarle por un lado.
function Tac.flankPoint(state, target)
	local dir = flat(target - state.root.Position)
	if dir.Magnitude < 1 then return nil end
	dir = dir.Unit
	local side = Vector3.new(-dir.Z, 0, dir.X) * (state.rng:NextNumber() < 0.5 and -1 or 1)
	return target + side * state.rng:NextNumber(18, 32)
end

-- --------------------------------------------------------------------------
--  Los cinco tipos de IA (cuando no estan peleando)
-- --------------------------------------------------------------------------
--  DEFENSIVA: toma un puesto y lo cubre agachado; cambia cada tanto.
function Tac.defend(state, now)
	local role = state.meta.role
	local hold = state.hold
	if hold and now > hold.untilT then
		state.hold = nil
		hold = nil
	end
	--  [IA v3] La amenaza ahora viene de otro lado y desde el puesto no se la
	--  ve: otro puesto (no se queda mirando a la pared unos 30 s).
	if hold and hold.threat and now - (hold.since or now) > 4 and now >= (state.nextHoldPick or 0) then
		local threat = Tac.threatGuess(state, now)
		if threat and (threat - hold.threat).Magnitude > 30 then
			hold.threat = threat
			Tac.params.FilterDescendantsInstances = Tac.worldFilter()
			local eye = hold.pos + Vector3.new(0, 4.6, 0)
			local hit = workspace:Raycast(eye, threat - eye, Tac.params)
			if hit and (hit.Position - eye).Magnitude < (threat - eye).Magnitude * 0.9 then
				state.hold = nil
				hold = nil
			end
		end
	end
	if not hold then
		if state.spotChecking then
			--  [IA v3] Comprobando el camino al puesto nuevo (un momento): quieto
			--  mirando hacia la amenaza, no sale a investigar el ruido.
			if state.moveMode ~= "hold" then stopWalking(state) end
			state.lookAt = Tac.threatGuess(state, now)
			state.lookUntil = now + 0.5
			return true
		end
		if now < (state.nextHoldPick or 0) then return false end
		state.nextHoldPick = now + 3
		--  [IA v3] Un puesto mirando todos los pisos (ventana del segundo piso,
		--  muro bajo, colina) hacia donde deberia venir el enemigo, con camino
		--  comprobado. Mientras lo comprueba, sigue con lo normal.
		local threat = Tac.AI.SmartPositions and Tac.threatGuess(state, now)
		if threat then
			local idealMin, idealMax, maxRange = Tac.weaponRanges(state)
			local origin = state.root.Position
			local ctx = { threat = threat, center = origin:Lerp(threat, 0.3), minRadius = 4, maxRadius = 45,
				needView = true, heightWeight = 0.8, idealMin = idealMin, idealMax = idealMax, maxRange = maxRange }
			local list = Tac.findPositions(state, ctx)
			if #list == 0 then
				--  Nada lo ve (esta detras de paredes): un lugar cubierto hacia alla.
				ctx.needView = false
				list = Tac.findPositions(state, ctx)
			end
			if #list > 0 then
				Tac.validateSpots(state, list, 4, function(candidate)
					state.hold = { pos = candidate.pos, face = threat, arrived = false, peek = candidate.peek,
						threat = threat, since = os.clock(),
						untilT = os.clock() + rangeNumber(state.rng, role.HoldTime or { 25, 55 }) }
					state.pathFails = 0
					dprint(state.bot.Name, candidate.pos.Y - origin.Y > 4 and "toma un puesto en alto" or "toma un puesto")
				end)
				return false
			end
		end
		local spot = Tac.findHoldSpot(state)
		if not spot then return false end
		hold = { pos = spot.pos, face = spot.face, untilT = now + rangeNumber(state.rng, role.HoldTime or { 25, 55 }), arrived = false }
		state.hold = hold
		state.pathFails = 0
	end
	local dist = flat(hold.pos - state.root.Position).Magnitude
	if not hold.arrived and not Tac.atPost(state, hold.pos, hold.peek and 1.6 or 3.5) then
		if not state.finalStep then Tac.goTo(state, now, hold.pos, "hold", dist > 40 and RUN_SPEED or WALK_SPEED, 5) end
		if state.pathFails >= 3 then
			state.hold = nil
			state.pathFails = 0
		end
		return true
	end
	if dist > 8 then
		--  Se movio peleando: vuelve a su puesto.
		hold.arrived = false
		return true
	end
	hold.arrived = true
	if state.moveMode ~= "hold" then stopWalking(state) end
	local look = state.orderLook or hold.face		-- [24/09] hacia donde dijo el Lider
	if state.noise and now - state.noise.at < 6 then
		look = state.noise.pos
	elseif state.lastSeenPos and now - state.lastSeenAt < 8 then
		look = state.lastSeenPos
	end
	state.lookAt = look
	state.lookUntil = now + 0.5
	return true
end

--  ESTRATEGA: con lo que oye o le avisan, busca un angulo para cubrir ese
--  punto, lo vigila agachado y despues flanquea por un costado.
function Tac.strategize(state, now)
	local role = state.meta.role
	local watch = state.watch
	if watch then
		if now > watch.untilT then
			state.flankGoal = Tac.flankPoint(state, watch.info)
			state.flankUntil = now + 14
			state.watch = nil
			state.pathFails = 0
			--  Un respiro antes de la siguiente vigilancia: ahora le toca moverse.
			state.nextWatchAt = now + rangeNumber(state.rng, role.WatchCooldown or { 8, 16 })
		else
			local dist = flat(watch.pos - state.root.Position).Magnitude
			if not watch.arrived and not Tac.atPost(state, watch.pos, watch.peek and 1.6 or 3.5) then
				if not state.finalStep then Tac.goTo(state, now, watch.pos, "watch", WALK_SPEED, 3) end
				if state.pathFails >= 3 then watch.arrived = true end
				return true
			end
			watch.arrived = true
			if state.moveMode ~= "hold" then stopWalking(state) end
			state.lookAt = watch.info
			state.lookUntil = now + 0.5
			return true
		end
	end

	local info = nil
	if now < (state.nextWatchAt or 0) then
		--  En su respiro: flanquea (abajo) o sigue lo normal.
	elseif state.noise and now - state.noise.at < 5 and state.noise.at > (state.lastInfoHandled or -1) then
		info = state.noise.pos
		state.lastInfoHandled = state.noise.at
	else
		local intel = Tac.intel(state, now)
		if intel and intel.at > (state.lastInfoHandled or -1) then
			info = intel.pos
			state.lastInfoHandled = intel.at
		end
	end
	if info then
		--  [IA v3] El angulo se busca en todos los pisos (una ventana arriba).
		local spot, peekSpot = nil, false
		if Tac.AI.SmartPositions then
			local idealMin, idealMax = Tac.weaponRanges(state)
			local best = Tac.findPositions(state, { threat = info, center = state.root.Position, minRadius = 4, maxRadius = 30,
				needView = true, samples = 18, heightWeight = 0.6, idealMin = idealMin, idealMax = idealMax })[1]
			if best then spot, peekSpot = best.pos, best.peek end
		end
		spot = spot or Tac.findWatchSpot(state, info) or state.root.Position
		state.watch = { pos = spot, info = info, untilT = now + rangeNumber(state.rng, role.WatchTime or { 6, 12 }), arrived = false, peek = peekSpot }
		state.noise = nil
		state.pathFails = 0
		return true
	end

	if state.flankGoal and now < (state.flankUntil or 0) then
		local dist = flat(state.flankGoal - state.root.Position).Magnitude
		if dist < 5 or state.pathFails >= 3 then
			state.flankGoal = nil
			state.pathFails = 0
			return false
		end
		Tac.goTo(state, now, state.flankGoal, "flank", WALK_SPEED, 3)
		return true
	end
	return false
end

--  EQUIPO: va con un companero (un jugador real primero) y todos a donde
--  un bot del equipo vio a alguien.
function Tac.teamUp(state, now)
	local role = state.meta.role
	local intel = Tac.intel(state, now)
	if intel and flat(intel.pos - state.root.Position).Magnitude > 14 then
		Tac.goTo(state, now, intel.pos, "intel", RUN_SPEED, 2)
		return true
	end
	local leader = nil
	--  [23/09 noche] En Guardian, el de equipo va de escolta del lider.
	for _, mate in ipairs(Tac.teammates(state)) do
		if mate.participant:GetAttribute("GuardianLeader") == true then
			leader = mate
			break
		end
	end
	for _, mate in ipairs(leader and {} or Tac.teammates(state)) do
		local mateBrain = brains[mate.participant]
		local follower = mateBrain and mateBrain.meta.role and mateBrain.meta.role.Kind == "Equipo"
		if not follower then
			if typeof(mate.participant) == "Instance" then
				leader = mate
				break
			end
			leader = leader or mate
		end
	end
	if not leader then return false end
	local follow = role.FollowRange or { 8, 20 }
	if leader.dist > follow[2] then
		local behind = leader.root.CFrame.LookVector * -6 + leader.root.CFrame.RightVector * (state.followSide or 4)
		Tac.goTo(state, now, leader.root.Position + behind, "follow", leader.dist > 45 and RUN_SPEED or WALK_SPEED, 1.2)
	else
		if state.moveMode ~= "hold" and leader.dist <= follow[1] + 4 then stopWalking(state) end
		state.lookAt = state.root.Position + leader.root.CFrame.LookVector * 30
		state.lookUntil = now + 0.5
	end
	return true
end

--  APOYO: va a ayudar al companero que esta peleando (levantar ya tiene
--  prioridad antes que esto, y busca mucho mas lejos).
function Tac.support(state, now)
	local role = state.meta.role
	local best = nil
	local mates = Tac.teammates(state)
	for _, mate in ipairs(mates) do
		local fighting, threat = false, nil
		local mateBrain = brains[mate.participant]
		if mateBrain and mateBrain.visible and mateBrain.target then
			fighting, threat = true, mateBrain.target.root.Position
		elseif typeof(mate.participant) == "Instance" then
			local combatUntil = tonumber(mate.participant:GetAttribute("CombatUntil"))
			fighting = combatUntil ~= nil and combatUntil > workspace:GetServerTimeNow()
		end
		if fighting and mate.dist <= (role.SupportRange or 130) and (not best or mate.dist < best.dist) then
			best = mate
			best.threat = threat
		end
	end
	if best then
		if best.dist > 10 then
			Tac.goTo(state, now, best.root.Position, "support", RUN_SPEED, 1.5)
		else
			if state.moveMode ~= "hold" then stopWalking(state) end
			state.lookAt = best.threat or (best.root.Position + best.root.CFrame.LookVector * 30)
			state.lookUntil = now + 0.5
		end
		return true
	end
	--  Sin peleas: no se aleja mucho del companero mas cercano.
	local nearest = mates[1]
	if nearest and nearest.dist > 28 then
		Tac.goTo(state, now, nearest.root.Position, "follow", WALK_SPEED, 2)
		return true
	end
	return false
end

--  ATAQUE: si alguien del equipo vio a un enemigo, va derecho y corriendo.
function Tac.assault(state, now)
	local intel = Tac.intel(state, now)
	if intel and flat(intel.pos - state.root.Position).Magnitude > 10 then
		Tac.goTo(state, now, intel.pos, "intel", RUN_SPEED, 2)
		return true
	end
	return false
end

-- --------------------------------------------------------------------------
--  CLIMAS: techo y lugar alto (23/09 noche)
-- --------------------------------------------------------------------------
Tac.probeParams = RaycastParams.new()
Tac.probeParams.FilterType = Enum.RaycastFilterType.Exclude
Tac.probeParams.IgnoreWater = true
Tac.badSpots = true		-- recordar lugares "seguros" que resultaron no servir

--  Que clima especial hay (cacheado 1 s). shelter = hay que estar bajo techo
--  (ventisca, lluvia acida, huracan); flood = inundacion.
function Tac.hazards(now)
	local cache = Tac.hazardCache
	if cache and now - cache.at < 1 then return cache.value end
	local value = nil
	if AmbienceConfig and type(AmbienceConfig.specialFor) == "function" and currentPhase() == "Round" then
		local ok, special = pcall(AmbienceConfig.specialFor, roundState:GetAttribute("WinningAmbience"))
		if ok and type(special) == "table" then
			local shelter = special.Freeze ~= nil or special.Acid ~= nil or special.Lightning ~= nil
			local flood = special.Flood ~= nil
			if shelter or flood then value = { shelter = shelter, flood = flood } end
		end
	end
	Tac.hazardCache = { at = now, value = value }
	return value
end

--  Techo solido encima de este punto del suelo (mismo criterio que el
--  clima: hojas, piezas sin colision, invisibles y bordes no cuentan).
--  (fromHeight: desde que altura sobre el punto se mira hacia arriba. Por
--  defecto 4.8 = la cabeza de pie, como mide el clima; un techo bajo a la
--  altura del pecho no cuenta.)
function Tac.isSheltered(point, fromHeight)
	local from = point + Vector3.new(0, fromHeight or 4.8, 0)
	--  [IA v2] Copia (el filtro compartido no se toca) y rayos propios (no
	--  pisa el filtro de Tac.params de quien la llama a mitad de un bucle).
	local filter = table.clone(Tac.worldFilter())
	for _ = 1, 8 do
		Tac.shelterParams.FilterDescendantsInstances = filter
		local result = workspace:Raycast(from, Vector3.new(0, 250, 0), Tac.shelterParams)
		if not result then return false end
		local part = result.Instance
		local ignorable = part ~= workspace.Terrain and (not part.CanCollide or part.Transparency >= 0.9
			or part.Material == Enum.Material.ForceField or part.Name == "LimiteMapa")
		if not ignorable then return true end
		table.insert(filter, part)
		from = result.Position
	end
	return false
end

--  El agua de la inundacion no llega a este punto del suelo. Mismo criterio
--  que ClimaEspecialServer (isInWater): el voxel de terreno a la altura de
--  los pies y el del torso; si cualquiera es agua, esta mojado.
function Tac.isDry(point)
	for _, height in ipairs({ 0.5, 3 }) do
		local p = point + Vector3.new(0, height, 0)
		local region = Region3.new(p - Vector3.new(0.1, 0.1, 0.1), p + Vector3.new(0.1, 0.1, 0.1)):ExpandToGrid(4)
		local ok, mats = pcall(function() return workspace.Terrain:ReadVoxels(region, 4) end)
		if ok and mats[1] and mats[1][1] and mats[1][1][1] == Enum.Material.Water then
			return false
		end
	end
	return true
end

--  El clima no le hace nada en este punto.
function Tac.climateOk(point)
	local hazards = Tac.hazards(os.clock())
	if not hazards then return true end
	if hazards.shelter and not Tac.isShelteredDeep(point) then return false end
	if hazards.flood and not Tac.isDry(point) then return false end
	return true
end

--  Techo que de verdad cubre: encima del punto y alrededor (a 2.5 studs en
--  las cuatro direcciones, deja fallar una). Una viga o un alero angosto
--  pasaban la prueba y el bot quedaba a la intemperie a un paso del punto.
function Tac.isShelteredDeep(point)
	if not Tac.isSheltered(point) then return false end
	local misses = 0
	for _, offset in ipairs({ Vector3.new(2.5, 0, 0), Vector3.new(-2.5, 0, 0), Vector3.new(0, 0, 2.5), Vector3.new(0, 0, -2.5) }) do
		if not Tac.isSheltered(point + offset) then
			misses += 1
			if misses > 1 then return false end
		end
	end
	return true
end

--  Punto cercano que cumpla (bajo techo y/o seco). Anillos que crecen y
--  tres alturas por direccion (pisos de arriba, escaleras, azoteas); en
--  inundacion, entre los secos prefiere el mas alto.
function Tac.findSafeSpot(state, needShelter, needDry, maxRadius, stepSize, directions)
	local origin = state.root.Position
	local rng = state.rng
	local step = stepSize or 8
	local dirs = directions or 12
	--  [IA v2] Una vez, no en cada uno de los cientos de rayos.
	Tac.probeParams.FilterDescendantsInstances = Tac.worldFilter()
	for ring = 1, math.max(1, math.ceil(maxRadius / step)) do
		local radius = ring * step
		local best, bestScore = nil, nil
		for i = 0, dirs - 1 do
			local angle = i * (math.pi * 2 / dirs) + rng:NextNumber(-0.25, 0.25)
			for _, lift in ipairs({ 0, 14, 28 }) do
				local probe = origin + Vector3.new(math.cos(angle) * radius, 6 + lift, math.sin(angle) * radius)
				local ground = workspace:Raycast(probe, Vector3.new(0, -(14 + lift), 0), Tac.probeParams)
				if ground and ground.Normal.Y > 0.7 then
					local spot = ground.Position
					local ok = (not needDry or Tac.isDry(spot)) and (not needShelter or Tac.isShelteredDeep(spot))
					if ok and Tac.badSpots then
						--  Lugares que ya probo y no sirvieron.
						for _, bad in ipairs(state.badSafeSpots or {}) do
							if (bad - spot).Magnitude < 6 then ok = false break end
						end
					end
					if ok then
						local score = -radius + (needDry and (spot.Y - origin.Y) * 0.5 or 0)
						if not bestScore or score > bestScore then best, bestScore = spot, score end
					end
				end
			end
		end
		if best then return best end
	end
	return nil
end

--  true si el clima se hizo cargo del movimiento en esta vuelta.
function Tac.weatherSafety(state, now)
	local handled, reason = Tac.weatherSafetyInner(state, now)
	if Config.Debug then state.character:SetAttribute("BotClima", reason) end
	return handled
end

function Tac.weatherSafetyInner(state, now)
	local hazards = Tac.hazards(now)
	if not hazards then
		state.safeGoal = nil
		return false, "sin clima"
	end
	local W = Config.Weather or {}
	local AI = Tac.AI
	local target = state.target
	--  [IA v2] Con vida, la pelea va primero: un enemigo a la vista (hasta
	--  WeatherFightRange), uno que acaba de perder de vista o un tiro que
	--  acaba de oir. Herido, vuelve a la regla vieja (solo si lo tiene encima).
	local healthy = state.humanoid.Health / math.max(state.humanoid.MaxHealth, 1) >= AI.WeatherPanicHealth
	local fightRange = healthy and math.max(W.FightFirst or 0, AI.WeatherFightRange) or (W.FightFirst or 20)
	if target and state.visible and (target.root.Position - state.root.Position).Magnitude < fightRange then
		return false, "peleando cerca"
	end
	if healthy and ((target and now - state.lastSeenAt < 5) or (state.noise and now - state.noise.at < 4)) then
		return false, "buscando pelea"
	end
	if now >= (state.nextHazardCheck or 0) then
		state.nextHazardCheck = now + 0.5
		local feet = state.root.Position - Vector3.new(0, 3, 0)
		state.inWater = hazards.flood and (state.character:GetAttribute("EnAgua") == true
			or state.humanoid:GetState() == Enum.HumanoidStateType.Swimming or not Tac.isDry(feet)) or false
		--  Desde su cabeza, igual que lo mide ClimaEspecialServer.
		state.skyExposed = hazards.shelter and not Tac.isSheltered(state.head.Position, 0) or false
		if state.inWater or state.skyExposed then
			state.exposedSince = state.exposedSince or now
		else
			state.exposedSince = nil
		end
	end
	if not state.inWater and not state.skyExposed then
		state.safeGoal = nil
		return false, "a resguardo"
	end
	--  [IA v2] Aguanta un rato a la intemperie (como un jugador que termina lo
	--  que estaba haciendo) antes de ir a buscar techo.
	local tolerance = state.inWater and AI.FloodTolerance or AI.WeatherTolerance
	if healthy and not state.safeGoal and now - (state.exposedSince or now) < tolerance then
		return false, "aguanta el clima"
	end
	local goal = state.safeGoal
	if goal and (now > goal.untilT or state.pathFails >= 2) then
		--  Llego y sigue expuesto / mojado, o no hay camino: ese lugar no sirve.
		state.badSafeSpots = state.badSafeSpots or {}
		table.insert(state.badSafeSpots, goal.pos)
		if #state.badSafeSpots > 16 then table.remove(state.badSafeSpots, 1) end
		goal = nil
		state.pathFails = 0
		--  Tres lugares seguidos que no sirven (un tunel inundado, un mapa sin
		--  techo alcanzable): deja de intentarlo un rato y juega normal.
		if now - (state.safeFailWindow or 0) > 40 then
			state.safeFailWindow = now
			state.safeFailures = 0
		end
		state.safeFailures = (state.safeFailures or 0) + 1
		if state.safeFailures >= 3 then
			state.safeFailures = 0
			state.safeGoal = nil
			state.noShelterUntil = now + 20
			state.nextSafeSearch = now + 20
			return false, "sin lugar seguro cerca"
		end
	end
	if not goal then
		if now < (state.nextSafeSearch or 0) then
			return false, (state.noShelterUntil and now < state.noShelterUntil) and "sin lugar seguro cerca" or "esperando busqueda"
		end
		state.nextSafeSearch = now + 2
		local radius = state.inWater and (W.HighGroundSearch or 100) or (W.ShelterSearch or 70)
		local spot = Tac.findSafeSpot(state, hazards.shelter, hazards.flood, radius)
		if not spot and hazards.shelter and hazards.flood then
			--  Techo Y seco no hay: primero salir del agua.
			spot = Tac.findSafeSpot(state, false, true, radius)
		end
		if not spot then
			--  Nada cerca: busca mas lejos, con menos detalle.
			spot = Tac.findSafeSpot(state, hazards.shelter and not state.inWater, state.inWater, W.MaxSearch or 160, 12, 8)
		end
		if not spot then
			--  No hay donde resguardarse: que juegue normal un rato en vez de
			--  quedarse parado buscando.
			state.noShelterUntil = now + 15
			state.nextSafeSearch = now + 15
			return false, "sin lugar seguro cerca"
		end
		state.noShelterUntil = nil
		goal = { pos = spot, untilT = now + 20 }
		state.safeGoal = goal
		dprint(state.bot.Name, state.inWater and "busca un lugar alto" or "busca techo")
	end
	--  Ya casi llega: camina derecho al punto exacto (el camino ya termino y
	--  pedir otro tan corto falla). Si ya esta encima y sigue expuesto, lo
	--  descarta en la proxima vuelta.
	local distToGoal = flat(goal.pos - state.root.Position).Magnitude
	if distToGoal < 5 then
		state.waypoints = nil
		state.moveMode = "direct"
		state.humanoid.WalkSpeed = WALK_SPEED
		state.humanoid:MoveTo(goal.pos)
		if distToGoal < 1.2 then
			goal.untilT = math.min(goal.untilT, now + 1.5)
		end
		return true, "llegando a lugar seguro"
	end
	Tac.goTo(state, now, goal.pos, "safe", RUN_SPEED, 3)
	return true, state.inWater and "yendo a lugar alto" or "yendo al techo"
end

--  Con clima peligroso, cambia un destino por uno seguro cerca de el; nil
--  si no hay (se queda donde esta, a resguardo).
function Tac.safeRoamGoal(state, goal, now)
	if not goal or not Tac.hazards(now) then return goal end
	if Tac.climateOk(goal) then return goal end
	for _ = 1, 10 do
		local angle = state.rng:NextNumber(0, math.pi * 2)
		local radius = state.rng:NextNumber(4, 30)
		Tac.probeParams.FilterDescendantsInstances = Tac.worldFilter()
		local probe = goal + Vector3.new(math.cos(angle) * radius, 8, math.sin(angle) * radius)
		local ground = workspace:Raycast(probe, Vector3.new(0, -20, 0), Tac.probeParams)
		if ground and ground.Normal.Y > 0.7 and Tac.climateOk(ground.Position) then
			return ground.Position
		end
	end
	return nil
end

-- --------------------------------------------------------------------------
--  LIDER DE GUARDIAN (23/09 noche)
-- --------------------------------------------------------------------------
function Tac.isLeader(state)
	return state.bot:GetAttribute("GuardianLeader") == true
end

--  Un puesto detras de su equipo (del lado contrario a los enemigos), con
--  paredes cerca y, si se puede, donde no lo vean desde la zona enemiga.
function Tac.findLeaderSpot(state, enemies)
	--  [IA v2] Filtros una sola vez (antes se armaban en cada vuelta del bucle).
	Tac.probeParams.FilterDescendantsInstances = Tac.worldFilter()
	Tac.params.FilterDescendantsInstances = Tac.worldFilter()
	local L = Config.Leader or {}
	local origin = state.root.Position
	local enemyCenter = nil
	if #enemies > 0 then
		local sum = Vector3.zero
		for _, entry in ipairs(enemies) do sum += entry.root.Position end
		enemyCenter = sum / #enemies
	end
	local mates = Tac.teammates(state)
	local teamCenter = origin
	if #mates > 0 then
		local sum, n = Vector3.zero, math.min(#mates, 4)
		for i = 1, n do sum += mates[i].root.Position end
		teamCenter = sum / n
	end
	local base = teamCenter
	if enemyCenter then
		local away = flat(teamCenter - enemyCenter)
		if away.Magnitude > 1 then base = teamCenter + away.Unit * (L.BehindTeam or 20) end
	end
	local rng = state.rng
	local best, bestScore = nil, nil
	for _ = 1, 16 do
		local angle = rng:NextNumber(0, math.pi * 2)
		local radius = rng:NextNumber(0, 22)
		local probe = Vector3.new(base.X + math.cos(angle) * radius, math.max(base.Y, origin.Y) + 8, base.Z + math.sin(angle) * radius)
		local ground = workspace:Raycast(probe, Vector3.new(0, -26, 0), Tac.probeParams)
		if ground and ground.Normal.Y > 0.7 and Tac.climateOk(ground.Position) then
			local spot = ground.Position
			local eye = spot + Vector3.new(0, 2.4, 0)
			local walls = 0
			for k = 0, 7 do
				local a = k * math.pi / 4
				if workspace:Raycast(eye - Vector3.new(0, 1, 0), Vector3.new(math.cos(a), 0, math.sin(a)) * 6, Tac.params) then
					walls += 1
				end
			end
			local hidden = 0
			local far = 0
			if enemyCenter then
				local from = enemyCenter + Vector3.new(0, 2, 0)
				local hit = workspace:Raycast(from, eye - from, Tac.params)
				if hit and (hit.Position - eye).Magnitude > 1.5 then hidden = 1 end
				far = (spot - enemyCenter).Magnitude
			end
			local score = walls * 3 + hidden * 25 + far * 0.3 - (spot - origin).Magnitude * 0.1
			if not bestScore or score > bestScore then best, bestScore = spot, score end
		end
	end
	return best, enemyCenter
end

function Tac.leaderMove(state, now)
	local L = Config.Leader or {}
	local humanoid = state.humanoid
	local target = state.target

	if target and state.visible then
		local dist = (target.root.Position - state.root.Position).Magnitude
		if dist < (L.CloseFight or 22) then
			--  Alguien encima: pelea, pero retrocediendo.
			humanoid.WalkSpeed = WALK_SPEED
			state.leaderSpot = nil
			if state.moveMode ~= "strafe" or now >= state.strafeUntil then
				local away = flat(state.root.Position - target.root.Position)
				local side = state.root.CFrame.RightVector * (state.rng:NextNumber() < 0.5 and -0.7 or 0.7)
				startStrafe(state, now, (away.Magnitude > 0.1 and away.Unit or side) + side, 0.8)
			end
			return
		end
		--  De lejos no se pone a pelear (ni dispara si no le estan pegando,
		--  para no delatarse): corta la linea de vision.
		local recentlyHit = state.lastDamageAt and now - state.lastDamageAt < 3
		if dist > 40 and not recentlyHit then state.holdFire = true end
		if not state.leaderCover or now > state.leaderCover.untilT then
			local spot = Tac.findCover(state, target.root.Position)
			state.leaderCover = spot and { pos = spot, untilT = now + 6, arrived = false } or nil
		end
	end

	local cover = state.leaderCover
	if cover and now <= cover.untilT then
		if not cover.arrived and flat(cover.pos - state.root.Position).Magnitude > 3 then
			Tac.goTo(state, now, cover.pos, "leadercover", RUN_SPEED, 2)
			return
		end
		cover.arrived = true
		if state.moveMode ~= "hold" then stopWalking(state) end
		return
	end
	state.leaderCover = nil

	--  Puesto seguro detras de su equipo; si un enemigo se le acerca, otro.
	local enemies = gatherEnemies(state, math.huge)
	local spot = state.leaderSpot
	local threatened = false
	if spot then
		for _, entry in ipairs(enemies) do
			if (entry.root.Position - spot.pos).Magnitude < (L.SafeDistance or 45) then
				threatened = true
				break
			end
		end
	end
	if (not spot or now > spot.untilT or threatened or state.pathFails >= 3) and now >= (state.nextLeaderPick or 0) then
		state.nextLeaderPick = now + 2
		state.pathFails = 0
		local pos, enemyCenter = Tac.findLeaderSpot(state, enemies)
		spot = pos and { pos = pos, face = enemyCenter, untilT = now + (L.Repick or 12), arrived = false } or nil
		state.leaderSpot = spot
	end
	if not spot then
		if state.moveMode ~= "hold" then stopWalking(state) end
		return
	end
	local dist = flat(spot.pos - state.root.Position).Magnitude
	if dist > 3.5 then
		spot.arrived = false
		Tac.goTo(state, now, spot.pos, "leader", dist > 30 and RUN_SPEED or WALK_SPEED, 3)
		return
	end
	spot.arrived = true
	if state.moveMode ~= "hold" then stopWalking(state) end
	if spot.face then
		state.lookAt = spot.face
		state.lookUntil = now + 0.5
	end
end

-- --------------------------------------------------------------------------
--  SIGILOSO (23/09 noche)
-- --------------------------------------------------------------------------
--  Presa: prefiere al que esta peleando con otro (distraido) y, si no, al
--  mas cercano. Se queda con ella un rato para no cambiar de plan a cada rato.
function Tac.pickPrey(state, now)
	local prey = state.prey
	if prey and now < prey.untilT and prey.character.Parent and prey.humanoid.Health > 0
		and prey.participant:GetAttribute("InRound") == true and not isDownedCharacter(prey.character) then
		return prey
	end
	state.prey = nil
	local best, bestScore = nil, nil
	for _, entry in ipairs(gatherEnemies(state, math.huge)) do
		if not entry.downed then
			local busy = false
			local enemyBrain = brains[entry.participant]
			if enemyBrain and enemyBrain.visible then
				busy = true
			elseif typeof(entry.participant) == "Instance" then
				local combatUntil = tonumber(entry.participant:GetAttribute("CombatUntil"))
				busy = combatUntil ~= nil and combatUntil > workspace:GetServerTimeNow()
			end
			local score = entry.dist - (busy and 60 or 0)
			--  [24/09] El que marco el Lider es su presa.
			if state.forcedPrey and entry.participant == state.forcedPrey then score -= 1000 end
			if not bestScore or score < bestScore then best, bestScore = entry, score end
		end
	end
	if best then
		best.untilT = now + 25
		best.phase = "wide"
		state.prey = best
		state.pathFails = 0
	end
	return best
end

--  Se abre bien por un costado (el mas lejos de la pelea) y despues entra
--  por la espalda de la presa, agachado cuando ya esta cerca.
function Tac.stealth(state, now)
	local role = state.meta.role
	local prey = Tac.pickPrey(state, now)
	if not prey then return false end
	local preyPos = prey.root.Position
	local myPos = state.root.Position
	local toPrey = flat(preyPos - myPos)
	local dist = toPrey.Magnitude
	local look = flat(prey.root.CFrame.LookVector)
	look = look.Magnitude > 0.1 and look.Unit or (dist > 0.1 and toPrey.Unit or Vector3.new(0, 0, -1))
	prey.behindDist = prey.behindDist or rangeNumber(state.rng, role.BehindDist or { 12, 20 })
	local behind = preyPos - look * prey.behindDist

	if prey.phase == "wide" then
		if not prey.widePoint then
			local dir = dist > 0.1 and toPrey.Unit or Vector3.new(1, 0, 0)
			local perp = Vector3.new(-dir.Z, 0, dir.X)
			local wide = rangeNumber(state.rng, role.FlankWide or { 35, 55 })
			local sideA, sideB = preyPos + perp * wide, preyPos - perp * wide
			local pick = state.rng:NextNumber() < 0.5 and sideA or sideB
			local intel = Tac.intel(state, now)
			if intel then
				--  Lejos de donde se esta peleando.
				pick = ((sideA - intel.pos).Magnitude >= (sideB - intel.pos).Magnitude) and sideA or sideB
			end
			prey.widePoint = pick:Lerp(behind, 0.35)
		end
		if flat(prey.widePoint - myPos).Magnitude < 8 or state.pathFails >= 3 or dist < 30 then
			prey.phase = "behind"
			state.pathFails = 0
		else
			Tac.goTo(state, now, prey.widePoint, "sneak", dist > 90 and RUN_SPEED or WALK_SPEED, 3)
			return true
		end
	end

	state.sneakClose = dist < (role.CrouchRange or 45)
	Tac.goTo(state, now, behind, "sneak", state.sneakClose and CROUCH_SPEED or WALK_SPEED, 1.5)
	if flat(behind - myPos).Magnitude < 4 then
		state.lookAt = preyPos
		state.lookUntil = now + 0.5
	end
	if state.pathFails >= 4 then
		state.prey = nil
		state.pathFails = 0
	end
	return true
end

-- --------------------------------------------------------------------------
--  PUERTAS (23/09 noche; [IA v3] 26/09: pasarlas bien)
--
--  Las puertas de los mapas se abren con un ProximityPrompt, y un prompt solo
--  lo puede activar un cliente. Los scripts de las puertas se parcharon para
--  escuchar tambien un BindableEvent "BotTrigger" dentro del prompt (hace lo
--  mismo que Triggered: abre / cierra con su sonido). Aqui:
--    · cada puerta lleva un PathfindingModifier PassThrough, asi los caminos
--      no la toman como pared y pasan por ella;
--    · [IA v3] se mira el camino que sigue (hasta ~9 studs, doblando con el
--      camino). Una puerta cerrada en el medio se abre desde cerca, se
--      espera quieto hasta que deja pasar (sin saltarle encima), y si la
--      hoja abierta queda tapando el paso se pasa por el costado libre;
--    · abierta = su script lo dice (texto "Close" / atributo Open) o la hoja
--      ya no esta donde estaba al registrarse. Una puerta abierta nunca se
--      vuelve a cerrar (antes, con un kit que no cambia el texto, el
--      siguiente bot la cerraba en la cara del primero);
--    · una que no abre (con llave, un script sin el parche) pasa a ser pared
--      para los caminos DoorLockedTime segundos y se busca otra ruta.
-- --------------------------------------------------------------------------
Tac.doorParts = setmetatable({}, { __mode = "k" })		-- [BasePart] = puerta
Tac.doorList = {}
Tac.doorCooldown = setmetatable({}, { __mode = "k" })	-- [prompt] = cuando se uso
Tac.doorParams = RaycastParams.new()
Tac.doorParams.FilterType = Enum.RaycastFilterType.Exclude
Tac.doorParams.IgnoreWater = true

function Tac.registerDoor(botTrigger)
	local prompt = botTrigger.Parent
	if not prompt or not prompt:IsA("ProximityPrompt") then return end
	local model = prompt:FindFirstAncestorOfClass("Model")
	if not model then return end
	for _, door in ipairs(Tac.doorList) do
		if door.prompt == prompt then return end
	end
	--  home: donde esta cada pieza solida al empezar (cerrada): si se movio,
	--  esta abierta, diga lo que diga el texto del prompt.
	local info = { prompt = prompt, trigger = botTrigger, model = model, home = {} }
	table.insert(Tac.doorList, info)
	local biggest = 0
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			Tac.doorParts[part] = info
			if part.CanCollide then
				info.home[part] = part.CFrame
				--  El hueco de la puerta: la hoja cerrada (la pieza mas grande).
				local size = part.Size
				local area = math.max(size.X, size.Z) * size.Y
				local thin = flat(size.X < size.Z and part.CFrame.RightVector or part.CFrame.LookVector)
				if area > biggest and thin.Magnitude > 0.5 then
					biggest = area
					info.doorway = { center = part.Position, normal = thin.Unit }
				end
			end
		end
	end
	if not model:FindFirstChild("BotDoorPassThrough") then
		local modifier = Instance.new("PathfindingModifier")
		modifier.Name = "BotDoorPassThrough"
		modifier.Label = "BotDoor"
		modifier.PassThrough = true
		modifier.Parent = model
	end
end

--  La hoja ya no esta donde estaba (giro, se deslizo o dejo de ser solida).
function Tac.doorMoved(info)
	for part, home in pairs(info.home) do
		if part.Parent then
			if not part.CanCollide then return true end
			local cframe = part.CFrame
			if (cframe.Position - home.Position).Magnitude > 0.4 or cframe.LookVector:Dot(home.LookVector) < 0.97 then
				return true
			end
		end
	end
	return false
end

--  Abierta segun el propio script de la puerta (el kit de la casa / Metro
--  cambia el texto del prompt a "Close"; RealisticDoorPack usa el atributo
--  Open) o porque la hoja se movio.
function Tac.doorIsOpen(info)
	if info.model:GetAttribute("Open") == true then return true end
	local text = info.prompt.ActionText
	if text == "Close" or text == "Cerrar" then return true end
	return Tac.doorMoved(info)
end

function Tac.doorAnchor(info)
	local parent = info.prompt.Parent
	if parent and parent:IsA("BasePart") then return parent.Position end
	if parent and parent:IsA("Attachment") then return parent.WorldPosition end
	return nil
end

--  Una pieza solida de ESA puerta delante (en la direccion en que pasa).
function Tac.doorBlocking(state, info, dir, reach)
	Tac.doorParams.FilterDescendantsInstances = { state.character, ACS_Workspace }
	for _, height in ipairs({ 0.5, -1.2 }) do
		local result = workspace:Raycast(state.root.Position + Vector3.new(0, height, 0), dir * (reach or 4), Tac.doorParams)
		if result and Tac.doorParts[result.Instance] == info and result.Instance.CanCollide then return result end
	end
	return nil
end

--  Tramos del camino que tiene por delante (hasta 'reach' studs), a la
--  altura de su cuerpo.
function Tac.routeAhead(state, reach)
	local root = state.root.Position
	local out = {}
	if state.moveMode == "path" and state.waypoints then
		local total, prev = 0, root
		for i = state.wpIndex, math.min(#state.waypoints, state.wpIndex + 3) do
			local point = state.waypoints[i].Position + Vector3.new(0, 3, 0)
			local segment = point - prev
			local length = segment.Magnitude
			if length > 0.2 then
				table.insert(out, { from = prev, dir = segment.Unit, length = math.min(length, reach - total) })
				total += length
				if total >= reach then break end
			end
			prev = point
		end
	elseif state.moveMode == "direct" then
		local segment = flat(state.humanoid.WalkToPoint - root)
		if segment.Magnitude > 0.5 then
			table.insert(out, { from = root, dir = segment.Unit, length = math.min(segment.Magnitude, reach) })
		end
	end
	return out
end

--  Cada vuelta de decisiones: una puerta en el camino que sigue.
function Tac.checkDoors(state, now)
	if #Tac.doorList == 0 or state.doorPass then return end
	if state.moveMode ~= "path" and state.moveMode ~= "direct" then return end
	--  Sin ninguna puerta cerca, ni un rayo.
	local root = state.root.Position
	local near = false
	for _, info in ipairs(Tac.doorList) do
		local anchor = info.doorway and info.doorway.center or Tac.doorAnchor(info)
		if anchor and (anchor - root).Magnitude < 14 then
			near = true
			break
		end
	end
	if not near then return end
	Tac.doorParams.FilterDescendantsInstances = { state.character, ACS_Workspace }
	for _, segment in ipairs(Tac.routeAhead(state, 9)) do
		for _, height in ipairs({ 0.5, -1.2 }) do
			local result = workspace:Raycast(segment.from + Vector3.new(0, height, 0), segment.dir * segment.length, Tac.doorParams)
			local info = result and Tac.doorParts[result.Instance]
			if info and result.Instance.CanCollide then
				Tac.startDoorPass(state, now, info, segment.dir)
				return
			end
		end
	end
end

function Tac.startDoorPass(state, now, info, dir)
	--  Trabada / con llave: los caminos ya la toman como pared.
	if info.lockedUntil and now < info.lockedUntil then return end
	local horizontal = flat(dir)
	if horizontal.Magnitude < 0.2 then return end
	state.doorPass = { info = info, dir = horizontal.Unit, startAt = now, phase = "approach", tries = 0 }
end

--  Activa el prompt (como un jugador apretando E). Si otro bot la acaba de
--  usar, solo espera a que termine de moverse.
function Tac.fireDoor(state, now, info)
	local prompt = info.prompt
	local last = Tac.doorCooldown[prompt]
	if last and now - last.at < (last.by == state and 1.5 or 2.5) then return end
	if not prompt.Enabled or not info.trigger.Parent then return end
	Tac.doorCooldown[prompt] = { at = now, by = state }
	info.trigger:Fire()
	dprint(state.bot.Name, "abre una puerta")
end

--  No hay forma de pasar por esta puerta: se deja el camino (el proximo ya
--  la toma como pared si quedo marcada) y cuenta como falla del destino.
function Tac.doorGiveUp(state, now, info)
	state.doorPass = nil
	state.detour = nil
	state.waypoints = nil
	state.moveMode = "hold"
	state.humanoid:MoveTo(state.root.Position)
	state.pathFails += 1
	state.goodPath = nil
	state.lastRepath = now - 1
end

function Tac.lockDoor(info, now)
	local AI = Tac.AI
	info.lockedUntil = now + AI.DoorLockedTime
	local modifier = info.model:FindFirstChild("BotDoorPassThrough")
	if modifier then modifier.PassThrough = false end
	dprint("puerta que no abre (" .. info.model.Name .. "): es pared por " .. AI.DoorLockedTime .. " s")
	task.delay(AI.DoorLockedTime, function()
		if info.lockedUntil and os.clock() >= info.lockedUntil - 0.5 then Tac.unlockDoor(info) end
	end)
end

function Tac.unlockDoor(info)
	info.lockedUntil = nil
	local modifier = info.model:FindFirstChild("BotDoorPassThrough")
	if modifier then modifier.PassThrough = true end
end

--  Cada frame mientras pasa una puerta. true = esta quieto esperando.
function Tac.doorStep(state, now)
	local pass = state.doorPass
	if not pass then return false end
	local AI = Tac.AI
	local info = pass.info
	if not info.prompt.Parent or not info.model.Parent or now - pass.startAt > AI.DoorWaitMax * 3
		or (state.moveMode ~= "path" and state.moveMode ~= "direct") then
		state.doorPass = nil
		return false
	end
	local blocking = Tac.doorBlocking(state, info, pass.dir, pass.phase == "approach" and 3.5 or 4.5)

	if pass.phase == "approach" then
		--  Camina hasta tenerla cerca; si deja de estar en el camino, listo.
		if not blocking then
			if now - pass.startAt > 3 then state.doorPass = nil end
			return false
		end
		if Tac.doorIsOpen(info) then
			pass.phase = "side"
		else
			Tac.fireDoor(state, now, info)
			pass.phase, pass.firedAt, pass.tries = "wait", now, 1
			state.humanoid:MoveTo(state.root.Position)
			state.lastMoveTarget = nil
			return true
		end
	end

	if pass.phase == "wait" then
		if not blocking then
			--  Ya deja pasar: cruza derecho por el medio del marco (en diagonal se
			--  trababa con el marco) y despues sigue su camino.
			local points = Tac.doorThrough(state, info)
			if points then
				pass.phase, pass.sideAt, pass.around, pass.aroundStep = "side", now, points, 1
				state.detour = { pos = points[1], untilT = now + 1.2 }
				state.lastMoveTarget = nil
				return false
			end
			Tac.doorPassDone(state)
			return false
		end
		local waited = now - pass.firedAt
		if waited > 0.6 and Tac.doorIsOpen(info) then
			pass.phase = "side"		-- abierta, pero la hoja quedo en el medio
		elseif waited > AI.DoorWaitMax then
			if pass.tries < 2 then
				--  Quizas el primer intento no le llego: una vez mas.
				pass.tries += 1
				pass.firedAt = now
				Tac.fireDoor(state, now, info)
			else
				Tac.lockDoor(info, now)
				Tac.doorGiveUp(state, now, info)
				return false
			end
		end
		if pass.phase == "wait" then return true end
	end

	if pass.phase == "side" then
		if not state.detour and (not pass.around or pass.aroundStep >= #pass.around) and (not blocking or pass.around) then
			Tac.doorPassDone(state)
			return false
		end
		if not pass.sideAt then
			pass.sideAt = now
			--  Rodear la hoja por su punta libre (la otra esta pegada al marco):
			--  alejarse de la hoja, ir a lo largo de ella y pasar la punta.
			pass.around = blocking and Tac.doorGoAround(state, blocking.Instance, pass.dir)
			if pass.around then
				pass.aroundStep = 1
				state.detour = { pos = pass.around[1], untilT = now + 1.2 }
				state.lastMoveTarget = nil
			else
				pass.sideAt = now - 10		-- no hay por donde
			end
		end
		local around = pass.around
		if around and pass.aroundStep < #around
			and (not state.detour or flat(around[pass.aroundStep] - state.root.Position).Magnitude < 0.9) then
			pass.aroundStep += 1
			state.detour = { pos = around[pass.aroundStep], untilT = now + 1.4 }
			state.lastMoveTarget = nil
		end
		if now - pass.sideAt > 4 then
			if blocking then
				--  La hoja tapa todo el paso: se la trata como cerrada un rato.
				info.lockedUntil = now + 20
				local modifier = info.model:FindFirstChild("BotDoorPassThrough")
				if modifier then
					modifier.PassThrough = false
					task.delay(20, function() Tac.unlockDoor(info) end)
				end
				Tac.doorGiveUp(state, now, info)
			else
				Tac.doorPassDone(state)
			end
		end
		return false
	end
	return false
end

--  Puntos para rodear una hoja abierta que tapa el paso: separarse de la
--  hoja (con el ancho del cuerpo), ir a lo largo de ella y pasar su punta
--  libre (la que no toca el marco), la que queda hacia donde va.
function Tac.doorGoAround(state, leaf, dir)
	local cframe, size = leaf.CFrame, leaf.Size
	local axis, half = cframe.RightVector, size.X / 2
	if size.Z > size.X then axis, half = cframe.LookVector, size.Z / 2 end
	axis = flat(axis)
	if axis.Magnitude < 0.2 then return nil end
	axis = axis.Unit
	local normal = Vector3.new(-axis.Z, 0, axis.X)
	local root = state.root.Position
	local center = Vector3.new(cframe.Position.X, root.Y, cframe.Position.Z)
	local offset = (root - center):Dot(normal)
	local side = offset >= 0 and 1 or -1
	Tac.doorParams.FilterDescendantsInstances = { state.character, ACS_Workspace }
	local best = nil
	for _, sign in ipairs({ 1, -1 }) do
		local tip = center + axis * sign * half
		--  Libre de los dos lados de la hoja y por el medio: la punta de la
		--  bisagra tiene el marco del otro lado (mirando de un solo lado, a
		--  veces la "rodeaba" por la bisagra y salia por la puerta).
		local free = true
		for _, lateral in ipairs({ 1.4, 0, -1.4 }) do
			local from = tip - axis * sign * 0.3 + normal * side * lateral
			if workspace:Raycast(from, axis * sign * 2.2, Tac.doorParams) then
				free = false
				break
			end
		end
		if free then
			local score = (axis * sign):Dot(dir)
			if not best or score > best.score then best = { sign = sign, tip = tip, score = score } end
		end
	end
	if not best then return nil end
	local points = {}
	if math.abs(offset) < 1.6 then
		table.insert(points, root + normal * side * (1.6 - math.abs(offset)))
	end
	table.insert(points, best.tip + normal * side * 1.6)
	--  Pasando la punta, ya del otro lado de la hoja (hacia donde sigue).
	table.insert(points, best.tip + axis * best.sign * 2 - normal * side * 1.2)
	return points
end

--  Cruzar el marco derecho: delante del centro y despues del otro lado.
function Tac.doorThrough(state, info)
	local doorway = info.doorway
	if not doorway or doorway.normal.Magnitude < 0.5 then return nil end
	local root = state.root.Position
	local center = Vector3.new(doorway.center.X, root.Y, doorway.center.Z)
	if flat(root - center).Magnitude > 7 then return nil end
	local side = (root - center):Dot(doorway.normal) >= 0 and 1 or -1
	return { center + doorway.normal * side * 1.4, center - doorway.normal * side * 3.2 }
end

--  Termino de pasar una puerta (quizas rodeando la hoja): sigue su camino
--  desde el punto mas cercano que tiene por delante, no desde uno que quedo
--  atras (volvia hasta la puerta).
function Tac.doorPassDone(state)
	local pass = state.doorPass
	state.doorPass = nil
	state.lastMoveTarget = nil
	local waypoints = state.waypoints
	if state.moveMode ~= "path" or not waypoints then return end
	local here = state.root.Position
	if pass and pass.around then
		--  Rodeo la hoja: el navmesh no la ve (la puerta es PassThrough) y
		--  puede haber dejado puntos pegados a ella. Retoma en el mas lejano
		--  al que llega en linea recta.
		local feetY = here.Y - state.humanoid.HipHeight - state.root.Size.Y * 0.5
		local params = Tac.moveParams
		params.FilterDescendantsInstances = Tac.worldFilter()
		for i = math.min(#waypoints, state.wpIndex + 4), state.wpIndex, -1 do
			local target = waypoints[i].Position
			if math.abs(target.Y - feetY) < 2.5 and Tac.walkLineClear(here, feetY, target, params) then
				state.wpIndex = i
				return
			end
		end
	end
	local best, bestDist = state.wpIndex, math.huge
	for i = state.wpIndex, math.min(#waypoints, state.wpIndex + 6) do
		local dist = (waypoints[i].Position + Vector3.new(0, 3, 0) - here).Magnitude
		if dist < bestDist then best, bestDist = i, dist end
	end
	--  Ese punto se da por pasado solo si esta encima o si ya lo dejo atras.
	if best < #waypoints then
		local point = waypoints[best].Position
		local along = flat(waypoints[best + 1].Position - point)
		if bestDist < 4.8 and (flat(here - point).Magnitude < 1.8
			or (along.Magnitude > 0.1 and flat(here - point):Dot(along.Unit) > 0.5)) then
			best += 1
		end
	end
	state.wpIndex = best
end

--  Atorado: si hay una puerta cerrada a unos pasos, va a pasarla.
function Tac.tryNearbyDoor(state, now)
	if state.doorPass then return true end
	local best, bestDist = nil, 9
	for _, info in ipairs(Tac.doorList) do
		local anchor = Tac.doorAnchor(info)
		if anchor then
			local dist = (anchor - state.root.Position).Magnitude
			if dist < bestDist and not Tac.doorIsOpen(info) then best, bestDist = info, dist end
		end
	end
	if not best then return false end
	local dir = flat(Tac.doorAnchor(best) - state.root.Position)
	if dir.Magnitude < 0.2 then return false end
	Tac.startDoorPass(state, now, best, dir.Unit)
	return state.doorPass ~= nil
end

--  Las puertas se registran solas cuando su script crea el BotTrigger.
workspace.DescendantAdded:Connect(function(instance)
	if instance.Name == "BotTrigger" and instance:IsA("BindableEvent") then
		task.defer(Tac.registerDoor, instance)
	end
end)
task.delay(2, function()
	for _, instance in ipairs(workspace:GetDescendants()) do
		if instance.Name == "BotTrigger" and instance:IsA("BindableEvent") then
			Tac.registerDoor(instance)
		end
	end
	dprint(#Tac.doorList .. " puertas registradas")
end)

-- --------------------------------------------------------------------------
--  MEMORIA DEL MAPA [IA v3] (26/09)
--
--  Lugares a los que no se puede llegar: ningun camino llega, se atasco
--  dos veces yendo, una puerta que no abre en el medio. La comparten TODOS
--  los bots: lo que aprende uno lo saben los demas y nadie vuelve a
--  intentarlo (ni a gastar calculos de camino). Hacen falta dos fallas para
--  darlo por inalcanzable (una sola puede ser mala suerte); se olvida a los
--  MemoryTime s y, si vuelve a fallar, se recuerda el doble (hasta
--  MemoryMax). Llegar a un lugar lo borra. Se reinicia en cada fase.
-- --------------------------------------------------------------------------
Tac.navMemory = {}		-- [celda de 6 studs (Tac.memoryKey)] = { pos, fails, level, untilT, partialUntil }

function Tac.memoryKey(x, y, z)
	return ((x + 20000) * 40000 + (z + 20000)) * 1000 + (y + 500)		-- numero: sin armar textos
end

function Tac.markUnreachable(pos, weight, why, maxTime)
	if not pos then return end
	local AI = Tac.AI
	local now = os.clock()
	local key = Tac.memoryKey(math.floor(pos.X / 6), math.floor(pos.Y / 6), math.floor(pos.Z / 6))
	local entry = Tac.navMemory[key]
	if not entry then
		entry = { pos = pos, fails = 0, level = 0, untilT = 0, partialUntil = 0 }
		Tac.navMemory[key] = entry
	end
	if now > entry.partialUntil then entry.fails = 0 end
	entry.fails += weight or 1
	entry.partialUntil = now + AI.MemoryTime
	if entry.fails >= 2 then
		entry.fails = 0
		entry.pos = pos
		entry.untilT = now + math.min(AI.MemoryTime * 2 ^ entry.level, AI.MemoryMax, maxTime or math.huge)
		entry.level = math.min(entry.level + 1, 5)
		dprint(string.format("memoria: no se llega a (%.0f, %.0f, %.0f) [%s]", pos.X, pos.Y, pos.Z, why or "?"))
	end
end

function Tac.isUnreachable(pos, radius)
	if not pos or next(Tac.navMemory) == nil then return false end
	local now = os.clock()
	local range = radius or 5
	local cx, cy, cz = math.floor(pos.X / 6), math.floor(pos.Y / 6), math.floor(pos.Z / 6)
	for dx = -1, 1 do
		for dy = -1, 1 do
			for dz = -1, 1 do
				local entry = Tac.navMemory[Tac.memoryKey(cx + dx, cy + dy, cz + dz)]
				if entry and now < entry.untilT and flat(entry.pos - pos).Magnitude < range
					and math.abs(entry.pos.Y - pos.Y) < 6 then
					return true
				end
			end
		end
	end
	return false
end

--  Alguien llego: ese lugar se puede alcanzar.
function Tac.markReached(pos)
	if not pos or next(Tac.navMemory) == nil then return end
	local cx, cy, cz = math.floor(pos.X / 6), math.floor(pos.Y / 6), math.floor(pos.Z / 6)
	for dx = -1, 1 do
		for dy = -1, 1 do
			for dz = -1, 1 do
				local key = Tac.memoryKey(cx + dx, cy + dy, cz + dz)
				local entry = Tac.navMemory[key]
				if entry and (entry.pos - pos).Magnitude < 5 then Tac.navMemory[key] = nil end
			end
		end
	end
end

--  Cada segundo (Heartbeat): mapa nuevo, memoria nueva.
function Tac.memoryTick(now)
	if now < (Tac.nextMemoryTick or 0) then return end
	Tac.nextMemoryTick = now + 1
	local phase = currentPhase()
	if phase ~= Tac.memoryPhase then
		Tac.memoryPhase = phase
		Tac.navMemory = {}
		for _, info in ipairs(Tac.doorList) do
			if info.lockedUntil then Tac.unlockDoor(info) end
		end
	end
end

--  Un camino no salio con ningun agente. Si el destino esta mas alto y hay
--  un borde que se pueda trepar, arma el plan para subir por ahi; si no, lo
--  anota en la memoria (solo si el bot esta en un lugar normal: si ninguno
--  de sus caminos sale, el problema es donde esta el, no el destino).
function Tac.onPathFailed(state, goal, target, startPos, trusted)
	local now = os.clock()
	if state.climbPlan and target ~= goal then
		--  Ni siquiera hay camino hasta el pie del borde.
		state.climbPlan = nil
		Tac.markUnreachable(goal, 1, "sin camino al borde")
		return
	end
	if goal.Y - startPos.Y > 2.5 then
		local plan = Tac.planClimb(state, goal)
		if plan then
			state.climbPlan = plan
			state.lastRepath = now - 1		-- el proximo goTo ya va hacia el borde
			dprint(state.bot.Name, string.format("sin camino para subir: trepara un borde de %.1f", plan.ledge))
			return
		end
	end
	if trusted and now - (state.lastPathOkAt or -100) < 40 then
		--  Con una puerta trabada en el mapa, quizas sea por ella: se recuerda
		--  solo hasta que la puerta vuelva a probarse.
		local doorsBack = nil
		for _, info in ipairs(Tac.doorList) do
			if info.lockedUntil and info.lockedUntil > now then doorsBack = math.max(doorsBack or 0, info.lockedUntil - now) end
		end
		Tac.markUnreachable(goal, 1, doorsBack and "sin camino (puerta trabada)" or "sin camino", doorsBack)
	end
end

-- --------------------------------------------------------------------------
--  SUBIR A LUGARES ALTOS [IA v3] (26/09)
--
--  El navmesh no conoce el trepar (MantleMaxHeight). Si no hay camino a un
--  lugar alto (techo bajo, contenedor, muro, balcon), se busca alrededor del
--  destino un borde que no pase de esa altura, se va por camino al pie del
--  borde y desde ahi se trepa.
-- --------------------------------------------------------------------------
function Tac.planClimb(state, goal)
	local AI = Tac.AI
	if AI.MantleMaxHeight <= 0 then return nil end
	local now = os.clock()
	if state.noClimbFor and now < (state.noClimbUntil or 0) and (goal - state.noClimbFor).Magnitude < 8 then return nil end
	local params = Tac.moveParams
	params.FilterDescendantsInstances = Tac.worldFilter()
	local surface = workspace:Raycast(goal + Vector3.new(0, 3, 0), Vector3.new(0, -8, 0), params)
	if not surface or surface.Normal.Y < 0.7 then return nil end
	local topY = surface.Position.Y
	local top = Vector3.new(goal.X, topY, goal.Z)
	local origin = state.root.Position
	local best, bestScore = nil, nil
	for i = 0, 15 do
		local angle = i * math.pi / 8
		local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
		--  Desde el destino hacia afuera hasta que se acaba el piso (el borde).
		local edge = nil
		for distance = 1.5, AI.ClimbSearch, 1.5 do
			if workspace:Raycast(top + dir * (distance - 1.5) + Vector3.new(0, 2.5, 0), dir * 1.5, params) then break end
			if not workspace:Raycast(top + dir * distance + Vector3.new(0, 1, 0), Vector3.new(0, -1.6, 0), params) then
				edge = distance
				break
			end
		end
		if edge then
			local outside = top + dir * (edge + 1.8)
			local below = workspace:Raycast(outside + Vector3.new(0, 0.5, 0), Vector3.new(0, -(AI.MantleMaxHeight + 3), 0), params)
			if below and below.Normal.Y > 0.7 then
				local ledge = topY - below.Position.Y
				local base = below.Position + dir * 0.6
				local lip = top + dir * math.max(edge - 1.2, 0.5)
				local roomBelow = not workspace:Raycast(below.Position + Vector3.new(0, 0.2, 0), Vector3.new(0, 5, 0), params)
				local roomAbove = not workspace:Raycast(lip + Vector3.new(0, 0.2, 0), Vector3.new(0, 5, 0), params)
				if ledge > 1.2 and ledge <= AI.MantleMaxHeight - 0.2 and roomBelow and roomAbove
					and not Tac.isUnreachable(base) and not Tac.nearBlocked(state, base) then
					local score = ledge * 2 + (base - origin).Magnitude * 0.05
					if not bestScore or score < bestScore then
						best = { base = base, lip = lip, topY = topY, top = goal, ledge = ledge }
						bestScore = score
					end
				end
			end
		end
	end
	if best then best.untilT = now + 25 end
	return best
end

--  Al pie del borde: derecho hacia el; el parkour trepa.
function Tac.startClimb(state, now, plan)
	state.climbing = { untilT = now + 5 }
	state.waypoints = nil
	state.detour = nil
	state.moveMode = "direct"
	state.directGoal = plan.lip
	state.directUntil = now + 5
	state.lastMoveTarget = nil
	state.nextMantleAt, state.nextJumpAt = 0, 0
	state.humanoid:MoveTo(plan.lip)
	state.lastMoveToAt = now
	dprint(state.bot.Name, string.format("trepa para llegar arriba (borde de %.1f)", plan.ledge))
end

--  Desde requestPath: a donde calcular el camino. nil = no calcular
--  (esta trepando o acaba de empezar a trepar).
function Tac.climbTarget(state, now, goal)
	if state.climbing then
		if now < state.climbing.untilT and state.moveMode == "direct" and state.directGoal then return nil end
		state.climbing = nil
	end
	local plan = state.climbPlan
	if not plan then return goal end
	local root = state.root.Position
	local feetY = root.Y - state.humanoid.HipHeight - state.root.Size.Y * 0.5
	if now > plan.untilT or (goal - plan.top).Magnitude > 6 or feetY > plan.topY - 1 then
		--  Otro destino, se vencio, o ya esta arriba: el plan termino.
		state.climbPlan = nil
		return goal
	end
	if flat(plan.base - root).Magnitude < 3 and math.abs(feetY - plan.base.Y) < 2.5 then
		Tac.startClimb(state, now, plan)
		return nil
	end
	return plan.base
end

-- --------------------------------------------------------------------------
--  POSICIONES [IA v3] (26/09): segundos pisos, ventanas, colinas, techos
--
--  En vez de mirar solo el piso a su altura, cada punto de busqueda revisa
--  TODOS los pisos de esa columna (suelo, segundo piso, azotea) y los
--  califica contra la amenaza:
--    · de pie la ve (puede disparar desde ahi);
--    · agachado queda tapado por algo pegado (alfeizar, muro bajo, la cresta
--      de una colina): un lugar para asomarse;
--    · altura sobre la amenaza, techo encima (no lo ven desde arriba),
--      paredes a los costados (sin ser un placard), distancia buena para su
--      arma, que no haya un companero ya ahi, y lo que tarda en llegar.
--  Los inalcanzables (memoria del mapa) ni se miran.
-- --------------------------------------------------------------------------
--  Pisos parados en la columna (x, z) entre topY y bottomY: uno debajo del
--  otro. Un rayo que empieza dentro de una pieza no la ve, asi que se
--  descartan los "pisos" que quedan dentro de algo solido.
function Tac.scanFloors(x, z, topY, bottomY, out)
	local y = topY
	for _ = 1, 4 do
		local hit = workspace:Raycast(Vector3.new(x, y, z), Vector3.new(0, bottomY - y, 0), Tac.params)
		if not hit then return end
		local pos = hit.Position
		if hit.Normal.Y > 0.7 and not isSeeThrough(hit.Instance) then
			local roomy = not workspace:Raycast(pos + Vector3.new(0, 0.2, 0), Vector3.new(0, 5, 0), Tac.params)
			if roomy and #workspace:GetPartBoundsInRadius(pos + Vector3.new(0, 1.6, 0), 1.25, Tac.overlap) == 0 then
				table.insert(out, pos)
			end
		end
		if hit.Instance == workspace.Terrain then return end
		y = pos.Y - 0.1
		if y <= bottomY then return end
	end
end

--  Arma principal: distancias buenas (con el multiplicador del tipo de IA).
function Tac.weaponRanges(state)
	local primary = state.weapons[(state.meta.loadout or Config.Loadout)[1]] or state.weapons[state.current]
	local cfg = primary and primary.info.cfg
	if not cfg then return 10, 80, 300 end
	local mult = (state.meta.role and state.meta.role.RangeMult) or 1
	return cfg.IdealMin * mult, cfg.IdealMax * mult, cfg.MaxRange
end

--  Llego a su puesto: cerca, o el camino ya termino y quedo a un par de pasos
--  (un puesto pegado a algo puede quedar un poco fuera del navmesh y el
--  camino no llega justo encima: antes iba y venia sin "llegar" nunca).
function Tac.atPost(state, pos, radius)
	local dist = flat(pos - state.root.Position).Magnitude
	if dist <= radius then
		state.finalStep = nil
		return true
	end
	local now = os.clock()
	local step = state.finalStep
	--  Uno de otro puesto o que ya vencio no cuenta (si quedaba, el que llama
	--  no volvia a pedir camino nunca).
	if step and ((step.pos - pos).Magnitude >= 0.5 or now > step.untilT + 1) then
		state.finalStep = nil
		step = nil
	end
	if step then
		--  Ultimo tramo derecho: si ni asi, se queda donde llego.
		if now > step.untilT then
			state.finalStep = nil
			return true
		end
		return false
	end
	if dist <= radius + 4.5 and state.moveMode == "hold" and not state.pathBusy and now - (state.arrivedAt or -100) < 1.5 then
		--  El camino termino a un par de pasos: el ultimo tramo, derecho.
		state.finalStep = { pos = pos, untilT = now + 2 }
		state.moveMode = "direct"
		state.directGoal = pos
		state.directUntil = now + 2
		--  Como desvio: camina hasta el punto exacto (el "direct" se da por
		--  llegado a 2.5 studs, y en una ventana eso ya es no ver por ella).
		state.detour = { pos = pos, untilT = now + 1.6 }
		state.lastMoveTarget = nil
		state.humanoid:MoveTo(pos)
		state.lastMoveToAt = now
		return false
	end
	return false
end

--  Por donde deberia venir el enemigo: lo que oyo, lo que le avisaron, el
--  ultimo que vio, el tiroteo que se oye, o por donde anda la gente.
function Tac.threatGuess(state, now)
	if state.noise and now - state.noise.at < 8 then return state.noise.pos end
	local intel = Tac.intel(state, now)
	if intel then return intel.pos end
	if state.lastSeenPos and now - state.lastSeenAt < 15 then return state.lastSeenPos end
	local hot = Tac.pickHotspot(state, now)
	if hot then return hot.pos end
	return Tac.enemyCenter(state)
end

--  Otro bot ya tomo un puesto ahi (no se amontonan).
Tac.POST_KEYS = { "hold", "perch", "watch", "peek", "ambush" }
function Tac.spotTaken(state, spot)
	for _, other in pairs(brains) do
		if other ~= state and not other.dead then
			for _, key in ipairs(Tac.POST_KEYS) do
				local post = other[key]
				if post and post.pos and (post.pos - spot).Magnitude < 7 then return true end
			end
		end
	end
	return false
end

--  Puntaje de un lugar (nil = no sirve). ctx.threat es un punto a la altura
--  del cuerpo del enemigo (raiz / de donde vino el tiro).
function Tac.rateSpot(state, spot, ctx)
	local params = Tac.params
	local height = spot.Y - (ctx.threat.Y - 3)
	if ctx.minHeight and height < ctx.minHeight then return nil end
	local aim = ctx.threat + Vector3.new(0, 0.5, 0)
	local standEye = spot + Vector3.new(0, 4.4, 0)		-- un poco bajo: con margen sobre un alfeizar
	local toThreat = aim - standEye
	local dist = toThreat.Magnitude
	if ctx.maxRange and dist > ctx.maxRange then return nil end
	if dist < (ctx.minThreatDist or 8) then return nil end		-- no encima de la amenaza
	local hit = workspace:Raycast(standEye, toThreat, params)
	local sees = not hit or (hit.Position - standEye).Magnitude > dist * 0.92 or isSeeThrough(hit.Instance)
	if ctx.needView and not sees then return nil end
	local score = sees and 30 or 0
	--  Agachado (la cabeza baja ~1.9): tapado por algo a pocos pasos.
	local crouchEye = spot + Vector3.new(0, 2.6, 0)
	local low = workspace:Raycast(crouchEye, aim - crouchEye, params)
	local coverDist = low and (low.Position - crouchEye).Magnitude or math.huge
	local peek = coverDist < 7 and not isSeeThrough(low.Instance)
	--  Pegado a la cobertura tapa mas angulo que a varios pasos de ella.
	if peek then score += (ctx.peekWeight or 22) * (1.15 - coverDist / 14) end
	score += math.clamp(height, -12, 30) * (ctx.heightWeight or 0.8)
	if ctx.idealMin and dist < ctx.idealMin then score -= 15 end
	if ctx.idealMax and dist > ctx.idealMax * 1.3 then score -= (dist - ctx.idealMax * 1.3) * 0.3 end
	score -= (spot - state.root.Position).Magnitude * (ctx.travelWeight or 0.12)
	if Tac.spotTaken(state, spot) then score -= 25 end
	return score, sees, peek
end

--  Lo caro del puntaje (solo para los mejores de la lista): techo encima (no
--  lo ven desde arriba) y paredes a los costados (sin ser un placard).
function Tac.rateSpotExtras(spot, ctx)
	local params = Tac.params
	local score = 0
	if workspace:Raycast(spot + Vector3.new(0, 5.2, 0), Vector3.new(0, 30, 0), params) then score += ctx.roofWeight or 6 end
	local walls = 0
	for k = 0, 5 do
		local angle = k * math.pi / 3
		if workspace:Raycast(spot + Vector3.new(0, 3, 0), Vector3.new(math.cos(angle), 0, math.sin(angle)) * 5, params) then
			walls += 1
		end
	end
	return score + (walls >= 6 and -15 or walls * 3)
end

--  Lugares alrededor de ctx.center (entre minRadius y maxRadius), mejores
--  primero: { pos, score, sees, peek }.
function Tac.findPositions(state, ctx)
	local origin = state.root.Position
	local center = ctx.center or origin
	local rng = state.rng
	local filter = Tac.worldFilter()
	Tac.params.FilterDescendantsInstances = filter
	Tac.overlap.FilterDescendantsInstances = filter
	local top = math.max(origin.Y, center.Y) + (ctx.up or 30)
	local bottom = math.min(origin.Y, center.Y) - (ctx.down or 25)
	local floors, list = {}, {}
	local interiors = {}		-- pisos bajo techo desde donde no se ve (ver abajo)
	local function consider(spots)
		for _, spot in ipairs(spots) do
			if flat(spot - center).Magnitude <= (ctx.maxRadius or 40) + 4 and not Tac.isUnreachable(spot)
				and not Tac.nearBlocked(state, spot) and Tac.climateOk(spot) then
				local score, sees, peek = Tac.rateSpot(state, spot, ctx)
				if score then
					table.insert(list, { pos = spot, score = score, sees = sees, peek = peek, face = ctx.threat })
				elseif ctx.threat and #interiors < 4
					and workspace:Raycast(spot + Vector3.new(0, 5.2, 0), Vector3.new(0, 12, 0), Tac.params) then
					table.insert(interiors, spot)
				end
			end
		end
	end
	for _ = 1, ctx.samples or 24 do
		local angle = rng:NextNumber(0, math.pi * 2)
		local radius = rng:NextNumber(ctx.minRadius or 4, ctx.maxRadius or 40)
		table.clear(floors)
		Tac.scanFloors(center.X + math.cos(angle) * radius, center.Z + math.sin(angle) * radius, top, bottom, floors)
		consider(floors)
	end
	--  Rayos DESDE la amenaza hacia la zona: si uno entra por una ventana y
	--  pega adentro (o pega en la ladera de una colina), ese lugar la ve por
	--  construccion. Al azar casi nunca se cae justo detras de una ventana.
	local threat = ctx.threat
	if threat and (ctx.sightRays or 20) > 0 then
		local eye = threat + Vector3.new(0, 1.5, 0)
		local toCenter = flat(center - eye)
		local baseYaw = toCenter.Magnitude > 1 and math.atan2(toCenter.Z, toCenter.X) or rng:NextNumber(0, math.pi * 2)
		local spread = toCenter.Magnitude > 1 and math.clamp(math.atan2(ctx.maxRadius or 40, toCenter.Magnitude), 0.3, math.pi) or math.pi
		local reach = toCenter.Magnitude + (ctx.maxRadius or 40)
		local across = math.max(toCenter.Magnitude, 12)
		for _ = 1, ctx.sightRays or 20 do
			local yaw = baseYaw + rng:NextNumber(-spread, spread)
			--  Apuntando a alturas de 0 a 14 studs (planta baja, primer piso,
			--  segundo piso) a la distancia de la zona.
			local pitch = math.atan2(rng:NextNumber(-2, 14), across)
			local dir = Vector3.new(math.cos(yaw) * math.cos(pitch), math.sin(pitch), math.sin(yaw) * math.cos(pitch))
			local hit = workspace:Raycast(eye, dir * reach, Tac.params)
			if hit then
				--  Justo antes de lo que toco y unos pasos mas atras: si el rayo
				--  entro por una ventana, pega al fondo del cuarto (desde donde el
				--  alfeizar tapa); pegado a la ventana si se ve.
				local travelled = (hit.Position - eye).Magnitude
				for _, back in ipairs({ 1.8, 6 }) do
					if back < travelled - 2 then
						local point = hit.Position - dir * back
						table.clear(floors)
						Tac.scanFloors(point.X, point.Z, point.Y + 2, point.Y - 10, floors)
						consider(floors)
					end
				end
			end
		end
	end
	--  Cobertura delante: rayos desde el lugar hacia la amenaza a la altura de
	--  alguien agachado; lo que tocan (un muro bajo, un auto, una cresta) tapa,
	--  y el lugar justo detras es para asomarse.
	if threat and ctx.coverRays then
		local root = state.root.Position
		local from = Vector3.new(center.X, root.Y - 3 + 2.2, center.Z)
		local toward = flat(threat - from)
		if toward.Magnitude > 4 then
			local baseYaw = math.atan2(toward.Z, toward.X)
			for i = 1, ctx.coverRays do
				local yaw = baseYaw + (i - (ctx.coverRays + 1) / 2) * (1.6 / ctx.coverRays)
				local dir = Vector3.new(math.cos(yaw), 0, math.sin(yaw))
				local hit = workspace:Raycast(from, dir * (ctx.maxRadius or 22), Tac.params)
				if hit and hit.Normal.Y < 0.5 and not isSeeThrough(hit.Instance) then
					for _, back in ipairs({ 1.3, 2.6 }) do
						local point = hit.Position - dir * back
						table.clear(floors)
						Tac.scanFloors(point.X, point.Z, point.Y + 3, point.Y - 6, floors)
						consider(floors)
					end
				end
			end
		end
	end
	--  Adentro de un edificio y sin ver nada: como una persona, a la pared que
	--  da hacia la amenaza y a lo largo de ella, buscando una ventana.
	if threat then
		local checked = interiors
		interiors = { true, true, true, true }		-- no juntar mas mientras tanto
		for _, spot in ipairs(checked) do
			local toThreat = flat(threat - spot)
			if toThreat.Magnitude > 4 then
				local dir = toThreat.Unit
				local wall = workspace:Raycast(spot + Vector3.new(0, 3, 0), dir * 40, Tac.params)
				if wall and math.abs(wall.Normal.Y) < 0.3 then
					local base = wall.Position - dir * 1.4
					local perp = Vector3.new(-dir.Z, 0, dir.X)
					for _, slide in ipairs({ 0, 2.5, -2.5, 5, -5, 7.5, -7.5 }) do
						local point = base + perp * slide
						table.clear(floors)
						Tac.scanFloors(point.X, point.Z, spot.Y + 2, spot.Y - 1, floors)
						consider(floors)
					end
				end
			end
		end
	end
	table.sort(list, function(a, b) return a.score > b.score end)
	--  Techo y paredes solo para los mejores (son 7 rayos por lugar).
	local refine = math.min(#list, 8)
	for i = 1, refine do
		list[i].score += Tac.rateSpotExtras(list[i].pos, ctx)
	end
	if refine > 1 then
		local top = table.move(list, 1, refine, 1, {})
		table.sort(top, function(a, b) return a.score > b.score end)
		table.move(top, 1, refine, 1, list)
	end
	return list
end

--  En segundo plano: el primero de la lista al que hay camino COMPLETO (un
--  techo por fuera o un balcon sin escalera no pasan). Los que no, a la
--  memoria. Cada calculo paga del presupuesto global.
function Tac.validateSpots(state, list, maxChecks, onFound)
	if state.spotChecking then return end
	state.spotChecking = true
	task.spawn(function()
		--  Agente angosto y con saltos: el mas permisivo (escaleras angostas).
		state.pathProbe = state.pathProbe or PathfindingService:CreatePath(Tac.tightAgent)
		local path = state.pathProbe
		for index = 1, math.min(#list, maxChecks) do
			if not isAlive(state) then break end
			local waited = 0
			while not Tac.takePathToken("perch") and waited < 5 do
				waited += task.wait(0.25)
			end
			if not isAlive(state) then break end
			local candidate = list[index]
			local ok = pcall(function() path:ComputeAsync(state.root.Position, candidate.pos) end)
			if ok and path.Status == Enum.PathStatus.Success then
				local waypoints = path:GetWaypoints()
				local last = waypoints[#waypoints]
				if last and flat(last.Position - candidate.pos).Magnitude < 4 and math.abs(last.Position.Y - candidate.pos.Y) < 3 then
					onFound(candidate)
					break
				end
			end
			Tac.markUnreachable(candidate.pos, 1, "sin camino al puesto")
		end
		state.spotChecking = false
	end)
end

--  Desde lejos, hacia un tiroteo: un lugar desde donde se lo ve (alto, con
--  cobertura) en vez de meterse en el medio.
function Tac.findOverwatch(state, spot)
	local idealMin, idealMax, maxRange = Tac.weaponRanges(state)
	local list = Tac.findPositions(state, { threat = spot, center = spot, minRadius = 20, maxRadius = math.max(30, math.min(60, maxRange * 0.8)),
		needView = true, samples = 16, heightWeight = 1, travelWeight = 0.04,
		idealMin = idealMin, idealMax = idealMax, maxRange = maxRange })
	return list[1] and list[1].pos or nil
end

--  Camper: un punto alto con vista, mirando todos los pisos (una ventana
--  del segundo piso, una azotea con escalera, la cima de una colina).
function Tac.findPerchV3(state)
	if not Tac.AI.SmartPositions then return {} end
	local role = state.meta.role
	local threat = Tac.threatGuess(state, os.clock())
	if not threat then return {} end
	local idealMin, idealMax, maxRange = Tac.weaponRanges(state)
	local list = Tac.findPositions(state, { threat = threat, center = state.root.Position, minRadius = 8,
		maxRadius = role.PerchSearch or 110, samples = 30, up = 45, down = 20, needView = true,
		minHeight = role.MinHeight or 6, heightWeight = 1.5, peekWeight = 25, travelWeight = 0.08,
		idealMin = idealMin, idealMax = idealMax, maxRange = maxRange })
	local out = {}
	for _, candidate in ipairs(list) do
		if not Tac.isBadPerch(state, candidate.pos)
			and not (state.lastPerch and (state.lastPerch - candidate.pos).Magnitude < 12) then
			table.insert(out, { pos = candidate.pos, face = threat, score = candidate.score, peek = candidate.peek })
		end
	end
	return out
end

-- --------------------------------------------------------------------------
--  ASOMARSE [IA v3] (26/09): pelea a distancia desde un lugar con cobertura
--
--  Peleando a media / larga distancia al descubierto, busca cerca un lugar
--  donde de pie ve al enemigo y agachado queda tapado (una ventana, un muro
--  bajo, la cresta de una colina). Ahi se asoma a disparar y se agacha a
--  ratos, para recargar y cuando le pegan. Se va si se le acercan, si lo
--  flanquean (le pegan agachado) o si pierde al enemigo.
-- --------------------------------------------------------------------------
function Tac.considerPeek(state, now, target, dist)
	local AI = Tac.AI
	if AI.PeekChance <= 0 or state.peek or state.cover or now < (state.nextPeekTry or 0) then return false end
	if Tac.controlZone() then return false end		-- [26/09] en Control se pelea en el area
	local role = state.meta.role
	local kind = role and role.Kind
	if kind == "Corredora" or kind == "Sigiloso" then return false end
	local _, _, maxRange = Tac.weaponRanges(state)
	if dist < AI.PeekMinDistance or dist > maxRange then return false end
	state.nextPeekTry = now + state.rng:NextNumber(4, 7)
	local recentlyHit = state.lastDamageAt ~= nil and now - state.lastDamageAt < 3
	if not recentlyHit and state.rng:NextNumber() > AI.PeekChance then return false end
	local threat = target.root.Position
	local list = Tac.findPositions(state, { threat = threat, center = state.root.Position, minRadius = 0, maxRadius = AI.PeekRange,
		needView = true, samples = 14, up = 12, down = 12, heightWeight = 0.4, peekWeight = 40, roofWeight = 3,
		travelWeight = 0.7, maxRange = maxRange, coverRays = 12, sightRays = 12 })
	local best = nil
	for _, candidate in ipairs(list) do
		if candidate.peek then
			best = candidate
			break
		end
	end
	if not best then return false end
	state.peek = { pos = best.pos, threat = threat, arrived = false, untilT = now + state.rng:NextNumber(14, 24),
		phase = "up", phaseUntil = 0, peek = true }
	dprint(state.bot.Name, "va a un lugar para asomarse a pelear")
	return true
end

--  true si asomarse se hizo cargo del movimiento en esta vuelta.
function Tac.updatePeek(state, now)
	local peek = state.peek
	if not peek then return false end
	local target = state.target
	local hitRecently = state.lastDamageAt ~= nil and now - state.lastDamageAt < 1.2
	local enemyClose = target ~= nil and state.visible and (target.root.Position - state.root.Position).Magnitude < 12
	local flanked = peek.arrived and peek.phase == "down" and hitRecently
	if state.cover or now > peek.untilT or enemyClose or flanked or now - state.lastSeenAt > 7 then
		state.peek = nil
		state.nextPeekTry = now + (flanked and 6 or 3)
		return false
	end
	if state.visible and target then peek.threat = target.root.Position end
	local dist = flat(peek.pos - state.root.Position).Magnitude
	if not peek.arrived then
		if not Tac.atPost(state, peek.pos, 1.6) then
			if not state.finalStep then Tac.goTo(state, now, peek.pos, "cover", RUN_SPEED, 2) end
			if state.pathFails >= 2 then
				state.peek = nil
				state.pathFails = 0
				state.nextPeekTry = now + 5
				return false
			end
			return true
		end
		peek.arrived = true
		peek.phase, peek.phaseUntil = "up", now + state.rng:NextNumber(1.5, 3)
	elseif dist > 5 then
		peek.arrived = false
		return true
	end
	if state.moveMode ~= "hold" then stopWalking(state) end
	--  Arriba un rato (dispara), abajo otro (se tapa).
	if now >= peek.phaseUntil then
		if peek.phase == "up" then
			peek.phase, peek.phaseUntil = "down", now + state.rng:NextNumber(0.7, 1.5)
		else
			peek.phase, peek.phaseUntil = "up", now + state.rng:NextNumber(1.6, 3.2)
		end
	end
	if not state.visible then
		state.lookAt = peek.threat
		state.lookUntil = now + 0.4
	end
	return true
end

--  En un puesto (defensiva, estratega, camper, asomarse): agachado o no.
--  Un puesto "para asomarse" solo se agacha para recargar o si le pegan
--  (agachado no ve nada); los demas, agachados siempre.
function Tac.postCrouch(state, post, now)
	if not post.peek then return true end
	if post == state.peek and post.phase == "down" then return true end
	return state.reload ~= nil or (state.lastDamageAt ~= nil and now - state.lastDamageAt < 1.2)
end

-- --------------------------------------------------------------------------
--  ESPERAR ABAJO [IA v3] (26/09)
--
--  El que se perdio de vista esta donde no se puede llegar (un techo, una
--  torre, un balcon sin escalera): en vez de ir y rendirse, se pone donde se
--  ve ese lugar y lo espera un rato, por si se asoma o baja.
-- --------------------------------------------------------------------------
function Tac.startAmbush(state, now, spot)
	if now < (state.nextAmbushAt or 0) then return false end
	state.nextAmbushAt = now + 20
	local list = Tac.findPositions(state, { threat = spot, center = state.root.Position, minRadius = 3, maxRadius = 30,
		needView = true, samples = 16, heightWeight = 0.3, peekWeight = 15 })
	local best = list[1]
	if not best then return false end
	state.ambush = { pos = best.pos, look = spot, untilT = now + state.rng:NextNumber(8, 15), peek = best.peek, arrived = false }
	dprint(state.bot.Name, "no puede llegar hasta ahi: lo espera donde lo ve")
	return true
end

-- --------------------------------------------------------------------------
--  CONTROL [26/09]: jugar el punto (AreaObjetivo)
--
--  Mientras se juega Control, el RoundManager publica la pieza del area en
--  State.ControlArea. Fuera de pelea los bots van al area y se quedan
--  adentro, repartidos y mirando hacia donde puede venir el enemigo.
--  Peleando: adentro no salen a perseguir (se mueven de lado sin salir);
--  de afuera van hacia el area disparando. Sumar puntos es estar ahi.
-- --------------------------------------------------------------------------
function Tac.controlZone()
	local now = os.clock()
	if Tac.zoneAt and now - Tac.zoneAt < 0.5 then return Tac.zone end
	Tac.zoneAt = now
	local value = roundState:FindFirstChild("ControlArea")
	local part = value and value:IsA("ObjectValue") and value.Value
	if part and part.Parent and part:IsA("BasePart") and roundState:GetAttribute("ActiveGamemode") == "Control" then
		Tac.zone = part
	else
		Tac.zone = nil
	end
	return Tac.zone
end

--  Ejes de la pieza: el que apunta hacia arriba y los dos de la huella.
function Tac.zoneAxes(zone)
	local cframe = zone.CFrame
	local x, y, z = math.abs(cframe.RightVector.Y), math.abs(cframe.UpVector.Y), math.abs(cframe.LookVector.Y)
	local up = (x >= y and x >= z) and 1 or (y >= z and 2 or 3)
	local round = zone:IsA("Part") and (zone.Shape == Enum.PartType.Ball or (zone.Shape == Enum.PartType.Cylinder and up == 1))
	return up, up == 1 and 2 or 1, up == 3 and 2 or 3, round
end

--  La raiz de un personaje dentro del area (mismo criterio que el
--  RoundManager); margin = cuanto mas adentro de los bordes.
function Tac.inZone(zone, position, margin)
	local cframe, half = zone.CFrame, zone.Size / 2
	local up, a, b, round = Tac.zoneAxes(zone)
	local relative = cframe:PointToObjectSpace(position)
	local coords = { relative.X, relative.Y, relative.Z }
	local halves = { half.X, half.Y, half.Z }
	local dy = position.Y - cframe.Position.Y
	if dy < -halves[up] - 1 or dy > halves[up] + 8 then return false end
	local ha, hb = math.max(halves[a] - (margin or 0), 0.3), math.max(halves[b] - (margin or 0), 0.3)
	if round then
		local radius = math.min(ha, hb)
		return coords[a] * coords[a] + coords[b] * coords[b] <= radius * radius
	end
	return math.abs(coords[a]) <= ha and math.abs(coords[b]) <= hb
end

--  Un lugar al azar dentro del area, sobre el piso (cada bot el suyo:
--  repartidos no se amontonan en el centro).
function Tac.zoneSpot(state, zone)
	local cframe, half = zone.CFrame, zone.Size / 2
	local up, a, b, round = Tac.zoneAxes(zone)
	local halves = { half.X, half.Y, half.Z }
	local params = Tac.moveParams
	params.FilterDescendantsInstances = Tac.worldFilter()
	for _ = 1, 8 do
		local u, v = state.rng:NextNumber(-1, 1), state.rng:NextNumber(-1, 1)
		if not round or u * u + v * v <= 1 then
			local coords = { 0, 0, 0 }
			coords[a] = u * math.max(halves[a] - 2, 0.5)
			coords[b] = v * math.max(halves[b] - 2, 0.5)
			local point = cframe:PointToWorldSpace(Vector3.new(coords[1], coords[2], coords[3]))
			local hit = workspace:Raycast(point + Vector3.new(0, 2, 0), Vector3.new(0, -(halves[up] + 10), 0), params)
			if hit and hit.Normal.Y > 0.6 and Tac.inZone(zone, hit.Position + Vector3.new(0, 3, 0), 1)
				and not Tac.isUnreachable(hit.Position) then
				return hit.Position
			end
		end
	end
	return nil
end

--  [26/09] El enemigo vivo (no abatido) parado en el area mas cercano, o nil.
function Tac.zoneIntruder(state, zone)
	local best, bestDist = nil, math.huge
	for _, entry in ipairs(gatherEnemies(state, math.huge)) do
		if not entry.downed and entry.dist < bestDist and Tac.inZone(zone, entry.root.Position, 0) then
			best, bestDist = entry, entry.dist
		end
	end
	return best
end

--  Fuera de pelea: al area y a quedarse adentro. true = se hizo cargo.
function Tac.playObjective(state, now)
	local zone = Tac.controlZone()
	if not zone then
		state.zoneSpot = nil
		return false
	end
	local root = state.root.Position
	--  [26/09] Un enemigo en el area (sin verlo todavia): a sacarlo. Corre
	--  hacia el, mirando hacia alli para verlo en cuanto asome.
	local intruder = Tac.zoneIntruder(state, zone)
	if intruder then
		local where = intruder.root.Position
		state.lookAt = where
		state.lookUntil = now + 0.6
		if flat(where - root).Magnitude > 6 then
			Tac.goTo(state, now, where - Vector3.new(0, 3, 0), "zone", RUN_SPEED, 4)
		elseif state.moveMode ~= "hold" then
			stopWalking(state)
		end
		return true
	end
	local spot = state.zoneSpot
	if not spot or now > (state.zoneSpotUntil or 0) then
		spot = Tac.zoneSpot(state, zone) or Vector3.new(zone.Position.X, root.Y - 3, zone.Position.Z)
		state.zoneSpot = spot
		state.zoneSpotUntil = now + state.rng:NextNumber(8, 16)
	end
	local inside = Tac.inZone(zone, root, 0.5)
	if inside and flat(spot - root).Magnitude < 3 then
		if state.moveMode ~= "hold" then stopWalking(state) end
		local threat = Tac.threatGuess(state, now)
		if threat then
			state.lookAt = threat
			state.lookUntil = now + 0.5
		end
		return true
	end
	Tac.goTo(state, now, spot, "zone", inside and WALK_SPEED or RUN_SPEED, 2)
	if state.pathFails >= 3 then
		state.zoneSpot = nil
		state.pathFails = 0
	end
	return true
end

--  Peleando en Control (lejos del enemigo). true = se hizo cargo.
function Tac.fightForZone(state, now, dist)
	local zone = Tac.controlZone()
	if not zone then return false end
	local root = state.root.Position
	local target = state.target
	local targetInZone = target and target.root and Tac.inZone(zone, target.root.Position, 0)
	--  [26/09] El enemigo esta EN el area: prioridad sacarlo. De cerca, la
	--  pelea normal (se le acerca, remata); de lejos, hacia el a paso de
	--  combate disparando.
	if targetInZone then
		if dist <= 10 then return false end
		Tac.goTo(state, now, target.root.Position - Vector3.new(0, 3, 0), "zone", Config.Movement.CombatSpeed, 4)
		return true
	end
	local inside = Tac.inZone(zone, root, 0.5)
	--  Afuera y con el enemigo encima: pelea normal.
	if not inside and dist <= 10 then return false end
	if inside then
		--  Adentro: dispara sin salir; de lado solo si sigue adentro.
		if state.moveMode == "path" or state.moveMode == "direct"
			or (state.moveMode == "strafe" and state.strafeDir and not Tac.inZone(zone, root + state.strafeDir * 4, 0.5)) then
			stopWalking(state)
		end
		if now >= state.nextDecisionAt then
			state.nextDecisionAt = now + rangeNumber(state.rng, Config.Movement.StrafeTime)
			local side = state.root.CFrame.RightVector * (state.rng:NextNumber() < 0.5 and -1 or 1)
			if state.rng:NextNumber() < 0.5 and Tac.inZone(zone, root + side * 5, 0.5) then
				startStrafe(state, now, side)
			elseif state.rng:NextNumber() < Tac.AI.CombatCrouchChance then
				state.crouchUntil = now + state.rng:NextNumber(0.7, 1.6)
			end
		end
		return true
	end
	--  Afuera: hacia el area, disparando en el camino.
	local spot = state.zoneSpot or Tac.zoneSpot(state, zone)
	if not spot then return false end
	state.zoneSpot = spot
	Tac.goTo(state, now, spot, "zone", Config.Movement.CombatSpeed, 1.5)
	return true
end

function Tac.ambushStep(state, now)
	local ambush = state.ambush
	if not ambush then return false end
	if now > ambush.untilT or state.visible then
		state.ambush = nil
		return false
	end
	local dist = flat(ambush.pos - state.root.Position).Magnitude
	if not ambush.arrived and not Tac.atPost(state, ambush.pos, ambush.peek and 1.6 or 3) then
		if not state.finalStep then Tac.goTo(state, now, ambush.pos, "watch", WALK_SPEED, 3) end
		if state.pathFails >= 3 then
			state.ambush = nil
			return false
		end
	else
		ambush.arrived = true
		if state.moveMode ~= "hold" then stopWalking(state) end
	end
	state.lookAt = ambush.look + Vector3.new(0, 1.5, 0)
	state.lookUntil = now + 0.5
	return true
end

-- --------------------------------------------------------------------------
--  NADAR (23/09 noche)
--
--  Un Humanoid nadando no sube solo a una orilla ni pasa por debajo de nada.
--  Cada frame que el bot esta en el agua:
--    · si el siguiente punto de su camino esta mas alto que sus pies (una
--      orilla, un escalon, una azotea), sube nadando y salta para salir;
--    · si lleva 1.2 s sin avanzar, prueba a subir y, si hay techo encima o
--      ya lo intento, bucea para pasar por debajo del obstaculo.
--  El servidor es el dueno del cuerpo del bot, asi que puede fijarle la
--  velocidad vertical directamente.
-- --------------------------------------------------------------------------
function Tac.swimAssist(state, now)
	local humanoid, root = state.humanoid, state.root
	if humanoid:GetState() ~= Enum.HumanoidStateType.Swimming then
		state.swimEscape = nil
		state.swimProgressAt = nil
		return
	end

	local target = nil
	if state.moveMode == "path" and state.waypoints then
		local waypoint = state.waypoints[state.wpIndex]
		target = waypoint and waypoint.Position
	elseif state.moveMode == "direct" then
		target = humanoid.WalkToPoint
	end

	local velocity = root.AssemblyLinearVelocity
	local vy = nil

	--  1) Salir del agua: lo que sigue esta arriba de sus pies.
	if target then
		local rise = target.Y - (root.Position.Y - 2.5)
		if rise > 1 then
			humanoid.Jump = true
			vy = flat(target - root.Position).Magnitude < 7 and 28 or 12
		end
	end

	--  2) Atorado nadando: arriba, y si no se puede (o ya probo), por abajo.
	--  Solo cuenta si de verdad quiere moverse: quieto a proposito (peleando,
	--  levantando a alguien, en su puesto) no es estar atorado.
	local wantsToMove = state.moveMode == "path" or state.moveMode == "direct" or state.moveMode == "strafe"
	if not wantsToMove or not state.swimProgressAt or (root.Position - state.swimProgressPos).Magnitude > 2 then
		state.swimProgressPos = root.Position
		state.swimProgressAt = now
	elseif now - state.swimProgressAt > 1.2 and not state.swimEscape then
		Tac.params.FilterDescendantsInstances = Tac.worldFilter()
		local ceiling = workspace:Raycast(root.Position, Vector3.new(0, 7, 0), Tac.params)
		local mode = (ceiling or state.lastSwimEscape == "up") and "down" or "up"
		state.swimEscape = { mode = mode, untilT = now + (mode == "down" and 1.4 or 1.0) }
		state.lastSwimEscape = mode
		state.swimProgressAt = now
		dprint(state.bot.Name, mode == "down" and "bucea para zafarse" or "sube nadando para zafarse")
	end
	local escape = state.swimEscape
	if escape then
		if now > escape.untilT then
			state.swimEscape = nil
		elseif escape.mode == "up" then
			humanoid.Jump = true
			vy = 24
		else
			vy = -14
		end
	end

	if vy then
		root.AssemblyLinearVelocity = Vector3.new(velocity.X, vy, velocity.Z)
	end
end

-- --------------------------------------------------------------------------
--  CORREDORA (24/09)
-- --------------------------------------------------------------------------
--  En pelea. true si se hizo cargo del movimiento.
function Tac.kite(state, now, target, dist)
	local role = state.meta.role
	local keep = role.KeepAway or { 45, 70 }
	local humanoid = state.humanoid
	local away = flat(state.root.Position - target.root.Position)
	if away.Magnitude < 0.1 then away = flat(-state.root.CFrame.LookVector) end
	away = away.Unit
	local side = Vector3.new(-away.Z, 0, away.X)

	local fleeing = state.fleeUntil and now < state.fleeUntil
	if dist < (role.PanicRange or 25) or fleeing then
		--  Se le acercaron: huir en zigzag (y barrerse), sin disparar salvo
		--  que lo tengan encima.
		if not fleeing then
			state.fleeUntil = now + rangeNumber(state.rng, role.FleeTime or { 2.5, 4 })
			dprint(state.bot.Name, "huye en zigzag")
		end
		if dist > 10 then state.holdFire = true end
		humanoid.WalkSpeed = RUN_SPEED
		if state.moveMode ~= "strafe" or now >= state.strafeUntil then
			state.zigSide = -(state.zigSide or 1)
			startStrafe(state, now, away + side * state.zigSide * 0.8, rangeNumber(state.rng, role.ZigzagTime or { 0.35, 0.6 }))
			if state.moveMode ~= "strafe" then
				--  Acorralada contra algo: por camino a un punto lejos.
				local goal = state.root.Position + away * rangeNumber(state.rng, role.FleeDistance or { 40, 60 })
				Tac.goTo(state, now, goal, "flee", RUN_SPEED, 1)
			end
		end
		return true
	end
	if dist < keep[1] then
		--  Un poco cerca: se aleja disparando.
		humanoid.WalkSpeed = WALK_SPEED
		if state.moveMode ~= "strafe" or now >= state.strafeUntil then
			startStrafe(state, now, away + side * (state.rng:NextNumber() < 0.5 and -0.6 or 0.6), 0.7)
		end
		return true
	end
	if dist <= keep[2] then
		--  A la distancia que le gusta: dispara moviendose de lado.
		humanoid.WalkSpeed = Config.Movement.CombatSpeed
		if now >= state.nextDecisionAt then
			state.nextDecisionAt = now + rangeNumber(state.rng, Config.Movement.StrafeTime)
			startStrafe(state, now, side * (state.rng:NextNumber() < 0.5 and -1 or 1))
		end
		return true
	end
	return false		-- muy lejos: se acerca como cualquiera
end

--  Sin pelea: se pone a su distancia de donde sabe que hay enemigos.
function Tac.runner(state, now)
	local role = state.meta.role
	local keep = role.KeepAway or { 45, 70 }
	local ref = nil
	if state.lastSeenPos and now - state.lastSeenAt < 8 then
		ref = state.lastSeenPos
	else
		local intel = Tac.intel(state, now)
		ref = intel and intel.pos
	end
	if not ref then return false end
	local away = flat(state.root.Position - ref)
	local dist = away.Magnitude
	if dist < keep[1] or dist > keep[2] then
		local dir = dist > 0.1 and away.Unit or Vector3.new(1, 0, 0)
		Tac.goTo(state, now, ref + dir * ((keep[1] + keep[2]) / 2), "kite", RUN_SPEED, 2)
		return true
	end
	if state.moveMode ~= "hold" then stopWalking(state) end
	state.lookAt = ref
	state.lookUntil = now + 0.5
	return true
end

-- --------------------------------------------------------------------------
--  CAMPER (24/09)
-- --------------------------------------------------------------------------
function Tac.enemyCenter(state)
	local enemies = gatherEnemies(state, math.huge)
	if #enemies == 0 then return nil end
	local sum = Vector3.zero
	for _, entry in ipairs(enemies) do sum += entry.root.Position end
	return sum / #enemies
end

function Tac.isBadPerch(state, spot)
	for _, bad in ipairs(state.badPerches or {}) do
		if (bad - spot).Magnitude < 8 then return true end
	end
	return false
end

--  Un punto ALTO (azotea, balcon, piso de arriba) con vista hacia los
--  enemigos y a distancia de tiro de su arma principal.
function Tac.findPerch(state)
	--  [IA v2] Filtros una sola vez (antes se armaban en cada vuelta del bucle).
	Tac.probeParams.FilterDescendantsInstances = Tac.worldFilter()
	Tac.params.FilterDescendantsInstances = Tac.worldFilter()
	local role = state.meta.role
	local origin = state.root.Position
	local rng = state.rng
	local enemyCenter = Tac.enemyCenter(state)
	local primary = state.weapons[(state.meta.loadout or Config.Loadout)[1]]
	local maxRange = primary and primary.info.cfg.MaxRange or 300
	local refY = enemyCenter and math.min(origin.Y, enemyCenter.Y) or origin.Y
	--  [24/09] Se prueba a varias alturas CERCA de su piso (12 a 60 studs
	--  arriba): mirar desde muy alto encontraba el techo por FUERA de los
	--  edificios (inalcanzable). Devuelve una lista ordenada de candidatos;
	--  Tac.camp comprueba que haya camino antes de elegir uno.
	local list = {}
	local lifts = { 12, 24, 36, 60 }
	for i = 1, 40 do
		local angle = rng:NextNumber(0, math.pi * 2)
		local radius = rng:NextNumber(10, role.PerchSearch or 110)
		local lift = lifts[(i % #lifts) + 1]
		local probe = Vector3.new(origin.X + math.cos(angle) * radius, origin.Y + lift, origin.Z + math.sin(angle) * radius)
		local ground = workspace:Raycast(probe, Vector3.new(0, -(lift + 20), 0), Tac.probeParams)
		if ground and ground.Normal.Y > 0.7 and not isSeeThrough(ground.Instance) then
			local spot = ground.Position
			local height = spot.Y - refY
			if height >= (role.MinHeight or 6) and not Tac.isBadPerch(state, spot) and Tac.climateOk(spot) then
				--  Que quepa una persona (nada justo encima).
				if not workspace:Raycast(spot + Vector3.new(0, 0.5, 0), Vector3.new(0, 5, 0), Tac.params) then
					local eye = spot + Vector3.new(0, 2.6, 0)
					local viewScore = 0
					if enemyCenter then
						local toEnemy = (enemyCenter + Vector3.new(0, 2, 0)) - eye
						local d = toEnemy.Magnitude
						if d <= maxRange then
							local hit = workspace:Raycast(eye, toEnemy, Tac.params)
							local clear = not hit or (hit.Position - eye).Magnitude > d * 0.8
							viewScore = (clear and 40 or 0) + math.min(d, 150) * 0.1
						else
							viewScore = -30
						end
					end
					local score = height * 1.5 + viewScore - (spot - origin).Magnitude * 0.08
					if state.lastPerch and (state.lastPerch - spot).Magnitude < 12 then score -= 40 end
					table.insert(list, { pos = spot, face = enemyCenter, score = score })
				end
			end
		end
	end
	table.sort(list, function(a, b) return a.score > b.score end)
	return list
end

--  Una entrada unica cerca (una de las puertas registradas o un pasillo
--  angosto) y un punto adentro, a 10-16 studs, desde donde se la ve. Elige
--  el lado contrario a los enemigos: ellos tienen que entrar por ahi.
function Tac.findChokeHold(state)
	--  [IA v2] Filtros una sola vez (antes se armaban en cada vuelta del bucle).
	Tac.probeParams.FilterDescendantsInstances = Tac.worldFilter()
	Tac.params.FilterDescendantsInstances = Tac.worldFilter()
	local origin = state.root.Position
	local rng = state.rng
	local enemyCenter = Tac.enemyCenter(state)
	local candidates = {}
	for _, info in ipairs(Tac.doorList) do
		local anchor = Tac.doorAnchor(info)
		local part = info.prompt.Parent
		if anchor and part and part:IsA("BasePart") and (anchor - origin).Magnitude < 90 then
			local normal = flat(part.CFrame.LookVector)
			if normal.Magnitude > 0.1 then
				normal = normal.Unit
				table.insert(candidates, { entry = anchor, dirs = { normal, -normal } })
			end
		end
	end
	--  Pasillos: pared a los dos lados (a menos de 5 studs) y abierto a lo largo.
	for _ = 1, 20 do
		local angle = rng:NextNumber(0, math.pi * 2)
		local radius = rng:NextNumber(8, 60)
		local ground = workspace:Raycast(origin + Vector3.new(math.cos(angle) * radius, 5, math.sin(angle) * radius), Vector3.new(0, -14, 0), Tac.probeParams)
		if ground and ground.Normal.Y > 0.7 then
			local p = ground.Position + Vector3.new(0, 2.5, 0)
			for _, axis in ipairs({ Vector3.new(1, 0, 0), Vector3.new(0, 0, 1) }) do
				if workspace:Raycast(p, axis * 5, Tac.params) and workspace:Raycast(p, -axis * 5, Tac.params) then
					local along = Vector3.new(-axis.Z, 0, axis.X)
					if not workspace:Raycast(p, along * 12, Tac.params) and not workspace:Raycast(p, -along * 12, Tac.params) then
						table.insert(candidates, { entry = ground.Position, dirs = { along, -along } })
					end
				end
			end
		end
	end
	local list = {}
	for _, candidate in ipairs(candidates) do
		for _, dir in ipairs(candidate.dirs) do
			local probe = candidate.entry + dir * rng:NextNumber(10, 16) + Vector3.new(0, 5, 0)
			local ground = workspace:Raycast(probe, Vector3.new(0, -14, 0), Tac.probeParams)
			if ground and ground.Normal.Y > 0.7 and not Tac.isBadPerch(state, ground.Position) and Tac.climateOk(ground.Position) then
				local spot = ground.Position
				local eye = spot + Vector3.new(0, 2.6, 0)
				local toEntry = (candidate.entry + Vector3.new(0, 2.5, 0)) - eye
				local hit = workspace:Raycast(eye, toEntry, Tac.params)
				if not hit or (hit.Position - eye).Magnitude > toEntry.Magnitude * 0.85 then
					local score = -(spot - origin).Magnitude * 0.1
					if enemyCenter then score += (spot - enemyCenter).Magnitude * 0.2 end
					table.insert(list, { pos = spot, face = candidate.entry, score = score })
				end
			end
		end
	end
	table.sort(list, function(a, b) return a.score > b.score end)
	return list
end

function Tac.camp(state, now)
	local role = state.meta.role
	local perch = state.perch
	local recentlyHit = state.lastDamageAt and now - state.lastDamageAt < 2
	if perch and (now > perch.untilT or (perch.arrived and recentlyHit) or state.pathFails >= 3) then
		--  Se acabo el tiempo, lo descubrieron, o no hay camino: otro punto.
		if Config.Debug then
			state.character:SetAttribute("BotCampCambio", state.pathFails >= 3 and "sin camino"
				or (perch.arrived and recentlyHit) and "lo descubrieron" or "tiempo")
		end
		state.lastPerch = perch.pos
		if state.pathFails >= 3 then
			state.badPerches = state.badPerches or {}
			table.insert(state.badPerches, perch.pos)
			if #state.badPerches > 12 then table.remove(state.badPerches, 1) end
		end
		state.perch = nil
		perch = nil
		state.pathFails = 0
	end
	if not perch then
		if state.perchSearching then
			--  [IA v3] Comprobando caminos a los puntos altos: quieto un momento.
			if state.moveMode ~= "hold" then stopWalking(state) end
			return true
		end
		if now < (state.nextPerchPick or 0) then return false end
		state.nextPerchPick = now + 3
		local choke = state.rng:NextNumber() < (role.ChokeChance or 0.35)
		local list = choke and Tac.findChokeHold(state) or {}
		if #list == 0 then
			choke = false
			--  [IA v3] Mirando todos los pisos; el viejo si no encuentra nada.
			list = Tac.findPerchV3(state)
			if #list == 0 then list = Tac.findPerch(state) end
		end
		if #list == 0 then return false end
		--  [24/09] Antes de elegir, que haya camino COMPLETO hasta el punto
		--  (en segundo plano: calcular caminos espera). Prueba los mejores
		--  candidatos en orden y se queda con el primero alcanzable.
		state.perchSearching = true
		task.spawn(function()
			--  [IA v2] Un solo Path por bot (antes uno nuevo en cada busqueda) y
			--  cada calculo paga del presupuesto global (espera si no alcanza).
			--  [IA v3] Con el agente angosto (como Tac.validateSpots): con el
			--  ancho, las escaleras angostas daban "sin camino" y el punto alto
			--  de un segundo piso quedaba descartado.
			state.pathProbe = state.pathProbe or PathfindingService:CreatePath(Tac.tightAgent)
			local path = state.pathProbe
			for index = 1, math.min(#list, 6) do
				if not isAlive(state) or state.perch then break end
				local waited = 0
				while not Tac.takePathToken("perch") and waited < 5 do
					waited += task.wait(0.25)
				end
				if not isAlive(state) or state.perch then break end
				local candidate = list[index]
				local ok = pcall(function() path:ComputeAsync(state.root.Position, candidate.pos) end)
				if ok and path.Status == Enum.PathStatus.Success then
					local waypoints = path:GetWaypoints()
					local last = waypoints[#waypoints]
					if last and flat(last.Position - candidate.pos).Magnitude < 4 and math.abs(last.Position.Y - candidate.pos.Y) < 3 then
						state.perch = { pos = candidate.pos, face = candidate.face, choke = choke, arrived = false, peek = candidate.peek,
							untilT = os.clock() + rangeNumber(state.rng, role.PerchTime or { 20, 45 }) }
						state.pathFails = 0
						dprint(state.bot.Name, choke and "va a holdear una entrada" or "va a un punto alto")
						break
					end
				end
				state.badPerches = state.badPerches or {}
				table.insert(state.badPerches, candidate.pos)
				if #state.badPerches > 16 then table.remove(state.badPerches, 1) end
				Tac.markUnreachable(candidate.pos, 1, "sin camino al punto alto")		-- [IA v3]
			end
			state.perchSearching = false
		end)
		return false
	end
	local dist = flat(perch.pos - state.root.Position).Magnitude
	local dy = math.abs(perch.pos.Y - (state.root.Position.Y - 3))
	if Config.Debug then
		state.character:SetAttribute("BotCamp", string.format("%s a %.0f studs (dy %.0f)", perch.arrived and "en su punto" or "yendo", dist, dy))
	end
	if (dist > 3 or dy > 4) and not (dy <= 4 and Tac.atPost(state, perch.pos, perch.peek and 1.6 or 3)) then
		perch.arrived = false
		Tac.goTo(state, now, perch.pos, "perch", dist > 30 and RUN_SPEED or WALK_SPEED, 3)
		return true
	end
	perch.arrived = true
	if state.moveMode ~= "hold" then stopWalking(state) end
	--  Cubre su angulo: la entrada, o hacia los enemigos / lo ultimo que oyo.
	local look = state.orderLook or perch.face		-- [24/09] hacia donde dijo el Lider
	if state.noise and now - state.noise.at < 6 then
		look = state.noise.pos
	elseif state.lastSeenPos and now - state.lastSeenAt < 8 then
		look = state.lastSeenPos
	end
	if look then
		state.lookAt = look
		state.lookUntil = now + 0.5
	end
	return true
end

-- --------------------------------------------------------------------------
--  LIDER (24/09)
--
--  Un bot de tipo Lider junta lo que vio su equipo (Tac.sightings), calcula
--  el frente (por donde vienen los enemigos, pesando mas lo reciente), elige
--  un objetivo prioritario (bajas, cercania a su equipo, vida que le falta)
--  y publica una orden para su equipo: punto de ataque, objetivo y un flanco
--  para cada bot. Los demas la siguen segun su tipo (Tac.followOrders). La
--  orden caduca en OrderLife s o si el Lider muere.
-- --------------------------------------------------------------------------
Tac.sightings = {}											-- [equipo] = { {pos, at, participant} }
Tac.sightingAt = setmetatable({}, { __mode = "k" })		-- [participante] = ultimo avistamiento
Tac.orders = {}												-- [equipo] = orden vigente

function Tac.killsOf(participant)
	local get = _G.LL_GetMatchEntry
	local entry = get and get(participant.UserId)
	return entry and entry.kills or 0
end

--  La orden vigente para el equipo de este bot (o nil).
function Tac.currentOrder(state, now)
	local team = Tac.teamKey(state)
	local order = team and Tac.orders[team]
	if not order then return nil end
	local leaderBrain = brains[order.by]
	if now - order.at > order.life or not leaderBrain or not isAlive(leaderBrain) then
		Tac.orders[team] = nil
		return nil
	end
	return order
end

function Tac.issueOrders(state, now)
	local role = state.meta.role
	local team = Tac.teamKey(state)
	if not team then return end
	--  Si ya hay otro Lider vivo mandando en este equipo, no se pisan.
	local current = Tac.currentOrder(state, now)
	if current and current.by ~= state.bot then return end

	local list = Tac.sightings[team] or {}
	--  Frente: promedio de los avistamientos de los ultimos 20 s (lo nuevo pesa mas).
	local sum, weight = Vector3.zero, 0
	local latest = {}
	for _, sighting in ipairs(list) do
		local age = now - sighting.at
		if age <= 20 then
			local w = 1 - age / 20
			sum += sighting.pos * w
			weight += w
		end
		if age <= 12 then latest[sighting.participant] = sighting end
	end
	local front = weight > 0 and sum / weight or nil

	local mates = Tac.teammates(state)
	local squad = { state.root.Position }
	for _, mate in ipairs(mates) do table.insert(squad, mate.root.Position) end
	local teamCenter = Vector3.zero
	for _, p in ipairs(squad) do teamCenter += p end
	teamCenter /= #squad

	--  Objetivo prioritario entre los que el equipo vio hace poco.
	local focus, focusPos, bestScore = nil, nil, nil
	for participant, sighting in pairs(latest) do
		local character = participant.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 and participant:GetAttribute("InRound") == true and not isDownedCharacter(character) then
			local closest = math.huge
			for _, p in ipairs(squad) do closest = math.min(closest, (p - sighting.pos).Magnitude) end
			local missing = 1 - humanoid.Health / math.max(humanoid.MaxHealth, 1)
			local score = Tac.killsOf(participant) * (role.KillWeight or 10)
				- closest * (role.CloseWeight or 1)
				+ missing * 100 * (role.LowHealthWeight or 0.5)
			if not bestScore or score > bestScore then
				focus, focusPos, bestScore = participant, sighting.pos, score
			end
		end
	end

	local attackPos = focusPos or front
	if not attackPos then
		Tac.orders[team] = nil
		return
	end

	--  Flancos: centro, derecha, izquierda, medio derecha, medio izquierda...
	local axis = flat(attackPos - teamCenter)
	axis = axis.Magnitude > 1 and axis.Unit or Vector3.new(1, 0, 0)
	local perp = Vector3.new(-axis.Z, 0, axis.X)
	local sides = { 0, 1, -1, 0.5, -0.5 }
	local assignments = {}
	local index = 0
	for _, mate in ipairs(mates) do
		if Registry.isBot(mate.participant) then
			index += 1
			assignments[mate.participant] = sides[((index - 1) % #sides) + 1]
		end
	end

	local previous = Tac.orders[team]
	Tac.orders[team] = {
		by = state.bot, at = now, life = role.OrderLife or 8,
		focus = focus, attackPos = attackPos, front = front,
		axis = axis, perp = perp, spread = role.FlankSpread or 25,
		focusBonus = role.FocusBonus or 40, assignments = assignments,
	}
	if not previous or previous.focus ~= focus then
		dprint(state.bot.Name, "(Lider) marca", focus and ("a " .. focus.Name) or "el frente", "-", index, "bots en flancos")
	end
	if Config.Debug then
		state.bot:SetAttribute("BotOrden", string.format("%s @ %.0f,%.0f,%.0f", focus and focus.Name or "frente", attackPos.X, attackPos.Y, attackPos.Z))
	end
end

--  Cada vuelta de decisiones del bot Lider, aunque este peleando.
function Tac.leaderTick(state, now)
	local role = state.meta.role
	if not role or role.Kind ~= "Lider" or now < (state.nextOrderAt or 0) then return end
	state.nextOrderAt = now + (role.OrderEvery or 3)
	Tac.issueOrders(state, now)
end

--  Movimiento del Lider cuando no pelea: detras del frente, mirando hacia alla.
function Tac.command(state, now)
	local role = state.meta.role
	local order = Tac.currentOrder(state, now)
	if not order or order.by ~= state.bot then return false end
	local goal = order.attackPos - order.axis * (role.StayBehind or 30)
	if flat(goal - state.root.Position).Magnitude > 6 then
		Tac.goTo(state, now, goal, "command", WALK_SPEED, 2)
	else
		if state.moveMode ~= "hold" then stopWalking(state) end
		state.lookAt = order.attackPos
		state.lookUntil = now + 0.5
	end
	return true
end

--  Lo que hace cada bot con la orden de su Lider (segun su tipo).
function Tac.followOrders(state, now)
	state.orderLook = nil
	state.forcedPrey = nil
	local order = Tac.currentOrder(state, now)
	if not order or order.by == state.bot then return false end
	local role = state.meta.role
	local kind = role and role.Kind
	if kind == "Defensiva" or kind == "Camper" then
		--  No dejan su puesto, pero cubren hacia donde dijo el Lider.
		state.orderLook = order.attackPos
		return false
	end
	if kind == "Sigiloso" then
		--  Su presa pasa a ser el objetivo marcado; sigue con su rodeo.
		if order.focus and (not state.prey or state.prey.participant ~= order.focus) then state.prey = nil end
		state.forcedPrey = order.focus
		return false
	end
	--  [24/09] Un segundo Lider en el mismo equipo no manda (no pisa las
	--  ordenes del que ya las da): las sigue como atacante, y toma el mando
	--  en cuanto el otro muera (la orden caduca).

	local side = order.assignments[state.bot] or 0
	local goal = order.attackPos + order.perp * side * order.spread - order.axis * 10
	if kind == "Corredora" then
		--  A su distancia del punto marcado, no encima.
		local keep = role.KeepAway or { 45, 70 }
		local away = flat(state.root.Position - order.attackPos)
		local dir = away.Magnitude > 0.1 and away.Unit or -order.axis
		goal = order.attackPos + dir * ((keep[1] + keep[2]) / 2)
	end
	if flat(goal - state.root.Position).Magnitude < 6 then
		if state.moveMode ~= "hold" then stopWalking(state) end
		state.lookAt = order.attackPos
		state.lookUntil = now + 0.5
		if Config.Debug then state.bot:SetAttribute("BotSigueOrden", "en su flanco") end
		return true
	end
	if Config.Debug then state.bot:SetAttribute("BotSigueOrden", string.format("yendo (flanco %+.1f)", side)) end
	Tac.goTo(state, now, goal, "order", RUN_SPEED, 2)
	return true
end

-- --------------------------------------------------------------------------
--  LEVANTAR MEJOR (24/09)
-- --------------------------------------------------------------------------
--  Hacia donde mirar mientras levanta. Devuelve (punto, disparando, soltar).
--  Si el enemigo esta a menos de ShootWhileRevivingAngle del caido, lo mira
--  a el: puede dispararle y el servidor lo sigue dejando levantar (pide
--  mirar al caido mas o menos de frente). Si esta fuera de ese angulo y se
--  le echa encima, suelta al caido para pelear.
function Tac.reviveFacing(state, victimPos)
	local R = Config.Revive
	local target = state.target
	if not (target and state.visible) then return victimPos, false, false end
	local here = state.root.Position
	local toVictim = flat(victimPos - here)
	local toEnemy = flat(target.root.Position - here)
	if toVictim.Magnitude < 0.5 or toEnemy.Magnitude < 0.5 then return victimPos, false, false end
	local angle = math.deg(math.acos(math.clamp(toVictim.Unit:Dot(toEnemy.Unit), -1, 1)))
	if angle <= (R.ShootWhileRevivingAngle or 70) then
		return target.root.Position, true, false
	end
	if toEnemy.Magnitude < (R.AbortClose or 18) then
		return nil, false, true
	end
	return victimPos, false, false
end

--  Desde donde levantarlo: un punto junto al caido donde, agachado, el
--  enemigo no lo ve; si no hay, DETRAS del caido respecto al enemigo (asi,
--  mirando al caido tambien mira al enemigo y le puede disparar).
function Tac.revivePosition(state, victimPos, threat)
	--  [IA v2] Filtros una sola vez (antes se armaban en cada vuelta del bucle).
	Tac.probeParams.FilterDescendantsInstances = Tac.worldFilter()
	Tac.params.FilterDescendantsInstances = Tac.worldFilter()
	local threatEye = threat + Vector3.new(0, 2, 0)
	local best, bestDist = nil, nil
	for i = 0, 7 do
		local angle = i * math.pi / 4
		for _, radius in ipairs({ 4, 7 }) do
			local probe = victimPos + Vector3.new(math.cos(angle) * radius, 4, math.sin(angle) * radius)
			local ground = workspace:Raycast(probe, Vector3.new(0, -10, 0), Tac.probeParams)
			if ground and ground.Normal.Y > 0.7 then
				local spot = ground.Position
				local head = spot + Vector3.new(0, 2.4, 0)
				local hit = workspace:Raycast(threatEye, head - threatEye, Tac.params)
				local covered = hit and (hit.Position - head).Magnitude > 1.2 and not isSeeThrough(hit.Instance)
				local seesVictim = not workspace:Raycast(head, (victimPos + Vector3.new(0, 0.5, 0)) - head, Tac.params)
				if covered and seesVictim then
					local d = (spot - state.root.Position).Magnitude
					if not bestDist or d < bestDist then best, bestDist = spot, d end
				end
			end
		end
	end
	if best then return best end
	local away = flat(victimPos - threat)
	if away.Magnitude < 1 then return nil end
	local ground = workspace:Raycast(victimPos + away.Unit * 5 + Vector3.new(0, 4, 0), Vector3.new(0, -10, 0), Tac.probeParams)
	return ground and ground.Position or nil
end

--  Ir a levantar al companero caido mas cercano. true si se hizo cargo.
function Tac.seekRevive(state, now)
	local mate, mateDist = findDownedTeammate(state)
	if not mate then
		state.reviveSpot = nil
		return false
	end
	local R = Config.Revive
	local humanoid = state.humanoid

	--  De donde viene el peligro (lo que ve, lo ultimo que vio, o un aviso).
	local threat = nil
	if state.target and state.visible then
		threat = state.target.root.Position
	elseif state.lastSeenPos and now - state.lastSeenAt < 6 then
		threat = state.lastSeenPos
	else
		local intel = Tac.intel(state, now)
		threat = intel and intel.pos
	end

	local spot = state.reviveSpot
	if not spot or spot.mate ~= mate.participant or now > spot.untilT then
		spot = { mate = mate.participant, untilT = now + 3,
			pos = threat and Tac.revivePosition(state, mate.root.Position, threat) or nil }
		state.reviveSpot = spot
	end

	local goal = spot.pos or mate.root.Position
	local distToGoal = flat(goal - state.root.Position).Magnitude
	local inPlace = (spot.pos and distToGoal < 2.5) or (not spot.pos and mateDist <= R.StartDistance)
	if inPlace and mateDist <= R.StartDistance + 3 and canSee(state, state.head.Position, mate) then
		if state.moveMode ~= "hold" then stopWalking(state) end
		state.lookAt = mate.root.Position
		state.lookUntil = now + 0.6
		local look = flat(state.root.CFrame.LookVector)
		local toMate = flat(mate.root.Position - state.root.Position)
		if look.Magnitude > 0.01 and toMate.Magnitude > 0.3 and look.Unit:Dot(toMate.Unit) > 0.6 then
			if _G.Downed_StartRevive and _G.Downed_StartRevive(state.bot, mate.participant) then
				dprint(state.bot.Name, "empieza a levantar a", mate.participant.Name, spot.pos and "(desde un punto elegido)" or "")
			end
		end
		return true
	end

	humanoid.WalkSpeed = mateDist > 30 and RUN_SPEED or WALK_SPEED
	--  Sin camino al punto elegido: directo al caido. Sin camino al caido:
	--  lo ignora 10 s (si no, se quedaba parado intentandolo para siempre).
	if state.pathKind == "revive" and state.pathFails >= 2 then
		state.pathFails = 0
		if spot.pos then
			spot.pos = nil
			spot.untilT = now + 6
		else
			state.reviveIgnore = state.reviveIgnore or setmetatable({}, { __mode = "k" })
			state.reviveIgnore[mate.participant] = os.clock() + 10
			state.reviveSpot = nil
			dprint(state.bot.Name, "no puede llegar a", mate.participant.Name)
			return false
		end
		goal = mate.root.Position
		distToGoal = flat(goal - state.root.Position).Magnitude
	end
	if spot.pos and distToGoal < 6 then
		--  Ultimos pasos, derecho al punto.
		state.waypoints = nil
		state.moveMode = "direct"
		humanoid:MoveTo(goal)
		state.lastMoveToAt = now
	elseif state.pathKind ~= "revive" or (not state.waypoints and not state.pathBusy)
		or now - state.lastRepath > Config.Movement.RepathMoving then
		requestPath(state, goal, "revive")
	end
	return true
end

function Tac.roleBehavior(state, now)
	local role = state.meta.role
	if not role then return false end
	local kind = role.Kind
	if kind == "Defensiva" then return Tac.defend(state, now) end
	if kind == "Estratega" then return Tac.strategize(state, now) end
	if kind == "Equipo" then return Tac.teamUp(state, now) end
	if kind == "Apoyo" then return Tac.support(state, now) end
	if kind == "Ataque" then return Tac.assault(state, now) end
	if kind == "Sigiloso" then return Tac.stealth(state, now) end
	if kind == "Corredora" then return Tac.runner(state, now) end
	if kind == "Camper" then return Tac.camp(state, now) end
	if kind == "Lider" then return Tac.command(state, now) end
	return false
end

local lastErrorAt = 0

local function stepBrain(state, now, dt)
	if not isAlive(state) then return end
	if now < state.activeAt then return end
	if not state.spawnPos then
		--  Ya lo teletransporto el RoundManager a su spawn.
		state.spawnPos = state.root.Position
		state.progressPos = state.root.Position
		state.progressAt = now
	end

	--  [fase 2] Abatido: DownedServer manda. Aqui solo el cuerpo (lo que
	--  haria el cliente) y las decisiones de alguien tirado en el suelo.
	if state.downed ~= "" then
		enforceDowned(state, now, dt)
		if now >= state.nextThink then
			local thinkDt = math.min(now - state.lastThink, 0.5)
			state.lastThink = now
			state.nextThink = now + 1 / Config.Perception.ThinkRate
			thinkDowned(state, now, thinkDt)
		end
		updateReload(state, now)
		if state.proneArmed then
			updateFacing(state, now, dt)
			updateFire(state, now)
		end
		stepMovement(state, now)
		state.recoil = math.max(0, state.recoil - dt * 4)
		return
	end

	--  [fase 2] Congelado en un bloque de hielo, paralizado por la
	--  electricidad o volando por el ventarron: los estados mandan sobre el
	--  Humanoid. No se mueve ni dispara; si es hielo, forcejea para romperlo
	--  (como un jugador pulsando la tecla).
	local character = state.character
	local frozen = character:GetAttribute("FreezeLocked") == true
	if frozen or character:GetAttribute("ShockParalyzed") == true or character:GetAttribute("Ventarron_Volando") then
		if state.moveMode ~= "hold" or state.waypoints then
			state.waypoints = nil
			state.moveMode = "hold"
		end
		state.align.Enabled = false
		state.burstLeft = 0
		if frozen and now >= (state.nextIcePress or 0) then
			state.nextIcePress = now + rangeNumber(state.rng, (Config.Downed and Config.Downed.StrugglePress) or { 0.1, 0.17 })
			local freezeScript = character:FindFirstChild("FreezeScript")
			local struggle = freezeScript and freezeScript:FindFirstChild("BotStruggle")
			if struggle then struggle:Fire() end
		end
		return
	end

	if now >= state.nextThink then
		local thinkDt = math.min(now - state.lastThink, 0.5)
		state.lastThink = now
		--  [IA v2] Lejos de jugadores reales y sin pelea, piensa mas lento (lod).
		state.nextThink = now + 1 / (Config.Perception.ThinkRate * (state.lod or 1))
		think(state, now, thinkDt)
		updateAnimation(state)
	end

	updateReload(state, now)
	updateFacing(state, now, dt)
	updateFire(state, now)
	--  [tacticas] Barrida en curso: ella mueve el cuerpo; si no, el camino.
	--  [23/09 noche] Abriendo una puerta: quieto hasta que termine de girar.
	--  [IA v3] Pasando una puerta: quieto mientras abre.
	local doorHold = Tac.doorStep and Tac.doorStep(state, now)
	if not doorHold and now >= (state.doorWaitUntil or 0) and not (Tac.updateSlide and Tac.updateSlide(state, now)) then
		stepMovement(state, now)
		--  [IA v2] Saltar, trepar, cruzar huecos, esquivar.
		if Tac.parkour then Tac.parkour(state, now) end
	end
	--  [23/09 noche] En el agua: subir a la orilla, o subir / bucear si se atora.
	if Tac.swimAssist then Tac.swimAssist(state, now) end
	updateProtection(state, now)
	state.recoil = math.max(0, state.recoil - dt * 4)
end

RunService.Heartbeat:Connect(function(dt)
	local now = os.clock()
	--  [IA v2] Recarga del presupuesto de caminos (ver Tac.takePathToken).
	Tac.pathTokens = math.min(Tac.AI.PathBurst, Tac.pathTokens + dt * Tac.AI.PathBudget)
	--  [IA v3] Memoria del mapa: se reinicia con cada fase (mapa nuevo).
	if Tac.memoryTick then Tac.memoryTick(now) end
	for _, state in pairs(brains) do
		if not state.dead then
			local ok, err = pcall(stepBrain, state, now, dt)
			if not ok and now - lastErrorAt > 5 then
				lastErrorAt = now
				warn("[Bots] Error en el cerebro de " .. tostring(state.bot.Name) .. ": " .. tostring(err))
			end
		end
	end
end)

--==========================================================================
--  VIDA Y MUERTE DEL CUERPO
--==========================================================================
local function announceDeath(bot, humanoid)
	if not killFeedEvent then return end
	local tag = humanoid:FindFirstChild("creator")
	local killer = tag and Registry.resolveKiller(tag.Value)
	if not killer or killer == bot then return end
	local weaponTag = humanoid:FindFirstChild("weaponUsed")
	local weaponName = (weaponTag and weaponTag.Value) or humanoid:GetAttribute("ACS_KillWeapon") or "Desconocida"
	local distance = tonumber(humanoid:GetAttribute("ACS_KillDistanceStuds")) or 0
	local bodyPart = tostring(humanoid:GetAttribute("ACS_KillBodyPart") or "cuerpo")
	if bodyPart == "" then bodyPart = "cuerpo" end
	killFeedEvent:FireAllClients({
		Killer = killer.Name,
		KillerName = killer.Name,
		Victim = bot.Name,
		VictimName = bot.Name,
		Weapon = weaponName,
		Distance = math.round((distance / 3.571) * 10) / 10,
		BodyPart = bodyPart,
	})
end

local function scheduleRespawn(bot)
	local meta = metas[bot]
	if not meta then return end
	local delay = Players.RespawnTime + rangeNumber(meta.rng, Config.Round.RespawnExtra)
	task.delay(delay, function()
		if not metas[bot] or not bot.Parent then return end
		if bot:GetAttribute("InRound") ~= true or bot:GetAttribute("Eliminated") == true then return end
		--  Guardian: la espera de reaparicion del modo tambien vale para el bot.
		local readyAt = tonumber(bot:GetAttribute("RespawnReadyAt"))
		if readyAt then
			local wait = readyAt - workspace:GetServerTimeNow()
			if wait > 0 then task.wait(wait) end
		end
		if not metas[bot] or not bot.Parent then return end
		if bot:GetAttribute("InRound") ~= true or bot:GetAttribute("Eliminated") == true then return end
		local character = bot.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 then return end
		bot:LoadCharacter()
	end)
end

local function onBodyDied(state)
	if state.dead then return end
	state.dead = true
	local bot, character, humanoid = state.bot, state.character, state.humanoid
	if state.align then state.align.Enabled = false end
	for _, track in pairs(state.tracks) do pcall(function() track:Stop(0.1) end) end
	pcall(Ragdoll, character)
	if bot:GetAttribute("InRound") == true then
		announceDeath(bot, humanoid)
		scheduleRespawn(bot)
	end
	Debris:AddItem(character, Config.Round.CorpseTime)
end

local function despawn(bot)
	local state = brains[bot]
	brains[bot] = nil
	if state then state.dead = true end
	local character = rawget(bot, "_character")
	if character then
		Registry.setCharacter(bot, nil)
		character:Destroy()
	end
end

local function newBrain(bot, meta, character)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	local head = character:FindFirstChild("Head")
	local neck = head and head:FindFirstChild("Neck")
	local now = os.clock()

	local attachment = Instance.new("Attachment")
	attachment.Name = "BotAim"
	attachment.Parent = root
	local align = Instance.new("AlignOrientation")
	align.Name = "BotAim"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.RigidityEnabled = false
	align.MaxTorque = 1e7
	align.Responsiveness = meta.react.TurnSpeed * 2.5
	align.MaxAngularVelocity = meta.react.TurnSpeed * 0.9
	--  El CFrame que se le da siempre es horizontal (lookAt sin Y), asi que
	--  lo mantiene derecho y solo cambia hacia donde mira.
	align.PrimaryAxisOnly = false
	align.Enabled = false
	align.Parent = root

	local agent = { AgentRadius = 1.8, AgentHeight = 5.4, AgentCanClimb = true, WaypointSpacing = 5, Costs = { Water = 6 } }
	local jumpAgent = table.clone(agent)
	agent.AgentCanJump = false
	jumpAgent.AgentCanJump = true

	local state = {
		bot = bot, meta = meta, rng = meta.rng, aim = meta.aim, react = meta.react,
		character = character, humanoid = humanoid, root = root, head = head,
		neck = neck, neckBase = neck and neck.C0 or CFrame.new(), pitch = 0,
		align = align,
		path = PathfindingService:CreatePath(agent),
		pathJump = PathfindingService:CreatePath(jumpAgent),
		weapons = {}, current = nil, equipUntil = 0, lastSwitchAt = -10, reload = nil,
		target = nil, visible = false, lastSeenAt = -100, lastSeenPos = nil,
		reactReadyAt = 0, errorDeg = meta.aim.FirstShotError, headAim = false,
		burstLeft = 0, pauseUntil = 0, nextShotAt = 0, recoil = 0, lastShotAt = -10,
		waypoints = nil, wpIndex = 1, pathBusy = false, pathKind = nil, pathGoal = nil,
		lastRepath = -10, pathFails = 0, moveMode = "hold", strafeDir = Vector3.zero, strafeUntil = 0,
		lastMoveTarget = nil, lastMoveToAt = 0, progressPos = root.Position, progressAt = now,
		lastJump = 0, nextRoamAt = 0, nextDecisionAt = 0, roamRun = true, arrivedAt = 0,
		noise = nil, lookAt = nil, lookUntil = 0,
		spawnedAt = now, activeAt = now + 0.35, spawnPos = nil,
		forceField = nil, protectedUntil = now + Config.SpawnProtection.MaxSeconds,
		tracks = {}, animKey = nil, animTrack = nil,
		nextThink = now + 0.35 + meta.rng:NextNumber(0, 0.12), lastThink = now,
		dead = false,
		--  [fase 2] abatido / revivir
		downed = "", proneArmed = false, reviveFace = nil, downedSince = 0, nextStrugglePress = 0,
		--  [fase 3] postura (0 de pie, 1 agachado) y ventarron
		stance = 0, stanceTweens = {}, galeExposed = false, nextSkyCheck = 0,
		--  [IA v2] vueltas de decisiones (cache de enemigos) y ritmo de pensar
		thinkTick = 0, lod = 1, lastPathOkAt = now,
	}

	--  [tacticas] Su equipo propio (principal al azar + Ithaca + Glock).
	meta.regenPoints = 0		-- como un jugador: se reinicia al reaparecer
	state.followSide = meta.rng:NextNumber() < 0.5 and -4 or 4
	for _, name in ipairs(meta.loadout or Config.Loadout) do
		local info = getWeaponInfo(name)
		if info and info.cfg.Role == "Sniper" then
			state.viewDistance = math.max(Config.Perception.ViewDistance, info.cfg.MaxRange)
		end
		if info then
			state.weapons[name] = { info = info, mag = info.magSize, reserve = info.reserve }
		end
	end

	--  Animaciones desde el servidor (se replican solas a los clientes).
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	for key, id in pairs(meta.animIds or DEFAULT_ANIMS) do
		local animation = Instance.new("Animation")
		animation.AnimationId = id
		local ok, track = pcall(function() return animator:LoadAnimation(animation) end)
		if ok and track then
			track.Priority = Enum.AnimationPriority.Core
			track.Looped = key ~= "jump"
			state.tracks[key] = track
		end
	end

	--  Recibir dano: mira hacia quien le pego aunque no lo vea.
	local lastHealth = humanoid.Health
	humanoid.HealthChanged:Connect(function(health)
		local dropped = health < lastHealth
		lastHealth = health
		if dropped then state.lastDamageAt = os.clock() end		-- [tacticas] para la cobertura
		if not dropped or state.dead then return end
		local attackerId = tonumber(humanoid:GetAttribute("ACS_KillKillerUserId"))
		local attacker = attackerId and (Players:GetPlayerByUserId(attackerId) or Registry.byUserId(attackerId))
		--  [IA v2] Quien le pego pasa a ser su prioridad (ver perceive), aunque
		--  este peleando con otro.
		if attacker and attacker ~= bot then
			state.lastAttacker = attacker
			state.lastAttackerAt = os.clock()
		end
		if state.visible then return end
		local attackerChar = attacker and attacker.Character
		local attackerRoot = attackerChar and attackerChar:FindFirstChild("HumanoidRootPart")
		if attackerRoot then
			local t = os.clock()
			state.noise = { pos = attackerRoot.Position, at = t }
			state.lastDamagePos = attackerRoot.Position
			state.lookAt = attackerRoot.Position
			state.lookUntil = t + 2
		end
	end)

	--  [fase 2] DownedServer avisa los cambios de postura con este atributo.
	character:GetAttributeChangedSignal("DownedState"):Connect(function()
		applyDownedState(state)
	end)

	humanoid.Died:Connect(function()
		onBodyDied(state)
	end)

	return state
end

--  Lo que corre cuando alguien llama bot:LoadCharacter(). El RoundManager
--  lo hace para meterlo a la ronda (ensureRoundCharacter) y para sacarlo
--  (resetPlayerForLobby). Fuera de ronda el bot "esta en el menu": sin
--  cuerpo.
local function loadCharacter(bot)
	local meta = metas[bot]
	if not meta or meta.loading then return end
	meta.loading = true

	despawn(bot)
	if bot:GetAttribute("InRound") ~= true then
		meta.loading = false
		return
	end

	--  Un frame de espera a proposito: asi el primer sendToRoundSpawn del
	--  RoundManager no alcanza a mover un cuerpo que todavia no existe, y
	--  el bot aparece UNA sola vez, ya en su spawn (via CharacterAdded).
	local waited = 0
	repeat
		task.wait()
		waited += 1
	until meta.template or waited > 600
	if not metas[bot] or not bot.Parent or bot:GetAttribute("InRound") ~= true or not meta.template then
		meta.loading = false
		return
	end

	local character = meta.template:Clone()
	character.Name = bot.Name
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	humanoid.DisplayName = bot.DisplayName
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer
	humanoid.NameDisplayDistance = StarterPlayer.NameDisplayDistance
	humanoid.HealthDisplayDistance = StarterPlayer.HealthDisplayDistance
	humanoid.BreakJointsOnDeath = false
	humanoid.UseJumpPower = true
	humanoid.JumpPower = JUMP_POWER
	humanoid.WalkSpeed = WALK_SPEED
	humanoid.MaxHealth = 100
	humanoid.Health = 100

	local spawnCFrame = lobbySpawnPart and lobbySpawnPart.CFrame or CFrame.new(0, 50, 0)
	character:PivotTo(spawnCFrame + Vector3.new(0, 5, 0))

	local state = newBrain(bot, meta, character)
	if Config.SpawnProtection.Enabled then
		local forceField = Instance.new("ForceField")
		forceField.Visible = true
		forceField.Parent = character
		state.forceField = forceField
	end

	character.Parent = workspace
	pcall(function() root:SetNetworkOwner(nil) end)
	brains[bot] = state

	local first = nil
	for _, name in ipairs(allowedWeapons(state)) do first = first or name end
	if first then equipWeapon(state, first, os.clock()) end

	meta.loading = false
	--  Dispara CharacterAdded: el RoundManager lo manda a su spawn y
	--  MatchStats / FishEconomy se enganchan a su Humanoid.
	Registry.setCharacter(bot, character)
	dprint(bot.Name, "aparecio")
end

--==========================================================================
--  ALTA Y BAJA DE BOTS
--==========================================================================
local function addBot()
	if Registry.count() >= Config.MaxBots then
		return false, "Ya hay el maximo de bots (" .. Config.MaxBots .. ")"
	end
	local rng = Random.new()
	local name = generateName(rng)
	usedNames[string.lower(name)] = true
	nextUserId -= 1

	local aim = pickWeighted(Config.AimPresets, rng)
	local react = pickWeighted(Config.ReactionPresets, rng)
	--  [tacticas] Tipo de IA y arma principal al azar.
	local role = pickWeighted(Config.Roles or { { Kind = "Ataque", Label = "Ataque" } }, rng)
	--  [24/09] Algunos tipos de IA prefieren ciertas armas (el camper, las
	--  de larga distancia): se multiplican sus pesos.
	local primaryPool = Config.PrimaryPool
	if primaryPool and role.PreferPrimary then
		local adjusted = {}
		for _, item in ipairs(primaryPool) do
			table.insert(adjusted, { Name = item.Name, Weight = (item.Weight or 1) * (role.PreferPrimary[item.Name] or 1) })
		end
		primaryPool = adjusted
	end
	local primaryPick = primaryPool and pickWeighted(primaryPool, rng)
	local primary = primaryPick and primaryPick.Name or Config.Loadout[1]
	local loadout = { primary }
	for _, name in ipairs(Config.Secondary or { Config.Loadout[2], Config.Loadout[3] }) do
		table.insert(loadout, name)
	end
	local meta = { rng = rng, aim = aim, react = react, role = role, loadout = loadout,
		template = nil, animIds = nil, loading = false, joinAt = nil, regenPoints = 0 }

	--  El avatar se arma en segundo plano (CreateHumanoidModelFromDescription
	--  descarga la ropa). Para cuando le toque entrar a la ronda ya esta.
	task.spawn(function()
		local template, ids = buildTemplate(rng)
		meta.template = template
		meta.animIds = ids
	end)

	local bot = Registry.create({
		Name = name,
		DisplayName = name,
		UserId = nextUserId,
		LoadCharacter = loadCharacter,
	})
	metas[bot] = meta
	bot:SetAttribute("BotAim", aim.Label)
	bot:SetAttribute("BotReaction", react.Label)
	bot:SetAttribute("BotRole", role.Label)
	bot:SetAttribute("BotPrimary", primary)

	print(("[Bots] + %s | punteria: %s | reaccion: %s | IA: %s | arma: %s"):format(name, aim.Label, react.Label, role.Label, primary))
	return true, ("Entro %s (punteria %s, reaccion %s, IA %s, %s)"):format(name, aim.Label, react.Label, role.Label, primary)
end

local function removeBot(bot)
	if not Registry.isBot(bot) then return end
	despawn(bot)
	usedNames[string.lower(bot.Name)] = nil
	metas[bot] = nil
	Registry.remove(bot)
	print("[Bots] - " .. bot.Name)
end

Registry.Removing:Connect(function(bot)
	--  Por si alguien lo saca con Registry.remove / bot:Kick() directo.
	local state = brains[bot]
	brains[bot] = nil
	if state then state.dead = true end
	metas[bot] = nil
	usedNames[string.lower(bot.Name)] = nil
end)

--==========================================================================
--  ENTRAR A LA RONDA (como darle a JUGAR en el menu)
--==========================================================================
task.spawn(function()
	while true do
		task.wait(0.5)
		local now = os.clock()
		local phase = currentPhase()
		if Tac.regenTick then pcall(Tac.regenTick, now) end		-- [tacticas] regeneracion por bajas
		for _, bot in ipairs(Registry.list()) do
			local meta = metas[bot]
			if meta then
				local inRound = bot:GetAttribute("InRound") == true
				if phase == "Round" and not inRound and bot:GetAttribute("Eliminated") ~= true then
					if not meta.joinAt then
						meta.joinAt = now + rangeNumber(meta.rng, Config.Round.JoinDelay)
					elseif now >= meta.joinAt then
						meta.joinAt = now + 4		-- si no lo dejan entrar, reintenta
						local join = Registry.Round.Join
						if join then
							local ok, joined = pcall(join, bot)
							if ok and joined then
								meta.joinAt = nil
								dprint(bot.Name, "entro a la ronda")
							elseif not ok then
								warn("[Bots] Round.Join fallo para " .. bot.Name .. ": " .. tostring(joined))
							end
						end
					end
				else
					meta.joinAt = nil
				end
				--  Fuera de ronda no deberia tener cuerpo.
				if not inRound and brains[bot] and not meta.loading then
					despawn(bot)
				end
			end
		end
	end
end)

--  Los bots "oyen" los disparos de los jugadores.
Evt.Atirar.OnServerEvent:Connect(function(player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then return end
	--  [IA v2] Un bot en la linea de tiro del jugador la "siente" (la cabeza
	--  sigue la mira de ACS; es aproximado, por eso el radio es mas grande).
	local head = character:FindFirstChild("Head")
	if head and Tac.bulletWhiz then
		Tac.bulletWhiz(player, head.Position, head.CFrame.LookVector, 600, os.clock(), Tac.AI.WhizRadius * 1.4)
	end
	notifyNoise(root.Position, player, 1)
end)

--==========================================================================
--  CONTROL (panel de admin)
--==========================================================================
local control = BotSystem:FindFirstChild("BotControl")
if not control then
	control = Instance.new("BindableFunction")
	control.Name = "BotControl"
	control.Parent = BotSystem
end

control.OnInvoke = function(op)
	if op == "add" then
		return addBot()
	elseif op == "removeOne" then
		local list = Registry.list()
		local bot = list[#list]
		if not bot then return false, "No hay bots" end
		local name = bot.Name
		removeBot(bot)
		return true, "Salio " .. name
	elseif op == "removeAll" then
		local list = Registry.list()
		for _, bot in ipairs(list) do removeBot(bot) end
		return true, ("Se fueron %d bot(s)"):format(#list)
	elseif op == "count" then
		return true, Registry.count()
	end
	return false, "Operacion desconocida: " .. tostring(op)
end

print("[Bots] BotServer listo (maximo " .. Config.MaxBots .. " bots)")