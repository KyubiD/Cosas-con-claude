local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local holder = script.Parent

local function findRemote(className)
	for _ = 1, 100 do
		local found = holder:FindFirstChildOfClass(className)
		if found then
			return found
		end
		task.wait(0.1)
	end
	return nil
end

local query = findRemote("RemoteFunction")
local channel = findRemote("RemoteEvent")
if not query or not channel then
	return
end

local token
for _ = 1, 5 do
	local ok, result = pcall(function()
		return query:InvokeServer()
	end)
	if ok and type(result) == "string" then
		token = result
		break
	end
	task.wait(2)
end
if not token then
	return
end

local function send(op, payload)
	channel:FireServer(token, op, payload)
end

local ShopConfig = require(ReplicatedStorage:WaitForChild("ShopConfig"))
local gunStorage = ReplicatedStorage:WaitForChild("GunStorage")
local AttachmentRegistry = nil
pcall(function()
	AttachmentRegistry = require(ReplicatedStorage:WaitForChild("AttachmentRegistry", 10))
end)

local ACCENT = Color3.fromRGB(150, 30, 30)
local ACCENT_SELECTED = Color3.fromRGB(120, 30, 30)
local BASE_BUTTON = Color3.fromRGB(35, 38, 45)
local LIST_BUTTON = Color3.fromRGB(30, 32, 38)
local FIELD = Color3.fromRGB(22, 24, 29)
local RESET_CONFIRM_WINDOW = 3

local selectedScope = "player"
local selectedRewardType = "Peces"
local selectedCrateName = ShopConfig.Crates[1] and ShopConfig.Crates[1].Name or nil
local selectedWeaponName = nil
local selectedWeaponAction = "grant"
local selectedAttachmentName = nil
local resetArmedUntil = 0
local botChoice = {}
local botOptions = {}
local botMax = nil

local function setFeedback(label, text, ok)
	label.Text = text
	label.TextColor3 = ok and Color3.fromRGB(120, 230, 140) or Color3.fromRGB(240, 90, 90)
end

local gui = Instance.new("ScreenGui")
gui.Name = (HttpService:GenerateGUID(false):gsub("-", "")):sub(1, 10)
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 500
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

gui:GetPropertyChangedSignal("Enabled"):Connect(function()
	if not gui.Enabled then
		task.defer(function()
			if gui.Parent then
				gui.Enabled = true
			end
		end)
	end
end)

local main = Instance.new("Frame")
main.Name = "Main"
main.AnchorPoint = Vector2.new(0.5, 0.5)
main.Position = UDim2.fromScale(0.5, 0.5)
main.Size = UDim2.fromScale(0.92, 0.9)
main.BackgroundColor3 = Color3.fromRGB(14, 15, 19)
main.BorderSizePixel = 0
main.Active = true
main.Visible = false
main.Parent = gui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)
local mainStroke = Instance.new("UIStroke", main)
mainStroke.Color = ACCENT
mainStroke.Thickness = 2
local mainLimits = Instance.new("UISizeConstraint", main)
mainLimits.MaxSize = Vector2.new(460, 640)
mainLimits.MinSize = Vector2.new(240, 220)

local function togglePanel(force)
	if force ~= nil then
		main.Visible = force
	else
		main.Visible = not main.Visible
	end
end

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -64, 0, 36)
title.Position = UDim2.fromOffset(14, 10)
title.BackgroundTransparency = 1
title.Text = "ADMIN // " .. player.Name
title.Font = Enum.Font.GothamBlack
title.TextColor3 = Color3.fromRGB(220, 60, 60)
title.TextScaled = true
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = main

local closeButton = Instance.new("TextButton")
closeButton.Size = UDim2.fromOffset(36, 36)
closeButton.Position = UDim2.new(1, -46, 0, 10)
closeButton.BackgroundColor3 = Color3.fromRGB(60, 20, 20)
closeButton.Text = "X"
closeButton.TextColor3 = Color3.new(1, 1, 1)
closeButton.Font = Enum.Font.GothamBold
closeButton.TextScaled = true
closeButton.Parent = main
Instance.new("UICorner", closeButton).CornerRadius = UDim.new(0, 6)
closeButton.Activated:Connect(function()
	togglePanel(false)
end)

local body = Instance.new("ScrollingFrame")
body.Name = "Body"
body.Position = UDim2.fromOffset(14, 56)
body.Size = UDim2.new(1, -28, 1, -68)
body.BackgroundTransparency = 1
body.BorderSizePixel = 0
body.ScrollBarThickness = 5
body.CanvasSize = UDim2.new(0, 0, 0, 0)
body.AutomaticCanvasSize = Enum.AutomaticSize.Y
body.ScrollingDirection = Enum.ScrollingDirection.Y
body.Parent = main
local bodyLayout = Instance.new("UIListLayout", body)
bodyLayout.Padding = UDim.new(0, 10)
bodyLayout.SortOrder = Enum.SortOrder.LayoutOrder
local bodyPadding = Instance.new("UIPadding", body)
bodyPadding.PaddingRight = UDim.new(0, 8)
bodyPadding.PaddingBottom = UDim.new(0, 10)

local function sectionLabel(text, order)
	local label = Instance.new("TextLabel")
	label.LayoutOrder = order
	label.Size = UDim2.new(1, 0, 0, 20)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = Color3.fromRGB(200, 200, 205)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = body
	return label
end

local function makeRow(order, height, padding)
	local row = Instance.new("Frame")
	row.LayoutOrder = order
	row.Size = UDim2.new(1, 0, 0, height)
	row.BackgroundTransparency = 1
	row.Parent = body
	local rowLayout = Instance.new("UIListLayout", row)
	rowLayout.FillDirection = Enum.FillDirection.Horizontal
	rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rowLayout.Padding = UDim.new(0, padding)
	return row
end

local function makeButton(parent, text, order, widthScale)
	local button = Instance.new("TextButton")
	button.LayoutOrder = order
	button.Size = UDim2.fromScale(widthScale, 1)
	button.BackgroundColor3 = BASE_BUTTON
	button.Text = text
	button.TextColor3 = Color3.fromRGB(230, 230, 230)
	button.Font = Enum.Font.GothamSemibold
	button.TextScaled = true
	button.Parent = parent
	Instance.new("UICorner", button).CornerRadius = UDim.new(0, 6)
	return button
