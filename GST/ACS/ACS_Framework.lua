--==========================================================================
--  ACS_Framework  —  VERSION PARCHEADA (01/09/2026)
--  Base: "ACS FRAMEWORK 31082026"
--
--  Parches aplicados:
--    F-01  Ignore_Model dejo de crecer sin limite (era LA causa de que el
--          FPS bajara solo con el tiempo de partida). Lista base + tope +
--          reset por disparo.
--    F-02  Eliminada la conexion InputBegan que se creaba de nuevo en CADA
--          recarga de municion y nunca se desconectaba.
--    F-05  Los print de diagnostico pasan por dprint(). Con DEBUG = false
--          no llega nada al log. Antes un fusil a 700 RPM generaba ~12
--          prints por segundo POR JUGADOR.
--    F-06  El FOV ya no crea un Tween nuevo en cada frame: SetFOV() solo
--          tweenea cuando el objetivo cambia de verdad.
--    F-07  SightMark y LaserPoint se cachean en setup(). Antes se hacian
--          DOS GetDescendants() del arma completa en cada frame.
--    F-08  El bucle de "whizz" ya no recorre a todos los jugadores en cada
--          frame por cada bala: sale con break en cuanto encuentra uno.
--    F-15  GrenadeTraj.Start se llamaba DOS veces seguidas.
--    F-16  WaistJ no estaba declarado: la pose de cintura del
--          BindToRenderStep corria 60 veces por segundo sin hacer nada.
--
--  10/09/2026  ->  buscar la marca  [F-42]
--    F-42  Proyectiles fisicos. CreateBullet le pasa el disparo a
--          ProjectileClient cuando el arma tiene Projectile = true.
--          Base: ACS_FRAMEWORK_10092026 (con municion Ricochet).
--    F-44  UpdateGui deja la municion actual en el atributo CurrentAmmo
--          del Tool, para que los ACS_Animations puedan leerla.
--==========================================================================

--  Interruptor de diagnostico. Ponelo en true solo cuando estes depurando.
local DEBUG = false	-- [29/09] apagado: con true imprime en cada postura/equipado
local function dprint(...)
	if DEBUG then print(...) end
end

--==========================================================================
--  [29/09/2026 RED] POSE DE LOS BRAZOS PARA LOS DEMAS (Evt.GunStance)
--  Antes cada vez que apuntabas, corrias o cambiabas de postura se mandaba
--  el ACS_Animations ENTERO al servidor y de ahi a todos los jugadores.
--  Los demas solo usan 2 CFrames por postura (brazo derecho e izquierdo):
--  ahora viajan solo esos. Global y dentro de su propia funcion para no
--  gastar locals del chunk (este script esta en el tope de 200).
--==========================================================================
;(function()
	local POSE_KEYS = {
		[0]  = { "SV_RightArmPos", "SV_LeftArmPos" },
		[2]  = { "RightAim", "LeftAim" },
		[1]  = { "RightHighReady", "LeftHighReady" },
		[-1] = { "RightLowReady", "LeftLowReady" },
		[-2] = { "RightPatrol", "LeftPatrol" },
		[3]  = { "RightSprint", "LeftSprint" },
	}
	-- [30/09/2026] Al apuntar (postura 2) el cano sale recto hacia donde
	-- miras: ReplicatedStorage.AimPose endereza RightAim/LeftAim (antes
	-- quedaba 15-20 grados hacia arriba visto desde fuera). Se carga la
	-- primera vez que hace falta; sin el modulo, la pose va como antes.
	local aimPose = nil
	local function levelAim(anim, right, left)
		if aimPose == nil then
			local ok, mod = pcall(function()
				return require(game:GetService("ReplicatedStorage"):FindFirstChild("AimPose"))
			end)
			aimPose = (ok and type(mod) == "table") and mod or false
		end
		if not aimPose then return right, left end
		local char = game:GetService("Players").LocalPlayer.Character
		local tool = char and char:FindFirstChildOfClass("Tool")
		local settings = tool and tool:FindFirstChild("ACS_Settings")
		local data = nil
		if settings and settings:IsA("ModuleScript") then
			local okS, result = pcall(require, settings)
			if okS and type(result) == "table" then data = result end
		end
		local okL, r, l = pcall(aimPose.Level, anim, right, left, char, data, tool and tool.Name)
		if okL then return r, l end
		return right, left
	end

	function LL_StancePose(stance, anim)
		if type(anim) ~= "table" then return anim end
		local keys = POSE_KEYS[stance]
		if not keys then return {} end
		local right, left = anim[keys[1]], anim[keys[2]]
		if stance == 2 then
			right, left = levelAim(anim, right, left)
		end
		return { [keys[1]] = right, [keys[2]] = left }
	end
end)()

