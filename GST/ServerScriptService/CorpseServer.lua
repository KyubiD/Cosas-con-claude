--[[
	CorpseServer  (24/09/2026)

	En los modos con Corpses = true en GamemodeConfig (Eliminacion y
	Ejecucion) el que muere -jugador o bot- deja su cuerpo en el mapa.

	Al morir, ACS arma el ragdoll (modulo Ragdoll). Aqui se hace una COPIA
	de ese ragdoll (el cuerpo original lo borra el juego al reaparecer / el
	bot a los pocos segundos) y se deja en workspace.Cuerpos:
	  · cae con fisica unos segundos y despues se queda fijo y sin colision
	    (no estorba el paso ni el pathfinding de los bots);
	  · las balas lo atraviesan (CanQuery = false): un cuerpo no es escudo;
	  · sin scripts, herramientas, sonidos, luces ni nombres flotantes.
	Se borran todos en cuanto la fase deja de ser "Round" (fin de la
	partida). Tope de MAX_CORPSES por si acaso.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GamemodeConfig = require(ReplicatedStorage:WaitForChild("GamemodeConfig"))
local roundSystem = ReplicatedStorage:WaitForChild("RoundSystem")
local state = roundSystem:WaitForChild("State")
local phaseValue = state:WaitForChild("Phase")

local RAGDOLL_WAIT = 0.3	-- s para que el ragdoll de ACS termine de armarse
local SETTLE_TIME = 5		-- s de fisica antes de dejarlo fijo
local MAX_CORPSES = 40

local REMOVE_CLASSES = {
	"LuaSourceContainer", "Tool", "BillboardGui", "SurfaceGui", "Sound",
	"ForceField", "Highlight", "ProximityPrompt", "Light", "ParticleEmitter",
	"Beam", "Trail", "AlignOrientation", "AlignPosition", "LinearVelocity",
	"AngularVelocity", "VectorForce", "BodyMover", "ValueBase", "Animator",
}

local folder = nil
local function corpsesFolder()
	if folder and folder.Parent then return folder end
	folder = Workspace:FindFirstChild("Cuerpos")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Cuerpos"
		folder.Parent = Workspace
	end
	return folder
end

local function corpsesActive()
	if phaseValue.Value ~= "Round" then return false end
	local mode = state:GetAttribute("ActiveGamemode")
	local rules = mode and GamemodeConfig.Modes and GamemodeConfig.Modes[mode]
	return rules ~= nil and rules.Corpses == true
end

local function strip(copy)
	--  Carpetas del cliente de ACS (sin sus scripts ya no hacen nada).
	for _, instance in ipairs(copy:GetDescendants()) do
		if instance.Parent and instance.Name == "ACS_Client" then instance:Destroy() end
	end
	for _, instance in ipairs(copy:GetDescendants()) do
		if instance.Parent then
			for _, className in ipairs(REMOVE_CLASSES) do
				if instance:IsA(className) then
					instance:Destroy()
					break
				end
			end
		end
	end
end

--  El cuerpo original queda invisible hasta que el juego lo borre.
local function hide(character)
	for _, instance in ipairs(character:GetDescendants()) do
		if instance:IsA("BasePart") then
			instance.Transparency = 1
			instance.CanCollide = false
			instance.CanQuery = false
		elseif instance:IsA("Decal") or instance:IsA("Texture") then
			instance.Transparency = 1
		end
	end
end

local function makeCorpse(character)
	if not character.Parent then return end
	local wasArchivable = character.Archivable
	character.Archivable = true
	local ok, copy = pcall(function() return character:Clone() end)
	character.Archivable = wasArchivable
	if not ok or not copy then return end

	strip(copy)
	copy.Name = "Cuerpo_" .. character.Name
	copy:SetAttribute("Cuerpo", true)
	local humanoid = copy:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.BreakJointsOnDeath = false
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	end
	for _, instance in ipairs(copy:GetDescendants()) do
		if instance:IsA("BasePart") then
			instance.Anchored = false
			instance.CanQuery = false
			instance.CanTouch = false
		end
	end
	local root = copy:FindFirstChild("HumanoidRootPart")
	if root then root.CanCollide = false end

	hide(character)

	local target = corpsesFolder()
	local existing = target:GetChildren()
	if #existing >= MAX_CORPSES then existing[1]:Destroy() end
	copy.Parent = target
	for _, instance in ipairs(copy:GetDescendants()) do
		if instance:IsA("BasePart") then
			pcall(function() instance:SetNetworkOwner(nil) end)
		end
	end

	task.delay(SETTLE_TIME, function()
		if not copy.Parent then return end
		for _, instance in ipairs(copy:GetDescendants()) do
			if instance:IsA("BasePart") then
				instance.Anchored = true
				instance.CanCollide = false
			end
		end
	end)
end

local watched = setmetatable({}, { __mode = "k" })
local function watch(character)
	if watched[character] then return end
	watched[character] = true
	local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 10)
	if not humanoid then return end
	humanoid.Died:Connect(function()
		if not corpsesActive() then return end
		task.wait(RAGDOLL_WAIT)
		makeCorpse(character)
	end)
end

--  Jugadores.
local function onPlayer(player)
	player.CharacterAdded:Connect(watch)
	if player.Character then task.spawn(watch, player.Character) end
end
Players.PlayerAdded:Connect(onPlayer)
for _, player in ipairs(Players:GetPlayers()) do onPlayer(player) end

--  Bots: sus cuerpos se crean directo en el workspace; BotRegistry
--  (_G.LL_Bots) dice si un modelo es el cuerpo de un bot.
Workspace.ChildAdded:Connect(function(child)
	if not child:IsA("Model") or Players:GetPlayerFromCharacter(child) then return end
	task.delay(1, function()
		local bots = _G.LL_Bots
		if child.Parent and bots and bots.fromInstance and bots.fromInstance(child) then
			watch(child)
		end
	end)
end)

--  Fin de la partida: se limpian.
phaseValue.Changed:Connect(function(phase)
	if phase ~= "Round" and folder and folder.Parent then
		folder:ClearAllChildren()
	end
end)
