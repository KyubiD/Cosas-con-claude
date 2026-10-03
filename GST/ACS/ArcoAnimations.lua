--==========================================================================
--  ACS_Animations del ARCO  (ModuleScript "ACS_Animations" dentro del Tool)
--  [03/10/2026]  Base: el ACS_Animations de la ballesta.
--
--  Modo de disparo 6 (Charge). Mientras cargas, la cuerda se tensa segun
--  el porcentaje de carga, las palas se doblan un poco, la flecha se va
--  hacia atras y la mano derecha va tirando de la cuerda. Al soltar, la
--  cuerda vuelve de golpe y vibra; si cancelas, se destensa despacio.
--
--  Necesita los 2 ganchos nuevos del ACS_Framework (ver ese script, busca
--  "[ARCO 03/10]"):
--    self.ChargeProgress(objs, ratio, dt)  cada frame mientras cargas
--    self.ChargeShot(objs)                 al disparar (aunque FireAnimLoop = false)
--    self.ChargeRelease(objs)              al soltar / cancelar
--  y tambien responde al que ya existia (ChargeFireAnim).
--
--  PIEZAS DEL MODELO (GunModels > Arco), se buscan por nombre:
--    Cuerda1 / Cuerda2         las dos mitades de la cuerda (arriba / abajo)
--    Side1 / Side2             las palas de arriba / abajo
--    LimiteCuerda1 / 2         la punta de cada pala donde se amarra la cuerda
--    HandGuard                 la empunadura (no se mueve)
--    Flecha / Arrow / Mag      la flecha (la primera que exista; ver
--                              Bow.ArrowNames). Se esconde al disparar y
--                              vuelve a aparecer al recargar.
--  Todo se calcula con la forma real del modelo: no hay que medir nada.
--  Si algo se ve al reves, ver Bow.FlipDraw.
--==========================================================================

local TS = game:GetService('TweenService')
local RunService = game:GetService("RunService")
local self = {}

self.MainCFrame 	= CFrame.new(0.5,-.85,-0.75)

self.GunModelFixed 	= true
self.GunCFrame 		= CFrame.new(0.15, -.2, .85) * CFrame.Angles(math.rad(90),math.rad(0),math.rad(0))
self.LArmCFrame 	= CFrame.new(-.65,-0.15,-.35) * CFrame.Angles(math.rad(110),math.rad(15),math.rad(15))
self.RArmCFrame 	= CFrame.new(0.05,-0.15,1) * CFrame.Angles(math.rad(90),math.rad(0),math.rad(0))

--==========================================================================
--  AJUSTES DEL ARCO
--==========================================================================
self.Bow = {
	--  Cuanto se va la cuerda hacia atras con la carga completa, en studs.
	--  nil = DrawFraction x el largo del arco (punta a punta).
	DrawDistance = nil,
	DrawFraction = 0.42,
	--  Cuantos grados se dobla cada pala con la carga completa.
	LimbBendDeg = 8,
	--  true = la cuerda se jala hacia el otro lado (si al cargar se va
	--  hacia adelante en vez de hacia ti).
	FlipDraw = false,
	--  Nombres posibles de la flecha (se usan todos los que existan).
	ArrowNames = { "Flecha", "Arrow", "Mag" },

	--  Resorte de la cuerda. Draw: al cargar (sin rebote). Release: al
	--  disparar (rapido y con vibracion; Damping mas bajo = vibra mas).
	DrawStiffness = 220,
	ReleaseStiffness = 1600,
	ReleaseDamping = 0.16,
	CancelStiffness = 120,

	--  Brazos: punto de la mano dentro del brazo (el mismo agarre que usa
	--  ACS) y rapidez con la que las manos siguen a la cuerda / empunadura.
	HandLocal = Vector3.new(0, -0.85, 0),
	ArmSpeed = 18,
	--  Desfase de cada mano respecto a su punto (en studs, ejes del arco).
	RightHandOffset = Vector3.new(0, 0, 0),
	LeftHandOffset = Vector3.new(0, 0, 0),
	--  Al disparar la mano derecha se va un poco mas atras (en studs).
	ReleaseFollowThrough = 0.35,

	--  Recarga: la mano derecha va a la aljaba (detras del hombro derecho).
	--  Pose del brazo en el espacio de los brazos (como RArmCFrame).
	QuiverPose = CFrame.new(0.9, 0.45, 1.6) * CFrame.Angles(math.rad(150), math.rad(-25), math.rad(0)),
	ReloadReach = 0.35,		-- segundos hasta la aljaba
	ReloadBack = 0.40,		-- segundos de vuelta con la flecha a la cuerda
}

