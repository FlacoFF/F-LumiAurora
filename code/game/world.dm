/*
	The initialization of the game happens roughly like this:

	1. All global variables are initialized (including the global_init instance).
	2. The map is initialized, and map objects are created.
	3. world/New() runs, creating & starting the master controller.
	4. The master controller initializes the rest of the game.

*/
GLOBAL_DATUM_INIT(init, /datum/global_init, new)
GLOBAL_DATUM(config, /datum/configuration)
GLOBAL_VAR(motd)
GLOBAL_PROTECT(config)

/**
 * THIS !!!SINGLE!!! PROC IS WHERE ANY FORM OF INIITIALIZATION THAT CAN'T BE PERFORMED IN SUBSYSTEMS OR WORLD/NEW IS DONE
 * NOWHERE THE FUCK ELSE
 * I DON'T CARE HOW MANY LAYERS OF DEBUG/PROFILE/TRACE WE HAVE, YOU JUST HAVE TO DEAL WITH THIS PROC EXISTING
 * I'M NOT EVEN GOING TO TELL YOU WHERE IT'S CALLED FROM BECAUSE I'M DECLARING THAT FORBIDDEN KNOWLEDGE
 * SO HELP ME GOD IF I FIND ABSTRACTION LAYERS OVER THIS!
 */
/world/proc/Genesis(tracy_initialized = FALSE)
	RETURN_TYPE(/datum/controller/master)

#ifdef USE_BYOND_TRACY
#warn USE_BYOND_TRACY is enabled
	if(!tracy_initialized)
		init_byond_tracy()
		Genesis(tracy_initialized = TRUE)
		return
#endif

	// Init the debugger first so we can debug Master
	init_debugger()

	// THAT'S IT, WE'RE DONE, THE. FUCKING. END.
	Master = new

/*
	Pre-map initialization stuff should go here.
*/
/datum/global_init/New()
	generate_gameid()

	load_configuration()

	qdel(src) //we're done
	GLOB.init = null

/datum/global_init/Destroy()
	..()
	return 3	// QDEL_HINT_HARDDEL ain't defined here, so magic number it is.

/proc/generate_gameid()
	if(GLOB.round_id != null)
		return
	GLOB.round_id = ""

	var/list/c = list("a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0")
	var/l = c.len

	var/t = world.timeofday
	for(var/_ = 1 to 4)
		GLOB.round_id = "[c[(t % l) + 1]][GLOB.round_id]"
		t = round(t / l)
	GLOB.round_id = "-[GLOB.round_id]"
	t = round(world.realtime / (10 * 60 * 60 * 24))
	for(var/_ = 1 to 3)
		GLOB.round_id = "[c[(t % l) + 1]][GLOB.round_id]"
		t = round(t / l)

/world
	mob = /mob/abstract/new_player
	turf = /turf/space
	area = /area/space
	view = "15x15"
	cache_lifespan = 0	//stops player uploaded stuff from being kept in the rsc past the current session
	maxx = WORLD_MIN_SIZE	// So that we don't get map-window-popin at boot. DMMS will expand this.
	maxy = WORLD_MIN_SIZE
	fps = 20
#ifdef FIND_REF_NO_CHECK_TICK
	loop_checks = FALSE
#endif

