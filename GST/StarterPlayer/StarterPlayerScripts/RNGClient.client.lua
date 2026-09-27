--==========================================================================
--  RNGClient  -  LocalScript (StarterPlayer > StarterPlayerScripts)
--  [27/09/2026]
--
--  Modo RNG: mientras estas en la ronda sale a la derecha de la pantalla
--  "Presiona G para cambiar" y las armas que tienes. La G (o el boton en
--  celular / Y en control) le pide al servidor (RoundManager) un arma al
--  azar de GunStorage. El servidor decide todo: aqui solo se pide y se
--  muestra.
--==========================================================================

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local roundSystem = ReplicatedStorage:WaitForChild("RoundSystem")
local state = roundSystem:WaitForChild("State")
local phaseValue = state:WaitForChild("Phase")
local rollEvent = roundSystem:WaitForChild("RNGRoll")

local ACTION = "RNGCambiarArma"
local KEY = Enum.KeyCode.G

--  Texto de la derecha
local gui = Instance.new("ScreenGui")
gui.Name = "RNGHud"
gui.ResetOnSpawn = false
gui.DisplayOrder = 5
gui.Enabled = false

local box = Instance.new("Frame")
box.Name = "Caja"
box.AnchorPoint = Vector2.new(1, 0.5)
box.Position = UDim2.new(1, -16, 0.5, 0)
box.Size = UDim2.fromOffset(230, 84)
box.BackgroundColor3 = Color3.new(0, 0, 0)
box.BackgroundTransparency = 0.55
box.Parent = gui
local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 6)
corner.Parent = box

local hint = Instance.new("TextLabel")
hint.Name = "Aviso"
hint.BackgroundTransparency = 1
hint.Position = UDim2.fromOffset(10, 6)
hint.Size = UDim2.new(1, -20, 0, 20)
hint.Font = Enum.Font.GothamBold
hint.TextSize = 15
hint.TextColor3 = Color3.fromRGB(255, 220, 90)
hint.TextXAlignment = Enum.TextXAlignment.Right
hint.Text = "Presiona G para cambiar"
hint.Parent = box

local list = Instance.new("TextLabel")
list.Name = "Armas"
list.BackgroundTransparency = 1
list.Position = UDim2.fromOffset(10, 28)
list.Size = UDim2.new(1, -20, 0, 50)
list.Font = Enum.Font.Gotham
list.TextSize = 14
list.TextColor3 = Color3.new(1, 1, 1)
list.TextXAlignment = Enum.TextXAlignment.Right
list.TextYAlignment = Enum.TextYAlignment.Top
list.RichText = true
list.Text = ""
list.Parent = box

gui.Parent = player:WaitForChild("PlayerGui")

local function isRNG()
	return state:GetAttribute("ActiveGamemode") == "RNG"
		and phaseValue.Value == "Round"
		and player:GetAttribute("InRound") == true
end

local function roll(_, inputState)
	if inputState ~= Enum.UserInputState.Begin then return Enum.ContextActionResult.Pass end
	if not isRNG() then return Enum.ContextActionResult.Pass end
	rollEvent:FireServer()
	return Enum.ContextActionResult.Sink
end

local bound = false
local function refresh()
	local active = isRNG()
	gui.Enabled = active
	if active and not bound then
		bound = true
		ContextActionService:BindAction(ACTION, roll, true, KEY, Enum.KeyCode.ButtonY)
		ContextActionService:SetTitle(ACTION, "G")
		ContextActionService:SetPosition(ACTION, UDim2.new(1, -150, 0.5, -30))
	elseif not active and bound then
		bound = false
		ContextActionService:UnbindAction(ACTION)
	end
end

local function refreshList()
	local text = player:GetAttribute("RNGWeapons")
	local names = {}
	if type(text) == "string" and text ~= "" then
		for name in string.gmatch(text, "[^|]+") do table.insert(names, name) end
	end
	if #names == 0 then
		list.Text = '<font color="#AAAAAA">Sin armas: presiona G</font>'
	else
		local lines = {}
		for index, name in ipairs(names) do
			table.insert(lines, index .. ". " .. name)
		end
		list.Text = table.concat(lines, "\n")
	end
end

state:GetAttributeChangedSignal("ActiveGamemode"):Connect(refresh)
phaseValue.Changed:Connect(refresh)
player:GetAttributeChangedSignal("InRound"):Connect(refresh)
player:GetAttributeChangedSignal("RNGWeapons"):Connect(refreshList)
refresh()
refreshList()

--  Espera entre tiradas: el aviso se apaga un momento.
RunService.Heartbeat:Connect(function()
	if not gui.Enabled then return end
	local nextAt = player:GetAttribute("RNGNextAt")
	local wait = type(nextAt) == "number" and (nextAt - Workspace:GetServerTimeNow()) or 0
	if wait > 0 then
		hint.Text = string.format("Espera %.1f s", wait)
		hint.TextColor3 = Color3.fromRGB(170, 170, 170)
	else
		hint.Text = "Presiona G para cambiar"
		hint.TextColor3 = Color3.fromRGB(255, 220, 90)
	end
end)
