--==========================================================================
--  GamemodeConfig  (ReplicatedStorage)  —  22/09/2026
--
--  Reglas de cada MODO DE JUEGO en un solo lugar. Antes vivian dentro del
--  RoundManager (GAMEMODE_RULES); ahora las leen tambien DownedServer (para
--  las reglas de remate de Ejecucion) y el cliente si algun dia hace falta.
--
--  Las claves van SIN acentos: viajan como opcion de voto y como valor del
--  atributo ActiveGamemode / WinningGamemode. El nombre bonito es Label.
--
--  Campos:
--    Duration          segundos que dura la ronda
--    Lives             0 = infinitas. 2 = la vida con la que entras + UN
--                      respawn; a la segunda muerte quedas fuera.
--    EndWhenOneLeft    corta la ronda cuando queda un jugador/equipo
--    EliminationDelay  segundos de killcam antes de mandarte al menu
--    GraceSeconds      la ronda no se corta sola antes de esto
--    JoinWindow        segundos desde que arranca la ronda para entrar con
--                      JOIN. Despues solo pueden volver los que ya habian
--                      entrado en ESTA ronda. 0 = se puede entrar siempre.
--    MinPlayers        si al cerrarse la entrada hay menos jugadores que
--                      esto, la ronda se cancela y se vuelve a votar (asi
--                      nadie se queda 15 min solo y el resto bloqueado).
--                      En Studio NO se cancela, para poder probar solo.
--    Execution         (solo Ejecucion) reglas de remate, ver abajo.
--    ForceTeams        si la votacion de EQUIPOS termina en FFA, se juega
--                      con este modo de equipos ("2 Teams"). Si salio
--                      2 o 4 equipos se respeta lo votado.
--    TeamPodium        el podio es POR EQUIPO: todos los del equipo con mas
--                      puntos quedan 1er lugar, los del segundo 2do, etc.
--    TeamPodiumBy      "Points" (por defecto) o "Lives": con que se ordena
--                      a los equipos para el podio.
--    TeamLives         reapariciones COMPARTIDAS por todo el equipo. Cada
--                      muerte gasta una; sin reapariciones, el que muere
--                      queda eliminado. Gana el equipo con mas al final, o
--                      el ultimo que quede en pie.
--    RoundLabel        nombre que se ve YA EN LA PARTIDA (marcador). Label
--                      es el de la votacion.
--    RespawnDelay      segundos minimos para volver a la partida despues de
--                      morir O de salir al menu (asi el menu no sirve para
--                      saltarse la espera). Sin esto, la espera normal.
--    Guardian          (solo Guardian) lider por equipo, ver abajo.
--    RequiresPart      [26/09] el mapa tiene que tener una pieza con este
--                      nombre; si el mapa votado no la tiene, esa partida
--                      se juega en Arcade (Control necesita AreaObjetivo).
--    Control           [26/09] (solo Control) puntos por mantener el area,
--                      ver abajo.
--
--  VOTACION: igual que los mapas, en cada votacion salen 3 modos al azar de
--  los de Order (lo sortea el RoundManager).
--==========================================================================

local GamemodeConfig = {}

--  1 metro = 3.5714 studs (la misma constante de CreateBullet / ACS_Server).
GamemodeConfig.STUDS_PER_METER = 3.5714

GamemodeConfig.Default = "Arcade"

--  Orden en el que salen en la votacion.
GamemodeConfig.Order = { "Arcade", "DueloEquipos", "DueloVidas", "Eliminacion", "Ejecucion", "Guardian", "Control" }

