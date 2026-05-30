package main

import "base:runtime"
import "core:log"
import "core:c"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:mem"
import "core:strings"
import k2 "shared:karl2d"
import hm "core:container/handle_map"

// --- Windows High Performance GPU Hint ---
@(export, link_name = "NvOptimusEnablement")
NvOptimusEnablement: c.ulong = 1
@(export, link_name = "AmdPowerXpressRequestingHighPerformance")
AmdPowerXpressRequestingHighPerformance: i32 = 1

WW :: #force_inline proc() -> f32 { return f32(k2.get_screen_width()) }
WH :: #force_inline proc() -> f32 { return f32(k2.get_screen_height()) }

Enemy_Type :: enum {
	Skeleton,
	Elite_Skeleton,
	Wizard,
	Boss,
}

Player :: struct {
	pos:              [2]f32,
	health:           int,
	max_health:       int,
	xp:               int,
	xp_needed:        int,
	level:            int,
	weapons:          [dynamic]^Weapon,
	whip_flash_timer: f32,
	shield_active:    bool,
}

Enemy :: struct {
	pos:             [2]f32,
	health:          int,
	speed:           f32,
	type:            Enemy_Type,
	is_charging:     bool,
	telegraph_timer: f32,
	id:              int, // Unique ID to track across frames safely
	boss_state:      ^Boss_State,
}

Boss_State :: struct {
	self_enemy_id: int,
	pos_x: f32,
	shield_active: bool,
	shield_power: f32,
	visual_scale: f32,
}

Weapon :: struct {
	name:     string,
	damage:   int,
	cooldown: f32,
	behavior: Handle,
}

Projectile :: struct {
	pos:                 [2]f32,
	dir:                 [2]f32,
	speed:               f32,
	damage:              int,
	is_enemy_projectile: bool,
}

Pop_Effect :: struct {
	pos:    [2]f32,
	radius: f32,
	ended:  bool,
}

Game_World :: struct {
	player:              Player,
	enemies:             [dynamic]Enemy,
	gems:                [dynamic][2]f32,
	projectiles:         [dynamic]Projectile,
	pop_effects:         [dynamic]^Pop_Effect,
	exec:                Executor, // Pauses with game
	sys_exec:            Executor, // Runs in real-time
	charge_semaphore:    Semaphore,
	diagnostics:         Diagnostics_DB,
	debug_visible:       bool,
	debug_compact:       bool,
	debug_paused:        bool,
	debug_scroll:        int,
	debug_filter:        [32]u8,
	is_paused:           bool,
	player_damage_timer: f32,
	camera_shake:        f32,
	level_up_scale:      f32,
	boss_fight: 		 bool,
	boss_spawned_at:     int,
	enemy_id_counter:    int,
}

// Helper to find enemy by ID (safest way to handle dynamic arrays in coroutines)
find_enemy :: proc(game: ^Game_World, id: int) -> ^Enemy {
	for &e in game.enemies {
		if e.id == id do return &e
	}
	return nil
}

// Ranged attack for Wizard, Telegraph -> Shoot (Protected by Weak guard)
wizard_attack_behavior :: proc(game: ^Game_World, enemy_id: int) -> Handle {
	// Local coro state
	Payload :: struct {
		game: ^Game_World,
		id:   int,
	}
	p := new(Payload)
	p.game = game
	p.id = enemy_id

	is_alive :: proc(p: ^Payload) -> bool {
		return find_enemy(p.game, p.id) != nil
	}

	context.user_ptr = &game.exec
	res := managed(weak(
		seq(
			sync(
				run(proc(p: ^Payload) -> bool {
					if e := find_enemy(p.game, p.id); e != nil do e.telegraph_timer = 0.8
					return true
				}, p),
				named(wait(0.8), "Telegraph Timer")
			),
			named(run(proc(p: ^Payload) -> bool {
				e := find_enemy(p.game, p.id)
				if e == nil do return true
				dir := linalg.normalize(p.game.player.pos - e.pos)
				append(
					&p.game.projectiles,
					Projectile {
						pos = e.pos,
						dir = dir,
						speed = 240.0,
						damage = 15,
						is_enemy_projectile = true,
					},
				)
				return true
		}, p), "Shoot Fireball")), is_alive, p), p)

	named(res, "Wizard Attack")
	return res
}

// Dash attack for Elites (Protected by Weak + Semaphore)
elite_charge_behavior :: proc(game: ^Game_World, enemy_id: int) -> Handle {
	Payload :: struct {
		game: ^Game_World,
		id:   int,
	}
	p := new(Payload)
	p.game = game
	p.id = enemy_id

	is_alive :: proc(p: ^Payload) -> bool {
		return find_enemy(p.game, p.id) != nil
	}

	context.user_ptr = &game.exec
	res := managed(weak(
		semaphore_scope(&game.charge_semaphore, // only allows two elites to run this dash
			named(seq(
				named(run(proc(p: ^Payload) -> bool { // start charge
					e := find_enemy(p.game, p.id)
					if e == nil do return true
					e.speed *= 3.5
					e.is_charging = true
					return true
				}, p), "Start Dash"),
				named(wait(1.0), "Dash Duration"),
				named(run(proc(p: ^Payload) -> bool { // stop it
					e := find_enemy(p.game, p.id)
					if e == nil do return true
					e.speed /= 3.5
					e.is_charging = false
					return true
			}, p), "End Dash")), "Elite Dash Sequence")
		), is_alive, p), p)

	named(res, "Elite Charge Behavior")
	return res
}

