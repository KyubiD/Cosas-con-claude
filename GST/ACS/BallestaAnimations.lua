--==========================================================================
--  ACS_Animations de la BALLESTA  (ModuleScript "ACS_Animations" del Tool)
--  [03/10/2026]  Estilo Rust, con la misma base que el arco.
--
--  · Se sostiene como tu ballesta de siempre (las manos donde ya estaban),
--    pero el arma la mueve este script: posturas propias para reposo,
--    correr, patrulla, etc.
--  · Al disparar: el virote (Mag) desaparece y la cuerda se suelta hacia
--    adelante con una vibracion corta.
--  · Al recargar (R): inclina la ballesta, la mano derecha jala la cuerda
--    hasta el seguro, va por otro virote, lo trae en la mano, lo pone en el
--    riel y vuelve al mango.
--
--  Necesita el gancho "[BALLESTA 03/10]" del ACS_Framework (ShotFired, en
--  GunFx). Sin el, el virote no desaparece al disparar.
--
--  PIEZAS DEL MODELO (GunModels > la ballesta), por nombre:
--    Handle                 el mango (mano derecha)
--    Mag                    el virote (ver Ballesta.BoltNames)
--    Cuerda1 / Cuerda2      OPCIONAL: las dos mitades de la cuerda. En el
--                           modelo la cuerda esta SUELTA (recta de punta a
--                           punta); tensada = jalada hasta detras del Clip.
--    Clip                   el seguro donde se engancha la cuerda tensada
--    Side1 / Side2          OPCIONAL: las palas
--    LimiteCuerda1 / 2      OPCIONAL: la punta de cada pala
--  Sin cuerda, todo lo demas funciona igual (la mano hace el gesto).
--==========================================================================

local TS = game:GetService('TweenService')
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local self = {}

--  Las de tu ballesta: de aqui sale como se sostiene en reposo.
self.MainCFrame 	= CFrame.new(0.5,-.85,-0.75)

self.GunModelFixed 	= true
self.GunCFrame 		= CFrame.new(0.15, -.2, .85) * CFrame.Angles(math.rad(90),math.rad(0),math.rad(0))
self.LArmCFrame 	= CFrame.new(-.65,-0.15,-.35) * CFrame.Angles(math.rad(110),math.rad(15),math.rad(15))
self.RArmCFrame 	= CFrame.new(0.05,-0.15,1) * CFrame.Angles(math.rad(90),math.rad(0),math.rad(0))