--==========================================================================
--  RIG DEL ARCO (una vez por modelo equipado)
--==========================================================================
local Rigs = {}			-- [WeaponInHand] = rig
local warned = false

local function partsNamed(model, names)
	local set = {}
	for _, name in ipairs(names) do set[name] = true end
	local list = {}
	for _, item in ipairs(model:GetDescendants()) do
		if item:IsA("BasePart") and set[item.Name] then table.insert(list, item) end
	end
	return list
end

--  Eje mas largo de una pieza (1 = X, 2 = Y, 3 = Z) y su vector.
local function longAxis(cf, size)
	local i = (size.X >= size.Y and size.X >= size.Z) and 1 or (size.Y >= size.Z and 2 or 3)
	local vectors = { cf.RightVector, cf.UpVector, cf.LookVector }
	local halves = { size.X / 2, size.Y / 2, size.Z / 2 }
	return i, vectors[i], halves[i]
end

local function rotationBetween(from, to)
	local a, b = from.Unit, to.Unit
	local axis = a:Cross(b)
	local dot = math.clamp(a:Dot(b), -1, 1)
	if axis.Magnitude < 1e-6 then return CFrame.new() end
	return CFrame.fromAxisAngle(axis.Unit, math.acos(dot))
end

local function rotOnly(cf) return cf - cf.Position end

local function buildRig(objs)
	local model = objs[4]
	local handle = model and model:FindFirstChild("Handle")
	if not handle then return nil end
	local B = self.Bow
	local cuerda1, cuerda2 = partsNamed(model, { "Cuerda1" }), partsNamed(model, { "Cuerda2" })
	if #cuerda1 == 0 or #cuerda2 == 0 then
		if not warned then
			warned = true
			warn("[Arco] No encontre Cuerda1 / Cuerda2 en " .. model:GetFullName() .. ": sin animacion de cuerda")
		end
		return nil
	end
	local side1, side2 = partsNamed(model, { "Side1" }), partsNamed(model, { "Side2" })
	local lim1, lim2 = partsNamed(model, { "LimiteCuerda1" }), partsNamed(model, { "LimiteCuerda2" })
	local arrows = partsNamed(model, B.ArrowNames)
	local guards = partsNamed(model, { "HandGuard" })

	--  Todo en el espacio del Handle (no depende de donde este el arma).
	local hInv = handle.CFrame:Inverse()
	local function rel(part) return hInv * part.CFrame end

	--  Extremos de cada mitad de la cuerda: la punta (lejos de la otra
	--  mitad) y el centro (donde se juntan = donde va la flecha).
	local function ends(parts)
		local list = {}
		for _, part in ipairs(parts) do
			local cf = rel(part)
			local _, vector, half = longAxis(cf, part.Size)
			table.insert(list, cf.Position + vector * half)
			table.insert(list, cf.Position - vector * half)
		end
		return list
	end
	local e1, e2 = ends(cuerda1), ends(cuerda2)
	local nock, best = nil, math.huge
	for _, a in ipairs(e1) do
		for _, b in ipairs(e2) do
			local d = (a - b).Magnitude
			if d < best then best, nock = d, (a + b) / 2 end
		end
	end
	local function farthest(list, from)
		local far, dist = list[1], -1
		for _, p in ipairs(list) do
			local d = (p - from).Magnitude
			if d > dist then far, dist = p, d end
		end
		return far
	end
	local tipTop, tipBot = farthest(e1, nock), farthest(e2, nock)
	local span = tipTop - tipBot
	if span.Magnitude < 0.05 then return nil end
	local axisUp = span.Unit

	--  Empunadura y hacia donde se jala (del arco hacia el arquero).
	local grip = Vector3.zero
	if #guards > 0 then
		for _, part in ipairs(guards) do grip += rel(part).Position end
		grip /= #guards
	end
	local toNock = nock - grip
	local perp = toNock - axisUp * toNock:Dot(axisUp)
	local D
	if perp.Magnitude > 0.05 then
		D = perp.Unit
	else
		local animPart = objs[5] and objs[5].PrimaryPart
		local back = animPart and handle.CFrame:VectorToObjectSpace(-animPart.CFrame.LookVector) or Vector3.new(0, 0, 1)
		back -= axisUp * back:Dot(axisUp)
		D = back.Magnitude > 0.01 and back.Unit or Vector3.new(0, 0, 1)
	end
	if B.FlipDraw then D = -D end

	--  Bisagra de cada pala: entre la empunadura y su primer tramo.
	local function hinge(parts, dir)
		local s = math.huge
		for _, part in ipairs(parts) do
			local d = (rel(part).Position - grip):Dot(dir)
			if d < s then s = d end
		end
		if s == math.huge then s = 0 end
		return grip + dir * math.max(s * 0.6, 0)
	end
	local topDir = (tipTop - grip):Dot(axisUp) >= 0 and axisUp or -axisUp

	local rig = {
		model = model, handle = handle, objs = objs,
		nock = nock, tipTop = tipTop, tipBot = tipBot, axisUp = axisUp, D = D, grip = grip,
		drawDist = B.DrawDistance or span.Magnitude * B.DrawFraction,
		hingeTop = hinge(side1, topDir), hingeBot = hinge(side2, -topDir),
		kTop = topDir:Cross(D).Unit, kBot = (-topDir):Cross(D).Unit,
		pieces = {}, arrows = {},
		x = 0, v = 0, target = 0, mode = "draw",
		phase = "idle", t = 0,
	}

	local animated = {}
	local function add(part, kind)
		if animated[part] then return end
		local cf = rel(part)
		local piece = { part = part, kind = kind, rest = cf, size = part.Size }
		if kind == "str1" or kind == "str2" then
			piece.axis = longAxis(cf, part.Size)
			local mesh = part:FindFirstChildOfClass("SpecialMesh")
			if mesh then piece.mesh, piece.meshScale = mesh, mesh.Scale end
		end
		animated[part] = piece
		table.insert(rig.pieces, piece)
	end
	for _, part in ipairs(side1) do add(part, "top") end
	for _, part in ipairs(side2) do add(part, "bot") end
	for _, part in ipairs(lim1) do add(part, (rel(part).Position - tipTop).Magnitude <= (rel(part).Position - nock).Magnitude and "top" or "nockpiece") end
	for _, part in ipairs(lim2) do add(part, (rel(part).Position - tipBot).Magnitude <= (rel(part).Position - nock).Magnitude and "bot" or "nockpiece") end
	for _, part in ipairs(cuerda1) do add(part, "str1") end
	for _, part in ipairs(cuerda2) do add(part, "str2") end
	for _, part in ipairs(arrows) do
		add(part, "arrow")
		table.insert(rig.arrows, { part = part, transparency = part.Transparency })
	end

	--  Cada pieza animada queda soldada SOLO al Handle con una soldadura
	--  propia (las de ACS / del modelo entre estas piezas se apagan para
	--  que no peleen). Lo que cuelga de una pieza (no hijo directo del
	--  modelo) se queda soldado a ella y la sigue.
	for _, joint in ipairs(model:GetDescendants()) do
		if joint:IsA("JointInstance") or joint:IsA("WeldConstraint") then
			local a, b = joint.Part0, joint.Part1
			if animated[a] or animated[b] then
				local other = animated[a] and b or a
				if other == handle or animated[other] or (other and other.Parent == model) then
					joint.Enabled = false
				end
			end
		end
	end
	for _, piece in ipairs(rig.pieces) do
		local weld = Instance.new("Weld")
		weld.Name = "ArcoRig"
		weld.Part0 = handle
		weld.Part1 = piece.part
		weld.C0 = piece.rest
		weld.Parent = handle
		piece.weld = weld
	end
	return rig
