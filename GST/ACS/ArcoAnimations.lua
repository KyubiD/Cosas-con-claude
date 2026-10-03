--==========================================================================
--  ACS_Animations del ARCO  (ModuleScript "ACS_Animations" dentro del Tool)
--  [03/10/2026]  Estilo Rust.
--
--  El arco va SIEMPRE en la mano izquierda (en el Handle) y la mano derecha
--  SIEMPRE en la cuerda, con la flecha (Mag). Todo se calcula cada frame
--  con la forma real del modelo, asi que no hay poses de brazos a mano:
--    · En reposo / corriendo / patrulla el arco va abajo a la izquierda e
--      inclinado.
--    · Al cargar (modo de disparo 6) el arco sube al centro con la flecha
--      apuntando a la mira; la cuerda y la flecha van hacia atras segun el
--      PORCENTAJE de carga (si el porcentaje baja, regresan suave), las
--      palas se doblan y la mano derecha jala hasta la mejilla.
--    · Al disparar la cuerda vuelve de golpe y vibra, la flecha desaparece
--      y la mano derecha se suelta hacia atras.
--    · Al recargar la mano derecha va por otra flecha y la pone en la cuerda.
--
--  Necesita los ganchos del ACS_Framework (busca "[ARCO 03/10]"):
--    self.ChargeProgress(objs, ratio, dt)  cada frame mientras cargas
--    self.ChargeShot(objs)                 al disparar
--    self.ChargeRelease(objs)              al soltar / cancelar
--
--  PIEZAS DEL MODELO (GunModels > Arco), por nombre:
--    Handle                 donde va la mano izquierda (la empunadura)
--    Cuerda1 / Cuerda2      las dos mitades de la cuerda (arriba / abajo)
--    Side1 / Side2          las palas de arriba / abajo
--    LimiteCuerda1 / 2      la punta de cada pala donde se amarra la cuerda
--    Mag                    la flecha (ver Bow.ArrowNames)
--==========================================================================

local TS = game:GetService('TweenService')
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local self = {}

--  El arco no usa las poses fijas de ACS: con MainCFrame en cero el punto
--  de los brazos queda justo frente a la camara (0.5 studs) y las poses de
--  abajo se miden desde la camara.
self.MainCFrame 	= CFrame.new()

self.GunModelFixed 	= true
self.GunCFrame 		= CFrame.new(0.15, -.2, .85) * CFrame.Angles(math.rad(90),math.rad(0),math.rad(0))
self.LArmCFrame 	= CFrame.new(-.65,-0.15,-.35) * CFrame.Angles(math.rad(110),math.rad(15),math.rad(15))
self.RArmCFrame 	= CFrame.new(0.05,-0.15,1) * CFrame.Angles(math.rad(90),math.rad(0),math.rad(0))

