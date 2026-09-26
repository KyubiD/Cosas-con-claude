--==========================================================================
--  BotConfig  —  ServerStorage.BotSystem  (23/09/2026)
--
--  Todo lo ajustable de los bots (jugadores falsos) vive aqui. Lo leen
--  BotServer (IA, armas, movimiento) y BotRegistry.
--
--  Los bots se agregan desde el panel de admin (F4 > BOTS). Entran a la
--  partida como un jugador que acaba de llegar: el RoundManager decide su
--  equipo, sus vidas y cuando quedan eliminados, igual que con cualquiera.
--
--  PUNTERIA: todos los errores estan en GRADOS. Como referencia, a 50
--  studs 1 grado de error son ~0.9 studs de desvio; un torso mide ~2.
--==========================================================================
local BotConfig = {}

BotConfig.Debug = false

--  Tope de bots por servidor (el boton del panel no deja pasar de aqui).
BotConfig.MaxBots = 45

--==========================================================================
--  NOMBRES  (se arman al azar y nunca se repiten en el mismo servidor)
--==========================================================================
BotConfig.Names = {
	First = {
		"Diego", "Mateo", "Santi", "Valeria", "Sofi", "Camila", "Emi", "Leo",
		"Alex", "Chris", "Jose", "Luis", "Fer", "Ana", "Pau", "Dani", "Maxi",
		"Juan", "Emilio", "Regina", "Ximena", "Andy", "Jake", "Ethan", "Noah",
		"Liam", "Mia", "Zoe", "Kevin", "Brayan", "Iker", "Aitana", "Tomas",
		"Lucas", "Nico", "Isa", "Renata", "Hugo", "Axel", "Kenia", "Timmy", "Tilin",
		"Javi", "Jorge", "Miguel", "Carlos", "Roberto", "Joaquin", "Pablo",
		"Gabriel", "Martin", "Beni", "Julieta", "Nahuel", "Tomi", "Peña nieto", "Yucateco",
		"Andres", "Andres manuel", "Amlo", "Claudia", "Little Jeff", "Jeffrey","Piratita", 
		"Mexican", "Mauu", "Nicolas", "Maduro", "Soap", "Ghost", "Nikolai", "Crystal", "Luna"
		,"El pepe","XxJuanito", "Juanito"
	},
	Words = {
		"Gamer", "Pro", "Noob", "Shadow", "Ninja", "Tacos", "Pollo", "Dragon",
		"Wolf", "Sniper", "Ghost", "Bacon", "Pixel", "Toxic", "King", "Queen",
		"Rayo", "Lobo", "Gato", "Panda", "Chido", "Crack", "Legend", "Blaze",
		"Storm", "Frost", "Venom", "Rex", "Titan", "Loco", "Tryhard", "Sweaty",
		"Chill", "Nova", "Viper", "Cobra", "Zorro", "Kaiju", "Mango", "Churro",
		"Patata", "Tactico", "Del diavlo", "Espacial", "Morado", "Colombiano", "Peruano",
		"Pobre", "Sparda"
	},
	Tags = { "YT", "MX", "GG", "xd", "OP", "HD", "TTV", "uwu", "EZ", "Real", "xX",":3", "Furry",".///." },
}