#define RECOMMENDED_VERSION 515
/world/New()
	//logs
	GLOB.diary_date_string = time2text(world.realtime, "YYYY/MM/DD")
	GLOB.href_logfile = file("data/logs/[GLOB.diary_date_string] hrefs.htm")
	GLOB.diary = "data/logs/[GLOB.diary_date_string]_[GLOB.round_id].log"

	var/latest_changelog = file("html/changelogs/archive/" + time2text(world.timeofday, "YYYY-MM") + ".yml")
	GLOB.changelog_hash = fexists(latest_changelog) ? md5(latest_changelog) : 0 //for telling if the changelog has changed recently

	log_startup()
	load_motd()

	if(GLOB.config.logsettings["log_runtime"])
		GLOB.diary_runtime = file("data/logs/_runtime/[GLOB.diary_date_string]-runtime.log")

	if(byond_version < RECOMMENDED_VERSION)
		log_world("ERROR: Your server's byond version does not meet the recommended requirements for this server. Please update BYOND to [RECOMMENDED_VERSION].")

	TgsNew(new /datum/tgs_event_handler/impl, TGS_SECURITY_TRUSTED)

	GLOB.config.post_load()

	if(GLOB.config && GLOB.config.server_name != null && GLOB.config.server_suffix && world.port > 0)
		// dumb and hardcoded but I don't care~
		GLOB.config.server_name += " #[(world.port % 1000) / 100]"

	callHook("startup")

	. = ..()

#ifdef UNIT_TEST
	#if defined(MANUAL_UNIT_TEST)

	world.log << "[ascii_green] *** NOTICE *** [ascii_reset] Unit Tests Enabled.  This will destroy the world when testing is complete."

	#else

	world.log << "::notice::Unit Tests Enabled.  This will destroy the world when testing is complete."

	#endif

	load_unit_test_changes()
#endif

	Master.Initialize(10, FALSE, TRUE)

#undef RECOMMENDED_VERSION

	return

var/list/world_api_rate_limit = list()

/world/Topic(T, addr, master, key)
	var/list/response[] = list()
	var/list/queryparams[]

	if (!SSfail2topic)
		response["statuscode"] = 500
		response["response"] = "Server not initialized."
		return json_encode(response)
	else if (SSfail2topic.IsRateLimited(addr))
		response["statuscode"] = 429
		response["response"] = "Rate limited."
		return json_encode(response)

	if (length(T) > 2000)
		response["statuscode"] = 413
		response["response"] = "Payload too large."
		return json_encode(response)

	try
		queryparams = json_decode(T)
	catch()
		queryparams = list()

	log_debug("API: Request Received - from:[addr], master:[master], key:[key]")
	log_topic(T, addr, master, key, queryparams)

	// TGS topic hook. Returns if successful, expects old-style serialization.
	var/tgs_topic_return = TgsTopic(T)

	if (tgs_topic_return)
		log_debug("API - TGS3 Request.")
		return tgs_topic_return
	else if (!queryparams.len)
		log_debug("API - Bad Request - Invalid/no JSON data sent.")
		response["statuscode"] = 400
		response["response"] = "Bad Request - Invalid/no JSON data sent."
		return json_encode(response)

	queryparams["addr"] = addr //Add the IP to the queryparams that are passed to the api functions
	var/query = queryparams["query"]
	var/auth = queryparams["auth"]

	if (isnull(query))
		log_debug("API - Bad Request - No query specified")
		response["statuscode"] = 400
		response["response"] = "Bad Request - No query specified"
		return json_encode(response)

	var/datum/topic_command/command = GLOB.topic_commands[query]

	//Check if that command exists
	if (isnull(command))
		log_debug("API: Unknown command called: [query]")
		response["statuscode"] = 501
		response["response"] = "Not Implemented"
		return json_encode(response)

	var/unauthed = command.check_auth(addr, auth)
	if (unauthed)
		if (unauthed == 3)
			log_debug("API: Request denied - Auth Service Unavailable")
			response["statuscode"] = 503
			response["response"] = "Auth Service Unavailable"
			return json_encode(response)
		else if (unauthed == 2)
			log_debug("API: Request denied - Throttled")
			response["statuscode"] = 429
			response["response"] = "Throttled"
			return json_encode(response)
		else
			log_debug("API: Request denied - Bad Auth")
			response["statuscode"] = 401
			response["response"] = "Bad Auth"
			return json_encode(response)

	log_debug("API: Auth valid")

	if(command.check_params_missing(queryparams))
		log_debug("API: Mising Params - Status: [command.statuscode] - Response: [command.response]")
		response["statuscode"] = command.statuscode
		response["response"] = command.response
		response["data"] = command.data
		return json_encode(response)
	else
		command.run_command(queryparams)
		log_debug("API: Command called: [query] - Status: [command.statuscode] - Response: [command.response]")
		response["statuscode"] = command.statuscode
		response["response"] = command.response
		response["data"] = command.data
		return json_encode(response)