end

--  Pone el arco en la tension x (0 = en reposo, 1 = carga completa; un
--  poco negativo justo despues de soltar, por la vibracion).
local function poseRig(rig, x)
	local B = self.Bow
	local pull = rig.drawDist * x
	local flex = math.rad(B.LimbBendDeg) * math.clamp(x, 0, 1.2)
	local rotTop = CFrame.fromAxisAngle(rig.kTop, flex)
	local rotBot = CFrame.fromAxisAngle(rig.kBot, flex)
	local function around(pivot, rot, cf) return CFrame.new(pivot) * rot * CFrame.new(-pivot) * cf end
	local tipTop = rig.hingeTop + rotTop * (rig.tipTop - rig.hingeTop)
	local tipBot = rig.hingeBot + rotBot * (rig.tipBot - rig.hingeBot)
	local nock = rig.nock + rig.D * pull
	local shift = nock - rig.nock

	local function stringFrame(oldTip, newTip)
		local r, n = rig.nock - oldTip, nock - newTip
		return rotationBetween(r, n), n.Magnitude / math.max(r.Magnitude, 1e-4), n.Unit
	end
	local q1, k1, n1 = stringFrame(rig.tipTop, tipTop)
	local q2, k2, n2 = stringFrame(rig.tipBot, tipBot)

	for _, piece in ipairs(rig.pieces) do
		local cf
		local kind = piece.kind
		if kind == "top" then
			cf = around(rig.hingeTop, rotTop, piece.rest)
		elseif kind == "bot" then
			cf = around(rig.hingeBot, rotBot, piece.rest)
		elseif kind == "arrow" or kind == "nockpiece" then
			cf = CFrame.new(shift) * piece.rest
		else
			local q, k, n, oldTip, newTip = q1, k1, n1, rig.tipTop, tipTop
			if kind == "str2" then q, k, n, oldTip, newTip = q2, k2, n2, rig.tipBot, tipBot end
			local offset = q * (piece.rest.Position - oldTip)
			offset += n * offset:Dot(n) * (k - 1)
			cf = CFrame.new(newTip + offset) * q * rotOnly(piece.rest)
			local size = piece.size
			local scaled = piece.axis == 1 and Vector3.new(size.X * k, size.Y, size.Z)
				or piece.axis == 2 and Vector3.new(size.X, size.Y * k, size.Z)
				or Vector3.new(size.X, size.Y, size.Z * k)
			if piece.part.Size ~= scaled then piece.part.Size = scaled end
			if piece.mesh then
				local s = piece.meshScale
				piece.mesh.Scale = piece.axis == 1 and Vector3.new(s.X * k, s.Y, s.Z)
					or piece.axis == 2 and Vector3.new(s.X, s.Y * k, s.Z) or Vector3.new(s.X, s.Y, s.Z * k)
			end
		end
		piece.weld.C0 = cf
	end
	return nock