// Visual "Pop" effect (Spawned via Fork)
death_pop_behavior :: proc(game: ^Game_World, pos: [2]f32) -> Handle {
	p := new(Pop_Effect, game.sys_exec.allocator)
	p.pos = pos
	p.ended = false
	p.radius = 0.0

	append(&game.pop_effects, p)

	context.user_ptr = &game.sys_exec
	res := fork(
		named(seq(
			named(tween(0.0, 30.0, 0.8, &p.radius, ease_in_out_elastic), "Expand"),
			named(tween(30.0, 0.0, 0.4, &p.radius, ease_in_out_cubic), "Contract"),
			run(proc(p: ^Pop_Effect) -> bool {
				p.ended = true
				return true
			}, p)
		), "Pop Animation"))

	named(res, "Death Pop Behavior")
	return res
}

whip_behavior :: proc(game: ^Game_World, weapon: ^Weapon) -> Handle {

	Weapon_Payload :: struct {
		game:   ^Game_World,
		weapon: ^Weapon,
	}

	p := new(Weapon_Payload); p.game = game; p.weapon = weapon
	context.user_ptr = &game.exec
	res := managed(loop(
		named(seq(
			named(wait_ptr(&weapon.cooldown), "Whip Cooldown"),
			named(run(proc(p: ^Weapon_Payload) -> bool {
				for &e in p.game.enemies {
					if linalg.distance(e.pos, p.game.player.pos) < 110.0 do e.health -= p.weapon.damage
				}
				p.game.player.whip_flash_timer = 0.15
				return true
			}, p), "Whip Slash")
		), "Whip Cycle")), p)

	named(res, "Whip Weapon Behavior")
	return res
}

fireball_behavior :: proc(game: ^Game_World, weapon: ^Weapon) -> Handle {

	Weapon_Payload :: struct {
		game:   ^Game_World,
		weapon: ^Weapon,
	}

	p := new(Weapon_Payload)
	p.game = game
	p.weapon = weapon
	context.user_ptr = &game.exec
	res := managed(loop(
		named(seq(
			named(wait_ptr(&weapon.cooldown), "Fireball Cooldown"),
			named(run(proc(p: ^Weapon_Payload) -> bool {
				if len(p.game.enemies) == 0 do return true
				nearest := 0
				min_d := f32(99999.0)
				for e, i in p.game.enemies {
					d := linalg.distance(e.pos, p.game.player.pos)
					if d < min_d {
						min_d = d
						nearest = i
					}
				}

				dir := linalg.normalize(p.game.enemies[nearest].pos - p.game.player.pos)
				append(&p.game.projectiles, Projectile{
					pos = p.game.player.pos,
					dir = dir,
					speed = 320.0,
					damage = p.weapon.damage
				})
				return true
			}, p), "Launch Fireball")
		), "Fireball Cycle")), p)

	named(res, "Fireball Weapon Behavior")
	return res
}

level_up_sequence :: proc(game: ^Game_World) -> Handle {
	context.user_ptr = &game.sys_exec
	res := named(seq(
		named(run(proc(g: ^Game_World) -> bool { // pause game
			g.is_paused = true
			g.level_up_scale = 0
			return true
		}, game), "Pause Game"),
		named(tween(0.0, 1.0, 0.4, &game.level_up_scale, ease_in_out_cubic), "Show Shop UI"),
		named(wait_until(proc(g: ^Game_World) -> bool { // until upgrade is not selected, waits here
			if k2.key_went_down(.N1) {
				for &w in g.player.weapons do w.cooldown *= 0.8
				return true
			}
			if k2.key_went_down(.N2) {
				for &w in g.player.weapons do w.damage += 15
				g.player.max_health += 25
				g.player.health = g.player.max_health
				return true
			}
			if k2.key_went_down(.N3) {
				enqueue_node(&g.exec, shield_behavior(g, 5.0))
				return true
			}
			return false
		}, game), "Wait for Player Choice"),
		named(tween(1.0, 0.0, 0.2, &game.level_up_scale, ease_in_out_cubic), "Hide Shop UI"),
		named(run(proc(g: ^Game_World) -> bool {
			g.is_paused = false
			return true
		}, game), "Unpause Game")), "Level Up Sequence")
	return res
}