--==========================================================================
--  AJUSTES
--
--  POSTURAS: cuanto se mueve / gira la ballesta respecto a como se sostiene
--  en reposo, girando sobre el mango (ejes de la camara):
--    Pos = Vector3(derecha, arriba, atras) en studs
--    Rot = Vector3(cabeceo, giro, inclinacion) en grados
--          cabeceo + = la punta sube; giro + = apunta a la izquierda;
--          inclinacion + = se ladea hacia la izquierda
--==========================================================================
self.Ballesta = {
	BoltNames = { "Mag", "Virote", "Flecha", "Arrow", "Bolt" },
	Poses = {
		Idle   = { Pos = Vector3.new(0, 0, 0),            Rot = Vector3.new(0, 0, 0) },
		Sprint = { Pos = Vector3.new(-0.25, -0.35, 0.15), Rot = Vector3.new(-25, 40, 25) },
		Low    = { Pos = Vector3.new(-0.10, -0.25, 0.05), Rot = Vector3.new(-20, 25, 15) },
		Patrol = { Pos = Vector3.new(-0.10, -0.25, 0.05), Rot = Vector3.new(-20, 25, 15) },
		High   = { Pos = Vector3.new(0, 0.10, 0),         Rot = Vector3.new(30, 10, -10) },
		Reload = { Pos = Vector3.new(-0.15, -0.10, 0.05), Rot = Vector3.new(12, 25, 22) },
		Check  = { Pos = Vector3.new(0, -0.05, -0.10),    Rot = Vector3.new(5, -30, -60) },
		Equip  = { Pos = Vector3.new(0.20, -1.20, 0.50),  Rot = Vector3.new(-60, 20, 30) },
	},
	PoseSpeed = 10,

	--  Cuerda tensada: jalada hasta el Clip. ClipBehind = true la deja justo
	--  detras del Clip (false = en su centro). Sin Clip: CockDistance studs
	--  (nil = CockFraction x el largo de punta a punta).
	ClipNames = { "Clip", "Seguro", "Latch" },
	ClipBehind = true,
	CockDistance = nil,
	CockFraction = 0.3,
	LimbBendDeg = 6,			-- palas Side1 / Side2 (si existen) al tensar
	FlipString = false,			-- true si al tensar la cuerda se va hacia adelante
	ReleaseStiffness = 1600,
	ReleaseDamping = 0.30,
	CockStiffness = 180,		-- al jalarla en la recarga (mas bajo = mas lento)
	ShotKickDeg = 4,			-- golpe extra hacia arriba al disparar

	--  Recarga (segundos desde que empieza).
	ReloadTilt = 0.30,			-- inclina la ballesta
	ReloadCockStart = 0.45,		-- la mano ya esta en la cuerda: empieza a jalar
	ReloadCocked = 0.80,		-- cuerda en el seguro
	ReloadFetch = 1.05,			-- la mano llega por el virote (aparece en la mano)
	ReloadSeat = 1.40,			-- virote puesto en el riel
	ReloadDone = 1.65,			-- mano de vuelta en el mango
	BoltFetchHand = Vector3.new(0.85, -1.10, 0.20),	-- donde va a buscar el virote (desde la camara)
	CarryTiltDeg = -15,			-- el virote en la mano, apuntando un poco hacia abajo

	ShoulderR = Vector3.new(0.85, -1.15, 0.6),		-- hombro derecho (desde la camara)
	HandLocal = Vector3.new(0, -0.85, 0),			-- la mano dentro de la pieza del brazo
	ArmSpeed = 22,
}

local function camPoint()
	return (self.MainCFrame:Inverse() * CFrame.new(0, 0, 0.5)).Position
end

--==========================================================================
--  RIG
--==========================================================================
local Rigs = {}

local function partsNamed(model, names)
	local set = {}
	for _, name in ipairs(names) do set[name] = true end
	local list = {}
	for _, item in ipairs(model:GetDescendants()) do
		if item:IsA("BasePart") and set[item.Name] then table.insert(list, item) end
	end
	return list