end

local function setArrowVisible(rig, visible)
	for _, arrow in ipairs(rig.arrows) do
		arrow.part.Transparency = visible and arrow.transparency or 1
		for _, child in ipairs(arrow.part:GetDescendants()) do
			if child:IsA("Decal") or child:IsA("Texture") then child.Transparency = visible and 0 or 1 end
		end
	end
	rig.arrowHidden = not visible
end

--==========================================================================
--  MANOS: mientras se carga / suelta / recarga, el arco queda quieto
--  frente a la camara y las manos se mueven solas (la izquierda en la
--  empunadura, la derecha en la cuerda). Despues todo vuelve a como ACS lo
--  tenia (el arco otra vez en la mano derecha).
--==========================================================================
local function weldPose(weld) return weld.C0 * weld.C1:Inverse() end
local function setWeldPose(weld, pose) weld.C1 = pose:Inverse() * weld.C0 end

--  Pose del brazo con la mano en H, apuntando hacia el hombro S.
local function armPose(H, S, rollRight)
	local up = S - H
	up = up.Magnitude > 1e-3 and up.Unit or Vector3.new(0, 1, 0)
	local right = rollRight - up * rollRight:Dot(up)
	right = right.Magnitude > 1e-3 and right.Unit or up:Cross(Vector3.new(0, 0, 1)).Unit
	local back = right:Cross(up)
	local hl = self.Bow.HandLocal
	return CFrame.fromMatrix(H - (right * hl.X + up * hl.Y + back * hl.Z), right, up)
end

local function lock(rig)
	if rig.locked then return end
	local rArm, lArm, gunWeld = rig.objs[1], rig.objs[2], rig.objs[3]
	rig.gunC0 = gunWeld.C0
	rig.r0, rig.l0 = weldPose(rArm), weldPose(lArm)
	rig.bow = rig.r0 * gunWeld.C0 * gunWeld.C1:Inverse()		-- el arco respecto a los brazos
	rig.r, rig.l = rig.r0, rig.l0
	local armLen = (rArm.Part1 and rArm.Part1.Size.Y or 2) / 2
	rig.shoulderR = rig.r0 * Vector3.new(0, armLen, 0)
	rig.shoulderL = rig.l0 * Vector3.new(0, armLen, 0)
	rig.locked = true
end

local function unlock(rig)
	if not rig.locked then return end
	local rArm, lArm, gunWeld = rig.objs[1], rig.objs[2], rig.objs[3]
	setWeldPose(rArm, rig.r0)
	setWeldPose(lArm, rig.l0)
	gunWeld.C0 = rig.gunC0
	rig.locked = false
	rig.phase = "idle"
end