end

local function makeInfoLabel(order, text)
	local label = Instance.new("TextLabel")
	label.LayoutOrder = order
	label.Size = UDim2.new(1, 0, 0, 22)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = Color3.fromRGB(170, 170, 178)
	label.Font = Enum.Font.Gotham
	label.TextScaled = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = body
	return label
end

local function makeTextBox(order, height, text, placeholder)
	local box = Instance.new("TextBox")
	box.LayoutOrder = order
	box.Size = UDim2.new(1, 0, 0, height)
	box.BackgroundColor3 = FIELD
	box.Text = text
	box.PlaceholderText = placeholder
	box.TextColor3 = Color3.fromRGB(230, 230, 230)
	box.Font = Enum.Font.Gotham
	box.TextScaled = true
	box.ClearTextOnFocus = false
	box.Parent = body
	Instance.new("UICorner", box).CornerRadius = UDim.new(0, 6)
	return box
end

local function makeList(order, height)
	local list = Instance.new("ScrollingFrame")
	list.LayoutOrder = order
	list.Size = UDim2.new(1, 0, 0, height)
	list.BackgroundColor3 = FIELD
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 4
	list.CanvasSize = UDim2.new(0, 0, 0, 0)
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.Visible = false
	list.Parent = body
	Instance.new("UICorner", list).CornerRadius = UDim.new(0, 6)
	local listLayout = Instance.new("UIListLayout", list)
	listLayout.Padding = UDim.new(0, 4)
	local listPadding = Instance.new("UIPadding", list)
	listPadding.PaddingTop = UDim.new(0, 4)
	listPadding.PaddingLeft = UDim.new(0, 4)
	listPadding.PaddingRight = UDim.new(0, 4)
	return list
end

local function makeListButton(parent, text)
	local button = Instance.new("TextButton")
	button.Size = UDim2.new(1, -8, 0, 30)
	button.BackgroundColor3 = LIST_BUTTON
	button.Text = text
	button.TextColor3 = Color3.fromRGB(225, 225, 225)
	button.Font = Enum.Font.GothamSemibold
	button.TextScaled = true
	button.Parent = parent
	Instance.new("UICorner", button).CornerRadius = UDim.new(0, 5)
	return button
end

local BOT_FIELDS = {
	{ key = "aim", title = "PUNTERÍA" },
	{ key = "reaction", title = "REACCIÓN" },
	{ key = "role", title = "TIPO DE IA" },
	{ key = "primary", title = "ARMA PRINCIPAL" },
}
local botValueLabels = {}

local function refreshBotChoices()
	for _, field in ipairs(BOT_FIELDS) do
		local label = botValueLabels[field.key]
		local value = botChoice[field.key]
		if label then
			label.Text = value and string.upper(value) or "ALEATORIO"
			label.TextColor3 = value and Color3.fromRGB(240, 240, 245) or Color3.fromRGB(140, 140, 150)
		end
	end
end

