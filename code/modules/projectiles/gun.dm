/*
	Defines a firing mode for a gun.

	burst			number of shots fired when the gun is used
	burst_delay 	tick delay between shots in a burst
	fire_delay		tick delay after the last shot before the gun may be used again
	move_delay		tick delay after the last shot before the player may move
	dispersion		dispersion of each shot in the burst measured in tiles per 7 tiles angle ratio
	accuracy		accuracy modifier applied to each shot in tiles.
					applied on top of the base weapon accuracy.
*/
/datum/firemode
	var/name = "default"
	var/burst = 1
	var/burst_delay = null
	var/fire_delay = null
	var/move_delay = 1
	var/list/accuracy = list(0)
	var/list/dispersion = list(0)

//using a list makes defining fire modes for new guns much nicer,
//however we convert the lists to datums in part so that firemodes can be VVed if necessary.
/datum/firemode/New(list/properties = null)
	..()
	if(!properties) return

	for(var/propname in vars)
		if(!isnull(properties[propname]))
			src.vars[propname] = properties[propname]

//Parent gun type. Guns are weapons that can be aimed at mobs and act over a distance
/obj/item/weapon/gun
	name = "gun"
	desc = "Its a gun. It's pretty terrible, though."
	icon = 'icons/obj/gun.dmi'
	item_icons = list(//DEPRECATED. USE CONTAINED SPRITES IN FUTURE
		slot_l_hand_str = 'icons/mob/items/lefthand_guns.dmi',
		slot_r_hand_str = 'icons/mob/items/righthand_guns.dmi',
		)
	icon_state = "detective"
	item_state = "gun"
	flags =  CONDUCT
	slot_flags = SLOT_BELT|SLOT_HOLSTER
	matter = list(DEFAULT_WALL_MATERIAL = 2000)
	w_class = 3
	throwforce = 5
	throw_speed = 4
	throw_range = 5
	force = 5
	origin_tech = "combat=1"
	attack_verb = list("struck", "hit", "bashed")
	zoomdevicename = "scope"

	var/fire_delay = 6 	//delay after shooting before the gun can be used again
	var/burst_delay = 2	//delay between shots, if firing in bursts
	var/fire_sound = 'sound/weapons/Gunshot.ogg'
	var/fire_sound_text = "gunshot"
	var/recoil = 0		//screen shake
	var/silenced = 0
	var/muzzle_flash = 3
	var/accuracy = 0   //accuracy is measured in tiles. +1 accuracy means that everything is effectively one tile closer for the purpose of miss chance, -1 means the opposite. launchers are not supported, at the moment.
	var/scoped_accuracy = null

	var/next_fire_time = 0

	var/sel_mode = 1 //index of the currently selected mode
	var/list/firemodes = list()
	var/firemode_type = /datum/firemode //for subtypes that need custom firemode data

	//wielding information
	var/fire_delay_wielded = 0
	var/recoil_wielded = 0
	var/accuracy_wielded = 0
	var/wielded = 0


	//aiming system stuff
	var/keep_aim = 1 	//1 for keep shooting until aim is lowered
						//0 for one bullet after tarrget moves and aim is lowered
	var/multi_aim = 0 //Used to determine if you can target multiple people.
	var/tmp/list/mob/living/aim_targets //List of who yer targeting.
	var/tmp/mob/living/last_moved_mob //Used to fire faster at more than one person.
	var/tmp/told_cant_shoot = 0 //So that it doesn't spam them with the fact they cannot hit them.
	var/tmp/lock_time = -100

/obj/item/weapon/gun/New()
	..()
	if(!firemodes.len)
		firemodes += new firemode_type
	else
		for(var/i in 1 to firemodes.len)
			firemodes[i] = new firemode_type(firemodes[i])

	if(isnull(scoped_accuracy))
		scoped_accuracy = accuracy