local function step(rig, dt)
	local B = self.Bow
	--  Resorte de la cuerda (con sub-pasos: el de soltar es muy duro).
	local stiffness, damping
	if rig.mode == "release" then
		stiffness = B.ReleaseStiffness
		damping = 2 * B.ReleaseDamping * math.sqrt(stiffness)
	elseif rig.mode == "cancel" then
		stiffness = B.CancelStiffness
		damping = 2 * math.sqrt(stiffness)
	else
		stiffness = B.DrawStiffness
		damping = 2 * math.sqrt(stiffness)
	end
	--  En reposo y sin manos que mover: nada que hacer.
	if not rig.locked and rig.atRest and rig.target == 0 and math.abs(rig.x) < 1e-4 and math.abs(rig.v) < 1e-4 then return end
	local steps = math.max(1, math.ceil(dt / (1 / 240)))
	local h = dt / steps
	for _ = 1, steps do
		rig.v += (-stiffness * (rig.x - rig.target) - damping * rig.v) * h
		rig.x += rig.v * h
	end
	local nock = poseRig(rig, rig.x)
	rig.atRest = rig.target == 0 and math.abs(rig.x) < 1e-4 and math.abs(rig.v) < 1e-4
	if rig.atRest and rig.x ~= 0 then
		rig.x, rig.v = 0, 0
		nock = poseRig(rig, 0)
	end

	if not rig.locked then return end
	rig.t += dt
	local rArm, lArm, gunWeld = rig.objs[1], rig.objs[2], rig.objs[3]
	local alpha = 1 - math.exp(-B.ArmSpeed * dt)
	local bow = rig.bow
	local rightTarget, leftTarget
	local nockPoint = bow * (nock + B.RightHandOffset)
	local gripPoint = bow * (rig.grip + B.LeftHandOffset)
	local gripPose = armPose(gripPoint, rig.shoulderL, rig.l0.RightVector)

	if rig.phase == "draw" then
		rightTarget = armPose(nockPoint, rig.shoulderR, rig.r0.RightVector)
		leftTarget = gripPose
	elseif rig.phase == "release" then
		--  La mano sigue hacia atras un instante y despues vuelve.
		local back = bow:VectorToWorldSpace(rig.D) * B.ReleaseFollowThrough
		if rig.t < 0.18 then
			rightTarget = armPose(nockPoint + back, rig.shoulderR, rig.r0.RightVector)
			leftTarget = gripPose
		else
			rightTarget, leftTarget = rig.r0, (rig.t < 0.3) and gripPose or rig.l0
		end
	elseif rig.phase == "reload" then
		leftTarget = gripPose
		if rig.t < B.ReloadReach then
			rightTarget = B.QuiverPose
		else
			if rig.arrowHidden then
				setArrowVisible(rig, true)
				local snd = rig.handle:FindFirstChild("MagIn")
				if snd and snd:IsA("Sound") then snd:Play() end
			end
			rightTarget = (rig.t < B.ReloadReach + B.ReloadBack) and armPose(nockPoint, rig.shoulderR, rig.r0.RightVector) or rig.r0
			if rig.t >= B.ReloadReach + B.ReloadBack then leftTarget = rig.l0 end
		end
	end

	rig.r = rig.r:Lerp(rightTarget or rig.r0, alpha)
	rig.l = rig.l:Lerp(leftTarget or rig.l0, alpha)
	setWeldPose(rArm, rig.r)
	setWeldPose(lArm, rig.l)
	gunWeld.C0 = rig.r:Inverse() * bow * gunWeld.C1		-- el arco no se mueve con la mano

	--  De vuelta en reposo: se le devuelve el arco a ACS.
	if rig.phase == "release" or rig.phase == "cancel" or rig.phase == "back" then
		local settled = math.abs(rig.x) < 0.01 and math.abs(rig.v) < 0.05
		local home = (rig.r.Position - rig.r0.Position).Magnitude < 0.02 and (rig.l.Position - rig.l0.Position).Magnitude < 0.02
		if (settled and home and rig.t > 0.3) or rig.t > 1.2 then unlock(rig) end
	end
end

local function getRig(objs)
	local model = objs and objs[4]
	if not model then return nil end
	local rig = Rigs[model]
	if rig == nil then
		local ok, result = pcall(buildRig, objs)
		if not ok then warn("[Arco] " .. tostring(result)) end
		rig = ok and result or false
		Rigs[model] = rig
		if rig then
			rig.conn = RunService.RenderStepped:Connect(function(dt)
				if not model.Parent then
					rig.conn:Disconnect()
					Rigs[model] = nil
					return
				end
				local okStep, err = pcall(step, rig, dt)
				if not okStep then
					rig.conn:Disconnect()
					warn("[Arco] " .. tostring(err))
				end
			end)
		end
	end
	return rig or nil
end

--==========================================================================
--  GANCHOS DEL MODO CHARGE (ACS_Framework)
--==========================================================================
self.ChargeProgress = function(objs, ratio, dt)
	local rig = getRig(objs)
	if not rig then return end
	if rig.phase ~= "draw" then
		if rig.phase == "reload" then return end
		lock(rig)
		rig.phase, rig.t, rig.mode = "draw", 0, "draw"
		if rig.arrowHidden then setArrowVisible(rig, true) end	-- si cargas, hay flecha
	end
	rig.target = math.clamp(ratio, 0, 1)
end