--==========================================================================
--  [29/09/2026] SONIDO DE TUS DISPAROS
--  Antes cada tiro hacia Muzzle.Fire:Play() sobre el MISMO sonido: al
--  llegar el segundo tiro se cortaba el primero de golpe y en rafaga se oia
--  raro. Ahora cada tiro es una copia: la cola del anterior sigue, pero
--  baja de volumen en un instante (TailDuck) para que no se amontonen, y
--  nunca suenan mas de MaxTails a la vez. Global y en su propia funcion
--  para no gastar locals del chunk.
--==========================================================================
;(function()
	local TweenService = game:GetService("TweenService")
	local Debris = game:GetService("Debris")
	local SHOT = {
		MaxTails = 3,		-- copias sonando a la vez (el tiro nuevo + 2 colas)
		TailDuck = 0.35,	-- al salir un tiro, las colas anteriores bajan a esto
		DuckTime = 0.06,	-- segundos del bajon (corto para que no se note)
	}
	local duckInfo = TweenInfo.new(SHOT.DuckTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tails = setmetatable({}, { __mode = "k" })	-- [sonido original] = { copias }

	--  [30/09] mods (opcional): el ModTable del arma. Si la municion toca
	--  el sonido (subsonica), la copia sale con su volumen, tono y graves.
	function LL_PlayShot(template, mods)
		if typeof(template) ~= "Instance" or not template:IsA("Sound") then return end
		local list = tails[template]
		if not list then
			list = {}
			tails[template] = list
		end
		for i = #list, 1, -1 do
			if not list[i].Parent or not list[i].IsPlaying then table.remove(list, i) end
		end
		while #list >= SHOT.MaxTails do
			table.remove(list, 1):Destroy()
		end
		for _, previous in ipairs(list) do
			TweenService:Create(previous, duckInfo, { Volume = previous.Volume * SHOT.TailDuck }):Play()
		end
		local copy = template:Clone()
		copy.Name = template.Name .. "_Tiro"
		copy.Looped = false
		copy.Parent = template.Parent
		if type(mods) == "table" then
			local v = tonumber(mods.ShotVolume) or 1
			local p = tonumber(mods.ShotPitch) or 1
			local b = tonumber(mods.ShotBass) or 0
			if v ~= 1 then copy.Volume = copy.Volume * v end
			if p ~= 1 then copy.PlaybackSpeed = copy.PlaybackSpeed * p end
			if b ~= 0 then
				local eq = Instance.new("EqualizerSoundEffect")
				eq.Name = "Municion"
				eq.LowGain = math.clamp(b, -80, 10)
				eq.MidGain = 0
				eq.HighGain = 0
				eq.Parent = copy
			end
		end
		copy:Play()
		table.insert(list, copy)
		local length = template.TimeLength
		Debris:AddItem(copy, (length > 0 and length / math.max(copy.PlaybackSpeed, 0.1) or 3) + 0.5)
	end
end)()

local Players = game:GetService("Players")

repeat
	task.wait()
until Players.LocalPlayer.Character

local plr 			= Players.LocalPlayer
local char 			= plr.Character or plr.CharacterAdded:Wait()
local mouse 		= plr:GetMouse()
local cam 			= workspace.CurrentCamera

local User 			= game:GetService("UserInputService")
local CAS 			= game:GetService("ContextActionService")

-- [CONTROLES 30/09/2026] Teclas y botones que el jugador puede cambiar en
-- Configuraciones > CONTROLES (ReplicatedStorage.Keybinds). Todas las
-- acciones de aqui se enlazan con _G.LL_Bind(nombre, fn, tactil, teclas de
-- fabrica...): usa las del jugador y se re-enlaza sola si las cambia. Sin el
-- modulo usa las de fabrica. Global y sin locals: este chunk esta al limite
-- de 200 locals.
pcall(require, game:GetService("ReplicatedStorage"):WaitForChild("Keybinds", 10))
if type(_G.LL_Bind) ~= "function" then
	function _G.LL_Bind(name, fn, touch, ...) CAS:BindAction(name, fn, touch, ...) end
end
local Run 			= game:GetService("RunService")
local TS 			= game:GetService('TweenService')
local Debris 		= game:GetService("Debris")
local PhysicsService= game:GetService("PhysicsService")

local RS 			= game:GetService("ReplicatedStorage")
local ACS_Workspace = workspace:WaitForChild("ACS_WorkSpace")
local Engine 		= RS:WaitForChild("ACS_Engine")
local Evt 			= Engine:WaitForChild("Events")
local Mods 			= Engine:WaitForChild("Modules")
local HUDs 			= Engine:WaitForChild("HUD")
local Essential 	= Engine:WaitForChild("Essential")
local ArmModel 		= Engine:WaitForChild("ArmModel")
local GunModels 	= Engine:WaitForChild("GunModels")
local AttModels 	= Engine:WaitForChild("AttModels")
local AttModules  	= Engine:WaitForChild("AttModules")
local Rules			= Engine:WaitForChild("GameRules")
local PastaFx		= Engine:WaitForChild("FX")

local gameRules		= require(Rules:WaitForChild("Config"))
local SpringMod 	= require(Mods:WaitForChild("Spring"))
local HitMod 		= require(Mods:WaitForChild("Hitmarker"))
-- Version segura: si el modulo falla, el ACS sigue funcionando igual
local GrenadeTraj = { Start = function() end, Stop = function() end }

task.spawn(function()
	local ok, mod = pcall(function()
		local m = game:GetService("ReplicatedStorage"):WaitForChild("GrenadeTrajectory", 5)
		return m and require(m) or nil
	end)
	if ok and type(mod) == "table" and mod.Start then
		GrenadeTraj = mod
	else
		warn("[GrenadeTraj] No se pudo cargar el modulo:", mod)
	end
end)
local WeaponTool
local WeaponData
local AnimData
local Ammo = 0
local StoredAmmo = 0
local MaxAmmo = 0
local Thread 		= require(Mods:WaitForChild("Thread"))
local Ultil			= require(Mods:WaitForChild("Utilities"))
local ACS_Client 	= char:WaitForChild("ACS_Client")

local Equipped 		= 0
local Primary 		= ""
local Secondary 	= ""
local Grenades 		= ""

local GreAmmo = 0

-- Nota: el original redeclaraba aqui  local WeaponInHand, WeaponTool,
-- WeaponData, AnimData  creando un SEGUNDO juego de variables que
-- sombreaba a las de arriba. Se dejo un solo juego.
local WeaponInHand
local ViewModel, AnimPart, LArm, RArm, LArmWeld, RArmWeld, GunWeld
local SightData, BarrelData, UnderBarrelData, OtherData
local generateBullet = 1
local BSpread
local RecoilPower
local LastSpreadUpdate = time()
local SE_GUI
local SKP_01 = Evt.AcessId:InvokeServer(plr.UserId)

local CHup, CHdown, CHleft, CHright = UDim2.new(),UDim2.new(),UDim2.new(),UDim2.new()

local charspeed 	= 0
local running 		= false
local runKeyDown 	= false
local aimming 		= false
local shooting 		= false
local reloading 	= false
local mouse1down 	= false
local pumpCooldown = false  -- bloqueo de Pump Action
local boltCooldown = false  -- bloqueo de Bolt Action
local isCharging    = false
local AnimDebounce 	= false
local CancelReload 	= false
local SafeMode		= false
local JumpDelay 	= false
local NVG 			= false
local NVGdebounce 	= false
local GunStance 	= 0
local AimPartMode 	= 1
local CheckingMag	= false
local Healing		= false
local IsStanced		= false

local SightAtt		= nil
local reticle		= nil
local CurAimpart 	= nil
local ActiveChargeSound = nil
local ActiveFullSound  = nil

local BarrelAtt 	= nil
local Suppressor 	= false
local FlashHider 	= false

local UnderBarrelAtt= nil

local OtherAtt 		= nil

local LaserAtt 		= false
local LaserActive	= false
local IRmode		= false
local IREnable		= false
local LaserDist 	= 0
local Laser 		= nil
local Pointer 		= nil

local TorchAtt 		= false
local TorchActive 	= false

local BipodAtt 		= false
local CanBipod 		= false
local BipodActive 	= false

local GRDebounce 	= false
local CookGrenade 	= false

local ToolEquip 	= false
local Sens 			= 50

-- [SETTINGS] Sensibilidad al apuntar desde el menu de configuraciones.
-- Se guarda en ClientSettings, que a su vez la persiste en DataStore.
-- Si el modulo no existe, Sens se queda en 50 y ACS funciona como siempre.
local AimSettings = nil
do
	local ok, module = pcall(function()
		return require(game:GetService("ReplicatedStorage"):WaitForChild("ClientSettings", 15))
	end)

	if ok and module then
		AimSettings = module
		Sens = AimSettings:Get("AimSensitivity") or Sens

		AimSettings:OnChanged("AimSensitivity", function(value)
			Sens = value
			-- [15/09] Se aplica en caliente solo si estas apuntando (ApplyAimSens
			-- lo revisa). Si no, el valor entra en el siguiente ADS.
			if ApplyAimSens then ApplyAimSens() end
		end)
		AimSettings:OnChanged("ScopeSensitivity", function()
			if ApplyAimSens then ApplyAimSens() end
		end)
	end
end
local Power 		= 150

local BipodCF 		= CFrame.new()
local NearZ 		= CFrame.new(0,0,-.5)

--------------------mods

local ModTable = {

	camRecoilMod 	= {
		RecoilTilt 	= 1,
		RecoilUp 	= 1,
		RecoilLeft 	= 1,
		RecoilRight = 1
	}

	,gunRecoilMod	= {
		RecoilUp 	= 1,
		RecoilTilt 	= 1,
		RecoilLeft 	= 1,
		RecoilRight = 1
	}

	,ZoomValue 		= 70
	,Zoom2Value 	= 70
	,AimRM 			= 1
	,SpreadRM 		= 1
	,DamageMod 		= 1
	,minDamageMod 	= 1

	,MinRecoilPower 			= 1
	,MaxRecoilPower 			= 1
	,RecoilPowerStepAmount 		= 1

	,MinSpread 					= 1
	,MaxSpread 					= 1
	,AimInaccuracyStepAmount 	= 1
	,AimInaccuracyDecrease 		= 1
	,WalkMult 					= 1
	,adsTime 					= 1
	,MuzzleVelocity 			= 1

	--  Peso del arma / accesorios sobre el movimiento del jugador.
	--  OJO: WalkMult de arriba es dispersion al caminar, no velocidad.
	,MoveSpeedMult 				= 1
	,JumpPowerMult 				= 1

	--==================================================================
	--  MUNICION (accesorio de categoria "Ammo")
	--  No lleva modelo ni Node: solo cambia propiedades de la bala.
	--  AmmoType  etiqueta informativa ("Incendiaria", "Perforante"...)
	--  BurnRatio fraccion del dano que se convierte en puntos de
	--            quemadura. 0 = municion normal.
	--==================================================================
	,AmmoType 					= ""
	,BurnRatio 					= 0

	--  RicochetBounces  cuantas veces puede rebotar la bala contra el
	--                   escenario antes de morir. 0 = municion normal.
	--  RicochetEnergy   que fraccion de la velocidad conserva en cada
	--                   rebote. 1 = rebota sin perder nada.
	,RicochetBounces 			= 0
	,RicochetEnergy 			= 0.8

	--  [F-50] MUNICION PERFORANTE
	--  PenetrateHumanoids     true = la bala atraviesa a todo humanoide
	--                         que toque, sin limite, danando a cada uno.
	--  PenetrateWalls         cuantas PIEZAS de escenario puede cruzar
	--                         antes de quedarse. 0 = municion normal.
	--  PenetrationDamageKeep  dano que conserva tras cruzar un cuerpo.
	--  WallDamageKeep         dano que conserva tras cruzar una pieza.
	,PenetrateHumanoids 		= false
	,PenetrateWalls 			= 0
	,PenetrationDamageKeep 		= 1
	,WallDamageKeep 			= 1

	--  [30/09] MUNICIONES NUEVAS (subsonica, vortice, curva)
	--  FixedMuzzleVelocity  velocidad FIJA de la bala (misma unidad que el
	--                       MuzzleVelocity del arma). 0 = normal.
	--  HideTracer           sin estela ni brillo, y sin bala replicada.
	--                       Tambien lo declara el silenciador.
	--  ShotVolume/ShotPitch multiplicadores del sonido del disparo.
	--  ShotBass             dB de graves del disparo (negativo = menos).
	--  Homing               module.Homing de la Municion Curva, o false.
	,FixedMuzzleVelocity 		= 0
	,HideTracer 				= false
	,ShotVolume 				= 1
	,ShotPitch 					= 1
	,ShotBass 					= 0
	,Homing 					= false
}

--------------------mods

local maincf 		= CFrame.new() --weapon offset of camera
local guncf  		= CFrame.new() --weapon offset of camera
local larmcf 		= CFrame.new() --left arm offset of weapon
local rarmcf 		= CFrame.new() --right arm offset of weapon

local gunbobcf		= CFrame.new()
local recoilcf 		= CFrame.new()
local aimcf 		= CFrame.new()
local AimTween 		= TweenInfo.new(
	0.2,
	Enum.EasingStyle.Linear,
	Enum.EasingDirection.InOut,
	0,
	false,
	0
)

--==========================================================================
--  [F-01] LISTA DE IGNORADOS DE LOS RAYCASTS
--
--  Antes:  local Ignore_Model = {cam,char,ACS_Workspace.Client,ACS_Workspace.Server}
--          y cada impacto ignorable (accesorio, casco, chaleco, parte
--          transparente) hacia table.insert() sin que nada la vaciara.
--          A los 20 minutos de partida la tabla tenia miles de entradas:
--          retenia partes ya destruidas (fuga de memoria literal) y cada
--          raycast tenia que filtrar contra toda esa lista.
--
--  Ahora:  BaseIgnore es lo unico permanente. Ignore_Model se reinicia al
--          empezar cada bala / cada golpe cuerpo a cuerpo, y tiene tope.
--==========================================================================
local BaseIgnore   = {cam, char, ACS_Workspace.Client, ACS_Workspace.Server}
local Ignore_Model = table.clone(BaseIgnore)
local MAX_IGNORE   = 64

-- Devuelve la lista a su estado base. Se reutiliza LA MISMA tabla porque
-- otras funciones (y HitMod.HitEffect) la tienen capturada como upvalue.
local function ResetIgnore()
	table.clear(Ignore_Model)
	table.move(BaseIgnore, 1, #BaseIgnore, 1, Ignore_Model)
end

-- Agrega un ignorado con tope. Si se pasa, reinicia en vez de crecer.
local function AddIgnore(inst)
	if not inst then return end
	if #Ignore_Model >= MAX_IGNORE then ResetIgnore() end
	table.insert(Ignore_Model, inst)
end

--==========================================================================
--  [F-06] CONTROL DEL FOV
--
--  Antes el RenderStepped hacia  TS:Create(cam,AimTween,{FieldOfView=X}):Play()
--  en cada frame y en 3 ramas distintas: 60 objetos Tween por segundo
--  tirados a la basura, cada uno pisando al anterior a mitad de camino
--  (parte de por que el ADS se sentia pegajoso).
--==========================================================================
local CurrentFOVGoal = -1
local ActiveFOVTween

local function SetFOV(goal)
	if CurrentFOVGoal == goal then return end
	CurrentFOVGoal = goal
	if ActiveFOVTween then ActiveFOVTween:Cancel() end
	ActiveFOVTween = TS:Create(cam, AimTween, {FieldOfView = goal})
	ActiveFOVTween:Play()
end

--==========================================================================
--  [F-07] CACHE DE PARTES DEL ARMA
--
--  El RenderStepped recorria WeaponInHand:GetDescendants() DOS veces por
--  frame (una para "SightMark", otra para "LaserPoint"). Cada llamada
--  construye una tabla nueva con todas las partes del arma. Los nombres no
--  cambian mientras el arma este equipada, asi que se cachean en setup().
--==========================================================================
local SightMarks  = {}
local LaserPoints = {}

--  [F-06 bis] Mismo problema que el FOV, pero con el icono del bipode.
local LastBipodColor = nil
local function SetBipodHUD(color, transparency)
	if LastBipodColor == color then return end
	LastBipodColor = color
	if SE_GUI then
		TS:Create(SE_GUI.GunHUD.Att.Bipod, TweenInfo.new(.1,Enum.EasingStyle.Linear), {ImageColor3 = color, ImageTransparency = transparency}):Play()
	end
end

local ModStorageFolder 	= plr.PlayerGui:FindFirstChild('ModStorage') or Instance.new('Folder')
ModStorageFolder.Parent = plr.PlayerGui
ModStorageFolder.Name 	= 'ModStorage'

function RAND(Min, Max, Accuracy)
	local Inverse = 1 / (Accuracy or 1)
	return (math.random(Min * Inverse, Max * Inverse) / Inverse)
end

SE_GUI = HUDs:WaitForChild("StatusUI"):Clone()
SE_GUI.Parent = plr.PlayerGui

local BloodScreen 		= TS:Create(SE_GUI.Efeitos.Health, TweenInfo.new(1,Enum.EasingStyle.Circular,Enum.EasingDirection.InOut,-1,true), {Size =  UDim2.new(1.2,0,1.4,0)})
local BloodScreenLowHP 	= TS:Create(SE_GUI.Efeitos.LowHealth, TweenInfo.new(1,Enum.EasingStyle.Circular,Enum.EasingDirection.InOut,-1,true), {Size =  UDim2.new(1.2,0,1.4,0)})

local Crosshair = SE_GUI.Crosshair

local RecoilSpring = SpringMod.new(Vector3.new())
RecoilSpring.d = .1
RecoilSpring.s = 20

local cameraspring = SpringMod.new(Vector3.new())
cameraspring.d	= .5
cameraspring.s	= 20

local SwaySpring = SpringMod.new(Vector3.new())
SwaySpring.d = .25
SwaySpring.s = 20

local TWAY, XSWY, YSWY = 0,0,0

local oldtick = tick()
local xTilt = 0
local yTilt = 0
local lastPitch = 0
local lastYaw = 0

local Stance = Evt.Stance
local Stances = 0
local Virar = 0
local CameraX = 0
local CameraY = 0

local Sentado 		= false
local Swimming		= false
local falling 		= false
local cansado 		= false
local Crouched 		= false
local Proned		= false
local Steady 		= false
local CanLean 		= true
local ChangeStance 	= true

--// Char Parts
local Humanoid = char:WaitForChild('Humanoid')
local Head = char:WaitForChild('Head')
local Torso = char:WaitForChild('UpperTorso')
local HumanoidRootPart = char:WaitForChild('HumanoidRootPart')

--==================================================================
--  SISTEMA DE MOVIMIENTO — bunny hop + peso del arma   11/09/2026
--
--  Todo va envuelto en una funcion anonima que se ejecuta sola: el
--  chunk principal del ACS_Framework esta pegado al limite de 200
--  locals de Luau, asi que las variables de estado de aqui dentro
--  pertenecen a esta funcion y no gastan cupo. Lo unico que sale
--  fuera son las tres funciones globales del final:
--
--      ApplyMoveSpeed()      recalcula WalkSpeed y JumpPower
--      MoveSysHopEnabled()   true si el bunny hop esta activo
--      MoveSysResetHop()     rompe la cadena de saltos a mano
--
--  Campos NUEVOS y OPCIONALES del ACS_Settings de cada arma:
--      MoveSpeedMult     1 = normal, 0.8 = pesada, 1.1 = ligera
--      AimMoveSpeedMult  extra al apuntar (se multiplica al anterior)
--      JumpPowerMult     1 = normal, <1 = saltas menos con esa arma
--  Si el arma no los declara, valen 1 y nada cambia.
--
--  Campos NUEVOS y OPCIONALES de un modulo de accesorio:
--      MoveSpeedMult, JumpPowerMult   (se acumulan multiplicando)
--
--  OJO: WalkMult (que ya existia) NO es esto. Ese multiplica la
--  dispersion al caminar. Este bloque no lo toca.
--==================================================================
;(function()

	local MOVE = {
		Enabled  = true,
		Debug    = false,
		MaxSpeed = 60,      -- tope duro del WalkSpeed final, por seguridad

		Weapon = {
			Enabled       = true,
			Min           = 0.55,   -- clamp del multiplicador acumulado
			Max           = 1.45,
			AffectsSprint = true,   -- el peso tambien frena el sprint
			AffectsCrouch = true,
			AffectsProne  = false,  -- tumbado ya vas lentisimo, no castigar mas
			AffectsJump   = true,   -- JumpPowerMult del arma
		},

		Hop = {
			Enabled         = true,
			ChainWindow     = 0.35, -- segundos tras tocar suelo para encadenar
			GainPerHop      = 2.5,  -- studs/s que suma cada salto encadenado
			MaxBonus        = 12,   -- tope del bono acumulado
			FirstHopCounts  = false,-- el primer salto no da nada
			RequireMoving   = true, -- saltar en el sitio no cuenta
			ScaleWithWeapon = true, -- un arma pesada tambien recorta el bono
			KeepWhileAiming = false,-- apuntar rompe la cadena
			AllowInjured    = false,-- herido no puedes encadenar
		},
	}

	----------------------------------------------------------------
	--  Estado interno
	----------------------------------------------------------------
	local hopChain = 0      -- saltos encadenados (1 = el primero)
	local hopBonus = 0      -- studs/s extra que aporta la cadena
	local grounded = true
	local lastLand = 0

	----------------------------------------------------------------
	--  Otros sistemas que mandan sobre el WalkSpeed
	--
	--  DownedClient reescribe WalkSpeed cada frame mientras estas
	--  abatido, y StatusFxClient hace lo mismo con el hielo solido.
	--  Si escribimos encima nos peleamos con ellos, asi que aqui
	--  soltamos el control por completo.
	----------------------------------------------------------------
	local function otherSystemOwnsSpeed()
		if not char or not char.Parent then return true end
		local ds = char:GetAttribute("DownedState")
		if type(ds) == "string" and ds ~= "" then return true end
		if char:GetAttribute("FreezeLocked") == true then return true end
		if char:GetAttribute("Sliding") == true then return true end      -- [SLIDE]
		return false
	end

	local function isInjured()
		return script.Parent:GetAttribute("Injured") and true or false
	end

	----------------------------------------------------------------
	--  Velocidad base segun postura. Replica exactamente lo que
	--  hacian Stand / Crouch / Prone antes de este parche.
	----------------------------------------------------------------
	local function baseSpeed()
		local injured = isInjured()

		if Stances == 2 then
			if ACS_Client:GetAttribute("Surrender") then
				return 0, false
			end
			return (gameRules.ProneWalksSpeed or 3), false

		elseif Stances == 1 then
			if injured then
				return (gameRules.InjuredCrouchWalkSpeed or 4), false
			end
			return (gameRules.CrouchWalkSpeed or 8), false

		elseif runKeyDown then
			return (gameRules.RunWalkSpeed or 24), true

		elseif Steady then
			return (gameRules.SlowPaceWalkSpeed or 8), true

		elseif injured then
			return (gameRules.InjuredWalksSpeed or 10), true
		end

		return (gameRules.NormalWalkSpeed or 16), true
	end

	----------------------------------------------------------------
	--  Multiplicador de peso: arma + accesorios
	----------------------------------------------------------------
	local function weaponMult()
		if not (MOVE.Weapon.Enabled and WeaponData) then return 1 end

		local m = tonumber(WeaponData.MoveSpeedMult) or 1
		if aimming then
			m = m * (tonumber(WeaponData.AimMoveSpeedMult) or 1)
		end
		m = m * (tonumber(ModTable.MoveSpeedMult) or 1)
		m = math.clamp(m, MOVE.Weapon.Min, MOVE.Weapon.Max)

		if Stances == 2 and not MOVE.Weapon.AffectsProne  then return 1 end
		if Stances == 1 and not MOVE.Weapon.AffectsCrouch then return 1 end
		if runKeyDown  and not MOVE.Weapon.AffectsSprint  then return 1 end

		return m
	end

	local function jumpPowerFor(mult)
		if Stances ~= 0 then return 0 end

		local jp = gameRules.JumpPower or 50
		if MOVE.Weapon.Enabled and MOVE.Weapon.AffectsJump and WeaponData then
			local m = (tonumber(WeaponData.JumpPowerMult) or 1)
				* (tonumber(ModTable.JumpPowerMult) or 1)
			jp = jp * math.clamp(m, MOVE.Weapon.Min, MOVE.Weapon.Max)
		end
		return jp
	end

	----------------------------------------------------------------
	--  ApplyMoveSpeed — unico sitio del framework que escribe
	--  WalkSpeed y JumpPower. Solo escribe si el valor cambia, para
	--  no pisarle la base a StatusFxClient frame a frame.
	----------------------------------------------------------------
	function ApplyMoveSpeed()
		if not MOVE.Enabled then return end

		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then return end
		if otherSystemOwnsSpeed() then return end

		local base, hopAllowed = baseSpeed()
		local mult = weaponMult()

		local bonus = 0
		if hopAllowed and hopBonus > 0 then
			bonus = hopBonus * (MOVE.Hop.ScaleWithWeapon and mult or 1)
		end

		local speed = math.clamp(base * mult + bonus, 0, MOVE.MaxSpeed)
		if math.abs(hum.WalkSpeed - speed) > 0.01 then
			hum.WalkSpeed = speed
		end

		local jp = jumpPowerFor(mult)
		if hum.UseJumpPower then
			if math.abs(hum.JumpPower - jp) > 0.01 then
				hum.JumpPower = jp
			end
		else
			-- equivalencia de Roblox: altura = potencia^2 / (2 * gravedad)
			local g = workspace.Gravity
			local h = (g > 0) and ((jp * jp) / (2 * g)) or 0
			if math.abs(hum.JumpHeight - h) > 0.01 then
				hum.JumpHeight = h
			end
		end

		if MOVE.Debug then
			dprint(string.format("[MOVE] ws=%.1f jp=%.1f mult=%.2f bono=%.1f cadena=%d",
				speed, jp, mult, hopBonus, hopChain))
		end
	end

	----------------------------------------------------------------
	--  Bunny hop
	----------------------------------------------------------------
	local function resetHop(reason)
		if hopChain == 0 and hopBonus == 0 then return end
		hopChain = 0
		hopBonus = 0
		if MOVE.Debug then dprint("[MOVE] cadena rota:", reason) end
		ApplyMoveSpeed()
	end

	local function canChain()
		if not (MOVE.Enabled and MOVE.Hop.Enabled) then return false end
		if Stances ~= 0 then return false end
		if Sentado or Swimming then return false end
		if otherSystemOwnsSpeed() then return false end
		if aimming and not MOVE.Hop.KeepWhileAiming then return false end
		if isInjured() and not MOVE.Hop.AllowInjured then return false end

		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then return false end
		if MOVE.Hop.RequireMoving and hum.MoveDirection.Magnitude < 0.1 then
			return false
		end
		return true
	end

	function MoveSysHopEnabled()
		return MOVE.Enabled and MOVE.Hop.Enabled
	end

	function MoveSysResetHop()
		resetHop("externo")
	end

	Humanoid.StateChanged:Connect(function(_, new)
		if new == Enum.HumanoidStateType.Landed then
			grounded = true
			lastLand = os.clock()

		elseif new == Enum.HumanoidStateType.Running
			or new == Enum.HumanoidStateType.RunningNoPhysics then
			if not grounded then
				grounded = true
				lastLand = os.clock()
			end

		elseif new == Enum.HumanoidStateType.Jumping then
			local now = os.clock()

			if not canChain() then
				hopChain = 0
			elseif grounded and hopChain > 0 and (now - lastLand) <= MOVE.Hop.ChainWindow then
				hopChain = hopChain + 1
			else
				hopChain = 1   -- arranca cadena nueva: este salto no suma
			end

			local steps = hopChain - (MOVE.Hop.FirstHopCounts and 0 or 1)
			if steps < 0 then steps = 0 end
			hopBonus = math.clamp(steps * MOVE.Hop.GainPerHop, 0, MOVE.Hop.MaxBonus)

			grounded = false
			ApplyMoveSpeed()

		elseif new == Enum.HumanoidStateType.Freefall then
			grounded = false

		elseif new == Enum.HumanoidStateType.Dead
			or new == Enum.HumanoidStateType.Seated
			or new == Enum.HumanoidStateType.FallingDown
			or new == Enum.HumanoidStateType.Ragdoll
			or new == Enum.HumanoidStateType.PlatformStanding then
			resetHop("estado")
		end
	end)

	-- Cuando otro sistema suelta el control (te levantan de abatido,
	-- se rompe el hielo) o cambia el estado de herido, hay que
	-- recalcular: si no, te quedas con la velocidad que dejo el.
	char:GetAttributeChangedSignal("DownedState"):Connect(function()
		resetHop("abatido")
		task.defer(ApplyMoveSpeed)
	end)

	char:GetAttributeChangedSignal("FreezeLocked"):Connect(function()
		task.defer(ApplyMoveSpeed)
	end)

	script.Parent:GetAttributeChangedSignal("Injured"):Connect(function()
		ApplyMoveSpeed()
	end)

	-- Vigilante barato: solo hace algo mientras hay cadena viva y
	-- estas en el suelo. Con hopChain a 0 sale en la primera linea.
	Run.Heartbeat:Connect(function()
		if hopChain <= 0 then return end
		if not grounded then return end

		if (os.clock() - lastLand) > MOVE.Hop.ChainWindow then
			resetHop("ventana")
		elseif not canChain() then
			resetHop("condicion")
		end
	end)

end)()

--==================================================================
--  DESLIZAMIENTO TACTICO  (slide tipo Warzone)          11/09/2026
--
--  Igual que el bloque MOVE de arriba: todo va dentro de una funcion
--  anonima que se ejecuta sola, porque el chunk principal del
--  ACS_Framework esta pegado al limite de 200 locals de Luau. Lo
--  unico que sale fuera son las funciones globales del final:
--
--      SlideTryStart()    intenta arrancar un slide. Devuelve true si arranco
--      SlideIsActive()    true mientras deslizas
--      SlideStop(motivo)  lo corta desde fuera
--      SlideNotifyRun(b)  le dice si la tecla de sprint sigue pulsada
--      SlideAllowsFire()  false si el slide bloquea el disparo
--      SlideAllowsAim()   false si el slide bloquea el ADS
--
--  COMO FUNCIONA
--    Esprintas (Shift) + pulsas C  ->  slide.
--    Durante el slide NO se toca el WalkSpeed desde ApplyMoveSpeed:
--    este bloque lo escribe frame a frame y mueve al personaje con
--    Humanoid:Move(). Por eso el parche 2 (una linea en
--    otherSystemOwnsSpeed) es OBLIGATORIO; sin el los dos sistemas se
--    pelean por el WalkSpeed y el slide se corta solo.
--
--    Al servidor se le manda postura 1 (agachado) con el Evt.Stance de
--    siempre, asi que los demas jugadores te ven bajo sin tocar una
--    sola linea del ACS_Server.
--
--  ATRIBUTO QUE EXPONE EN EL CHARACTER
--      Sliding  ->  true mientras deslizas
--    Cualquier otro sistema (StatusFxClient, DownedClient, lo que sea)
--    puede leerlo para apartarse.
--==================================================================
;(function()

	local SLIDE = {
		Enabled = true,
		Debug   = false,

		--  ARRANQUE
		--  OJO con MinSpeed: es el freno de verdad contra el encadenado,
		--  no el Cooldown. Tiene que quedar POR ENCIMA de EndSpeed, para
		--  que al acabar un slide te falte velocidad y tengas que correr
		--  un momento antes de poder soltar el siguiente.
		MinSpeed      = 12,    -- velocidad horizontal minima para poder deslizar
		BoostMult     = 1.75,  -- empujon inicial sobre tu velocidad al pulsar C
		MaxStartSpeed = 55,    -- tope de la velocidad inicial
		Cooldown      = 0.30,  -- segundos entre un slide y el siguiente

		--  DURANTE
		MaxTime       = 1.30,  -- tope duro de duracion, en segundos
		EndSpeed      = 9,     -- por debajo de esto el slide termina solo
		Friction      = 28,    -- studs/s^2 que pierde en llano
		SlopeGain     = 34,    -- cuanto frena la cuesta arriba / empuja la de bajada
		MaxSpeed      = 62,    -- tope absoluto, para que una bajada no te dispare
		SteerRate     = 2.6,   -- rad/s que puedes corregir la direccion con WASD
		AirGrace      = 0.25,  -- segundos en el aire antes de cortarlo

		--  QUE PUEDES HACER MIENTRAS DESLIZAS
		CanShoot      = true,
		CanAim        = false,
		JumpCancel    = true,  -- saltar corta el slide (el "slide cancel")

		--  COMO TERMINA
		EndsCrouched  = true,  -- true: acabas agachado. false: acabas de pie
		ResumeSprint  = true,  -- si sigues pulsando Shift, vuelves a esprintar
		ResetHopChain = true,  -- el slide rompe la cadena de bunny hop

		--  PRESENTACION
		CameraY       = -1.9,  -- altura de camara durante el slide (agachado es -1)
		CameraRoll    = 5,     -- grados de inclinacion lateral
		RollSpeed     = 9,     -- cuan rapido entra y sale esa inclinacion

		SoundId       = "",    -- "rbxassetid://XXXX"  o  ""  para que no suene
		SoundVolume   = 0.6,

		--  TERCERA PERSONA (lo que ven los demas)
		--  La barrida va en DOS posturas, no en una. El ACS_Server tweenea
		--  0.3 s entre postura y postura, asi que ese salto de la 3 a la 4
		--  es el que da la sensacion de movimiento: se te ve ENTRAR en la
		--  barrida en vez de aparecer ya tumbado de golpe.
		--  Pon PoseEntry = 1 para desactivarlo todo y que te vean agachado.
		PoseEntry     = 3,     -- al pulsar C: el cuerpo empieza a caer
		PoseSettle    = 4,     -- la barrida asentada
		SettleDelay   = 0.22,  -- cuanto tarda en pasar de una a otra

		--  AnimId: si le pones una animacion tuya, manda ella y se apaga
		--  todo el apaño de abajo. Es la opcion buena.
		AnimId        = "",

		--  Solo se usan cuando AnimId esta vacio: callan la animacion de
		--  correr para que las piernas no pedaleen encima de la postura.
		MuteWalkAnim  = true,
		ReloadAnimate = true,  -- al terminar, reinicia el script Animate
	}

	----------------------------------------------------------------
	--  Estado interno
	----------------------------------------------------------------
	local sliding     = false
	local slideDir    = Vector3.new(0, 0, 0)
	local slideSpeed  = 0
	local startedAt   = 0
	local lastEnd     = -1e9
	local airborneAt  = nil
	local sprintHeld  = false

	local roll        = 0
	local rollTarget  = 0

	local slideSound  = nil
	local slideAnim   = nil     -- Animation cacheada
	local slideTrack  = nil     -- AnimationTrack en curso
	local muted       = {}      -- tracks de locomocion que paramos
	local lastMute    = 0
	local posePhase   = 0       -- que postura de barrida mandamos la ultima vez
	local lastArmed   = nil     -- si ACS tenia el mando de los brazos

	local function sdprint(...)
		if SLIDE.Debug then dprint("[SLIDE]", ...) end
	end

	----------------------------------------------------------------
	--  Otros sistemas que mandan sobre el personaje
	----------------------------------------------------------------
	local function ownedByOther()
		if not char or not char.Parent then return true end
		local ds = char:GetAttribute("DownedState")
		if type(ds) == "string" and ds ~= "" then return true end
		if char:GetAttribute("FreezeLocked") == true then return true end
		return false
	end

	local function flatSpeed()
		local v = HumanoidRootPart.AssemblyLinearVelocity
		return Vector3.new(v.X, 0, v.Z).Magnitude
	end

	local function grounded()
		local st = Humanoid:GetState()
		return st == Enum.HumanoidStateType.Running
			or st == Enum.HumanoidStateType.RunningNoPhysics
			or st == Enum.HumanoidStateType.Landed
	end

	----------------------------------------------------------------
	--  Sonido y animacion (los dos opcionales)
	----------------------------------------------------------------
	local function playSound()
		if SLIDE.SoundId == "" then return end
		if not slideSound or not slideSound.Parent then
			slideSound = Instance.new("Sound")
			slideSound.Name       = "ACS_SlideSound"
			slideSound.SoundId    = SLIDE.SoundId
			slideSound.Volume     = SLIDE.SoundVolume
			slideSound.RollOffMaxDistance = 60
			slideSound.Parent     = HumanoidRootPart
		end
		slideSound.TimePosition = 0
		slideSound:Play()
	end

	local function stopSound()
		if slideSound and slideSound.Parent and slideSound.IsPlaying then
			slideSound:Stop()
		end
	end

	local function playAnim()
		if SLIDE.AnimId == "" then return end
		local animator = Humanoid:FindFirstChildOfClass("Animator")
		if not animator then return end

		if not slideAnim then
			slideAnim = Instance.new("Animation")
			slideAnim.AnimationId = SLIDE.AnimId
		end

		local ok, track = pcall(function()
			return animator:LoadAnimation(slideAnim)
		end)
		if ok and track then
			track.Priority = Enum.AnimationPriority.Action
			track.Looped   = true
			track:Play(0.08)
			slideTrack = track
		end
	end

	local function stopAnim()
		if slideTrack then
			pcall(function() slideTrack:Stop(0.15) end)
			slideTrack = nil
		end
	end

	----------------------------------------------------------------
	--  Callar la animacion de correr
	--
	--  El script Animate de Roblox reproduce idle/andar/correr con
	--  prioridad Core. Esa animacion mueve caderas y rodillas ENCIMA
	--  de la postura que escribe el servidor, asi que sin esto los
	--  demas te ven pedaleando las piernas mientras deslizas.
	--
	--  No se puede bajar el peso a cero: Roblox normaliza los pesos
	--  dentro de cada nivel de prioridad, y si solo hay un track en
	--  Core acaba pesando 1 aunque le pongas 0.001. Hay que pararlo.
	--
	--  Si pusiste AnimId, nada de esto hace falta: un track en
	--  prioridad Action pisa a Core el solo.
	----------------------------------------------------------------
	local function muteLocomotion()
		if not SLIDE.MuteWalkAnim or SLIDE.AnimId ~= "" then return end
		local animator = Humanoid:FindFirstChildOfClass("Animator")
		if not animator then return end
		for _, t in ipairs(animator:GetPlayingAnimationTracks()) do
			if t.Priority == Enum.AnimationPriority.Core and not muted[t] then
				muted[t] = true
				pcall(function() t:Stop(0.08) end)
			end
		end
	end

	--  Al terminar hay que devolverle el mando a Animate. Un Stop() a
	--  secas no vale: Animate cree que ese track sigue puesto y no lo
	--  vuelve a lanzar hasta que cambie de animacion. Reiniciar el
	--  script es la unica forma fiable de que se resincronice.
	local function unmuteLocomotion()
		if next(muted) == nil then return end
		muted = {}

		if not SLIDE.ReloadAnimate then return end
		local a = char:FindFirstChild("Animate")
		if not a or not a:IsA("BaseScript") then return end
		a.Disabled = true
		task.defer(function()
			if a and a.Parent then a.Disabled = false end
		end)
	end

	----------------------------------------------------------------
	--  Limpieza dura: solo apaga banderas. No toca posturas.
	--  La usan la muerte y el unset, donde el ACS ya recoloca todo.
	----------------------------------------------------------------
	local function hardReset()
		if not sliding then return end
		sliding    = false
		airborneAt = nil
		rollTarget = 0
		roll       = 0
		if char and char.Parent then
			char:SetAttribute("Sliding", false)
		end
		stopAnim()
		stopSound()
		unmuteLocomotion()
	end

	----------------------------------------------------------------
	--  Fin del slide
	--    forceStand = true  -> te levantas si o si (salto, aire, muerte)
	----------------------------------------------------------------
	local function stopSlide(reason, forceStand)
		if not sliding then return end

		sliding    = false
		airborneAt = nil
		rollTarget = 0
		posePhase  = 0
		lastEnd    = os.clock()
		char:SetAttribute("Sliding", false)

		stopAnim()
		stopSound()
		unmuteLocomotion()
		sdprint("fin:", reason, string.format("%.1f studs/s", slideSpeed))

		if Humanoid.Health <= 0 or ownedByOther() then
			roll = 0
			return
		end

		-- de pie o agachado
		local standUp = forceStand or (not SLIDE.EndsCrouched)
		if sprintHeld and SLIDE.ResumeSprint then standUp = true end

		Proned = false

		if standUp then
			Stances  = 0
			Crouched = false
			CameraY  = 0
			Stand()
		else
			Stances  = 1
			Crouched = true
			CameraY  = -1
			Crouch()
		end

		-- volver a esprintar si sigues pulsando la tecla
		local resumed = false
		if standUp and sprintHeld and SLIDE.ResumeSprint
			and not Swimming and not Sentado and not Healing
			and not script.Parent:GetAttribute("Injured") then

			runKeyDown = true
			resumed    = true

			if aimming then
				aimming = false
				ADS(aimming)
			end

			if not CheckingMag and not reloading and WeaponData
				and WeaponData.Type ~= "Grenade"
				and (GunStance == 0 or GunStance == 2 or GunStance == 3) then
				GunStance = 3
				Evt.GunStance:FireServer(GunStance, LL_StancePose(GunStance, AnimData))
				SprintAnim()
			end
		end

		-- si no vuelves al sprint, los brazos tienen que quedar en idle
		if not resumed then
			if not CheckingMag and not reloading and WeaponData
				and WeaponData.Type ~= "Grenade" and GunStance == 3 then
				GunStance = 0
				Evt.GunStance:FireServer(GunStance, LL_StancePose(GunStance, AnimData))
				IdleAnim()
			end
		end

		ApplyMoveSpeed()
	end

	----------------------------------------------------------------
	--  Arranque
	----------------------------------------------------------------
	local function tryStart()
		if not SLIDE.Enabled then return false end
		if sliding then return false end
		if not runKeyDown then return false end          -- solo se entra desde sprint
		if Stances ~= 0 then return false end
		if not ChangeStance then return false end
		if Swimming or Sentado or Healing then return false end
		if script.Parent:GetAttribute("Injured") then return false end
		if ownedByOther() then return false end
		if Humanoid.Health <= 0 then return false end
		if (os.clock() - lastEnd) < SLIDE.Cooldown then return false end
		if not grounded() then return false end
		if Humanoid.MoveDirection.Magnitude < 0.1 then return false end
		if flatSpeed() < SLIDE.MinSpeed then return false end

		-- direccion: hacia donde te mueves de verdad
		local dir = Humanoid.MoveDirection
		dir = Vector3.new(dir.X, 0, dir.Z)
		if dir.Magnitude < 0.05 then
			local look = HumanoidRootPart.CFrame.LookVector
			dir = Vector3.new(look.X, 0, look.Z)
		end
		if dir.Magnitude < 0.05 then return false end
		slideDir = dir.Unit

		local base = math.max(flatSpeed(), tonumber(gameRules.RunWalkSpeed) or 24)
		slideSpeed = math.clamp(base * SLIDE.BoostMult, 0, SLIDE.MaxStartSpeed)

		sliding    = true
		startedAt  = os.clock()
		airborneAt = nil
		sprintHeld = true                 -- venimos de sprint, la tecla esta abajo
		char:SetAttribute("Sliding", true)

		runKeyDown = false                -- el sprint termina aqui

		if SLIDE.ResetHopChain and MoveSysResetHop then
			MoveSysResetHop()
		end

		-- postura agachada: HUD, camara y Evt.Stance al servidor
		Virar    = 0
		CameraX  = 0
		CameraY  = SLIDE.CameraY
		Stances  = 1
		Crouched = true
		Proned   = false
		Lean()
		Crouch()

		-- postura de barrida para el resto del servidor. Crouch() acaba de
		-- mandar la 1; esta la pisa. Si PoseEntry vale 1 no mandamos nada.
		if SLIDE.PoseEntry ~= 1 then
			posePhase = SLIDE.PoseEntry
			Stance:FireServer(SLIDE.PoseEntry, 0)

			if SLIDE.PoseSettle ~= SLIDE.PoseEntry then
				-- El startedAt guardado evita que un slide viejo mande su
				-- fase 2 tarde y le pise la postura al slide siguiente.
				local thisSlide = startedAt
				task.delay(SLIDE.SettleDelay, function()
					if sliding and startedAt == thisSlide then
						posePhase = SLIDE.PoseSettle
						Stance:FireServer(SLIDE.PoseSettle, 0)
					end
				end)
			end
		end

		-- AnimBase es el esqueleto de brazos que monta ACS al equipar.
		-- Si existe, ACS manda en los brazos y el servidor no les pone
		-- la pose de barrida desarmada.
		lastArmed = (char:FindFirstChild("AnimBase") ~= nil)

		muteLocomotion()
		lastMute = os.clock()

		-- desde aqui el WalkSpeed lo escribimos nosotros
		Humanoid.WalkSpeed = slideSpeed

		if aimming and not SLIDE.CanAim then
			aimming = false
			ADS(aimming)
		end

		-- brazos: si puedes disparar, sacalos de la pose de sprint
		if SLIDE.CanShoot then
			if not CheckingMag and not reloading and WeaponData
				and WeaponData.Type ~= "Grenade" and GunStance == 3 then
				GunStance = 0
				Evt.GunStance:FireServer(GunStance, LL_StancePose(GunStance, AnimData))
				IdleAnim()
			end
		else
			mouse1down = false   -- si venias con el gatillo apretado, se suelta
		end

		playSound()
		playAnim()

		sdprint("inicio a", string.format("%.1f studs/s", slideSpeed))
		return true
	end

	----------------------------------------------------------------
	--  Un frame de slide
	----------------------------------------------------------------
	local function updateSlide(dt)
		if Humanoid.Health <= 0 or ownedByOther() or Swimming or Sentado then
			stopSlide("estado", true)
			return
		end

		local now = os.clock()
		if (now - startedAt) > SLIDE.MaxTime then
			stopSlide("tiempo")
			return
		end

		-- suelo / aire
		if grounded() then
			airborneAt = nil
		else
			airborneAt = airborneAt or now
			if (now - airborneAt) > SLIDE.AirGrace then
				stopSlide("aire", true)
				return
			end
		end

		-- pendiente: >0 subiendo, <0 bajando
		local slope = 0
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { char }
		local hit = workspace:Raycast(HumanoidRootPart.Position, Vector3.new(0, -6, 0), params)
		if hit then
			slope = -slideDir:Dot(hit.Normal)
		end

		slideSpeed = slideSpeed - (SLIDE.Friction + SLIDE.SlopeGain * slope) * dt
		slideSpeed = math.clamp(slideSpeed, 0, SLIDE.MaxSpeed)

		if slideSpeed <= SLIDE.EndSpeed then
			stopSlide("velocidad")
			return
		end

		-- correccion de direccion con WASD, limitada
		-- (ojo: esto se lee ANTES de nuestro Move, o sea que aqui
		--  MoveDirection todavia trae lo que pidio el jugador este frame)
		if SLIDE.SteerRate > 0 then
			local want = Humanoid.MoveDirection
			want = Vector3.new(want.X, 0, want.Z)
			if want.Magnitude > 0.05 then
				want = want.Unit
				local ang = math.acos(math.clamp(slideDir:Dot(want), -1, 1))
				if ang > 1e-4 then
					local t = math.min((SLIDE.SteerRate * dt) / ang, 1)
					local nd = slideDir:Lerp(want, t)
					if nd.Magnitude > 1e-4 then
						slideDir = nd.Unit
					end
				end
			end
		end

		-- inclinacion de camara segun cuanto deslizas de lado
		local cr = cam.CFrame.RightVector
		cr = Vector3.new(cr.X, 0, cr.Z)
		if cr.Magnitude > 1e-3 then
			rollTarget = math.rad(SLIDE.CameraRoll) * -slideDir:Dot(cr.Unit)
		end

		-- Si sacas o guardas el arma a mitad de barrida, hay que remandar
		-- la postura: el servidor decide ahi si pone los brazos de la
		-- barrida o se los deja a ACS, y sin remandarla se queda con lo
		-- que hubiera decidido al arrancar.
		local armedNow = (char:FindFirstChild("AnimBase") ~= nil)
		if armedNow ~= lastArmed then
			lastArmed = armedNow
			if posePhase ~= 0 and SLIDE.PoseEntry ~= 1 then
				Stance:FireServer(posePhase, 0)
			end
		end

		-- Animate puede cambiar de andar a correr a mitad del slide y
		-- lanzar un track nuevo. Se revisa cada 0.12 s, no cada frame.
		if (now - lastMute) > 0.12 then
			lastMute = now
			muteLocomotion()
		end

		Humanoid.WalkSpeed = slideSpeed
		Humanoid:Move(slideDir, false)
	end

	----------------------------------------------------------------
	--  RenderStep a 250: por debajo va "Camera Update" (200), asi que
	--  aqui la camara ya esta puesta y podemos inclinarla. Y el
	--  ControlModule de Roblox llama a Humanoid:Move en prioridad 100,
	--  o sea antes, asi que nuestro Move es el que manda.
	----------------------------------------------------------------
	Run:BindToRenderStep("ACS_Slide", 250, function(dt)
		if sliding then
			updateSlide(dt)
		end

		if math.abs(roll - rollTarget) > 1e-4 then
			roll = roll + (rollTarget - roll) * math.clamp(SLIDE.RollSpeed * dt, 0, 1)
		else
			roll = rollTarget
		end

		if math.abs(roll) > 1e-4 then
			cam.CFrame = cam.CFrame * CFrame.Angles(0, 0, roll)
		end
	end)

	----------------------------------------------------------------
	--  Slide cancel: saltar corta el slide en seco
	----------------------------------------------------------------
	Humanoid:GetPropertyChangedSignal("Jump"):Connect(function()
		if sliding and Humanoid.Jump and SLIDE.JumpCancel then
			stopSlide("salto", true)
		end
	end)

	Humanoid.Died:Connect(function()
		hardReset()
	end)

	char:GetAttributeChangedSignal("DownedState"):Connect(function()
		if sliding then stopSlide("abatido", true) end
	end)

	----------------------------------------------------------------
	--  API global
	----------------------------------------------------------------
	function SlideTryStart()
		return tryStart()
	end

	function SlideIsActive()
		return sliding
	end

	function SlideStop(reason)
		stopSlide(reason or "externo")
	end

	function SlideNotifyRun(down)
		sprintHeld = (down == true)
	end

	function SlideAllowsFire()
		if not sliding then return true end
		return SLIDE.CanShoot
	end

	function SlideAllowsAim()
		if not sliding then return true end
		return SLIDE.CanAim
	end

end)()

local RootJoint = char.LowerTorso:WaitForChild('Root')
local Neck = Head:WaitForChild('Neck')
--  [F-16] Esta linea NO existia. ApplyACSAnimationPose usaba WaistJ como
--  global nil, el guard "if joint" se lo tragaba sin error, y la pose de
--  cintura/lean simplemente nunca se aplicaba.
local WaistJ = Torso:WaitForChild('Waist')
local Right_Shoulder = char.RightUpperArm:WaitForChild('RightShoulder')
local Left_Shoulder = char.LeftUpperArm:WaitForChild('LeftShoulder')
local Right_Hip = char.RightUpperLeg:WaitForChild('RightHip')
local Left_Hip = char.LeftUpperLeg:WaitForChild('LeftHip')

local YOffset = Neck.C0.Y
local WaistYOffset = Neck.C0.Y
local CFNew, CFAng = CFrame.new, CFrame.Angles
local Asin = math.asin
local T = 0.15

--  [F-07 bis] Las rodillas tambien se buscaban con FindFirstChild en cada
--  frame dentro de ApplyACSAnimationPose. Se resuelven una sola vez.
local Right_Knee = char:FindFirstChild("RightLowerLeg") and char.RightLowerLeg:FindFirstChild("RightKnee")
local Left_Knee  = char:FindFirstChild("LeftLowerLeg")  and char.LeftLowerLeg:FindFirstChild("LeftKnee")

local function SetPoseTransform(joint, transform)
	if joint and joint.Parent then
		joint.Transform = transform
	end
end

local function ApplyACSAnimationPose()
	if not char.Parent or Humanoid.Health <= 0 then return end
	-- [16/09] Abatido (gateando / arrastrandose, con o sin arma): las
	-- animaciones las pone DownedClient. Si aqui se escribian caderas,
	-- rodillas, hombros, cuello y cintura cada frame, pisaban la animacion de
	-- arrastrarse armado y el cuerpo quedaba enterrado con los pies afuera.
	local downedState = char:GetAttribute("DownedState")
	if downedState ~= nil and downedState ~= "" then return end
	local leanAngle = math.rad(-30 * Virar)
	local poseAngle = 0
	if Stances == 1 then
		poseAngle = math.rad(-18)
	elseif Stances == 2 then
		poseAngle = math.rad(-90)
	end

	-- [16/09] Tumbado: el servidor YA gira el cuerpo -90 con el C0 del Root
	-- (Evt.Stance). Sumarle aqui otros -90 lo dejaba en -180: pelvis al reves,
	-- torso enterrado y solo los pies afuera; sobre todo al arrastrarse,
	-- porque la animacion de caminar reescribia este valor frame a frame y se
	-- alternaban la pose buena y la volteada. El cuello si se compensa (+90)
	-- para que la cabeza mire al frente.
	local rootAngle = (Stances == 2) and 0 or poseAngle
	SetPoseTransform(RootJoint, CFrame.Angles(rootAngle, 0, 0))
	SetPoseTransform(Neck, CFrame.Angles(-poseAngle, 0, leanAngle * 0.35))
	SetPoseTransform(WaistJ, CFrame.Angles(0, 0, leanAngle) * CFrame.Angles(poseAngle * 0.2, 0, 0))

	local armAngle = Stances == 2 and math.rad(-25) or (Stances == 1 and math.rad(-8) or 0)
	SetPoseTransform(Right_Shoulder, CFrame.Angles(armAngle, 0, 0))
	SetPoseTransform(Left_Shoulder, CFrame.Angles(armAngle, 0, 0))

	if Stances == 2 then
		SetPoseTransform(Right_Hip, CFrame.Angles(math.rad(18), 0, 0))
		SetPoseTransform(Left_Hip, CFrame.Angles(math.rad(18), 0, 0))
		SetPoseTransform(Right_Knee, CFrame.Angles(math.rad(-35), 0, 0))
		SetPoseTransform(Left_Knee, CFrame.Angles(math.rad(-35), 0, 0))
	else
		SetPoseTransform(Right_Hip, CFrame.new())
		SetPoseTransform(Left_Hip, CFrame.new())
		SetPoseTransform(Right_Knee, CFrame.new())
		SetPoseTransform(Left_Knee, CFrame.new())
	end
end

Run:BindToRenderStep("ACS Animation Pose", Enum.RenderPriority.Character.Value + 1, ApplyACSAnimationPose)
-- [16/09] Tumbado la pose se aplica tambien DESPUES del paso de animacion:
-- si no, al arrastrarse la animacion de caminar la pisaba en frames sueltos.
-- De pie y agachado queda como estaba.
Run.Stepped:Connect(function()
	if Stances == 2 then ApplyACSAnimationPose() end
end)

User.MouseIconEnabled 	= true
plr.CameraMode 			= Enum.CameraMode.Classic

cam.CameraType = Enum.CameraType.Custom
cam.CameraSubject = Humanoid

if gameRules.TeamTags then
	local tag = Essential.TeamTag:clone()
	tag.Parent = char
	tag.Disabled = false
end

function handleAction(actionName, inputState, inputObject)

	-- [SPRAY 29/09/2026] Soltar el click corta el First Aid Spray SIEMPRE,
	-- antes de cualquier return de aqui abajo (slide y demas).
	if actionName == "Fire" and SprayStop and (inputState == Enum.UserInputState.End
		or inputState == Enum.UserInputState.Cancel) then
		SprayStop()
	end

	-- ============================================================
	-- [SLIDE]  Deslizamiento tactico
	--   · Shift (sprint) + C  ->  slide
	--   · Mientras deslizas, C lo corta y el resto de teclas de
	--     postura se ignoran. Saltar lo cancela: de eso se encarga
	--     el propio bloque SLIDE, no hace falta tocarlo aqui.
	-- TIENE que ir aqui arriba, antes de Fire, ADS, Stand y Crouch:
	-- mas abajo los candados de CanShoot y CanAim no sirven de nada
	-- porque el input ya se proceso.
	-- ============================================================
	if actionName == "Run" and SlideNotifyRun then
		if inputState == Enum.UserInputState.Begin then
			SlideNotifyRun(true)
		elseif inputState == Enum.UserInputState.End then
			SlideNotifyRun(false)
		end
	end

	if SlideIsActive and SlideIsActive() then
		if actionName == "Crouch" and inputState == Enum.UserInputState.Begin then
			SlideStop("tecla")
			return
		end
		if actionName == "Stand" or actionName == "Crouch" or actionName == "Run"
			or actionName == "ToggleWalk" or actionName == "LeanLeft" or actionName == "LeanRight" then
			return
		end
		if actionName == "ADS" and not SlideAllowsAim() then
			return
		end
		if actionName == "Fire" and not SlideAllowsFire() then
			mouse1down = false
			return
		end
	end

	if actionName == "Crouch" and inputState == Enum.UserInputState.Begin
		and ChangeStance and not Swimming and not Sentado
		and SlideTryStart and SlideTryStart() then
		return
	end

	-- [MELEE SPRINT 22092026] SprintAnim() deja AnimDebounce en false todo
	-- el tiempo que corres; con melee se deja pasar el click igual.
	local meleeSprintFire = runKeyDown and GunStance == 3 and WeaponData
		and WeaponData.Type == "Melee" and WeaponData.MeleeWhileSprinting ~= false

	if actionName == "Fire" and inputState == Enum.UserInputState.Begin and (AnimDebounce or meleeSprintFire) then
		if Healing then return end

		if WeaponData and WeaponData.Type == "Medical" then
			-- [SPRAY 29/09] El spray se MANTIENE: rocia mientras dure el click.
			if WeaponData.HealMode == "Spray" then
				if SprayStart then SprayStart() end
				return
			end
			StartHeal(nil)
			return
		end

		Shoot()

		-- [GRANADAS CS2 30092026] click izquierdo = tiro LEJOS (se cocina
		-- mientras lo mantienes; se lanza al soltar)
		if WeaponData.Type == "Grenade" then
			LL_NadeInput("L", true)
		end

	elseif actionName == "Fire" and inputState == Enum.UserInputState.End then
		mouse1down = false
		if LL_NadeInput then LL_NadeInput("L", false) else CookGrenade = false end	-- [GRANADAS CS2] solo se lanza si tampoco hay click derecho
		if ActiveChargeSound and ActiveChargeSound.IsPlaying then
			ActiveChargeSound:Stop()
		end
		ActiveChargeSound = nil

	end


	--  [DUAL 22/09] Segunda pistola: click derecho / LT / FUEGO 2 del movil.
	if actionName == "Fire2" and DualWield.active then
		DualWield.fire(inputState == Enum.UserInputState.Begin)
	end

	if actionName == "Reload" and inputState == Enum.UserInputState.Begin and AnimDebounce and not CheckingMag and not reloading then
		--  [DUAL 22/09] una sola R recarga las dos pistolas
		if DualWield.active then task.spawn(DualWield.reload) end
		if WeaponData.Jammed then
			Jammed()
		else
			Reload()
		end
	end

	if actionName == "Reload" and inputState == Enum.UserInputState.Begin and reloading and WeaponData.ShellInsert then
		CancelReload = true
	end

	if actionName == "CycleLaser" and inputState == Enum.UserInputState.Begin and LaserAtt then
		SetLaser()
	end

	if actionName == "CycleLight" and inputState == Enum.UserInputState.Begin and TorchAtt then
		SetTorch()
	end

	if actionName == "CycleFiremode" and inputState == Enum.UserInputState.Begin and WeaponData and WeaponData.FireModes.ChangeFiremode then
		Firemode()
	end

	if actionName == "CycleAimpart" and inputState == Enum.UserInputState.Begin then
		SetAimpart()
	end

	if actionName == "ZeroUp" and inputState == Enum.UserInputState.Begin and WeaponData and WeaponData.EnableZeroing  then
		if WeaponData.CurrentZero < WeaponData.MaxZero then
			WeaponInHand.Handle.Click:play()
			WeaponData.CurrentZero = math.min(WeaponData.CurrentZero + WeaponData.ZeroIncrement, WeaponData.MaxZero)
			UpdateGui()
		end
	end

	if actionName == "ZeroDown" and inputState == Enum.UserInputState.Begin and WeaponData and WeaponData.EnableZeroing  then
		if WeaponData.CurrentZero > 0 then
			WeaponInHand.Handle.Click:play()
			WeaponData.CurrentZero = math.max(WeaponData.CurrentZero - WeaponData.ZeroIncrement, 0)
			UpdateGui()
		end
	end

	if actionName == "CheckMag" and inputState == Enum.UserInputState.Begin and not CheckingMag and not reloading and not runKeyDown and AnimDebounce then
		CheckMagFunction()
	end

	if actionName == "ToggleBipod" and inputState == Enum.UserInputState.Begin and CanBipod then

		BipodActive = not BipodActive
		UpdateGui()
	end

	if actionName == "NVG" and inputState == Enum.UserInputState.Begin and not NVGdebounce then
		if plr.Character then
			local helmet = plr.Character:FindFirstChild("Helmet")
			if helmet then
				local nvg = helmet:FindFirstChild("Up")
				if nvg then
					NVGdebounce = true
					task.delay(.8,function()
						NVG = not NVG
						Evt.NVG:Fire(NVG)
						NVGdebounce = false
					end)

				end
			end
		end
	end
	if actionName == "ADS" and inputState == Enum.UserInputState.Begin and AnimDebounce then
		if Healing then return end

		if WeaponData and WeaponData.Type == "Medical" then
			-- [SPRAY 29/09] La nube ya cura a todo el que tengas cerca: el
			-- click derecho no hace nada con el spray.
			if WeaponData.HealMode == "Spray" then return end
			StartHeal(GetHealTarget())
			return
		end

		-- [DUAL 22/09] Con dos pistolas no se apunta.
		if WeaponData and WeaponData.canAim and GunStance > -2 and not runKeyDown and not CheckingMag
			and not DualWield.active then
			aimming = not aimming
			ADS(aimming)
		end

		-- [GRANADAS CS2 30092026] click derecho = tiro CERCA (por abajo,
		-- enfrente de ti). Los dos a la vez = tiro medio. Ya no hay modos.
		if WeaponData.Type == "Grenade" then
			LL_NadeInput("R", true)
		end
	end

	if actionName == "ADS" and (inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel)
		and LL_Nade and LL_Nade.R then
		LL_NadeInput("R", false)
	end


	if actionName == "Stand" and inputState == Enum.UserInputState.Begin and ChangeStance and not Swimming and not Sentado and not runKeyDown then
		if Stances == 2 then
			Crouched = true
			Proned = false
			Stances = 1
			CameraY = -1
			Crouch()


		elseif Stances == 1 then
			Crouched = false
			Stances = 0
			CameraY = 0
			Stand()
		end
	end

	if actionName == "Crouch" and inputState == Enum.UserInputState.Begin and ChangeStance and not Swimming and not Sentado and not runKeyDown then
		if Stances == 0 then
			Stances = 1
			CameraY = -1
			Crouch()
			Crouched = true
		elseif Stances == 1 then
			Stances = 2
			CameraX = 0
			CameraY = -3.25
			Virar = 0
			Lean()
			Prone()
			Crouched = false
			Proned = true
		end
	end

	if actionName == "ToggleWalk" and inputState == Enum.UserInputState.Begin and ChangeStance and not runKeyDown then
		Steady = not Steady

		if Steady then
			SE_GUI.MainFrame.Poses.Steady.Visible = true
		else
			SE_GUI.MainFrame.Poses.Steady.Visible = false
		end

		if Stances == 0 then
			Stand()
		end
	end

	if actionName == "LeanLeft" and inputState == Enum.UserInputState.Begin and Stances ~= 2 and ChangeStance and not Swimming and not runKeyDown and CanLean then
		if Virar == 0 or Virar == 1 then
			Virar = -1
			CameraX = -1.25
		else
			Virar = 0
			CameraX = 0
		end
		Lean()
	end

	if actionName == "LeanRight" and inputState == Enum.UserInputState.Begin and Stances ~= 2 and ChangeStance and not Swimming and not runKeyDown and CanLean then
		if Virar == 0 or Virar == -1 then
			Virar = 1
			CameraX = 1.25
		else
			Virar = 0
			CameraX = 0
		end
		Lean()
	end

	-- [MELEE SPRINT 21092026] swing o carga de melee en curso: Shift no
	-- suelta el click ni pisa la animacion; RunCheck() al final del golpe
	-- pone la pose de sprint.
	local meleeBusy = WeaponData and WeaponData.Type == "Melee" and shooting

	if actionName == "Run" and inputState == Enum.UserInputState.Begin and running and not Healing and not script.Parent:GetAttribute("Injured") then
		if not meleeBusy then
			mouse1down = false
		end
		pumpCooldown = false
		boltCooldown = false
		runKeyDown = true
		Stand()
		Stances = 0
		Virar = 0
		CameraX = 0
		CameraY = 0
		Lean()

		-- La velocidad de sprint ya la calcula ApplyMoveSpeed leyendo
		-- runKeyDown; aqui solo se fuerza el recalculo con Stances ya a 0.
		ApplyMoveSpeed()

		if aimming then
			aimming = false
			ADS(aimming)
		end

		if not meleeBusy and not CheckingMag and not reloading and WeaponData and WeaponData.Type ~= "Grenade" and (GunStance == 0 or GunStance == 2 or GunStance == 3) then
			GunStance = 3
			Evt.GunStance:FireServer(GunStance, LL_StancePose(GunStance, AnimData))
			SprintAnim()
		end

	elseif actionName == "Run" and inputState == Enum.UserInputState.End and runKeyDown then
		runKeyDown 	= false
		Stand()
		if not meleeBusy and not CheckingMag and not reloading and WeaponData and WeaponData.Type ~= "Grenade" and (GunStance == 0 or GunStance == 2 or GunStance == 3) then
			GunStance = 0
			Evt.GunStance:FireServer(GunStance, LL_StancePose(GunStance, AnimData))
			IdleAnim()
		end
	end
end

--  [DUAL 22/09] Con  T  (tabla destino) escribe ahi en vez de en el
--  ModTable del arma en mano: asi la pistola izquierda tiene sus propios
--  multiplicadores de accesorios sin pisar los de la derecha.
function resetMods(T)
	local ModTable = T or ModTable

	ModTable.camRecoilMod.RecoilUp 		= 1
	ModTable.camRecoilMod.RecoilLeft 	= 1
	ModTable.camRecoilMod.RecoilRight 	= 1
	ModTable.camRecoilMod.RecoilTilt 	= 1

	ModTable.gunRecoilMod.RecoilUp 		= 1
	ModTable.gunRecoilMod.RecoilTilt 	= 1
	ModTable.gunRecoilMod.RecoilLeft 	= 1
	ModTable.gunRecoilMod.RecoilRight 	= 1

	ModTable.AimRM			= 1
	ModTable.SpreadRM 		= 1
	ModTable.DamageMod 		= 1
	ModTable.minDamageMod 	= 1

	ModTable.MinRecoilPower 		= 1
	ModTable.MaxRecoilPower 		= 1
	ModTable.RecoilPowerStepAmount 	= 1

	ModTable.MinSpread 					= 1
	ModTable.MaxSpread 					= 1
	ModTable.AimInaccuracyStepAmount 	= 1
	ModTable.AimInaccuracyDecrease 		= 1
	ModTable.WalkMult 					= 1
	ModTable.MuzzleVelocity 			= 1
	ModTable.MoveSpeedMult 				= 1
	ModTable.JumpPowerMult 				= 1

	ModTable.AmmoType 					= ""
	ModTable.BurnRatio 					= 0
	ModTable.RicochetBounces 			= 0
	ModTable.RicochetEnergy 			= 0.8

	ModTable.PenetrateHumanoids 		= false	-- [F-50]
	ModTable.PenetrateWalls 			= 0
	ModTable.PenetrationDamageKeep 		= 1
	ModTable.WallDamageKeep 			= 1

	ModTable.FixedMuzzleVelocity 		= 0	-- [30/09] municiones nuevas
	ModTable.HideTracer 				= false
	ModTable.ShotVolume 				= 1
	ModTable.ShotPitch 					= 1
	ModTable.ShotBass 					= 0
	ModTable.Homing 					= false

end

function setMods(ModData, T)
	local ModTable = T or ModTable	-- [DUAL 22/09] ver resetMods

	-- Un modulo de accesorio NO tiene por que declarar todos los campos.
	-- Los de mira/canon/etc. los traen todos porque se clonaron del AttModule
	-- de ejemplo, pero uno de MUNICION solo toca dano y velocidad de bala.
	-- num() devuelve 1 (neutro) para todo lo que el modulo no declare, asi que
	-- un modulo de tres lineas ya es valido y no revienta con nil.
	if type(ModData) ~= "table" then return end

	local function num(v)
		return tonumber(v) or 1
	end

	local camR = ModData.camRecoil or {}
	local gunR = ModData.gunRecoil or {}

	ModTable.camRecoilMod.RecoilUp 		= ModTable.camRecoilMod.RecoilUp * num(camR.RecoilUp)
	ModTable.camRecoilMod.RecoilLeft 	= ModTable.camRecoilMod.RecoilLeft * num(camR.RecoilLeft)
	ModTable.camRecoilMod.RecoilRight 	= ModTable.camRecoilMod.RecoilRight * num(camR.RecoilRight)
	ModTable.camRecoilMod.RecoilTilt 	= ModTable.camRecoilMod.RecoilTilt * num(camR.RecoilTilt)

	ModTable.gunRecoilMod.RecoilUp 		= ModTable.gunRecoilMod.RecoilUp * num(gunR.RecoilUp)
	ModTable.gunRecoilMod.RecoilTilt 	= ModTable.gunRecoilMod.RecoilTilt * num(gunR.RecoilTilt)
	ModTable.gunRecoilMod.RecoilLeft 	= ModTable.gunRecoilMod.RecoilLeft * num(gunR.RecoilLeft)
	ModTable.gunRecoilMod.RecoilRight 	= ModTable.gunRecoilMod.RecoilRight * num(gunR.RecoilRight)

	ModTable.AimRM						= ModTable.AimRM * num(ModData.AimRecoilReduction)
	ModTable.SpreadRM 					= ModTable.SpreadRM * num(ModData.AimSpreadReduction)
	ModTable.DamageMod 					= ModTable.DamageMod * num(ModData.DamageMod)
	ModTable.minDamageMod 				= ModTable.minDamageMod * num(ModData.minDamageMod)

	ModTable.MinRecoilPower 			= ModTable.MinRecoilPower * num(ModData.MinRecoilPower)
	ModTable.MaxRecoilPower 			= ModTable.MaxRecoilPower * num(ModData.MaxRecoilPower)
	ModTable.RecoilPowerStepAmount 		= ModTable.RecoilPowerStepAmount * num(ModData.RecoilPowerStepAmount)

	ModTable.MinSpread 					= ModTable.MinSpread * num(ModData.MinSpread)
	ModTable.MaxSpread 					= ModTable.MaxSpread * num(ModData.MaxSpread)
	ModTable.AimInaccuracyStepAmount 	= ModTable.AimInaccuracyStepAmount * num(ModData.AimInaccuracyStepAmount)
	ModTable.AimInaccuracyDecrease 		= ModTable.AimInaccuracyDecrease * num(ModData.AimInaccuracyDecrease)
	ModTable.WalkMult 					= ModTable.WalkMult * num(ModData.WalkMult)
	ModTable.MuzzleVelocity 			= ModTable.MuzzleVelocity * num(ModData.MuzzleVelocityMod)
	ModTable.MoveSpeedMult 				= ModTable.MoveSpeedMult * num(ModData.MoveSpeedMult)
	ModTable.JumpPowerMult 				= ModTable.JumpPowerMult * num(ModData.JumpPowerMult)

	--==================================================================
	--  MUNICION
	--  Estos dos campos NO son multiplicadores: los declara solo el
	--  modulo de municion y no se acumulan con los demas accesorios.
	--==================================================================
	if type(ModData.AmmoType) == "string" and ModData.AmmoType ~= "" then
		ModTable.AmmoType = ModData.AmmoType
	end
	if tonumber(ModData.BurnOnHit) then
		ModTable.BurnRatio = ModTable.BurnRatio + tonumber(ModData.BurnOnHit)
	end
	if tonumber(ModData.RicochetBounces) then
		ModTable.RicochetBounces = math.floor(tonumber(ModData.RicochetBounces))
	end
	if tonumber(ModData.RicochetEnergy) then
		ModTable.RicochetEnergy = tonumber(ModData.RicochetEnergy)
	end

	--  [F-50] Perforacion. Tampoco son multiplicadores: los declara solo el
	--  modulo de municion.
	if ModData.PenetrateHumanoids ~= nil then
		ModTable.PenetrateHumanoids = (ModData.PenetrateHumanoids == true)
	end
	if tonumber(ModData.PenetrateWalls) then
		ModTable.PenetrateWalls = math.floor(tonumber(ModData.PenetrateWalls))
	end
	if tonumber(ModData.PenetrationDamageKeep) then
		ModTable.PenetrationDamageKeep = tonumber(ModData.PenetrationDamageKeep)
	end
	if tonumber(ModData.WallDamageKeep) then
		ModTable.WallDamageKeep = tonumber(ModData.WallDamageKeep)
	end

	--  [30/09] Municiones nuevas. FixedMuzzleVelocity, HideTracer y Homing
	--  no son multiplicadores; volumen y tono si (se acumulan), y los
	--  graves se suman en dB.
	if (tonumber(ModData.FixedMuzzleVelocity) or 0) > 0 then
		ModTable.FixedMuzzleVelocity = tonumber(ModData.FixedMuzzleVelocity)
	end
	if ModData.HideTracer == true then
		ModTable.HideTracer = true
	end
	if tonumber(ModData.ShotVolume) then
		ModTable.ShotVolume = (ModTable.ShotVolume or 1) * tonumber(ModData.ShotVolume)
	end
	if tonumber(ModData.ShotPitch) then
		ModTable.ShotPitch = (ModTable.ShotPitch or 1) * tonumber(ModData.ShotPitch)
	end
	if tonumber(ModData.ShotBass) then
		ModTable.ShotBass = (ModTable.ShotBass or 0) + tonumber(ModData.ShotBass)
	end
	if type(ModData.Homing) == "table" then
		ModTable.Homing = ModData.Homing
	end
end

function loadAttachment(weapon)

	--==================================================================
	--  MUNICION (categoria "Ammo")
	--
	--  A diferencia de mira / canon / bajo-canon / otros, este accesorio
	--  NO tiene modelo en AttModels ni necesita un Node en el arma: no se
	--  monta nada fisico, solo cambia propiedades de la bala. Por eso el
	--  bloque va FUERA del  if weapon.Nodes  de abajo: un arma sin carpeta
	--  Nodes igual puede llevar municion especial.
	--
	--  El modulo se resuelve en setup(): atributo Att_Ammo del Tool si el
	--  jugador configuro uno, si no el AmmoAtt del ACS_Settings del arma.
	--==================================================================
	if WeaponData and type(WeaponData.AmmoAtt) == "string" and WeaponData.AmmoAtt ~= "" then
		local ammoModule = AttModules:FindFirstChild(WeaponData.AmmoAtt)
		if ammoModule and ammoModule:IsA("ModuleScript") then
			local okAmmo, AmmoData = pcall(require, ammoModule)
			if okAmmo and type(AmmoData) == "table" then
				setMods(AmmoData)
				dprint("[Ammo]", WeaponData.AmmoAtt,
					"| DamageMod", ModTable.DamageMod,
					"| MuzzleVel", ModTable.MuzzleVelocity,
					"| BurnRatio", ModTable.BurnRatio)
			else
				warn("[ACS] El modulo de municion '"..tostring(WeaponData.AmmoAtt).."' fallo al cargar: "..tostring(AmmoData))
			end
		else
			warn("[ACS] No existe el ModuleScript de municion '"..tostring(WeaponData.AmmoAtt).."' en AttModules")
		end
	end

	if weapon and weapon:FindFirstChild("Nodes") ~= nil then

		--load sight Att
		if weapon.Nodes:FindFirstChild("Sight") ~= nil and WeaponData.SightAtt ~= "" then

			SightData =  require(AttModules[WeaponData.SightAtt])

			SightAtt = AttModels[WeaponData.SightAtt]:Clone()
			SightAtt.Parent = weapon
			SightAtt:SetPrimaryPartCFrame(weapon.Nodes.Sight.CFrame)
			weapon.AimPart.CFrame = SightAtt.AimPos.CFrame

			reticle = SightAtt.SightMark.SurfaceGui.Border.Scope
			if SightData.SightZoom > 0 then
				ModTable.ZoomValue = SightData.SightZoom
			end
			if SightData.SightZoom2 > 0 then
				ModTable.Zoom2Value = SightData.SightZoom2
			end
			setMods(SightData)


			for index, key in pairs(weapon:GetChildren()) do
				if key.Name == "IS" then
					key.Transparency = 1
				end
			end

			for index, key in pairs(SightAtt:GetChildren()) do
				if key:IsA('BasePart') then
					Ultil.Weld(weapon:WaitForChild("Handle"), key )
					key.Anchored = false
					key.CanCollide = false
				end
			end

		end

		--load Barrel Att
		if weapon.Nodes:FindFirstChild("Barrel") ~= nil and WeaponData.BarrelAtt ~= "" then

			BarrelData =  require(AttModules[WeaponData.BarrelAtt])

			BarrelAtt = AttModels[WeaponData.BarrelAtt]:Clone()
			BarrelAtt.Parent = weapon
			BarrelAtt:SetPrimaryPartCFrame(weapon.Nodes.Barrel.CFrame)


			if BarrelAtt:FindFirstChild("BarrelPos") ~= nil then
				weapon.Handle.Muzzle.WorldCFrame = BarrelAtt.BarrelPos.CFrame
			end

			Suppressor 		= BarrelData.IsSuppressor
			FlashHider 		= BarrelData.IsFlashHider

			setMods(BarrelData)

			for index, key in pairs(BarrelAtt:GetChildren()) do
				if key:IsA('BasePart') then
					Ultil.Weld(weapon:WaitForChild("Handle"), key )
					key.Anchored = false
					key.CanCollide = false
				end
			end
		end

		--load Under Barrel Att
		if weapon.Nodes:FindFirstChild("UnderBarrel") ~= nil and WeaponData.UnderBarrelAtt ~= "" then

			UnderBarrelData =  require(AttModules[WeaponData.UnderBarrelAtt])

			UnderBarrelAtt = AttModels[WeaponData.UnderBarrelAtt]:Clone()
			UnderBarrelAtt.Parent = weapon
			UnderBarrelAtt:SetPrimaryPartCFrame(weapon.Nodes.UnderBarrel.CFrame)


			setMods(UnderBarrelData)
			BipodAtt = UnderBarrelData.IsBipod

			if BipodAtt then
				_G.LL_Bind("ToggleBipod", handleAction, true, Enum.KeyCode.B)
			end

			for index, key in pairs(UnderBarrelAtt:GetChildren()) do
				if key:IsA('BasePart') then
					Ultil.Weld(weapon:WaitForChild("Handle"), key )
					key.Anchored = false
					key.CanCollide = false
				end
			end
		end

		if weapon.Nodes:FindFirstChild("Other") ~= nil and WeaponData.OtherAtt ~= "" then

			OtherData =  require(AttModules[WeaponData.OtherAtt])

			OtherAtt = AttModels[WeaponData.OtherAtt]:Clone()
			OtherAtt.Parent = weapon
			OtherAtt:SetPrimaryPartCFrame(weapon.Nodes.Other.CFrame)


			setMods(OtherData)
			LaserAtt = OtherData.EnableLaser
			TorchAtt = OtherData.EnableFlashlight

			if OtherData.InfraRed then
				IREnable = true
			end

			for index, key in pairs(OtherAtt:GetChildren()) do
				if key:IsA('BasePart') then
					Ultil.Weld(weapon:WaitForChild("Handle"), key )
					key.Anchored = false
					key.CanCollide = false
				end
			end
		end
	end
end

function SetLaser()
	if gameRules.RealisticLaser and IREnable then
		if not LaserActive and not IRmode then
			LaserActive = true
			IRmode 		= true

		elseif LaserActive and IRmode then
			IRmode 		= false
		else
			LaserActive = false
			IRmode 		= false
		end
	else
		LaserActive = not LaserActive
	end

	dprint("[Laser]", LaserActive, IRmode)

	if LaserActive then
		if not Pointer then
			for index, Key in pairs(LaserPoints) do
				if Key.Parent then
					local LaserPointer = Instance.new('Part')
					LaserPointer.Shape = 'Ball'
					LaserPointer.Size = Vector3.new(0.2, 0.2, 0.2)
					LaserPointer.CanCollide = false
					LaserPointer.Color = Key.Color
					LaserPointer.Material = Enum.Material.Neon
					LaserPointer.Parent = Key

					local LaserSP = Instance.new('Attachment')
					LaserSP.Parent = Key

					local LaserEP = Instance.new('Attachment')
					LaserEP.Parent = LaserPointer

					local LaserBeam = Instance.new('Beam')
					LaserBeam.Transparency = NumberSequence.new(0)
					LaserBeam.LightEmission = 1
					LaserBeam.LightInfluence = 1
					LaserBeam.Attachment0 = LaserSP
					LaserBeam.Attachment1 = LaserEP
					LaserBeam.Color = ColorSequence.new(Key.Color)
					LaserBeam.FaceCamera = true
					LaserBeam.Width0 = 0.01
					LaserBeam.Width1 = 0.01

					if gameRules.RealisticLaser then
						LaserBeam.Enabled = false
					end
					LaserBeam.Parent = LaserPointer

					Pointer = LaserPointer
					break
				end
			end
		end
	else
		for index, Key in pairs(LaserPoints) do
			if Key.Parent then
				Key:ClearAllChildren()
				break
			end
		end
		Pointer = nil
		if gameRules.ReplicatedLaser then
			Evt.SVLaser:FireServer(nil,2,nil,false,WeaponTool)
		end
	end
	WeaponInHand.Handle.Click:play()
	UpdateGui()
end

function SetTorch()

	TorchActive = not TorchActive

	if TorchActive then
		for index, Key in pairs(WeaponInHand:GetDescendants()) do
			if Key:IsA("BasePart") and Key.Name == "FlashPoint" then
				Key.Light.Enabled = true
			end
		end
	else
		for index, Key in pairs(WeaponInHand:GetDescendants()) do
			if Key:IsA("BasePart") and Key.Name == "FlashPoint" then
				Key.Light.Enabled = false
			end
		end
	end
	Evt.SVFlash:FireServer(WeaponTool,TorchActive)
	WeaponInHand.Handle.Click:play()
	UpdateGui()
end

function ADS(aimming)
	if WeaponData and WeaponInHand then

		if aimming then

			if SafeMode then
				SafeMode = false
				GunStance = 0
				IdleAnim()
				UpdateGui()
			end

			-- [15/09] segun la mira: normal / de aumento / mezcla
			User.MouseDeltaSensitivity = (CurrentAimSens()/100)

			WeaponInHand.Handle.AimDown:Play()

			GunStance = 2
			Evt.GunStance:FireServer(GunStance, LL_StancePose(GunStance, AnimData))

			TS:Create(Crosshair.Up, TweenInfo.new(.2,Enum.EasingStyle.Linear), {BackgroundTransparency = 1}):Play()
			TS:Create(Crosshair.Down, TweenInfo.new(.2,Enum.EasingStyle.Linear), {BackgroundTransparency = 1}):Play()
			TS:Create(Crosshair.Left, TweenInfo.new(.2,Enum.EasingStyle.Linear), {BackgroundTransparency = 1}):Play()
			TS:Create(Crosshair.Right, TweenInfo.new(.2,Enum.EasingStyle.Linear), {BackgroundTransparency = 1}):Play()
			TS:Create(Crosshair.Center, TweenInfo.new(.2,Enum.EasingStyle.Linear), {ImageTransparency = 1}):Play()

		else
			User.MouseDeltaSensitivity = 1
			WeaponInHand.Handle.AimUp:Play()

			GunStance = 0
			Evt.GunStance:FireServer(GunStance, LL_StancePose(GunStance, AnimData))

			if  WeaponData.CrossHair then
				TS:Create(Crosshair.Up, TweenInfo.new(.2,Enum.EasingStyle.Linear), {BackgroundTransparency = 0}):Play()
				TS:Create(Crosshair.Down, TweenInfo.new(.2,Enum.EasingStyle.Linear), {BackgroundTransparency = 0}):Play()
				TS:Create(Crosshair.Left, TweenInfo.new(.2,Enum.EasingStyle.Linear), {BackgroundTransparency = 0}):Play()
				TS:Create(Crosshair.Right, TweenInfo.new(.2,Enum.EasingStyle.Linear), {BackgroundTransparency = 0}):Play()
			end

			if  WeaponData.CenterDot then
				TS:Create(Crosshair.Center, TweenInfo.new(.2,Enum.EasingStyle.Linear), {ImageTransparency = 0}):Play()
			else
				TS:Create(Crosshair.Center, TweenInfo.new(.2,Enum.EasingStyle.Linear), {ImageTransparency = 1}):Play()
			end
		end
	end

	-- Apuntar puede frenarte (AimMoveSpeedMult) y romper el bunny hop.
	ApplyMoveSpeed()
end

function SetAimpart()
	if aimming then
		if AimPartMode == 1 then
			AimPartMode = 2
			if WeaponInHand:FindFirstChild('AimPart2') then
				CurAimpart = WeaponInHand:FindFirstChild('AimPart2')
			end
		else
			AimPartMode = 1
			CurAimpart = WeaponInHand:FindFirstChild('AimPart')
		end
	end
end

local FiremodeOrder = {
	{ Mode = 1, Key = "Semi"   },
	{ Mode = 2, Key = "Burst"  },
	{ Mode = 3, Key = "Auto"   },
	{ Mode = 4, Key = "Pump"   },
	{ Mode = 5, Key = "Bolt"   },
	{ Mode = 6, Key = "Charge" },
}

function Firemode()

	-- No cambiar de modo a mitad de una carga
	if isCharging then return end

	if WeaponInHand and WeaponInHand:FindFirstChild("Handle") and WeaponInHand.Handle:FindFirstChild("SafetyClick") then
		WeaponInHand.Handle.SafetyClick:Play()
	end
	mouse1down = false

	local modes = WeaponData and WeaponData.FireModes
	if not modes then return end

	-- Armar la lista de modos habilitados, en orden
	local enabled = {}
	for _, entry in ipairs(FiremodeOrder) do
		if modes[entry.Key] == true then
			table.insert(enabled, entry.Mode)
		end
	end

	if #enabled <= 1 then
		UpdateGui()
		return
	end

	-- Buscar el modo actual y saltar al siguiente
	local index = nil
	for i, mode in ipairs(enabled) do
		if mode == WeaponData.ShootType then
			index = i
			break
		end
	end

	if index then
		WeaponData.ShootType = enabled[(index % #enabled) + 1]
	else
		WeaponData.ShootType = enabled[1]
	end

	UpdateGui()
end
--==========================================================================
--  [DUAL 22/09] PISTOLAS DUALES — fase 2: las dos pistolas en las manos
--
--  LoadoutServer entrega la terciaria dual como UN Tool: el arma de la
--  mano DERECHA (slot 2) con el atributo DualLeft = arma de la mano
--  IZQUIERDA (slot 1) y sus accesorios en DualL_Att_*. ACS maneja la
--  derecha como siempre; aqui se monta la izquierda:
--    · su modelo va soldado al brazo izquierdo (con sus accesorios);
--    · el brazo izquierdo deja las animaciones del arma (que lo ponen de
--      apoyo): LArmWeld queda sin Part1 y en cada frame el brazo copia en
--      ESPEJO al derecho. Equipar, correr y recargar se ven parejos;
--    · en dual no se apunta (el candado esta en handleAction, "ADS").
--  Fase 3: disparo de la izquierda (click derecho / LT / Fire 2).
--  Global + funcion anonima: este chunk esta al limite de 200 locals.
--  Respaldo: ServerStorage.Respaldo_antes_22092026.ACS_Framework_22092026_antesDual
--==========================================================================
DualWield = { active = false }
;(function()
	local SPREAD = 0.15		-- cuanto se abre cada brazo hacia afuera (studs)
	local ATT_SLOTS = { "Sight", "Barrel", "UnderBarrel", "Other" }
	local GunStorage = RS:WaitForChild("GunStorage")
	local state = { planeX = 0, armMotor = nil }

	--  ESTADO DE LA PISTOLA IZQUIERDA (fase 3)
	--  Su propia copia de lo que ACS guarda del arma en mano: stats,
	--  multiplicadores de los accesorios, municion, y la dispersion y el
	--  retroceso acumulados. Asi las dos pistolas se gastan y patean por
	--  separado en vez de compartir los contadores de la derecha.
	local L = {}
	local function clearLeft()
		L = { spread = 0, power = 0, ammo = 0, stored = 0, lastShot = 0 }
	end
	clearLeft()

	DualWield.recoilMult   = 2		-- se lee de DualConfig
	DualWield.convergeDist = 300	-- studs: donde se cruzan los dos disparos
	local RELOAD = { time = 1.5, emptyExtra = 0.3, upAngle = 135 }	-- se lee de DualConfig
	do
		local mod = RS:FindFirstChild("DualConfig")
		local ok, cfg = false, nil
		if mod then ok, cfg = pcall(require, mod) end
		if ok and type(cfg) == "table" then
			if tonumber(cfg.RecoilMult) then DualWield.recoilMult = tonumber(cfg.RecoilMult) end
			if tonumber(cfg.ReloadTime) then RELOAD.time = tonumber(cfg.ReloadTime) end
			if tonumber(cfg.EmptyReloadExtra) then RELOAD.emptyExtra = tonumber(cfg.EmptyReloadExtra) end
			if tonumber(cfg.ReloadUpAngle) then RELOAD.upAngle = tonumber(cfg.ReloadUpAngle) end
			--  [22/09] pose general de correr (ver DualConfig.SprintPose)
			if typeof(cfg.SprintPose) == "CFrame" then DualWield.sprintPose = cfg.SprintPose end
		end
	end

	-- Espejo de un CFrame sobre el plano x = planeX: la posicion se refleja
	-- y la rotacion queda S*R*S (S = diag(-1,1,1)), que sigue siendo una
	-- rotacion valida.
	local function mirror(cf, planeX)
		local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
		return CFrame.new(2 * planeX - x, y, z, r00, -r01, -r02, -r10, r11, r12, -r20, r21, r22)
	end

	-- Donde esta el brazo derecho respecto de AnimPart (Motor6D: C0 * C1^-1)
	local function rightArmFrame()
		return RArmWeld.C0 * RArmWeld.C1:Inverse()
	end

	-- Accesorio de la izquierda: atributo Att_<slot> de su ficha;
	-- ausente = el de fabrica de su ACS_Settings; "" = sin accesorio.
	local function leftAttachment(ficha, slot, defaults)
		local chosen = ficha and ficha:GetAttribute("Att_" .. slot)
		if chosen == nil and defaults then chosen = defaults[slot .. "Att"] end
		if type(chosen) ~= "string" or chosen == "" then return nil end
		return AttModels:FindFirstChild(chosen)
	end

	--  Stats y accesorios de la izquierda, igual que hace setup() con el arma
	--  en mano. Sin ficha se queda con los valores de fabrica y NO dispara:
	--  la ficha es lo que se manda en el remote de dano.
	local function buildLeftState(ficha, settings)
		clearLeft()
		if type(settings) ~= "table" then return end

		local data = {}
		for k, v in pairs(settings) do data[k] = v end

		local function resolveAtt(slot)
			local chosen = ficha and ficha:GetAttribute("Att_" .. slot)
			if chosen == nil then return data[slot .. "Att"] or "" end
			if type(chosen) ~= "string" then return "" end
			return chosen
		end
		data.SightAtt       = resolveAtt("Sight")
		data.BarrelAtt      = resolveAtt("Barrel")
		data.UnderBarrelAtt = resolveAtt("UnderBarrel")
		data.OtherAtt       = resolveAtt("Other")
		data.AmmoAtt        = resolveAtt("Ammo")

		local mods = { camRecoilMod = {}, gunRecoilMod = {} }
		resetMods(mods)

		local function applyAtt(name)
			if type(name) ~= "string" or name == "" then return nil end
			local mod = AttModules:FindFirstChild(name)
			if not (mod and mod:IsA("ModuleScript")) then return nil end
			local ok, att = pcall(require, mod)
			if not (ok and type(att) == "table") then return nil end
			setMods(att, mods)
			return att
		end

		applyAtt(data.AmmoAtt)
		applyAtt(data.SightAtt)
		local barrel = applyAtt(data.BarrelAtt)
		applyAtt(data.UnderBarrelAtt)
		applyAtt(data.OtherAtt)

		L.data = data
		L.mods = mods
		L.tool = ficha
		L.suppressor = (barrel ~= nil and barrel.IsSuppressor == true)
		L.flashHider = (barrel ~= nil and barrel.IsFlashHider == true)
		L.spread = math.min(data.MinSpread * mods.MinSpread, data.MaxSpread * mods.MaxSpread)
		L.power  = math.min(data.MinRecoilPower * mods.MinRecoilPower, data.MaxRecoilPower * mods.MaxRecoilPower)

		--  Municion guardada en la ficha, igual que ACS la guarda en el Tool.
		L.ammo   = tonumber(ficha and ficha:GetAttribute("CurrentAmmo"))   or tonumber(data.Ammo)       or 0
		L.stored = tonumber(ficha and ficha:GetAttribute("CurrentStored")) or tonumber(data.StoredAmmo) or 0

		L.ctx = { data = data, mods = mods, tool = ficha, spread = L.spread }
	end

	-- Clona el modelo de la izquierda y lo arma igual que setup() arma
	-- WeaponInHand. Los accesorios van solo como modelo por ahora.
	local function buildLeftGun(ficha, leftName)
		local template = GunModels:FindFirstChild(leftName)
		if not template then return nil end
		local gun = template:Clone()
		gun.Name = "DualLeftGun"
		local handle = gun:FindFirstChild("Handle")
		if not handle then gun:Destroy() return nil end
		gun.PrimaryPart = handle

		local defaults = L.data		-- ya resuelto en buildLeftState

		local nodes = gun:FindFirstChild("Nodes")
		if nodes then
			for _, slot in ipairs(ATT_SLOTS) do
				local node = nodes:FindFirstChild(slot)
				local model = node and leftAttachment(ficha, slot, defaults)
				if model then
					local att = model:Clone()
					att.Parent = gun
					pcall(function()
						if att.PrimaryPart then att:SetPrimaryPartCFrame(node.CFrame) else att:PivotTo(node.CFrame) end
					end)
					if slot == "Sight" then
						for _, key in ipairs(gun:GetChildren()) do
							if key.Name == "IS" and key:IsA("BasePart") then key.Transparency = 1 end
						end
					elseif slot == "Barrel" and att:FindFirstChild("BarrelPos") and handle:FindFirstChild("Muzzle") then
						handle.Muzzle.WorldCFrame = att.BarrelPos.CFrame
					end
					for _, key in ipairs(att:GetChildren()) do
						if key:IsA("BasePart") then
							Ultil.Weld(handle, key)
							key.Anchored = false
							key.CanCollide = false
						end
					end
				end
			end
		end

		for _, key in ipairs(gun:GetChildren()) do
			if key:IsA("BasePart") and key ~= handle then
				if key.Name == "Bolt" or key.Name == "Slide" then
					Ultil.WeldComplex(handle, key, key.Name)
				elseif key.Name == "Lid" then
					Ultil.Weld(key, gun:FindFirstChild("LidHinge") or handle)
				else
					Ultil.Weld(handle, key)
				end
			end
		end
		for _, key in ipairs(gun:GetChildren()) do
			if key:IsA("BasePart") then
				key.Anchored = false
				key.CanCollide = false
			end
		end
		if nodes then
			for _, key in ipairs(nodes:GetChildren()) do
				if key:IsA("BasePart") then
					Ultil.Weld(handle, key)
					key.Anchored = false
					key.CanCollide = false
				end
			end
		end
		return gun, handle
	end

	function DualWield.detach()
		if DualWield.active then
			if DualWield.saveAmmo then DualWield.saveAmmo() end
			CAS:UnbindAction("Fire2")
		end
		DualWield.active = false
		DualWield.gun = nil
		DualWield.leftName = nil
		state.armMotor = nil
		clearLeft()
	end

	-- Se llama desde setup() con el viewmodel ya armado, antes de EquipAnim.
	function DualWield.attach(Tool)
		DualWield.detach()
		local leftName = Tool and Tool:GetAttribute("DualLeft")
		if type(leftName) ~= "string" or leftName == "" then return end
		if not (ViewModel and AnimPart and LArm and RArm and LArmWeld and RArmWeld and AnimData) then return end

		local leftTool = GunStorage:FindFirstChild(leftName)
		local animMod = leftTool and leftTool:FindFirstChild("ACS_Animations")
		local okAnim, leftAnim = false, nil
		if animMod then okAnim, leftAnim = pcall(require, animMod) end
		if not (okAnim and type(leftAnim) == "table" and typeof(leftAnim.GunCFrame) == "CFrame") then
			warn("[DUAL] No se pudo leer ACS_Animations de " .. leftName)
			return
		end

		--  FICHA DE LA IZQUIERDA: la escribe LoadoutServer dentro del Tool.
		--  Es una carpeta con el nombre del arma, una copia de su ACS_Settings
		--  y sus accesorios. Va en el remote de dano, asi que el anti-exploit
		--  compara los stats CONTRA ESTA pistola y el kill feed muestra la que
		--  de verdad mato. Sin ficha la izquierda se monta pero no dispara.
		local ficha = Tool:FindFirstChild(leftName)
		local settingsMod = ficha and ficha:FindFirstChild("ACS_Settings")
		local okSet, leftSettings = false, nil
		if settingsMod then okSet, leftSettings = pcall(require, settingsMod) end
		if not (okSet and type(leftSettings) == "table") then
			ficha = nil
			local propio = leftTool and leftTool:FindFirstChild("ACS_Settings")
			if propio then
				local ok2, res = pcall(require, propio)
				if ok2 then leftSettings = res end
			end
			warn("[DUAL] " .. leftName .. " sin ficha en el Tool: se monta sin disparar")
		end
		buildLeftState(ficha, leftSettings)

		local gun, handle = buildLeftGun(ficha, leftName)
		if not gun then
			warn("[DUAL] No hay modelo en GunModels para " .. leftName)
			return
		end

		-- El brazo izquierdo sale de las animaciones del arma.
		LArmWeld.Part1 = nil
		local arm = Instance.new("Motor6D")
		arm.Name = "DualLeftArm"
		arm.Part0 = AnimPart
		arm.Part1 = LArm
		arm.Parent = AnimPart

		-- Los dos brazos un poco hacia afuera para que no se atraviesen.
		RArmWeld.C0 = CFrame.new(SPREAD, 0, 0)

		-- Plano del espejo: el centro de la pantalla visto desde AnimPart.
		local main = AnimData.MainCFrame
		state.planeX = -((typeof(main) == "CFrame") and main.X or 0)
		arm.C1 = mirror(rightArmFrame(), state.planeX):Inverse()

		local gunMotor = Instance.new("Motor6D")
		gunMotor.Name = "DualLeftHandle"
		gunMotor.Part0 = LArm
		gunMotor.Part1 = handle
		gunMotor.C1 = mirror(leftAnim.GunCFrame, 0)
		gunMotor.Parent = AnimPart
		gun.Parent = ViewModel

		if handle:FindFirstChild("GunEquip") then handle.GunEquip:Play() end

		state.armMotor = arm
		DualWield.gun = gun
		DualWield.leftName = leftName
		if L.ctx then L.ctx.gun = gun end
		DualWield.active = true

		--  Click derecho / LT / FUEGO 2 del movil disparan la izquierda. ADS
		--  sigue enlazado al mismo boton, pero en duales no hace nada (el
		--  candado esta en handleAction), asi que no hay que desenlazarlo.
		_G.LL_Bind("Fire2", handleAction, false, Enum.UserInputType.MouseButton2, Enum.KeyCode.ButtonL2)

		dprint("[DUAL] montada", leftName, "en la mano izquierda | dispara:", L.tool ~= nil)
	end

	--  MUNICION de la izquierda: se escribe en la ficha para que sobreviva a
	--  guardar y sacar el arma, igual que ACS hace con el Tool.
	local function saveAmmo()
		if L.tool and L.tool:IsDescendantOf(game) then
			L.tool:SetAttribute("CurrentAmmo", L.ammo)
			L.tool:SetAttribute("CurrentStored", L.stored)
		end
	end
	DualWield.saveAmmo = saveAmmo

	local function leftHandle()
		return DualWield.gun and DualWield.gun:FindFirstChild("Handle")
	end

	--  Fogonazo, humo, casquillo, corredera y subida de dispersion, lo mismo
	--  que GunFx() hace con el arma en mano.
	local function leftFx(chargeSnd)
		local handle = leftHandle()
		if not handle then return end

		local muzzle = handle:FindFirstChild("Muzzle")
		if muzzle then
			local cf = chargeSnd and muzzle:FindFirstChild("ChargeFire")
			if L.suppressor and muzzle:FindFirstChild("Supressor") then
				LL_PlayShot(muzzle.Supressor, L.mods)	-- [30/09] municion de la izquierda
			elseif cf and cf:IsA("Sound") then
				cf.PlaybackSpeed = chargeSnd
				cf:Play()
			elseif muzzle:FindFirstChild("Fire") then
				LL_PlayShot(muzzle.Fire, L.mods)
			end
			if not L.flashHider and muzzle:FindFirstChild("FlashFX[Flash]") then
				muzzle["FlashFX[Flash]"]:Emit(10)
			end
			if muzzle:FindFirstChild("Smoke") then muzzle.Smoke:Emit(10) end
		end

		local chamber = handle:FindFirstChild("Chamber")
		if chamber then
			if chamber:FindFirstChild("Smoke") then chamber.Smoke:Emit(10) end
			if chamber:FindFirstChild("Shell") then chamber.Shell:Emit(1) end
		end

		local slide = handle:FindFirstChild("Slide")
		if slide and typeof(L.data.SlideEx) == "CFrame" then
			local rate = tonumber(L.data.ShootRate) or 600
			local vuelve = (L.ammo > 0) or not L.data.SlideLock
			TS:Create(slide, TweenInfo.new(30/rate, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, 0, vuelve, 0),
				{ C0 = L.data.SlideEx:inverse() }):Play()
		end

		L.spread = math.min(L.data.MaxSpread * L.mods.MaxSpread,
			L.spread + L.data.AimInaccuracyStepAmount * L.mods.AimInaccuracyStepAmount)
		L.power = math.min(L.data.MaxRecoilPower * L.mods.MaxRecoilPower,
			L.power + L.data.RecoilPowerStepAmount * L.mods.RecoilPowerStepAmount)
		L.lastShot = time()
	end

	local function leftReady()
		return DualWield.active and L.data ~= nil and L.tool ~= nil
			and not reloading and not L.reloading and not runKeyDown
			and not SafeMode and not CheckingMag
	end

	--  Un disparo de la izquierda. Sin argumentos es un tiro normal; el modo
	--  carga pasa sus multiplicadores, perdigones, sonido y costo.
	--  El "L" al final le dice al servidor y a los demas jugadores que el
	--  fogonazo sale de la pistola IZQUIERDA.
	local function shootLeftOnce(dmgMult, spdMult, spread, pellets, chargeSnd, cost)
		L.ammo -= (cost or 1)
		saveAmmo()
		Evt.Atirar:FireServer(WeaponTool, L.suppressor, L.flashHider, chargeSnd, "L")
		L.ctx.spread = L.spread
		local n = pellets or math.max(1, tonumber(L.data.Bullets) or 1)
		for _ = 1, n do
			Thread:Spawn(function() CreateBullet(dmgMult or 1, spdMult or 1, spread or 0, L.ctx) end)
		end
		leftFx(chargeSnd)
		UpdateGui()
		Thread:Spawn(function() Recoil(L.data, L.mods, L.power) end)
	end

	local function leftMuzzle()
		local h = leftHandle()
		return h and h:FindFirstChild("Muzzle")
	end

	local function leftChargeSound(muzzle, play)
		if not muzzle then return end
		local s = muzzle:FindFirstChild("Charge")
		local f = muzzle:FindFirstChild("ChargeFull")
		if f and f:IsA("Sound") then f:Stop() end
		if s and s:IsA("Sound") then
			s:Stop()
			if play then
				s.TimePosition = 0
				s:Play()
			end
		end
	end

	--==================================================================
	--  MODO CARGA (ShootType 6) de la izquierda — mismo reglamento que
	--  el bloque de carga de Shoot(): ChargeTime, ChargeSemi (tipo R8:
	--  carga, dispara al llenarse y vuelve a cargar), soltar para
	--  disparar, carga minima, moverse cancela/decae, escala de dano y
	--  velocidad, perdigones, costo de municion y sonidos Charge /
	--  ChargeFull / ChargeFire de SU muzzle.
	--==================================================================
	local function chargeLeft(myGun, rate)
		local d = L.data
		local chargeTime    = math.max(tonumber(d.ChargeTime) or 2, 0.01)
		local releaseToFire = d.ChargeReleaseToFire == true
		local semi          = d.ChargeSemi == true
		if semi then releaseToFire = false end
		local semiRepeat    = d.ChargeSemiRepeat ~= false
		local semiCooldown  = tonumber(d.ChargeSemiCooldown) or (60 / rate)
		local minRatio      = tonumber(d.ChargeMinRatio) or 0
		local fullAt        = math.clamp(tonumber(d.ChargeFullSoundAt) or 1, 0.05, 1)
		local moveBehavior  = d.ChargeMoveBehavior or "none"
		local moveThreshold = tonumber(d.ChargeMoveThreshold) or 2
		local decayRate     = tonumber(d.ChargeDecayRate) or 1
		local curve   = math.max(tonumber(d.ChargeCurve) or 1, 0.05)
		local cDamage = math.max(tonumber(d.ChargeCurveDamage) or curve, 0.05)
		local cSpeed  = math.max(tonumber(d.ChargeCurveVelocity) or curve, 0.05)
		local cShape  = math.max(tonumber(d.ChargeCurveShape) or curve, 0.05)

		local bullets = math.max(1, tonumber(d.Bullets) or 1)
		local maxPellets, minPellets, maxSpread, minSpread = bullets, bullets, 0, 0
		if d.ChargeShotgun == true then
			maxPellets = tonumber(d.ChargeBullets) or bullets
			minPellets = tonumber(d.ChargeMinBullets) or maxPellets
			maxSpread  = tonumber(d.ChargeSpread) or 0
			minSpread  = tonumber(d.ChargeMinSpread) or maxSpread
		end

		local muzzle = leftMuzzle()
		local atFull = false

		local function isMoving()
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if hum and hum.MoveDirection.Magnitude > 0 then return true end
			local root = char and char:FindFirstChild("HumanoidRootPart")
			if root then
				local v = root.AssemblyLinearVelocity
				return Vector3.new(v.X, 0, v.Z).Magnitude > moveThreshold
			end
			return false
		end

		local function fireCharged(ratio)
			local cost = tonumber(d.ChargeAmmoCost) or 1
			if d.ChargeCostScales == true then cost = math.ceil(cost * ratio) end
			cost = math.max(1, math.floor(cost))
			if L.ammo < cost then
				if d.ChargePartialFire == true and L.ammo > 0 then
					cost = L.ammo
				else
					local h = leftHandle()
					if h and h:FindFirstChild("Click") then h.Click:Play() end
					return false
				end
			end

			local minDmg = tonumber(d.ChargeMinDamageMult) or 0
			local minSpd = tonumber(d.ChargeMinSpeedMult) or 0
			local dmgMult = (d.ChargeScaleDamage == true) and (minDmg + (1 - minDmg) * ratio ^ cDamage) or 1
			local spdMult = (d.ChargeScaleVelocity == true) and (minSpd + (1 - minSpd) * ratio ^ cSpeed) or 1
			spdMult = math.max(spdMult, 0.05)
			local pellets = math.max(1, math.round(minPellets + (maxPellets - minPellets) * ratio ^ cShape))
			local spread  = math.max(0, minSpread + (maxSpread - minSpread) * ratio ^ cShape)
			if d.ChargeSplitDamage == true then dmgMult = dmgMult / pellets end

			local snd = nil
			local cf = muzzle and muzzle:FindFirstChild("ChargeFire")
			if cf and cf:IsA("Sound") and ratio >= (tonumber(d.ChargeFireSoundAt) or 1) then
				snd = 1
				if d.ChargeFirePitch == true then
					local pMin = tonumber(d.ChargeFirePitchMin) or 1.3
					local pMax = tonumber(d.ChargeFirePitchMax) or 1.0
					snd = pMin + (pMax - pMin) * ratio
				end
			end

			shootLeftOnce(dmgMult, spdMult, spread, pellets, snd, cost)
			return true
		end

		local function alive()
			return DualWield.gun == myGun and leftReady() and L.ammo > 0
		end

		local charge = 0
		leftChargeSound(muzzle, true)

		while true do
			while true do
				local dt = task.wait()
				if not alive() then
					leftChargeSound(muzzle, false)
					return
				end
				if not L.down then break end

				local moving = (moveBehavior ~= "none") and isMoving() or false
				if moving and moveBehavior == "cancel" then
					leftChargeSound(muzzle, false)
					return
				elseif moving and moveBehavior == "decay" then
					charge = math.max(0, charge - dt * decayRate)
				else
					charge = math.min(chargeTime, charge + dt)
				end

				if not releaseToFire and charge >= chargeTime then break end

				if releaseToFire and not atFull and charge / chargeTime >= fullAt then
					atFull = true
					local s = muzzle and muzzle:FindFirstChild("Charge")
					if s and s:IsA("Sound") then s:Stop() end
					local f = muzzle and muzzle:FindFirstChild("ChargeFull")
					if f and f:IsA("Sound") then
						f.Looped = true
						f.TimePosition = 0
						f:Play()
					end
				end
			end

			local ratio = math.clamp(charge / chargeTime, 0, 1)

			if semi then
				-- Solto antes de completar: se cancela sin gastar bala
				if charge < chargeTime or not alive() then break end
				if not fireCharged(1) then break end
				leftChargeSound(muzzle, false)
				if not semiRepeat then
					while L.down and DualWield.gun == myGun do task.wait() end
					task.wait(semiCooldown)
					break
				end
				task.wait(semiCooldown)
				if not (alive() and L.down) then break end
				charge = 0
				leftChargeSound(muzzle, true)

			elseif releaseToFire then
				if ratio >= minRatio and alive() then fireCharged(ratio) end
				break

			else
				while alive() and L.down do
					if not fireCharged(1) then break end
					task.wait(60 / rate)
				end
				break
			end
		end

		leftChargeSound(muzzle, false)
	end

	--  Disparo de la izquierda. Respeta el modo de fuego de SU pistola y no
	--  toca los candados de la derecha: las dos pueden disparar a la vez.
	function DualWield.fire(begin)
		if not begin then
			L.down = false
			return
		end
		if not leftReady() or L.shooting then return end

		if L.ammo <= 0 then
			local handle = leftHandle()
			if handle and handle:FindFirstChild("Click") then handle.Click:Play() end
			return
		end

		L.down = true
		local shootType = tonumber(L.data.ShootType) or 1
		local rate = tonumber(L.data.ShootRate) or 600
		local myGun = DualWield.gun

		task.spawn(function()
			if shootType == 3 then					-- automatica
				while L.down and DualWield.gun == myGun and leftReady() and L.ammo > 0 do
					L.shooting = true
					shootLeftOnce()
					task.wait(60 / rate)
					L.shooting = false
				end
				L.shooting = false

			elseif shootType == 2 then				-- rafaga: un click, rafaga entera
				local shots = math.max(1, math.floor(tonumber(L.data.BurstShot) or 3))
				local burstRate = rate * (tonumber(L.data.BurstRateMultiplier) or 1)
				if burstRate <= 0 then burstRate = rate end
				L.shooting = true
				for i = 1, shots do
					if DualWield.gun ~= myGun or not leftReady() or L.ammo <= 0 then break end
					shootLeftOnce()
					if i < shots then task.wait(60 / burstRate) end
				end
				task.wait(tonumber(L.data.BurstCooldown) or (60 / rate))
				L.shooting = false

			elseif shootType == 6 then				-- carga (Revolver R8 y demas)
				L.shooting = true
				local ok, err = pcall(chargeLeft, myGun, rate)
				if not ok then warn("[DUAL] carga de la izquierda: " .. tostring(err)) end
				L.shooting = false

			else									-- semi, pump y cerrojo
				L.shooting = true
				shootLeftOnce()
				task.wait(60 / rate)
				-- bomba y cerrojo: la misma pausa extra que les da Shoot()
				if shootType == 4 or shootType == 5 then task.wait(0.15) end
				L.shooting = false
			end
		end)
	end

	--==================================================================
	--  [22/09] ANIMACION DE RECARGA GENERAL PARA DUALES
	--  Cada pistola trae su propia ReloadAnim pensada para UNA mano (el
	--  brazo izquierdo mete el cargador). En duales el brazo izquierdo
	--  copia en espejo al derecho, asi que con unas pistolas las dos
	--  bajaban y con otras subian. Esta es una sola para todas: ambos
	--  brazos suben, las pistolas apuntan hacia arriba, caen los
	--  cargadores, entran los nuevos y (si alguna estaba vacia) se suelta
	--  la corredera. Solo se mueve el brazo derecho; el izquierdo lo
	--  sigue en espejo.
	--  which: "both" | "right" | "left" = que pistolas cambian cargador.
	--  Tiempos y angulo en DualConfig (ReloadTime, EmptyReloadExtra,
	--  ReloadUpAngle).
	--==================================================================
	function DualWield.leftReloading()
		return L.reloading == true
	end

	function DualWield.reloadAnim(empty, which)
		if not (RArmWeld and AnimData) then return end
		which = which or "both"
		if which ~= "right" and L.data and L.ammo <= 0 then empty = true end

		local guns = {}
		if which ~= "left" and WeaponInHand then table.insert(guns, WeaponInHand) end
		if which ~= "right" and DualWield.gun then table.insert(guns, DualWield.gun) end

		local function sound(name)
			for _, g in ipairs(guns) do
				local h = g:FindFirstChild("Handle")
				local s = h and h:FindFirstChild(name)
				if s and s:IsA("Sound") then s:Play() end
			end
		end
		local function mags(t)
			for _, g in ipairs(guns) do
				local m = g:FindFirstChild("Mag")
				if m and m:IsA("BasePart") then m.Transparency = t end
			end
		end
		local function pose(angle, z, t, style)
			if not RArmWeld then return end
			TS:Create(RArmWeld, TweenInfo.new(t, style or Enum.EasingStyle.Sine),
				{ C1 = (CFrame.new(0.05, -0.15, z) * CFrame.Angles(math.rad(angle), math.rad(-12), 0)):Inverse() }):Play()
		end

		local total = RELOAD.time + (empty and RELOAD.emptyExtra or 0)
		local up = RELOAD.upAngle

		-- 1) subir los brazos, pistolas hacia arriba
		pose(up, 0.3, 0.25)
		task.wait(0.25)

		-- 2) sacudida hacia arriba: caen los cargadores
		sound("MagOut")
		mags(1)
		pose(up + 12, 0.4, 0.3, Enum.EasingStyle.Back)
		task.wait(math.max(0.1, total * 0.45))

		-- 3) bajan un poco: meter cargadores nuevos
		pose(up - 6, 0.25, 0.25)
		sound("AimUp")
		task.wait(math.max(0.1, total * 0.3))
		sound("MagIn")
		mags(0)

		-- 4) vacias: soltar la corredera
		if empty then
			task.wait(0.15)
			for _, g in ipairs(guns) do
				local h = g:FindFirstChild("Handle")
				local slide = h and h:FindFirstChild("Slide")
				if slide and slide:IsA("Motor6D") then
					TS:Create(slide, TweenInfo.new(0.05, Enum.EasingStyle.Linear), { C0 = CFrame.new() }):Play()
				end
				local bolt = g:FindFirstChild("Bolt")
				local release = bolt and bolt:FindFirstChild("SlideRelease")
				if release and release:IsA("Sound") then release:Play() end
			end
		end
		task.wait(0.15)

		-- 5) de vuelta a la pose normal
		local rest = AnimData and AnimData.RArmCFrame
		if RArmWeld and typeof(rest) == "CFrame" then
			TS:Create(RArmWeld, TweenInfo.new(0.25, Enum.EasingStyle.Sine), { C1 = rest:Inverse() }):Play()
		end
		task.wait(0.2)
	end

	--  R recarga las DOS. La izquierda sigue el ritmo de la derecha, y como
	--  el brazo izquierdo copia su animacion en espejo, las dos manos
	--  recargan juntas. Si la derecha estaba llena, la izquierda se recarga
	--  sola con la misma animacion.
	function DualWield.reload()
		if not (DualWield.active and L.data and L.tool) then return end
		if L.reloading then return end

		local full = (tonumber(L.data.Ammo) or 0) + (L.data.IncludeChamberedBullet and 1 or 0)
		if L.ammo >= full or L.stored <= 0 then return end

		L.reloading = true
		L.down = false
		local myGun = DualWield.gun

		local t0 = os.clock()
		repeat task.wait() until reloading or os.clock() - t0 > 0.3 or DualWield.gun ~= myGun
		if reloading then
			repeat task.wait() until not reloading or DualWield.gun ~= myGun
		elseif DualWield.gun == myGun then
			DualWield.reloadAnim(L.ammo <= 0, "left")	-- solo la izquierda
		end

		if DualWield.active and DualWield.gun == myGun then
			local needed = full - L.ammo
			if needed > L.stored then
				L.ammo += L.stored
				L.stored = 0
			else
				L.ammo += needed
				L.stored -= needed
			end
			saveAmmo()
			UpdateGui()
		end
		L.reloading = false
	end

	--  Municion y nombre de la izquierda en el HUD del arma.
	function DualWield.hud(HUD)
		if not (L.data and HUD) then return end
		local f = HUD:FindFirstChild("FText")
		if f then f.Text = f.Text .. "   ·   IZQ " .. L.ammo .. "/" .. L.stored end
		local n = HUD:FindFirstChild("NText")
		if n and L.data.gunName then n.Text = n.Text .. "  +  " .. L.data.gunName end
	end

	-- Cada frame el brazo izquierdo copia al derecho en espejo, y la
	-- dispersion y el retroceso de la izquierda bajan solos, igual que los
	-- de cualquier arma cuando dejas de disparar.
	Run.RenderStepped:Connect(function()
		if not DualWield.active then return end

		local arm = state.armMotor
		if arm and arm.Parent and RArmWeld then
			arm.C1 = mirror(rightArmFrame(), state.planeX):Inverse()
		end

		if L.data and not L.shooting
			and (time() - L.lastShot) > (60 / (tonumber(L.data.ShootRate) or 600)) * 2 then
			L.spread = math.max(L.data.MinSpread * L.mods.MinSpread,
				L.spread - L.data.AimInaccuracyDecrease * L.mods.AimInaccuracyDecrease)
			L.power = math.max(L.data.MinRecoilPower * L.mods.MinRecoilPower,
				L.power - L.data.RecoilPowerStepAmount * L.mods.RecoilPowerStepAmount)
		end
	end)