--==========================================================================
--  AJUSTES DEL ARCO
--
--  Las POSES dicen donde queda el punto de la cuerda TENSADA del todo
--  (donde va la mano derecha a carga completa), medido desde la camara:
--    Pos = Vector3(derecha, arriba, atras)   (Z negativo = hacia adelante)
--    Rot = Vector3(cabeceo, giro, inclinacion) en grados
--          cabeceo +      la punta de la flecha sube
--          giro +         la flecha apunta mas a la izquierda
--          inclinacion -  la parte de arriba del arco se va a la derecha
--  El arco entero se acomoda solo a partir de ese punto.
--==========================================================================
self.Bow = {
	--  Cuanto se va la cuerda hacia atras con la carga completa, en studs.
	--  nil = DrawFraction x el largo del arco (punta a punta).
	DrawDistance = nil,
	DrawFraction = 0.42,
	LimbBendDeg = 8,			-- grados que se dobla cada pala a carga completa
	FlipDraw = false,			-- true si la cuerda se va hacia adelante en vez de hacia ti
	ArrowNames = { "Mag", "Flecha", "Arrow" },

	--  Cargando: la mano derecha en la mejilla y la flecha apuntando a la
	--  mira (a Converge studs).
	Aim = { Pos = Vector3.new(0.08, -0.28, -0.25), Roll = -6, Converge = 60 },
	Poses = {
		Idle   = { Pos = Vector3.new(-0.20, -0.95, -0.15), Rot = Vector3.new(-8, 14, -32) },
		Sprint = { Pos = Vector3.new(-0.15, -1.30,  0.10), Rot = Vector3.new(-35, 32, -55) },
		Low    = { Pos = Vector3.new(-0.15, -1.15,  0.00), Rot = Vector3.new(-25, 25, -45) },
		Patrol = { Pos = Vector3.new(-0.15, -1.15,  0.00), Rot = Vector3.new(-25, 25, -45) },
		High   = { Pos = Vector3.new(-0.15, -0.45, -0.20), Rot = Vector3.new(30, 10, -22) },
		Reload = { Pos = Vector3.new(-0.30, -1.05, -0.20), Rot = Vector3.new(-5, 20, -48) },
		Check  = { Pos = Vector3.new(-0.05, -0.70, -0.40), Rot = Vector3.new(10, -35, -75) },
		Equip  = { Pos = Vector3.new(-0.30, -2.40,  0.40), Rot = Vector3.new(-60, 35, -65) },
	},
	PoseSpeed = 9,				-- rapidez entre posturas
	RaiseSpeed = 11,			-- rapidez con la que sube a apuntar al cargar
	HoldAfterShot = 0.35,		-- segundos que se queda arriba despues de disparar

	--  Hombros (desde la camara): de ahi salen los brazos hacia cada mano.
	ShoulderR = Vector3.new(0.85, -1.15, 0.6),
	ShoulderL = Vector3.new(-0.85, -1.15, 0.6),
	HandLocal = Vector3.new(0, -0.85, 0),	-- la mano dentro de la pieza del brazo
	--  Desfase de cada mano (studs; X = a la derecha del arco, Y = arriba,
	--  Z = hacia ti). La derecha un poco abajo de la flecha, como en Rust.
	RightHandOffset = Vector3.new(0.04, -0.10, 0.05),
	LeftHandOffset = Vector3.new(0, 0, 0),
	ArmSpeed = 26,

	--  Resorte de la cuerda. Draw: siguiendo el porcentaje (sube o baja
	--  suave). Release: al disparar (rapido; Damping mas bajo = vibra mas).
	DrawStiffness = 140,
	ReleaseStiffness = 1600,
	ReleaseDamping = 0.30,
	ReleaseOvershoot = 0.10,		-- maximo que la cuerda se pasa hacia adelante al vibrar (fraccion del jalon)
	CancelStiffness = 90,
	ReleaseFollowThrough = 0.30,	-- la mano derecha se va hacia atras al soltar

	--  Recarga: la mano derecha va por una flecha (desde la camara) y vuelve.
	QuiverHand = Vector3.new(0.75, -0.75, 0.55),
	ReloadReach = 0.35,
	ReloadBack = 0.40,
}

--  La camara en el espacio de los brazos (ACS: AnimPart = camara * NearZ *
--  MainCFrame, con NearZ = 0.5 studs hacia adelante).
local function camPoint()
	return (self.MainCFrame:Inverse() * CFrame.new(0, 0, 0.5)).Position
end

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