end

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
	local B = self.Ballesta
	local hInv = handle.CFrame:Inverse()
	local function rel(part) return hInv * part.CFrame end

	--  Hacia adelante: del mango al Muzzle (o, si no hay, al AimPart / -Z).
	local muzzle = handle:FindFirstChild("Muzzle")
	local forward = muzzle and muzzle:IsA("Attachment") and muzzle.Position or nil
	if not forward or forward.Magnitude < 0.05 then
		local aim = model:FindFirstChild("AimPart")
		forward = aim and aim:IsA("BasePart") and rel(aim).LookVector or Vector3.new(0, 0, -1)
	end
	forward = forward.Unit

	local rig = {
		model = model, handle = handle, objs = objs, forward = forward,
		pieces = {}, bolts = {},
		c = 1, v = 0, cTarget = 1,		-- c: 1 = cuerda tensada (en el Clip), 0 = suelta (como el modelo)
		n = 1,							-- virote: 0 = en la mano, 1 = en el riel
		phase = "idle", t = 0, stance = "Idle", kick = 0, kickV = 0,
	}

	--  Cuerda (opcional).
	local cuerda1, cuerda2 = partsNamed(model, { "Cuerda1" }), partsNamed(model, { "Cuerda2" })
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

	if #cuerda1 > 0 and #cuerda2 > 0 then
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
		if span.Magnitude > 0.05 then
			local axisUp = span.Unit
			--  D = hacia atras (hacia el tirador), perpendicular a la cuerda: del
			--  centro de la cuerda hacia el Clip. Distancia: hasta detras del Clip.
			local function perp(v) return v - axisUp * v:Dot(axisUp) end
			local clip = partsNamed(model, B.ClipNames)[1]
			local back, cockDist
			if clip then
				local clipCF = rel(clip)
				back = perp(clipCF.Position - nock)
				if back.Magnitude > 0.05 then
					local D0 = back.Unit
					cockDist = back.Magnitude
					if B.ClipBehind then
						local s = clip.Size
						local reach = math.abs(clipCF.RightVector:Dot(D0)) * s.X / 2
							+ math.abs(clipCF.UpVector:Dot(D0)) * s.Y / 2
							+ math.abs(clipCF.LookVector:Dot(D0)) * s.Z / 2
						cockDist += reach + 0.02
					end
				end
			end
			if not cockDist then
				back = perp(-forward)
				cockDist = B.CockDistance or span.Magnitude * B.CockFraction
			end
			if B.CockDistance then cockDist = B.CockDistance end
			local D = back.Magnitude > 0.01 and back.Unit or Vector3.new(0, 0, 1)
			if B.FlipString then D = -D end
			local center = (tipTop + tipBot) / 2
			local function hinge(dir)
				return center + dir * 0.1
			end
			rig.string = {
				nock = nock, tipTop = tipTop, tipBot = tipBot, D = D,
				cock = cockDist,
				hingeTop = hinge(axisUp), hingeBot = hinge(-axisUp),
				kTop = axisUp:Cross(D).Unit, kBot = (-axisUp):Cross(D).Unit,
			}
			for _, part in ipairs(partsNamed(model, { "Side1" })) do add(part, "top") end
			for _, part in ipairs(partsNamed(model, { "Side2" })) do add(part, "bot") end
			for _, part in ipairs(partsNamed(model, { "LimiteCuerda1" })) do add(part, "top") end
			for _, part in ipairs(partsNamed(model, { "LimiteCuerda2" })) do add(part, "bot") end
			for _, part in ipairs(cuerda1) do add(part, "str1") end
			for _, part in ipairs(cuerda2) do add(part, "str2") end
		end
	end

	--  Virote.
	for _, part in ipairs(partsNamed(model, B.BoltNames)) do
		add(part, "bolt")
		table.insert(rig.bolts, { part = part, transparency = part.Transparency })
	end
	--  Punto de atras del virote (donde lo agarra la mano / toca la cuerda).
	if #rig.bolts > 0 then
		local cf = rel(rig.bolts[1].part)
		local _, vector, half = longAxis(cf, rig.bolts[1].part.Size)
		local rear = cf.Position + vector * half
		local other = cf.Position - vector * half
		if (other - rear):Dot(forward) < 0 then rear = other end		-- el de atras
		rig.boltRear = rear
		rig.boltCenter = cf.Position
	end
	local str = rig.string
	--  Eje de lado a lado del arma (para inclinar el virote en la mano).
	local lateral = str and (str.tipTop - str.tipBot) or forward:Cross(Vector3.new(0, 1, 0))
	rig.lateral = lateral.Magnitude > 1e-3 and lateral.Unit or Vector3.new(1, 0, 0)
	rig.cockPoint = str and str.nock or rig.boltRear or forward * 1
	rig.backDir = str and str.D or -forward
	rig.cock = str and str.cock or (B.CockDistance or 0.6)

	--  Soldaduras propias para lo que se mueve: se apaga TODA soldadura que
	--  ate una pieza animada a otra cosa (Handle, otra pieza del modelo...),
	--  salvo a sus propias piezas hijas, que la siguen.
	local disabled = 0
	for _, joint in ipairs(model:GetDescendants()) do
		if joint:IsA("JointInstance") or joint:IsA("WeldConstraint") then
			local a, b = joint.Part0, joint.Part1
			local mine = animated[a] and a or (animated[b] and b) or nil
			if mine then
				local other = (mine == a) and b or a
				if not (other and other:IsDescendantOf(mine)) and joint.Enabled then
					joint.Enabled = false
					disabled += 1
				end
			end
		end
	end
	for _, piece in ipairs(rig.pieces) do
		local weld = Instance.new("Weld")
		weld.Name = "BallestaRig"
		weld.Part0 = handle
		weld.Part1 = piece.part
		weld.C0 = piece.rest
		weld.Parent = handle
		piece.weld = weld
	end

	--  Que se vea en Output que encontro (por si algo no se mueve).
	local count = { str1 = 0, str2 = 0, top = 0, bot = 0, bolt = 0 }
	for _, piece in ipairs(rig.pieces) do count[piece.kind] = (count[piece.kind] or 0) + 1 end
	print(string.format("[Ballesta] %s: Cuerda1 x%d, Cuerda2 x%d, Clip %s, virote x%d, palas %d/%d, cuerda %s (tensada se jala %.2f studs), %d soldaduras viejas apagadas",
		model.Name, count.str1, count.str2, partsNamed(model, B.ClipNames)[1] and "si" or "NO",
		count.bolt, count.top, count.bot, rig.string and "SI" or "NO", rig.cock or 0, disabled))
	if not rig.string then
		warn("[Ballesta] Sin cuerda animada: el modelo " .. model:GetFullName()
			.. " necesita piezas llamadas exactamente Cuerda1 y Cuerda2 (hijas directas del modelo en GunModels)")
	end
	return rig