//Checks whether a given mob can use the gun
//Any checks that shouldn't result in handle_click_empty() being called if they fail should go here.
//Otherwise, if you want handle_click_empty() to be called, check in consume_next_projectile() and return null there.
/obj/item/weapon/gun/proc/special_check(var/mob/user)
	if(!istype(user, /mob/living))
		return 0
	if(!user.IsAdvancedToolUser())
		return 0

	var/mob/living/M = user

	if(HULK in M.mutations)
		M << "<span class='danger'>Your fingers are much too large for the trigger guard!</span>"
		return 0
	if((CLUMSY in M.mutations) && prob(40)) //Clumsy handling
		var/obj/P = consume_next_projectile()
		if(P)
			if(process_projectile(P, user, user, pick("l_foot", "r_foot")))
				handle_post_fire(user, user)
				user.visible_message(
					"<span class='danger'>[user] shoots \himself in the foot with \the [src]!</span>",
					"<span class='danger'>You shoot yourself in the foot with \the [src]!</span>"
					)
				M.drop_item()
		else
			handle_click_empty(user)
		return 0
	return 1

/obj/item/weapon/gun/emp_act(severity)
	for(var/obj/O in contents)
		O.emp_act(severity)

/obj/item/weapon/gun/afterattack(atom/A, mob/living/user, adjacent, params)
	if(adjacent) return //A is adjacent, is the user, or is on the user's person

	//decide whether to aim or shoot normally
	var/aiming = 0
	if(user && user.client && !(A in aim_targets))
		if(user.client.gun_mode)
			aiming = PreFire(A,user,params) //They're using the new gun system, locate what they're aiming at.

	if (!aiming)
		Fire(A,user,params) //Fire normally and always.

/obj/item/weapon/gun/attack(atom/A, mob/living/user, def_zone)
	if (A == user && user.zone_sel.selecting == "mouth" && !mouthshoot)
		handle_suicide(user)
	else if(user.a_intent == I_HURT) //point blank shooting
		Fire(A, user, pointblank=1)
	else
		return ..() //Pistolwhippin'

/obj/item/weapon/gun/proc/Fire(atom/target, mob/living/user, clickparams, pointblank=0, reflex=0)
	if(!user || !target) return

	add_fingerprint(user)

	if(!special_check(user))
		return

	if(world.time < next_fire_time)
		if (world.time % 3) //to prevent spam
			user << "<span class='warning'>[src] is not ready to fire again!</span>"
		return

	//unpack firemode data
	var/datum/firemode/firemode = firemodes[sel_mode]
	var/_burst = firemode.burst
	var/_burst_delay = isnull(firemode.burst_delay)? src.burst_delay : firemode.burst_delay
	var/_fire_delay = isnull(firemode.fire_delay)? src.fire_delay : firemode.fire_delay
	if(can_wield() && !wielded && firemode.fire_delay)
		_fire_delay += initial(fire_delay) / 2
	var/_move_delay = firemode.move_delay

	var/shoot_time = (_burst - 1)*_burst_delay
	user.next_move = world.time + shoot_time  //no clicking on things while shooting
	if(user.client) user.client.move_delay = world.time + shoot_time //no moving while shooting either
	next_fire_time = world.time + shoot_time

	//actually attempt to shoot
	var/turf/targloc = get_turf(target) //cache this in case target gets deleted during shooting, e.g. if it was a securitron that got destroyed.
	for(var/i in 1 to _burst)
		var/obj/projectile = consume_next_projectile(user)
		if(!projectile)
			handle_click_empty(user)
			break

		var/acc = firemode.accuracy[min(i, firemode.accuracy.len)]
		var/disp = firemode.dispersion[min(i, firemode.dispersion.len)]
		process_accuracy(projectile, user, target, acc, disp)

		if(pointblank)
			process_point_blank(projectile, user, target)

		if(process_projectile(projectile, user, target, user.zone_sel.selecting, clickparams))
			handle_post_fire(user, target, pointblank, reflex, i == _burst)
			update_icon()

		if(i < _burst)
			sleep(_burst_delay)

		if(!(target && target.loc))
			target = targloc
			pointblank = 0

	update_held_icon()

	//update timing
	user.next_move = world.time + 4
	if(user.client) user.client.move_delay = world.time + _move_delay
	next_fire_time = world.time + _fire_delay

	if(muzzle_flash)
		set_light(0)