--==========================================================================
--  AVATAR  (ropa y pelo gratis de Roblox, colores de piel por defecto)
--  Se puede agregar cualquier ID de catalogo a estas listas.
--==========================================================================
BotConfig.Avatar = {
	Shirts = {
		855777286,		-- Roblox Purple Shirt
		855766176,		-- Roblox Green Shirt
		855768342,		-- Roblox Orange Shirt
		855779323,		-- Roblox Yellow Shirt
		144076436,		-- Grey Striped Shirt with Denim Jacket
		398633584,		-- Denim Jacket with White Hoodie
		4047884939,		-- My Favorite Pizza Shirt
		4047884046,		-- Guitar Tee with Black Jacket
		382538059,		-- Green Jersey
		382537702,		-- Teal Shirt
	},
	Pants = {
		855782781,		-- Roblox Purple Shorts
		855785499,		-- Roblox Yellow Shorts
		144076760,		-- Dark Green Jeans
		398635338,		-- Ripped Skater Pants
		382537569,		-- Black Jeans
		382538503,		-- Black Jeans with Sneakers
	},
	Hair = {
		63690008,		-- Pal Hair
		451220849,		-- Lavender Updo
		376548738,		-- Brown Charmer Hair
		376524487,		-- Blonde Spiked Hair
		62724852,		-- Chestnut Bun
		451221329,		-- True Blue Hair
		62743701,		-- Stylish Brown Hair
	},
	Faces = {
		144075659,		-- Smile
		7074764,		-- Chill
		7699174,		-- Silly Fun
		20418658,		-- Err...
	},
	HairChance = 0.8,

	--  Algunos bots salen "clasicos": sin ropa, solo colores lisos, como
	--  el avatar por defecto de antes (cabeza amarilla, torso azul...).
	ClassicChance = 0.2,
	Classic = {
		{ Head = Color3.fromRGB(245, 205, 48), Torso = Color3.fromRGB(13, 105, 172), Legs = Color3.fromRGB(164, 189, 71) },
		{ Head = Color3.fromRGB(245, 205, 48), Torso = Color3.fromRGB(196, 40, 28), Legs = Color3.fromRGB(13, 105, 172) },
		{ Head = Color3.fromRGB(234, 184, 146), Torso = Color3.fromRGB(27, 42, 53), Legs = Color3.fromRGB(99, 95, 98) },
	},

	--  [25/09] Sin el amarillo "noob" (ese queda solo en los Classic) para que
	--  los bots se vean mas humanos.
	SkinTones = {
		Color3.fromRGB(255, 219, 172), Color3.fromRGB(255, 204, 153), Color3.fromRGB(234, 184, 146),
		Color3.fromRGB(224, 172, 128), Color3.fromRGB(204, 142, 105), Color3.fromRGB(175, 125, 95),
		Color3.fromRGB(141, 101, 76), Color3.fromRGB(124, 92, 70), Color3.fromRGB(86, 66, 54),
	},

	--======================================================================
	--  ESTILOS  [25/09]  (uno al azar por bot, con estos pesos)
	--
	--  El uniforme es el color del cuerpo con textura de tela y el equipo
	--  son piezas pegadas al cuerpo (no hace falta ningun ID del catalogo).
	--  Las piezas no chocan ni frenan balas: la hitbox es la de siempre.
	--
	--  Kind      "Militar", "Civil" o "Clasico" (el avatar liso de antes).
	--  Top / Bottom   colores de la parte de arriba (torso y mangas) y de
	--                 las piernas. Uno al azar de cada lista.
	--  Camo      colores de las manchas de camuflaje (vacio = liso).
	--  Vest      color del chaleco / mochila / cinturon (y del casco si no
	--            hay HeadgearColors).
	--  Headgear  { Tipo = peso }: Casco, Gorra, Gorro, Boonie, Boina, Ninguno.
	--  Gear      probabilidad (0-1) de cada pieza: Chaleco, Mochila,
	--            Cinturon, Rodilleras, Guantes, Pasamontanas, Bufanda,
	--            Auriculares, Gafas, VisionNocturna (soporte en el casco).
	--  Gloves / Boots / MaskColors / ScarfColors   colores de esas piezas.
	--  HairChance     pelo (solo si no lleva nada en la cabeza).
	--  Civil: CatalogChance = prob. de usar Shirts/Pants de arriba en vez
	--         de ropa lisa; ShortSleeveChance = remera de manga corta.
	--======================================================================
	Styles = {
		{ Name = "Civil", Kind = "Civil", Weight = 26,
			CatalogChance = 0.45, ShortSleeveChance = 0.55, HairChance = 0.85,
			Top = {
				Color3.fromRGB(35, 35, 38), Color3.fromRGB(235, 235, 235), Color3.fromRGB(120, 30, 35),
				Color3.fromRGB(40, 60, 110), Color3.fromRGB(95, 95, 100), Color3.fromRGB(70, 90, 60),
				Color3.fromRGB(190, 160, 120), Color3.fromRGB(150, 60, 30), Color3.fromRGB(60, 45, 80),
				Color3.fromRGB(230, 200, 90), Color3.fromRGB(45, 110, 120),
			},
			Bottom = {
				Color3.fromRGB(45, 60, 95), Color3.fromRGB(60, 80, 120), Color3.fromRGB(30, 30, 32),
				Color3.fromRGB(170, 150, 115), Color3.fromRGB(85, 85, 90), Color3.fromRGB(70, 60, 50),
			},
			Boots = { Color3.fromRGB(240, 240, 240), Color3.fromRGB(25, 25, 25), Color3.fromRGB(110, 75, 50), Color3.fromRGB(90, 90, 95) },
			Vest = { Color3.fromRGB(30, 30, 30), Color3.fromRGB(150, 40, 40), Color3.fromRGB(40, 70, 120), Color3.fromRGB(110, 110, 110) },
			Headgear = { Ninguno = 6, Gorra = 3, Gorro = 1 },
			Gear = { Mochila = 0.2, Auriculares = 0.12, Gafas = 0.15, Guantes = 0.05 },
			Gloves = { Color3.fromRGB(30, 30, 30) },
		},
		{ Name = "Clasico", Kind = "Clasico", Weight = 5 },

		{ Name = "Bosque", Kind = "Militar", Weight = 12, HairChance = 0.3,
			Top = { Color3.fromRGB(85, 94, 54), Color3.fromRGB(74, 83, 52), Color3.fromRGB(92, 98, 66) },
			Bottom = { Color3.fromRGB(78, 85, 55), Color3.fromRGB(66, 72, 48) },
			Camo = { Color3.fromRGB(46, 54, 34), Color3.fromRGB(96, 78, 52), Color3.fromRGB(32, 34, 28), Color3.fromRGB(112, 120, 80) },
			Vest = { Color3.fromRGB(66, 75, 48), Color3.fromRGB(80, 84, 60), Color3.fromRGB(58, 62, 44) },
			Headgear = { Casco = 5, Boonie = 3, Gorra = 1, Ninguno = 1 },
			Gear = { Chaleco = 0.85, Mochila = 0.45, Cinturon = 0.9, Rodilleras = 0.55, Guantes = 0.6, Pasamontanas = 0.08,
				Bufanda = 0.2, Auriculares = 0.3, Gafas = 0.25, VisionNocturna = 0.1 },
			Gloves = { Color3.fromRGB(40, 40, 36), Color3.fromRGB(70, 62, 48) },
			Boots = { Color3.fromRGB(40, 34, 28), Color3.fromRGB(28, 28, 28) },
			ScarfColors = { Color3.fromRGB(60, 66, 44), Color3.fromRGB(90, 80, 60) },
			MaskColors = { Color3.fromRGB(45, 50, 38) },
		},
		{ Name = "Nieve", Kind = "Militar", Weight = 8, HairChance = 0.2,
			Top = { Color3.fromRGB(235, 238, 240), Color3.fromRGB(220, 224, 228), Color3.fromRGB(205, 210, 214) },
			Bottom = { Color3.fromRGB(225, 228, 232), Color3.fromRGB(200, 205, 210) },
			Camo = { Color3.fromRGB(170, 178, 186), Color3.fromRGB(140, 148, 156), Color3.fromRGB(250, 250, 250) },
			Vest = { Color3.fromRGB(210, 214, 218), Color3.fromRGB(190, 195, 200), Color3.fromRGB(150, 155, 160) },
			HeadgearColors = { Color3.fromRGB(235, 235, 235), Color3.fromRGB(200, 205, 210), Color3.fromRGB(90, 95, 100) },
			Headgear = { Casco = 4, Gorro = 4, Ninguno = 1 },
			Gear = { Chaleco = 0.7, Mochila = 0.5, Cinturon = 0.8, Rodilleras = 0.4, Guantes = 0.85, Pasamontanas = 0.35,
				Bufanda = 0.5, Auriculares = 0.2, Gafas = 0.35 },
			Gloves = { Color3.fromRGB(60, 62, 66), Color3.fromRGB(230, 230, 230) },
			Boots = { Color3.fromRGB(50, 50, 52), Color3.fromRGB(210, 210, 210) },
			ScarfColors = { Color3.fromRGB(240, 240, 240), Color3.fromRGB(170, 175, 180) },
			MaskColors = { Color3.fromRGB(240, 240, 240), Color3.fromRGB(190, 195, 200) },
		},
		{ Name = "Desierto", Kind = "Militar", Weight = 9, HairChance = 0.3,
			Top = { Color3.fromRGB(194, 170, 125), Color3.fromRGB(180, 155, 110), Color3.fromRGB(205, 185, 140) },
			Bottom = { Color3.fromRGB(185, 160, 115), Color3.fromRGB(170, 148, 105) },
			Camo = { Color3.fromRGB(150, 120, 80), Color3.fromRGB(215, 195, 150), Color3.fromRGB(130, 105, 70) },
			Vest = { Color3.fromRGB(175, 150, 105), Color3.fromRGB(160, 140, 100), Color3.fromRGB(120, 110, 80) },
			Headgear = { Casco = 4, Boonie = 3, Gorra = 2, Ninguno = 1 },
			Gear = { Chaleco = 0.8, Mochila = 0.4, Cinturon = 0.9, Rodilleras = 0.6, Guantes = 0.5, Pasamontanas = 0.05,
				Bufanda = 0.55, Auriculares = 0.3, Gafas = 0.45 },
			Gloves = { Color3.fromRGB(120, 95, 65), Color3.fromRGB(60, 55, 48) },
			Boots = { Color3.fromRGB(140, 110, 75), Color3.fromRGB(95, 75, 55) },
			ScarfColors = { Color3.fromRGB(200, 185, 150), Color3.fromRGB(110, 120, 90), Color3.fromRGB(60, 60, 60) },
		},
		{ Name = "Nocturno", Kind = "Militar", Weight = 9, HairChance = 0.15,
			Top = { Color3.fromRGB(28, 30, 32), Color3.fromRGB(38, 40, 44), Color3.fromRGB(22, 24, 28) },
			Bottom = { Color3.fromRGB(32, 34, 38), Color3.fromRGB(26, 28, 30) },
			Camo = {},
			Vest = { Color3.fromRGB(20, 20, 22), Color3.fromRGB(45, 48, 40), Color3.fromRGB(35, 38, 45) },
			Headgear = { Casco = 6, Gorra = 1, Gorro = 1 },
			Gear = { Chaleco = 0.95, Mochila = 0.25, Cinturon = 0.9, Rodilleras = 0.7, Guantes = 0.9, Pasamontanas = 0.5,
				Auriculares = 0.6, Gafas = 0.2, VisionNocturna = 0.45 },
			Gloves = { Color3.fromRGB(20, 20, 20) },
			Boots = { Color3.fromRGB(20, 20, 20) },
			MaskColors = { Color3.fromRGB(22, 22, 24) },
		},
		{ Name = "Urbano", Kind = "Militar", Weight = 9, HairChance = 0.3,
			Top = { Color3.fromRGB(95, 100, 108), Color3.fromRGB(120, 124, 130), Color3.fromRGB(70, 74, 80) },
			Bottom = { Color3.fromRGB(80, 84, 90), Color3.fromRGB(60, 62, 68) },
			Camo = { Color3.fromRGB(50, 52, 58), Color3.fromRGB(150, 152, 158), Color3.fromRGB(35, 36, 40) },
			Vest = { Color3.fromRGB(60, 62, 66), Color3.fromRGB(40, 42, 46) },
			Headgear = { Casco = 4, Gorra = 2, Gorro = 1, Ninguno = 1 },
			Gear = { Chaleco = 0.85, Mochila = 0.3, Cinturon = 0.85, Rodilleras = 0.6, Guantes = 0.7, Pasamontanas = 0.2,
				Bufanda = 0.15, Auriculares = 0.45, Gafas = 0.3, VisionNocturna = 0.15 },
			Gloves = { Color3.fromRGB(30, 30, 30) },
			Boots = { Color3.fromRGB(25, 25, 25), Color3.fromRGB(60, 50, 40) },
			MaskColors = { Color3.fromRGB(30, 30, 32), Color3.fromRGB(80, 84, 90) },
		},
		--  Contratista: ropa de civil (remera, caqui, jeans) con equipo tactico.
		{ Name = "Contratista", Kind = "Militar", Weight = 8, HairChance = 0.6, ShortSleeveChance = 0.5,
			Top = { Color3.fromRGB(40, 40, 40), Color3.fromRGB(90, 90, 95), Color3.fromRGB(50, 70, 90), Color3.fromRGB(150, 135, 110), Color3.fromRGB(225, 225, 225) },
			Bottom = { Color3.fromRGB(170, 150, 115), Color3.fromRGB(60, 62, 66), Color3.fromRGB(55, 60, 80) },
			Camo = {},
			Vest = { Color3.fromRGB(170, 150, 110), Color3.fromRGB(60, 65, 50), Color3.fromRGB(30, 30, 30) },
			Headgear = { Gorra = 5, Ninguno = 3, Casco = 1 },
			Gear = { Chaleco = 0.9, Mochila = 0.3, Cinturon = 0.8, Rodilleras = 0.3, Guantes = 0.6, Auriculares = 0.6, Gafas = 0.45 },
			Gloves = { Color3.fromRGB(150, 130, 100), Color3.fromRGB(30, 30, 30) },
			Boots = { Color3.fromRGB(120, 95, 70), Color3.fromRGB(30, 30, 30) },
		},
	},
	--  Tope de piezas de equipo por bot (rendimiento con muchos bots).
	MaxGearParts = 40,
	--  Manchas de camuflaje por bot (0 = uniforme liso).
	CamoPatches = 6,
}