/proc/reboot_world()
	world.Reboot()

/world/Reboot(reason, hard_reset = FALSE)
	if (!hard_reset && world.TgsAvailable())
		switch (GLOB.config.rounds_until_hard_restart)
			if (-1)
				hard_reset = FALSE
			if (0)
				hard_reset = TRUE
			else
				if (SSpersistent_configuration.rounds_since_hard_restart >= GLOB.config.rounds_until_hard_restart)
					hard_reset = TRUE
					SSpersistent_configuration.rounds_since_hard_restart = 0
				else
					hard_reset = FALSE
					SSpersistent_configuration.rounds_since_hard_restart++
	else if (!world.TgsAvailable() && hard_reset)
		hard_reset = FALSE

	SSpersistent_configuration.save_to_file("data/persistent_config.json")
	Master.Shutdown()

	for(var/thing in GLOB.clients)
		if(!thing)
			continue
		var/client/C = thing
		C?.tgui_panel?.send_roundrestart()
		if(GLOB.config.server) //if you set a server location in config.txt, it sends you there instead of trying to reconnect to the same world address. -- NeoFite
			C << link("byond://[GLOB.config.server]")

	world.TgsReboot()

	if (hard_reset)
		log_misc("World hard rebooted at [time_stamp()].")
		shutdown_logging()
		world.TgsEndProcess()

	log_misc("World soft rebooted at [time_stamp()].")
	shutdown_logging()
	..(reason)

/proc/load_configuration()
	GLOB.config = new()
	GLOB.config.load("config/config.txt")
	GLOB.config.load("config/game_options.txt","game_options")

	if (GLOB.config.age_restrictions_from_file)
		GLOB.config.load("config/age_restrictions.txt", "age_restrictions")

/world/proc/update_status()
    var/new_status = ""

    if (GLOB.config)
        var/server_name = GLOB.config.server_name
        if (server_name)
            new_status += "<b>[server_name]</b> &#8212; "

    new_status += "("
    new_status += "<a href=\"[GLOB.config.forumurl]\">" // Обновите на Discord URL или другой
    new_status += "Discord"
    new_status += ")"
    new_status += "<br>Высокий уровень RolePlay, модифицированный без ответвлений билд Aurora"

    // Устанавливаем статус игры в зависимости от состояния
    if (SSticker.current_state <= GAME_STATE_PREGAME)
        new_status += "<br>СТАТУС ИГРЫ: <b>В ЛОББИ</b><br>"
    else
        new_status += "<br>СТАТУС ИГРЫ: <b>ИДЁТ ИГРА</b><br>"

    // Обновление статуса
    if (src.status != new_status)
        src.status = new_status

#define FAILED_DB_CONNECTION_CUTOFF 5

/hook/startup/proc/load_databases()
	if(!GLOB.config.sql_enabled)
		log_world("ERROR: Database Connection disabled. - Skipping Connection Establishment")
		return 1
	//Construct the database object from an init file.
	GLOB.dbcon = initialize_database_object("config/dbconfig.txt")

	if(!setup_database_connection(GLOB.dbcon))
		log_world("ERROR: Your server failed to establish a connection with the configured database.")
	else
		log_world("Database connection established.")
	return 1