local function stepBotChoice(key, direction)
	local list = botOptions[key] or {}
	if #list == 0 then
		return
	end
	local index = 0
	for i, value in ipairs(list) do
		if value == botChoice[key] then
			index = i
		end
	end
	index = (index + direction) % (#list + 1)
	botChoice[key] = index > 0 and list[index] or nil
	refreshBotChoices()
end

sectionLabel("BOTS (JUGADORES FALSOS)", -30)
for i, field in ipairs(BOT_FIELDS) do
	local row = makeRow(-30 + i, 30, 4)
	local caption = Instance.new("TextLabel")
	caption.LayoutOrder = 1
	caption.Size = UDim2.fromScale(0.34, 1)
	caption.BackgroundTransparency = 1
	caption.Text = field.title
	caption.TextColor3 = Color3.fromRGB(170, 170, 178)
	caption.Font = Enum.Font.GothamBold
	caption.TextScaled = true
	caption.TextXAlignment = Enum.TextXAlignment.Left
	caption.Parent = row
	local previousButton = makeButton(row, "<", 2, 0.11)
	local value = Instance.new("TextLabel")
	value.LayoutOrder = 3
	value.Size = UDim2.fromScale(0.38, 1)
	value.BackgroundColor3 = FIELD
	value.Text = "ALEATORIO"
	value.TextColor3 = Color3.fromRGB(140, 140, 150)
	value.Font = Enum.Font.GothamSemibold
	value.TextScaled = true
	value.Parent = row
	Instance.new("UICorner", value).CornerRadius = UDim.new(0, 6)
	local nextButton = makeButton(row, ">", 4, 0.11)
	botValueLabels[field.key] = value
	previousButton.Activated:Connect(function()
		stepBotChoice(field.key, -1)
	end)
	nextButton.Activated:Connect(function()
		stepBotChoice(field.key, 1)
	end)
end

local botInputRow = makeRow(-25, 32, 6)
local botNameBox = Instance.new("TextBox")
botNameBox.LayoutOrder = 1
botNameBox.Size = UDim2.fromScale(0.64, 1)
botNameBox.BackgroundColor3 = FIELD
botNameBox.Text = ""
botNameBox.PlaceholderText = "Nombre (vacío = al azar)"
botNameBox.TextColor3 = Color3.fromRGB(230, 230, 230)
botNameBox.Font = Enum.Font.Gotham
botNameBox.TextScaled = true
botNameBox.ClearTextOnFocus = false
botNameBox.Parent = botInputRow
Instance.new("UICorner", botNameBox).CornerRadius = UDim.new(0, 6)
local botCountBox = Instance.new("TextBox")
botCountBox.LayoutOrder = 2
botCountBox.Size = UDim2.fromScale(0.32, 1)
botCountBox.BackgroundColor3 = FIELD
botCountBox.Text = "1"
botCountBox.PlaceholderText = "Cantidad"
botCountBox.TextColor3 = Color3.fromRGB(230, 230, 230)
botCountBox.Font = Enum.Font.Gotham
botCountBox.TextScaled = true
botCountBox.ClearTextOnFocus = false
botCountBox.Parent = botInputRow
Instance.new("UICorner", botCountBox).CornerRadius = UDim.new(0, 6)

local botRow = makeRow(-24, 38, 6)
local addBotButton = makeButton(botRow, "+ AGREGAR", 1, 0.33)
addBotButton.BackgroundColor3 = ACCENT
local randomBotButton = makeButton(botRow, "AZAR", 2, 0.16)
local removeBotButton = makeButton(botRow, "QUITAR 1", 3, 0.2)
local clearBotsButton = makeButton(botRow, "QUITAR TODOS", 4, 0.25)
clearBotsButton.BackgroundColor3 = Color3.fromRGB(70, 25, 25)
local botStatus = makeInfoLabel(-23, "Bots en el servidor: 0")
local botFeedback = makeInfoLabel(-22, "")

local refreshBotCount = function() end
task.spawn(function()
	local fakePlayers = ReplicatedStorage:WaitForChild("FakePlayers", 30)
	if not fakePlayers then
		return
	end
	refreshBotCount = function()
		botStatus.Text = "Bots en el servidor: " .. #fakePlayers:GetChildren() .. (botMax and (" / " .. botMax) or "")
	end
	fakePlayers.ChildAdded:Connect(refreshBotCount)
	fakePlayers.ChildRemoved:Connect(refreshBotCount)
	refreshBotCount()
end)

addBotButton.Activated:Connect(function()
	local options = {}
	for _, field in ipairs(BOT_FIELDS) do
		options[field.key] = botChoice[field.key]
	end
	local name = (botNameBox.Text:gsub("^%s+", ""):gsub("%s+$", ""))
	if name ~= "" then
		options.name = name
	end
	local count = math.clamp(math.floor(tonumber(botCountBox.Text) or 1), 1, 10)
	send("bot", { action = "add", options = options, count = count })
	setFeedback(botFeedback, count > 1 and ("Agregando " .. count .. " bots...") or "Agregando bot...", true)
end)
randomBotButton.Activated:Connect(function()
	table.clear(botChoice)
	botNameBox.Text = ""
	botCountBox.Text = "1"
	refreshBotChoices()
	setFeedback(botFeedback, "Todo al azar", true)
end)

local function cyclerRow(order, title)
	local row = makeRow(order, 30, 4)
	local caption = Instance.new("TextLabel")
	caption.LayoutOrder = 1
	caption.Size = UDim2.fromScale(0.34, 1)
	caption.BackgroundTransparency = 1
	caption.Text = title
	caption.TextColor3 = Color3.fromRGB(170, 170, 178)
	caption.Font = Enum.Font.GothamBold
	caption.TextScaled = true
	caption.TextXAlignment = Enum.TextXAlignment.Left
	caption.Parent = row
	local previousButton = makeButton(row, "<", 2, 0.11)
	local value = Instance.new("TextLabel")
	value.LayoutOrder = 3
	value.Size = UDim2.fromScale(0.38, 1)
	value.BackgroundColor3 = FIELD
	value.TextColor3 = Color3.fromRGB(240, 240, 245)
	value.Font = Enum.Font.GothamSemibold
	value.TextScaled = true
	value.Parent = row
	Instance.new("UICorner", value).CornerRadius = UDim.new(0, 6)
	local nextButton = makeButton(row, ">", 4, 0.11)
	return row, previousButton, value, nextButton
end

local Match = {
	fields = {
		{ key = "map", title = "MAPA" },
		{ key = "mode", title = "EQUIPOS" },
		{ key = "gamemode", title = "MODO DE JUEGO" },
	},
	choice = {},
	lists = { map = {}, mode = {}, gamemode = {} },
	values = {},
	bases = { { id = "Dia", label = "DÍA" }, { id = "Atardecer", label = "ATARDECER" }, { id = "Noche", label = "NOCHE" } },
	skies = { { id = "Despejado", label = "DESPEJADO" }, { id = "Nublado", label = "NUBLADO" }, { id = "Lluvia", label = "LLUVIA" }, { id = "Tormenta", label = "TORMENTA" } },
	specials = {
		{ id = "Ventisca", label = "VENTISCA" }, { id = "Huracan", label = "HURACÁN" }, { id = "Inundacion", label = "INUNDACIÓN" },
		{ id = "LluviaAcida", label = "LLUVIA ÁCIDA" }, { id = "Ventarron", label = "VENTARRÓN" },
		{ id = "Volcan", label = "VOLCÁN" }, { id = "OlaDeCalor", label = "OLA DE CALOR" },
	},
	climate = { custom = false, base = 1, sky = 1, fog = false, specials = {} },
	climateRows = {},
	specialButtons = {},
	phases = { Lobby = "LOBBY", Voting = "VOTACIÓN", Ready = "EN PARTIDA", Round = "EN PARTIDA" },
}
pcall(function()
	Match.ambience = require(ReplicatedStorage:WaitForChild("AmbienceConfig", 10))
end)

function Match.labelIn(key, id)
	for _, item in ipairs(Match.lists[key]) do
		if item.id == id then
			return item.label
		end
	end
	return id
end

function Match.refreshChoices()
	for _, field in ipairs(Match.fields) do
		local label = Match.values[field.key]
		local id = Match.choice[field.key]
		label.Text = id and string.upper(tostring(Match.labelIn(field.key, id))) or "VOTACIÓN"
		label.TextColor3 = id and Color3.fromRGB(240, 240, 245) or Color3.fromRGB(140, 140, 150)
	end
end

function Match.step(key, direction)
	local list = Match.lists[key]
	if #list == 0 then
		return
	end
	local index = 0
	for i, item in ipairs(list) do
		if item.id == Match.choice[key] then
			index = i
		end
	end
	index = (index + direction) % (#list + 1)
	Match.choice[key] = index > 0 and list[index].id or nil
	Match.refreshChoices()
end

function Match.climateKey()
	local config = Match.ambience
	if not (config and config.Presets) then
		return nil, false
	end
	local climate = Match.climate
	local wanted = {}
	for id, on in pairs(climate.specials) do
		if on then
			table.insert(wanted, id)
		end
	end
	table.sort(wanted)
	local wantedId = table.concat(wanted, "+")
	local base = Match.bases[climate.base].id
	local sky = Match.skies[climate.sky].id
	--  [30/09] Tambien la hora puede quedar fijada por un especial (la Ola
	--  de calor solo es de dia): se busca la mas parecida, primero la hora y
	--  despues el cielo.
	local best, bestScore = nil, -1
	for key, preset in pairs(config.Presets) do
		if (preset.Fog ~= nil) == climate.fog then
			local names = table.clone(preset.Specials or {})
			table.sort(names)
			if table.concat(names, "+") == wantedId then
				local score = (preset.Base == base and 2 or 0) + (preset.Sky == sky and 1 or 0)
				if score > bestScore or (score == bestScore and key < best) then
					best, bestScore = key, score
				end
			end
		end
	end
	return best, bestScore == 3
end

function Match.describe(forced)
	if type(forced) ~= "table" then
		return "nada"
	end
	local parts = {}
	if forced.map then
		table.insert(parts, Match.labelIn("map", forced.map))
	end
	if forced.mode then
		table.insert(parts, forced.mode)
	end
	if forced.gamemode then
		table.insert(parts, Match.labelIn("gamemode", forced.gamemode))
	end
	if forced.ambience then
		table.insert(parts, Match.ambience and Match.ambience.labelFor(forced.ambience) or forced.ambience)
	end
	return #parts > 0 and table.concat(parts, " / ") or "nada"
end

sectionLabel("PARTIDA (ANTES DE EMPEZAR)", -20)
Match.status = makeInfoLabel(-19, "Fase: ...")
Match.status.Size = UDim2.new(1, 0, 0, 40)
Match.status.TextWrapped = true
for i, field in ipairs(Match.fields) do
	local _, previousButton, value, nextButton = cyclerRow(-19 + i, field.title)
	Match.values[field.key] = value
	previousButton.Activated:Connect(function()
		Match.step(field.key, -1)
	end)
	nextButton.Activated:Connect(function()
		Match.step(field.key, 1)
	end)
end
Match.refreshChoices()

local climateToggleRow = makeRow(-15, 32, 6)
Match.climateToggle = makeButton(climateToggleRow, "CLIMA: LO DECIDE LA VOTACIÓN", 1, 0.98)

local baseRow, basePrevious, baseValue, baseNext = cyclerRow(-14, "HORA")
local skyRow, skyPrevious, skyValue, skyNext = cyclerRow(-13, "CIELO")
local fogRow = makeRow(-12, 30, 6)
Match.fogButton = makeButton(fogRow, "NIEBLA: NO", 1, 0.98)
local specialRowA = makeRow(-11, 30, 6)
local specialRowB = makeRow(-10, 30, 6)
--  [30/09] 7 especiales: 4 arriba y 3 abajo.
for i, special in ipairs(Match.specials) do
	local row = i <= 4 and specialRowA or specialRowB
	local button = makeButton(row, special.label, i, i <= 4 and 0.235 or 0.315)
	Match.specialButtons[special.id] = button
end
Match.climateResult = makeInfoLabel(-9, "")
Match.climateRows = { baseRow, skyRow, fogRow, specialRowA, specialRowB, Match.climateResult }

function Match.refreshClimate()
	local climate = Match.climate
	Match.climateToggle.Text = climate.custom and "CLIMA: PERSONALIZADO" or "CLIMA: LO DECIDE LA VOTACIÓN"
	Match.climateToggle.BackgroundColor3 = climate.custom and ACCENT_SELECTED or BASE_BUTTON
	for _, row in ipairs(Match.climateRows) do
		row.Visible = climate.custom
	end
	baseValue.Text = Match.bases[climate.base].label
	skyValue.Text = Match.skies[climate.sky].label
	Match.fogButton.Text = climate.fog and "NIEBLA: SÍ" or "NIEBLA: NO"
	Match.fogButton.BackgroundColor3 = climate.fog and ACCENT_SELECTED or BASE_BUTTON
	for id, button in pairs(Match.specialButtons) do
		button.BackgroundColor3 = climate.specials[id] and ACCENT_SELECTED or BASE_BUTTON
	end
	if climate.custom then
		local key, exact = Match.climateKey()
		if key then
			Match.climateResult.Text = "Queda: " .. Match.ambience.labelFor(key) .. (exact and "" or " (ese especial fija el cielo o la hora)")
			Match.climateResult.TextColor3 = Color3.fromRGB(120, 230, 140)
		else
			Match.climateResult.Text = "Esa combinación de especiales no existe"
			Match.climateResult.TextColor3 = Color3.fromRGB(240, 90, 90)
		end
	end
end

Match.climateToggle.Activated:Connect(function()
	Match.climate.custom = not Match.climate.custom
	Match.refreshClimate()
end)
basePrevious.Activated:Connect(function()
	Match.climate.base = (Match.climate.base - 2) % #Match.bases + 1
	Match.refreshClimate()
end)
baseNext.Activated:Connect(function()
	Match.climate.base = Match.climate.base % #Match.bases + 1
	Match.refreshClimate()
end)
skyPrevious.Activated:Connect(function()
	Match.climate.sky = (Match.climate.sky - 2) % #Match.skies + 1
	Match.refreshClimate()
end)
skyNext.Activated:Connect(function()
	Match.climate.sky = Match.climate.sky % #Match.skies + 1
	Match.refreshClimate()
end)
Match.fogButton.Activated:Connect(function()
	Match.climate.fog = not Match.climate.fog
	Match.refreshClimate()
end)
for id, button in pairs(Match.specialButtons) do
	button.Activated:Connect(function()
		Match.climate.specials[id] = not Match.climate.specials[id] or nil
		Match.refreshClimate()
	end)
end
Match.refreshClimate()

local matchButtonRow = makeRow(-8, 38, 6)
local forceButton = makeButton(matchButtonRow, "FORZAR", 1, 0.3)
forceButton.BackgroundColor3 = ACCENT
local forceNowButton = makeButton(matchButtonRow, "FORZAR Y VOTAR YA", 2, 0.38)
local clearForceButton = makeButton(matchButtonRow, "QUITAR", 3, 0.26)
clearForceButton.BackgroundColor3 = Color3.fromRGB(70, 25, 25)
Match.feedback = makeInfoLabel(-7, "")

function Match.apply(info)
	if type(info) ~= "table" then
		return
	end
	local function readList(raw)
		local list = {}
		for _, item in ipairs(type(raw) == "table" and raw or {}) do
			if type(item) == "table" and type(item.id) == "string" then
				table.insert(list, { id = item.id, label = tostring(item.label or item.id) })
			elseif type(item) == "string" then
				table.insert(list, { id = item, label = item })
			end
		end
		return list
	end
	Match.lists.map = readList(info.maps)
	Match.lists.mode = readList(info.modes)
	Match.lists.gamemode = readList(info.gamemodes)
	for key, list in pairs(Match.lists) do
		local valid = false
		for _, item in ipairs(list) do
			if item.id == Match.choice[key] then
				valid = true
			end
		end
		if not valid then
			Match.choice[key] = nil
		end
	end
	Match.refreshChoices()
	local phaseText = info.waiting and "ESPERANDO QUE ALGUIEN LE DÉ A JUGAR" or (Match.phases[info.phase] or tostring(info.phase))
	local text = "Fase: " .. phaseText .. " · Forzado: " .. Match.describe(info.pending)
	if info.current then
		text = text .. " · Va a empezar: " .. Match.describe(info.current)
	end
	Match.status.Text = text
end

local function sendForce(now)
	local payload = {
		action = "force",
		map = Match.choice.map,
		mode = Match.choice.mode,
		gamemode = Match.choice.gamemode,
		now = now,
	}
	if Match.climate.custom then
		local key = Match.climateKey()
		if not key then
			setFeedback(Match.feedback, "Esa combinación de clima no existe", false)
			return
		end
		payload.ambience = key
	end
	if not (payload.map or payload.mode or payload.gamemode or payload.ambience) then
		setFeedback(Match.feedback, "Elige algo para forzar (mapa, equipos, modo o clima)", false)
		return
	end
	send("match", payload)
	setFeedback(Match.feedback, "Enviando...", true)
end

forceButton.Activated:Connect(function()
	sendForce(false)
end)
forceNowButton.Activated:Connect(function()
	sendForce(true)
end)
clearForceButton.Activated:Connect(function()
	send("match", { action = "clear" })
	setFeedback(Match.feedback, "Quitando...", true)
end)
removeBotButton.Activated:Connect(function()
	send("bot", "removeOne")
	setFeedback(botFeedback, "Quitando bot...", true)
end)
clearBotsButton.Activated:Connect(function()
	send("bot", "removeAll")
	setFeedback(botFeedback, "Quitando todos los bots...", true)
end)

--  [03/10] EQUIPOS: fijar el equipo de un jugador o de los bots (lo hace
--  el script AdminTeamControl). Fijado = se cambia ya si esta jugando, y si
--  no, entra a ese equipo la proxima vez. AUTO lo vuelve a dejar al azar.
local TeamPanel = {
	order = { "Rojo", "Azul", "Verde", "Amarillo", "Auto" },
	colors = {
		Rojo = Color3.fromRGB(170, 40, 40), Azul = Color3.fromRGB(40, 80, 190),
		Verde = Color3.fromRGB(40, 140, 65), Amarillo = Color3.fromRGB(190, 160, 35),
	},
	targets = {},
	selected = "*bots",
	buttons = {},
}
sectionLabel("EQUIPOS (JUGADORES Y BOTS)", -6)
TeamPanel.status = makeInfoLabel(-5, "Equipos: ...")
TeamPanel.status.Size = UDim2.new(1, 0, 0, 40)
TeamPanel.status.TextWrapped = true
local _, teamWhoPrevious, teamWhoValue, teamWhoNext = cyclerRow(-4, "QUIÉN")
TeamPanel.whoValue = teamWhoValue
local teamButtonRow = makeRow(-3, 34, 4)
for i, name in ipairs(TeamPanel.order) do
	local button = makeButton(teamButtonRow, string.upper(name), i, 0.19)
	button.BackgroundColor3 = TeamPanel.colors[name] or BASE_BUTTON
	TeamPanel.buttons[name] = button
	button.Activated:Connect(function()
		if not TeamPanel.selected then
			setFeedback(TeamPanel.feedback, "Elige a quién primero", false)
			return
		end
		send("team", { action = "set", target = TeamPanel.selected, team = name })
		setFeedback(TeamPanel.feedback, "Enviando...", true)
	end)
end
TeamPanel.feedback = makeInfoLabel(-2, "")

function TeamPanel.refreshWho()
	local label = "—"
	for _, item in ipairs(TeamPanel.targets) do
		if item.id == TeamPanel.selected then
			label = item.label
		end
	end
	TeamPanel.whoValue.Text = label
end

function TeamPanel.step(direction)
	local list = TeamPanel.targets
	if #list == 0 then
		return
	end
	local index = 1
	for i, item in ipairs(list) do
		if item.id == TeamPanel.selected then
			index = i
		end
	end
	index = (index - 1 + direction) % #list + 1
	TeamPanel.selected = list[index].id
	TeamPanel.refreshWho()
end
teamWhoPrevious.Activated:Connect(function()
	TeamPanel.step(-1)
end)
teamWhoNext.Activated:Connect(function()
	TeamPanel.step(1)
end)

function TeamPanel.apply(info)
	if type(info) ~= "table" then
		return
	end
	local targets = {
		{ id = "*bots", label = "TODOS LOS BOTS" },
		{ id = "*players", label = "TODOS LOS JUGADORES" },
		{ id = "*all", label = "TODOS" },
	}
	for _, person in ipairs(type(info.people) == "table" and info.people or {}) do
		if type(person) == "table" and type(person.name) == "string" then
			local team = (type(person.team) == "string" and person.team ~= "") and person.team or "sin equipo"
			local label = person.name .. (person.bot and " (bot)" or "") .. " · " .. team
			if type(person.forced) == "string" and person.forced ~= "" then
				label = label .. " · fijo " .. person.forced
			end
			table.insert(targets, { id = person.name, label = label })
		end
	end
	TeamPanel.targets = targets
	local found = false
	for _, item in ipairs(targets) do
		if item.id == TeamPanel.selected then
			found = true
		end
	end
	if not found then
		TeamPanel.selected = "*bots"
	end
	TeamPanel.refreshWho()
	local teams = type(info.teams) == "table" and info.teams or {}
	if type(info.mode) == "string" and info.mode ~= "" then
		TeamPanel.status.Text = #teams > 0 and ("En partida (" .. info.mode .. "): " .. table.concat(teams, ", ") .. ". Fijar cambia ya al que está jugando.")
			or ("En partida (" .. info.mode .. "): sin equipos. Lo fijado se aplica en la próxima con equipos.")
	else
		TeamPanel.status.Text = "Sin partida: lo fijado se aplica cuando entren."
	end
	for name, button in pairs(TeamPanel.buttons) do
		local usable = name == "Auto" or #teams == 0 or table.find(teams, name) ~= nil
		button.BackgroundTransparency = usable and 0 or 0.55
	end
end

sectionLabel("RECOMPENSA", 1)
local rewardRow = makeRow(2, 38, 6)
local pecesButton = makeButton(rewardRow, "PECES", 1, 0.23)
local crateButton = makeButton(rewardRow, "CAJA", 2, 0.23)
local weaponButton = makeButton(rewardRow, "ARMA", 3, 0.23)
local attachmentButton = makeButton(rewardRow, "ACCESORIO", 4, 0.23)

local crateLabel = sectionLabel("TIPO DE CAJA", 3)
crateLabel.Visible = false
local crateScroll = makeList(4, 110)

local crateButtons = {}
local function refreshCrateSelection()
	for name, button in pairs(crateButtons) do
		button.BackgroundColor3 = (name == selectedCrateName) and ACCENT_SELECTED or LIST_BUTTON
	end
end
for _, crate in ipairs(ShopConfig.Crates) do
	local crateName = crate.Name
	local button = makeListButton(crateScroll, crateName)
	crateButtons[crateName] = button
	button.Activated:Connect(function()
		selectedCrateName = crateName
		refreshCrateSelection()
	end)
end
refreshCrateSelection()

local weaponActionLabel = sectionLabel("ACCIÓN", 5)
weaponActionLabel.Visible = false
local weaponActionRow = makeRow(6, 34, 6)
weaponActionRow.Visible = false
local weaponActionButtons = {
	grant = makeButton(weaponActionRow, "DAR", 1, 0.315),
	remove = makeButton(weaponActionRow, "QUITAR", 2, 0.315),
	resetAll = makeButton(weaponActionRow, "RESET", 3, 0.315),
}
weaponActionButtons.resetAll.BackgroundColor3 = Color3.fromRGB(70, 25, 25)

local weaponSearch = makeTextBox(7, 32, "", "Buscar arma...")
weaponSearch.Visible = false
local weaponScroll = makeList(8, 140)

local weaponNames = {}
for _, gun in ipairs(gunStorage:GetChildren()) do
	table.insert(weaponNames, gun.Name)
end
table.sort(weaponNames)

local weaponListButtons = {}
local function refreshWeaponSelection()
	for name, button in pairs(weaponListButtons) do
		button.BackgroundColor3 = (name == selectedWeaponName) and ACCENT_SELECTED or LIST_BUTTON
	end
end
for _, name in ipairs(weaponNames) do
	local button = makeListButton(weaponScroll, name)
	weaponListButtons[name] = button
	button.Activated:Connect(function()
		selectedWeaponName = name
		refreshWeaponSelection()
	end)
end

local attachmentScroll = makeList(8, 140)
local attachmentListButtons = {}
local attachmentSearchText = {}
local function refreshAttachmentSelection()
	for name, button in pairs(attachmentListButtons) do
		button.BackgroundColor3 = (name == selectedAttachmentName) and ACCENT_SELECTED or LIST_BUTTON
	end
end
if AttachmentRegistry and type(AttachmentRegistry.All) == "function" then
	for _, name in ipairs(AttachmentRegistry.All()) do
		local display = AttachmentRegistry.GetDisplayName(name)
		local quality = AttachmentRegistry.GetQuality(name)
		local text = (display ~= name) and (display .. " (" .. name .. ")") or name
		if quality then
			text = text .. " · " .. quality
		end
		local button = makeListButton(attachmentScroll, text)
		attachmentListButtons[name] = button
		attachmentSearchText[name] = text:lower()
		button.Activated:Connect(function()
			selectedAttachmentName = name
			refreshAttachmentSelection()
		end)
	end
end

weaponSearch:GetPropertyChangedSignal("Text"):Connect(function()
	local needle = weaponSearch.Text:lower()
	for name, button in pairs(weaponListButtons) do
		button.Visible = (needle == "") or (name:lower():find(needle, 1, true) ~= nil)
	end
	for name, button in pairs(attachmentListButtons) do
		button.Visible = (needle == "") or (attachmentSearchText[name]:find(needle, 1, true) ~= nil)
	end
end)

local function refreshPickers()
	local pickable = selectedWeaponAction ~= "resetAll"
	weaponSearch.PlaceholderText = selectedRewardType == "Attachment" and "Buscar accesorio..." or "Buscar arma..."
	weaponSearch.Visible = pickable and (selectedRewardType == "Weapon" or selectedRewardType == "Attachment")
	weaponScroll.Visible = pickable and selectedRewardType == "Weapon"
	attachmentScroll.Visible = pickable and selectedRewardType == "Attachment"
end

local function setWeaponAction(newAction)
	selectedWeaponAction = newAction
	resetArmedUntil = 0
	for key, button in pairs(weaponActionButtons) do
		if key == "resetAll" then
			button.BackgroundColor3 = (key == newAction) and Color3.fromRGB(150, 35, 35) or Color3.fromRGB(70, 25, 25)
		else
			button.BackgroundColor3 = (key == newAction) and ACCENT_SELECTED or BASE_BUTTON
		end
	end
	refreshPickers()
end
weaponActionButtons.grant.Activated:Connect(function()
	setWeaponAction("grant")
end)
weaponActionButtons.remove.Activated:Connect(function()
	setWeaponAction("remove")
end)
weaponActionButtons.resetAll.Activated:Connect(function()
	setWeaponAction("resetAll")
end)

local amountBox

local function setRewardType(newType)
	local wasItem = selectedRewardType == "Weapon" or selectedRewardType == "Attachment"
	selectedRewardType = newType
	resetArmedUntil = 0
	pecesButton.BackgroundColor3 = newType == "Peces" and ACCENT_SELECTED or BASE_BUTTON
	crateButton.BackgroundColor3 = newType == "Crate" and ACCENT_SELECTED or BASE_BUTTON
	weaponButton.BackgroundColor3 = newType == "Weapon" and ACCENT_SELECTED or BASE_BUTTON
	attachmentButton.BackgroundColor3 = newType == "Attachment" and ACCENT_SELECTED or BASE_BUTTON
	crateLabel.Visible = newType == "Crate"
	crateScroll.Visible = newType == "Crate"
	local isItem = newType == "Weapon" or newType == "Attachment"
	weaponActionLabel.Visible = isItem
	weaponActionRow.Visible = isItem
	refreshPickers()
	if amountBox then
		if isItem and not wasItem and amountBox.Text == "100" then
			amountBox.Text = "1"
		elseif not isItem and wasItem and amountBox.Text == "1" then
			amountBox.Text = "100"
		end
	end
end
pecesButton.Activated:Connect(function()
	setRewardType("Peces")
end)
crateButton.Activated:Connect(function()
	setRewardType("Crate")
end)
weaponButton.Activated:Connect(function()
	setRewardType("Weapon")
end)
attachmentButton.Activated:Connect(function()
	setRewardType("Attachment")
end)

sectionLabel("CANTIDAD", 9)
amountBox = makeTextBox(10, 36, "100", "Cantidad...")

sectionLabel("A QUIÉN", 11)
local scopeRow = makeRow(12, 34, 6)
local scopeButtons = {
	player = makeButton(scopeRow, "Jugador", 1, 0.325),
	server = makeButton(scopeRow, "Server", 2, 0.325),
	allServers = makeButton(scopeRow, "Todos", 3, 0.325),
}

local targetLabel = sectionLabel("USERNAME DEL JUGADOR (exacto)", 13)
local targetBox = makeTextBox(14, 36, "", "Username exacto...")

local function setScope(newScope)
	selectedScope = newScope
	resetArmedUntil = 0
	for key, button in pairs(scopeButtons) do
		button.BackgroundColor3 = key == newScope and ACCENT_SELECTED or BASE_BUTTON
	end
	targetLabel.Visible = newScope == "player"
	targetBox.Visible = newScope == "player"
end
for key, button in pairs(scopeButtons) do
	button.Activated:Connect(function()
		setScope(key)
	end)
end

local giveButton = Instance.new("TextButton")
giveButton.LayoutOrder = 15
giveButton.Size = UDim2.new(1, 0, 0, 44)
giveButton.BackgroundColor3 = ACCENT
giveButton.Text = "DAR"
giveButton.TextColor3 = Color3.new(1, 1, 1)
giveButton.Font = Enum.Font.GothamBlack
giveButton.TextScaled = true
giveButton.Parent = body
Instance.new("UICorner", giveButton).CornerRadius = UDim.new(0, 8)

local feedbackLabel = Instance.new("TextLabel")
feedbackLabel.LayoutOrder = 16
feedbackLabel.Size = UDim2.new(1, 0, 0, 44)
feedbackLabel.BackgroundTransparency = 1
feedbackLabel.Text = ""
feedbackLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
feedbackLabel.Font = Enum.Font.Gotham
feedbackLabel.TextScaled = true
feedbackLabel.TextWrapped = true
feedbackLabel.Parent = body

setRewardType("Peces")
setWeaponAction("grant")
setScope("player")

local function trimmed(text)
	return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

giveButton.Activated:Connect(function()
	local targetName = selectedScope == "player" and trimmed(targetBox.Text) or nil
	if selectedScope == "player" and targetName == "" then
		setFeedback(feedbackLabel, "Escribe el username del jugador", false)
		return
	end

	if selectedRewardType == "Attachment" then
		if selectedWeaponAction ~= "resetAll" and not selectedAttachmentName then
			setFeedback(feedbackLabel, "Elige un accesorio de la lista primero", false)
			return
		end
		if selectedWeaponAction == "resetAll" then
			if os.clock() > resetArmedUntil then
				resetArmedUntil = os.clock() + RESET_CONFIRM_WINDOW
				local scopeText = selectedScope == "server" and "TODO el servidor" or "ese jugador"
				setFeedback(feedbackLabel,
					"Vas a borrar los accesorios ganados de " .. scopeText .. ". Pulsa DAR otra vez para confirmar.", false)
				return
			end
			resetArmedUntil = 0
		end
		send("give", {
			rewardType = "Attachment",
			attachmentAction = selectedWeaponAction,
			attachmentName = selectedWeaponAction ~= "resetAll" and selectedAttachmentName or nil,
			amount = tonumber(amountBox.Text),
			scope = selectedScope,
			targetName = targetName,
		})
		setFeedback(feedbackLabel, "Enviando...", true)
		return
	end

	if selectedRewardType == "Weapon" then
		if selectedWeaponAction ~= "resetAll" and not selectedWeaponName then
			setFeedback(feedbackLabel, "Elige un arma de la lista primero", false)
			return
		end
		if selectedWeaponAction == "resetAll" then
			if os.clock() > resetArmedUntil then
				resetArmedUntil = os.clock() + RESET_CONFIRM_WINDOW
				local scopeText = selectedScope == "server" and "TODO el servidor" or "ese jugador"
				setFeedback(feedbackLabel,
					"Vas a resetear el inventario de " .. scopeText .. ". Pulsa DAR otra vez para confirmar.", false)
				return
			end
			resetArmedUntil = 0
		end
		send("give", {
			rewardType = "Weapon",
			weaponAction = selectedWeaponAction,
			weaponName = selectedWeaponAction ~= "resetAll" and selectedWeaponName or nil,
			amount = tonumber(amountBox.Text) or 1,
			scope = selectedScope,
			targetName = targetName,
		})
		setFeedback(feedbackLabel, "Enviando...", true)
		return
	end

	local amount = tonumber(amountBox.Text)
	if not amount then
		setFeedback(feedbackLabel, "Cantidad inválida", false)
		return
	end
	send("give", {
		rewardType = selectedRewardType,
		amount = amount,
		crateName = selectedRewardType == "Crate" and selectedCrateName or nil,
		scope = selectedScope,
		targetName = targetName,
	})
	setFeedback(feedbackLabel, "Enviando...", true)
end)

channel.OnClientEvent:Connect(function(ok, message, tag, data)
	if tag == "botOptions" then
		if ok and type(data) == "table" then
			for _, field in ipairs(BOT_FIELDS) do
				local list = {}
				for _, value in ipairs(type(data[field.key]) == "table" and data[field.key] or {}) do
					if type(value) == "string" then
						table.insert(list, value)
					end
				end
				botOptions[field.key] = list
				if botChoice[field.key] and not table.find(list, botChoice[field.key]) then
					botChoice[field.key] = nil
				end
			end
			botMax = tonumber(data.max)
			refreshBotChoices()
			refreshBotCount()
		else
			setFeedback(botFeedback, message, false)
		end
	elseif tag == "match" then
		if type(data) == "table" then
			Match.apply(data)
		end
		if message ~= "" then
			setFeedback(Match.feedback, message, ok)
		end
	elseif tag == "bots" then
		setFeedback(botFeedback, message, ok)
	elseif tag == "team" then
		if type(data) == "table" then
			TeamPanel.apply(data)
		end
		if message ~= "" then
			setFeedback(TeamPanel.feedback, message, ok)
		end
	else
		setFeedback(feedbackLabel, message, ok)
	end
end)

send("bot", { action = "options" })
send("match", { action = "options" })
send("team", { action = "options" })
main:GetPropertyChangedSignal("Visible"):Connect(function()
	if main.Visible then
		send("bot", { action = "options" })
		send("match", { action = "options" })
		send("team", { action = "options" })
	end
end)
task.spawn(function()
	while gui.Parent do
		task.wait(4)
		if main.Visible then
			send("match", { action = "options" })
			send("team", { action = "options" })
		end
	end
end)

local launcher = Instance.new("TextButton")
launcher.Name = "Launcher"
launcher.AnchorPoint = Vector2.new(0.5, 0.5)
launcher.Position = UDim2.fromScale(0.95, 0.3)
launcher.Size = UDim2.fromOffset(50, 50)
launcher.BackgroundColor3 = Color3.fromRGB(16, 17, 21)
launcher.BackgroundTransparency = 0.35
launcher.Text = ""
launcher.AutoButtonColor = false
launcher.Active = true
launcher.ZIndex = 20
launcher.Visible = false
launcher.Parent = gui
Instance.new("UICorner", launcher).CornerRadius = UDim.new(1, 0)
local launcherStroke = Instance.new("UIStroke", launcher)
launcherStroke.Color = ACCENT
launcherStroke.Thickness = 2
launcherStroke.Transparency = 0.3

local launcherDot = Instance.new("Frame")
launcherDot.AnchorPoint = Vector2.new(0.5, 0.5)
launcherDot.Position = UDim2.fromScale(0.5, 0.5)
launcherDot.Size = UDim2.fromScale(0.34, 0.34)
launcherDot.BackgroundColor3 = Color3.fromRGB(220, 60, 60)
launcherDot.BorderSizePixel = 0
launcherDot.ZIndex = 21
launcherDot.Parent = launcher
Instance.new("UICorner", launcherDot).CornerRadius = UDim.new(1, 0)

local function refreshLauncher()
	launcher.Visible = UserInputService.TouchEnabled or not UserInputService.KeyboardEnabled
end
refreshLauncher()
UserInputService:GetPropertyChangedSignal("TouchEnabled"):Connect(refreshLauncher)
UserInputService:GetPropertyChangedSignal("KeyboardEnabled"):Connect(refreshLauncher)

main:GetPropertyChangedSignal("Visible"):Connect(function()
	launcherDot.BackgroundColor3 = main.Visible and Color3.fromRGB(120, 230, 140) or Color3.fromRGB(220, 60, 60)
end)

local DRAG_THRESHOLD = 8
local dragInput, dragStart, dragOrigin, dragMoved

local function isPress(input)
	return input.UserInputType == Enum.UserInputType.Touch
		or input.UserInputType == Enum.UserInputType.MouseButton1
end

local function belongsToDrag(input)
	if not dragInput then
		return false
	end
	if dragInput.UserInputType == Enum.UserInputType.Touch then
		return input == dragInput
	end
	return input.UserInputType == Enum.UserInputType.MouseMovement
		or input.UserInputType == Enum.UserInputType.MouseButton1
end

launcher.InputBegan:Connect(function(input)
	if dragInput or not isPress(input) then
		return
	end
	dragInput = input
	dragStart = input.Position
	dragOrigin = launcher.Position
	dragMoved = false
	launcher.BackgroundTransparency = 0.1
end)

UserInputService.InputChanged:Connect(function(input)
	if not belongsToDrag(input) then
		return
	end
	local delta = input.Position - dragStart
	if not dragMoved and Vector2.new(delta.X, delta.Y).Magnitude < DRAG_THRESHOLD then
		return
	end
	dragMoved = true
	local viewport = gui.AbsoluteSize
	if viewport.X <= 0 or viewport.Y <= 0 then
		return
	end
	launcher.Position = UDim2.fromScale(
		math.clamp(dragOrigin.X.Scale + delta.X / viewport.X, 0.04, 0.96),
		math.clamp(dragOrigin.Y.Scale + delta.Y / viewport.Y, 0.06, 0.94)
	)
end)

UserInputService.InputEnded:Connect(function(input)
	if not dragInput or not isPress(input) or not belongsToDrag(input) then
		return
	end
	local wasTap = not dragMoved
	dragInput = nil
	launcher.BackgroundTransparency = 0.35
	if wasTap then
		togglePanel()
	end
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if input.KeyCode == Enum.KeyCode.F4 then
		togglePanel()
	end
end)