--==========================================================================
--  ARMAS
--  Solo las iniciales. Salen de GunStorage con su ACS_Settings real, asi
--  que el dano, la caida por distancia y el cargador son los mismos que
--  los de un jugador. Aqui va solo lo que el bot necesita para "usarlas".
--
--  RecoilDeg     grados que se abre la punteria por cada tiro seguido.
--  PelletSpread  cono de los perdigones (solo escopeta), en grados.
--  IdealMin/Max  distancia (studs) a la que el bot se siente comodo con
--                esa arma; fuera de ahi se acerca o se aleja.
--  MaxRange      mas lejos que esto no dispara.
--==========================================================================
BotConfig.Weapons = {
	["SCAR-H"] = {
		Slot = "2Primary", Role = "Rifle", FireMode = "Auto",
		ReloadTime = 2.8, EquipTime = 0.6,
		RecoilDeg = 0.55, PelletSpread = 0,
		IdealMin = 20, IdealMax = 150, MaxRange = 330,
	},
	["Ithaca-37"] = {
		Slot = "3Secondary", Role = "Shotgun", FireMode = "Pump",
		ReloadStart = 0.45, ReloadPerShell = 0.5, EquipTime = 0.7,
		PumpTime = 0.85, RecoilDeg = 0, PelletSpread = 3.2,
		IdealMin = 0, IdealMax = 14, MaxRange = 45,
	},
	["Glock 26"] = {
		Slot = "4Tertiary", Role = "Pistol", FireMode = "Semi",
		ReloadTime = 1.7, EquipTime = 0.4,
		RecoilDeg = 0.9, PelletSpread = 0,
		IdealMin = 6, IdealMax = 45, MaxRange = 120,
	},

	--  [tacticas 23/09] Principales que puede sacar al azar (BotConfig.PrimaryPool).
	--  ErrorScale  multiplica su error de punteria (mira: <1, cadera: >1).
	--  SemiScale   que tanto mas despacio hace clic que con una pistola.
	--  BoltTime    cerrojo entre tiro y tiro (francotirador).
	--  AimTime     lo que tarda en apuntar con la mira antes de cada tiro.
	["AK-47"] = {
		Slot = "2Primary", Role = "Rifle", FireMode = "Auto",
		ReloadTime = 2.7, EquipTime = 0.65,
		RecoilDeg = 0.75, PelletSpread = 0,
		IdealMin = 18, IdealMax = 130, MaxRange = 300,
	},
	["MP5"] = {
		Slot = "2Primary", Role = "SMG", FireMode = "Auto",
		ReloadTime = 2.3, EquipTime = 0.5,
		RecoilDeg = 0.4, PelletSpread = 0, ErrorScale = 1.1,
		IdealMin = 6, IdealMax = 55, MaxRange = 170,
	},
	["R700"] = {
		Slot = "2Primary", Role = "Sniper", FireMode = "Bolt",
		BoltTime = 1.3, AimTime = { 0.35, 0.8 },
		ReloadTime = 3.2, EquipTime = 0.8,
		RecoilDeg = 0, PelletSpread = 0, ErrorScale = 0.5,
		IdealMin = 40, IdealMax = 400, MaxRange = 650,
	},
	["AR-15"] = {
		Slot = "2Primary", Role = "DMR", FireMode = "Semi", SemiScale = 1.25,
		ReloadTime = 2.5, EquipTime = 0.6,
		RecoilDeg = 0.35, PelletSpread = 0, ErrorScale = 0.85,
		IdealMin = 15, IdealMax = 190, MaxRange = 400,
	},
}