shield_behavior :: proc(game: ^Game_World, duration: f32) -> Handle {
	context.user_ptr = &game.exec
	res := named(seq(
		named(run(
			proc(g: ^Game_World) -> bool {
				g.player.shield_active = true;
				return true
			},
			game,
		), "Activate Shield"),
		// Race against timer: Stay active until timer wins
		named(race(
			named(wait(duration), "Shield Timer"),
			named(wait_forever(), "Constant Shield")
		), "Shield Active State"),
		named(run(
			proc(g: ^Game_World) -> bool {
				g.player.shield_active = false;
				return true
			},
			game,
		), "Deactivate Shield"),
	), "Shield Behavior")
	return res
}

super_attack_behavior :: proc(game: ^Game_World) -> Handle {
	context.user_ptr = &game.exec
	res := named(seq(
		named(sync(
			named(apply_camera_shake(game, 15.0), "Shake Camera"),
			named(wait(0.5), "Charge Delay")
		), "Charge Phase"),
		named(run(proc(g: ^Game_World) -> bool {
			for i in 0 ..< 12 {
				a := f32(i) * math.PI / 6.0
				append(
					&g.projectiles,
					Projectile {
						pos = g.player.pos,
						dir = {math.cos(a), math.sin(a)},
						speed = 450.0,
						damage = 100,
					},
				)
			}
			return true
		}, game), "Radial Burst")), "Super Attack")
	return res
}

apply_camera_shake :: proc(game: ^Game_World, amount: f32) -> Handle {
	return named(tween(amount, 0.0, 0.4, &game.camera_shake), "Camera Shake")
}

spawner_behavior :: proc(game: ^Game_World) -> Handle {
	spawn :: proc(game: ^Game_World, type: Enemy_Type) -> ^Enemy {
		game.enemy_id_counter += 1
		angle := rand.float32_range(0, 2 * math.PI)
		dist := f32(450.0)
		if type == .Wizard do dist = 500.0

		hp := 25
		spd := f32(80.0)
		switch type {
		case .Elite_Skeleton:
			hp = 100; spd = 65.0
		case .Wizard:
			hp = 40; spd = 45.0; dist = 500.0
		case .Boss:
			hp = 600; spd = 50.0; dist = 400.0
		case .Skeleton:
		}

		append(
			&game.enemies,
			Enemy {
				pos = game.player.pos + {math.cos(angle), math.sin(angle)} * dist,
				health = hp,
				speed = spd,
				type = type,
				id = game.enemy_id_counter,
				boss_state = nil,
			},
		)

		boss_idx := len(game.enemies) - 1
		boss := &game.enemies[boss_idx]
		if type == .Boss {
			bs := new(Boss_State)
			bs.self_enemy_id = boss.id
			bs.pos_x = boss.pos.x
			bs.visual_scale = 1.0
			boss.boss_state = bs
		}

		return &game.enemies[boss_idx]
	}
	exec := &game.exec
	context.user_ptr = exec
	res := named(loop(
		named(seq(
			named(select(
				named(seq(
					named(check(proc(g: ^Game_World) -> bool {
							return g.player.level > 0 && g.player.level % 2 == 0 && g.boss_spawned_at != g.player.level
						}, game), "Check Boss Conditions"),
					named(run(proc(g: ^Game_World) -> bool {
							g.boss_spawned_at = g.player.level
							g.boss_fight = true // lock spawning of mobs until boss is defeated
							boss := spawn(g, .Boss)
							{
								context.user_ptr = &g.sys_exec
								enqueue_node(&g.sys_exec, apply_camera_shake(g, 10.0))
							}
							{
								context.user_ptr = &g.exec
								enqueue_node(&g.exec, boss_ai_timeline(g, boss.boss_state))
							}
							return true
                        }, game), "Spawn Boss"),
					named(wait_until(proc(g: ^Game_World) -> bool {
						return g.boss_fight == false
					}, game), "Boss Fight Defeated?")
				), "Boss Spawn Branch"),
				named(seq(
					named(race(
						named(wait(3.0), "Spawn Interval"),
						named(wait_until(proc(g: ^Game_World) -> bool {
							return g.player.health < 30
						}, game), "Urgent Spawn Trigger")
					), "Normal Wait"),
					named(run(proc(g: ^Game_World) -> bool {
						spawn(g, .Skeleton)
						if rand.float32() < 0.4 do spawn(g, .Wizard)
						if rand.float32() < 0.2 do spawn(g, .Elite_Skeleton)
						return true
					}, game), "Spawn Mob")
				), "Normal Spawn Branch")
			), "Spawn Logic")
		), "Spawner Main Loop")), "Enemy Spawner Behavior")
	return res
}