--  Disparo: lo llama el gancho ChargeShot del framework (siempre) y el
--  ChargeFireAnim de siempre (si FireAnimLoop no esta en false). El
--  segundo que llega no hace nada.
self.ChargeShot = function(objs)
	local rig = getRig(objs)
	if not rig then return end
	if rig.phase == "release" and rig.t < 0.1 then return end
	lock(rig)
	rig.phase, rig.t, rig.mode, rig.target = "release", 0, "release", 0
	setArrowVisible(rig, false)		-- la flecha salio volando
end
self.ChargeFireAnim = self.ChargeShot

--  Soltar sin disparar (o despues de disparar: entonces no hace nada).
self.ChargeRelease = function(objs)
	local rig = getRig(objs)
	if not rig or rig.phase ~= "draw" then return end
	rig.phase, rig.t, rig.mode, rig.target = "cancel", 0, "cancel", 0
end

--  Espera a que el arco termine de soltar / recargar antes de otra animacion.
local function waitFree(objs, maxTime)
	local rig = objs and Rigs[objs[4]]
	local waited = 0
	while rig and rig.locked and waited < (maxTime or 1.5) do
		waited += task.wait()
	end
end

--  Mueve los brazos ya o, si el arco esta tensado / soltando, en cuanto
--  termine (sin frenar al framework mientras tanto).
local function whenFree(objs, tweens)
	local rig = objs and Rigs[objs[4]]
	if rig and rig.locked then
		task.spawn(function()
			waitFree(objs)
			tweens()
		end)
	else
		tweens()
	end
end

--==========================================================================
--  ANIMACIONES NORMALES (las de la ballesta, sin cargador ni cerrojo)
--==========================================================================
self.EquipAnim = function(objs)
	getRig(objs)		-- arma el rig del arco recien equipado
	TS:Create(objs[1], TweenInfo.new(.25,Enum.EasingStyle.Linear), {C1 = (CFrame.new(1,-1,1) * CFrame.Angles(math.rad(0),math.rad(0),math.rad(0))):inverse() }):Play()
	TS:Create(objs[2], TweenInfo.new(.25,Enum.EasingStyle.Linear), {C1 = (CFrame.new(-1,-1,1) * CFrame.Angles(math.rad(0),math.rad(0),math.rad(0))):inverse() }):Play()
	task.wait(.25)
	TS:Create(objs[1], TweenInfo.new(.35,Enum.EasingStyle.Sine), {C1 = self.RArmCFrame:Inverse()}):Play()
	TS:Create(objs[2], TweenInfo.new(.35,Enum.EasingStyle.Sine), {C1 = self.LArmCFrame:Inverse()}):Play()
	task.wait(.35)
end;

self.IdleAnim = function(objs)
	whenFree(objs, function()
		TS:Create(objs[1], TweenInfo.new(.25,Enum.EasingStyle.Sine), {C1 = self.RArmCFrame:Inverse()}):Play()
		TS:Create(objs[2], TweenInfo.new(.25,Enum.EasingStyle.Sine), {C1 = self.LArmCFrame:Inverse()}):Play()
	end)
end;

self.LowReady = function(objs)
	whenFree(objs, function()
		TS:Create(objs[1],TweenInfo.new(.25,Enum.EasingStyle.Sine),{C1 = (CFrame.new(0.05,-0.15,1) * CFrame.Angles(math.rad(65), math.rad(0), math.rad(0))):inverse() }):Play()
		TS:Create(objs[2],TweenInfo.new(.25,Enum.EasingStyle.Sine),{C1 = (CFrame.new(-.6,-0.75,-.25) * CFrame.Angles(math.rad(85),math.rad(15),math.rad(15))):inverse() }):Play()
	end)
	task.wait(0.25)
end;

self.HighReady = function(objs)
	whenFree(objs, function()
		TS:Create(objs[1],TweenInfo.new(.25,Enum.EasingStyle.Sine),{C1 = (CFrame.new(0.35,-0.75,1) * CFrame.Angles(math.rad(135), math.rad(0), math.rad(0))):inverse() }):Play()
		TS:Create(objs[2],TweenInfo.new(.25,Enum.EasingStyle.Sine),{C1 = (CFrame.new(-.2,-0.15,0.25) * CFrame.Angles(math.rad(155),math.rad(35),math.rad(15))):inverse() }):Play()
	end)
	task.wait(0.25)
end;

self.Patrol = function(objs)
	whenFree(objs, function()
		TS:Create(objs[1], TweenInfo.new(.25,Enum.EasingStyle.Sine), {C1 = (CFrame.new(.75,-0.15,0) * CFrame.Angles(math.rad(90),math.rad(20),math.rad(-75))):inverse() }):Play()
		TS:Create(objs[2], TweenInfo.new(.25,Enum.EasingStyle.Sine), {C1 = (CFrame.new(-1.15,-0.75,0.4) * CFrame.Angles(math.rad(90),math.rad(20),math.rad(25))):inverse() }):Play()
	end)
	task.wait(.25)