--  [tacticas 23/09] Cada bot sale con UNA principal al azar (con estos pesos)
--  y siempre la Ithaca y la Glock de secundaria y terciaria.
BotConfig.PrimaryPool = {
	{ Name = "AK-47",  Weight = 24 },
	{ Name = "SCAR-H", Weight = 22 },
	{ Name = "MP5",    Weight = 20 },
	{ Name = "AR-15",  Weight = 18 },
	{ Name = "R700",   Weight = 12 },
}
BotConfig.Secondary = { "Ithaca-37", "Glock 26" }

--  Con francotirador y alguien a menos de esto, saca la pistola.
BotConfig.SniperMinRange = 25

--  Orden de preferencia. El bot arranca con la primera que tenga permitida.
BotConfig.Loadout = { "SCAR-H", "Ithaca-37", "Glock 26" }

--  Mas cerca que esto saca la escopeta (si le quedan cartuchos).
BotConfig.ShotgunRange = 13
--  Si el rifle se vacia con un enemigo a menos de esto, saca la pistola
--  en vez de recargar en la cara del otro.
BotConfig.PistolSwapRange = 55
--  Segundos sin ver enemigos para recargar "por si acaso" y volver al rifle.
BotConfig.CalmReloadAfter = 2.5

--==========================================================================
--  PRESETS DE PUNTERIA  (uno al azar por bot, con estos pesos)
--
--  FirstShotError  error al descubrir al objetivo (grados).
--  SettledError    error despues de "acomodarse" siguiendolo.
--  TrackRate       que tan rapido pasa del primero al segundo (1/s).
--  MoveError       grados extra por cada stud/s que se mueve el objetivo
--                  de lado (dificultad para seguir a alguien que corre).
--  SelfMoveError   grados extra si el bot va caminando mientras dispara.
--  RecoilControl   0 = no controla el retroceso, 1 = lo anula entero.
--  HeadChance      probabilidad de apuntar a la cabeza en cada rafaga.
--  Burst / Pause   rafagas del rifle (tiros) y la pausa entre ellas (s).
--  SemiDelay       lo que tarda en volver a hacer clic con la pistola.
--  StrafeChance    probabilidad de moverse de lado mientras pelea.
--==========================================================================
BotConfig.AimPresets = {
	{ Label = "Noob",        Weight = 14, FirstShotError = 9.0, SettledError = 4.6, TrackRate = 0.8, MoveError = 0.20, SelfMoveError = 1.6, RecoilControl = 0.10, HeadChance = 0.04, Burst = { 6, 14 }, Pause = { 0.35, 0.9 },  SemiDelay = { 0.30, 0.55 }, StrafeChance = 0.10 },
	{ Label = "Novato",      Weight = 18, FirstShotError = 7.2, SettledError = 3.5, TrackRate = 1.1, MoveError = 0.16, SelfMoveError = 1.3, RecoilControl = 0.25, HeadChance = 0.07, Burst = { 5, 11 }, Pause = { 0.30, 0.75 }, SemiDelay = { 0.24, 0.45 }, StrafeChance = 0.20 },
	{ Label = "Casual",      Weight = 20, FirstShotError = 5.6, SettledError = 2.6, TrackRate = 1.5, MoveError = 0.13, SelfMoveError = 1.0, RecoilControl = 0.40, HeadChance = 0.11, Burst = { 4, 9 },  Pause = { 0.25, 0.6 },  SemiDelay = { 0.20, 0.38 }, StrafeChance = 0.35 },
	{ Label = "Promedio",    Weight = 18, FirstShotError = 4.3, SettledError = 1.9, TrackRate = 2.0, MoveError = 0.10, SelfMoveError = 0.8, RecoilControl = 0.50, HeadChance = 0.16, Burst = { 4, 8 },  Pause = { 0.22, 0.5 },  SemiDelay = { 0.17, 0.32 }, StrafeChance = 0.50 },
	{ Label = "Bueno",       Weight = 12, FirstShotError = 3.3, SettledError = 1.4, TrackRate = 2.6, MoveError = 0.08, SelfMoveError = 0.6, RecoilControl = 0.62, HeadChance = 0.22, Burst = { 3, 7 },  Pause = { 0.18, 0.42 }, SemiDelay = { 0.15, 0.28 }, StrafeChance = 0.62 },
	{ Label = "Veterano",    Weight = 9,  FirstShotError = 2.5, SettledError = 1.0, TrackRate = 3.3, MoveError = 0.06, SelfMoveError = 0.45, RecoilControl = 0.72, HeadChance = 0.30, Burst = { 3, 6 },  Pause = { 0.15, 0.35 }, SemiDelay = { 0.13, 0.24 }, StrafeChance = 0.72 },
	{ Label = "Profesional", Weight = 6,  FirstShotError = 1.8, SettledError = 0.65, TrackRate = 4.2, MoveError = 0.04, SelfMoveError = 0.3, RecoilControl = 0.82, HeadChance = 0.40, Burst = { 3, 6 },  Pause = { 0.12, 0.28 }, SemiDelay = { 0.11, 0.2 },  StrafeChance = 0.82 },
	{ Label = "Elite",       Weight = 3,  FirstShotError = 1.2, SettledError = 0.42, TrackRate = 5.5, MoveError = 0.03, SelfMoveError = 0.2, RecoilControl = 0.90, HeadChance = 0.50, Burst = { 2, 5 },  Pause = { 0.10, 0.22 }, SemiDelay = { 0.10, 0.17 }, StrafeChance = 0.90 },
}