--  Eje mas largo de una pieza (1 = X, 2 = Y, 3 = Z), su vector y medio largo.
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
			warn("[Arco] No encontre Cuerda1 / Cuerda2 en " .. model:GetFullName() .. ": sin animacion de arco")
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

	--  La mano izquierda va en el Handle. Hacia donde se jala la cuerda: del
	--  Handle hacia la cuerda (hacia el arquero).
	local grip = Vector3.zero
	local function perpTo(v) return v - axisUp * v:Dot(axisUp) end
	local perp = perpTo(nock - grip)
	if perp.Magnitude < 0.05 and #guards > 0 then
		local avg = Vector3.zero
		for _, part in ipairs(guards) do avg += rel(part).Position end
		perp = perpTo(nock - avg / #guards)
	end
	local D
	if perp.Magnitude > 0.05 then
		D = perp.Unit
	else
		local animPart = objs[5] and objs[5].PrimaryPart
		local back = animPart and handle.CFrame:VectorToObjectSpace(-animPart.CFrame.LookVector) or Vector3.new(0, 0, 1)
		back = perpTo(back)
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
	local drawDist = B.DrawDistance or span.Magnitude * B.DrawFraction

	local rig = {
		model = model, handle = handle, objs = objs,
		nock = nock, tipTop = tipTop, tipBot = tipBot, axisUp = axisUp, D = D, grip = grip,
		drawDist = drawDist,
		hingeTop = hinge(side1, topDir), hingeBot = hinge(side2, -topDir),
		kTop = topDir:Cross(D).Unit, kBot = (-topDir):Cross(D).Unit,
		--  Marco del arco: origen = donde queda la cuerda a carga completa,
		--  Y = a lo largo de la cuerda (hacia arriba), Z = hacia el arquero.
		frame = CFrame.fromMatrix(nock + D * drawDist, topDir:Cross(D), topDir),
		pieces = {}, arrows = {},
		x = 0, v = 0, target = 0, mode = "draw",
		phase = "idle", t = 0, aim = 0, stance = "Idle",
	}
	rig.frameInv = rig.frame:Inverse()

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
	--  propia (las de ACS / del modelo entre estas piezas se apagan para que
	--  no peleen). Lo que cuelga de una pieza (no hijo directo del modelo)
	--  sigue soldado a ella.
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
--  poco negativo justo despues de soltar, por la vibracion). Devuelve
--  donde quedo el punto de la cuerda (espacio del Handle).
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
			cf = CFrame.new(shift) * piece.rest		-- la flecha va con la cuerda
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
--  POSTURAS Y MANOS
--==========================================================================
local function weldPose(weld) return weld.C0 * weld.C1:Inverse() end
local function setWeldPose(weld, pose) weld.C1 = pose:Inverse() * weld.C0 end

--  Pose del brazo con la mano en H, apuntando hacia el hombro S.
local function armPose(H, S)
	local up = S - H
	up = up.Magnitude > 1e-3 and up.Unit or Vector3.new(0, 1, 0)
	local right = Vector3.new(1, 0, 0) - up * up.X
	right = right.Magnitude > 1e-3 and right.Unit or up:Cross(Vector3.new(0, 0, 1)).Unit
	local back = right:Cross(up)
	local hl = self.Bow.HandLocal
	return CFrame.fromMatrix(H - (right * hl.X + up * hl.Y + back * hl.Z), right, up)
end

--  Donde va el marco del arco en una postura (espacio de los brazos).
local function poseFrame(spec)
	local rot = spec.Rot or Vector3.zero
	return CFrame.new(camPoint() + spec.Pos)
		* CFrame.Angles(math.rad(rot.X), math.rad(rot.Y), math.rad(rot.Z))
end

--  Apuntando: la flecha hacia la mira.
local function aimFrame()
	local A = self.Bow.Aim
	local cam = camPoint()
	local from = cam + A.Pos
	local to = cam + Vector3.new(0, 0, -(A.Converge or 60))
	return CFrame.lookAt(from, to) * CFrame.Angles(0, 0, math.rad(A.Roll or 0))
end