end)()

--==========================================================================
--  [R15 23/09] BRAZOS R15 EN PRIMERA PERSONA  (piloto: armas de WIP/TEST)
--
--  El Viewmodel de ACS trae dos bloques R6 ("Left Arm" / "Right Arm") sin
--  codo: por eso en primera persona los brazos se ven R6 aunque el juego
--  sea R15. Esto los viste con brazo, antebrazo y mano R15 (copias de los
--  del propio personaje, con su camisa y su color de piel):
--    · Los bloques R6 siguen existiendo pero INVISIBLES. Las animaciones
--      de cada arma los mueven igual que siempre y el arma sigue soldada
--      a ellos: no hay que reescribir ninguna animacion para usar esto.
--    · Mano y antebrazo copian al bloque R6 (lo que ves en pantalla queda
--      donde lo puso la animacion original).
--    · El brazo (hombro-codo) sale del codo hacia un hombro fijo al
--      cuerpo: ahi aparece el codo doblado.
--  Se activa por arma con  self.R15Arms = true  en su ACS_Animations, o
--  para todas con CONFIG.ForceAll. Ajustes opcionales por arma, pisan al
--  CONFIG:  self.R15Config = { ShoulderR = Vector3.new(...), WidthScale = 1.1 }
--  Global + funcion anonima: este chunk esta al limite de 200 locals.
--  Respaldo: ServerStorage.Respaldo_antes_23092026.ACS_Framework_23092026_antesBrazosR15
--==========================================================================
R15Arms = { active = false }
;(function()
	local CONFIG = {
		Enabled     = true,
		ForceAll    = false,	-- true = todas las armas, sin mirar self.R15Arms
		Debug       = false,	-- imprime las medidas al equipar

		-- Hombros en espacio de CAMARA (x derecha, y arriba, z hacia atras).
		-- El brazo (hombro-codo) apunta desde el codo hacia este punto.
		ShoulderR   = Vector3.new( 0.9, -1.35, 0.45),
		ShoulderL   = Vector3.new(-0.9, -1.35, 0.45),

		LengthScale = 1.0,	-- largo total del brazo R15 respecto del bloque R6
		WidthScale  = 1.0,	-- grosor respecto del bloque R6 (1 = igual que antes)
		CastShadow  = false,
	}

	local SIDES = {
		{ key = "R", up = "RightUpperArm", low = "RightLowerArm", hand = "RightHand",
		  sh = "RightShoulderRigAttachment", el = "RightElbowRigAttachment", wr = "RightWristRigAttachment" },
		{ key = "L", up = "LeftUpperArm", low = "LeftLowerArm", hand = "LeftHand",
		  sh = "LeftShoulderRigAttachment", el = "LeftElbowRigAttachment", wr = "LeftWristRigAttachment" },
	}

	-- Medidas de un brazo R15 estandar, por si el personaje no trae las
	-- piezas o sus attachments de rig.
	local DEFAULT = {
		upSize = Vector3.new(1, 1.169, 1), lowSize = Vector3.new(1, 1.052, 1), handSize = Vector3.new(1, 0.3, 1),
		upSh = Vector3.new(0, 0.42, 0), upEl = Vector3.new(0, -0.334, 0),
		lowEl = Vector3.new(0, 0.26, 0), lowWr = Vector3.new(0, -0.5, 0),
		handWr = Vector3.new(0, 0.125, 0),
	}

	local RENDER_NAME = "ACS_R15Arms"
	local state = nil

	local function attPos(part, name, fallback)
		local a = part and part:FindFirstChild(name)
		if a and a:IsA("Attachment") then return a.Position end
		return fallback
	end

	-- Rotacion que lleva el eje local "dir" (casi siempre +Y) al +Y.
	-- Sirve para que la linea entre dos attachments de rig quede exacta
	-- aunque tengan un poco de X/Z.
	local function alignInv(dir)
		if dir.Magnitude < 1e-4 then return CFrame.new() end
		local y = dir.Unit
		local z = Vector3.zAxis - y * y.Z
		if z.Magnitude < 1e-4 then z = Vector3.xAxis - y * y.X end
		z = z.Unit
		local x = y:Cross(z)
		return CFrame.fromMatrix(Vector3.zero, x, y, z):Inverse()
	end

	local function scaleVec(v, k, kw)
		return Vector3.new(v.X * kw, v.Y * k, v.Z * kw)
	end

	-- Copia limpia de una pieza del personaje (o una pieza lisa si no hay).
	local function makeSegment(src, name, size, color)
		local p
		if src and src:IsA("BasePart") then
			p = src:Clone()
			for _, d in ipairs(p:GetDescendants()) do
				if d:IsA("JointInstance") or d:IsA("Constraint") or d:IsA("Attachment")
					or d:IsA("LuaSourceContainer") or d:IsA("WrapTarget") or d:IsA("WrapLayer") then
					d:Destroy()
				end
			end
		else
			p = Instance.new("Part")
			p.Material = Enum.Material.SmoothPlastic
			if color then p.Color = color end
		end
		p.Name = name
		p.Size = size
		p.Anchored = false
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Massless = true
		p.CastShadow = CONFIG.CastShadow
		p.Transparency = 0
		p.LocalTransparencyModifier = 0
		return p
	end

	-- CFrame del bloque R6 visto desde AnimPart, leido de su Motor6D
	-- (RightArm / LeftArm, o DualLeftArm en pistolas duales).
	local function armFrame(arm)
		for _, j in ipairs(AnimPart:GetChildren()) do
			if j:IsA("Motor6D") and j.Part1 == arm and j.Part0 == AnimPart and j.Enabled then
				return j.C0 * j.Transform * j.C1:Inverse()
			end
		end
		if arm.Parent then
			return AnimPart.CFrame:ToObjectSpace(arm.CFrame)
		end
		return nil
	end

	local function place(s)
		local cf = armFrame(s.arm)
		if not cf then return end

		local rot = cf.Rotation
		local up  = cf.UpVector
		local W   = cf.Position - up * (s.H * 0.5) + up * s.handLen	-- muneca
		local E   = W + up * s.foreLen									-- codo

		s.mHand.C0 = CFrame.new(W) * rot * s.handOff
		s.mLow.C0  = CFrame.new(W) * rot * s.lowOff

		-- Brazo: del codo hacia el hombro. Su frente (-Z) mira hacia donde
		-- va el antebrazo, asi el codo siempre dobla como uno de verdad.
		local toS = s.shoulder - E
		local Yu  = (toS.Magnitude > 0.05) and toS.Unit or up
		local f   = -up
		local front = f - Yu * f:Dot(Yu)
		if front.Magnitude < 1e-3 then
			local lv = cf.LookVector
			front = lv - Yu * lv:Dot(Yu)
		end
		if front.Magnitude < 1e-3 then return end
		local Zu = -front.Unit
		local Xu = Yu:Cross(Zu)
		local R  = CFrame.fromMatrix(Vector3.zero, Xu, Yu, Zu) * s.upAlign
		s.mUp.C0 = CFrame.new(E) * R * CFrame.new(-s.upEl)

		if s.arm.Transparency ~= 1 then s.arm.Transparency = 1 end
	end

	local function step()
		if not (state and AnimPart and AnimPart.Parent) then return end
		for _, s in ipairs(state.sides) do
			if s.arm and s.arm.Parent then
				local ok, err = pcall(place, s)
				if not ok and CONFIG.Debug then warn("[R15Arms]", err) end
			end
		end
	end

	function R15Arms.detach()
		pcall(function() Run:UnbindFromRenderStep(RENDER_NAME) end)
		if state then
			for _, s in ipairs(state.sides) do
				if s.arm and s.arm.Parent then s.arm.Transparency = s.oldTransparency or 0 end
			end
			if state.model then state.model:Destroy() end
		end
		state = nil
		R15Arms.active = false
	end

	-- Se llama desde setup() con el viewmodel ya armado (y la pistola
	-- izquierda montada si es dual), antes de EquipAnim.
	function R15Arms.attach()
		R15Arms.detach()
		if not CONFIG.Enabled then return end
		if not (ViewModel and AnimPart and LArm and RArm and AnimData) then return end
		if not (CONFIG.ForceAll or AnimData.R15Arms == true) then return end

		local perWeapon = (type(AnimData.R15Config) == "table") and AnimData.R15Config or {}
		local function opt(k)
			if perWeapon[k] ~= nil then return perWeapon[k] end
			return CONFIG[k]
		end

		local main = (typeof(AnimData.MainCFrame) == "CFrame") and AnimData.MainCFrame or CFrame.new()
		local camToAnim = (NearZ * main):Inverse()

		local model = Instance.new("Model")
		model.Name = "R15Arms"

		-- Humanoid propio (R15) para que la camisa y el color de piel se
		-- apliquen a las piezas R15; el del Viewmodel es R6.
		local hum = Instance.new("Humanoid")
		hum.RigType = Enum.HumanoidRigType.R15
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
		hum.RequiresNeck = false
		hum.BreakJointsOnDeath = false
		hum.EvaluateStateMachine = false
		hum.Parent = model

		local shirt = char:FindFirstChildOfClass("Shirt")
		if shirt then shirt:Clone().Parent = model end
		local colors = char:FindFirstChildOfClass("BodyColors")
		if colors then colors:Clone().Parent = model end

		local sides = {}
		for _, def in ipairs(SIDES) do
			local arm = (def.key == "R") and RArm or LArm
			local srcUp   = char:FindFirstChild(def.up)
			local srcLow  = char:FindFirstChild(def.low)
			local srcHand = char:FindFirstChild(def.hand)

			local upSize   = srcUp and srcUp.Size or DEFAULT.upSize
			local lowSize  = srcLow and srcLow.Size or DEFAULT.lowSize
			local handSize = srcHand and srcHand.Size or DEFAULT.handSize

			local upSh   = attPos(srcUp,   def.sh, DEFAULT.upSh)
			local upEl   = attPos(srcUp,   def.el, DEFAULT.upEl)
			local lowEl  = attPos(srcLow,  def.el, DEFAULT.lowEl)
			local lowWr  = attPos(srcLow,  def.wr, DEFAULT.lowWr)
			local handWr = attPos(srcHand, def.wr, DEFAULT.handWr)

			-- Escala: el brazo R15 completo (hombro -> punta de la mano)
			-- mide lo mismo que el bloque R6; el grosor igual al del bloque.
			-- OJO: el attachment del hombro de R15 esta corrido hacia el torso
			-- (X ~ -0.5); del brazo solo cuenta el largo vertical.
			local H = arm.Size.Y
			local total0 = math.abs(upSh.Y - upEl.Y) + (lowEl - lowWr).Magnitude + (handWr.Y + handSize.Y * 0.5)
			local k  = (H * opt("LengthScale")) / math.max(total0, 0.1)
			local kw = (arm.Size.X * opt("WidthScale")) / math.max(upSize.X, 0.1)

			upSh, upEl   = scaleVec(upSh, k, kw), scaleVec(upEl, k, kw)
			lowEl, lowWr = scaleVec(lowEl, k, kw), scaleVec(lowWr, k, kw)
			handWr       = scaleVec(handWr, k, kw)
			local handSz = scaleVec(handSize, k, kw)

			local skin = arm.Color
			local pUp   = makeSegment(srcUp,   def.up,   scaleVec(upSize, k, kw),  skin)
			local pLow  = makeSegment(srcLow,  def.low,  scaleVec(lowSize, k, kw), skin)
			local pHand = makeSegment(srcHand, def.hand, handSz,                    skin)
			pUp.Parent, pLow.Parent, pHand.Parent = model, model, model

			local function motor(part)
				local m = Instance.new("Motor6D")
				m.Name = "R15_" .. part.Name
				m.Part0 = AnimPart
				m.Part1 = part
				m.Parent = model
				return m
			end

			local shoulderCam = opt("Shoulder" .. def.key)
			if typeof(shoulderCam) ~= "Vector3" then shoulderCam = CONFIG["Shoulder" .. def.key] end

			table.insert(sides, {
				arm      = arm,
				oldTransparency = arm.Transparency,
				H        = H,
				handLen  = handWr.Y + handSz.Y * 0.5,
				foreLen  = (lowEl - lowWr).Magnitude,
				upEl     = upEl,
				upAlign  = CFrame.new(),
				handOff  = CFrame.new(-handWr),
				lowOff   = alignInv(lowEl - lowWr) * CFrame.new(-lowWr),
				shoulder = camToAnim * shoulderCam,
				mUp = motor(pUp), mLow = motor(pLow), mHand = motor(pHand),
			})

			if opt("Debug") then
				print(string.format("[R15Arms] %s  H=%.2f k=%.2f kw=%.2f  brazo=%.2f antebrazo=%.2f mano=%.2f  piezas=%s",
					def.key, H, k, kw, math.abs(upSh.Y - upEl.Y), (lowEl - lowWr).Magnitude,
					handWr.Y + handSz.Y * 0.5, srcUp and "personaje" or "lisas"))
			end
		end

		model.Parent = ViewModel
		state = { model = model, sides = sides }
		R15Arms.active = true

		step()
		Run:BindToRenderStep(RENDER_NAME, Enum.RenderPriority.Last.Value, step)
	end
end)()

