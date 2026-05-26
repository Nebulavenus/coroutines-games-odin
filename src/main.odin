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
	pos:     [2]f32,
	health:  int,
	speed:   f32,
	is_boss: bool,
}

Weapon :: struct {
	name:     string,
	damage:   int,
	cooldown: f32,
	behavior: ^Node, // auto-firing loop
}

Projectile :: struct {
	pos:   [2]f32,
	dir:   [2]f32,
	speed: f32,
}

Game_World :: struct {
	player:              Player,
	enemies:             [dynamic]Enemy,
	gems:                [dynamic][2]f32,
	projectiles:         [dynamic]Projectile,
	spawner_coro:        ^Node, // spawning loop
	exec:                Executor, // gameplay time
	sys_exec:            Executor, // real time (UI, juice)
	is_paused:           bool,
	player_damage_timer: f32,
	camera_shake:        f32,
	level_up_scale:      f32,
}

apply_camera_shake :: proc(game: ^Game_World, amount: f32) -> ^Node {
	return tween(amount, 0.0, 0.4, &game.camera_shake)
}

shield_behavior :: proc(game: ^Game_World, duration: f32) -> ^Node {
	return seq(run(proc(data: rawptr) -> bool {
				gw := (^Game_World)(data)
				gw.player.shield_active = true
				return true
			}, game), scope(wait(duration), proc(data: rawptr, status: Status) {
				gw := (^Game_World)(data)
				gw.player.shield_active = false
			}, game))
}

super_attack_behavior :: proc(game: ^Game_World) -> ^Node {
	return seq(
		sync(apply_camera_shake(game, 15.0), wait(0.5)), // Parallel Shake and Wait, then Fire
		// Fire in all directions
		run(proc(data: rawptr) -> bool {
				gw := (^Game_World)(data)
				for i in 0 ..< 8 {
					angle := f32(i) * math.PI / 4.0
					dir := [2]f32{math.cos(angle), math.sin(angle)}
					append(
						&gw.projectiles,
						Projectile{pos = gw.player.pos, dir = dir, speed = 400.0},
					)
				}
				return true
			}, game),
	)
}

// attacks enemies in area with intervals
whip_behavior :: proc(game: ^Game_World, weapon: ^Weapon) -> ^Node {
	return loop(
		seq(
			wait(weapon.cooldown), // delay between attacks

			// animation and damage
			run(
				proc(data: rawptr) -> bool {
					gw := (^Game_World)(data)

					for &enemy in gw.enemies {
						dist := linalg.distance(enemy.pos, gw.player.pos)
						if dist < 120.0 {
							enemy.health -= 15
						}
					}
					gw.player.whip_flash_timer = 0.15 // flash duration
					return true
				},
				game,
			),
		),
	)
}

// every few seconds fires fireball to nearest enemy
fireball_behavior :: proc(game: ^Game_World, weapon: ^Weapon) -> ^Node {
	return loop(
		seq(
			wait(weapon.cooldown), // delay between attacks

			// animation and damage
			run(
				proc(data: rawptr) -> bool {
					gw := (^Game_World)(data)
					if len(gw.enemies) == 0 do return true

					// find nearest enemy
					nearest_index := 0
					min_dist := f32(99999.0)
					for enemy, i in gw.enemies {
						dist := linalg.distance(enemy.pos, gw.player.pos)
						if dist < min_dist {
							min_dist = dist
							nearest_index = i
						}
					}

					dir := gw.enemies[nearest_index].pos - gw.player.pos
					if linalg.length(dir) > 0 {
						dir = linalg.normalize(dir)
						append(
							&gw.projectiles,
							Projectile{pos = gw.player.pos, dir = dir, speed = 280.0},
						)
					}
					return true
				},
				game,
			),
		),
	)
}