boss_ai_timeline :: proc(game: ^Game_World, boss: ^Boss_State) -> Handle {
	Boss_AI_Payload :: struct {
		game: ^Game_World,
		boss: ^Boss_State,
	}

	context.user_ptr = &game.exec
	p := new(Boss_AI_Payload)
	p.game = game
	p.boss = boss

	center_x := WW() / 2

	is_alive :: proc(p: ^Boss_AI_Payload) -> bool {
		return find_enemy(p.game, p.boss.self_enemy_id) != nil
	}

	return managed(weak(scope(
		seq(
			// phase 1 - attack loop,
			race(
				// trigger for phase 2, if boss hp is below 400
				wait_until(proc(p: ^Boss_AI_Payload) -> bool {
					e := find_enemy(p.game, p.boss.self_enemy_id)
					return e != nil && e.health < 400
				}, p),

				// if hp is still above 400 hp, standard movement, and attack loops
				sync(
					// horizontal slide loop
					loop(seq(
						tween(center_x, center_x + 200.0, 3.0, &boss.pos_x, ease_in_out_cubic),
						wait(0.5),
						tween(center_x + 200.0, center_x - 200.0, 6.0, &boss.pos_x, ease_in_out_cubic),
						wait(0.5),
						tween(center_x - 200.0, center_x, 3.0, &boss.pos_x, ease_in_out_cubic),
					)),
					// firing lop
					loop(seq(
						wait(1.5),
						run(proc(p: ^Boss_AI_Payload) -> bool {
							e := find_enemy(p.game, p.boss.self_enemy_id)
							if e == nil do return true

							// spawn spiral pattern bullets
							for i in 0..<8 {
								angle := f32(i) * math.PI / 4.0
								append(&p.game.projectiles, Projectile {
									pos = e.pos,
									dir = {math.cos(angle), math.sin(angle)},
									speed = 200.0,
									damage = 10,
									is_enemy_projectile = true,
								})
							}

							return true
						}, p),
					))
				)
			),
			// phase 2 - transition shield charging in center
			seq(
				// move boss to center
				tween(&boss.pos_x, center_x, 1.0, &boss.pos_x, ease_in_out_cubic),

				scope(seq(
					// activate shield
					run(proc(p: ^Boss_AI_Payload) -> bool {
						p.boss.shield_active = true
						return true
					}, p),
					tween(0.0, 1.0, 0.5, &boss.shield_power),
					// shake screen, charge shield
					sync(
						apply_camera_shake(game, 15.0),
						seq(
							tween(1.0, 1.6, 1.5, &boss.visual_scale, ease_in_out_elastic),
							wait(0.5),
						),
					),
					// trigger super explosion
					run(proc(p: ^Boss_AI_Payload) -> bool {
						e := find_enemy(p.game, p.boss.self_enemy_id)
						if e == nil do return true

						// spawn 32 projectiles in a massive ring
						for i in 0..<24 {
							angle := f32(i) * math.PI / 12.0
							append(&p.game.projectiles, Projectile {
								pos = e.pos,
								dir = {math.cos(angle), math.sin(angle)},
								speed = 250.0,
								damage = 5,
								is_enemy_projectile = true,
							})
						}

						return true
					}, p)),
					// cleanup scope, deactivate shield
					on_exit = proc(b: ^Boss_AI_Payload, status: Status) {
						b.boss.shield_active = false
						b.boss.shield_power = 0.0
					},
					payload = p
				),
			),

			// phase 3 - visually bigger and rapid fire
			seq(
				tween(boss.visual_scale, 1.3, 0.6, &boss.visual_scale, ease_in_out_cubic),
				sync(
					loop(seq( // normal attacks
						wait(0.6), // rapid firing rate
						run(proc(p: ^Boss_AI_Payload) -> bool {
							e := find_enemy(p.game, p.boss.self_enemy_id)
							if e == nil do return true

							// spawn faster projectiles
							dir := linalg.normalize(p.game.player.pos - e.pos)
							append(&p.game.projectiles, Projectile {
								pos = e.pos,
								dir = dir,
								speed = 350.0,
								damage = 3,
								is_enemy_projectile = true,
							})

							return true
						}, p)),
					),
					loop(seq( // sometimes rings
						wait(4),
						run(proc(p: ^Boss_AI_Payload) -> bool {
							e := find_enemy(p.game, p.boss.self_enemy_id)
							if e == nil do return true

							// spawn 32 projectiles in a massive ring
							for i in 0..<16 {
								angle := f32(i) * math.PI / 8.0
								append(&p.game.projectiles, Projectile {
									pos = e.pos,
									dir = {math.cos(angle), math.sin(angle)},
									speed = 100.0,
									damage = 5,
									is_enemy_projectile = true,
								})
							}

							return true
						}, p)),
					)
				)
			),
		),
		// global cleanup scope, reset visual scale, properties for boss state?
		on_exit = proc(b: ^Boss_AI_Payload, status: Status) {
			free(b.boss)
		},
		payload = p,
	), is_alive, p), p)
}

get_status_color :: proc(status: Status) -> k2.Color {
	switch status {
	case .Running:
		return k2.RL_SKYBLUE
	case .Suspended:
		return k2.RL_YELLOW
	case .Completed:
		return k2.RL_GREEN
	case .Failed:
		return k2.RL_RED
	case .Aborted:
		return k2.RL_ORANGE
	case .None:
		return k2.RL_LIGHTGRAY
	}
	return k2.RL_WHITE
}