/proc/initialize_database_object(var/filename)
	if (!filename)
		// The code is written in a manner that is spasses out whenever dbcon = null, so we just make a dummy DB object.
		return new/DBConnection()

	var/list/data = list("address", "port", "database", "login", "password")

	var/list/Lines = file2list(filename)

	if (!Lines)
		// Return dummy object for safety.
		return new/DBConnection()

	for (var/t in Lines)
		if (!t)
			continue

		t = trim(t)
		if (length(t) == 0)
			continue
		else if (copytext(t, 1, 2) == "#")
			continue

		var/pos = findtext(t, " ")
		var/name = null
		var/value = null

		name = lowertext(copytext(t, 1, pos))
		value = copytext(t, pos + 1)

		if (!name)
			continue

		if (name in data)
			data[name] = value
		else
			log_misc("Unknown setting while setting up database connection. Filename: '[filename]', value: '[value]'.")

	return new/DBConnection(data["address"], data["port"], data["database"], data["login"], data["password"])

/proc/setup_database_connection(var/DBConnection/con)
	if (!con)
		log_world("ERROR: No DBConnection object passed to setup_database_connection().")
		return 0

	if (con.failed_connections > FAILED_DB_CONNECTION_CUTOFF)	//If it failed to establish a connection more than 5 times in a row, don't bother attempting to conenct anymore.
		return 0

	con.Connect()
	. = con.IsConnected()
	if ( . )
		con.failed_connections = 0	//If this connection succeeded, reset the failed connections counter.
	else
		con.failed_connections++		//If it failed, increase the failed connections counter.
		con.last_fail = world.timeofday

#ifdef UNIT_TEST
		// UTs are presumed public. Change this to hide your shit.
		log_world("ERROR: Database connection failed with message:")
		log_world("ERROR: [con.ErrorMsg()]")
#else
		log_world("ERROR: [time2text(con.last_fail, "hh:mm:ss")]: Database connection failed (try #[con.failed_connections]/[FAILED_DB_CONNECTION_CUTOFF])")
		log_world("ERROR: [con.ErrorMsg()]")
#endif

	return .

//This proc ensures that the connection to the feedback database (global variable dbcon) is established
/proc/establish_db_connection(var/DBConnection/con)
	if (!GLOB.config.sql_enabled)
		return FALSE

	if (!con)
		log_sql("ERROR: No DBConnection object passed to establish_db_connection() proc.")
		return FALSE

	if (con.failed_connections > FAILED_DB_CONNECTION_CUTOFF)
		if(world.timeofday < con.last_fail + 100) // 10 seconds
			log_sql("ERROR: DB connection cutoff exceeded for a database object in establish_db_connection().")
			return FALSE

		con.failed_connections = 0

	if (!con.IsConnected())
		return setup_database_connection(con)
	else
		return TRUE

/world/proc/incrementMaxZ()
	maxz++

/world/proc/change_fps(new_value = 20)
	if(new_value <= 0)
		CRASH("change_fps() called with [new_value] new_value.")
	if(fps == new_value)
		return //No change required.

	fps = new_value
	on_tickrate_change()

/world/proc/change_tick_lag(new_value = 0.5)
	if(new_value <= 0)
		CRASH("change_tick_lag() called with [new_value] new_value.")
	if(tick_lag == new_value)
		return //No change required.

	tick_lag = new_value
	on_tickrate_change()

/world/proc/on_tickrate_change()
	SStimer?.reset_buckets()


/world/proc/init_byond_tracy()
	var/library

	switch (system_type)
		if (MS_WINDOWS)
			library = "prof.dll"
		if (UNIX)
			library = "libprof.so"
		else
			CRASH("Unsupported platform: [system_type]")

	var/init_result = call_ext(library, "init")("block")
	if (init_result != "0")
		CRASH("Error initializing byond-tracy: [init_result]")

/world/proc/init_debugger()
	var/dll = GetConfig("env", "AUXTOOLS_DEBUG_DLL")
	if (dll)
		call_ext(dll, "auxtools_init")()
		enable_debugging()

/world/proc/load_motd()
	GLOB.motd = file2text("config/motd.txt")

#undef FAILED_DB_CONNECTION_CUTOFF