end;

self.SprintAnim = function(objs)
	whenFree(objs, function()
		TS:Create(objs[1], TweenInfo.new(.25,Enum.EasingStyle.Sine), {C1 = (CFrame.new(.75,-0.15,0) * CFrame.Angles(math.rad(90),math.rad(20),math.rad(-75))):inverse() }):Play()
		TS:Create(objs[2], TweenInfo.new(.25,Enum.EasingStyle.Sine), {C1 = (CFrame.new(-1.15,-0.75,0.4) * CFrame.Angles(math.rad(90),math.rad(20),math.rad(25))):inverse() }):Play()
	end)
	task.wait(.25)
end;

--  Recarga: la mano derecha va a la aljaba, saca una flecha y la pone en
--  la cuerda (el arco se queda en su lugar). Sin rig: solo reaparece.
self.ReloadAnim = function(objs)
	waitFree(objs)
	local rig = getRig(objs)
	local B = self.Bow
	local outSnd = objs[4]:FindFirstChild("Handle") and objs[4].Handle:FindFirstChild("MagOut")
	if outSnd and outSnd:IsA("Sound") then outSnd:Play() end
	if not rig then
		task.wait(B.ReloadReach + B.ReloadBack)
		for _, part in ipairs(partsNamed(objs[4], B.ArrowNames)) do part.Transparency = 0 end
		return
	end
	lock(rig)
	rig.phase, rig.t, rig.mode, rig.target = "reload", 0, "cancel", 0
	task.wait(B.ReloadReach + B.ReloadBack + 0.1)
	if rig.phase == "reload" then rig.phase, rig.t = "back", 0 end
	waitFree(objs, 1)
end;

self.TacticalReloadAnim = function(objs)
	self.ReloadAnim(objs)
end;

self.JammedAnim = function(objs)
	task.wait(0.25)
end;

self.PumpAnim = function(objs)

end;

self.MagCheck = function(objs)
	waitFree(objs)
	TS:Create(objs[1], TweenInfo.new(.25,Enum.EasingStyle.Sine), {C1 = (CFrame.new(0.5,-0.15,0) * CFrame.Angles(math.rad(100),math.rad(0),math.rad(-45))):inverse() }):Play()
	TS:Create(objs[2], TweenInfo.new(.25,Enum.EasingStyle.Linear), {C1 = (CFrame.new(-1,-1,1) * CFrame.Angles(math.rad(0),math.rad(0),math.rad(0))):inverse() }):Play()
	task.wait(2.5)
	TS:Create(objs[1], TweenInfo.new(.25,Enum.EasingStyle.Sine), {C1 = (CFrame.new(0.5,-0.15,0) * CFrame.Angles(math.rad(160),math.rad(60),math.rad(-45))):inverse() }):Play()
	TS:Create(objs[2], TweenInfo.new(.25,Enum.EasingStyle.Linear), {C1 = (CFrame.new(-1,-1,1) * CFrame.Angles(math.rad(0),math.rad(0),math.rad(0))):inverse() }):Play()
	task.wait(2.5)
end;

self.meleeAttack = function(objs)

end;

self.GrenadeReady = function(objs)

end;

self.GrenadeThrow = function(objs)

end;

--  Solo para pruebas fuera de Roblox.
self.__ArcoTest = { build = buildRig, pose = poseRig, rigs = Rigs }

----------------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------
--//Server Animations
------//Idle Position
self.SV_GunPos = CFrame.new(-.3, -.2, -0.4) * CFrame.Angles(math.rad(-90), math.rad(0), math.rad(0))

self.SV_RightArmPos = CFrame.new(-.9, 1.25, -0.35) * CFrame.Angles(math.rad(-30), math.rad(0), math.rad(0))	--Server
self.SV_LeftArmPos = CFrame.new(1,1,-1) * CFrame.Angles(math.rad(-80),math.rad(30),math.rad(-10))	--server

self.SV_RightElbowPos = CFrame.new(0,-0.45,-.25) * CFrame.Angles(math.rad(-80), math.rad(0), math.rad(0))		--Client
self.SV_LeftElbowPos = CFrame.new(0,0, -0.1) * CFrame.Angles(math.rad(-15),math.rad(0),math.rad(0))	--Client

self.SV_RightWristPos = CFrame.new(0,0,0.15) * CFrame.Angles(math.rad(20), math.rad(0), math.rad(0))		--Client
self.SV_LeftWristPos = CFrame.new(0,0,0) * CFrame.Angles(math.rad(0),math.rad(-15),math.rad(0))