render_coroutine_debugger :: proc(game: ^Game_World) {
	if !game.diagnostics.enabled do return

	// clear memory
	to_remove := make([dynamic]int, context.temp_allocator)
	for f, i in game.diagnostics.fading_nodes {
		if game.sys_exec.total_time - f.end_time > 0.5 {
			append(&to_remove, i)
		}
	}
	#reverse for idx in to_remove {
		f := game.diagnostics.fading_nodes[idx]
		if len(f.info) > 0 do delete(f.info, game.diagnostics.allocator)
		ordered_remove(&game.diagnostics.fading_nodes, idx)
	}

	if !game.debug_visible do return

	W_W :: 300
	W_X := WW() - W_W

	k2.draw_rect(
		k2.Rect{W_X, 0, f32(W_W), WH()},
		k2.color_alpha(k2.BLACK, 216),
	)
	k2.draw_rect_outline(
		k2.Rect{W_X, 0, f32(W_W), WH()},
		1.0,
		k2.RL_DARKGRAY,
	)

	y: i32 = 45
	k2.draw_text("COROUTINE DEBUGGER", {W_X + 10, 10}, 18, k2.RL_GOLD)
	k2.draw_text(
		game.debug_compact ? "MODE: COMPACT (F2)" : "MODE: FULL (F2)",
		{W_X + 10, 26},
		12,
		k2.RL_GRAY,
	)
	if game.debug_paused {
		k2.draw_text("PAUSED (F3)", {W_X + 120, 26}, 12, k2.RL_MAROON)
	}

	// Scrolling
	wheel := k2.get_mouse_wheel_delta()
	if wheel != 0 {
		game.debug_scroll -= int(wheel * 2)
		game.debug_scroll = max(0, game.debug_scroll)
	}

	// Filter String
	filter_str := string(game.debug_filter[:])
	for i in 0..<len(filter_str) {
		if game.debug_filter[i] == 0 {
			filter_str = filter_str[:i]
			break
		}
	}

	if len(filter_str) > 0 {
		k2.draw_text(
			fmt.tprintf("FILTER: %s", filter_str),
			{W_X + 10, WH() - 20},
			12,
			k2.RL_SKYBLUE,
		)
	}

	line_index := 0

    render_node :: proc(game: ^Game_World, exec: ^Executor, h: Handle, depth: int, y: ^i32, line_index: ^int, filter: string) {
		if h.idx == 0 do return
        node, ok := hm.get(&exec.pool, h)
        if !ok do return

		should_render := true
        // Compact mode: only show leaves or scopes
		if game.debug_compact {
            is_leaf: bool = node.first_child.idx == 0
            is_scope: bool = node.name == "Scope" || node.name == "Managed" || node.name == "Semaphore"
			if !is_leaf && !is_scope {
				should_render = false
			}
		}

		// Substring filter
		if len(filter) > 0 {
			name_lower := strings.to_lower(node.name, context.temp_allocator)
			filter_lower := strings.to_lower(filter, context.temp_allocator)
			if !strings.contains(name_lower, filter_lower) {
				should_render = false
			}
		}

		if should_render {
			if line_index^ >= game.debug_scroll {
				color := get_status_color(node.status)
				indent := depth * 10
				prefix := node.first_child.idx == 0 ? "  " : "v "
				if node.status == Status.Suspended do prefix = "> "

				display_name := node.name
				if len(node.user_name) > 0 {
					display_name = fmt.tprintf("%s (%s)", node.user_name, node.name)
				}

				info_buf: [128]byte
				info_str := node_get_debug_info(exec, h, info_buf[:])

				if node.show_age {
					age := f32(exec.total_time - node.start_time)
					if len(info_str) > 0 {
						display_name = fmt.tprintf("%s [%s] %.1fs", display_name, info_str, age)
					} else {
						display_name = fmt.tprintf("%s %.1fs", display_name, age)
					}
				} else {
					if len(info_str) > 0 {
						display_name = fmt.tprintf("%s [%s]", display_name, info_str)
					}
				}

				text := fmt.tprintf("%s%s", prefix, display_name)

				if y^ < i32(WH() - 30) {
					k2.draw_text(text, {WW() - 300 + 10 + f32(indent), f32(y^)}, 12, color)
					y^ += 12
				}
			}
			line_index^ += 1
		}

		child_depth := should_render ? depth + 1 : depth

		// Recursively render children
        curr := node.first_child
        for curr.idx != 0 {
            c_node, c_ok := hm.get(&exec.pool, curr)
            if !c_ok do break
            render_node(game, exec, curr, child_depth, y, line_index, filter)
            curr = c_node.next_sibling
        }
	}

	// Traversal
    it := hm.iterator_make(&game.exec.pool)
    for node, h in hm.iterate(&it) {
        if node.parent.idx == 0 {
            render_node(game, &game.exec, h, 0, &y, &line_index, filter_str)
        }
    }

    it_sys := hm.iterator_make(&game.sys_exec.pool)
    for node, h in hm.iterate(&it_sys) {
        if node.parent.idx == 0 {
            render_node(game, &game.sys_exec, h, 0, &y, &line_index, filter_str)
        }
    }

	for f in game.diagnostics.fading_nodes {
		if line_index >= game.debug_scroll {
			alpha := 1.0 - f32(game.sys_exec.total_time - f.end_time) / 0.5
			color := k2.color_alpha(get_status_color(f.status), u8(alpha * 255.0))
			indent := f.depth * 10
			display_name := f.name
			if len(f.user_name) > 0 {
				display_name = fmt.tprintf("%s (%s)", f.user_name, f.name)
			}
			text := fmt.tprintf("v %s", display_name)
			if len(f.info) > 0 {
				text = fmt.tprintf("%s : %s", text, f.info)
			}
			if y < i32(WH() - 30) {
				k2.draw_text(text, {WW() - 300 + 10 + f32(indent), f32(y)}, 12, color)
				y += 12
			}
		}
		line_index += 1
	}
}


