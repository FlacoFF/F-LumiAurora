/*
	Click code cleanup
	~Sayu
*/

// 1 decisecond click delay (above and beyond mob/next_move)
/mob/var/next_click = 0

/*
	Before anything else, defer these calls to a per-mobtype handler.  This allows us to
	remove istype() spaghetti code, but requires the addition of other handler procs to simplify it.

	Alternately, you could hardcode every mob's variation in a flat ClickOn() proc; however,
	that's a lot of code duplication and is hard to maintain.

	Note that this proc can be overridden, and is in the case of screen objects.
*/

/atom/Click(location,control,params)
	var/datum/click_handler/click_handler = usr.GetClickHandler()
	click_handler.OnClick(src, params)

/atom/DblClick(var/location, var/control, var/params)
	var/datum/click_handler/click_handler = usr.GetClickHandler()
	click_handler.OnDblClick(src, params)

	if(istype(usr.machine,/obj/machinery/computer/security))
		var/obj/machinery/computer/security/console = usr.machine
		console.jump_on_click(usr,src)

/atom/proc/allow_click_through(var/atom/A, var/params, var/mob/user)
	return FALSE

/turf/allow_click_through(var/atom/A, var/params, var/mob/user)
	return TRUE

/atom/proc/RelayMouseDrag(src_object, over_object, src_location, over_location, src_control, over_control, params, var/mob/user)
	return FALSE

/mob/proc/OnMouseDrag(src_object, over_object, src_location, over_location, src_control, over_control, params)
	if(istype(loc, /atom))
		var/atom/A = loc
		if(A.RelayMouseDrag(src_object, over_object, src_location, over_location, src_control, over_control, params, src))
			return

	if(over_object)
		if(!incapacitated())
			var/obj/item/gun/gun = get_active_hand()
			if(istype(gun))
				set_dir(get_dir(src, over_object))
				gun.Fire(get_turf(over_object), src, params, (get_dist(over_object, src) <= 1), FALSE)

/**
 * Standard mob ClickOn()
 * Handles exceptions: middle click, modified clicks, mech actions
 *
 * After that, mostly just check your state, check whether you're holding an item,
 * check whether you're adjacent to the target, then pass off the click to whoever
 * is receiving it.
 * The most common are:
 * * [mob/proc/UnarmedAttack] (atom,adjacent) - used here only when adjacent, with no item in hand; in the case of humans, checks gloves
 * * [atom/proc/attackby] (item,user) - used only when adjacent
 * * [obj/item/proc/afterattack] (atom,user,adjacent,params) - used both ranged and adjacent
 * * [mob/proc/RangedAttack] (atom,modifiers) - used only ranged, only used for tk and laser eyes but could be changed
 */