// progression with intervals spawning
spawner_behavior :: proc(game: ^Game_World) -> ^Node {

	spawn_skeleton_wave :: proc(data: rawptr) -> bool {
		gw := (^Game_World)(data)
		for i in 0 ..< 5 {
			angle := rand.float32_range(0, 2 * math.PI)
			offset := [2]f32{math.cos(angle), math.sin(angle)} * 220.0
			append(
				&gw.enemies,
				Enemy{pos = gw.player.pos + offset, health = 20, speed = 70.0, is_boss = false},
			)
		}
		return true
	}

	spawn_boss :: proc(data: rawptr) -> bool {
		gw := (^Game_World)(data)
		append(
			&gw.enemies,
			Enemy{pos = gw.player.pos + {0, -200}, health = 250, speed = 50.0, is_boss = true},
		)
		enqueue_node(&gw.exec, apply_camera_shake(gw, 10.0))
		return true
	}

	return loop(
		seq(
			select(
				seq(
					check(
						proc(data: rawptr) -> bool { 	// Select - try to spawn boss if level is high, otherwise normal wave
							gw := (^Game_World)(data)
							return gw.player.level % 3 == 0
						},
						game,
					),
					run(spawn_boss, game),
					wait(10.0),
				),
				seq(
					race(
						wait(3.0),
						wait_until(
							proc(data: rawptr) -> bool { 	// Race - Wait for 3 seconds or until player health is low
								gw := (^Game_World)(data)
								return gw.player.health < 20
							},
							game,
						),
					),
					run(spawn_skeleton_wave, game),
				),
			),
		),
	)
}

level_up_sequence :: proc(game: ^Game_World) -> ^Node {
	return seq(
		run(
			proc(data: rawptr) -> bool { 	// pause gameplay
				gw := (^Game_World)(data)
				gw.is_paused = true
				gw.level_up_scale = 0
				return true
			},
			game,
		),
		tween(0.0, 1.0, 0.4, &game.level_up_scale),
		// upgrade ui, wait for input
		wait_until(
			proc(data: rawptr) -> bool {
				gw := (^Game_World)(data)

				// pressed [1] cooldown upgrade
				if rl.IsKeyPressed(.ONE) {
					for &weapon in gw.player.weapons {
						if weapon.name == "Whip" {
							weapon.cooldown = math.max(0.4, weapon.cooldown - 0.25)
						}
					}
					return true
				}
				// pressed [2] health recovery upgrade
				if rl.IsKeyPressed(.TWO) {
					gw.player.max_health += 30
					gw.player.health = gw.player.max_health
					return true
				}
				// pressed [3] special shield
				if rl.IsKeyPressed(.THREE) {
					enqueue_node(&gw.exec, shield_behavior(gw, 5.0))
					return true
				}
				return false
			},
			game,
		),
		tween(1.0, 0.0, 0.2, &game.level_up_scale),
		// apply upgrade and resume game
		run(proc(data: rawptr) -> bool {
				gw := (^Game_World)(data)
				gw.is_paused = false
				return true
			}, game),
	)
}