--==========================================================================
--  PRESETS DE TIEMPO DE REACCION  (se tira aparte de la punteria)
--
--  Reaction   segundos desde que ve al enemigo hasta el primer tiro.
--  TurnSpeed  que tan rapido gira el cuerpo hacia el objetivo.
--  AimCone    no dispara hasta estar mirando a menos de estos grados.
--==========================================================================
BotConfig.ReactionPresets = {
	{ Label = "Muy lenta",  Weight = 12, Reaction = { 0.85, 1.25 }, TurnSpeed = 6,  AimCone = 14 },
	{ Label = "Lenta",      Weight = 20, Reaction = { 0.60, 0.85 }, TurnSpeed = 9,  AimCone = 16 },
	{ Label = "Normal",     Weight = 30, Reaction = { 0.42, 0.60 }, TurnSpeed = 12, AimCone = 18 },
	{ Label = "Rapida",     Weight = 20, Reaction = { 0.30, 0.42 }, TurnSpeed = 16, AimCone = 20 },
	{ Label = "Muy rapida", Weight = 12, Reaction = { 0.22, 0.30 }, TurnSpeed = 22, AimCone = 22 },
	{ Label = "Relampago",  Weight = 6,  Reaction = { 0.16, 0.22 }, TurnSpeed = 30, AimCone = 24 },
}