end

--  Cuerda en la tension c (0 = suelta como el modelo, 1 = tensada en el
--  Clip; un poco menos de 0 al vibrar). Devuelve el punto de la cuerda
--  (espacio del Handle).
local function poseString(rig, c)
	local str = rig.string
	if not str then
		return rig.cockPoint - rig.backDir * rig.cock * (1 - c)
	end
	local B = self.Ballesta
	local x = c			-- 0 = como el modelo, 1 = tensada
	local flex = math.rad(B.LimbBendDeg) * x
	local rotTop = CFrame.fromAxisAngle(str.kTop, flex)
	local rotBot = CFrame.fromAxisAngle(str.kBot, flex)
	local function around(pivot, rot, cf) return CFrame.new(pivot) * rot * CFrame.new(-pivot) * cf end
	local tipTop = str.hingeTop + rotTop * (str.tipTop - str.hingeTop)
	local tipBot = str.hingeBot + rotBot * (str.tipBot - str.hingeBot)
	local nock = str.nock + str.D * str.cock * x
	local function stringFrame(oldTip, newTip)
		local r, n = str.nock - oldTip, nock - newTip
		return rotationBetween(r, n), n.Magnitude / math.max(r.Magnitude, 1e-4), n.Unit
	end
	local q1, k1, n1 = stringFrame(str.tipTop, tipTop)
	local q2, k2, n2 = stringFrame(str.tipBot, tipBot)
	for _, piece in ipairs(rig.pieces) do
		local kind = piece.kind
		local cf
		if kind == "top" then
			cf = around(str.hingeTop, rotTop, piece.rest)
		elseif kind == "bot" then
			cf = around(str.hingeBot, rotBot, piece.rest)
		elseif kind == "str1" or kind == "str2" then
			local q, k, n, oldTip, newTip = q1, k1, n1, str.tipTop, tipTop
			if kind == "str2" then q, k, n, oldTip, newTip = q2, k2, n2, str.tipBot, tipBot end
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
		if cf then piece.weld.C0 = cf end
	end
	return nock
end

local function setBoltVisible(rig, visible)
	for _, bolt in ipairs(rig.bolts) do
		bolt.part.Transparency = visible and bolt.transparency or 1
		for _, child in ipairs(bolt.part:GetDescendants()) do
			if child:IsA("Decal") or child:IsA("Texture") then child.Transparency = visible and 0 or 1 end
		end
	end
	rig.boltHidden = not visible
end

local function playSound(rig, name)
	local snd = rig.handle:FindFirstChild(name)
	if snd and snd:IsA("Sound") then snd:Play() end
end

--==========================================================================
--  POSTURAS Y MANOS
--==========================================================================
local function weldPose(weld) return weld.C0 * weld.C1:Inverse() end
local function setWeldPose(weld, pose) weld.C1 = pose:Inverse() * weld.C0 end

local function armPose(H, S)
	local up = S - H
	up = up.Magnitude > 1e-3 and up.Unit or Vector3.new(0, 1, 0)
	local right = Vector3.new(1, 0, 0) - up * up.X
	right = right.Magnitude > 1e-3 and right.Unit or up:Cross(Vector3.new(0, 0, 1)).Unit
	local back = right:Cross(up)
	local hl = self.Ballesta.HandLocal
	return CFrame.fromMatrix(H - (right * hl.X + up * hl.Y + back * hl.Z), right, up)