function setup(Tool)
	if char and char:WaitForChild("Humanoid").Health > 0 and Tool ~= nil then

		-- Limpiar variables globales del arma anterior ANTES de todo
		Ammo = 0
		StoredAmmo = 0

		ToolEquip = true
		User.MouseIconEnabled = false
		plr.CameraMode = Enum.CameraMode.LockFirstPerson

		WeaponTool = Tool
		local settings = require(Tool:WaitForChild("ACS_Settings"))

		-- Primero copiamos toda la configuracion normalmente
		WeaponData = {}
		for key, value in pairs(settings) do
			WeaponData[key] = value
		end

		-- ===== ACCESORIOS POR JUGADOR (blindado) =====
		-- LoadoutServer escribe estos atributos en el clon del Tool.
		-- Atributo ausente = usar el default del ACS_Settings.
		-- Atributo = "" = el jugador lo quito a proposito.
		local attOk, attErr = pcall(function()
			local function resolveAtt(attrName, fallback)
				local chosen = Tool:GetAttribute(attrName)
				if chosen == nil then return fallback or "" end
				if type(chosen) ~= "string" or chosen == "" then return "" end
				if AttModels:FindFirstChild(chosen) and AttModules:FindFirstChild(chosen) then
					return chosen
				end
				warn("[ACS] Accesorio invalido en "..Tool.Name..": "..tostring(chosen))
				return ""
			end

			WeaponData.SightAtt       = resolveAtt("Att_Sight",       WeaponData.SightAtt)
			WeaponData.BarrelAtt      = resolveAtt("Att_Barrel",      WeaponData.BarrelAtt)
			WeaponData.UnderBarrelAtt = resolveAtt("Att_UnderBarrel", WeaponData.UnderBarrelAtt)
			WeaponData.OtherAtt       = resolveAtt("Att_Other",       WeaponData.OtherAtt)

			-- MUNICION: no lleva modelo, asi que NO se valida contra
			-- AttModels; basta con que exista el ModuleScript.
			local function resolveAmmo(fallback)
				local chosen = Tool:GetAttribute("Att_Ammo")
				if chosen == nil then return fallback or "" end
				if type(chosen) ~= "string" or chosen == "" then return "" end
				if AttModules:FindFirstChild(chosen) then return chosen end
				warn("[ACS] Municion invalida en "..Tool.Name..": "..tostring(chosen))
				return ""
			end

			WeaponData.AmmoAtt = resolveAmmo(WeaponData.AmmoAtt)
		end)
		if not attOk then
			warn("[ACS] Bloque de accesorios fallo: "..tostring(attErr))
		end

		local savedJammed = Tool:GetAttribute("Jammed")
		if savedJammed ~= nil then
			WeaponData.Jammed = savedJammed
		else
			WeaponData.Jammed = false
		end

		-- Restaurar municion
		local savedAmmo = Tool:GetAttribute("CurrentAmmo")
		local savedStored = Tool:GetAttribute("CurrentStored")

		if savedAmmo ~= nil then
			Ammo = savedAmmo
			WeaponData.AmmoInGun = savedAmmo
		else
			-- Primera vez que se equipa esta arma, usar valores del settings
			Ammo = WeaponData.Ammo or 0
			WeaponData.AmmoInGun = Ammo
		end

		if savedStored ~= nil then
			StoredAmmo = savedStored
			WeaponData.StoredAmmo = savedStored
		else
			StoredAmmo = WeaponData.StoredAmmo or 0
			WeaponData.StoredAmmo = StoredAmmo
		end

		-- Asegurar que sean numeros validos
		Ammo = tonumber(Ammo) or 0
		StoredAmmo = tonumber(StoredAmmo) or 0
		WeaponData.AmmoInGun = Ammo
		WeaponData.StoredAmmo = StoredAmmo

		dprint("[SETUP]", Tool.Name, "Ammo:", Ammo, "Stored:", StoredAmmo)

		AnimData = require(Tool:WaitForChild("ACS_Animations"))
		WeaponInHand = GunModels:WaitForChild(Tool.Name):Clone()
		WeaponInHand.PrimaryPart = WeaponInHand:WaitForChild("Handle")

		if WeaponInHand.Handle:FindFirstChild("GunEquip") then
			WeaponInHand.Handle.GunEquip:Play()
		end

		Evt.Equip:FireServer(Tool,1,WeaponData,AnimData)

		ViewModel = ArmModel:WaitForChild("Arms"):Clone()
		ViewModel.Name = "Viewmodel"

		if char:FindFirstChild("Body Colors") ~= nil then
			local Colors = char:WaitForChild("Body Colors"):Clone()
			Colors.Parent = ViewModel
		end

		if char:FindFirstChild("Shirt") ~= nil then
			local Shirt = char:FindFirstChild("Shirt"):Clone()
			Shirt.Parent = ViewModel
		end

		AnimPart = Instance.new("Part")
		AnimPart.Size = Vector3.new(0.1,0.1,0.1)
		AnimPart.Anchored = true
		AnimPart.CanCollide = false
		AnimPart.Transparency = 1
		AnimPart.Parent = ViewModel

		ViewModel.PrimaryPart = AnimPart

		LArmWeld = Instance.new("Motor6D")
		LArmWeld.Name = "LeftArm"
		LArmWeld.Part0 = AnimPart
		LArmWeld.Parent = AnimPart

		RArmWeld = Instance.new("Motor6D")
		RArmWeld.Name = "RightArm"
		RArmWeld.Part0 = AnimPart
		RArmWeld.Parent = AnimPart

		GunWeld = Instance.new("Motor6D")
		GunWeld.Name = "Handle"
		GunWeld.Parent = AnimPart

		--setup arms to camera
		ViewModel.Parent = cam

		maincf = AnimData.MainCFrame
		guncf = AnimData.GunCFrame

		larmcf = AnimData.LArmCFrame
		rarmcf = AnimData.RArmCFrame

		if  WeaponData.CrossHair then
			TS:Create(Crosshair.Up, TweenInfo.new(.2,Enum.EasingStyle.Linear), {BackgroundTransparency = 0}):Play()
			TS:Create(Crosshair.Down, TweenInfo.new(.2,Enum.EasingStyle.Linear), {BackgroundTransparency = 0}):Play()
			TS:Create(Crosshair.Left, TweenInfo.new(.2,Enum.EasingStyle.Linear), {BackgroundTransparency = 0}):Play()
			TS:Create(Crosshair.Right, TweenInfo.new(.2,Enum.EasingStyle.Linear), {BackgroundTransparency = 0}):Play()

			if WeaponData.Bullets > 1 then
				Crosshair.Up.Rotation = 90
				Crosshair.Down.Rotation = 90
				Crosshair.Left.Rotation = 90
				Crosshair.Right.Rotation = 90
			else
				Crosshair.Up.Rotation = 0
				Crosshair.Down.Rotation = 0
				Crosshair.Left.Rotation = 0
				Crosshair.Right.Rotation = 0
			end

		else
			TS:Create(Crosshair.Up, TweenInfo.new(.2,Enum.EasingStyle.Linear), {BackgroundTransparency = 1}):Play()
			TS:Create(Crosshair.Down, TweenInfo.new(.2,Enum.EasingStyle.Linear), {BackgroundTransparency = 1}):Play()
			TS:Create(Crosshair.Left, TweenInfo.new(.2,Enum.EasingStyle.Linear), {BackgroundTransparency = 1}):Play()
			TS:Create(Crosshair.Right, TweenInfo.new(.2,Enum.EasingStyle.Linear), {BackgroundTransparency = 1}):Play()
		end

		if  WeaponData.CenterDot then
			TS:Create(Crosshair.Center, TweenInfo.new(.2,Enum.EasingStyle.Linear), {ImageTransparency = 0}):Play()
		else
			TS:Create(Crosshair.Center, TweenInfo.new(.2,Enum.EasingStyle.Linear), {ImageTransparency = 1}):Play()
		end

		LArm = ViewModel:WaitForChild("Left Arm")
		LArmWeld.Part1 = LArm
		LArmWeld.C0 = CFrame.new()
		LArmWeld.C1 = CFrame.new(1,-1,-5) * CFrame.Angles(math.rad(0),math.rad(0),math.rad(0)):inverse()

		RArm = ViewModel:WaitForChild("Right Arm")
		RArmWeld.Part1 = RArm
		RArmWeld.C0 = CFrame.new()
		RArmWeld.C1 = CFrame.new(-1,-1,-5) * CFrame.Angles(math.rad(0),math.rad(0),math.rad(0)):inverse()
		GunWeld.Part0 = RArm

		LArm.Anchored = false
		RArm.Anchored = false

		--setup weapon to camera
		ModTable.ZoomValue 		= WeaponData.Zoom
		ModTable.Zoom2Value 	= WeaponData.Zoom2
		IREnable 				= WeaponData.InfraRed

		-- Disparo
		-- [15/09] Con el HUD tactil propio (PlatformControls) no se crean los
		-- circulos genericos de ACS; sin el, quedan como antes.
		_G.LL_Bind("Fire", handleAction, not _G.LL_CustomTouchHUD, Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonR2)
		CAS:SetTitle("Fire", "Fire")
		CAS:SetPosition("Fire", UDim2.new(1, -140, 1, -160))

		-- Apuntar
		_G.LL_Bind("ADS", handleAction, not _G.LL_CustomTouchHUD, Enum.UserInputType.MouseButton2, Enum.KeyCode.ButtonL2)
		CAS:SetTitle("ADS", "Aim")
		CAS:SetPosition("ADS", UDim2.new(1, -100, 1, -100))

		-- Recargar
		_G.LL_Bind("Reload", handleAction, not _G.LL_CustomTouchHUD, Enum.KeyCode.R, Enum.KeyCode.ButtonX)
		CAS:SetTitle("Reload", "RL")
		CAS:SetPosition("Reload", UDim2.new(0, 20, 1, -160))

		_G.LL_Bind("CycleAimpart", handleAction, false, Enum.KeyCode.T, Enum.KeyCode.ButtonR3)

		_G.LL_Bind("CycleLaser", handleAction, not _G.LL_CustomTouchHUD, Enum.KeyCode.H, Enum.KeyCode.DPadLeft)
		CAS:SetTitle("CycleLaser", "Laser")
		CAS:SetPosition("CycleLaser", UDim2.new(0, 20, 1, -220))

		_G.LL_Bind("CycleLight", handleAction, false, Enum.KeyCode.J, Enum.KeyCode.DPadRight)
		CAS:SetTitle("CycleLight", "Light")
		CAS:SetPosition("CycleLight", UDim2.new(0, 120, 1, -220))

		_G.LL_Bind("CycleFiremode", handleAction, false, Enum.KeyCode.V, Enum.KeyCode.DPadUp)
		_G.LL_Bind("CheckMag", handleAction, false, Enum.KeyCode.M)
		_G.LL_Bind("ZeroDown", handleAction, false, Enum.KeyCode.LeftBracket)
		_G.LL_Bind("ZeroUp", handleAction, false, Enum.KeyCode.RightBracket)

		loadAttachment(WeaponInHand)

		-- Ya estan aplicados los mods del arma y sus accesorios:
		-- recalcular la velocidad con el peso de esta arma.
		ApplyMoveSpeed()

		BSpread				= math.min(WeaponData.MinSpread * ModTable.MinSpread, WeaponData.MaxSpread * ModTable.MaxSpread)
		RecoilPower 		= math.min(WeaponData.MinRecoilPower * ModTable.MinRecoilPower, WeaponData.MaxRecoilPower * ModTable.MaxRecoilPower)

		CurAimpart = WeaponInHand:FindFirstChild("AimPart")

		--==================================================================
		--  [F-07] Un solo GetDescendants() por equipamiento, en vez de dos
		--  por frame. Aprovechamos el mismo recorrido para detectar
		--  FlashPoint / LaserPoint y para cachear SightMark / LaserPoint.
		--==================================================================
		table.clear(SightMarks)
		table.clear(LaserPoints)
		for _, Key in ipairs(WeaponInHand:GetDescendants()) do
			if Key:IsA("BasePart") then
				if Key.Name == "FlashPoint" then
					TorchAtt = true
				elseif Key.Name == "LaserPoint" then
					LaserAtt = true
					table.insert(LaserPoints, Key)
				elseif Key.Name == "SightMark" then
					table.insert(SightMarks, Key)
				end
			end
		end

		if WeaponData.EnableHUD then
			SE_GUI.GunHUD.Visible = true
		end
		UpdateGui()

		for index, key in pairs(WeaponInHand:GetChildren()) do
			if key:IsA('BasePart') and key.Name ~= 'Handle' then

				if key.Name ~= "Bolt" and key.Name ~= 'Lid' and key.Name ~= "Slide" then
					Ultil.Weld(WeaponInHand:WaitForChild("Handle"), key)
				end

				if key.Name == "Bolt" or key.Name == "Slide" then
					Ultil.WeldComplex(WeaponInHand:WaitForChild("Handle"), key, key.Name)
				end;

				if key.Name == "Lid" then
					if WeaponInHand:FindFirstChild('LidHinge') then
						Ultil.Weld(key, WeaponInHand:WaitForChild("LidHinge"))
					else
						Ultil.Weld(key, WeaponInHand:WaitForChild("Handle"))
					end
				end
			end
		end;

		for L_213_forvar1, L_214_forvar2 in pairs(WeaponInHand:GetChildren()) do
			if L_214_forvar2:IsA('BasePart') then
				L_214_forvar2.Anchored = false
				L_214_forvar2.CanCollide = false
			end
		end;

		if WeaponInHand:FindFirstChild("Nodes") then
			for L_213_forvar1, L_214_forvar2 in pairs(WeaponInHand.Nodes:GetChildren()) do
				if L_214_forvar2:IsA('BasePart') then
					Ultil.Weld(WeaponInHand:WaitForChild("Handle"), L_214_forvar2)
					L_214_forvar2.Anchored = false
					L_214_forvar2.CanCollide = false
				end
			end;
		end

		GunWeld.Part1 = WeaponInHand:WaitForChild("Handle")
		GunWeld.C1 = guncf

		WeaponInHand.Parent = ViewModel
		if Ammo <= 0 and WeaponData.Type == "Gun" then
			WeaponInHand.Handle.Slide.C0 = WeaponData.SlideEx:inverse()
		end
		DualWield.attach(Tool)		-- [DUAL 22/09] pistola izquierda (si el Tool la trae)
		if DualWield.active then UpdateGui() end	-- que el HUD muestre ya la izquierda
		R15Arms.attach()			-- [R15 23/09] brazos R15 (si el arma lo pide)
		EquipAnim()
		if WeaponData and WeaponData.Type ~= "Grenade" then
			RunCheck()
		end
	end