main :: proc() {
	context.logger = log.create_console_logger()

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
	gw.player.xp = 0
	gw.player.xp_needed = 5
	gw.player.level = 1

	gw.enemies = make([dynamic]Enemy)
	gw.gems = make([dynamic][2]f32)
	gw.projectiles = make([dynamic]Projectile)

	executor_init(&gw.exec)
	executor_init(&gw.sys_exec)
	defer {
		for w in gw.player.weapons {
			free(w)
		}
		delete(gw.player.weapons)
		delete(gw.enemies)
		delete(gw.gems)
		delete(gw.projectiles)
		executor_destroy(&gw.exec)
		executor_destroy(&gw.sys_exec)
	}

	gw.spawner_coro = spawner_behavior(&gw)
	enqueue_node(&gw.exec, gw.spawner_coro)

	// Player weapons
	whip := new(Weapon)
	whip.name = "Whip"
	whip.damage = 15
	whip.cooldown = 1.3
	whip.behavior = whip_behavior(&gw, whip)
	append(&gw.player.weapons, whip)
	enqueue_node(&gw.exec, whip.behavior)

	fireball := new(Weapon)
	fireball.name = "Fireball"
	fireball.damage = 25
	fireball.cooldown = 1.8
	fireball.behavior = fireball_behavior(&gw, fireball)
	append(&gw.player.weapons, fireball)
	enqueue_node(&gw.exec, fireball.behavior)

	// Game loop
	for !rl.WindowShouldClose() {
		dt := rl.GetFrameTime()

		// update game
		if !gw.is_paused {
			p_dir: [2]f32
			if rl.IsKeyDown(.W) || rl.IsKeyDown(.UP) do p_dir.y -= 1
			if rl.IsKeyDown(.S) || rl.IsKeyDown(.DOWN) do p_dir.y += 1
			if rl.IsKeyDown(.A) || rl.IsKeyDown(.LEFT) do p_dir.x -= 1
			if rl.IsKeyDown(.D) || rl.IsKeyDown(.RIGHT) do p_dir.x += 1

			if linalg.length(p_dir) > 0 {
				p_dir = linalg.normalize(p_dir)
				gw.player.pos += p_dir * 180.0 * dt
				gw.player.pos.x = math.clamp(gw.player.pos.x, 10, W_WIDTH - 10)
				gw.player.pos.y = math.clamp(gw.player.pos.y, 10, W_HEIGHT - 10)
			}

			if rl.IsKeyPressed(.SPACE) {
				enqueue_node(&gw.exec, super_attack_behavior(&gw))
			}

			if gw.player.whip_flash_timer > 0.0 {
				gw.player.whip_flash_timer -= dt
			}

			if gw.player_damage_timer > 0.0 {
				gw.player_damage_timer -= dt
			}

			// update enemies
			for i := len(gw.enemies) - 1; i >= 0; i -= 1 {
				enemy := &gw.enemies[i]

				e_dir := gw.player.pos - enemy.pos
				dist := linalg.length(e_dir)
				if dist > 5.0 {
					e_dir = linalg.normalize(e_dir)
					enemy.pos += e_dir * enemy.speed * dt
				}

				if dist < 15.0 && gw.player_damage_timer <= 0.0 && !gw.player.shield_active {
					gw.player.health = math.max(0, gw.player.health - 10)
					gw.player_damage_timer = 0.5
					enqueue_node(&gw.sys_exec, apply_camera_shake(&gw, 5.0))
				}

				if enemy.health <= 0 {
					append(&gw.gems, enemy.pos)
					unordered_remove(&gw.enemies, i)
				}
			}

			// update projectiles
			for i := len(gw.projectiles) - 1; i >= 0; i -= 1 {
				proj := &gw.projectiles[i]
				proj.pos += proj.dir * proj.speed * dt

				hit := false
				for &enemy in gw.enemies {
					if linalg.distance(proj.pos, enemy.pos) < 20.0 {
						enemy.health -= 25
						hit = true
						break
					}
				}

				offscreen :=
					proj.pos.x < -10 ||
					proj.pos.x > W_WIDTH + 10 ||
					proj.pos.y < -10 ||
					proj.pos.y > W_HEIGHT + 10
				if hit || offscreen {
					unordered_remove(&gw.projectiles, i)
				}
			}

			// update gems
			for i := len(gw.gems) - 1; i >= 0; i -= 1 {
				gem_pos := gw.gems[i]
				dist := linalg.distance(gw.player.pos, gem_pos)
				if dist < 60.0 {
					// Attract toward player
					dir := linalg.normalize(gw.player.pos - gem_pos)
					gw.gems[i] += dir * 250.0 * dt

					if dist < 12.0 {
						gw.player.xp += 1
						unordered_remove(&gw.gems, i)

						// Trigger level up sequence coroutine
						if gw.player.xp >= gw.player.xp_needed {
							gw.player.xp -= gw.player.xp_needed
							gw.player.level += 1
							gw.player.xp_needed = int(f32(gw.player.xp_needed) * 1.6)
							enqueue_node(&gw.sys_exec, level_up_sequence(&gw))
						}
					}
				}
			}
		}

		// update coroutines
		current_dt := gw.is_paused ? f32(0.0) : dt
		executor_step(&gw.exec, current_dt)
		executor_step(&gw.sys_exec, dt)

		// render everything
		rl.BeginDrawing()
		rl.ClearBackground(rl.Color{24, 28, 36, 255})

		shake_offset := [2]f32 {
			rand.float32_range(-gw.camera_shake, gw.camera_shake),
			rand.float32_range(-gw.camera_shake, gw.camera_shake),
		}

		for gem in gw.gems {
			rl.DrawRectanglePro(
				rl.Rectangle {
					x = gem.x + shake_offset.x,
					y = gem.y + shake_offset.y,
					width = 8,
					height = 8,
				},
				rl.Vector2{4, 4},
				45.0,
				rl.SKYBLUE,
			)
		}

		for enemy in gw.enemies {
			color := enemy.is_boss ? rl.MAROON : rl.RED
			radius := f32(enemy.is_boss ? 18.0 : 10.0)
			rl.DrawCircleV(cast(rl.Vector2)(enemy.pos + shake_offset), radius, color)
		}

		for proj in gw.projectiles {
			rl.DrawCircleV(cast(rl.Vector2)(proj.pos + shake_offset), 5.0, rl.ORANGE)
		}

		player_color := gw.player_damage_timer > 0.0 ? rl.ORANGE : rl.GREEN
		rl.DrawCircleV(cast(rl.Vector2)(gw.player.pos + shake_offset), 12.0, player_color)

		if gw.player.shield_active {
			rl.DrawCircleLinesV(cast(rl.Vector2)(gw.player.pos + shake_offset), 20.0, rl.SKYBLUE)
		}

		if gw.player.whip_flash_timer > 0.0 {
			rl.DrawCircleLinesV(
				cast(rl.Vector2)(gw.player.pos + shake_offset),
				120.0,
				rl.Fade(rl.LIGHTGRAY, 0.4),
			)
		}

		hud_y := i32(10)
		rl.DrawText(
			rl.TextFormat("HP: %d/%d", gw.player.health, gw.player.max_health),
			10,
			hud_y,
			16,
			rl.WHITE,
		)
		rl.DrawText(rl.TextFormat("Level: %d", gw.player.level), 160, hud_y, 16, rl.GOLD)
		rl.DrawText(
			rl.TextFormat("XP: %d/%d", gw.player.xp, gw.player.xp_needed),
			280,
			hud_y,
			16,
			rl.SKYBLUE,
		)
		rl.DrawText(
			rl.TextFormat("Active Enemies: %d", len(gw.enemies)),
			440,
			hud_y,
			16,
			rl.LIGHTGRAY,
		)
		rl.DrawText("SPACE for Super Attack", 10, W_HEIGHT - 30, 16, rl.DARKGRAY)

		// Level Up Card Screen
		if gw.is_paused {
			rl.DrawRectangle(0, 0, W_WIDTH, W_HEIGHT, rl.Fade(rl.BLACK, 0.75 * gw.level_up_scale))

			card_y := f32(W_HEIGHT / 2 - 50) * gw.level_up_scale

			rl.DrawText("LEVEL UP!", W_WIDTH / 2 - 70, i32(card_y - 100), 28, rl.YELLOW)
			rl.DrawText(
				"Choose an upgrade:",
				W_WIDTH / 2 - 100,
				i32(card_y - 50),
				18,
				rl.LIGHTGRAY,
			)

			rl.DrawRectangle(40, i32(card_y), 180, 100, rl.DARKGRAY)
			rl.DrawRectangleLines(40, i32(card_y), 180, 100, rl.GOLD)
			rl.DrawText("[1] Whip Spd", 50, i32(card_y + 15), 14, rl.GOLD)
			rl.DrawText("Lower cooldown", 50, i32(card_y + 40), 16, rl.WHITE)

			rl.DrawRectangle(230, i32(card_y), 180, 100, rl.DARKGRAY)
			rl.DrawRectangleLines(230, i32(card_y), 180, 100, rl.GOLD)
			rl.DrawText("[2] Vitality", 240, i32(card_y + 15), 14, rl.GOLD)
			rl.DrawText("Heal + Max HP", 240, i32(card_y + 40), 16, rl.WHITE)

			rl.DrawRectangle(420, i32(card_y), 180, 100, rl.DARKGRAY)
			rl.DrawRectangleLines(420, i32(card_y), 180, 100, rl.GOLD)
			rl.DrawText("[3] Shield", 430, i32(card_y + 15), 14, rl.GOLD)
			rl.DrawText("5s Invincibility", 430, i32(card_y + 40), 16, rl.WHITE)
		}

		if gw.player.health <= 0 {
			rl.DrawRectangle(0, 0, W_WIDTH, W_HEIGHT, rl.Fade(rl.MAROON, 0.6))
			rl.DrawText("GAME OVER", W_WIDTH / 2 - 100, W_HEIGHT / 2 - 20, 32, rl.WHITE)
		}

		rl.EndDrawing()
	}
}