//obtains the next projectile to fire
/obj/item/weapon/gun/proc/consume_next_projectile()
	return null

//used by aiming code
/obj/item/weapon/gun/proc/can_hit(atom/target as mob, var/mob/living/user as mob)
	if(!special_check(user))
		return 2
	//just assume we can shoot through glass and stuff. No big deal, the player can just choose to not target someone
	//on the other side of a window if it makes a difference. Or if they run behind a window, too bad.
	return check_trajectory(target, user)

//called if there was no projectile to shoot
/obj/item/weapon/gun/proc/handle_click_empty(mob/user)
	if (user)
		user.visible_message("*click click*", "<span class='danger'>*click*</span>")
	else
		src.visible_message("*click click*")
	playsound(src.loc, 'sound/weapons/empty.ogg', 100, 1)

//called after successfully firing
/obj/item/weapon/gun/proc/handle_post_fire(mob/user, atom/target, var/pointblank=0, var/reflex=0, var/playemote = 1)
	if(silenced)
		playsound(user, fire_sound, 10, 1)
	else
		playsound(user, fire_sound, 50, 1)

		if (playemote)
			if(reflex)
				user.visible_message(
					"<span class='reflex_shoot'><b>\The [user] fires \the [src][pointblank ? " point blank at \the [target]":""] by reflex!<b></span>",
					"<span class='reflex_shoot'>You fire \the [src] by reflex!</span>",
					"You hear a [fire_sound_text]!"
					)
			else
				user.visible_message(
					"<span class='danger'>\The [user] fires \the [src][pointblank ? " point blank at \the [target]":""]!</span>",
					"<span class='warning'>You fire \the [src]!</span>",
					"You hear a [fire_sound_text]!"
					)

		if(muzzle_flash)
			set_light(muzzle_flash)

	if(recoil)
		spawn()
			shake_camera(user, recoil+1, recoil)
	update_icon()


/obj/item/weapon/gun/proc/process_point_blank(obj/projectile, mob/user, atom/target)
	var/obj/item/projectile/P = projectile
	if(!istype(P))
		return //default behaviour only applies to true projectiles

	//default point blank multiplier
	var/damage_mult = 1.3

	//determine multiplier due to the target being grabbed
	if(ismob(target))
		var/mob/M = target
		if(M.grabbed_by.len)
			var/grabstate = 0
			for(var/obj/item/weapon/grab/G in M.grabbed_by)
				grabstate = max(grabstate, G.state)
			if(grabstate >= GRAB_NECK)
				damage_mult = 2.5
			else if(grabstate >= GRAB_AGGRESSIVE)
				damage_mult = 1.5
	P.damage *= damage_mult
	//you can't miss at point blank..
	P.can_miss = 1

/obj/item/weapon/gun/proc/process_accuracy(obj/projectile, mob/user, atom/target, acc_mod, dispersion)
	var/obj/item/projectile/P = projectile
	if(!istype(P))
		return //default behaviour only applies to true projectiles

	//Accuracy modifiers
	P.accuracy = accuracy + acc_mod
	P.dispersion = dispersion

	//Increasing accuracy across the board, ever so slightly
	P.accuracy += 1

	//accuracy bonus from aiming
	if (aim_targets && (target in aim_targets))
		//If you aim at someone beforehead, it'll hit more often.
		//Kinda balanced by fact you need like 2 seconds to aim
		//As opposed to no-delay pew pew
		P.accuracy += 2