end
function unset()
	dprint("[UNSET]", WeaponTool and WeaponTool.Name or "nil", "Ammo:", Ammo, "Stored:", StoredAmmo)
	DualWield.detach()		-- [DUAL 22/09] el modelo se va con el ViewModel
	R15Arms.detach()		-- [R15 23/09]

	-- GUARDAR PRIMERO, antes de hacer NADA
	if WeaponTool and WeaponTool:IsDescendantOf(game) and WeaponData then
		WeaponTool:SetAttribute("CurrentAmmo", Ammo)
		WeaponTool:SetAttribute("CurrentStored", StoredAmmo)
		WeaponTool:SetAttribute("Jammed", WeaponData.Jammed or false)

		if DEBUG then
			local verificarAmmo = WeaponTool:GetAttribute("CurrentAmmo")
			local verificarStored = WeaponTool:GetAttribute("CurrentStored")
			if verificarAmmo ~= Ammo or verificarStored ~= StoredAmmo then
				warn("[UNSET] La municion NO se guardo correctamente")
			end
		end
	end

	-- NO LIMPIAR AQUI - se limpia en setup() para evitar race conditions

	ToolEquip = false
	StopHeal()

	-- Cancelar recarga
	if reloading then
		CancelReload = true
		reloading = false
	end

	Evt.Equip:FireServer(WeaponTool,2)

	--unsetup weapon data module
	CAS:UnbindAction("Fire")
	CAS:UnbindAction("ADS")
	CAS:UnbindAction("Reload")
	CAS:UnbindAction("CycleLaser")
	CAS:UnbindAction("CycleLight")
	CAS:UnbindAction("CycleFiremode")
	CAS:UnbindAction("CycleAimpart")
	CAS:UnbindAction("ZeroUp")
	CAS:UnbindAction("ZeroDown")
	CAS:UnbindAction("CheckMag")
	CAS:UnbindAction("ToggleBipod")

	-- Resetear variables de estado
	mouse1down = false
	aimming = false
	shooting = false
	reloading = false
	pumpCooldown = false
	boltCooldown = false
	isCharging = false
	CancelReload = false

	-- Detener sonido Charge
	if ActiveChargeSound and ActiveChargeSound.IsPlaying then
		ActiveChargeSound:Stop()
	end
	ActiveChargeSound = nil
	if ActiveFullSound and ActiveFullSound.IsPlaying then
		ActiveFullSound:Stop()
	end
	ActiveFullSound = nil

	SetFOV(70)								-- [F-06]
	TS:Create(Crosshair.Up, TweenInfo.new(.2,Enum.EasingStyle.Linear), {BackgroundTransparency = 1}):Play()
	TS:Create(Crosshair.Down, TweenInfo.new(.2,Enum.EasingStyle.Linear), {BackgroundTransparency = 1}):Play()
	TS:Create(Crosshair.Left, TweenInfo.new(.2,Enum.EasingStyle.Linear), {BackgroundTransparency = 1}):Play()
	TS:Create(Crosshair.Right, TweenInfo.new(.2,Enum.EasingStyle.Linear), {BackgroundTransparency = 1}):Play()
	TS:Create(Crosshair.Center, TweenInfo.new(.2,Enum.EasingStyle.Linear), {ImageTransparency = 1}):Play()

	User.MouseIconEnabled = true
	User.MouseDeltaSensitivity = 1
	cam.CameraType = Enum.CameraType.Custom
	plr.CameraMode = Enum.CameraMode.Classic

	if WeaponInHand then
		ViewModel:Destroy()
		ViewModel 		= nil
		WeaponInHand	= nil
		WeaponTool		= nil
		LArm 			= nil
		RArm 			= nil
		LArmWeld 		= nil
		RArmWeld 		= nil
		WeaponData 		= nil
		AnimData		= nil
		SightAtt		= nil
		reticle			= nil
		BarrelAtt 		= nil
		UnderBarrelAtt 	= nil
		OtherAtt 		= nil
		LaserAtt 		= false
		LaserActive		= false
		IRmode			= false
		TorchAtt 		= false
		TorchActive 	= false
		BipodAtt 		= false
		BipodActive 	= false
		LaserDist 		= 0
		Pointer 		= nil
		BSpread 		= nil
		RecoilPower 	= nil
		Suppressor 		= false
		FlashHider 		= false
		SafeMode		= false
		CheckingMag		= false
		GRDebounce 		= false
		CookGrenade 	= false
		if LL_Nade then LL_Nade.L, LL_Nade.R, LL_Nade.hand = false, false, false end	-- [GRANADAS CS2]
		Power = 150
		GrenadeTraj.Stop()
		GunStance 		= 0
		resetMods()
		generateBullet 	= 1
		AimPartMode 	= 1

		-- [F-07] soltar las partes cacheadas del arma que ya no existe
		table.clear(SightMarks)
		table.clear(LaserPoints)
		LastBipodColor = nil

		SE_GUI.GunHUD.Visible = false
		SE_GUI.GrenadeForce.Visible = false
		BipodCF = CFrame.new()
		if gameRules.ReplicatedLaser then
			Evt.SVLaser:FireServer(nil,2,nil,false,WeaponTool)
		end
	end

	-- Sin arma en mano se vuelve a la velocidad limpia de la postura.
	ApplyMoveSpeed()
end
local HalfStep = false
--  [15/09/2026] MIRADA EN TERCERA PERSONA (emisor)
--  Antes se mandaba el C0 del cuello ya armado ~30 veces por segundo. Ahora
--  solo se manda HACIA DONDE MIRAS (en grados, relativo al cuerpo), 12
--  veces por segundo como mucho y solo si cambio. Cada cliente arma la pose
--  (cabeza y torso) en ACS_EventHandler.
--  Formato: CFrame.new(pitch, yaw, 1)  (la Z = 1 marca el formato nuevo)
;(function()
	local SEND_RATE = 12
	local lastSent = 0
	local lastPitch, lastYaw = 999, 999

	function HeadMovement()
		local hum = char:FindFirstChildOfClass("Humanoid")
		local root = char:FindFirstChild("HumanoidRootPart")
		if not (hum and root and hum.Health > 0) then return end
		local now = os.clock()
		if now - lastSent < 1 / SEND_RATE then return end

		local pitch, yaw = 0, 0
		-- [16/09] solo cuenta si la camara te sigue a ti (no en menu,
		-- killcam ni espectador); si no, se manda mirada al frente
		if cam.CameraType == Enum.CameraType.Custom and cam.CameraSubject == hum then
			local rel = root.CFrame:VectorToObjectSpace(cam.CFrame.LookVector)
			pitch = math.floor(math.deg(math.asin(math.clamp(rel.Y, -1, 1))) + 0.5)
			-- [16/09 b] primera persona: cabeza al centro (los brazos del arma
			-- cuelgan de ella). Tercera persona: el giro lateral se desvanece al
			-- mirar hacia atras (90-130 grados) en vez de trabarse de un lado.
			-- Mismo criterio que ACS_EventHandler y FirstPersonBody.
			local firstPerson = (cam.CFrame.Position - cam.Focus.Position).Magnitude < 2.5
			if not firstPerson then
				local raw = math.deg(math.atan2(-rel.X, -rel.Z))
				local abs = math.abs(raw)
				if abs >= 130 then
					yaw = 0
				elseif abs > 90 then
					yaw = math.floor(raw * (1 - (abs - 90) / 40) + 0.5)
				else
					yaw = math.floor(raw + 0.5)
				end
			end
		end
		if math.abs(pitch - lastPitch) < 1 and math.abs(yaw - lastYaw) < 1 then return end

		lastSent = now
		lastPitch, lastYaw = pitch, yaw
		Evt.HeadRot:FireServer(CFrame.new(pitch, yaw, 1))
	end
end)()

function renderCam()
	cam.CFrame = cam.CFrame*CFrame.Angles(cameraspring.p.x,cameraspring.p.y,cameraspring.p.z)
end

--==========================================================
--  [23/09] PUNTERIA AGACHADO (estilo Rust)
--  Agachado y quieto     -> 35% menos retroceso y dispersion
--  Agachado moviendote   -> 20% menos
--  De pie / tumbado      -> normal
--  Se aplica en Recoil(), CreateBullet() y la mira. NO toca
--  WeaponData (el anti-exploit compara esa tabla). Se suma
--  (multiplica) con el bono de plataforma y el de duales.
--  Va envuelto en funcion por el limite de 200 locals.
--==========================================================
;(function()
	local CONFIG = {
		CrouchStill   = 0.65,	-- agachado y quieto (0.65 = 35% menos)
		CrouchMoving  = 0.80,	-- agachado moviendote (0.80 = 20% menos)
		Prone         = 1,		-- tumbado (1 = sin bono)
		MoveThreshold = 1,		-- studs/s horizontales para contar como "moviendote"
	}

	function LL_StanceAimMult()
		if Stances == 1 then
			local root = char and char:FindFirstChild("HumanoidRootPart")
			local moving = false
			if root then
				local v = root.AssemblyLinearVelocity
				moving = Vector3.new(v.X, 0, v.Z).Magnitude > CONFIG.MoveThreshold
			end
			return moving and CONFIG.CrouchMoving or CONFIG.CrouchStill
		elseif Stances == 2 then
			return CONFIG.Prone
		end
		return 1
	end
end)()

function renderGunRecoil()
	recoilcf = recoilcf*CFrame.Angles(RecoilSpring.p.x,RecoilSpring.p.y,RecoilSpring.p.z)
end

--  [DUAL 22/09] Con Data / Mods / Power patea con esa arma en vez de con la
--  que ACS lleva en mano (la usa la pistola izquierda). En duales el
--  retroceso de CADA pistola se multiplica por DualConfig.RecoilMult: llevas
--  dos armas, no una.
function Recoil(Data, Mods, Power)
	local WeaponData  = Data  or WeaponData
	local ModTable    = Mods  or ModTable
	local RecoilPower = Power or RecoilPower

	-- [15/09] Retroceso por plataforma (lo publica PlatformControls):
	-- celular 0.25 (75% menos), mando 0.75 (25% menos), teclado 1.
	-- Se multiplica aqui y NO en WeaponData: el anti-exploit compara esa tabla.
	local platformMult = ((_G.LL_Platform and tonumber(_G.LL_Platform.RecoilMult)) or 1)
		* ((DualWield and DualWield.active and DualWield.recoilMult) or 1)
		* LL_StanceAimMult()	-- [23/09] agachado
	local vr = (math.random(WeaponData.camRecoil.camRecoilUp[1], WeaponData.camRecoil.camRecoilUp[2])/2) * ModTable.camRecoilMod.RecoilUp
	local lr = (math.random(WeaponData.camRecoil.camRecoilLeft[1], WeaponData.camRecoil.camRecoilLeft[2])) * ModTable.camRecoilMod.RecoilLeft
	local rr = (math.random(WeaponData.camRecoil.camRecoilRight[1], WeaponData.camRecoil.camRecoilRight[2])) * ModTable.camRecoilMod.RecoilRight
	local hr = (math.random(-rr, lr)/2)
	local tr = (math.random(WeaponData.camRecoil.camRecoilTilt[1], WeaponData.camRecoil.camRecoilTilt[2])/2) * ModTable.camRecoilMod.RecoilTilt

	local RecoilX = math.rad(vr * RAND( 1, 1, .1)) * platformMult
	local RecoilY = math.rad(hr * RAND(-1, 1, .1)) * platformMult
	local RecoilZ = math.rad(tr * RAND(-1, 1, .1)) * platformMult

	local gvr = (math.random(WeaponData.gunRecoil.gunRecoilUp[1], WeaponData.gunRecoil.gunRecoilUp[2]) /10) * ModTable.gunRecoilMod.RecoilUp * platformMult
	local gdr = (math.random(-1,1) * math.random(WeaponData.gunRecoil.gunRecoilTilt[1], WeaponData.gunRecoil.gunRecoilTilt[2]) /10) * ModTable.gunRecoilMod.RecoilTilt * platformMult
	local glr = (math.random(WeaponData.gunRecoil.gunRecoilLeft[1], WeaponData.gunRecoil.gunRecoilLeft[2])) * ModTable.gunRecoilMod.RecoilLeft
	local grr = (math.random(WeaponData.gunRecoil.gunRecoilRight[1], WeaponData.gunRecoil.gunRecoilRight[2])) * ModTable.gunRecoilMod.RecoilRight

	local ghr = (math.random(-grr, glr)/10) * platformMult

	local ARR = WeaponData.AimRecoilReduction * ModTable.AimRM

	if BipodActive then
		cameraspring:accelerate(Vector3.new( RecoilX, RecoilY/2, 0 ))

		if not aimming then
			RecoilSpring:accelerate(Vector3.new( math.rad(.25 * gvr * RecoilPower), math.rad(.25 * ghr * RecoilPower), math.rad(.25 * gdr)))
			recoilcf = recoilcf * CFrame.new(0,0,.1) * CFrame.Angles( math.rad(.25 * gvr * RecoilPower ),math.rad(.25 * ghr * RecoilPower ),math.rad(.25 * gdr * RecoilPower ))

		else
			RecoilSpring:accelerate(Vector3.new( math.rad( .25 * gvr * RecoilPower/ARR) , math.rad(.25 * ghr * RecoilPower/ARR), math.rad(.25 * gdr/ ARR)))
			recoilcf = recoilcf * CFrame.new(0,0,.1) * CFrame.Angles( math.rad(.25 * gvr * RecoilPower/ARR ),math.rad(.25 * ghr * RecoilPower/ARR ),math.rad(.25 * gdr * RecoilPower/ARR ))
		end

		Thread:Wait(0.05)
		cameraspring:accelerate(Vector3.new(-RecoilX, -RecoilY/2, 0))

	else
		cameraspring:accelerate(Vector3.new( RecoilX , RecoilY, RecoilZ ))
		if not aimming then
			RecoilSpring:accelerate(Vector3.new( math.rad(gvr * RecoilPower), math.rad(ghr * RecoilPower), math.rad(gdr)))
			recoilcf = recoilcf * CFrame.new(0,-0.05,.1) * CFrame.Angles( math.rad( gvr * RecoilPower ),math.rad( ghr * RecoilPower ),math.rad( gdr * RecoilPower ))

		else
			RecoilSpring:accelerate(Vector3.new( math.rad(gvr * RecoilPower/ARR) , math.rad(ghr * RecoilPower/ARR), math.rad(gdr/ ARR)))
			recoilcf = recoilcf * CFrame.new(0,0,.1) * CFrame.Angles( math.rad( gvr * RecoilPower/ARR ),math.rad( ghr * RecoilPower/ARR ),math.rad( gdr * RecoilPower/ARR ))
		end
	end
end

function CheckForHumanoid(L_225_arg1)
	local L_226_ = false
	local L_227_ = nil
	if L_225_arg1 then
		if (L_225_arg1.Parent:FindFirstChildOfClass("Humanoid") or L_225_arg1.Parent.Parent:FindFirstChildOfClass("Humanoid")) then
			L_226_ = true
			if L_225_arg1.Parent:FindFirstChildOfClass('Humanoid') then
				L_227_ = L_225_arg1.Parent:FindFirstChildOfClass('Humanoid')
			elseif L_225_arg1.Parent.Parent:FindFirstChildOfClass('Humanoid') then
				L_227_ = L_225_arg1.Parent.Parent:FindFirstChildOfClass('Humanoid')
			end
		else
			L_226_ = false
		end
	end
	return L_226_, L_227_
end

--  [DUAL 22/09]  Ctx  = disparo de un arma que NO es la que ACS lleva en
--  mano (la pistola izquierda de las duales): { data, mods, gun, tool }.
--  Al sombrear los nombres, TODO el cuerpo de abajo sigue igual y trabaja
--  con esa arma: misma balistica, misma perforacion, mismo remote de dano
--  (con SU Tool, asi el anti-exploit compara los stats correctos).
function CastRay(Bullet, Origin, ChargeDmgMult, MaxDist, PenState, Ctx)
	local WeaponData = (Ctx and Ctx.data) or WeaponData
	local ModTable   = (Ctx and Ctx.mods) or ModTable
	local WeaponTool = (Ctx and Ctx.tool) or WeaponTool

	ChargeDmgMult = ChargeDmgMult or 1
	MaxDist = MaxDist or 7000					-- [F-28] alcance maximo por arma

	--==================================================================
	--  [F-50] ESTADO DE LA BALA  (18/09/2026, municion perforante)
	--
	--  CastRay se llama a si misma cada vez que la bala atraviesa un
	--  accesorio, un chaleco o una parte ignorable. Antes los contadores
	--  eran locales de la LLAMADA, asi que cada una de esas recursiones
	--  los reiniciaba: una bala podia rebotar mas veces de las que dice
	--  RicochetBounces, y con perforante podria cruzar mas paredes de
	--  las permitidas. Ahora el estado viaja con la bala.
	--==================================================================
	local St = PenState or {
		bounces = 0,		-- rebotes gastados (municion ricochet)
		path    = 0,		-- distancia de los tramos ya cerrados
		walls   = 0,		-- piezas de escenario ya perforadas
		dmg     = 1,		-- dano que le queda tras cada perforacion
		hit     = {},		-- personajes ya danados por ESTA bala
	}

	if Bullet then

		local Bpos = Bullet.Position
		local Bpos2 = cam.CFrame.Position

		local recast = false
		local TotalDistTraveled = 0
		local Debounce = false
		local raycastResult

		--  St.path  distancia de los tramos ya cerrados (rebotes). Sin
		--           esto, el dano por distancia y el MaxDist medirian la
		--           linea recta desde el canon hasta el punto final, que
		--           despues de un par de rebotes puede ser cortisima aunque
		--           la bala haya recorrido medio mapa.

		--  [F-50] skipWait / scans: cuando la bala acaba de perforar algo
		--  se vuelve a barrer el MISMO tramo desde el punto de salida sin
		--  esperar al frame siguiente. scans es el tope de seguridad para
		--  que ese rebarrido no pueda colgar el bucle.
		local skipWait = false
		local scans    = 0

		--==============================================================
		--  [F-50] Manda el remote de dano de UN impacto.
		--  La usa la municion perforante, que con una sola bala puede
		--  pegarle a varios cuerpos. Va dentro de un task.spawn porque
		--  InvokeServer espera la respuesta del servidor (ida y vuelta,
		--  ~100 ms): si bloqueara aqui, la bala se quedaria congelada a
		--  mitad de vuelo y el segundo enemigo no cobraria nunca.
		--==============================================================
		local function SendDamage(hitPart, victimHum, dist)
			if not (hitPart and hitPart.Parent and victimHum and WeaponData) then return end

			local DmgMods = ModTable
			local mult = (ChargeDmgMult or 1) * (St.dmg or 1)
			if mult ~= 1 then
				DmgMods = {}
				for k, v in pairs(ModTable) do DmgMods[k] = v end
				DmgMods.DamageMod    = (ModTable.DamageMod or 1) * mult
				DmgMods.minDamageMod = (ModTable.minDamageMod or 1) * mult
			end

			local region
			if hitPart.Name == "Head" or hitPart.Parent.Name == "Top" or hitPart.Parent.Name == "Headset" or hitPart.Parent.Name == "Olho" or hitPart.Parent.Name == "Face" or hitPart.Parent.Name == "Numero" then
				region = 1
			elseif hitPart.Name == "Torso" or hitPart.Name == "UpperTorso" or hitPart.Name == "LowerTorso" or hitPart.Parent.Name == "Chest" or hitPart.Parent.Name == "Waist" or hitPart.Name == "Right Arm" or hitPart.Name == "Left Arm" or hitPart.Name == "RightUpperArm" or hitPart.Name == "RightLowerArm" or hitPart.Name == "RightHand" or hitPart.Name == "LeftUpperArm" or hitPart.Name == "LeftLowerArm" or hitPart.Name == "LeftHand" then
				region = 2
			elseif hitPart.Name == "Right Leg" or hitPart.Name == "Left Leg" or hitPart.Name == "RightUpperLeg" or hitPart.Name == "RightLowerLeg" or hitPart.Name == "RightFoot" or hitPart.Name == "LeftUpperLeg" or hitPart.Name == "LeftLowerLeg" or hitPart.Name == "LeftFoot" then
				region = 3
			end
			if not region then return end

			local SKP_02 = SKP_01.."-"..plr.UserId
			task.spawn(function()
				Evt.Damage:InvokeServer(WeaponTool, victimHum, dist, region, nil, { DamageMod = DmgMods and DmgMods.DamageMod or 1, minDamageMod = DmgMods and DmgMods.minDamageMod or 1 }, nil, nil, SKP_02)
			end)
		end

		local raycastParams = RaycastParams.new()
		raycastParams.FilterDescendantsInstances = Ignore_Model
		raycastParams.FilterType = Enum.RaycastFilterType.Blacklist
		raycastParams.IgnoreWater = true

		while Bullet do
			--  [F-50] Si la bala acaba de perforar algo NO se espera al
			--  frame siguiente: se rebarre el mismo tramo desde el punto de
			--  salida. Sin esto, dos enemigos pegados en el mismo frame solo
			--  recibirian un balazo.
			if skipWait then
				skipWait = false
			else
				Run.Heartbeat:Wait()
				scans = 0
			end

			if Bullet.Parent ~= nil then
				Bpos = Bullet.Position

				--  [30/09] MUNICION CURVA: se tuerce un poco hacia el enemigo
				--  que tenga por delante (MunicionFX.Steer). Solo en cuadros
				--  nuevos: en los rebarridos de la perforante scans > 0.
				if ModTable.Homing and scans == 0 then
					local curva = Mods:FindFirstChild("MunicionFX")
					if curva then require(curva).Steer(Bullet, St, ModTable.Homing, plr) end
				end

				TotalDistTraveled = St.path + (Bullet.Position - Origin).Magnitude

				if TotalDistTraveled > MaxDist then		-- [F-28]
					Bullet:Destroy()
					Debounce = true
					break
				end

				--==========================================================
				--  [F-08] Antes esto recorria game.Players:GetChildren()
				--  ENTERO en cada Heartbeat, para CADA bala viva, y no
				--  cortaba nunca (el Debounce solo saltaba el cuerpo del if).
				--  Con 16 jugadores y 10 balas en el aire eran ~9600
				--  iteraciones por segundo. Ahora sale con break apenas
				--  encuentra al primero.
				--==========================================================
				if not Debounce then
					for _, plyr in ipairs(Players:GetPlayers()) do
						if plyr ~= plr then
							local otherChar = plyr.Character
							local head = otherChar and otherChar:FindFirstChild('Head')
							if head and (head.Position - Bpos).Magnitude <= 25 then
								Evt.Whizz:FireServer(plyr)
								Evt.Suppression:FireServer(plyr, 1, nil, nil)
								Debounce = true
								break
							end
						end
					end
				end

				-- Set an origin and directional vector
				raycastResult = workspace:Raycast(Bpos2, (Bpos - Bpos2) * 1, raycastParams)

				recast = false
				local bounced    = false
				local penetrated = false

				if raycastResult then
					local Hit2 = raycastResult.Instance

					if Hit2 and Hit2.Parent:IsA('Accessory') or Hit2.Parent:IsA('Hat') then
						for _,players in pairs(game.Players:GetPlayers()) do
							if players.Character then
								for i, hats in pairs(players.Character:GetChildren()) do
									if hats:IsA("Accessory") then
										AddIgnore(hats)					-- [F-01]
									end
								end
							end
						end
						recast = true
						CastRay(Bullet, Origin, ChargeDmgMult, MaxDist, St)	-- [F-28] / [F-50] estado de la bala
						break
					end

					-- [VIDRIO 24/09/2026] Ventana rompible (atributo VidrioRompible):
					-- se avisa al servidor (VidrioServer la agrieta o la revienta) y la
					-- bala SIGUE de largo, como en la vida real. Sin locals nuevos.
					if Hit2 and Hit2:GetAttribute("VidrioRompible") == true then
						HitMod.HitEffect(Ignore_Model, raycastResult.Position, Hit2, raycastResult.Normal, raycastResult.Material, { Type = WeaponData.Type or "Gun" })
						Evt.HitEffect:FireServer(raycastResult.Position, Hit2, raycastResult.Normal, raycastResult.Material, { Type = WeaponData.Type or "Gun" }, Ctx and "L" or nil)	-- [29/09 RED] solo Type (antes el ACS_Settings entero)
						AddIgnore(Hit2)
						recast = true
						CastRay(Bullet, Origin, ChargeDmgMult, MaxDist, St, Ctx)
						break
					end

					if Hit2 and Hit2.Name == "Ignorable" or Hit2.Name == "Glass" or Hit2.Name == "Ignore" or Hit2.Parent.Name == "Top" or Hit2.Parent.Name == "Helmet" or Hit2.Parent.Name == "Up" or Hit2.Parent.Name == "Down" or Hit2.Parent.Name == "Face" or Hit2.Parent.Name == "Olho" or Hit2.Parent.Name == "Headset" or Hit2.Parent.Name == "Numero" or Hit2.Parent.Name == "Vest" or Hit2.Parent.Name == "Chest" or Hit2.Parent.Name == "Waist" or Hit2.Parent.Name == "Back" or Hit2.Parent.Name == "Belt" or Hit2.Parent.Name == "Leg1" or Hit2.Parent.Name == "Leg2" or Hit2.Parent.Name == "Arm1"  or Hit2.Parent.Name == "Arm2" then
						AddIgnore(Hit2)								-- [F-01]
						recast = true
						CastRay(Bullet, Origin, ChargeDmgMult, MaxDist, St)	-- [F-28] / [F-50] estado de la bala
						break
					end

					if Hit2 and Hit2.Parent.Name == "Top" or Hit2.Parent.Name == "Helmet" or Hit2.Parent.Name == "Up" or Hit2.Parent.Name == "Down" or Hit2.Parent.Name == "Face" or Hit2.Parent.Name == "Olho" or Hit2.Parent.Name == "Headset" or Hit2.Parent.Name == "Numero" or Hit2.Parent.Name == "Vest" or Hit2.Parent.Name == "Chest" or Hit2.Parent.Name == "Waist" or Hit2.Parent.Name == "Back" or Hit2.Parent.Name == "Belt" or Hit2.Parent.Name == "Leg1" or Hit2.Parent.Name == "Leg2" or Hit2.Parent.Name == "Arm1"  or Hit2.Parent.Name == "Arm2" then
						AddIgnore(Hit2.Parent)						-- [F-01]
						recast = true
						CastRay(Bullet, Origin, ChargeDmgMult, MaxDist, St)	-- [F-28] / [F-50] estado de la bala
						break
					end

					if Hit2 and (Hit2.Transparency >= 1 or Hit2.CanCollide == false) and Hit2.Name ~= 'Head' and Hit2.Name ~= 'Right Arm' and Hit2.Name ~= 'Left Arm' and Hit2.Name ~= 'Right Leg' and Hit2.Name ~= 'Left Leg' and Hit2.Name ~= "UpperTorso" and Hit2.Name ~= "LowerTorso" and Hit2.Name ~= "RightUpperArm" and Hit2.Name ~= "RightLowerArm" and Hit2.Name ~= "RightHand" and Hit2.Name ~= "LeftUpperArm" and Hit2.Name ~= "LeftLowerArm" and Hit2.Name ~= "LeftHand" and Hit2.Name ~= "RightUpperLeg" and Hit2.Name ~= "RightLowerLeg" and Hit2.Name ~= "RightFoot" and Hit2.Name ~= "LeftUpperLeg" and Hit2.Name ~= "LeftLowerLeg" and Hit2.Name ~= "LeftFoot" and Hit2.Name ~= 'Armor' and Hit2.Name ~= 'EShield' then
						AddIgnore(Hit2)								-- [F-01]
						recast = true
						CastRay(Bullet, Origin, ChargeDmgMult, MaxDist, St)	-- [F-28] / [F-50] estado de la bala
						break
					end

					if not recast then

						--==================================================
						--  REBOTE
						--  Solo contra el escenario: si hay humanoide al
						--  otro lado, la bala se queda y hace dano como
						--  siempre. Se hace ANTES de destruir la bala, que
						--  es lo unico que habia aqui.
						--==================================================
						local humanoAhi, VitimaAhi = CheckForHumanoid(raycastResult.Instance)

						--==================================================
						--  [F-50] PERFORACION  (municion perforante)
						--
						--  A los humanoides los atraviesa a TODOS: pega,
						--  sigue de largo, y al que venga detras tambien le
						--  pega. Del escenario solo puede cruzar tantas
						--  piezas como diga PenetrateWalls; la siguiente la
						--  para en seco.
						--
						--  La bala NO se destruye: lo que acaba de cruzar se
						--  mete en la lista de ignorados (por eso nadie cobra
						--  dos veces con el mismo disparo aunque el rayo le
						--  entre y le salga por dos partes) y se sigue.
						--==================================================
						local segDir = Bpos - Bpos2

						if Bullet.Parent and humanoAhi and VitimaAhi and ModTable.PenetrateHumanoids then
							local victimChar = VitimaAhi.Parent
							local hitPart    = raycastResult.Instance

							HitMod.HitEffect(Ignore_Model, raycastResult.Position, hitPart, raycastResult.Normal, raycastResult.Material, { Type = WeaponData.Type or "Gun" })
							Evt.HitEffect:FireServer(raycastResult.Position, hitPart, raycastResult.Normal, raycastResult.Material, { Type = WeaponData.Type or "Gun" }, Ctx and "L" or nil)	-- [29/09 RED]

							if victimChar and not St.hit[victimChar] and VitimaAhi.Health > 0 then
								St.hit[victimChar] = true
								SendDamage(hitPart, VitimaAhi, St.path + (raycastResult.Position - Origin).Magnitude)
								St.dmg = St.dmg * (ModTable.PenetrationDamageKeep or 1)
							end

							AddIgnore(victimChar or raycastResult.Instance)
							penetrated = true

						elseif Bullet.Parent and not humanoAhi and St.walls < (ModTable.PenetrateWalls or 0) then
							St.walls = St.walls + 1

							HitMod.HitEffect(Ignore_Model, raycastResult.Position, raycastResult.Instance, raycastResult.Normal, raycastResult.Material, { Type = WeaponData.Type or "Gun" })
							Evt.HitEffect:FireServer(raycastResult.Position, raycastResult.Instance, raycastResult.Normal, raycastResult.Material, { Type = WeaponData.Type or "Gun" })

							AddIgnore(raycastResult.Instance)
							St.dmg = St.dmg * (ModTable.WallDamageKeep or 1)
							penetrated = true
						end

						if penetrated then
							-- FilterDescendantsInstances guarda una COPIA de la
							-- lista: si no se vuelve a asignar, lo que acabamos
							-- de ignorar no cuenta y el rayo choca otra vez con
							-- lo mismo.
							raycastParams.FilterDescendantsInstances = Ignore_Model

							local dir = (segDir.Magnitude > 0.001) and segDir.Unit or Vector3.new(0, 0, 0)
							Bpos2 = raycastResult.Position + dir * 0.05

							-- Si todavia queda tramo de ESTE frame por delante,
							-- se rebarre ya mismo. El tope de 8 es por si la
							-- lista de ignorados se reinicia a mitad del vuelo
							-- (AddIgnore tiene tope) y el rayo se quedara
							-- chocando eternamente con la misma pared.
							scans = scans + 1
							skipWait = (scans < 8) and ((Bpos - Bpos2):Dot(dir) > 0.05)
						end

						if not penetrated
							and St.bounces < (ModTable.RicochetBounces or 0)
							and not humanoAhi
							and Bullet.Parent
						then
							local normal = raycastResult.Normal
							local vel    = Bullet.AssemblyLinearVelocity
							local speed  = vel.Magnitude

							if speed > 1 then
								St.bounces = St.bounces + 1

								-- Reflexion sobre la normal de la superficie.
								local reflected = (vel - 2 * vel:Dot(normal) * normal)
									* (ModTable.RicochetEnergy or 0.8)

								-- El impacto se ve y se oye igual que uno
								-- normal: sin esto el rebote es invisible.
								HitMod.HitEffect(Ignore_Model, raycastResult.Position, raycastResult.Instance, raycastResult.Normal, raycastResult.Material, { Type = WeaponData.Type or "Gun" })
								Evt.HitEffect:FireServer(raycastResult.Position, raycastResult.Instance, raycastResult.Normal, raycastResult.Material, { Type = WeaponData.Type or "Gun" })

								-- Se cierra el tramo recorrido y se abre uno
								-- nuevo desde el punto de rebote.
								St.path = St.path + (raycastResult.Position - Origin).Magnitude

								-- Despegada de la pared: si la dejas justo
								-- encima, el siguiente raycast vuelve a
								-- chocar con la misma cara y la bala se
								-- queda pegada rebotando en el sitio.
								local newPos = raycastResult.Position + normal * 0.35
								Origin = newPos

								if reflected.Magnitude > 0.01 then
									Bullet.CFrame = CFrame.new(newPos, newPos + reflected.Unit)
								else
									Bullet.CFrame = CFrame.new(newPos)
								end
								Bullet.AssemblyLinearVelocity = reflected

								Bpos  = newPos
								Bpos2 = newPos
								bounced = true
							end
						end

						if not bounced and not penetrated then

							Bullet:SetAttribute("TracerEnd", raycastResult.Position)	-- [17/09] TracerFX: hasta donde llega la linea
							Bullet:Destroy()
							Debounce = true

							local FoundHuman,VitimaHuman = CheckForHumanoid(raycastResult.Instance)
							HitMod.HitEffect(Ignore_Model, raycastResult.Position, raycastResult.Instance , raycastResult.Normal, raycastResult.Material, { Type = WeaponData.Type or "Gun" })
							Evt.HitEffect:FireServer(raycastResult.Position, raycastResult.Instance , raycastResult.Normal, raycastResult.Material, { Type = WeaponData.Type or "Gun" }, Ctx and "L" or nil)	-- [29/09 RED]

							local HitPart = raycastResult.Instance
							-- St.path suma los tramos anteriores si la bala venia
							-- rebotando; en una bala normal vale 0.
							TotalDistTraveled = St.path + (raycastResult.Position - Origin).Magnitude

							if FoundHuman == true and VitimaHuman.Health > 0 and WeaponData then
								local SKP_02 = SKP_01.."-"..plr.UserId
								-- Copia del ModTable con el multiplicador de carga aplicado
								local DmgMods = ModTable
								if ChargeDmgMult ~= 1 then
									DmgMods = {}
									for k, v in pairs(ModTable) do DmgMods[k] = v end
									DmgMods.DamageMod    = (ModTable.DamageMod or 1) * ChargeDmgMult
									DmgMods.minDamageMod = (ModTable.minDamageMod or 1) * ChargeDmgMult
								end

								if HitPart.Name == "Head" or HitPart.Parent.Name == "Top" or HitPart.Parent.Name == "Headset" or HitPart.Parent.Name == "Olho" or HitPart.Parent.Name == "Face" or HitPart.Parent.Name == "Numero" then
									Evt.Damage:InvokeServer(WeaponTool, VitimaHuman, TotalDistTraveled, 1, nil, { DamageMod = DmgMods and DmgMods.DamageMod or 1, minDamageMod = DmgMods and DmgMods.minDamageMod or 1 }, nil, nil, SKP_02)
								elseif HitPart.Name == "Torso" or HitPart.Name == "UpperTorso" or HitPart.Name == "LowerTorso" or HitPart.Parent.Name == "Chest" or HitPart.Parent.Name == "Waist" or HitPart.Name == "Right Arm" or HitPart.Name == "Left Arm" or HitPart.Name == "RightUpperArm" or HitPart.Name == "RightLowerArm" or HitPart.Name == "RightHand" or HitPart.Name == "LeftUpperArm" or HitPart.Name == "LeftLowerArm" or HitPart.Name == "LeftHand" then
									Evt.Damage:InvokeServer(WeaponTool, VitimaHuman, TotalDistTraveled, 2, nil, { DamageMod = DmgMods and DmgMods.DamageMod or 1, minDamageMod = DmgMods and DmgMods.minDamageMod or 1 }, nil, nil, SKP_02)
								elseif HitPart.Name == "Right Leg" or HitPart.Name == "Left Leg" or HitPart.Name == "RightUpperLeg" or HitPart.Name == "RightLowerLeg" or HitPart.Name == "RightFoot" or HitPart.Name == "LeftUpperLeg" or HitPart.Name == "LeftLowerLeg" or HitPart.Name == "LeftFoot" then
									Evt.Damage:InvokeServer(WeaponTool, VitimaHuman, TotalDistTraveled, 3, nil, { DamageMod = DmgMods and DmgMods.DamageMod or 1, minDamageMod = DmgMods and DmgMods.minDamageMod or 1 }, nil, nil, SKP_02)
								end
							end

						end -- if not bounced
					end

					-- [F-50] Si perforo, la bala sigue viva y Bpos2 ya apunta
					-- al punto de salida: no se corta ni se pisa.
					if not bounced and not penetrated then break end
				end

				if not penetrated then
					Bpos2 = Bpos
				end
			else
				break
			end
		end
	end