gw: ^Game_World

init :: proc() {
	// Init karl2d
	k2.init(1024, 768, "Game", {window_mode = .Windowed_Resizable})

	// Init game
	gw = new(Game_World)
	gw.player.pos = {WW() / 2, WH() / 2}
	gw.player.health = 100
	gw.player.max_health = 100
	gw.player.level = 1
	gw.player.xp_needed = 5

	gw.enemies = make([dynamic]Enemy)
	gw.gems = make([dynamic][2]f32)
	gw.projectiles = make([dynamic]Projectile)

	executor_init(&gw.exec)
	executor_init(&gw.sys_exec)
	semaphore_init(&gw.charge_semaphore, 2)
	diagnostics_db_init(&gw.diagnostics)

	gw.exec.debugger = &gw.diagnostics
	gw.sys_exec.debugger = &gw.diagnostics

	// Initial Behaviors
	enqueue_node(&gw.exec, spawner_behavior(gw))

	// Player weapons
	whip := new(Weapon)
	whip.name = "Whip"; whip.damage = 15; whip.cooldown = 1.2
	whip.behavior = whip_behavior(gw, whip)
	append(&gw.player.weapons, whip)
	enqueue_node(&gw.exec, whip.behavior)

	fireball := new(Weapon)
	fireball.name = "Fireball"
	fireball.damage = 15
	fireball.cooldown = 1.8
	fireball.behavior = fireball_behavior(gw, fireball)
	append(&gw.player.weapons, fireball)
	enqueue_node(&gw.exec, fireball.behavior)
}

shutdown :: proc() {
	if gw == nil do return
	for w in gw.player.weapons do free(w)
	delete(gw.player.weapons)
	delete(gw.enemies)
	delete(gw.gems)
	delete(gw.projectiles)
	for p in gw.pop_effects do free(p, gw.sys_exec.allocator)
	delete(gw.pop_effects)
	executor_destroy(&gw.exec)
	executor_destroy(&gw.sys_exec)
	semaphore_destroy(&gw.charge_semaphore)
	diagnostics_db_destroy(&gw.diagnostics)
	free(gw)
	k2.shutdown()
}