/mob/proc/ClickOn(var/atom/A, var/params)

	if(world.time <= next_click) // Hard check, before anything else, to avoid crashing
		return

	next_click = world.time + 1

	if(istype(loc, /mob/living/heavy_vehicle) && !(A in src.contents))
		var/mob/living/heavy_vehicle/M = loc
		return M.ClickOn(A, params, src)

	// pAI handling
	if(istype(loc.loc, /mob/living/bot))
		var/mob/living/bot/B = loc.loc
		if(!B.on)
			to_chat(src, SPAN_WARNING("\The [B] isn't turned on!"))
			return
		return B.ClickOn(A, params)

	var/list/modifiers = params2list(params)
	if(modifiers["right"])
		RightClickOn(A)
		return TRUE
	if(modifiers["shift"] && modifiers["ctrl"])
		CtrlShiftClickOn(A)
		return TRUE
	if(modifiers["shift"] && modifiers["middle"])
		pointed(A)
		return TRUE
	if(modifiers["middle"])
		MiddleClickOn(A)
		return TRUE
	if(modifiers["shift"])
		ShiftClickOn(A)
		return FALSE
	if(modifiers["alt"]) // alt and alt-gr (rightalt)
		AltClickOn(A)
		return
	if(modifiers["ctrl"])
		CtrlClickOn(A)
		return TRUE

	if(stat || paralysis || stunned || weakened)
		return

	face_atom(A) // change direction to face what you clicked on

	if(!canClick()) // in the year 2000...
		return

	if(restrained())
		setClickCooldown(10)
		RestrainedClickOn(A)
		return 1

	if(in_throw_mode && (isturf(A) || isturf(A.loc)) && throw_item(A))
		trigger_aiming(TARGET_CAN_CLICK)
		throw_mode_off()
		return TRUE

	var/obj/item/W = get_active_hand()

	if(W == A) // Handle attack_self
		W.attack_self(src)
		trigger_aiming(TARGET_CAN_CLICK)
		if(hand)
			update_inv_l_hand(0)
		else
			update_inv_r_hand(0)
		return 1

	//Atoms on your person
	// A is your location but is not a turf; or is on you (backpack); or is on something on you (box in backpack); sdepth is needed here because contents depth does not equate inventory storage depth.
	var/sdepth = A.storage_depth(src)
	if((!isturf(A) && A == loc) || (sdepth != -1 && sdepth <= 1))
		// faster access to objects already on you
		if(A.loc != src)
			setMoveCooldown(10) //getting something out of a backpack

		if(W)
			var/resolved = W.resolve_attackby(A, src, params)
			if(!resolved && A && W)
				W.afterattack(A, src, 1, params) // 1 indicates adjacency
		else
			if(ismob(A)) // No instant mob attacking
				setClickCooldown(DEFAULT_ATTACK_COOLDOWN)
			UnarmedAttack(A, 1)

		trigger_aiming(TARGET_CAN_CLICK)
		return 1

	if(!isturf(loc)) // This is going to stop you from telekinesing from inside a closet, but I don't shed many tears for that
		return

	//Atoms on turfs (not on your person)
	// A is a turf or is on a turf, or in something on a turf (pen in a box); but not something in something on a turf (pen in a box in a backpack)
	sdepth = A.storage_depth_turf()
	if(isturf(A) || isturf(A.loc) || (sdepth != -1 && sdepth <= 1))
		if(A.Adjacent(src) || (W && W.attack_can_reach(src, A, W.reach)) ) // see adjacent.dm
			if(W)
				// Return 1 in attackby() to prevent afterattack() effects (when safely moving items for example)
				var/resolved = W.resolve_attackby(A,src, params)
				if(!resolved && A && W)
					W.afterattack(A, src, 1, params) // 1: clicking something Adjacent
			else
				if(ismob(A)) // No instant mob attacking
					setClickCooldown(DEFAULT_ATTACK_COOLDOWN)
				UnarmedAttack(A, 1)

			trigger_aiming(TARGET_CAN_CLICK)
			return
		else // non-adjacent click
			if(W)
				W.afterattack(A, src, 0, params) // 0: not Adjacent
			else
				RangedAttack(A, params)

			trigger_aiming(TARGET_CAN_CLICK)
	return 1

/mob/proc/setClickCooldown(var/timeout)
	next_move = max(world.time + timeout, next_move)

/mob/proc/canClick()
	if(GLOB.config.no_click_cooldown || next_move <= world.time)
		return 1
	return 0

// Default behavior: ignore double clicks, the second click that makes the doubleclick call already calls for a normal click
/mob/proc/DblClickOn(var/atom/A, var/params)
	return

/*
	Translates into attack_hand, etc.

	Note: proximity_flag here is used to distinguish between normal usage (flag=1),
	and usage when clicking on things telekinetically (flag=0).  This proc will
	not be called at ranged except with telekinesis.

	proximity_flag is not currently passed to attack_hand, and is instead used
	in human click code to allow glove touches only at melee range.
*/
/mob/proc/UnarmedAttack(var/atom/A, var/proximity_flag)
	return

/mob/living/UnarmedAttack(var/atom/A, var/proximity_flag)
	if(!(GAME_STATE & RUNLEVELS_PLAYING))
		to_chat(src, "You cannot attack people before the game has started.")
		return FALSE

	if(stat)
		return FALSE

	if(check_sting(src, A))
		return FALSE

	return 1

/**
 * Ranged unarmed attack:
 *
 * This currently is just a default for all mobs, involving
 * laser eyes and telekinesis.  You could easily add exceptions
 * for things like ranged glove touches, spitting alien acid/neurotoxin,
 * animals lunging, etc.
 */
/mob/proc/RangedAttack(atom/A, params)
	SHOULD_NOT_SLEEP(TRUE)

	if((mutations & LASER_EYES) && a_intent == I_HURT)
		LaserEyes(A, params) // moved into a proc below
		return
	A.attack_ranged(src, params)