//does the actual launching of the projectile
/obj/item/weapon/gun/proc/process_projectile(obj/projectile, mob/user, atom/target, var/target_zone, var/params=null)
	var/obj/item/projectile/P = projectile
	if(!istype(P))
		return 0 //default behaviour only applies to true projectiles

	if(params)
		P.set_clickpoint(params)

	//shooting while in shock
	var/x_offset = 0
	var/y_offset = 0
	if(istype(user, /mob/living/carbon))
		var/mob/living/carbon/mob = user
		if(mob.shock_stage > 120)
			y_offset = rand(-2,2)
			x_offset = rand(-2,2)
		else if(mob.shock_stage > 70)
			y_offset = rand(-1,1)
			x_offset = rand(-1,1)

	return !P.launch_from_gun(target, user, src, target_zone, x_offset, y_offset)

//Suicide handling.
/obj/item/weapon/gun/var/mouthshoot = 0 //To stop people from suiciding twice... >.>
/obj/item/weapon/gun/proc/handle_suicide(mob/living/user)
	if(!ishuman(user))
		return
	var/mob/living/carbon/human/M = user

	mouthshoot = 1
	M.visible_message("\red [user] sticks their gun in their mouth, ready to pull the trigger...")
	if(!do_after(user, 40))
		M.visible_message("\blue [user] decided life was worth living")
		mouthshoot = 0
		return
	var/obj/item/projectile/in_chamber = consume_next_projectile()
	if (istype(in_chamber))
		user.visible_message("<span class = 'warning'>[user] pulls the trigger.</span>")
		if(silenced)
			playsound(user, fire_sound, 10, 1)
		else
			playsound(user, fire_sound, 50, 1)

		in_chamber.on_hit(M)

		if (in_chamber.damage == 0)
			user.show_message("<span class = 'warning'>You feel rather silly, trying to commit suicide with a toy.</span>")
			mouthshoot = 0
			return
		else if (in_chamber.damage_type == HALLOSS)
			user << "<span class = 'notice'>Ow...</span>"
			user.apply_effect(110,AGONY,0)
		else
			log_and_message_admins("[key_name(user)] commited suicide using \a [src]")
			user.apply_damage(in_chamber.damage*2.5, in_chamber.damage_type, "head", used_weapon = "Point blank shot in the mouth with \a [in_chamber]", sharp=1)
			user.death()
		qdel(in_chamber)
		mouthshoot = 0
		return
	else
		handle_click_empty(user)
		mouthshoot = 0
		return

/obj/item/weapon/gun/proc/toggle_scope(var/zoom_amount=2.0)
	//looking through a scope limits your periphereal vision
	//still, increase the view size by a tiny amount so that sniping isn't too restricted to NSEW
	var/zoom_offset = round(world.view * zoom_amount)
	var/view_size = round(world.view + zoom_amount)
	var/scoped_accuracy_mod = zoom_offset

	zoom(zoom_offset, view_size)
	if(zoom)
		accuracy = scoped_accuracy + scoped_accuracy_mod
		if(recoil)
			recoil = round(recoil*zoom_amount+1) //recoil is worse when looking through a scope

//make sure accuracy and recoil are reset regardless of how the item is unzoomed.
/obj/item/weapon/gun/zoom()
	..()
	if(!zoom)
		if(can_wield() && wielded)
			if(accuracy_wielded)
				accuracy = accuracy_wielded
			else
				accuracy = initial(accuracy)
			if(recoil_wielded)
				recoil = recoil_wielded
			else
				recoil = initial(recoil)
		else
			accuracy = initial(accuracy)
			recoil = initial(recoil)

/obj/item/weapon/gun/examine(mob/user)
	..()
	if(firemodes.len > 1)
		var/datum/firemode/current_mode = firemodes[sel_mode]
		user << "The fire selector is set to [current_mode.name]."

