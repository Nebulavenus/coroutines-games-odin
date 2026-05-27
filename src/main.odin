package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:mem"
import "core:strings"
import rl "vendor:raylib"

// --- Windows High Performance GPU Hint ---
@(export, link_name = "NvOptimusEnablement")
NvOptimusEnablement: c.ulong = 1
@(export, link_name = "AmdPowerXpressRequestingHighPerformance")
AmdPowerXpressRequestingHighPerformance: i32 = 1

W_WIDTH, W_HEIGHT :: 640, 480

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
	pending_level_ups: int,
}

Enemy :: struct {
	pos:             [2]f32,
	health:          int,
	speed:           f32,
	type:            Enemy_Type,
	is_charging:     bool,
	telegraph_timer: f32,
	id:              int, // Unique ID to track across frames safely
}

Weapon :: struct {
	name:     string,
	damage:   int,
	cooldown: f32,
	behavior: ^Node,
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
wizard_attack_behavior :: proc(game: ^Game_World, enemy_id: int) -> ^Node {
	// Local coro state
	Payload :: struct {
		game: ^Game_World,
		id:   int,
	}
	p := new(Payload)
	p.game = game
	p.id = enemy_id

	is_alive :: proc(d: rawptr) -> bool {
		p := (^Payload)(d); return find_enemy(p.game, p.id) != nil
	}

	return managed(weak(
		named(seq(
			named(sync(
				run(proc(d: rawptr) -> bool {
					p := (^Payload)(d)
					find_enemy(p.game, p.id).telegraph_timer = 0.8
					return true
				}, p),
				named(wait(0.8), "Telegraph Timer")
			), "Telegraph Phase"),
			named(run(proc(d: rawptr) -> bool {
				p := (^Payload)(d)
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
		}, p), "Shoot Fireball")), "Wizard Attack"), is_alive, p), p)
}

// Dash attack for Elites (Protected by Weak + Semaphore)
elite_charge_behavior :: proc(game: ^Game_World, enemy_id: int) -> ^Node {
	Payload :: struct {
		game: ^Game_World,
		id:   int,
	}
	p := new(Payload)
	p.game = game
	p.id = enemy_id

	is_alive :: proc(d: rawptr) -> bool {
		p := (^Payload)(d)
		return find_enemy(p.game, p.id) != nil
	}

	return managed(weak(
		semaphore_scope(&game.charge_semaphore, // only allows two elites to run this dash
			named(seq(
				named(run(proc(d: rawptr) -> bool { // start charge
					p := (^Payload)(d)
					e := find_enemy(p.game, p.id)
					if e == nil do return true
					e.speed *= 3.5
					e.is_charging = true
					return true
				}, p), "Start Dash"),
				named(wait(1.0), "Dash Duration"),
				named(run(proc(d: rawptr) -> bool { // stop it
					p := (^Payload)(d)
					e := find_enemy(p.game, p.id)
					if e == nil do return true
					e.speed /= 3.5
					e.is_charging = false
					return true
			}, p), "End Dash")), "Elite Dash Sequence")
		), is_alive, p), p)
}

// Visual "Pop" effect (Spawned via Fork)
death_pop_behavior :: proc(game: ^Game_World, pos: [2]f32) -> ^Node {
	p := new(Pop_Effect, game.sys_exec.allocator)
	p.pos = pos
	p.ended = false
	p.radius = 0.0

	append(&game.pop_effects, p)

	// don't delete payload here with managed, executor can delete pop_effect quicker
	// than animation happens in main loop causing dangling pointer
	return fork(
			named(seq(
				named(tween(0.0, 30.0, 0.8, &p.radius, ease_in_out_elastic), "Expand"),
				named(tween(30.0, 0.0, 0.4, &p.radius, ease_in_out_cubic), "Contract"),
				run(proc(data: rawptr) -> bool {
					p := (^Pop_Effect)(data)
					p.ended = true
					return true
				}, p)
			), "Pop Animation"))
}

whip_behavior :: proc(game: ^Game_World, weapon: ^Weapon) -> ^Node {

	Weapon_Payload :: struct {
		game:   ^Game_World,
		weapon: ^Weapon,
	}

	p := new(Weapon_Payload); p.game = game; p.weapon = weapon
	return managed(named(loop(
		named(seq(
			named(wait_ptr(&weapon.cooldown), "Whip Cooldown"),
			named(run(proc(d: rawptr) -> bool {
				p := (^Weapon_Payload)(d)
				for &e in p.game.enemies {
					if linalg.distance(e.pos, p.game.player.pos) < 110.0 do e.health -= p.weapon.damage
				}
				p.game.player.whip_flash_timer = 0.15
				return true
			}, p), "Whip Slash")
		), "Whip Sequence")), "Whip Behavior"), p)
}

fireball_behavior :: proc(game: ^Game_World, weapon: ^Weapon) -> ^Node {

	Weapon_Payload :: struct {
		game:   ^Game_World,
		weapon: ^Weapon,
	}

	p := new(Weapon_Payload)
	p.game = game
	p.weapon = weapon
	return managed(named(loop(
		named(seq(
			named(wait_ptr(&weapon.cooldown), "Fireball Cooldown"),
			named(run(proc(d: rawptr) -> bool {
				p := (^Weapon_Payload)(d)
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
		), "Fireball Sequence")), "Fireball Behavior"), p)
}

level_up_sequence :: proc(game: ^Game_World) -> ^Node {
	return named(seq(
		named(run(proc(d: rawptr) -> bool { // pause game
			g := (^Game_World)(d)
			g.is_paused = true
			g.level_up_scale = 0
			return true
		}, game), "Pause Game"),
		named(tween(0.0, 1.0, 0.4, &game.level_up_scale, ease_in_out_cubic), "Show Shop UI"),
		named(wait_until(proc(d: rawptr) -> bool { // until upgrade is not selected, waits here
			g := (^Game_World)(d)
			if rl.IsKeyPressed(.ONE) {
				for &w in g.player.weapons do w.cooldown *= 0.8
				return true
			}
			if rl.IsKeyPressed(.TWO) {
				for &w in g.player.weapons do w.damage += 15
				g.player.max_health += 25
				g.player.health = g.player.max_health
				return true
			}
			if rl.IsKeyPressed(.THREE) {
				enqueue_node(&g.exec, shield_behavior(g, 5.0))
				return true
			}
			return false
		}, game), "Wait for Player Choice"),
		named(tween(1.0, 0.0, 0.2, &game.level_up_scale, ease_in_out_cubic), "Hide Shop UI"),
		named(run(proc(d: rawptr) -> bool {
			(^Game_World)(d).is_paused = false
			return true
		}, game), "Unpause Game")), "Level Up Sequence")
}

shield_behavior :: proc(game: ^Game_World, duration: f32) -> ^Node {
	return named(seq(
		named(run(
			proc(d: rawptr) -> bool {(^Game_World)(d).player.shield_active = true; return true},
			game,
		), "Activate Shield"),
		// Race against timer: Stay active until timer wins
		named(race(named(wait(duration), "Shield Timer"), named(wait_forever(), "Constant Shield")), "Shield Active State"),
		named(run(
			proc(d: rawptr) -> bool {(^Game_World)(d).player.shield_active = false; return true},
			game,
		), "Deactivate Shield"),
	), "Shield Behavior")
}

super_attack_behavior :: proc(game: ^Game_World) -> ^Node {
	return named(seq(
		named(sync(named(apply_camera_shake(game, 15.0), "Shake Camera"), named(wait(0.5), "Charge Delay")), "Charge Phase"),
		named(run(proc(d: rawptr) -> bool {
			g := (^Game_World)(d)
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
}

apply_camera_shake :: proc(game: ^Game_World, amount: f32) -> ^Node {
	return named(tween(amount, 0.0, 0.4, &game.camera_shake), "Camera Shake")
}

spawner_behavior :: proc(game: ^Game_World) -> ^Node {
	spawn :: proc(game: ^Game_World, type: Enemy_Type) {
		game.enemy_id_counter += 1
		angle := rand.float32_range(0, 2 * math.PI)
		dist := f32(260.0)
		if type == .Wizard do dist = 300.0

		hp := 25
		spd := f32(80.0)
		switch type {
		case .Elite_Skeleton:
			hp = 100; spd = 65.0
		case .Wizard:
			hp = 40; spd = 45.0; dist = 300.0
		case .Boss:
			hp = 600; spd = 50.0; dist = 220.0
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
			},
		)
	}
	return named(loop(named(seq(
			named(select(
				named(seq(named(check(proc(d: rawptr) -> bool {
							g := (^Game_World)(d)
							return g.player.level > 0 && g.player.level % 5 == 0 && g.boss_spawned_at != g.player.level
						}, game), "Check Boss Conditions"),
					named(run(proc(d: rawptr) -> bool {
							g := (^Game_World)(d)
							g.boss_spawned_at = g.player.level
							spawn(g, .Boss)
							enqueue_node(&g.sys_exec, apply_camera_shake(g, 10.0))
							return true
						}, game), "Spawn Boss"),
					named(wait(20.0), "Boss Cooldown")
				), "Boss Spawn Branch"),
				named(seq(named(race(named(wait(3.0), "Spawn Interval"), named(wait_until(proc(d: rawptr) -> bool {
							return (^Game_World)(d).player.health < 30
						}, game), "Urgent Spawn Trigger")), "Normal Wait"),
					named(run(proc(d: rawptr) -> bool {
						g := (^Game_World)(d)
						spawn(g, .Skeleton)
						if rand.float32() < 0.4 do spawn(g, .Wizard)
						if rand.float32() < 0.2 do spawn(g, .Elite_Skeleton)
						return true
					}, game), "Spawn Mob")
				), "Normal Spawn Branch")
			), "Spawn Logic")
		), "Spawner Main Loop")), "Enemy Spawner Behavior")
}

diagnostics_db_prune :: proc(db: ^Diagnostics_DB, current_time: f64, fade_duration: f64) {
	if db == nil do return
	to_remove := make([dynamic]rawptr, context.temp_allocator)
	for id, &entry in db.entries {
		if entry.end_time > 0 && current_time - entry.end_time > fade_duration {
			append(&to_remove, id)
		}
	}
	for id in to_remove {
		if entry, found := db.entries[id]; found {
			if len(entry.info) > 0 do delete(entry.info, db.allocator)
			delete_key(&db.entries, id)
		}
	}
}

get_status_color :: proc(status: Status) -> rl.Color {
	switch status {
	case .Running:
		return rl.SKYBLUE
	case .Suspended:
		return rl.YELLOW
	case .Completed:
		return rl.GREEN
	case .Failed:
		return rl.RED
	case .Aborted:
		return rl.ORANGE
	case .None:
		return rl.LIGHTGRAY
	}
	return rl.WHITE
}

render_coroutine_debugger :: proc(game: ^Game_World) {
	if !game.diagnostics.enabled do return

	// Continuous memory maintenance: prune finished nodes even if UI is hidden
	if !game.debug_paused {
		diagnostics_db_prune(&game.diagnostics, game.sys_exec.total_time, 0.5)
	}

	if !game.debug_visible do return

	W_X :: 400
	W_W :: 240

	rl.DrawRectangle(W_X, 0, W_W, W_HEIGHT, rl.Fade(rl.BLACK, 0.85))
	rl.DrawRectangleLines(W_X, 0, W_W, W_HEIGHT, rl.DARKGRAY)

	y: i32 = 45
	rl.DrawText("COROUTINE DEBUGGER", W_X + 10, 10, 16, rl.GOLD)
	rl.DrawText(game.debug_compact ? "MODE: COMPACT (F2)" : "MODE: FULL (F2)", W_X + 10, 26, 10, rl.GRAY)
	if game.debug_paused do rl.DrawText("PAUSED (F3)", W_X + 120, 26, 10, rl.MAROON)

	// Scrolling
	wheel := rl.GetMouseWheelMove()
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
		rl.DrawText(rl.TextFormat("FILTER: %s", filter_str), W_X + 10, W_HEIGHT - 20, 10, rl.SKYBLUE)
	}

	// Simple key-based filtering
	// TODO: text input field

	// Build adjacency list
	Children_Map :: map[rawptr][dynamic]rawptr
	children := make(Children_Map, context.temp_allocator)
	roots := make([dynamic]rawptr, context.temp_allocator)

	for id, entry in game.diagnostics.entries {
		if entry.parent_id == nil {
			append(&roots, id)
		} else {
			if entry.parent_id not_in children {
				children[entry.parent_id] = make([dynamic]rawptr, context.temp_allocator)
			}
			append(&children[entry.parent_id], id)
		}
	}

	line_index := 0
	render_entry :: proc(game: ^Game_World, id: rawptr, children: ^Children_Map, depth: int, y: ^i32, line_index: ^int, filter: string) {
		entry := game.diagnostics.entries[id]

		should_render := true
		if game.debug_compact {
			if !entry.is_leaf && !entry.is_scope {
				should_render = false
			}
		}

		// Substring filter
		if len(filter) > 0 {
			name_lower := strings.to_lower(entry.name, context.temp_allocator)
			filter_lower := strings.to_lower(filter, context.temp_allocator)
			if !strings.contains(name_lower, filter_lower) {
				should_render = false
			}
		}

		if should_render {
			if line_index^ >= game.debug_scroll {
				color := get_status_color(entry.status)
				if entry.end_time > 0 {
					alpha := 1.0 - f32(game.sys_exec.total_time - entry.end_time) / 0.5
					color = rl.Fade(color, alpha)
				}

				indent := i32(depth * 10)
				prefix := entry.is_leaf ? "  " : "v "
				if entry.status == .Suspended do prefix = "> "

				display_name := entry.name
				if len(entry.user_name) > 0 {
					display_name = string(rl.TextFormat("%s (%s)", entry.user_name, entry.name))
				}

				text := rl.TextFormat("%s%s", prefix, display_name)
				if len(entry.info) > 0 {
					text = rl.TextFormat("%s : %s", text, entry.info)
				}

				if y^ < W_HEIGHT - 30 {
					rl.DrawText(text, 410 + indent, y^, 10, color)
					y^ += 12
				}
			}
			line_index^ += 1
		}

		if id in children {
			for cid in children[id] {
				render_entry(game, cid, children, should_render ? depth + 1 : depth, y, line_index, filter)
			}
		}
	}

	for root in roots {
		render_entry(game, root, &children, 0, &y, &line_index, filter_str)
	}
}

main :: proc() {
	// Tracking memory
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)
	defer {
		for _, leak in track.allocation_map {
			fmt.printf("%v leaked %v bytes\n", leak.location, leak.size)
		}
		mem.tracking_allocator_clear(&track)
	}

	// Init raylib
	rl.InitWindow(W_WIDTH, W_HEIGHT, "Game")
	rl.SetTargetFPS(60)
	defer rl.CloseWindow()

	// Init game
	gw: Game_World
	gw.player.pos = {f32(W_WIDTH / 2), f32(W_HEIGHT / 2)}
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

	defer {
		for w in gw.player.weapons do free(w)
		delete(gw.player.weapons)
		delete(gw.enemies)
		delete(gw.gems)
		delete(gw.projectiles)
		delete(gw.pop_effects)
		executor_destroy(&gw.exec)
		executor_destroy(&gw.sys_exec)
		semaphore_destroy(&gw.charge_semaphore)
		diagnostics_db_destroy(&gw.diagnostics)
	}

	// Initial Behaviors
	enqueue_node(&gw.exec, spawner_behavior(&gw))

	// Player weapons
	whip := new(Weapon)
	whip.name = "Whip"; whip.damage = 15; whip.cooldown = 1.2
	whip.behavior = whip_behavior(&gw, whip)
	append(&gw.player.weapons, whip)
	enqueue_node(&gw.exec, whip.behavior)

	fireball := new(Weapon)
	fireball.name = "Fireball"
	fireball.damage = 15
	fireball.cooldown = 1.8
	fireball.behavior = fireball_behavior(&gw, fireball)
	append(&gw.player.weapons, fireball)
	enqueue_node(&gw.exec, fireball.behavior)

	// Game loop
	for !rl.WindowShouldClose() {
		dt := rl.GetFrameTime()

		// Debugger Inputs
		if rl.IsKeyPressed(.F1) {
			gw.debug_visible = !gw.debug_visible
			gw.diagnostics.enabled = gw.debug_visible
			if !gw.diagnostics.enabled {
				// clean memory
				for id, &entry in gw.diagnostics.entries {
					if len(entry.info) > 0 do delete(entry.info, gw.diagnostics.allocator)
				}
				delete(gw.diagnostics.entries)
				gw.diagnostics.entries = make(map[rawptr]Debug_Node, 16, gw.diagnostics.allocator)
				executor_shrink(&gw.exec)
				executor_shrink(&gw.sys_exec)
			}
		}
		if rl.IsKeyPressed(.F2) do gw.debug_compact = !gw.debug_compact
		if rl.IsKeyPressed(.F3) {
			gw.debug_paused = !gw.debug_paused
			gw.is_paused = gw.debug_paused
		}
		if rl.IsKeyPressed(.F4) do mem.set(&gw.debug_filter, 0, len(gw.debug_filter))

		// Sample filter for testing
		if rl.IsKeyPressed(.F12) {
			copy(gw.debug_filter[:], "wait")
		}

		if !gw.is_paused {
			// Player Movement
			p_dir: [2]f32
			if rl.IsKeyDown(.W) || rl.IsKeyDown(.UP) do p_dir.y -= 1
			if rl.IsKeyDown(.S) || rl.IsKeyDown(.DOWN) do p_dir.y += 1
			if rl.IsKeyDown(.A) || rl.IsKeyDown(.LEFT) do p_dir.x -= 1
			if rl.IsKeyDown(.D) || rl.IsKeyDown(.RIGHT) do p_dir.x += 1

			if linalg.length(p_dir) > 0 {
				gw.player.pos += linalg.normalize(p_dir) * 200.0 * dt
			}
			gw.player.pos.x = math.clamp(gw.player.pos.x, 10, W_WIDTH - 10)
			gw.player.pos.y = math.clamp(gw.player.pos.y, 10, W_HEIGHT - 10)

			if rl.IsKeyPressed(.SPACE) do enqueue_node(&gw.exec, super_attack_behavior(&gw))

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
					enqueue_node(&gw.exec, wizard_attack_behavior(&gw, e.id))
				}
				if e.type == .Elite_Skeleton && !e.is_charging && rand.float32() < 0.006 {
					enqueue_node(&gw.exec, elite_charge_behavior(&gw, e.id))
				}

				// Timers
				if e.telegraph_timer > 0.0 do e.telegraph_timer -= dt

				// Collision
				if dist < 15.0 && gw.player_damage_timer <= 0.0 && !gw.player.shield_active {
					gw.player.health -= 10
					gw.player_damage_timer = 0.5
					enqueue_node(&gw.sys_exec, apply_camera_shake(&gw, 6.0))
				}

				// Death
				if e.health <= 0 {
					append(&gw.gems, e.pos)
					enqueue_node(&gw.sys_exec, death_pop_behavior(&gw, e.pos)) // Visual effect on death
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
				   p.pos.x > W_WIDTH + 50 ||
				   p.pos.y < -50 ||
				   p.pos.y > W_HEIGHT + 50 {
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
							enqueue_node(&gw.sys_exec, level_up_sequence(&gw))
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
		rl.BeginDrawing()
		rl.ClearBackground(rl.Color{24, 28, 36, 255})

		shake := [2]f32 {
			rand.float32_range(-gw.camera_shake, gw.camera_shake),
			rand.float32_range(-gw.camera_shake, gw.camera_shake),
		}

		for g in gw.gems {
			rl.DrawRectanglePro(
				rl.Rectangle{g.x + shake.x, g.y + shake.y, 8, 8},
				{4, 4},
				45.0,
				rl.SKYBLUE,
			)
		}

		for e in gw.enemies {
			col := rl.GRAY
			sz := f32(10.0)
			switch e.type {
			case .Skeleton:
				col = rl.GRAY; sz = 10
			case .Elite_Skeleton:
				col = rl.ORANGE; sz = 16
			case .Wizard:
				col = rl.PURPLE; sz = 12
			case .Boss:
				col = rl.MAROON; sz = 24
			}
			if e.is_charging do col = rl.YELLOW

			rl.DrawCircleV(cast(rl.Vector2)(e.pos + shake), sz, col)
			if e.telegraph_timer > 0.0 {
				rl.DrawCircleLinesV(
					cast(rl.Vector2)(e.pos + shake),
					45.0 * (e.telegraph_timer / 0.8),
					rl.RED,
				)
			}
		}

		for p in gw.projectiles {
			rl.DrawCircleV(
				cast(rl.Vector2)(p.pos + shake),
				5.0,
				p.is_enemy_projectile ? rl.VIOLET : rl.GOLD,
			)
		}

		for eff in gw.pop_effects {
			rl.DrawCircleLinesV(cast(rl.Vector2)(eff.pos + shake), eff.radius, rl.WHITE)
		}

		p_col := gw.player_damage_timer > 0.0 ? rl.ORANGE : rl.GREEN
		rl.DrawCircleV(cast(rl.Vector2)(gw.player.pos + shake), 13.0, p_col)
		if gw.player.shield_active do rl.DrawCircleLinesV(cast(rl.Vector2)(gw.player.pos + shake), 24.0, rl.SKYBLUE)
		if gw.player.whip_flash_timer > 0.0 do rl.DrawCircleLinesV(cast(rl.Vector2)(gw.player.pos + shake), 110.0, rl.Fade(rl.WHITE, 0.5))

		// HUD
		rl.DrawText(
			rl.TextFormat(
				"HP: %d/%d | LVL: %d | XP: %d/%d",
				gw.player.health,
				gw.player.max_health,
				gw.player.level,
				gw.player.xp,
				gw.player.xp_needed,
			),
			10,
			10,
			18,
			rl.WHITE,
		)

		rl.DrawText(
			rl.TextFormat("Active Enemies: %d", len(gw.enemies)),
			440,
			10,
			16,
			rl.LIGHTGRAY,
		)
		rl.DrawText("SPACE: Super Attack", 10, W_HEIGHT - 30, 16, rl.DARKGRAY)

		// Level Up Screen
		if gw.is_paused {
			rl.DrawRectangle(0, 0, W_WIDTH, W_HEIGHT, rl.Fade(rl.BLACK, 0.8 * gw.level_up_scale))
			y := f32(W_HEIGHT / 2 - 40) * gw.level_up_scale
			rl.DrawText("LEVEL UP!", W_WIDTH / 2 - 80, i32(y - 100), 32, rl.GOLD)

			opts := [3]string{"[1] SPEED", "[2] POWER", "[3] SHIELD"}
			for s, i in opts {
				rl.DrawRectangle(i32(40 + i * 195), i32(y), 170, 80, rl.DARKGRAY)
				rl.DrawRectangleLines(i32(40 + i * 195), i32(y), 170, 80, rl.GOLD)
				rl.DrawText(rl.TextFormat("%s", s), i32(70 + i * 195), i32(y + 32), 16, rl.WHITE)
			}
		}

		if gw.player.health <= 0 {
			rl.DrawRectangle(0, 0, W_WIDTH, W_HEIGHT, rl.Fade(rl.MAROON, 0.7))
			rl.DrawText("GAME OVER", W_WIDTH / 2 - 100, W_HEIGHT / 2 - 20, 40, rl.WHITE)
		}

		render_coroutine_debugger(&gw)

		rl.EndDrawing()
	}
}