/*
	Restrained ClickOn

	Used when you are handcuffed and click things.
	Not currently used by anything but could easily be.
*/
/mob/proc/RestrainedClickOn(var/atom/A)
	return

/*
	Middle click
*/
/mob/proc/MiddleClickOn(var/atom/A)
	if(A.handle_middle_mouse_click(src))
		return
	swap_hand()

/mob/living/carbon/human/MiddleClickOn(var/atom/A)
	if(species.handle_middle_mouse_click(src, A))
		return
	return ..()

// In case of use break glass
/*
/atom/proc/MiddleClick(var/mob/M as mob)
	return
*/

/*
	Shift click
	For most mobs, examine.
	This is overridden in ai.dm
*/
/mob/proc/ShiftClickOn(var/atom/A)
	A.ShiftClick(src)
	return

/atom/proc/ShiftClick(var/mob/user)
	if(user.can_examine())
		examinate(user, src)

/*
	Ctrl click
	For most objects, pull
*/
/mob/proc/CtrlClickOn(var/atom/A)
	A.CtrlClick(src)
	return

/atom/proc/CtrlClick(var/mob/user)
	return

/atom/movable/CtrlClick(var/mob/user)
	if(Adjacent(user))
		user.start_pulling(src)

/*
	Alt click
	Unused except for AI
*/
/mob/proc/AltClickOn(var/atom/A)
	A.AltClick(src)
	return

/atom/proc/AltClick(var/mob/user)
	var/turf/T = get_turf(src)
	if(!T || !user.TurfAdjacent(T))
		return FALSE
	if(T && (isturf(loc) || isturf(src)) && user.TurfAdjacent(T))
		user.set_listed_turf(T)

/mob/proc/TurfAdjacent(var/turf/T)
	return T.AdjacentQuick(src)

/mob/proc/RightClickOn(atom/A)
	A.RightClick(src)

/atom/proc/RightClick(mob/user)
	return

/*
	Control+Shift click
	Unused except for AI
*/
/mob/proc/CtrlShiftClickOn(var/atom/A)
	A.CtrlShiftClick(src)
	return

/atom/proc/CtrlShiftClick(var/mob/user)
	return

/*
	Misc helpers

	Laser Eyes: as the name implies, handles this since nothing else does currently
	face_atom: turns the mob towards what you clicked on
*/
/mob/proc/LaserEyes(atom/A, params)
	return

/mob/living/LaserEyes(atom/A, params)
	setClickCooldown(4)
	var/turf/T = get_turf(src)
	src.visible_message(SPAN_DANGER("\The [src]'s eyes flare with ruby light!"))
	var/obj/projectile/beam/LE = new (T)
	LE.muzzle_type = /obj/effect/projectile/muzzle/eyelaser
	LE.tracer_type = /obj/effect/projectile/tracer/eyelaser
	LE.impact_type = /obj/effect/projectile/impact/eyelaser
	playsound(usr.loc, 'sound/weapons/wave.ogg', 75, 1)
	LE.launch_projectile(A, zone_sel? zone_sel.selecting : null, src, params)

/mob/living/carbon/human/LaserEyes(atom/A, params)
	if(nutrition <= 0)
		to_chat(src, SPAN_WARNING("You're out of energy!  You need food!"))
		return
	..()
	adjustNutritionLoss(rand(1,5))
	handle_regular_hud_updates()

// Simple helper to face what you clicked on, in case it should be needed in more than one place
/mob/proc/face_atom(var/atom/A, var/force_face = FALSE)
	if(!A || !x || !y || !A.x || !A.y) return
	var/dx = A.x - x
	var/dy = A.y - y

	var/direction
	if (loc == A.loc && A.atom_flags & ATOM_FLAG_CHECKS_BORDER)
		direction = A.dir
	else if (!dx && !dy)
		return
	else if(abs(dx) < abs(dy))
		if(dy > 0)
			direction = NORTH
		else
			direction = SOUTH
	else
		if(dx > 0)
			direction = EAST
		else
			direction = WEST

	if(direction != dir)
		facedir(direction, force_face)

var/global/list/click_catchers

/obj/screen/click_catcher
	icon = 'icons/mob/screen_gen.dmi'
	icon_state = "click_catcher"
	plane = CLICKCATCHER_PLANE
	mouse_opacity = MOUSE_OPACITY_OPAQUE
	screen_loc = "CENTER-7,CENTER-7"

/obj/screen/click_catcher/Destroy()
	SHOULD_CALL_PARENT(FALSE)
	return QDEL_HINT_LETMELIVE