--==========================================================================
--  TIPOS DE IA  (uno al azar por bot, con estos pesos)  [tacticas 23/09]
--
--  Ataque     empuja: va a donde estan los enemigos, corre siempre, pelea
--             mas de cerca y se barre mucho.
--  Equipo     va pegado a un companero (jugador real primero) y todos van
--             juntos a donde un bot del equipo vio a un enemigo.
--  Defensiva  busca un puesto con cobertura mirando hacia los enemigos y lo
--             cubre agachado ("campea"); cambia de puesto cada tanto.
--  Estratega     con lo que oye (disparos, dano, avisos del equipo) busca un
--             angulo desde donde cubrir ese punto, lo vigila agachado y
--             luego flanquea por un costado. WatchCooldown: segundos entre
--             una vigilancia y la siguiente (en ese rato flanquea o pelea).
--  Apoyo      prioriza levantar companeros (busca mucho mas lejos) y va a
--             ayudar a los que estan peleando.
--  Sigiloso   rodea bien abierto, lejos de la pelea, y llega por la espalda
--             agachado; no dispara hasta estar cerca salvo que lo vean.
--  Corredora  mantiene la distancia; si se le acercan huye en zigzag y pelea
--             de lejos.
--  Camper     busca puntos altos y lejanos (o una entrada unica) y dispara
--             desde ahi; se mueve entre puntos.
--  Lider      marca a los demas bots de su equipo por donde atacar, a quien
--             priorizar y por que flanco ir; el se queda atras observando.
--
--  HuntBias     que tanto pasea hacia donde andan los enemigos.
--  RunChance    probabilidad de ir corriendo cuando pasea.
--  RangeMult    multiplica la distancia a la que le gusta pelear.
--  StrafeBonus  se suma a StrafeChance de su punteria.
--  SlideChance  que tan seguido se barre.
--  CoverHealth  con menos vida que esto (0-1) busca donde cubrirse.
--==========================================================================
BotConfig.Roles = {
	{ Kind = "Ataque",    Label = "Ataque",    Weight = 22, HuntBias = 0.95, RunChance = 0.95, RangeMult = 0.7,  StrafeBonus = 0.1,  SlideChance = 0.55, CoverHealth = 0.22 },
	{ Kind = "Equipo",    Label = "Equipo",    Weight = 22, HuntBias = 0.6,  RunChance = 0.7,  RangeMult = 1.0,  StrafeBonus = 0,    SlideChance = 0.25, CoverHealth = 0.35, FollowRange = { 8, 20 } },
	{ Kind = "Defensiva", Label = "Defensiva", Weight = 18, HuntBias = 0.4,  RunChance = 0.4,  RangeMult = 1.4,  StrafeBonus = -0.2, SlideChance = 0.08, CoverHealth = 0.5,  HoldTime = { 25, 55 } },
	{ Kind = "Estratega", Label = "Estratega", Weight = 18, HuntBias = 0.55, RunChance = 0.5,  RangeMult = 1.15, StrafeBonus = 0,    SlideChance = 0.2,  CoverHealth = 0.45, WatchTime = { 6, 12 }, WatchCooldown = { 8, 16 } },
	{ Kind = "Apoyo",     Label = "Apoyo",     Weight = 20, HuntBias = 0.5,  RunChance = 0.75, RangeMult = 1.0,  StrafeBonus = 0,    SlideChance = 0.25, CoverHealth = 0.35, ReviveRangeMult = 1.8, SupportRange = 130 },
	--  [23/09 noche] SIGILOSO: elige una presa, la rodea bien abierto (lejos
	--  de la pelea), se le acerca agachado por la espalda y no dispara hasta
	--  estar cerca (HoldFireRange) salvo que lo descubran.
	{ Kind = "Sigiloso",  Label = "Sigiloso",  Weight = 16, HuntBias = 0.9,  RunChance = 0.25, RangeMult = 0.8,  StrafeBonus = -0.15, SlideChance = 0.03, CoverHealth = 0.45, FlankWide = { 35, 55 }, BehindDist = { 12, 20 }, HoldFireRange = 40, CrouchRange = 45 },
	--  [24/09] CORREDORA: pelea siempre a distancia. Si se le acercan a menos
	--  de PanicRange huye en zigzag (sin disparar, barriendose) y vuelve a
	--  pelear desde KeepAway. Sin pelea, se acomoda a esa distancia de donde
	--  sabe que hay enemigos, en vez de ir encima.
	{ Kind = "Corredora", Label = "Corredora", Weight = 14, HuntBias = 0.6,  RunChance = 1.0,  RangeMult = 1.6,  StrafeBonus = 0.2,  SlideChance = 0.6,  CoverHealth = 0.4,
		KeepAway = { 45, 70 }, PanicRange = 25, FleeTime = { 2.5, 4 }, ZigzagTime = { 0.35, 0.6 }, FleeDistance = { 40, 60 } },
	--  [24/09] CAMPER: busca un punto alto con vista hacia los enemigos, se
	--  agacha y dispara desde ahi sin perseguir; cambia de punto cada
	--  PerchTime, si le pegan o si alguien se le acerca. Con ChokeChance, en
	--  vez de subir holdea una entrada unica (una puerta o un pasillo angosto)
	--  desde adentro. PreferPrimary: multiplica la probabilidad de esas armas.
	{ Kind = "Camper",    Label = "Camper",    Weight = 14, HuntBias = 0.3,  RunChance = 0.6,  RangeMult = 1.8,  StrafeBonus = -0.3, SlideChance = 0.02, CoverHealth = 0.5,
		PerchTime = { 20, 45 }, PerchSearch = 110, MinHeight = 6, ChokeChance = 0.35, CloseFight = 15,
		PreferPrimary = { ["R700"] = 4, ["AR-15"] = 2.5 } },
	--  [24/09] LIDER: dirige a los bots de su equipo. Junta lo que ven todos,
	--  calcula por donde vienen los enemigos, elige un objetivo prioritario y
	--  cada OrderEvery s da una orden: punto de ataque + un flanco para cada
	--  bot. El se queda StayBehind studs detras del frente, observando.
	--  Prioridad del objetivo = bajas * KillWeight - distancia a su equipo *
	--  CloseWeight + vida que le falta (%) * LowHealthWeight.
	--  (No es el lider del modo Guardian: ese lo elige la partida.)
	{ Kind = "Lider",     Label = "Lider",     Weight = 10, HuntBias = 0.4,  RunChance = 0.6,  RangeMult = 1.3,  StrafeBonus = 0,    SlideChance = 0.15, CoverHealth = 0.45,
		OrderEvery = 3, OrderLife = 8, FlankSpread = 25, StayBehind = 30, FocusBonus = 40,
		KillWeight = 10, CloseWeight = 1, LowHealthWeight = 0.5 },
}