end

local Tracers = 0
function TracerCalculation()
	if WeaponData.Tracer or WeaponData.BulletFlare then
		if WeaponData.RandomTracer.Enabled then
			if (math.random(1, 100) <= WeaponData.RandomTracer.Chance) then
				return true
			else
				return false
			end
		else
			if Tracers >= WeaponData.TracerEveryXShots then
				Tracers = 0
				return true
			else
				Tracers = Tracers + 1
				return false
			end
		end
	end
end

function CreateBullet(ChargeDmgMult, ChargeSpdMult, ChargeSpread, Ctx)
	--  [DUAL 22/09] ver CastRay: con Ctx la bala sale de la otra pistola.
	local WeaponData   = (Ctx and Ctx.data) or WeaponData
	local ModTable     = (Ctx and Ctx.mods) or ModTable
	local WeaponInHand = (Ctx and Ctx.gun)  or WeaponInHand
	local WeaponTool   = (Ctx and Ctx.tool) or WeaponTool
	local BSpread      = (Ctx and Ctx.spread) or BSpread

	ChargeDmgMult = ChargeDmgMult or 1
	ChargeSpdMult = ChargeSpdMult or 1
	ChargeSpread  = ChargeSpread  or 0

	ResetIgnore()					-- [F-01] cada bala arranca con la lista limpia

	local EffVelocity = math.max(WeaponData.MuzzleVelocity * ChargeSpdMult, 0.01)

	--  [30/09] VelMul reemplaza a ModTable.MuzzleVelocity en todo el disparo.
	--  Con FixedMuzzleVelocity (municion subsonica) la bala sale SIEMPRE a
	--  esa velocidad, pisando accesorios y carga.
	local VelMul = ModTable.MuzzleVelocity or 1
	if (tonumber(ModTable.FixedMuzzleVelocity) or 0) > 0 then
		VelMul = ModTable.FixedMuzzleVelocity / EffVelocity
	end
	local EffSpread   = (BSpread or 0) + ChargeSpread

	local Bullet = Instance.new("Part")
	Bullet.Name = plr.Name.."_Bullet"
	Bullet.CanCollide = false
	Bullet.Shape = Enum.PartType.Ball
	Bullet.Transparency = 1
	Bullet.Size = Vector3.new(1,1,1)
	Bullet.Parent = ACS_Workspace.Client

	local Origin 		= WeaponInHand.Handle.Muzzle.WorldPosition

	--==========================================================
	--  [F-27] BALISTICA - Compensacion de zero
	--  Antes: Up * ((BulletDrop * CurrentZero/4)/MuzzleVelocity)/2
	--  Ese termino divide entre V (no entre V^2), no normaliza el
	--  vector y no tiene tope, asi que con MuzzleVelocity baja el
	--  angulo de salida hacia arriba crecia sin limite y la bala
	--  salia disparada al cielo.
	--==========================================================
	local MuzzleCF   = WeaponInHand.Handle.Muzzle.WorldCFrame
	local BulletMass = Bullet:GetMass()
	local ZeroComp   = 0
	local BDrop      = WeaponData.BulletDrop or 0
	local ZeroM      = WeaponData.CurrentZero or 0
	if BDrop > 0 and ZeroM > 0 then
		local vReal = math.max(EffVelocity * VelMul, 0.01) / BulletMass
		local aReal = (BDrop * 196.2) / BulletMass
		local dStud = ZeroM * 3.5714					-- metros -> studs
		ZeroComp = math.clamp((aReal * dStud) / (2 * vReal * vReal), 0, 0.18)	-- tope ~10 grados
	end
	local Direction 	= (MuzzleCF.LookVector + MuzzleCF.UpVector * ZeroComp).Unit

	--==========================================================
	--  [DUAL 22/09] TIROS AL CENTRO
	--  Con dos pistolas cada canon esta a medio stud del centro de
	--  la pantalla. Si cada una dispara recto hacia adelante, los
	--  balazos caen a los lados de la mira. Aqui las dos apuntan al
	--  mismo punto lejano bajo la mira, asi que convergen en el
	--  centro. La dispersion y el zero se aplican igual, despues.
	--==========================================================
	if DualWield and DualWield.active then
		local target = cam.CFrame.Position + cam.CFrame.LookVector * (DualWield.convergeDist or 300)
		local toTarget = target - Origin
		if toTarget.Magnitude > 1 then
			Direction = (toTarget.Unit + MuzzleCF.UpVector * ZeroComp).Unit
		end
	end
	local BulletCF 		= CFrame.new(Origin, Origin + Direction)	-- [F-27] el 2do arg es un PUNTO, no un vector
	local StanceMul 	= LL_StanceAimMult()	-- [23/09] agachado: menos dispersion
	local WalkMul 		= WeaponData.WalkMult * ModTable.WalkMult * StanceMul
	EffSpread 			= EffSpread * StanceMul
	local BColor 		= Color3.fromRGB(255,255,255)
	local balaspread
	if aimming and WeaponData.Bullets <= 1 and ChargeSpread <= 0 then
		balaspread = CFrame.Angles(
			math.rad(RAND(-EffSpread - (charspeed/1) * WalkMul, EffSpread + (charspeed/1) * WalkMul) / (10 * WeaponData.AimSpreadReduction)),
			math.rad(RAND(-EffSpread - (charspeed/1) * WalkMul, EffSpread + (charspeed/1) * WalkMul) / (10 * WeaponData.AimSpreadReduction)),
			math.rad(RAND(-EffSpread - (charspeed/1) * WalkMul, EffSpread + (charspeed/1) * WalkMul) / (10 * WeaponData.AimSpreadReduction))
		)
	else
		balaspread = CFrame.Angles(
			math.rad(RAND(-EffSpread - (charspeed/1) * WalkMul, EffSpread + (charspeed/1) * WalkMul) / 10),
			math.rad(RAND(-EffSpread - (charspeed/1) * WalkMul, EffSpread + (charspeed/1) * WalkMul) / 10),
			math.rad(RAND(-EffSpread - (charspeed/1) * WalkMul, EffSpread + (charspeed/1) * WalkMul) / 10)
		)
	end
	Direction = balaspread * Direction

	--==========================================================
	--  [F-42] PROYECTILES FISICOS  (10/09/2026)
	--  Si el ACS_Settings del arma tiene  self.Projectile = true,
	--  el disparo NO crea bala hitscan: se le pasa a
	--  ProjectileClient (StarterPlayerScripts), que lo dibuja al
	--  instante y avisa a ProjectileServer. El dano lo decide el
	--  servidor, no esto. Se reutilizan Origin y Direction de
	--  arriba, asi que la dispersion (apuntando, moviendose,
	--  ChargeSpread) es la misma que la de una bala normal.
	--==========================================================
	if WeaponData.Projectile == true then
		Bullet:Destroy()
		if _G.ACS_ProjectileFire then
			_G.ACS_ProjectileFire(WeaponTool, WeaponData, Origin, Direction, ChargeDmgMult, ChargeSpdMult)
		else
			warn("[ACS] "..tostring(WeaponTool).." tiene Projectile = true pero ProjectileClient no esta cargado")
		end
		return
	end

	local Visivel = TracerCalculation()

	if WeaponData.RainbowMode then
		BColor = Color3.fromRGB(math.random(0,255),math.random(0,255),math.random(0,255))
	else
		BColor = WeaponData.TracerColor
	end

	--  [30/09] HideTracer (subsonica / silenciador): ni estela, ni brillo,
	--  ni bala replicada a los demas; no delata de donde viene el tiro.
	if Visivel and not ModTable.HideTracer then
		if gameRules.ReplicatedBullets then
			-- [29/09 RED] Antes viajaba el ACS_Settings entero (~1.5 KB) en CADA
			-- bala. Ahora va el Tool: quien la recibe lee su propia copia del
			-- modulo. De los mods, solo lo que usa la bala replicada.
			Evt.ServerBullet:FireServer(Origin, Direction, WeaponTool, {
				MuzzleVelocity = VelMul * ChargeSpdMult,	-- [30/09] velocidad real (fija o con carga)
				PenetrateWalls = ModTable.PenetrateWalls,
				PenetrateHumanoids = ModTable.PenetrateHumanoids,
			})
		end

		if WeaponData.Tracer == true then
			-- [17/09] Estela con duracion configurable por arma
			-- (TracerHoldTime / TracerFadeTime en ACS_Settings).
			-- La crea TracerFX para que no muera junto con la bala.
			local TracerMod = Mods:FindFirstChild("TracerFX")
			if TracerMod then
				require(TracerMod).Create(Bullet, WeaponData, BColor, BulletCF)
			end
		end

		if WeaponData.BulletFlare == true then
			local bg = Instance.new("BillboardGui")
			bg.Adornee = Bullet
			bg.Enabled = false
			local flashsize = math.random(275, 375)/10
			bg.Size = UDim2.new(flashsize, 0, flashsize, 0)
			bg.LightInfluence = 0
			bg.Parent = Bullet

			local flash = Instance.new("ImageLabel")
			flash.BackgroundTransparency = 1
			flash.Size = UDim2.new(1, 0, 1, 0)
			flash.Position = UDim2.new(0, 0, 0, 0)
			flash.Image = "http://www.roblox.com/asset/?id=1047066405"
			flash.ImageTransparency = math.random(2, 5)/15
			flash.ImageColor3 = BColor
			flash.Parent = bg

			task.delay(.1, function()
				if bg and bg.Parent then
					bg.Enabled = true
				end
			end)
		end

	end

	--==========================================================
	--  [F-27] BALISTICA - Antigravedad
	--  Antes: BulletMass*196.2 - BulletDrop*196.2, con 196.2
	--  hardcodeado. Si workspace.Gravity es menor a 196.2 la
	--  fuerza quedaba de mas y la bala aceleraba HACIA ARRIBA.
	--  Ahora la caida neta siempre es DropAccel hacia abajo.
	--==========================================================
	local DropAccel = math.max(WeaponData.BulletDrop or 0, 0) * 196.2 / BulletMass
	local Force = Vector3.new(0, BulletMass * (workspace.Gravity - DropAccel), 0)
	local BF = Instance.new("BodyForce")
	BF.Parent = Bullet

	Bullet.CFrame = BulletCF
	Bullet:ApplyImpulse(Direction * EffVelocity * VelMul)	-- [30/09] VelMul
	BF.Force = Force

	--==========================================================
	--  [F-28] Vida y alcance de la bala, configurables por arma.
	--  En el modulo de settings del arma (opcionales):
	--      BulletLifetime     = 15,		-- segundos, default 5
	--      MaxBulletDistance  = 10000,	-- studs,    default 7000
	--==========================================================
	game.Debris:AddItem(Bullet, WeaponData.BulletLifetime or 5)

	CastRay(Bullet, Origin, ChargeDmgMult, WeaponData.MaxBulletDistance or 7000, nil, Ctx)
end


function meleeCast(heavy)
	local MAX_ATTEMPTS = 15
	local attempts = 0

	ResetIgnore()					-- [F-01] cada golpe arranca con la lista limpia

	while attempts < MAX_ATTEMPTS do
		attempts += 1

		local rayOrigin 	= cam.CFrame.Position
		local rayDirection 	= cam.CFrame.LookVector * WeaponData.BladeRange

		local raycastParams = RaycastParams.new()
		raycastParams.FilterDescendantsInstances = Ignore_Model
		raycastParams.FilterType = Enum.RaycastFilterType.Blacklist
		raycastParams.IgnoreWater = true

		local raycastResult = workspace:Raycast(rayOrigin, rayDirection, raycastParams)

		if raycastResult then
			local Hit2 = raycastResult.Instance

			-- Revisar si el objeto debe ignorarse
			local shouldIgnore = false

			if Hit2 then
				local parentName = Hit2.Parent and Hit2.Parent.Name or ""
				local name = Hit2.Name

				-- Accesorios
				if Hit2.Parent:IsA("Accessory") or Hit2.Parent:IsA("Hat") then
					for _, player in pairs(game.Players:GetPlayers()) do
						if player.Character then
							for _, hat in pairs(player.Character:GetChildren()) do
								if hat:IsA("Accessory") then
									AddIgnore(hat)					-- [F-01]
								end
							end
						end
					end
					shouldIgnore = true
				end

				-- Superficies o decoraciones
				local ignorableNames = {
					"Ignorable", "Glass", "Ignore", "Top", "Helmet", "Up", "Down",
					"Face", "Olho", "Headset", "Numero", "Vest", "Chest", "Waist",
					"Back", "Belt", "Leg1", "Leg2", "Arm1", "Arm2"
				}

				if table.find(ignorableNames, name) or table.find(ignorableNames, parentName) then
					AddIgnore(Hit2)									-- [F-01]
					shouldIgnore = true
				end

				-- Partes invisibles
				if (Hit2.Transparency >= 1 or not Hit2.CanCollide)
					and not table.find({ "Head", "Right Arm", "Left Arm", "Right Leg", "Left Leg",
						"UpperTorso", "LowerTorso", "RightUpperArm", "RightLowerArm", "RightHand",
						"LeftUpperArm", "LeftLowerArm", "LeftHand", "RightUpperLeg", "RightLowerLeg",
						"RightFoot", "LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "Armor", "EShield"
					}, name) then
					AddIgnore(Hit2)									-- [F-01]
					shouldIgnore = true
				end
			end

			if not shouldIgnore then
				-- Procesamiento valido de golpe
				local FoundHuman, VitimaHuman = CheckForHumanoid(Hit2)
				HitMod.HitEffect(Ignore_Model, raycastResult.Position, Hit2, raycastResult.Normal, raycastResult.Material, { Type = WeaponData.Type or "Gun" })
				Evt.HitEffect:FireServer(raycastResult.Position, Hit2, raycastResult.Normal, raycastResult.Material, { Type = WeaponData.Type or "Gun" })	-- [29/09 RED]

				if FoundHuman and VitimaHuman and VitimaHuman.Health > 0 then
					local SKP_02 = SKP_01 .. "-" .. plr.UserId
					local partName = Hit2.Name
					local parentName = Hit2.Parent and Hit2.Parent.Name or ""

					local region = 3 -- default limb
					if table.find({ "Head", "Top", "Headset", "Olho", "Face", "Numero" }, partName) or table.find({ "Top", "Headset", "Olho", "Face", "Numero" }, parentName) then
						region = 1 -- head
					elseif table.find({ "Torso", "UpperTorso", "LowerTorso", "Chest", "Waist",
						"RightUpperArm", "RightLowerArm", "RightHand",
						"LeftUpperArm", "LeftLowerArm", "LeftHand" }, partName) or table.find({ "Chest", "Waist" }, parentName) then
						region = 2 -- torso
					end

					Thread:Spawn(function()
						Evt.Damage:InvokeServer(WeaponTool, VitimaHuman, 0, region, nil, { DamageMod = ModTable and ModTable.DamageMod or 1, minDamageMod = ModTable and ModTable.minDamageMod or 1 }, nil, nil, SKP_02)
					end)

					-- ===== [BATE] golpe cargado a la cabeza =====
					-- El dano ya salio arriba y es el normal del arma: el cargado NO
					-- pega mas fuerte. Esto solo pide los EFECTOS (aturdimiento,
					-- ragdoll, empujon); el servidor revalida todo por su cuenta.
					if heavy and region == 1 then
						local HeavyEvt = Evt:FindFirstChild("MeleeHeavy")
						if HeavyEvt then
							HeavyEvt:FireServer(WeaponTool, VitimaHuman, SKP_02)
						end
					end
					-- ============================================
				end

				break -- salir del bucle porque se encontro algo valido
			end
		else
			break -- nada fue detectado, salir del bucle
		end
	end
end


function UpdateGui()
	-- [F-44] La municion del arma en mano queda siempre en el atributo
	-- CurrentAmmo del Tool. Antes solo se escribia al guardar el arma, asi
	-- que ningun otro script podia saber cuantos tiros quedan. Con esto un
	-- ACS_Animations puede, por ejemplo, esconder el cohete del lanzacohetes
	-- cuando esta vacio. No cambia como se guarda la municion: unset() la
	-- sigue escribiendo igual.
	if WeaponTool and WeaponTool:IsDescendantOf(game) then
		WeaponTool:SetAttribute("CurrentAmmo", Ammo)
	end

	if SE_GUI then
		local HUD = SE_GUI.GunHUD

		if WeaponData ~= nil then

			if WeaponData.Jammed then
				HUD.B.BackgroundColor3 = Color3.fromRGB(255,0,0)
			else
				HUD.B.BackgroundColor3 = Color3.fromRGB(255,255,255)
			end

			if SafeMode then
				HUD.A.Visible = true
			else
				HUD.A.Visible = false
			end

			if Ammo > 0 then
				HUD.B.Visible = true
			else
				HUD.B.Visible = false
			end

			if WeaponData.ShootType == 1 then
				HUD.FText.Text = Ammo.."/"..StoredAmmo.." | Semi"
			elseif WeaponData.ShootType == 2 then
				HUD.FText.Text = Ammo.."/"..StoredAmmo.." | Burst"
			elseif WeaponData.ShootType == 3 then
				HUD.FText.Text = Ammo.."/"..StoredAmmo.." | Auto"
			elseif WeaponData.ShootType == 4 then
				HUD.FText.Text = Ammo.."/"..StoredAmmo.." | Pump-Action"
			elseif WeaponData.ShootType == 5 then
				HUD.FText.Text = Ammo.."/"..StoredAmmo.." | Bolt-Action"
			elseif WeaponData.ShootType == 6 then
				HUD.FText.Text = Ammo.."/"..StoredAmmo.." | Charge"
			end
			if WeaponData.Type == "Medical" then
				local uses = (WeaponTool and WeaponTool:GetAttribute("HealCharges")) or WeaponData.HealUses or 0
				local maxu = WeaponData.HealUses or 0

				if HUD:FindFirstChild("FText") then HUD.FText.Text = uses .. "/" .. maxu .. " | Curacion" end
				if HUD:FindFirstChild("BText") then HUD.BText.Text = "+" .. (WeaponData.HealAmount or 0) .. " HP" end
				if HUD:FindFirstChild("NText") then HUD.NText.Text = WeaponData.gunName end
				if HUD:FindFirstChild("SAText") then HUD.SAText.Text = uses end
				if HUD:FindFirstChild("Sens") then HUD.Sens.Text = (Sens/100) end
				if HUD:FindFirstChild("Magazines") then HUD.Magazines.Visible = false end
				if HUD:FindFirstChild("Bullets") then HUD.Bullets.Visible = true end
				if HUD:FindFirstChild("A") then HUD.A.Visible = false end
				if HUD:FindFirstChild("B") then HUD.B.Visible = false end
				if HUD:FindFirstChild("ZeText") then HUD.ZeText.Visible = false end
				if HUD:FindFirstChild("Att") then
					for _, a in ipairs(HUD.Att:GetChildren()) do
						if a:IsA("GuiObject") then a.Visible = false end
					end
				end
				return
			end
			HUD.Sens.Text = (Sens/100)
			HUD.BText.Text = WeaponData.BulletType
			HUD.NText.Text = WeaponData.gunName

			--  [DUAL 22/09] municion y nombre de la pistola izquierda
			if DualWield.active and DualWield.hud then DualWield.hud(HUD) end

			if WeaponData.EnableZeroing then
				HUD.ZeText.Visible = true
				HUD.ZeText.Text = WeaponData.CurrentZero .." m"
			else
				HUD.ZeText.Visible = false
			end

			if WeaponData.MagCount then
				HUD.SAText.Text = math.ceil(StoredAmmo/WeaponData.Ammo)
				HUD.Magazines.Visible = true
				HUD.Bullets.Visible = false
			else
				HUD.SAText.Text = StoredAmmo
				HUD.Magazines.Visible = false
				HUD.Bullets.Visible = true
			end

			if Suppressor then
				HUD.Att.Silencer.Visible = true
			else
				HUD.Att.Silencer.Visible = false
			end


			if LaserAtt then
				HUD.Att.Laser.Visible = true
				if LaserActive then
					if IRmode then
						TS:Create(HUD.Att.Laser, TweenInfo.new(.1,Enum.EasingStyle.Linear), {ImageColor3 = Color3.fromRGB(0,255,0), ImageTransparency = .123}):Play()
					else
						TS:Create(HUD.Att.Laser, TweenInfo.new(.1,Enum.EasingStyle.Linear), {ImageColor3 = Color3.fromRGB(255,255,255), ImageTransparency = .123}):Play()
					end
				else
					TS:Create(HUD.Att.Laser, TweenInfo.new(.1,Enum.EasingStyle.Linear), {ImageColor3 = Color3.fromRGB(255,0,0), ImageTransparency = .5}):Play()
				end
			else
				HUD.Att.Laser.Visible = false
			end

			if BipodAtt then
				HUD.Att.Bipod.Visible = true
			else
				HUD.Att.Bipod.Visible = false
			end

			if TorchAtt then
				HUD.Att.Flash.Visible = true
				if TorchActive then
					TS:Create(HUD.Att.Flash, TweenInfo.new(.1,Enum.EasingStyle.Linear), {ImageColor3 = Color3.fromRGB(255,255,255), ImageTransparency = .123}):Play()
				else
					TS:Create(HUD.Att.Flash, TweenInfo.new(.1,Enum.EasingStyle.Linear), {ImageColor3 = Color3.fromRGB(255,0,0), ImageTransparency = .5}):Play()
				end
			else
				HUD.Att.Flash.Visible = false
			end

			if WeaponData.Type == "Grenade" then
				SE_GUI.GrenadeForce.Visible = true
				SE_GUI.GrenadeForce.Text = "IZQ: LEJOS · DER: CERCA"	-- [GRANADAS CS2]
			else
				SE_GUI.GrenadeForce.Visible = false
			end
		end
	end
end

function CheckMagFunction()

	if aimming then
		aimming = false
		ADS(aimming)
	end

	if SE_GUI then
		local HUD = SE_GUI.GunHUD

		TS:Create(HUD.CMText,TweenInfo.new(.25,Enum.EasingStyle.Linear,Enum.EasingDirection.InOut,0,false,0),{TextTransparency = 0,TextStrokeTransparency = 0.75}):Play()

		if Ammo >= WeaponData.Ammo then
			HUD.CMText.Text = "Full"
		elseif Ammo > math.floor((WeaponData.Ammo)*.75) and Ammo < WeaponData.Ammo then
			HUD.CMText.Text = "Nearly full"
		elseif Ammo < math.floor((WeaponData.Ammo)*.75) and Ammo > math.floor((WeaponData.Ammo)*.5) then
			HUD.CMText.Text = "Almost half"
		elseif Ammo == math.floor((WeaponData.Ammo)*.5) then
			HUD.CMText.Text = "Half"
		elseif Ammo > math.ceil((WeaponData.Ammo)*.25) and Ammo <  math.floor((WeaponData.Ammo)*.5) then
			HUD.CMText.Text = "Less than half"
		elseif Ammo < math.ceil((WeaponData.Ammo)*.25) and Ammo > 0 then
			HUD.CMText.Text = "Almost empty"
		elseif Ammo == 0 then
			HUD.CMText.Text = "Empty"
		end

		task.delay(.25,function()
			TS:Create(HUD.CMText,TweenInfo.new(.25,Enum.EasingStyle.Linear,Enum.EasingDirection.InOut,0,false,5),{TextTransparency = 1,TextStrokeTransparency = 1}):Play()
		end)
	end
	mouse1down 	= false
	SafeMode 	= false
	GunStance 	= 0
	Evt.GunStance:FireServer(GunStance, LL_StancePose(GunStance, AnimData))
	UpdateGui()
	MagCheckAnim()
	RunCheck()
end

function Grenade()
	if not GRDebounce then
		GRDebounce = true
		-- [GRANADAS CS2 30092026] Se quita el seguro al empezar a apretar:
		-- desde ese momento corre la mecha. Si la aguantas de mas, revienta
		-- en tu mano (todas menos las que tengan NoCook, p. ej. Molotov).
		LL_Nade.pin  = os.clock()
		LL_Nade.hand = false
		LL_Nade.fuse = LL_NadeFuse(WeaponData)
		LL_NadeUpdatePower()

		GrenadeReady()

		-- [F-15] Aqui habia DOS llamadas identicas seguidas a
		-- GrenadeTraj.Start(): se calculaba y dibujaba la trayectoria
		-- dos veces en paralelo.
		GrenadeTraj.Start(WeaponData, function() return Power end,
			function() return os.clock() - LL_Nade.pin end)

		repeat
			task.wait()
			LL_NadeTick()
		until not CookGrenade

		GrenadeTraj.Stop()
		TossGrenade()
	end
end

function TossGrenade()
	if WeaponTool and WeaponData and GRDebounce == true then
		local SKP_02 = SKP_01.."-"..plr.UserId
		-- [GRANADAS CS2] si revento en la mano no hay animacion de lanzar
		if not LL_Nade.hand then GrenadeThrow() end
		if WeaponTool and WeaponData then
			local nCh = plr.Character
			local nHd = nCh and nCh:FindFirstChild("Head")
			local nRt = nCh and nCh:FindFirstChild("HumanoidRootPart")
			Evt.Grenade:FireServer(WeaponTool,WeaponData,cam.CFrame,cam.CFrame.LookVector,Power,SKP_02, {
				o = nHd and nHd.Position,						-- desde la cabeza (igual que la linea)
				v = nRt and nRt.AssemblyLinearVelocity,		-- tiros corriendo / saltando
				c = os.clock() - (LL_Nade.pin or os.clock()),	-- segundos cocinada
				h = LL_Nade.hand or nil,						-- revento en la mano
			})
			unset()
		end
	end
end

--==========================================================================
--  [GRANADAS CS2 30092026] Controles estilo Counter-Strike
--    · Click izquierdo (R2 / FUEGO)    -> tiro LEJOS
--    · Click derecho  (L2 / APUNTAR)  -> tiro CERCA, por abajo, enfrente
--    · Los dos a la vez               -> tiro MEDIO
--  Se lanza al soltar el ULTIMO boton. La mecha corre desde que aprietas.
--  Todo va dentro de una funcion para no sumar locals al chunk principal
--  (limite de 200). Solo quedan globales las funciones de afuera.
--==========================================================================
;(function()
	LL_Nade = { L = false, R = false, pin = 0, hand = false, fuse = nil }

	local GP
	local function gp()
		if GP == nil then
			local m = game:GetService("ReplicatedStorage"):FindFirstChild("GrenadePhysics")
			local ok, mod = pcall(require, m)
			GP = ok and mod or false
		end
		return GP or nil
	end

	-- segundos que aguanta en la mano antes de reventar (nil = no se cocina)
	function LL_NadeFuse(data)
		local m = gp()
		if not m or not data then return nil end
		return m.CookFuse(m.GetProfile(data.gunName))
	end

	function LL_NadeUpdatePower()
		if LL_Nade.L and LL_Nade.R then
			Power = 100
		elseif LL_Nade.L then
			Power = 150
		elseif LL_Nade.R then
			Power = 50
		end
	end

	local NAMES = { [150] = "LEJOS", [100] = "MEDIO", [50] = "CERCA" }

	function LL_NadeTick()
		LL_NadeUpdatePower()
		local label = NAMES[Power] or ""
		if LL_Nade.fuse then
			local left = LL_Nade.fuse - (os.clock() - LL_Nade.pin)
			if left <= 0 then
				-- se te quedo en la mano
				LL_Nade.hand = true
				CookGrenade  = false
				return
			end
			label = ("%s  ·  %.1fs"):format(label, left)
		end
		pcall(function() SE_GUI.GrenadeForce.Text = label end)
	end

	function LL_NadeInput(side, down)
		if side == "L" then LL_Nade.L = down else LL_Nade.R = down end
		if down then
			LL_NadeUpdatePower()
			if not CookGrenade and not GRDebounce then
				CookGrenade = true
				task.spawn(Grenade)
			end
		elseif not LL_Nade.L and not LL_Nade.R then
			CookGrenade = false
		end
	end
end)()

function GrenadeMode()	-- [GRANADAS CS2] ya no se usa (antes: modo de tiro con click derecho)
	if Power >= 150 then
		Power = 100
		SE_GUI.GrenadeForce.Text = "Mid Throw"
	elseif Power >= 100 then
		Power = 50
		SE_GUI.GrenadeForce.Text = "Low Throw"
	elseif Power >= 50 then
		Power = 150
		SE_GUI.GrenadeForce.Text = "High Throw"
	end
end

function JamChance()
	if WeaponData.CanBreak == true and not WeaponData.Jammed and Ammo - 1 > 0 then
		local Jam = math.random(1000)
		if Jam <= 2 then
			WeaponData.Jammed = true
			WeaponInHand.Handle.Click:Play()
		end
	end
end

function Jammed()
	if WeaponData.Type == "Gun" and WeaponData.Jammed then

		mouse1down = false
		reloading = true
		SafeMode = false
		GunStance = 0
		Evt.GunStance:FireServer(GunStance, LL_StancePose(GunStance, AnimData))
		UpdateGui()

		JammedAnim()
		WeaponData.Jammed = false
		UpdateGui()
		reloading = false
		RunCheck()
	end
