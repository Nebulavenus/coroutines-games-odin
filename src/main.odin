package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:mem"
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

Game_World :: struct {
	player:              Player,
	enemies:             [dynamic]Enemy,
	gems:                [dynamic][2]f32,
	projectiles:         [dynamic]Projectile,
	exec:                Executor, // Pauses with game
	sys_exec:            Executor, // Runs in real-time
	charge_semaphore:    Semaphore,
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

// Ranged attack for Wizard
wizard_attack_behavior :: proc(game: ^Game_World, enemy_id: int) -> ^Node {
	// Local coro state
	Payload :: struct {
		game: ^Game_World,
		id:   int,
	}
	p := new(Payload)
	p.game = game
	p.id = enemy_id

	// Wrap in managed so that payload p is freed automatically
	return managed(
		seq(
			sync(
				run(
					proc(data: rawptr) -> bool { 	// Telegraph phase
						p := (^Payload)(data)
						if e := find_enemy(p.game, p.id); e != nil {
							e.telegraph_timer = 0.8
							return true
						}
						return false
					},
					p,
				),
				wait(0.8),
			),
			// Shoot phase
			run(proc(data: rawptr) -> bool {
					p := (^Payload)(data)
					if e := find_enemy(p.game, p.id); e != nil {
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
					}
					return false
				}, p),
		),
		p,
	)
}

// Dash attack for Elites
elite_charge_behavior :: proc(game: ^Game_World, enemy_id: int) -> ^Node {
	Payload :: struct {
		game: ^Game_World,
		id:   int,
	}
	p := new(Payload)
	p.game = game
	p.id = enemy_id

	return managed(
		semaphore_scope(
			&game.charge_semaphore,
			seq(
				run(
					proc(data: rawptr) -> bool { 	// Start Charge
						p := (^Payload)(data)
						if e := find_enemy(p.game, p.id); e != nil {
							e.speed *= 3.5
							e.is_charging = true
							return true
						}
						return false
					},
					p,
				),
				wait(1.0),
				// Stop Charge
				run(proc(data: rawptr) -> bool {
						p := (^Payload)(data)
						if e := find_enemy(p.game, p.id); e != nil {
							e.speed /= 3.5
							e.is_charging = false
							return true
						}
						return false
					}, p),
			),
		),
		p,
	)
}

whip_behavior :: proc(game: ^Game_World, weapon: ^Weapon) -> ^Node {

	Weapon_Payload :: struct {
		game:   ^Game_World,
		weapon: ^Weapon,
	}

	payload := new(Weapon_Payload)
	payload.game = game
	payload.weapon = weapon

	// managed() wraps the whole loop. When weapon is removed, this entire node is aborted
	// and its payload is automatically freed.
	return managed(loop(seq(wait_ptr(&weapon.cooldown), run(proc(data: rawptr) -> bool {
						p := (^Weapon_Payload)(data)
						for &e in p.game.enemies {
							if linalg.distance(e.pos, p.game.player.pos) < 110.0 {
								e.health -= p.weapon.damage
							}
						}
						p.game.player.whip_flash_timer = 0.15
						return true
					}, payload))), payload)
}

fireball_behavior :: proc(game: ^Game_World, weapon: ^Weapon) -> ^Node {

	Weapon_Payload :: struct {
		game:   ^Game_World,
		weapon: ^Weapon,
	}

	payload := new(Weapon_Payload)
	payload.game = game
	payload.weapon = weapon

	return managed(loop(seq(wait_ptr(&weapon.cooldown), run(proc(data: rawptr) -> bool {
						p := (^Weapon_Payload)(data)
						if len(p.game.enemies) == 0 do return true

						nearest := 0
						min_dist := f32(99999.0)
						for e, i in p.game.enemies {
							d := linalg.distance(e.pos, p.game.player.pos)
							if d < min_dist {
								min_dist = d
								nearest = i
							}
						}

						dir := linalg.normalize(p.game.enemies[nearest].pos - p.game.player.pos)
						append(&p.game.projectiles, Projectile{pos = p.game.player.pos, dir = dir, speed = 320.0, damage = p.weapon.damage})
						return true
					}, payload))), payload)
}

level_up_juice :: proc(game: ^Game_World) -> ^Node {
	return optional_seq(
		run(
			proc(d: rawptr) -> bool {(^Game_World)(d).player.whip_flash_timer = 0.2; return true},
			game,
		),
		wait_frames(8),
		run(
			proc(d: rawptr) -> bool {(^Game_World)(d).player.whip_flash_timer = 0.2; return true},
			game,
		),
		wait_frames(8),
		run(
			proc(d: rawptr) -> bool {(^Game_World)(d).player.whip_flash_timer = 0.2; return true},
			game,
		),
	)
}

level_up_sequence :: proc(game: ^Game_World) -> ^Node {
	return seq(
		run(
			proc(d: rawptr) -> bool { 	// Pause and Show UI
				gw := (^Game_World)(d)
				gw.is_paused = true
				gw.level_up_scale = 0
				return true
			},
			game,
		),
		tween(0.0, 1.0, 0.8, &game.level_up_scale, ease_in_out_cubic),
		// Wait for Input
		wait_until(proc(d: rawptr) -> bool {
				gw := (^Game_World)(d)
				if rl.IsKeyPressed(.ONE) {
					for &w in gw.player.weapons do w.cooldown *= 0.8
					return true
				}
				if rl.IsKeyPressed(.TWO) {
					for &w in gw.player.weapons do w.damage += 15
					gw.player.max_health += 25
					gw.player.health = gw.player.max_health
					return true
				}
				if rl.IsKeyPressed(.THREE) {
					enqueue_node(&gw.exec, shield_behavior(gw, 5.0))
					return true
				}
				return false
			}, game),
		// Feedback and Close
		level_up_juice(game),
		tween(1.0, 0.0, 0.4, &game.level_up_scale, ease_in_out_cubic),
		run(proc(d: rawptr) -> bool {
				(^Game_World)(d).is_paused = false
				return true
			}, game),
	)
}

shield_behavior :: proc(game: ^Game_World, duration: f32) -> ^Node {
	return seq(
		run(
			proc(d: rawptr) -> bool {(^Game_World)(d).player.shield_active = true; return true},
			game,
		),
		scope(
			wait(duration),
			proc(d: rawptr, s: Status) {(^Game_World)(d).player.shield_active = false},
			game,
		),
	)
}

super_attack_behavior :: proc(game: ^Game_World) -> ^Node {
	return seq(sync(apply_camera_shake(game, 15.0), wait(0.5)), run(proc(d: rawptr) -> bool {
				gw := (^Game_World)(d)
				for i in 0 ..< 12 {
					angle := f32(i) * math.PI / 6.0
					dir := [2]f32{math.cos(angle), math.sin(angle)}
					append(
						&gw.projectiles,
						Projectile{pos = gw.player.pos, dir = dir, speed = 450.0, damage = 100},
					)
				}
				return true
			}, game))
}

apply_camera_shake :: proc(game: ^Game_World, amount: f32) -> ^Node {
	return tween(amount, 0.0, 0.4, &game.camera_shake)
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
			hp = 40; spd = 45.0
		case .Boss:
			hp = 500; spd = 50.0; dist = 220.0
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

	return loop(
		seq(
			select(
				seq(
					check(
						proc(d: rawptr) -> bool { 	// Try Boss Spawn
							g := (^Game_World)(d)
							return(
								g.player.level > 0 &&
								g.player.level % 5 == 0 &&
								g.boss_spawned_at != g.player.level \
							)
						},
						game,
					),
					run(proc(d: rawptr) -> bool {
							g := (^Game_World)(d)
							g.boss_spawned_at = g.player.level
							spawn(g, .Boss)
							enqueue_node(&g.sys_exec, apply_camera_shake(g, 10.0))
							return true
						}, game),
					wait(20.0),
				),
				// Normal Wave Spawn
				seq(race(wait(3.0), wait_until(proc(d: rawptr) -> bool {return (^Game_World)(d).player.health < 30}, game)), run(proc(d: rawptr) -> bool {
							g := (^Game_World)(d)
							spawn(g, .Skeleton)
							if rand.float32() < 0.4 do spawn(g, .Wizard)
							if rand.float32() < 0.2 do spawn(g, .Elite_Skeleton)
							return true
						}, game)),
			),
		),
	)
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

	defer {
		for w in gw.player.weapons do free(w)
		delete(gw.player.weapons)
		delete(gw.enemies)
		delete(gw.gems)
		delete(gw.projectiles)
		executor_destroy(&gw.exec)
		executor_destroy(&gw.sys_exec)
		semaphore_destroy(&gw.charge_semaphore)
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

		rl.EndDrawing()
	}
}