local function lock(rig)
	if rig.locked then return end
	rig.stanceCF = poseFrame(self.Bow.Poses.Equip)
	rig.r, rig.l = weldPose(rig.objs[1]), weldPose(rig.objs[2])
	rig.locked = true
	--  Equipada sin flecha (se guardo con 0 balas): sin flecha en la cuerda.
	local character = Players.LocalPlayer and Players.LocalPlayer.Character
	local tool = character and character:FindFirstChild(rig.model.Name)
	if tool and tool:IsA("Tool") and tool:GetAttribute("CurrentAmmo") == 0 then
		setArrowVisible(rig, false)
	end
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
	local steps = math.max(1, math.ceil(dt / (1 / 240)))
	local h = dt / steps
	for _ = 1, steps do
		rig.v += (-stiffness * (rig.x - rig.target) - damping * rig.v) * h
		rig.x += rig.v * h
	end
	if rig.target == 0 and math.abs(rig.x) < 1e-4 and math.abs(rig.v) < 1e-4 then rig.x, rig.v = 0, 0 end
	--  Al vibrar, la cuerda se pasa poco hacia adelante (curva suave).
	local shown = rig.x
	if shown < 0 then
		local limit = B.ReleaseOvershoot
		shown = -limit * (1 - math.exp(shown / math.max(limit, 1e-3)))
	end
	local nock = poseRig(rig, shown)
	if not rig.locked then return end
	rig.t += dt

	--  Donde va el arco: la postura y, mientras se carga, sube a apuntar.
	local raising = rig.phase == "draw" or (rig.phase == "release" and rig.t < B.HoldAfterShot)
	rig.aim += ((raising and 1 or 0) - rig.aim) * (1 - math.exp(-B.RaiseSpeed * dt))
	local spec = B.Poses[rig.stance] or B.Poses.Idle
	rig.stanceCF = rig.stanceCF:Lerp(poseFrame(spec), 1 - math.exp(-B.PoseSpeed * dt))
	local a = rig.aim * rig.aim * (3 - 2 * rig.aim)
	local bow = rig.stanceCF:Lerp(aimFrame(), a) * rig.frameInv		-- el Handle en el espacio de los brazos

	--  Manos: izquierda en el Handle, derecha en la cuerda.
	local cam = camPoint()
	local function frameVec(v) return rig.frame:VectorToWorldSpace(v) end
	local leftHand = bow * (rig.grip + frameVec(B.LeftHandOffset))
	local rightHand = bow * (nock + frameVec(B.RightHandOffset))
	if rig.phase == "release" and rig.t < 0.2 then
		rightHand += bow:VectorToWorldSpace(rig.D * B.ReleaseFollowThrough + frameVec(Vector3.new(0.12, 0, 0)))
	elseif rig.phase == "reload" then
		if rig.t < B.ReloadReach then
			rightHand = cam + B.QuiverHand
		elseif rig.arrowHidden then
			setArrowVisible(rig, true)
			local snd = rig.handle:FindFirstChild("MagIn")
			if snd and snd:IsA("Sound") then snd:Play() end
		end
	end
	local speed = (rig.phase == "draw") and B.ArmSpeed * 1.6 or B.ArmSpeed
	local alpha = 1 - math.exp(-speed * dt)
	rig.r = rig.r:Lerp(armPose(rightHand, cam + B.ShoulderR), alpha)
	rig.l = rig.l:Lerp(armPose(leftHand, cam + B.ShoulderL), alpha)

	local rArm, lArm, gunWeld = rig.objs[1], rig.objs[2], rig.objs[3]
	setWeldPose(rArm, rig.r)
	setWeldPose(lArm, rig.l)
	gunWeld.C0 = rig.r:Inverse() * bow * gunWeld.C1		-- el arco va donde se calculo, no pegado a la mano derecha

	if (rig.phase == "release" or rig.phase == "cancel") and rig.t > B.HoldAfterShot + 0.2 then
		rig.phase = "idle"
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
			lock(rig)
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
		rig.phase, rig.t, rig.mode = "draw", 0, "draw"
		if rig.arrowHidden then setArrowVisible(rig, true) end	-- si cargas, hay flecha
	end
	rig.target = math.clamp(ratio, 0, 1)		-- sube o baja: el resorte lo sigue suave
end

--  Disparo: lo llama el gancho ChargeShot del framework (siempre) y el
--  ChargeFireAnim de siempre (si FireAnimLoop no esta en false). El segundo
--  que llega no hace nada.
self.ChargeShot = function(objs)
	local rig = getRig(objs)
	if not rig then return end
	if rig.phase == "release" and rig.t < 0.1 then return end
	rig.phase, rig.t, rig.mode, rig.target = "release", 0, "release", 0
	setArrowVisible(rig, false)		-- la flecha salio volando
end
self.ChargeFireAnim = self.ChargeShot

--  Soltar sin disparar (despues de disparar no hace nada).
self.ChargeRelease = function(objs)
	local rig = getRig(objs)
	if not rig or rig.phase ~= "draw" then return end
	rig.phase, rig.t, rig.mode, rig.target = "cancel", 0, "cancel", 0