step :: proc() -> bool {
	if !k2.update() { return false }
	dt := k2.get_frame_time()

	// Debugger Inputs
	if k2.key_went_down(.F1) {
		gw.debug_visible = !gw.debug_visible
		gw.diagnostics.enabled = gw.debug_visible
		if !gw.diagnostics.enabled {
			// clean memory
			for &f in gw.diagnostics.fading_nodes {
				if len(f.info) > 0 do delete(f.info, gw.diagnostics.allocator)
			}
			delete(gw.diagnostics.fading_nodes)
			gw.diagnostics.fading_nodes = make([dynamic]Fading_Node, 0, 128, gw.diagnostics.allocator)
		}
	}
	if k2.key_went_down(.F2) do gw.debug_compact = !gw.debug_compact
	if k2.key_went_down(.F3) {
		gw.debug_paused = !gw.debug_paused
		gw.is_paused = gw.debug_paused
	}
	if k2.key_went_down(.F4) do mem.set(&gw.debug_filter, 0, len(gw.debug_filter))

	if !gw.is_paused {
		// Player Movement
		p_dir: [2]f32
		if k2.key_is_held(.W) || k2.key_is_held(.Up) do p_dir.y -= 1
		if k2.key_is_held(.S) || k2.key_is_held(.Down) do p_dir.y += 1
		if k2.key_is_held(.A) || k2.key_is_held(.Left) do p_dir.x -= 1
		if k2.key_is_held(.D) || k2.key_is_held(.Right) do p_dir.x += 1

		if linalg.length(p_dir) > 0 {
			gw.player.pos += linalg.normalize(p_dir) * 200.0 * dt
		}
		gw.player.pos.x = math.clamp(gw.player.pos.x, 10, WW() - 10)
		gw.player.pos.y = math.clamp(gw.player.pos.y, 10, WH() - 10)

		if k2.key_went_down(.Space) do enqueue_node(&gw.exec, super_attack_behavior(gw))

		// Timers
		if gw.player.whip_flash_timer > 0.0 do gw.player.whip_flash_timer -= dt
		if gw.player_damage_timer > 0.0 do gw.player_damage_timer -= dt

		// Update Enemies
		for i := len(gw.enemies) - 1; i >= 0; i -= 1 {
			e := &gw.enemies[i]
			dist_vec := gw.player.pos - e.pos
			dist := linalg.length(dist_vec)

			// Move
			if dist > 5.0 {
				e.pos += linalg.normalize(dist_vec) * e.speed * dt
			}

			// AI Ticks (Coroutines will handle specialized logic)
			if e.type == .Wizard && rand.float32() < 0.01 {
				enqueue_node(&gw.exec, wizard_attack_behavior(gw, e.id))
			}
			if e.type == .Elite_Skeleton && !e.is_charging && rand.float32() < 0.006 {
				enqueue_node(&gw.exec, elite_charge_behavior(gw, e.id))
			}

			// Timers
			if e.telegraph_timer > 0.0 do e.telegraph_timer -= dt

			// Collision
			if dist < 15.0 && gw.player_damage_timer <= 0.0 && !gw.player.shield_active {
				gw.player.health -= 10
				gw.player_damage_timer = 0.5
				context.user_ptr = &gw.sys_exec
				enqueue_node(&gw.sys_exec, apply_camera_shake(gw, 6.0))
			}

			// Death
			if e.health <= 0 {
				append(&gw.gems, e.pos)
				context.user_ptr = &gw.sys_exec
				enqueue_node(&gw.sys_exec, death_pop_behavior(gw, e.pos)) // Visual effect on death

				// handle boss death
				if e.type == .Boss {
					gw.boss_fight = false
					context.user_ptr = &gw.sys_exec
					enqueue_node(&gw.sys_exec, apply_camera_shake(gw, 20.0))
				}

				unordered_remove(&gw.enemies, i)
			}
		}

		// Update Projectiles
		for i := len(gw.projectiles) - 1; i >= 0; i -= 1 {
			p := &gw.projectiles[i]
			p.pos += p.dir * p.speed * dt

			hit := false
			if p.is_enemy_projectile {
				if linalg.distance(p.pos, gw.player.pos) < 18.0 && !gw.player.shield_active {
					gw.player.health -= p.damage
					hit = true
				}
			} else {
				for &e in gw.enemies {
					if linalg.distance(p.pos, e.pos) < 20.0 {
						e.health -= p.damage
						hit = true
						break
					}
				}
			}

			if hit ||
			   p.pos.x < -50 ||
			   p.pos.x > WW() + 50 ||
			   p.pos.y < -50 ||
			   p.pos.y > WH() + 50 {
				unordered_remove(&gw.projectiles, i)
			}
		}

		// Update Gems
		for i := len(gw.gems) - 1; i >= 0; i -= 1 {
			gp := gw.gems[i]
			d := linalg.distance(gw.player.pos, gp)
			if d < 80.0 {
				gw.gems[i] += linalg.normalize(gw.player.pos - gp) * 280.0 * dt
				if d < 12.0 {
					gw.player.xp += 1
					unordered_remove(&gw.gems, i)
					if gw.player.xp >= gw.player.xp_needed {
						gw.player.xp -= gw.player.xp_needed
						gw.player.level += 1
						gw.player.xp_needed = int(f32(gw.player.xp_needed) * 1.5)
						enqueue_node(&gw.sys_exec, level_up_sequence(gw))
					}
				}
			}
		}

		// Update Pop Effects
		for i := len(gw.pop_effects) - 1; i >= 0; i -= 1 {
			eff := gw.pop_effects[i]
			if eff.ended {
				// clean pop effect here, instead of coroutine... safely
				free(eff, gw.sys_exec.allocator)
				unordered_remove(&gw.pop_effects, i)
			}
		}
	}

	// Update Executors
	executor_step(&gw.exec, gw.is_paused ? 0.0 : dt)
	executor_step(&gw.sys_exec, dt)

	// Rendering
	k2.clear(k2.Color{24, 28, 36, 255})

	shake := [2]f32 {
		rand.float32_range(-gw.camera_shake, gw.camera_shake),
		rand.float32_range(-gw.camera_shake, gw.camera_shake),
	}

	for g in gw.gems {
		k2.draw_rect_vec(
			g + shake,
			{8, 8},
			k2.RL_SKYBLUE,
			{4, 4},
			45.0 * (math.PI / 180.0),
		)
	}

	for &e in gw.enemies {
		col := k2.RL_GRAY
		sz := f32(10.0)
		switch e.type {
		case .Skeleton:
			col = k2.RL_GRAY; sz = 10
		case .Elite_Skeleton:
			col = k2.RL_ORANGE; sz = 16
		case .Wizard:
			col = k2.RL_PURPLE; sz = 12
		case .Boss:
			col = k2.RL_MAROON; sz = 24
			if e.boss_state != nil {
				sz *= e.boss_state.visual_scale
			}
		}
		if e.is_charging do col = k2.RL_YELLOW

		if e.type == .Boss && e.boss_state != nil {
			// sync boss_state pos
			e.pos.x = e.boss_state.pos_x
		}

		if e.type == .Boss && e.boss_state != nil && e.boss_state.shield_active {
			clamped_alpha := math.clamp(e.boss_state.shield_power * 0.6 * 255.0, 0, 255)
			shield_color := k2.color_alpha(k2.RL_SKYBLUE, u8(clamped_alpha))
			k2.draw_circle_outline(e.pos + shake, sz + 12.0, 1.0, shield_color)
		}

		k2.draw_circle(e.pos + shake, sz, col)
		if e.telegraph_timer > 0.0 {
			k2.draw_circle_outline(
				e.pos + shake,
				45.0 * (e.telegraph_timer / 0.8),
				1.0,
				k2.RL_RED,
			)
		}
	}

	for p in gw.projectiles {
		k2.draw_circle(
			p.pos + shake,
			5.0,
			p.is_enemy_projectile ? k2.RL_VIOLET : k2.RL_GOLD,
		)
	}

	for eff in gw.pop_effects {
		k2.draw_circle_outline(eff.pos + shake, eff.radius, 1.0, k2.RL_WHITE)
	}

	p_col := gw.player_damage_timer > 0.0 ? k2.RL_ORANGE : k2.RL_GREEN
	k2.draw_circle(gw.player.pos + shake, 13.0, p_col)
	if gw.player.shield_active {
		k2.draw_circle_outline(gw.player.pos + shake, 24.0, 1.0, k2.RL_SKYBLUE)
	}
	if gw.player.whip_flash_timer > 0.0 {
		k2.draw_circle_outline(
			gw.player.pos + shake,
			110.0,
			1.0,
			k2.color_alpha(k2.RL_WHITE, 128),
		)
	}

	// HUD
	hud_str := fmt.tprintf(
		"HP: %d/%d | LVL: %d | XP: %d/%d",
		gw.player.health,
		gw.player.max_health,
		gw.player.level,
		gw.player.xp,
		gw.player.xp_needed,
	)
	k2.draw_text(hud_str, {10, 10}, 20, k2.RL_WHITE)

	enemies_str := fmt.tprintf("Active Enemies: %d", len(gw.enemies))
	k2.draw_text(enemies_str, {WW() - 200, 10}, 20, k2.RL_LIGHTGRAY)
	k2.draw_text("SPACE: Super Attack", {10, WH() - 30}, 20, k2.RL_DARKGRAY)

	// Level Up Screen
	if gw.is_paused {
		k2.draw_rect(
			k2.Rect{0, 0, WW(), WH()},
			k2.color_alpha(k2.BLACK, u8(0.8 * gw.level_up_scale * 255.0)),
		)
		y := (WH() / 2 - 40) * gw.level_up_scale
		k2.draw_text("LEVEL UP!", {WW() / 2 - 80, y - 100}, 32, k2.RL_GOLD)

		opts := [3]string{"[1] SPEED", "[2] POWER", "[3] SHIELD"}
		for s, i in opts {
			rx := WW() / 2 - 300 + f32(i) * 210
			k2.draw_rect(k2.Rect{rx, y, 180, 80}, k2.RL_DARKGRAY)
			k2.draw_rect_outline(k2.Rect{rx, y, 180, 80}, 1.0, k2.RL_GOLD)
			k2.draw_text(s, {rx + 30, y + 32}, 16, k2.RL_WHITE)
		}
	}

	if gw.player.health <= 0 {
		k2.draw_rect(
			k2.Rect{0, 0, WW(), WH()},
			k2.color_alpha(k2.RL_MAROON, 178),
		)
		k2.draw_text(
			"GAME OVER",
			{WW() / 2 - 100, WH() / 2 - 20},
			40,
			k2.RL_WHITE,
		)
	}

	render_coroutine_debugger(gw)

	k2.present()

	free_all(context.temp_allocator)

	return true
}

main :: proc() {
	context.logger = log.create_console_logger()

	// Tracking memory
	track: mem.Tracking_Allocator
	when ODIN_DEBUG {
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)
	}

	reset_tracking_allocator :: proc(track: ^mem.Tracking_Allocator) -> (leaks: bool) {
		for _, leak in track.allocation_map {
			fmt.printf("%v leaked %v bytes\n", leak.location, leak.size)
			leaks = true
		}
		for bad_free in track.bad_free_array {
			fmt.printf("%v allocation %p was freed badly\n", bad_free.location, bad_free.memory)
		}
		mem.tracking_allocator_clear(track)
		return
	}
	defer reset_tracking_allocator(&track)

	init()
	defer shutdown()
	for step() {}
}