--  [23/09 noche] Bot LIDER en Guardian: si muere su equipo ya no reaparece,
--  asi que juega a no morir. Se queda detras de su equipo y lejos de los
--  enemigos, rompe la linea de vision en vez de pelear de lejos y solo
--  pelea (retrocediendo) si alguien se le acerca a menos de CloseFight.
BotConfig.Leader = {
	CloseFight = 22,		-- studs: mas cerca que esto pelea retrocediendo
	BehindTeam = 20,		-- studs detras de su equipo (lado contrario a los enemigos)
	SafeDistance = 45,		-- si un enemigo se acerca a esto de su puesto, se mueve
	Repick = 12,			-- s: cada cuanto busca un puesto nuevo
}

--  [23/09 noche] Sobrevivir a los climas especiales.
--  Ventisca / lluvia acida / huracan: busca techo y se mueve solo entre
--  lugares techados. Inundacion: busca un lugar alto y seco.
BotConfig.Weather = {
	ShelterSearch = 70,		-- studs a la redonda donde busca techo
	MaxSearch = 160,		-- si no hay nada cerca, hasta aqui busca (con menos detalle)
	HighGroundSearch = 100,	-- studs a la redonda donde busca lugar alto
	FightFirst = 20,		-- con un enemigo a menos de esto, primero pelea
}

--  Segundos que vale el aviso "vi a un enemigo aqui" entre bots del equipo.
BotConfig.TeamIntelTime = 8

--  Cobertura con poca vida: cuanto se queda escondido (s).
BotConfig.Cover = {
	StayTime = { 8, 14 },
}

--  Igual que un jugador (script regen): matar da +25 de vida al instante y
--  20 puntos de regeneracion (1 de vida cada 4 s). Se reinicia al reaparecer.
BotConfig.KillReward = {
	Health = 25,
	RegenPoints = 20,
	RegenInterval = 4,
}

--  De noche (ambiente "Noche_...") todas sus armas llevan lampara encendida.
BotConfig.Night = {
	Flashlights = true,
}

--==========================================================================
--  PERCEPCION
--==========================================================================
BotConfig.Perception = {
	ViewDistance   = 380,	-- studs
	FOV            = 150,	-- grados totales del cono de vision (23/09 noche: antes 125)
	CloseAwareness = 24,	-- a menos de esto te nota aunque este de espaldas (antes 14:
							--  se le pasaban abatidos arrastrandose por un lado)
	HearingRange   = 170,	-- oye disparos a esta distancia
	MemorySeconds  = 6,		-- recuerda donde te vio por ultima vez
	ThinkRate      = 8,		-- decisiones por segundo por bot
}