------//High Ready Animations
self.RightHighReady = CFrame.new(-1.1, .5, -1.1) * CFrame.Angles(math.rad(-90), math.rad(0), math.rad(0));
self.LeftHighReady = CFrame.new(0.65,0.4,-1.3) * CFrame.Angles(math.rad(-140),math.rad(30),math.rad(30));

self.RightElbowHighReady = CFrame.new(0,-0.25,-.35) * CFrame.Angles(math.rad(-45), math.rad(0), math.rad(0));
self.LeftElbowHighReady = CFrame.new(0,0, -0.1) * CFrame.Angles(math.rad(-15),math.rad(0),math.rad(0));

self.RightWristHighReady = CFrame.new(0,0,0) * CFrame.Angles(math.rad(0), math.rad(0), math.rad(0));
self.LeftWristHighReady = CFrame.new(0,0,0) * CFrame.Angles(math.rad(0),math.rad(-15),math.rad(0));

------//Low Ready Animations
self.RightLowReady = CFrame.new(-.9, 1.25, 0) * CFrame.Angles(math.rad(0), math.rad(0), math.rad(0));
self.LeftLowReady = CFrame.new(1,1,-0.6) * CFrame.Angles(math.rad(-45),math.rad(15),math.rad(-25));

self.RightElbowLowReady = CFrame.new(0,-0.45,-.25) * CFrame.Angles(math.rad(-80), math.rad(0), math.rad(0));
self.LeftElbowLowReady = CFrame.new(0,0,0)  * CFrame.Angles(math.rad(0), math.rad(0), math.rad(0));

self.RightWristLowReady = CFrame.new(0,0,0.15) * CFrame.Angles(math.rad(20), math.rad(0), math.rad(0));
self.LeftWristLowReady = CFrame.new(0,0,0)  * CFrame.Angles(math.rad(0), math.rad(0), math.rad(0));

------//Patrol Animations
self.RightPatrol = CFrame.new(-.85, 0.75, -1.3) * CFrame.Angles(math.rad(-30), math.rad(-90), math.rad(0));
self.LeftPatrol = CFrame.new(1.5,1.1,0) * CFrame.Angles(math.rad(0),math.rad(0),math.rad(0));

self.RightElbowPatrol = CFrame.new(0,-0.2,-.1) * CFrame.Angles(math.rad(-40), math.rad(0), math.rad(0));
self.LeftElbowPatrol = CFrame.new(0,-0.15,-0.25)  * CFrame.Angles(math.rad(-50), math.rad(0), math.rad(0));

self.RightWristPatrol = CFrame.new(0,0,0) * CFrame.Angles(math.rad(0), math.rad(0), math.rad(-15));
self.LeftWristPatrol = CFrame.new(0,0,0)  * CFrame.Angles(math.rad(0), math.rad(-90), math.rad(0));

------//Aim Animations
self.RightAim = CFrame.new(-.6, 0.85, -0.5) * CFrame.Angles(math.rad(-50), math.rad(0), math.rad(0));
self.LeftAim = CFrame.new(1.6,0.6,-0.85) * CFrame.Angles(math.rad(-95),math.rad(35),math.rad(-25));

self.RightElbowAim = CFrame.new(0,-0.2,-.25) * CFrame.Angles(math.rad(-60), math.rad(0), math.rad(0));
self.LeftElbowAim = CFrame.new(0,0,0)  * CFrame.Angles(math.rad(0), math.rad(0), math.rad(0));

self.RightWristAim = CFrame.new(0,0,0.15) * CFrame.Angles(math.rad(20), math.rad(0), math.rad(0));
self.LeftWristAim = CFrame.new(0,0,0)  * CFrame.Angles(math.rad(0), math.rad(0), math.rad(0));

------//Sprinting Animations
self.RightSprint = CFrame.new(-.9, 1.25, 0) * CFrame.Angles(math.rad(0), math.rad(0), math.rad(0));
self.LeftSprint = CFrame.new(1,1,-0.6) * CFrame.Angles(math.rad(-45),math.rad(15),math.rad(-25));

self.RightElbowSprint = CFrame.new(0,-0.45,-.25) * CFrame.Angles(math.rad(-80), math.rad(0), math.rad(0));
self.LeftElbowSprint = CFrame.new(0,0,0)  * CFrame.Angles(math.rad(0), math.rad(0), math.rad(0));

self.RightWristSprint = CFrame.new(0,0,0.15) * CFrame.Angles(math.rad(20), math.rad(0), math.rad(0));
self.LeftWristSprint = CFrame.new(0,0,0)  * CFrame.Angles(math.rad(0), math.rad(0), math.rad(0));

return self