/proc/create_click_catcher()
	. = list()
	for(var/i = 0, i<15, i++)
		for(var/j = 0, j<15, j++)
			var/obj/screen/click_catcher/CC = new()
			CC.screen_loc = "NORTH-[i],EAST-[j]"
			. += CC

/obj/screen/click_catcher/Click(location, control, params)
	var/list/modifiers = params2list(params)
	if(modifiers["middle"] && istype(usr, /mob/living/carbon))
		var/mob/living/carbon/C = usr
		C.swap_hand()
	else
		var/turf/T = screen_loc2turf(screen_loc, get_turf(usr))
		if(T)
			T.Click(location, control, params)
	. = 1

// Suppress the mouse macros
/client/var/has_mouse_macro_warning
/mob/proc/LogMouseMacro(verbused, params)
	if(!client)
		return
	if(!client.has_mouse_macro_warning) // Log once
		log_admin("[key_name(usr)] attempted to use a mouse macro: [verbused] [params]")
/mob/verb/ClickSubstitute(params as command_text)
	set hidden = 1
	set name = ".click"
	LogMouseMacro(".click", params)
/mob/verb/DblClickSubstitute(params as command_text)
	set hidden = 1
	set name = ".dblclick"
	LogMouseMacro(".dblclick", params)
/mob/verb/MouseSubstitute(params as command_text)
	set hidden = 1
	set name = ".mouse"
	LogMouseMacro(".mouse", params)

/*
	Custom Click Handlinig
*/

/mob
	var/datum/stack/click_handlers


var/const/CLICK_HANDLER_NONE = 0
var/const/CLICK_HANDLER_REMOVE_ON_MOB_LOGOUT = 1
var/const/CLICK_HANDLER_ALL = (~0)

/datum/click_handler
	var/mob/user
	var/handler_flags = CLICK_HANDLER_NONE

/datum/click_handler/New(mob/user)
	..()
	src.user = user
	if(handler_flags & CLICK_HANDLER_REMOVE_ON_MOB_LOGOUT)
		RegisterSignal(user, COMSIG_MOB_LOGOUT, /datum/click_handler/proc/OnMobLogout, TRUE)

/datum/click_handler/Destroy()
	if(handler_flags & CLICK_HANDLER_REMOVE_ON_MOB_LOGOUT)
		UnregisterSignal(user, COMSIG_MOB_LOGOUT)
	user = null
	. = ..()

/datum/click_handler/proc/Enter()
	return

/datum/click_handler/proc/Exit()
	return


/datum/click_handler/proc/OnMobLogout()
	user.RemoveClickHandler(src)

/datum/click_handler/proc/OnClick(var/atom/A, var/params)
	return

/datum/click_handler/proc/OnDblClick(var/atom/A, var/params)
	return

/datum/click_handler/default/OnClick(var/atom/A, var/params)
	user.ClickOn(A, params)

/datum/click_handler/default/OnDblClick(var/atom/A, var/params)
	user.DblClickOn(A, params)

/mob/proc/GetClickHandler(var/datum/click_handler/popped_handler)
	if(!click_handlers)
		click_handlers = new()
	if(click_handlers.is_empty())
		PushClickHandler(/datum/click_handler/default)
	return click_handlers.Top()

/mob/proc/RemoveClickHandler(var/datum/click_handler/click_handler)
	if(!click_handlers)
		return

	var/was_top = click_handlers.Top() == click_handler

	if(was_top)
		click_handler.Exit()
	click_handlers.Remove(click_handler)
	qdel(click_handler)

	if(!was_top)
		return
	click_handler = click_handlers.Top()
	if(click_handler)
		click_handler.Enter()

/mob/proc/PopClickHandler()
	if(!click_handlers)
		return
	RemoveClickHandler(click_handlers.Top())

/mob/proc/PushClickHandler(var/datum/click_handler/new_click_handler_type)
	if((initial(new_click_handler_type.handler_flags) & CLICK_HANDLER_REMOVE_ON_MOB_LOGOUT) && !client)
		return FALSE
	if(!click_handlers)
		click_handlers = new()
	var/datum/click_handler/click_handler = click_handlers.Top()
	if(click_handler)
		click_handler.Exit()

	click_handler = new new_click_handler_type(src)
	click_handler.Enter()
	click_handlers.Push(click_handler)