--==========================================================================
--  MOVIMIENTO  (los valores de ACS GameRules mandan si existen)
--==========================================================================
BotConfig.Movement = {
	CombatSpeed    = 10,	-- caminando mientras apunta/dispara
	RepathMoving   = 1.2,	-- s: cada cuanto recalcula si persigue a alguien
	RepathRoam     = 4,		-- s: cada cuanto recalcula paseando
	ArriveDistance = 4,
	StuckJump      = 1.0,	-- s sin avanzar -> salta
	StuckGiveUp    = 2.6,	-- s sin avanzar -> otro destino
	StrafeTime     = { 0.5, 1.3 },
	--  Al pasear, que tanto "sabe" donde andan los enemigos (0 = pasea al
	--  azar, 1 = va directo a la zona del enemigo). Un humano conoce el mapa.
	HuntBias       = 0.65,
	HuntNoise      = 35,	-- studs de error al adivinar donde esta alguien

	--  [tacticas] Barrida (la misma postura de ACS que usa un jugador).
	SlideSpeed     = 34,			-- studs/s al arrancar (baja hasta ~40%)
	SlideTime      = 0.85,			-- segundos que dura
	SlideCooldown  = { 4, 8 },		-- segundos entre barridas
}

--==========================================================================
--  RONDA
--==========================================================================
BotConfig.Round = {
	JoinDelay     = { 1.5, 5 },	-- s desde que arranca la ronda hasta que "le da a JUGAR"
	RespawnExtra  = { 0.2, 1.2 },	-- s extra sobre el RespawnTime de Roblox
	CorpseTime    = 5,				-- s que queda el cuerpo tirado
}

--==========================================================================
--  ABATIDO  (fase 2 — las reglas y la vida las lleva DownedServer, igual
--  que con un jugador; esto es solo como se comporta el bot en el suelo)
--==========================================================================
BotConfig.Downed = {
	--  Segundos entre "pulsaciones" de espacio al forcejear para levantarse.
	StrugglePress = { 0.09, 0.17 },
	--  Si hay un companero de pie a menos de esto, no forcejea: se arrastra
	--  hacia el y espera que lo levante...
	WaitForTeammateRange = 45,
	--  ...pero si nadie viene en estos segundos, forcejea igual.
	WaitForTeammateMax = 14,
	--  Arrastrandose (ya sin intentos de levantarse) saca la pistola y pelea
	--  desde el suelo, como puede hacer un jugador con la terciaria.
	ShootWhileProne = true,
	--  Grados extra de error disparando tirado en el suelo.
	ProneAimPenalty = 1.5,
}

--==========================================================================
--  LEVANTAR COMPANEROS  (bots y jugadores de su mismo equipo; en FFA no)
--==========================================================================
BotConfig.Revive = {
	Enabled = true,
	SearchRange = 110,	-- busca companeros abatidos a esta distancia (studs)
	StartDistance = 9,	-- se planta a esta distancia para levantarlo
	EnemyAbort = 70,	-- (ya no se usa: ahora dispara mientras levanta)
	--  [24/09] Mientras levanta a alguien dispara a un enemigo que este a
	--  menos de estos grados del caido (el servidor exige mirar al caido mas
	--  o menos de frente para seguir levantando).
	ShootWhileRevivingAngle = 70,
	--  Si un enemigo se le echa encima (a menos de esto) por un lado que no
	--  puede cubrir, suelta al caido y pelea. El Apoyo tambien pelea primero
	--  si tiene a alguien a esta distancia.
	AbortClose = 18,
}

--  Igual que los jugadores: el ForceField se va al disparar o al alejarse
--  2 m (7.14 studs) del spawn. MaxSeconds es un tope por si se queda quieto.
BotConfig.SpawnProtection = {
	Enabled = true,
	MoveStuds = 7.14,
	MaxSeconds = 8,
}

--==========================================================================
--  IA v2  [25/09]  (parkour, oido, caminos, encierros, rendimiento)
--
--  Todo tiene un valor por defecto dentro de BotServer (tabla Tac.AI).
--  Cualquier clave que pongas aqui lo reemplaza; las que no pongas quedan
--  igual. Las mas utiles:
--
--    MantleMaxHeight   bordes hasta esta altura se trepan (6.5; 0 = nunca).
--                      Un jugador con JumpPower 25 sube ~3.3: con 3.3 los
--                      bots quedan parejos con los jugadores.
--    GapMax            huecos hasta este largo se saltan (8; 0 = nunca).
--    HotspotRange      de tan lejos oyen un tiroteo y van hacia el (480).
--    FootstepRange     pasos corriendo; caminando ~45 % de esto (42).
--    WeatherTolerance  s a la intemperie antes de buscar techo (8).
--    WeatherFightRange con un enemigo a menos de esto pelea igual (70).
--    JumpLoopLimit     saltos en el mismo lugar antes de rendirse (5).
--    ConfinedTime      s sin salir de un lugar antes de explorar (10).
--    WindowEscapeAfter exploraciones antes de salir por una ventana (2).
--    PathBudget        calculos de camino por segundo entre todos (14).
--    LodDistance       sin jugadores reales a esto piensan mas lento (260).
--==========================================================================
BotConfig.AI = {
	-- MantleMaxHeight = 6.5,
	-- GapMax = 8,
}

return BotConfig