end

--  Como se sostiene en reposo (el Handle en el espacio de los brazos) y los
--  brazos respecto al arma: de las poses de tu ballesta.
local function restHandle() return self.RArmCFrame * self.GunCFrame:Inverse() end

local function placement(spec)
	local h0 = restHandle()
	local rot = spec.Rot or Vector3.zero
	return CFrame.new(h0.Position + (spec.Pos or Vector3.zero))
		* CFrame.Angles(math.rad(rot.X), math.rad(rot.Y), math.rad(rot.Z)) * rotOnly(h0)
end

local function lock(rig)
	if rig.locked then return end
	local h0 = restHandle()
	rig.armR = h0:Inverse() * self.RArmCFrame		-- brazo derecho respecto al arma
	rig.armL = h0:Inverse() * self.LArmCFrame		-- brazo izquierdo respecto al arma
	rig.place = placement(self.Ballesta.Poses.Equip)
	rig.r, rig.l = weldPose(rig.objs[1]), weldPose(rig.objs[2])
	rig.locked = true
	--  Equipada descargada: cuerda suelta y sin virote.
	local character = Players.LocalPlayer and Players.LocalPlayer.Character
	local tool = character and character:FindFirstChild(rig.model.Name)
	if tool and tool:IsA("Tool") and tool:GetAttribute("CurrentAmmo") == 0 then
		setBoltVisible(rig, false)
		rig.c, rig.cTarget = 0, 0
	end
end

local function step(rig, dt)
	local B = self.Ballesta
	if rig.phase == "reload" then rig.t += dt end

	--  Cuerda (resorte).
	local stiffness = (rig.phase == "reload") and B.CockStiffness or B.ReleaseStiffness
	local damping = (rig.phase == "reload") and 2 * math.sqrt(stiffness) or 2 * B.ReleaseDamping * math.sqrt(stiffness)
	local steps = math.max(1, math.ceil(dt / (1 / 240)))
	local h = dt / steps
	for _ = 1, steps do
		rig.v += (-stiffness * (rig.c - rig.cTarget) - damping * rig.v) * h
		rig.c += rig.v * h
		rig.kickV += (-260 * rig.kick - 2 * 0.7 * math.sqrt(260) * rig.kickV) * h
		rig.kick += rig.kickV * h
	end
	local shown = math.clamp(rig.c, -0.15, 1.1)
	local nock = poseString(rig, shown)

	--  Donde va la ballesta.
	local spec = B.Poses[rig.stance] or B.Poses.Idle
	rig.place = rig.place:Lerp(placement(spec), 1 - math.exp(-B.PoseSpeed * dt))
	local gun = rig.place
	if math.abs(rig.kick) > 1e-4 then
		gun = CFrame.new(gun.Position) * CFrame.Angles(math.rad(B.ShotKickDeg * rig.kick), 0, 0) * rotOnly(gun)
	end

	--  Manos: la izquierda siempre agarrando el arma; la derecha en el mango
	--  salvo en la recarga.
	local cam = camPoint()
	local rightTarget = gun * rig.armR
	local t = rig.t
	if rig.phase == "reload" then
		local function ik(point) return armPose(point, cam + B.ShoulderR) end
		if t >= B.ReloadTilt and t < B.ReloadCocked + 0.05 then
			--  A la cuerda y jalarla hasta el seguro.
			if t >= B.ReloadCockStart then rig.cTarget = 1 end
			rightTarget = ik(gun * nock)
			if t >= B.ReloadCocked and not rig.cockedSound then
				rig.cockedSound = true
				playSound(rig, "AimUp")
			end
		elseif t >= B.ReloadCocked + 0.05 and t < B.ReloadFetch then
			rightTarget = ik(cam + B.BoltFetchHand)
		elseif t >= B.ReloadFetch and t < B.ReloadSeat then
			if rig.boltHidden then
				rig.n = 0
				setBoltVisible(rig, true)
			end
			local seatAt = gun * (rig.boltRear or rig.cockPoint)
			rightTarget = ik(seatAt)
			local k = math.clamp((t - (B.ReloadFetch + 0.12)) / math.max(B.ReloadSeat - B.ReloadFetch - 0.12, 0.05), 0, 1)
			rig.n = k
		elseif t >= B.ReloadSeat then
			if rig.n < 1 or not rig.seatedSound then
				rig.n = 1
				rig.seatedSound = true
				playSound(rig, "MagIn")
			end
		end
	end
	local alpha = 1 - math.exp(-B.ArmSpeed * dt)
	rig.r = rig.r:Lerp(rightTarget, alpha)
	rig.l = rig.l:Lerp(gun * rig.armL, alpha)

	--  El virote: en el riel (n = 1) o en la mano derecha (n = 0).
	if #rig.bolts > 0 and rig.boltRear then
		local handInGun = gun:Inverse() * (rig.r * B.HandLocal)
		local tilt = CFrame.fromAxisAngle(rig.lateral, math.rad(B.CarryTiltDeg))
		local carry = CFrame.new(handInGun) * tilt * CFrame.new(-rig.boltRear)
		local n = rig.n * rig.n * (3 - 2 * rig.n)
		for _, piece in ipairs(rig.pieces) do
			if piece.kind == "bolt" then
				piece.weld.C0 = (carry * piece.rest):Lerp(piece.rest, n)
			end
		end
	end

	local rArm, lArm, gunWeld = rig.objs[1], rig.objs[2], rig.objs[3]
	setWeldPose(rArm, rig.r)
	setWeldPose(lArm, rig.l)
	gunWeld.C0 = rig.r:Inverse() * gun * gunWeld.C1