end

--==========================================================================
--  ANIMACIONES DE ACS: solo cambian la postura (el rig hace el resto).
--  Si el modelo no tiene Cuerda1 / Cuerda2 se usan las de la ballesta.
--==========================================================================
local function stance(objs, name, waitTime, fallback)
	local rig = getRig(objs)
	if rig then
		rig.stance = name
		if waitTime then task.wait(waitTime) end
	elseif fallback then
		fallback()
	end
end

self.EquipAnim = function(objs)
	stance(objs, "Idle", 0.45, function()
		TS:Create(objs[1], TweenInfo.new(.25,Enum.EasingStyle.Linear), {C1 = (CFrame.new(1,-1,1)):inverse() }):Play()
		TS:Create(objs[2], TweenInfo.new(.25,Enum.EasingStyle.Linear), {C1 = (CFrame.new(-1,-1,1)):inverse() }):Play()
		task.wait(.25)
		TS:Create(objs[1], TweenInfo.new(.35,Enum.EasingStyle.Sine), {C1 = self.RArmCFrame:Inverse()}):Play()
		TS:Create(objs[2], TweenInfo.new(.35,Enum.EasingStyle.Sine), {C1 = self.LArmCFrame:Inverse()}):Play()
		task.wait(.35)
	end)
end;

self.IdleAnim = function(objs)
	stance(objs, "Idle", nil, function()
		TS:Create(objs[1], TweenInfo.new(.25,Enum.EasingStyle.Sine), {C1 = self.RArmCFrame:Inverse()}):Play()
		TS:Create(objs[2], TweenInfo.new(.25,Enum.EasingStyle.Sine), {C1 = self.LArmCFrame:Inverse()}):Play()
	end)
end;

self.LowReady = function(objs) stance(objs, "Low", 0.25) end;
self.HighReady = function(objs) stance(objs, "High", 0.25) end;
self.Patrol = function(objs) stance(objs, "Patrol", 0.25) end;
self.SprintAnim = function(objs) stance(objs, "Sprint", 0.25) end;

--  Recarga: la mano derecha va por una flecha y la pone en la cuerda.
self.ReloadAnim = function(objs)
	local rig = getRig(objs)
	local B = self.Bow
	local handle = objs[4]:FindFirstChild("Handle")
	local outSnd = handle and handle:FindFirstChild("MagOut")
	if outSnd and outSnd:IsA("Sound") then outSnd:Play() end
	if not rig then
		task.wait(B.ReloadReach + B.ReloadBack)
		for _, part in ipairs(partsNamed(objs[4], B.ArrowNames)) do part.Transparency = 0 end
		return
	end
	local before = rig.stance
	rig.stance = "Reload"
	rig.phase, rig.t, rig.mode, rig.target = "reload", 0, "cancel", 0
	task.wait(B.ReloadReach + B.ReloadBack)
	if rig.arrowHidden then setArrowVisible(rig, true) end
	if rig.phase == "reload" then rig.phase = "idle" end
	if rig.stance == "Reload" then rig.stance = (before ~= "Reload") and before or "Idle" end
end;

self.TacticalReloadAnim = function(objs)
	self.ReloadAnim(objs)
end;

self.JammedAnim = function(objs)
	task.wait(0.25)
end;

self.PumpAnim = function(objs)

end;

--  Revisar: se gira el arco para verlo y vuelve.
self.MagCheck = function(objs)
	local rig = getRig(objs)
	if not rig then task.wait(1) return end
	local before = rig.stance
	rig.stance = "Check"
	task.wait(2)
	if rig.stance == "Check" then rig.stance = (before ~= "Check") and before or "Idle" end
end;

self.meleeAttack = function(objs)

end;

self.GrenadeReady = function(objs)

end;

self.GrenadeThrow = function(objs)

end;

--  Solo para pruebas fuera de Roblox.
self.__ArcoTest = { build = buildRig, pose = poseRig, rigs = Rigs, step = step, lock = lock }

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