/obj/item/weapon/gun/proc/switch_firemodes(mob/user=null)
	sel_mode++
	if(sel_mode > firemodes.len)
		sel_mode = 1
	var/datum/firemode/new_mode = firemodes[sel_mode]
	user << "<span class='notice'>\The [src] is now set to [new_mode.name].</span>"

/obj/item/weapon/gun/attack_self(mob/user)
	if(firemodes.len > 1)
		switch_firemodes(user)

//Handling of rifles and two-handed weapons.
/obj/item/weapon/gun/proc/can_wield()
	return 0

/obj/item/weapon/gun/proc/toggle_wield(mob/user as mob)
	if(!can_wield())
		return
	if(!istype(user.get_active_hand(), /obj/item/weapon/gun))
		user << "<span class='warning'>You need to be holding the [name] in your active hand</span>"
		return
	if(!istype(user, /mob/living/carbon/human))
		user << "<span class='warning'>It's too heavy for you to stabilize properly.</span>"
		return

	var/mob/living/carbon/human/M = user
	if(istype(M.species, /datum/species/monkey))
		user << "<span class='warning'>It's too heavy for you to stabilize properly.</span>"
		return

	if(wielded)
		unwield()
		user << "<span class='notice'>You are no-longer stabilizing the [name] with both hands.</span>"

		var/obj/item/weapon/gun/offhand/O = user.get_inactive_hand()
		if(O && istype(O))
			O.unwield()
		else
			O = user.get_active_hand()
			if(O && istype(O))
				O.unwield()

		return

	else
		if(user.get_inactive_hand())
			user << "<span class='warning'>You need your other hand to be empty.</span>"
			return
		wield()
		user << "<span class='notice'>You stabilize the [initial(name)] with both hands.</span>"

		var/obj/item/weapon/gun/offhand/O = new(user)
		O.name = "[initial(name)] - offhand"
		O.desc = "Your second grip on the [initial(name)]."
		user.put_in_inactive_hand(O)

	return

/obj/item/weapon/gun/proc/unwield()
	wielded = 0
	if(fire_delay_wielded)
		fire_delay = initial(fire_delay)
	if(recoil_wielded)
		recoil = initial(recoil)
	if(accuracy_wielded)
		accuracy = initial(accuracy)

/obj/item/weapon/gun/proc/wield()
	wielded = 1
	if(fire_delay_wielded)
		fire_delay = fire_delay_wielded
	if(recoil_wielded)
		recoil = recoil_wielded
	if(accuracy_wielded)
		accuracy = accuracy_wielded

/obj/item/weapon/gun/mob_can_equip(M as mob, slot)
	//Cannot equip wielded items.
	if(can_wield())
		if(wielded)
			M << "<span class='warning'>Lower the [initial(name)] first!</span>"
			return 0

	return ..()

/obj/item/weapon/gun/dropped(mob/living/user as mob)
	//Unwields the item when dropped, deletes the offhand
	if(can_wield())
		if(user)
			var/obj/item/weapon/gun/O = user.get_inactive_hand()
			if(istype(O))
				O.unwield()
		return unwield()

/obj/item/weapon/gun/pickup(mob/user)
	if(can_wield())
		unwield()

///////////OFFHAND///////////////
/obj/item/weapon/gun/offhand
	w_class = 5.0
	icon = 'icons/obj/weapons.dmi'
	icon_state = "offhand"
	item_state = "nothing"
	name = "offhand"

	unwield()
		qdel(src)

	wield()
		qdel(src)

	dropped(mob/living/user as mob)
		if(user)
			var/obj/item/weapon/gun/O = user.get_inactive_hand()
			if(istype(O))
				user << "<span class='notice'>You are no-longer stabilizing the [name] with both hands.</span>"
				O.unwield()
				unwield()
		if(src)
			qdel(src)

	mob_can_equip(M as mob, slot)
		return 0