end
function Reload()
	if WeaponData.Type ~= "Gun" then return end
	if StoredAmmo <= 0 then return end

	local maxAmmo = WeaponData.Ammo or 0
	local chambered = WeaponData.IncludeChamberedBullet and 1 or 0
	local fullAmmo = maxAmmo + chambered

	if Ammo >= fullAmmo then return end

	-- Guardar referencia del arma ACTUAL al inicio de la recarga
	local reloadingTool = WeaponTool
	local reloadingData = WeaponData

	mouse1down = false
	reloading = true
	SafeMode = false
	GunStance = 0
	Evt.GunStance:FireServer(GunStance, LL_StancePose(GunStance, AnimData))
	UpdateGui()

	if WeaponData.ShellInsert then
		if Ammo > 0 then
			for i = 1, fullAmmo - Ammo do
				-- Verificar que seguimos con la misma arma
				if WeaponTool ~= reloadingTool then break end
				if StoredAmmo > 0 and Ammo < fullAmmo then
					if CancelReload then break end
					ReloadAnim()
					if WeaponTool ~= reloadingTool then break end -- verificar despues de la animacion
					Ammo += 1
					StoredAmmo -= 1
					UpdateGui()
				end
			end
		else
			TacticalReloadAnim()
			if WeaponTool == reloadingTool then
				Ammo += 1
				StoredAmmo -= 1
				UpdateGui()
			end

			for i = 1, fullAmmo - Ammo do
				if WeaponTool ~= reloadingTool then break end
				if StoredAmmo > 0 and Ammo < fullAmmo then
					if CancelReload then break end
					ReloadAnim()
					if WeaponTool ~= reloadingTool then break end
					Ammo += 1
					StoredAmmo -= 1
					UpdateGui()
				end
			end
		end
	else
		if Ammo > 0 then
			ReloadAnim()
		else
			TacticalReloadAnim()
		end

		-- Verificar despues de la animacion (que es donde ocurre el delay)
		if WeaponTool == reloadingTool then
			local needed = fullAmmo - Ammo
			if needed > StoredAmmo then
				Ammo += StoredAmmo
				StoredAmmo = 0
			else
				Ammo += needed
				StoredAmmo -= needed
			end
		end
	end

	CancelReload = false
	reloading = false
	RunCheck()
	UpdateGui()
end



function GunFx(ChargeSnd)
	local muzzle = WeaponInHand.Handle.Muzzle

	if Suppressor == true then
		LL_PlayShot(muzzle.Supressor, ModTable)	-- [30/09] ModTable: sonido de la municion
	elseif ChargeSnd then
		local cf = muzzle:FindFirstChild("ChargeFire")
		if cf and cf:IsA("Sound") then
			cf.PlaybackSpeed = ChargeSnd
			cf:Play()
		else
			LL_PlayShot(muzzle.Fire, ModTable)
		end
	else
		LL_PlayShot(muzzle.Fire, ModTable)
	end
	-- [BALLESTA 03/10] Aviso de disparo a la animacion del arma (la ballesta
	-- esconde el virote y suelta la cuerda). Las armas sin ShotFired, igual.
	if AnimData and AnimData.ShotFired then
		pcall(AnimData.ShotFired, { RArmWeld, LArmWeld, GunWeld, WeaponInHand, ViewModel })
	end
	-- [30/09] GunFx seguro: si al modelo le falta un efecto se salta en vez
	-- de tronar. Antes un Chamber.Shell faltante (Steyr Scout) mataba el hilo
	-- de disparo y dejaba shooting/boltCooldown en true hasta re-equipar.
	local smk = muzzle:FindFirstChild("Smoke")
	if smk then smk:Emit(10) end
	if FlashHider ~= true then
		local fl = muzzle:FindFirstChild("FlashFX[Flash]")
		if fl then fl:Emit(10) end
	end

	if BSpread then
		BSpread = math.min(WeaponData.MaxSpread * ModTable.MaxSpread, BSpread + WeaponData.AimInaccuracyStepAmount * ModTable.AimInaccuracyStepAmount)
		RecoilPower =  math.min(WeaponData.MaxRecoilPower * ModTable.MaxRecoilPower, RecoilPower + WeaponData.RecoilPowerStepAmount * ModTable.RecoilPowerStepAmount)
	end

	generateBullet = generateBullet + 1
	LastSpreadUpdate = time()

	local slideW = WeaponInHand.Handle:FindFirstChild("Slide")
	if slideW then
		if Ammo > 0 or not WeaponData.SlideLock then
			TS:Create( slideW, TweenInfo.new(30/WeaponData.ShootRate,Enum.EasingStyle.Linear,Enum.EasingDirection.InOut,0,true,0), {C0 =  WeaponData.SlideEx:inverse() }):Play()
		elseif Ammo <= 0 and WeaponData.SlideLock then
			TS:Create( slideW, TweenInfo.new(30/WeaponData.ShootRate,Enum.EasingStyle.Linear,Enum.EasingDirection.InOut,0,false,0), {C0 =  WeaponData.SlideEx:inverse() }):Play()
		end
	end
	local chamber = WeaponInHand.Handle:FindFirstChild("Chamber")
	if chamber then
		local cs = chamber:FindFirstChild("Smoke")
		if cs then cs:Emit(10) end
		local sh = chamber:FindFirstChild("Shell")
		if sh then sh:Emit(1) end
	end
end


function Shoot()
	if WeaponData and WeaponData.Type == "Gun" and not shooting and not reloading then
		local shootType = WeaponData.ShootType
		if not shootType or shootType < 1 then return end

		-- BLOQUEO ESPECIAL PARA PUMP Y BOLT
		if shootType == 4 and (pumpCooldown or shooting) then
			return
		end
		if shootType == 5 and (boltCooldown or shooting) then
			return
		end

		if reloading or runKeyDown or SafeMode or CheckingMag then
			mouse1down = false
			return
		end

		if Ammo <= 0 or WeaponData.Jammed then
			WeaponInHand.Handle.Click:Play()
			mouse1down = false
			return
		end

		mouse1down = true

		task.spawn(function()
			-- ShootType 1: Semi-Auto
			if WeaponData and WeaponData.ShootType == 1 then
				shooting = true
				Evt.Atirar:FireServer(WeaponTool,Suppressor,FlashHider)
				for _ =  1, WeaponData.Bullets do
					Thread:Spawn(CreateBullet)
				end
				Ammo = Ammo - 1
				GunFx()
				JamChance()
				UpdateGui()
				Thread:Spawn(Recoil)
				task.wait(60/WeaponData.ShootRate)
				shooting = false

				-- ShootType 2: Burst   [F-50] 22/09/2026
				-- Un click = rafaga completa. Soltar el click YA NO la corta
				-- (antes el bucle hacia break con "not mouse1down").
				-- shooting queda en true toda la rafaga + la pausa, asi que
				-- spamear click no encima rafagas. Solo se corta si cambias
				-- de arma, recargas, esprintas, sin balas o encasquillada.
				-- Opcional en ACS_Settings:  self.BurstCooldown = 0.25
				-- (segundos entre rafagas; si no esta, 60/ShootRate).
			elseif WeaponData and WeaponData.ShootType == 2 then

				local myTool = WeaponTool
				local myData = WeaponData

				local shots     = math.max(1, math.floor(tonumber(myData.BurstShot) or 3))
				local baseRate  = tonumber(myData.ShootRate) or 600
				local burstRate = baseRate * (tonumber(myData.BurstRateMultiplier) or 1)
				if burstRate <= 0 then burstRate = baseRate end
				local cooldown  = tonumber(myData.BurstCooldown) or (60 / baseRate)

				shooting = true

				for i = 1, shots do
					if WeaponTool ~= myTool or reloading or runKeyDown
						or Ammo <= 0 or myData.Jammed then
						break
					end

					Evt.Atirar:FireServer(myTool, Suppressor, FlashHider)
					for _ = 1, myData.Bullets do
						Thread:Spawn(CreateBullet)
					end

					Ammo = Ammo - 1
					GunFx()
					JamChance()
					UpdateGui()
					Thread:Spawn(Recoil)

					if i < shots then
						task.wait(60 / burstRate)
					end
				end

				-- Pausa entre rafagas. Si cambiaste de arma a mitad, unset()
				-- ya dejo shooting en false y no se toca el arma nueva.
				if WeaponTool == myTool then
					task.wait(cooldown)
				end
				if WeaponTool == myTool then
					shooting = false
				end

				-- ShootType 3: Full Auto
			elseif WeaponData and WeaponData.ShootType == 3 then
				while mouse1down do
					if shooting or Ammo <= 0 or WeaponData.Jammed then
						break
					end
					shooting = true
					Evt.Atirar:FireServer(WeaponTool,Suppressor,FlashHider)
					for _ =  1, WeaponData.Bullets do
						Thread:Spawn(CreateBullet)
					end
					Ammo = Ammo - 1
					GunFx()
					JamChance()
					UpdateGui()
					Thread:Spawn(Recoil)
					task.wait(60/WeaponData.ShootRate)
					shooting = false
				end

				-- ShootType 4: Pump Action
			elseif WeaponData and WeaponData.ShootType == 4 then

				if shooting or reloading or Ammo <= 0 or WeaponData.Jammed or pumpCooldown then
					return
				end

				-- ACTIVAR COOLDOWN INMEDIATAMENTE
				pumpCooldown = true
				shooting = true

				-- Disparo
				Evt.Atirar:FireServer(WeaponTool, Suppressor, FlashHider)

				for _ = 1, WeaponData.Bullets do
					Thread:Spawn(CreateBullet)
				end

				Ammo -= 1
				GunFx()
				JamChance()
				UpdateGui()
				Thread:Spawn(Recoil)

				-- Animacion de bombeo de forma SINCRONA
				if AnimData and AnimData.PumpAnim then
					AnimData.PumpAnim({
						RArmWeld,
						LArmWeld,
						GunWeld,
						WeaponInHand,
						ViewModel
					})
				else
					-- Si no hay animacion, usar un delay fijo
					task.wait(60 / WeaponData.ShootRate)
				end

				-- Espera adicional para asegurar que la animacion termine
				task.wait(0.15)

				-- DESBLOQUEAR
				shooting = false
				pumpCooldown = false
				mouse1down = false  -- Forzar reset del click

				-- ShootType 5: Bolt Action
			elseif WeaponData and WeaponData.ShootType == 5 then

				if shooting or reloading or Ammo <= 0 or WeaponData.Jammed or boltCooldown then
					return
				end

				-- ACTIVAR COOLDOWN INMEDIATAMENTE
				boltCooldown = true
				shooting = true

				-- Un solo disparo
				Evt.Atirar:FireServer(WeaponTool, Suppressor, FlashHider)

				for _ = 1, WeaponData.Bullets do
					Thread:Spawn(CreateBullet)
				end

				Ammo -= 1
				GunFx()
				JamChance()
				UpdateGui()
				Thread:Spawn(Recoil)

				-- Animacion de cerrojo SINCRONA
				if AnimData and AnimData.PumpAnim then
					AnimData.PumpAnim({RArmWeld, LArmWeld, GunWeld, WeaponInHand, ViewModel})
				else
					task.wait(60 / WeaponData.ShootRate)
				end

				task.wait(0.15)

				-- DESBLOQUEAR
				shooting = false
				boltCooldown = false
				mouse1down = false

				-- ShootType 6: Charge
			elseif WeaponData and WeaponData.ShootType == 6 then
				if shooting or reloading or not mouse1down or WeaponData.Jammed then
					return
				end

				local entryCost = WeaponData.ChargeAmmoCost or 1
				if WeaponData.ChargePartialFire == true then entryCost = 1 end
				if Ammo < entryCost then
					if WeaponInHand and WeaponInHand.Handle:FindFirstChild("Click") then
						WeaponInHand.Handle.Click:Play()
					end
					mouse1down = false
					return
				end

				if shooting or reloading or not mouse1down or Ammo <= 0 or WeaponData.Jammed then
					return
				end

				-- Capturar el arma activa al iniciar la carga
				local myTool = WeaponTool
				local myData = WeaponData

				shooting = true
				isCharging = true

				-- Config
				local chargeTime    = myData.ChargeTime          or 2
				local releaseToFire = myData.ChargeReleaseToFire == true
				local scaleDamage   = myData.ChargeScaleDamage   == true
				local scaleVelocity = myData.ChargeScaleVelocity == true
				local minRatio      = myData.ChargeMinRatio      or 0
				local minDmgMult    = myData.ChargeMinDamageMult or 0
				local minSpdMult    = myData.ChargeMinSpeedMult  or 0
				local moveBehavior  = myData.ChargeMoveBehavior  or "none"
				local moveThreshold = myData.ChargeMoveThreshold or 2
				local decayRate     = myData.ChargeDecayRate     or 1
				local fullAt        = math.clamp(myData.ChargeFullSoundAt or 1, 0.05, 1)
				-- [CHARGE SEMI 22092026] Modo semi tipo R8 (CS2):
				-- cargar -> dispara 1 vez al llenarse -> hay que volver a
				-- cargar antes del siguiente disparo.
				local semiMode     = myData.ChargeSemi == true
				local semiRepeat   = myData.ChargeSemiRepeat ~= false
				local semiCooldown = myData.ChargeSemiCooldown or (60 / (myData.ShootRate or 600))
				if semiMode then releaseToFire = false end

				local curve       = math.max(myData.ChargeCurve or 1, 0.05)
				local curveDamage = math.max(myData.ChargeCurveDamage   or curve, 0.05)
				local curveSpeed  = math.max(myData.ChargeCurveVelocity or curve, 0.05)
				local curveShape  = math.max(myData.ChargeCurveShape    or curve, 0.05)

				if chargeTime <= 0 then chargeTime = 0.01 end

				-- Perdigones y dispersion: solo si ChargeShotgun esta activo
				local maxPellets, minPellets = myData.Bullets, myData.Bullets
				local maxSpread,  minSpread  = 0, 0

				if myData.ChargeShotgun == true then
					maxPellets = myData.ChargeBullets    or myData.Bullets
					minPellets = myData.ChargeMinBullets or maxPellets
					maxSpread  = myData.ChargeSpread     or 0
					minSpread  = myData.ChargeMinSpread  or maxSpread
				end

				-- Referencias de sonido
				local ChargeEvt = Evt:FindFirstChild("ChargeSound")
				local muzzleRef
				local handle = myTool:FindFirstChild("Handle") or (WeaponInHand and WeaponInHand:FindFirstChild("Handle"))
				if handle then
					muzzleRef = handle:FindFirstChild("Muzzle")
				end

				local atFull = false

				local function StopCharge()
					if ActiveChargeSound and ActiveChargeSound.IsPlaying then
						ActiveChargeSound:Stop()
					end
					if ActiveFullSound and ActiveFullSound.IsPlaying then
						ActiveFullSound:Stop()
					end
					ActiveChargeSound = nil
					ActiveFullSound   = nil
					atFull = false
					if ChargeEvt then ChargeEvt:FireServer(myTool, "stop") end
					-- [ARCO 03/10] Soltar / cancelar la carga (el arco destensa la cuerda)
					if AnimData and AnimData.ChargeRelease and WeaponTool == myTool then
						pcall(AnimData.ChargeRelease, { RArmWeld, LArmWeld, GunWeld, WeaponInHand, ViewModel })
					end
				end

				-- Entrar al zumbido de carga maxima
				local function EnterFull()
					if atFull then return end
					atFull = true
					if ActiveChargeSound and ActiveChargeSound.IsPlaying then
						ActiveChargeSound:Stop()
					end
					local s = muzzleRef and muzzleRef:FindFirstChild("ChargeFull")
					if s and s:IsA("Sound") then
						s.Looped = true
						s.TimePosition = 0
						s:Play()
						ActiveFullSound = s
					end
					if ChargeEvt then ChargeEvt:FireServer(myTool, "full") end
				end

				-- Volver del zumbido al sonido de carga
				local function ExitFull()
					if not atFull then return end
					atFull = false
					if ActiveFullSound and ActiveFullSound.IsPlaying then
						ActiveFullSound:Stop()
					end
					ActiveFullSound = nil
					if ActiveChargeSound and not ActiveChargeSound.IsPlaying then
						ActiveChargeSound:Resume()
					end
					if ChargeEvt then ChargeEvt:FireServer(myTool, "resume") end
				end

				local function AbortCharge()
					StopCharge()
					isCharging = false
					if WeaponTool == myTool then
						shooting = false
						UpdateGui()
					end
				end

				-- Deteccion de movimiento
				local function IsMoving()
					if Humanoid.MoveDirection.Magnitude > 0 then return true end
					local root = char and char:FindFirstChild("HumanoidRootPart")
					if root then
						local v = root.AssemblyLinearVelocity
						if Vector3.new(v.X, 0, v.Z).Magnitude > moveThreshold then return true end
					end
					return false
				end

				-- Particulas de carga
				local chargeFX = muzzleRef and muzzleRef:FindFirstChild("ChargeFX")
				if not (chargeFX and chargeFX:IsA("ParticleEmitter")) then chargeFX = nil end

				local emitAccum = 0

				--==========================================================
				--  [EXTRA] Dos bugs latentes del bloque de carga:
				--
				--  1) fxNetAccum y lastSentRate estaban declarados DENTRO
				--     de EmitCharge, asi que se reiniciaban en cada frame
				--     y el throttle de red nunca llegaba a 0.25s: la
				--     replicacion de particulas jamas se disparaba.
				--  2) ChargeHUD usaba "dt" como global (nil), porque el
				--     dt real se declara dentro del while de abajo. Con
				--     ChargeParticles = true eso reventaba en "rate * dt".
				--
				--  Ahora los acumuladores viven aqui y dt se pasa como
				--  parametro.
				--==========================================================
				local fxNetAccum = 0
				local lastSentRate = -1

				local function ReplicateFX(ratio, dt)
					if not chargeFX or myData.ChargeParticles ~= true then return end
					if not ChargeEvt then return end

					fxNetAccum = fxNetAccum + dt
					if fxNetAccum < 0.25 then return end
					fxNetAccum = 0

					local rMin = myData.ChargeEmitMin  or 3
					local rMax = myData.ChargeEmitRate or 20
					local rate = rMin + (rMax - rMin) * ratio

					if math.abs(rate - lastSentRate) < 0.5 then return end
					lastSentRate = rate
					ChargeEvt:FireServer(myTool, "fx", rate)
				end

				local function EmitCharge(ratio, dt)
					if not chargeFX or myData.ChargeParticles ~= true then return end
					local rMin = myData.ChargeEmitMin  or 3
					local rMax = myData.ChargeEmitRate or 20
					local rate = rMin + (rMax - rMin) * ratio
					emitAccum = emitAccum + rate * dt
					local n = math.floor(emitAccum)
					if n >= 1 then
						emitAccum = emitAccum - n
						chargeFX:Emit(n)
					end
				end

				-- Animacion de carga
				local animAccum = 0
				local function PlayChargeAnim(dt)
					local period = myData.ChargeAnimLoop or 0
					if period <= 0 then return end
					if not (AnimData and AnimData.ChargeAnim) then return end
					animAccum = animAccum + dt
					if animAccum < period then return end
					animAccum = 0
					task.spawn(function()
						pcall(function()
							AnimData.ChargeAnim({ RArmWeld, LArmWeld, GunWeld, WeaponInHand, ViewModel })
						end)
					end)
				end

				-- Costo de municion
				local function AmmoCost(ratio)
					local cost = myData.ChargeAmmoCost or 1
					if myData.ChargeCostScales == true then
						cost = math.ceil(cost * ratio)
					end
					return math.max(1, math.floor(cost))
				end

				-- Disparo cargado
				local function FireCharged(ratio)
					local cost = AmmoCost(ratio)

					if Ammo < cost then
						if myData.ChargePartialFire == true and Ammo > 0 then
							cost = Ammo
						else
							if WeaponInHand and WeaponInHand.Handle:FindFirstChild("Click") then
								WeaponInHand.Handle.Click:Play()
							end
							return false
						end
					end

					local cd = ratio ^ curveDamage
					local cv = ratio ^ curveSpeed
					local cs = ratio ^ curveShape

					local dmgMult = scaleDamage   and (minDmgMult + (1 - minDmgMult) * cd) or 1
					local spdMult = scaleVelocity and (minSpdMult + (1 - minSpdMult) * cv) or 1
					spdMult = math.max(spdMult, 0.05)

					local pellets = math.max(1, math.round(minPellets + (maxPellets - minPellets) * cs))
					local spread  = math.max(0, minSpread + (maxSpread - minSpread) * cs)

					if myData.ChargeSplitDamage == true then
						dmgMult = dmgMult / pellets
					end

					-- Sonido de disparo cargado
					local chargeSnd = nil
					if muzzleRef then
						local cf = muzzleRef:FindFirstChild("ChargeFire")
						if cf and cf:IsA("Sound") and ratio >= (myData.ChargeFireSoundAt or 1) then
							chargeSnd = 1
							if myData.ChargeFirePitch == true then
								local pMin = myData.ChargeFirePitchMin or 1.3
								local pMax = myData.ChargeFirePitchMax or 1.0
								chargeSnd = pMin + (pMax - pMin) * ratio
							end
						end
					end

					Evt.Atirar:FireServer(myTool, Suppressor, FlashHider, chargeSnd)

					for _ = 1, pellets do
						task.spawn(CreateBullet, dmgMult, spdMult, spread)
					end

					Ammo -= cost
					GunFx(chargeSnd)
					JamChance()
					UpdateGui()
					Thread:Spawn(Recoil)

					-- [ARCO 03/10] Disparo cargado (la cuerda vuelve de golpe), aunque FireAnimLoop = false
					if AnimData and AnimData.ChargeShot then
						pcall(AnimData.ChargeShot, { RArmWeld, LArmWeld, GunWeld, WeaponInHand, ViewModel }, ratio)
					end

					-- Animacion de disparo
					if myData.FireAnimLoop ~= false and AnimData and AnimData.ChargeFireAnim then
						task.spawn(function()
							pcall(function()
								AnimData.ChargeFireAnim({ RArmWeld, LArmWeld, GunWeld, WeaponInHand, ViewModel })
							end)
						end)
					end

					return true
				end

				-- HUD en vivo
				local function ChargeHUD(ratio, dt)
					EmitCharge(ratio, dt)
					ReplicateFX(ratio, dt)
					PlayChargeAnim(dt)
					-- [ARCO 03/10] Cada frame de la carga con el porcentaje real (0..1):
					-- el arco tensa la cuerda segun lo cargado.
					if AnimData and AnimData.ChargeProgress then
						pcall(AnimData.ChargeProgress, { RArmWeld, LArmWeld, GunWeld, WeaponInHand, ViewModel }, ratio, dt)
					end
					local gunHUD = SE_GUI and SE_GUI:FindFirstChild("GunHUD")
					local ftext  = gunHUD and gunHUD:FindFirstChild("FText")
					if ftext then
						local tag = (ratio >= fullAt) and " | READY" or (" | Charge " .. math.floor(ratio * 100) .. "%")
						ftext.Text = Ammo .. "/" .. StoredAmmo .. tag
					end
				end

				-- Arrancar sonido de carga (se reusa en cada ciclo del modo semi)
				local function StartChargeSound()
					if muzzleRef then
						local s = muzzleRef:FindFirstChild("Charge")
						if s and s:IsA("Sound") then
							s:Stop()
							s.TimePosition = 0
							s:Play()
							ActiveChargeSound = s
						end
					end
					if ChargeEvt then ChargeEvt:FireServer(myTool, "start") end
				end

				StartChargeSound()

				local charge = 0
				local wasMoving = false

				--==========================================================
				--  [CHARGE SEMI 22092026] Ciclo exterior. En los modos
				--  release y auto se recorre UNA sola vez (igual que antes).
				--  En modo semi se repite: cargar -> disparar 1 vez ->
				--  volver a cargar... mientras sigas con click (R8).
				--==========================================================
				while true do

					-- Loop de carga
					while true do
						local dt = task.wait()

						if WeaponTool ~= myTool or reloading or Ammo <= 0 or myData.Jammed then
							AbortCharge()
							return
						end

						if not mouse1down then
							break
						end

						local moving = (moveBehavior ~= "none") and IsMoving() or false

						if moving and moveBehavior == "cancel" then
							AbortCharge()
							return

						elseif moving and moveBehavior == "decay" then
							charge = math.max(0, charge - dt * decayRate)
							if not wasMoving and not atFull then
								if ActiveChargeSound and ActiveChargeSound.IsPlaying then
									ActiveChargeSound:Pause()
								end
								if ChargeEvt then ChargeEvt:FireServer(myTool, "pause") end
							end

						else
							charge = math.min(chargeTime, charge + dt)
							if wasMoving and not atFull then
								if ActiveChargeSound and not ActiveChargeSound.IsPlaying then
									ActiveChargeSound:Resume()
								end
								if ChargeEvt then ChargeEvt:FireServer(myTool, "resume") end
							end
						end

						wasMoving = moving

						local ratio = charge / chargeTime
						ChargeHUD(ratio, dt)					-- [EXTRA] dt como parametro

						-- Modo automatico: salir a disparar al completar
						if not releaseToFire and charge >= chargeTime then
							break
						end

						-- Zumbido de carga maxima (solo en modo release-to-fire)
						if releaseToFire then
							if ratio >= fullAt then
								EnterFull()
							elseif atFull then
								ExitFull()
							end
						end
					end

					isCharging = false

					local ratio = math.clamp(charge / chargeTime, 0, 1)

					if semiMode then
						-- Solto antes de completar la carga: se cancela sin gastar bala
						if charge < chargeTime then break end
						if WeaponTool ~= myTool or Ammo <= 0 or reloading or myData.Jammed then break end
						if not FireCharged(1) then break end
						StopCharge()

						if not semiRepeat then
							-- ChargeSemiRepeat = false: hay que soltar y volver a dar click
							while mouse1down and WeaponTool == myTool do task.wait() end
							task.wait(semiCooldown)
							break
						end

						-- Pausa del martillo antes de volver a cargar
						task.wait(semiCooldown)
						if WeaponTool ~= myTool or not mouse1down or Ammo <= 0 or reloading or myData.Jammed then
							break
						end

						-- Reiniciar la carga para el siguiente tiro
						charge = 0
						wasMoving = false
						emitAccum = 0
						animAccum = 0
						fxNetAccum = 0
						lastSentRate = -1
						isCharging = true
						StartChargeSound()

					elseif releaseToFire then
						if ratio >= minRatio and WeaponTool == myTool and Ammo > 0 and not reloading and not myData.Jammed then
							FireCharged(ratio)
						end
						break
					else
						while WeaponTool == myTool and mouse1down and Ammo > 0 and not myData.Jammed and not reloading do
							if not FireCharged(1) then break end
							task.wait(60 / myData.ShootRate)
						end
						break
					end
				end

				StopCharge()
				if WeaponTool == myTool then
					shooting = false
					UpdateGui()
				end
			end
		end)

	elseif WeaponData and WeaponData.Type == "Melee"
		and (not runKeyDown or WeaponData.MeleeWhileSprinting ~= false) then
		if not shooting then
			-- [BATE] mouse1down se pone aqui igual que en las armas de fuego;
			-- handleAction lo baja al soltar ("Fire", End). MeleeSwing decide
			-- si fue golpe normal o cargado.
			-- [MELEE SPRINT 21092026] se puede golpear corriendo. Se saca el
			-- arma de la pose de sprint (GunStance 0) para que los demas vean
			-- el golpe; al terminar, RunCheck() la regresa a sprint si sigues
			-- con Shift. Poner MeleeWhileSprinting = false en el ACS_Settings
			-- de un arma para volver al comportamiento viejo.
			if runKeyDown and GunStance == 3 then
				GunStance = 0
				Evt.GunStance:FireServer(GunStance, LL_StancePose(GunStance, AnimData))
			end
			mouse1down = true
			task.spawn(MeleeSwing)
		end
	end
end

local L_150_ = {}

local LeanSpring = {}
LeanSpring.cornerPeek = SpringMod.new(0)
LeanSpring.cornerPeek.d = 1
LeanSpring.cornerPeek.s = 20
LeanSpring.peekFactor = math.rad(-15)
LeanSpring.dirPeek = 0

function L_150_.Update()

	LeanSpring.cornerPeek.t = LeanSpring.peekFactor * Virar
	local NewLeanCF = CFrame.fromAxisAngle(Vector3.new(0, 0, 1), LeanSpring.cornerPeek.p)
	cam.CFrame = cam.CFrame * NewLeanCF
end

Run:BindToRenderStep("Camera Update", 200, L_150_.Update)

function RunCheck()
	if runKeyDown then
		mouse1down = false
		GunStance = 3
		Evt.GunStance:FireServer(GunStance, LL_StancePose(GunStance, AnimData))
		SprintAnim()
	else
		if aimming then
			GunStance = 2
			Evt.GunStance:FireServer(GunStance, LL_StancePose(GunStance, AnimData))
		else
			GunStance = 0
			Evt.GunStance:FireServer(GunStance, LL_StancePose(GunStance, AnimData))
		end
		IdleAnim()
	end
end

local function SendStance(label)
	local validStance = Stances == 0 or Stances == 1 or Stances == 2
	local validLean = Virar == -1 or Virar == 0 or Virar == 1
	if not validStance or not validLean then
		warn("[ACS] Invalid stance state", label, Stances, Virar)
		return
	end
	dprint("[ACS] Stance", label, Stances, Virar)
	Stance:FireServer(Stances, Virar)
end

function Stand()
	SendStance("Stand")
	TS:Create(Humanoid, TweenInfo.new(.3), {CameraOffset = Vector3.new(CameraX,CameraY,0)} ):Play()

	SE_GUI.MainFrame.Poses.Levantado.Visible = true
	SE_GUI.MainFrame.Poses.Agaixado.Visible = false
	SE_GUI.MainFrame.Poses.Deitado.Visible = false

	-- Velocidad y salto los decide ApplyMoveSpeed:
	-- postura + peso del arma + bono de bunny hop.
	ApplyMoveSpeed()

	IsStanced = false

end

function Crouch()
	SendStance("Crouch")
	TS:Create(Humanoid, TweenInfo.new(.3), {CameraOffset = Vector3.new(CameraX,CameraY,0)} ):Play()

	SE_GUI.MainFrame.Poses.Levantado.Visible = false
	SE_GUI.MainFrame.Poses.Agaixado.Visible = true
	SE_GUI.MainFrame.Poses.Deitado.Visible = false

	ApplyMoveSpeed()

	IsStanced = true
end

function Prone()
	SendStance("Prone")
	TS:Create(Humanoid, TweenInfo.new(.3), {CameraOffset = Vector3.new(CameraX,CameraY,0)} ):Play()

	SE_GUI.MainFrame.Poses.Levantado.Visible = false
	SE_GUI.MainFrame.Poses.Agaixado.Visible = false
	SE_GUI.MainFrame.Poses.Deitado.Visible = true

	ApplyMoveSpeed()

	IsStanced = true
end

function Lean()
	TS:Create(Humanoid, TweenInfo.new(.3), {CameraOffset = Vector3.new(CameraX,CameraY,0)} ):Play()
	SendStance("Lean")

	if Virar == 0 then
		SE_GUI.MainFrame.Poses.Esg_Left.Visible = false
		SE_GUI.MainFrame.Poses.Esg_Right.Visible = false
	elseif Virar == 1 then
		SE_GUI.MainFrame.Poses.Esg_Left.Visible = false
		SE_GUI.MainFrame.Poses.Esg_Right.Visible = true
	elseif Virar == -1 then
		SE_GUI.MainFrame.Poses.Esg_Left.Visible = true
		SE_GUI.MainFrame.Poses.Esg_Right.Visible = false
	end
end

----------//Animation Loader\\----------
function EquipAnim()
	AnimDebounce = false
	pcall(function()
		AnimData.EquipAnim({
			RArmWeld,
			LArmWeld,
			GunWeld,
			WeaponInHand,
			ViewModel,
		})
	end)
	AnimDebounce = true
end


function IdleAnim()
	pcall(function()
		AnimData.IdleAnim({
			RArmWeld,
			LArmWeld,
			GunWeld,
			WeaponInHand,
			ViewModel,
		})
	end)
	AnimDebounce = true
end

function SprintAnim()
	AnimDebounce = false
	--  [DUAL 22/09] En duales se corre con UNA pose general para cualquier
	--  pistola (DualConfig.SprintPose): cada arma trae la suya pensada para
	--  una mano y unas bajaban y otras subian. Solo se mueve el brazo
	--  derecho; el izquierdo lo copia en espejo.
	if DualWield and DualWield.active and typeof(DualWield.sprintPose) == "CFrame" and RArmWeld then
		pcall(function()
			TS:Create(RArmWeld, TweenInfo.new(.25, Enum.EasingStyle.Sine), { C1 = DualWield.sprintPose:Inverse() }):Play()
			task.wait(.25)
		end)
		return
	end
	pcall(function()
		AnimData.SprintAnim({
			RArmWeld,
			LArmWeld,
			GunWeld,
			WeaponInHand,
			ViewModel,
		})
	end)
end

function HighReady()
	pcall(function()
		AnimData.HighReady({
			RArmWeld,
			LArmWeld,
			GunWeld,
			WeaponInHand,
			ViewModel,
		})
	end)
end

function LowReady()
	pcall(function()
		AnimData.LowReady({
			RArmWeld,
			LArmWeld,
			GunWeld,
			WeaponInHand,
			ViewModel,
		})
	end)
end

function Patrol()
	pcall(function()
		AnimData.Patrol({
			RArmWeld,
			LArmWeld,
			GunWeld,
			WeaponInHand,
			ViewModel,
		})
	end)
end

function ReloadAnim()
	--  [22/09] En duales: la recarga general de dos pistolas
	if DualWield and DualWield.active and DualWield.reloadAnim then
		pcall(DualWield.reloadAnim, false, DualWield.leftReloading() and "both" or "right")
		return
	end
	pcall(function()
		AnimData.ReloadAnim({
			RArmWeld,
			LArmWeld,
			GunWeld,
			WeaponInHand,
			ViewModel,
		})
	end)
end

function TacticalReloadAnim()
	--  [22/09] En duales: la recarga general de dos pistolas (vacia)
	if DualWield and DualWield.active and DualWield.reloadAnim then
		pcall(DualWield.reloadAnim, true, DualWield.leftReloading() and "both" or "right")
		return
	end
	pcall(function()
		AnimData.TacticalReloadAnim({
			RArmWeld,
			LArmWeld,
			GunWeld,
			WeaponInHand,
			ViewModel,
		})
	end)
end

function JammedAnim()
	pcall(function()
		AnimData.JammedAnim({
			RArmWeld,
			LArmWeld,
			GunWeld,
			WeaponInHand,
			ViewModel,
		})
	end)
end

function PumpAnim()
	reloading = true
	pcall(function()
		AnimData.PumpAnim({
			RArmWeld,
			LArmWeld,
			GunWeld,
			WeaponInHand,
			ViewModel,
		})
	end)
	reloading = false
end

function MagCheckAnim()
	CheckingMag = true
	pcall(function()
		AnimData.MagCheck({
			RArmWeld,
			LArmWeld,
			GunWeld,
			WeaponInHand,
			ViewModel,
		})
	end)
	CheckingMag = false
end

function meleeAttack()
	pcall(function()
		AnimData.meleeAttack({
			RArmWeld,
			LArmWeld,
			GunWeld,
			WeaponInHand,
			ViewModel,
		})
	end)
end