GamemodeConfig.Modes = {
	Arcade = {
		Label = "ARCADE",
		Duration = 300,
		Lives = 0,
		EndWhenOneLeft = false,
		JoinWindow = 0,
	},

	--  [22/09/2026] Duelo por equipos: reaparicion infinita, siempre con
	--  equipos, y gana el EQUIPO (todos sus jugadores quedan 1er lugar).
	DueloEquipos = {
		Label = "DUELO POR EQUIPOS",
		Duration = 300,
		Lives = 0,					-- reaparece infinitamente
		EndWhenOneLeft = false,
		JoinWindow = 0,				-- se puede entrar en cualquier momento
		ForceTeams = "2 Teams",
		TeamPodium = true,
		--  Morir (de verdad, no quedar abatido) le quita estos puntos al
		--  jugador Y a su equipo. Quedar abatido no cuesta nada: si te
		--  levantan, el equipo no pierde. Salir con M o al terminar la
		--  ronda no cuenta como muerte. 0 = sin penalizacion.
		DeathPenalty = 100,
	},

	--  [22/09/2026] Duelo por equipos, variante de VIDAS. En la votacion se
	--  llama IGUAL que el otro a proposito: nadie sabe cual de los dos le
	--  toca hasta que arranca la partida.
	DueloVidas = {
		Label = "DUELO POR EQUIPOS",
		RoundLabel = "DUELO POR EQUIPOS · VIDAS",
		Duration = 900,
		Lives = 0,					-- sin vidas individuales: manda TeamLives
		TeamLives = 50,				-- 50 reapariciones para TODO el equipo
		EndWhenOneLeft = false,		-- la ronda se corta por TeamLives
		EliminationDelay = 4.5,
		GraceSeconds = 10,
		JoinWindow = 0,
		ForceTeams = "2 Teams",
		TeamPodium = true,
		TeamPodiumBy = "Lives",
	},

	--  [22/09/2026] Guardian: a los PickDelay segundos se elige un lider al
	--  azar en cada equipo. Solo el lider usa armas largas; los demas solo
	--  terciaria (y cuerpo a cuerpo / misc). Mientras el lider vive, su
	--  equipo reaparece sin limite (con RespawnDelay de espera). Si el lider
	--  muere (o se va), ese equipo ya no reaparece. Gana el equipo que quede
	--  en pie, con o sin lider. Al acabarse el tiempo: primero los que
	--  conservan al lider, despues los que tienen mas gente en pie, y los
	--  puntos desempatan.
	Guardian = {
		Label = "GUARDIÁN",
		Duration = 300,
		Lives = 0,
		EndWhenOneLeft = false,		-- lo corta la regla de Guardian
		EliminationDelay = 4.5,
		GraceSeconds = 10,
		JoinWindow = 15,
		MinPlayers = 2,
		ForceTeams = "2 Teams",
		TeamPodium = true,
		TeamPodiumBy = "Standing",
		RespawnDelay = 5,
		Guardian = {
			PickDelay = 5,
			--  Slots (WeaponCategory de LoadoutServer) que NO recibe quien
			--  no es lider: las armas largas.
			RestrictedSlots = "2Primary,3Secondary",
		},
	},

	--  [26/09/2026] Control: mantener el AreaObjetivo del mapa (hoy solo
	--  Prision la tiene). Cada segundo se cuenta quien esta parado en el area
	--  y cada enemigo anula a uno: el equipo con mas gente suma (sus
	--  jugadores - los de todos los demas) * PointsPerSecond. Si nadie supera
	--  a los demas, el punto queda en disputa (nadie suma, el area toma la
	--  mezcla de colores). Gana el equipo con mas puntos al acabarse el
	--  tiempo. El RoundManager publica los puntos en State.ControlScore_<Equipo>
	--  y, al terminar, TeamStanding_<Equipo> = puntos (de ahi el podio).
	Control = {
		Label = "CONTROL",
		Duration = 600,				-- 10 minutos
		Lives = 0,					-- reaparicion normal
		EndWhenOneLeft = false,
		JoinWindow = 0,
		ForceTeams = "2 Teams",
		TeamPodium = true,
		TeamPodiumBy = "Standing",	-- ordena por TeamStanding_ = puntos de Control
		RequiresPart = "AreaObjetivo",
		Control = {
			PointsPerSecond = 1,	-- por cada jugador de ventaja dentro del area
			ScoreLimit = 0,			-- > 0: gana el primero que llega (0 = solo el tiempo)
		},
	},

	Eliminacion = {
		Label = "ELIMINACIÓN",
		Duration = 900,				-- 15 minutos
		Lives = 1,					-- [24/09] sin reapariciones: si mueres quedas fuera
		Corpses = true,				-- [24/09] los muertos dejan su cuerpo en el mapa
		EndWhenOneLeft = true,
		EliminationDelay = 4.5,
		GraceSeconds = 15,
		JoinWindow = 15,
		MinPlayers = 2,
	},

	Ejecucion = {
		Label = "EJECUCIÓN",
		Duration = 900,
		Lives = 1,					-- [24/09] sin reapariciones: si mueres quedas fuera
		Corpses = true,				-- [24/09] los muertos dejan su cuerpo en el mapa
		EndWhenOneLeft = true,
		EliminationDelay = 4.5,
		GraceSeconds = 15,
		JoinWindow = 15,
		MinPlayers = 2,

		--  Un abatido SOLO se puede rematar:
		--    · desde menos de RangeMeters (cualquier dano, cuerpo a cuerpo o
		--      a quemarropa), o
		--    · con un tiro a la cabeza (este o no abatido).
		--  Todo lo demas que le pegue estando en el suelo no le hace nada.
		Execution = {
			RangeMeters = 1,
			--  Margen extra en studs por latencia: el cuerpo tumbado se mide
			--  a su parte mas cercana (cabeza, torso, cadera), no al centro.
			ToleranceStuds = 0.75,
			--  Headshot a un abatido = remate instantaneo (no resta reserva,
			--  lo termina).
			HeadshotFinishesDowned = true,
			--  Headshot letal a alguien de pie = muerte directa, sin abatido.
			HeadshotSkipsDowned = true,
			--  false: desangrarse NO mata; la reserva se queda en 1 y hay que
			--  ir a rematarlo. Tambien se ignora el dano de fuera de la
			--  puerta (fuego, sangrado, clima) mientras esta abatido.
			BleedoutKills = true,
			--  Aviso al que dispara a un abatido sin poder rematarlo.
			HintCooldown = 2,
			HintText = "Acércate a menos de 1 m o dispárale a la cabeza para rematarlo",
		},
	},
}

function GamemodeConfig.get(name)
	return GamemodeConfig.Modes[name] or GamemodeConfig.Modes[GamemodeConfig.Default]
end

function GamemodeConfig.labelFor(name)
	local mode = GamemodeConfig.Modes[name]
	return (mode and mode.Label) or tostring(name)
end

return GamemodeConfig