end

local function getRig(objs)
	local model = objs and objs[4]
	if not model then return nil end
	local rig = Rigs[model]
	if rig == nil then
		local ok, result = pcall(buildRig, objs)
		if not ok then warn("[Ballesta] " .. tostring(result)) end
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
					warn("[Ballesta] " .. tostring(err))
				end
			end)
		end
	end
	return rig or nil
end

--==========================================================================
--  DISPARO (gancho ShotFired del ACS_Framework)
--==========================================================================
self.ShotFired = function(objs)
	local rig = getRig(objs)
	if not rig then return end
	setBoltVisible(rig, false)			-- el virote salio
	rig.cTarget = 0						-- la cuerda se suelta hacia adelante
	rig.kickV += 9						-- golpe hacia arriba
end

--==========================================================================
--  ANIMACIONES DE ACS
--==========================================================================
local function stance(objs, name, waitTime)
	local rig = getRig(objs)
	if rig then rig.stance = name end
	if waitTime then task.wait(waitTime) end
end

self.EquipAnim = function(objs) stance(objs, "Idle", 0.45) end;
self.IdleAnim = function(objs) stance(objs, "Idle") end;
self.LowReady = function(objs) stance(objs, "Low", 0.25) end;
self.HighReady = function(objs) stance(objs, "High", 0.25) end;
self.Patrol = function(objs) stance(objs, "Patrol", 0.25) end;
self.SprintAnim = function(objs) stance(objs, "Sprint", 0.25) end;

self.ReloadAnim = function(objs)
	local rig = getRig(objs)
	local B = self.Ballesta
	if not rig then
		--  Sin rig: solo esconder y volver a mostrar el virote.
		local bolt = objs[4]:FindFirstChild("Mag")
		task.wait(0.8)
		if bolt then bolt.Transparency = 0 end
		task.wait(0.4)
		return
	end
	local before = rig.stance
	rig.stance = "Reload"
	rig.phase, rig.t = "reload", 0
	rig.cockedSound, rig.seatedSound = false, false
	if not rig.boltHidden then setBoltVisible(rig, false) end	-- recarga tactica: se cambia el virote
	rig.cTarget = rig.c								-- la cuerda espera a la mano
	playSound(rig, "MagOut")
	task.wait(B.ReloadDone)
	rig.n, rig.cTarget = 1, 1
	if rig.boltHidden then setBoltVisible(rig, true) end
	rig.phase = "idle"
	if rig.stance == "Reload" then rig.stance = (before ~= "Reload") and before or "Idle" end
	task.wait(0.15)
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
self.__BallestaTest = { build = buildRig, step = step, lock = lock, rigs = Rigs, poseString = poseString }

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