--==========================================================================
--  [BATE] GOLPE CARGADO  (instalado 15/09/2026, disenado el 13/09)
--  Click rapido = golpe normal. Mantener = cargar; al soltar con la carga
--  completa sale el golpe cargado (mismo dano; a la cabeza aturde,
--  ragdollea y empuja via el remote MeleeHeavy).
--  La carga no se cancela con nada salvo cambiar de arma o morir.
--  Dentro de su propia funcion: el chunk esta al limite de 200 locals.
--  Solo sale MeleeSwing (global, igual que Shoot o RunCheck).
--  Valores por defecto sobreescribibles desde el ACS_Settings del arma:
--    MeleeCharge, MeleeChargeTime, MeleeMinRatio, MeleeTapWindow,
--    MeleeCooldown, MeleeHeavyCooldown
--==========================================================================
;(function()
	local DEF = {
		MeleeCharge        = true,	-- false = melee de siempre, sin carga
		MeleeChargeTime    = 0.85,	-- segundos hasta tener el golpe listo
		MeleeMinRatio      = 1,		-- 1 = solo cuenta a carga COMPLETA
		MeleeTapWindow     = 0.12,	-- por debajo de esto siempre es golpe normal
		MeleeCooldown      = 0.35,	-- espera despues del golpe normal
		MeleeHeavyCooldown = 0.75,	-- espera despues del cargado
	}

	local function conf(key)
		local v = WeaponData and WeaponData[key]
		if v == nil then return DEF[key] end
		return v
	end

	local function animObjs()
		return { RArmWeld, LArmWeld, GunWeld, WeaponInHand, ViewModel }
	end

	-- Sonidos opcionales en el Handle: Charge, ChargeReady, HeavySwing
	local function handleSound(name)
		if not WeaponInHand then return nil end
		local handle = WeaponInHand:FindFirstChild("Handle")
		if not handle then return nil end
		local s = handle:FindFirstChild(name)
		if not (s and s:IsA("Sound")) then return nil end
		s:Stop()
		s.TimePosition = 0
		s:Play()
		return s
	end

	local function hitTimeFor(heavy)
		if heavy then
			return (AnimData and AnimData.MeleeHeavyHitTime) or 0.42
		end
		return (AnimData and AnimData.MeleeHitTime) or 0.30
	end

	local function heavyAnim()
		if not (AnimData and AnimData.MeleeHeavyAnim) then
			meleeAttack()
			return
		end
		pcall(function()
			AnimData.MeleeHeavyAnim(animObjs())
		end)
	end

	function MeleeSwing()
		if shooting then return end
		if not (WeaponData and WeaponData.Type == "Melee") then return end

		shooting = true

		local myTool     = WeaponTool
		local chargeTime = math.max(conf("MeleeChargeTime"), 0.05)
		local minRatio   = math.clamp(conf("MeleeMinRatio"), 0, 1)
		local tapWindow  = conf("MeleeTapWindow")
		local canCharge  = conf("MeleeCharge") == true

		local held      = 0
		local ready     = false
		local chargeSnd = nil

		if canCharge then
			if AnimData and AnimData.MeleeChargeAnim then
				pcall(function()
					AnimData.MeleeChargeAnim(animObjs(), chargeTime)
				end)
			end
			chargeSnd = handleSound("Charge")

			while mouse1down do
				local dt = task.wait()
				held = held + dt

				-- unicos cortes: cambiaste de arma o te mataron
				if WeaponTool ~= myTool or Humanoid.Health <= 0 then
					if chargeSnd then chargeSnd:Stop() end
					IdleAnim()
					shooting = false
					return
				end

				if not ready and (held / chargeTime) >= minRatio then
					ready = true
					if chargeSnd then chargeSnd:Stop() end
					chargeSnd = nil
					handleSound("ChargeReady")
				end
			end

			if chargeSnd then chargeSnd:Stop() end
		end

		local heavy = ready and (held > tapWindow)

		-- el raycast sale en el momento del CONTACTO del swing
		task.delay(hitTimeFor(heavy), function()
			if WeaponTool == myTool and Humanoid.Health > 0 then
				meleeCast(heavy)
			end
		end)

		if heavy then
			heavyAnim()
			task.wait(conf("MeleeHeavyCooldown"))
		else
			meleeAttack()
			task.wait(conf("MeleeCooldown"))
		end

		if WeaponTool == myTool then
			RunCheck()
		end
		shooting = false
	end
end)()

function GrenadeReady()
	pcall(function()
		AnimData.GrenadeReady({
			RArmWeld,
			LArmWeld,
			GunWeld,
			WeaponInHand,
			ViewModel,
		})
	end)
end

function GrenadeThrow()
	pcall(function()
		AnimData.GrenadeThrow({
			RArmWeld,
			LArmWeld,
			GunWeld,
			WeaponInHand,
			ViewModel,
		})
	end)
end
----------//Animation Loader\\----------

----------//KeyBinds\\----------
_G.LL_Bind("Run", handleAction, false, Enum.KeyCode.LeftShift,Enum.KeyCode.ButtonL3)

_G.LL_Bind("Stand", handleAction, false, Enum.KeyCode.X)
_G.LL_Bind("Crouch", handleAction, false, Enum.KeyCode.C, Enum.KeyCode.ButtonB)
_G.LL_Bind("NVG", handleAction, false, Enum.KeyCode.N)

_G.LL_Bind("ToggleWalk", handleAction, false, Enum.KeyCode.Z)
_G.LL_Bind("LeanLeft", handleAction, false, Enum.KeyCode.Q)
_G.LL_Bind("LeanRight", handleAction, false, Enum.KeyCode.E)

-- [15/09] PlatformControls (celular y mando) usa las MISMAS acciones que el
-- teclado, y lee este estado para decidir (agacharse o levantarse, etc.).
-- Tabla global y no local: este chunk esta al limite de 200 locals.
_G.ACS_Controls = {
	handle = handleAction,
	state = function()
		return {
			Stances = Stances, aimming = aimming, runKeyDown = runKeyDown,
			mouse1down = mouse1down, Steady = Steady, Virar = Virar,
			BipodActive = BipodActive, CanBipod = CanBipod,
			equipped = WeaponData ~= nil,
			-- [MELEE SPRINT 21092026] PlatformControls no corta el sprint al
			-- golpear con melee
			weaponType = WeaponData and WeaponData.Type or nil,
			-- [DUAL 22/09] duales activas: el HUD tactil usa el segundo boton
			-- de fuego para la pistola izquierda.
			dual = (DualWield and DualWield.active) == true,
			meleeWhileSprinting = WeaponData ~= nil and WeaponData.MeleeWhileSprinting ~= false,
			-- [15/09] sensibilidad al apuntar segun la mira (PlatformControls
			-- la aplica en celular y mando; el menu la muestra)
			aimFov = CurrentAimFov and CurrentAimFov() or nil,
			aimSens = CurrentAimSens and CurrentAimSens() or Sens,
			aimSensMult = (aimming and CurrentAimSens) and (CurrentAimSens() / 100) or 1,
		}
	end,
}

-- ============================================================
-- [15/09] SENSIBILIDAD SEGUN LA MIRA
-- El "zoom" es el FOV que ACS pone al apuntar (SightZoom de la mira montada
-- o Zoom / Zoom2 del arma, segun la parte de mira activa).
--   FOV >= 60  -> AimSensitivity   (miras normales)
--   FOV <= 30  -> ScopeSensitivity (miras de aumento)
--   en medio   -> mezcla lineal entre las dos
-- Funciones globales y no locales: este chunk esta al limite de 200 locals.
-- ============================================================
function CurrentAimFov()
	-- con vision nocturna y mira NVAim, ACS apunta a FOV 70
	if NVG and WeaponInHand and WeaponInHand:FindFirstChild("AimPart")
		and WeaponInHand.AimPart:FindFirstChild("NVAim") then
		return 70
	end
	local fov = (AimPartMode == 2) and ModTable.Zoom2Value or ModTable.ZoomValue
	return tonumber(fov) or 70
end

-- Devuelve la sensibilidad (5-100) y si cuenta como mira de aumento.
function CurrentAimSens()
	local aimSens = Sens
	local scopeSens = (AimSettings and AimSettings:Get("ScopeSensitivity")) or Sens
	local fov = CurrentAimFov()
	if fov <= 30 then return scopeSens, true end
	if fov >= 60 then return aimSens, false end
	local t = (fov - 30) / 30		-- 0 en zoom 30, 1 en zoom 60
	return scopeSens + (aimSens - scopeSens) * t, fov < 45
end

-- Pone MouseDeltaSensitivity segun la mira. Solo mientras apuntas: sin
-- apuntar ACS la deja en 1 y esto no la toca.
function ApplyAimSens()
	if not aimming then return end
	local want = CurrentAimSens() / 100
	if math.abs(User.MouseDeltaSensitivity - want) > 0.001 then
		User.MouseDeltaSensitivity = want
	end
end

-- Rueda del mouse: sube o baja la que se esta usando en ese momento.
function AdjustAimSens(delta)
	local _, scoped = CurrentAimSens()
	if scoped and AimSettings then
		local current = AimSettings:Get("ScopeSensitivity") or Sens
		AimSettings:Set("ScopeSensitivity", math.clamp(current + delta, 5, 100))
	else
		Sens = math.clamp(Sens + delta, 5, 100)
		if AimSettings then AimSettings:Set("AimSensitivity", Sens) end
	end
	UpdateGui()
	ApplyAimSens()
end
----------//KeyBinds\\----------
local HealEvt = Evt:WaitForChild("Heal")
local HEAL_RANGE = 14

local HealTargetPlayer = nil
local healSeq = 0

function StopHeal()
	-- [SPRAY 29/09] Desequipar (unset) o cancelar corta tambien el spray.
	if SprayStop then SprayStop() end

	healSeq = healSeq + 1
	local wasHealing = Healing
	Healing = false
	HealTargetPlayer = nil

	if not wasHealing then return end

	-- avisar al modulo de animacion que corte, y matar el sonido
	if WeaponInHand and WeaponInHand.Parent then
		WeaponInHand:SetAttribute("HealCancel", true)
		local handle = WeaponInHand:FindFirstChild("Handle")
		local swing = handle and handle:FindFirstChild("Swing")
		if swing and swing.IsPlaying then
			swing:Stop()
		end
	end

	if WeaponData and WeaponData.Type == "Medical" then
		task.delay(0.05, function()
			if not Healing and WeaponData and WeaponData.Type == "Medical" then
				IdleAnim()
			end
		end)
	end
end

function HealAnim(duration)
	-- se corre en su propio hilo: NO debe bloquear a StartHeal
	AnimDebounce = false
	pcall(function()
		if AnimData.HealAnim then
			AnimData.HealAnim({
				RArmWeld,
				LArmWeld,
				GunWeld,
				WeaponInHand,
				ViewModel,
			}, duration)
		else
			AnimData.GrenadeReady({
				RArmWeld,
				LArmWeld,
				GunWeld,
				WeaponInHand,
				ViewModel,
			})
		end
	end)
	AnimDebounce = true
end

function GetHealTarget()
	local origin = cam.CFrame.Position
	local dir = cam.CFrame.LookVector

	local ignore = { char, cam }
	local acsws = workspace:FindFirstChild("ACS_WorkSpace")
	if acsws then
		table.insert(ignore, acsws)
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true

	local result = workspace:Raycast(origin, dir * HEAL_RANGE, params)
	if result and result.Instance then
		local model = result.Instance:FindFirstAncestorOfClass("Model")
		if model then
			local p = Players:GetPlayerFromCharacter(model)
			if p and p ~= plr then
				return p
			end
		end
	end

	-- fallback: el jugador mas centrado en la mira dentro del rango
	local best, bestDot = nil, 0.93
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= plr and other.Character then
			local root = other.Character:FindFirstChild("HumanoidRootPart")
			local h = other.Character:FindFirstChildOfClass("Humanoid")
			if root and h and h.Health > 0 then
				local offset = root.Position - origin
				if offset.Magnitude <= HEAL_RANGE and offset.Magnitude > 0 then
					local d = dir:Dot(offset.Unit)
					if d > bestDot then
						best = other
						bestDot = d
					end
				end
			end
		end
	end
	return best
end

function StartHeal(target)
	if Healing then return end
	if not WeaponData or WeaponData.Type ~= "Medical" then return end
	if not WeaponTool or not AnimDebounce or reloading or CheckingMag then return end

	local charges = WeaponTool:GetAttribute("HealCharges") or WeaponData.HealUses or 6
	if charges <= 0 then return end

	if target == nil and Humanoid.Health >= Humanoid.MaxHealth then return end

	if target ~= nil and not target.Character then return end

	Healing = true
	HealTargetPlayer = target
	mouse1down = false

	if aimming then
		aimming = false
		ADS(aimming)
	end

	healSeq = healSeq + 1
	local healTime = WeaponData.HealTime or 3.1

	if WeaponInHand then
		WeaponInHand:SetAttribute("HealCancel", false)
	end

	-- el servidor cuenta el tiempo; aqui solo mandamos y animamos
	HealEvt:FireServer(WeaponTool, target, SKP_01 .. "-" .. plr.UserId)

	task.spawn(function()
		HealAnim(healTime)
	end)
end

HealEvt.OnClientEvent:Connect(function(status, a, b)
	if status == "done" then
		StopHeal()
		-- refrescar el HUD nativo de ACS con los usos restantes
		task.delay(0.1, function()
			pcall(UpdateGui)
		end)
	elseif status == "cancel" or status == "full" or status == "empty" then
		StopHeal()
	end
end)

--==========================================================================
--  [SPRAY 29/09/2026] FIRST AID SPRAY - LADO CLIENTE  (HealMode = "Spray")
--
--  El lado servidor (ACS_Server, remote HealSpray) seguia intacto, pero
--  este bloque se habia perdido del framework: el spray caia al camino de
--  la jeringa, que cura UNA vez por click, con HealTime = 0 y sin
--  animacion ni sonido. De ahi el spameo de click.
--
--  Mantener click:  SprayStart -> manda "start", sube el bote (SprayStart
--                   del ACS_Animations), lo sacude en bucle (SprayShake),
--                   suena Handle.Swing en loop y sale Particle.SprayFx.
--  Soltar click:    SprayStop  -> manda "stop", SprayEnd, apaga todo.
--  El servidor manda "tick" con las cargas y "empty"/"cancel" para cortar.
--
--  Va dentro de una funcion: el chunk del framework esta en el tope de 200
--  locals y no admite ni uno mas. Solo SprayStart y SprayStop son globales,
--  porque los llaman handleAction y StopHeal desde arriba.
--==========================================================================
;(function()
	local sprayEvt = Evt:WaitForChild("HealSpray", 10)
	if not sprayEvt then
		warn("[SPRAY] No existe Evt.HealSpray: el First Aid Spray no va a curar")
	end

	local active = false
	local seq = 0

	local function animObjs()
		return { RArmWeld, LArmWeld, GunWeld, WeaponInHand, ViewModel }
	end

	local function isSpray()
		return WeaponData ~= nil and WeaponData.Type == "Medical" and WeaponData.HealMode == "Spray"
	end

	-- Sonido y particulas del bote que tienes en la mano (viewmodel).
	local function setFx(on)
		local model = WeaponInHand
		if not model or not model.Parent then return end

		local handle = model:FindFirstChild("Handle")
		local sound = handle and handle:FindFirstChild("Swing")
		if sound and sound:IsA("Sound") then
			if on then
				sound.Looped = true
				if not sound.IsPlaying then
					sound.TimePosition = 0
					sound:Play()
				end
			else
				sound:Stop()
			end
		end

		local part = model:FindFirstChild("Particle")
		local emitter = part and part:FindFirstChild("SprayFx")
		if emitter and emitter:IsA("ParticleEmitter") then
			emitter.Enabled = on
		end
	end

	function SprayStop(fromServer)
		if not active then return end
		active = false
		seq = seq + 1

		setFx(false)
		if sprayEvt and not fromServer and WeaponTool then
			sprayEvt:FireServer("stop", WeaponTool, SKP_01 .. "-" .. plr.UserId)
		end

		Healing = false
		mouse1down = false
		if AnimData and AnimData.SprayEnd then
			pcall(AnimData.SprayEnd, animObjs())
		end
		AnimDebounce = true
	end

	function SprayStart()
		if active or not sprayEvt or not isSpray() then return end
		if not WeaponTool or reloading or CheckingMag then return end

		local charges = WeaponTool:GetAttribute("HealCharges") or WeaponData.HealUses or 0
		if charges <= 0 then return end

		active = true
		Healing = true          -- bloquea correr, cambiar de postura y el resto
		mouse1down = false
		seq = seq + 1
		local mine = seq

		if aimming then
			aimming = false
			ADS(aimming)
		end

		AnimDebounce = false    -- que Idle / Sprint no le pisen la pose al bote
		sprayEvt:FireServer("start", WeaponTool, SKP_01 .. "-" .. plr.UserId)
		setFx(true)

		task.spawn(function()
			if AnimData and AnimData.SprayStart then
				pcall(AnimData.SprayStart, animObjs())
			end
			local step = 0
			local stepTime = tonumber(WeaponData and WeaponData.SprayShakeTime) or 0.16
			while active and seq == mine do
				step = step + 1
				if AnimData and AnimData.SprayShake then
					pcall(AnimData.SprayShake, animObjs(), step, stepTime)
				end
				task.wait(stepTime)
			end
		end)
	end

	if sprayEvt then
		sprayEvt.OnClientEvent:Connect(function(status)
			if status == "tick" then
				pcall(UpdateGui)
			elseif status == "empty" or status == "cancel" then
				SprayStop(true)
				pcall(UpdateGui)
			end
		end)
	end
end)()

----------//Gun System\\----------
local L_199_ = nil

char.ChildAdded:Connect(function(Tool)
	if not Tool:IsA('Tool') then return end

	local s = Tool:FindFirstChild("ACS_Settings")
	local tp = s and require(s).Type or "SIN SETTINGS"

	dprint("[EQUIP]", Tool.Name, "| Type:", tp, "| ToolEquip:", ToolEquip)

	if Humanoid.Health > 0 and not ToolEquip and s ~= nil and (tp == 'Gun' or tp == 'Melee' or tp == 'Grenade' or tp == 'Medical') then
		local L_370_ = true
		if char:WaitForChild('Humanoid').Sit and char.Humanoid.SeatPart and char.Humanoid.SeatPart:IsA("VehicleSeat") then
			L_370_ = false
			dprint("[EQUIP] Bloqueado: sentado en VehicleSeat")
		end

		if L_370_ then
			L_199_ = Tool
			if not ToolEquip then
				setup(Tool)
			else
				pcall(function()
					unset()
					setup(Tool)
				end)
			end
		end
	end
end)

char.ChildRemoved:Connect(function(Tool)
	if Tool == WeaponTool then
		if ToolEquip then
			unset()
		end
	end
end)

Humanoid.Running:Connect(function(speed)
	charspeed = speed
	if speed > 0.1 then
		running = true
	else
		running = false
	end
end)

Humanoid.Swimming:Connect(function(speed)
	if Swimming then
		charspeed = speed
		if speed > 0.1 then
			running = true
		else
			running = false
		end
	end
end)

Humanoid.Died:Connect(function()
	TS:Create(char.Humanoid, TweenInfo.new(1), {CameraOffset = Vector3.new(0,0,0)} ):Play()
	ChangeStance = false
	Stand()
	Stances = 0
	Virar = 0
	CameraX = 0
	CameraY = 0
	Lean()
	Equipped = 0
	unset()
	Evt.NVG:Fire(false)
end)

Humanoid.Seated:Connect(function(IsSeated, Seat)

	if IsSeated and Seat and (Seat:IsA("VehicleSeat")) then
		unset()
		Humanoid:UnequipTools()
		CanLean = false
		plr.CameraMaxZoomDistance = gameRules.VehicleMaxZoom
	else
		plr.CameraMaxZoomDistance = game.StarterPlayer.CameraMaxZoomDistance
	end

	if IsSeated  then
		Sentado = true
		Stances = 0
		Virar = 0
		CameraX = 0
		CameraY = 0
		Stand()
		Lean()
	else
		Sentado = false
		CanLean = true
	end
end)

Humanoid.Changed:Connect(function(Property)
	if Property ~= "Jump" then return end

	-- Saltar sentado siempre te levanta del asiento
	if Humanoid.Sit == true and Humanoid.SeatPart ~= nil then
		Humanoid.Sit = false
		return
	end

	-- El cooldown antisalto de GameRules es justo lo contrario del
	-- bunny hop. Si el bunny hop esta activo en el bloque MOVE, se
	-- ignora aunque gameRules.AntiBunnyHop siga en true.
	if MoveSysHopEnabled and MoveSysHopEnabled() then return end

	if gameRules.AntiBunnyHop and Humanoid.Sit == false then
		if JumpDelay then
			Humanoid.Jump = false
			return
		end
		JumpDelay = true
		task.delay(gameRules.JumpCoolDown, function()
			JumpDelay = false
		end)
	end
end)

Humanoid.StateChanged:Connect(function(Old,state)
	if state == Enum.HumanoidStateType.Swimming then
		Swimming = true
		Stances = 0
		Virar = 0
		CameraX = 0
		CameraY = 0
		Stand()
		Lean()
	else
		Swimming = false
	end

	if gameRules.EnableFallDamage then
		if state == Enum.HumanoidStateType.Freefall and not falling then
			falling = true
			local curVel = 0
			local peak = 0

			while falling do
				curVel = HumanoidRootPart.AssemblyLinearVelocity.Magnitude
				peak = peak + 1
				Thread:Wait()
			end
			local damage = (curVel - (gameRules.MaxVelocity)) * gameRules.DamageMult
			--  [22/09 Ventarron] curVel es la velocidad TOTAL (horizontal incluida):
			--  salir volando por el viento a 90 contaba como una caida mortal.
			--  Mientras volas por el ventarron y un rato despues (los pone
			--  ClimaEspecialServer) no hay dano por caida; el choque ya cobra.
			local windFlight = char:GetAttribute("Ventarron_Volando") or char:GetAttribute("Ventarron_SinCaida")
			if damage > 5 and peak > 20 and not windFlight then
				local SKP_02 = SKP_01.."-"..plr.UserId

				cameraspring:accelerate(Vector3.new(-damage/20, 0, math.random(-damage, damage)/5))
				SwaySpring:accelerate(Vector3.new( math.random(-damage, damage)/5, damage/5,0))

				local hurtSound = PastaFx.FallDamage:Clone()
				hurtSound.Parent = plr.PlayerGui
				hurtSound.Volume = damage/Humanoid.MaxHealth
				hurtSound:Play()
				Debris:AddItem(hurtSound,hurtSound.TimeLength)

				Evt.Damage:InvokeServer(nil, nil, nil, nil, nil, nil, true, damage, SKP_02)

			end
		elseif state == Enum.HumanoidStateType.Landed or state == Enum.HumanoidStateType.Dead then
			falling = false
			SwaySpring:accelerate(Vector3.new(0, 2.5, 0))
		end
	end

end)

mouse.WheelBackward:Connect(function()

	if ToolEquip and not CheckingMag and not aimming and not reloading and not runKeyDown and AnimDebounce and WeaponData.Type == "Gun" then
		mouse1down = false
		if GunStance == 0 then
			SafeMode = true
			GunStance = -1
			UpdateGui()
			Evt.GunStance:FireServer(GunStance, LL_StancePose(GunStance, AnimData))
			LowReady()
		elseif GunStance == -1 then
			SafeMode = true
			GunStance = -2
			UpdateGui()
			Evt.GunStance:FireServer(GunStance, LL_StancePose(GunStance, AnimData))
			Patrol()
		elseif GunStance == 1 then
			SafeMode = false
			GunStance = 0
			UpdateGui()
			Evt.GunStance:FireServer(GunStance, LL_StancePose(GunStance, AnimData))
			IdleAnim()
		end
	end

	if ToolEquip and aimming then
		-- [15/09] ajusta la que se esta usando: apuntar o mira de aumento
		AdjustAimSens(-5)
	end

end)


mouse.WheelForward:Connect(function()

	if ToolEquip and not CheckingMag and not aimming and not reloading and not runKeyDown and AnimDebounce and WeaponData.Type == "Gun" then
		mouse1down = false
		if GunStance == 0 then
			SafeMode = true
			GunStance = 1
			UpdateGui()
			Evt.GunStance:FireServer(GunStance, LL_StancePose(GunStance, AnimData))
			HighReady()
		elseif GunStance == -1 then
			SafeMode = false
			GunStance = 0
			UpdateGui()
			Evt.GunStance:FireServer(GunStance, LL_StancePose(GunStance, AnimData))
			IdleAnim()
		elseif GunStance == -2 then
			SafeMode = true
			GunStance = -1
			UpdateGui()
			Evt.GunStance:FireServer(GunStance, LL_StancePose(GunStance, AnimData))
			LowReady()
		end
	end

	if ToolEquip and aimming then
		-- [15/09] ajusta la que se esta usando: apuntar o mira de aumento
		AdjustAimSens(5)
	end

end)

script.Parent:GetAttributeChangedSignal("Injured"):Connect(function()
	local valor = script.Parent:GetAttribute("Injured")

	if valor and runKeyDown then
		runKeyDown 	= false
		Stand()
		if not CheckingMag and not reloading and WeaponData and WeaponData.Type ~= "Grenade" and (GunStance == 0 or GunStance == 2 or GunStance == 3) then
			GunStance = 0
			Evt.GunStance:FireServer(GunStance, LL_StancePose(GunStance, AnimData))
			IdleAnim()
		end
	end

	if Stances == 0 then
		Stand()
	elseif Stances == 1 then
		Crouch()
	end

end)

----------//Gun System\\----------

----------//Health HUD\\----------
BloodScreen:Play()
BloodScreenLowHP:Play()
Humanoid.HealthChanged:Connect(function(Health)
	SE_GUI.Efeitos.Health.ImageTransparency = math.clamp(((Health - (Humanoid.MaxHealth/2))/(Humanoid.MaxHealth/2)), 0, 1)
	SE_GUI.Efeitos.LowHealth.ImageTransparency = math.clamp((Health /(Humanoid.MaxHealth/2)), 0, 1)
end)
----------//Health HUD\\----------

----------//Render Functions\\----------
Run.RenderStepped:Connect(function(step)
	HeadMovement()
	renderGunRecoil()
	renderCam()

	if ViewModel and LArm and RArm and WeaponInHand then --Check if the weapon and arms are loaded

		local mouseDelta = User:GetMouseDelta()
		SwaySpring:accelerate(Vector3.new(mouseDelta.x/60, mouseDelta.y/60, 0))

		local swayVec = SwaySpring.p
		local TSWAY = swayVec.z
		local XSSWY = swayVec.X
		local YSSWY = swayVec.Y
		local Sway = CFrame.Angles(YSSWY,XSSWY,XSSWY)

		if BipodAtt and UnderBarrelAtt and UnderBarrelAtt:FindFirstChild("Main") then

			local BipodParams = RaycastParams.new()
			BipodParams.FilterDescendantsInstances = Ignore_Model
			BipodParams.FilterType = Enum.RaycastFilterType.Blacklist
			BipodParams.IgnoreWater = true

			local BipodResult = workspace:Raycast(UnderBarrelAtt.Main.Position, Vector3.new(0,-1.75,0), BipodParams)

			if BipodResult then
				CanBipod = true
				if CanBipod and BipodActive and not runKeyDown and (GunStance == 0 or GunStance == 2) then
					SetBipodHUD(Color3.fromRGB(255,255,255), .123)		-- [F-06 bis]
					if not aimming then
						BipodCF = BipodCF:Lerp(CFrame.new(0,(((UnderBarrelAtt.Main.Position - BipodResult.Position).Magnitude)-1) * (-1.5), 0),.2)
					else
						BipodCF = BipodCF:Lerp(CFrame.new(),.2)
					end

				else
					BipodActive = false
					BipodCF = BipodCF:Lerp(CFrame.new(),.2)
					SetBipodHUD(Color3.fromRGB(255,255,0), .5)			-- [F-06 bis]
				end
			else
				BipodActive = false
				CanBipod = false
				BipodCF = BipodCF:Lerp(CFrame.new(),.2)
				SetBipodHUD(Color3.fromRGB(255,0,0), .5)				-- [F-06 bis]
			end

		end

		AnimPart.CFrame = cam.CFrame * NearZ * BipodCF * maincf * gunbobcf * aimcf

		if not AnimData.GunModelFixed then
			WeaponInHand:SetPrimaryPartCFrame(
				ViewModel.PrimaryPart.CFrame
					* guncf
			)
		end

		if running then
			gunbobcf = gunbobcf:Lerp(CFrame.new(
				0.025 * (charspeed/10) * math.sin(tick() * 8),
				0.025 * (charspeed/10) * math.cos(tick() * 16),
				0
				) * CFrame.Angles(
					math.rad( 1 * (charspeed/10) * math.sin(tick() * 16) ),
					math.rad( 1 * (charspeed/10) * math.cos(tick() * 8) ),
					math.rad(0)
				), 0.1)
		else
			gunbobcf = gunbobcf:Lerp(CFrame.new(
				0.005 * math.sin(tick() * 1.5),
				0.005 * math.cos(tick() * 2.5),
				0
				), 0.1)
		end

		if CurAimpart and aimming and AnimDebounce and not CheckingMag then
			if not NVG or WeaponInHand.AimPart:FindFirstChild("NVAim") == nil then
				if AimPartMode == 1 then
					SetFOV(ModTable.ZoomValue); ApplyAimSens()							-- [F-06] [15/09]
					maincf = maincf:Lerp(maincf * CFrame.new(0,0,-.5) * recoilcf * Sway:inverse() * CurAimpart.CFrame:toObjectSpace(cam.CFrame), 0.2)
				else
					SetFOV(ModTable.Zoom2Value); ApplyAimSens()							-- [F-06] [15/09]
					maincf = maincf:Lerp(maincf * CFrame.new(0,0,-.5) * recoilcf * Sway:inverse() * CurAimpart.CFrame:toObjectSpace(cam.CFrame), 0.2)
				end
			else
				SetFOV(70)												-- [F-06]
				maincf = maincf:Lerp(maincf * CFrame.new(0,0,-.5) * recoilcf * Sway:inverse() * (WeaponInHand.AimPart.CFrame * WeaponInHand.AimPart.NVAim.CFrame):toObjectSpace(cam.CFrame), 0.2)
			end

		else
			SetFOV(70)													-- [F-06]
			maincf = maincf:Lerp(AnimData.MainCFrame * recoilcf * Sway:inverse(), 0.2)
		end

		--  [F-07] Antes: for index, Part in pairs(WeaponInHand:GetDescendants())
		--  buscando "SightMark" EN CADA FRAME. Ahora la lista viene cacheada
		--  de setup().
		for _, Part in ipairs(SightMarks) do
			if Part.Parent then
				local dist_scale = Part.CFrame:pointToObjectSpace(cam.CFrame.Position)/Part.Size
				local scopeReticle = Part.SurfaceGui.Border.Scope
				scopeReticle.Position = UDim2.new(.5+dist_scale.x,0,.5-dist_scale.y,0)
			end
		end

		recoilcf = recoilcf:Lerp(CFrame.new() * CFrame.Angles( math.rad(RecoilSpring.p.X), math.rad(RecoilSpring.p.Y), math.rad(RecoilSpring.p.z)), 0.2)


		if WeaponData.CrossHair then
			if aimming then
				CHup = CHup:Lerp(UDim2.new(.5,0,.5,0),0.2)
				CHdown = CHdown:Lerp(UDim2.new(.5,0,.5,0),0.2)
				CHleft = CHleft:Lerp(UDim2.new(.5,0,.5,0),0.2)
				CHright = CHright:Lerp(UDim2.new(.5,0,.5,0),0.2)
			else
				local Normalized = ((WeaponData.CrosshairOffset + (BSpread + (charspeed * WeaponData.WalkMult * ModTable.WalkMult)) * LL_StanceAimMult() ) / 50)/10	-- [23/09] la mira se cierra agachado

				CHup = CHup:Lerp(UDim2.new(0.5, 0, 0.5 - Normalized,0),0.5)
				CHdown = CHdown:Lerp(UDim2.new(.5, 0, 0.5 + Normalized,0),0.5)
				CHleft = CHleft:Lerp(UDim2.new(.5 - Normalized, 0, 0.5, 0),0.5)
				CHright = CHright:Lerp(UDim2.new(.5 + Normalized, 0, 0.5, 0),0.5)
			end

			Crosshair.Position = UDim2.new(0,mouse.X,0,mouse.Y)

			Crosshair.Up.Position = CHup
			Crosshair.Down.Position = CHdown
			Crosshair.Left.Position = CHleft
			Crosshair.Right.Position = CHright

		else

			CHup = CHup:Lerp(UDim2.new(.5,0,.5,0),0.2)
			CHdown = CHdown:Lerp(UDim2.new(.5,0,.5,0),0.2)
			CHleft = CHleft:Lerp(UDim2.new(.5,0,.5,0),0.2)
			CHright = CHright:Lerp(UDim2.new(.5,0,.5,0),0.2)

			Crosshair.Position = UDim2.new(0,mouse.X,0,mouse.Y)

			Crosshair.Up.Position = CHup
			Crosshair.Down.Position = CHdown
			Crosshair.Left.Position = CHleft
			Crosshair.Right.Position = CHright

		end

		if BSpread then
			local currTime = time()
			if currTime - LastSpreadUpdate > (60/WeaponData.ShootRate) * 2 and not shooting and BSpread > WeaponData.MinSpread * ModTable.MinSpread then
				BSpread = math.max(WeaponData.MinSpread * ModTable.MinSpread, BSpread - WeaponData.AimInaccuracyDecrease * ModTable.AimInaccuracyDecrease)
			end
			if currTime - LastSpreadUpdate > (60/WeaponData.ShootRate) * 1.5 and not shooting and RecoilPower > WeaponData.MinRecoilPower * ModTable.MinRecoilPower then
				RecoilPower =  math.max(WeaponData.MinRecoilPower * ModTable.MinRecoilPower, RecoilPower - WeaponData.RecoilPowerStepAmount * ModTable.RecoilPowerStepAmount)
			end
		end

		if LaserActive and Pointer ~= nil then

			if NVG then
				Pointer.Transparency = 0
				Pointer.Beam.Enabled = true
			else
				if not gameRules.RealisticLaser then
					Pointer.Beam.Enabled = true
				else
					Pointer.Beam.Enabled = false
				end
				if IRmode then
					Pointer.Transparency = 1
				else
					Pointer.Transparency = 0
				end
			end

			--  [F-07] Antes: otro GetDescendants() completo por frame
			--  buscando "LaserPoint". Ahora sale de la cache.
			local Key = LaserPoints[1]
			if Key and Key.Parent then
				local LaserParams = RaycastParams.new()
				LaserParams.FilterDescendantsInstances = Ignore_Model
				LaserParams.FilterType = Enum.RaycastFilterType.Blacklist
				LaserParams.IgnoreWater = true

				local LaserResult = workspace:Raycast(Key.CFrame.Position, Key.CFrame.LookVector * 1000, LaserParams)

				if LaserResult then
					Pointer.CFrame = CFrame.new(LaserResult.Position, LaserResult.Position + LaserResult.Normal)
				else
					Pointer.CFrame = CFrame.new(cam.CFrame.Position + Key.CFrame.LookVector * 2000, Key.CFrame.LookVector)
				end

				--  [LASER 23/09/2026] Antes solo se mandaba cuando pegaba en algo
				--  (al apuntar al cielo el punto de los demas se quedaba congelado)
				--  y 30 veces por segundo. Ahora: siempre, max 15/s, y si no se
				--  mueve solo un "sigo prendido" cada 0.4 s.
				if gameRules.ReplicatedLaser then
					local sendPos = LaserResult and LaserResult.Position or (Key.CFrame.Position + Key.CFrame.LookVector * 1000)
					local nowT  = os.clock()
					local lastT = Pointer:GetAttribute("LL_SendT") or 0
					local lastP = Pointer:GetAttribute("LL_SendP")
					local changed = (not lastP) or (lastP - sendPos).Magnitude > 0.05 or Pointer:GetAttribute("LL_SendIR") ~= IRmode
					if nowT - lastT >= 1/15 and (changed or nowT - lastT >= 0.4) then
						Pointer:SetAttribute("LL_SendT", nowT)
						Pointer:SetAttribute("LL_SendP", sendPos)
						Pointer:SetAttribute("LL_SendIR", IRmode)
						Evt.SVLaser:FireServer(sendPos,1,Pointer.Color,IRmode,WeaponTool)
					end
				end
			end
		end
	end
end)
----------//Render Functions\\----------

----------//Events\\----------
--==========================================================================
--  [F-02] Aqui adentro vivia un
--     game:GetService("UserInputService").InputBegan:Connect(...)
--  que imprimia el backpack entero al presionar P. Como estaba DENTRO del
--  handler, se creaba una conexion nueva en CADA recarga de municion y
--  nunca se desconectaba: tras 40 recargas habia 40 conexiones vivas,
--  cada una reteniendo el estado del momento.
--  Si necesitas ese debug, ponelo UNA sola vez fuera de todo Connect.
--==========================================================================
Evt.Refil.OnClientEvent:Connect(function(Tool, Infinite, Stored)

	local data = require(Tool.ACS_Settings)
	local NewStored = math.min(data.MaxStoredAmmo - StoredAmmo, Stored.Value)

	StoredAmmo = StoredAmmo + NewStored
	data.StoredAmmo = StoredAmmo

	UpdateGui()

	if not Infinite then
		Evt.Refil:FireServer(Stored, NewStored)
	end
end)
----------//Events\\----------

dprint("[ACS Framework] Parches de rendimiento 01/09/2026 cargados")