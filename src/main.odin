package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:strings"
import rl "vendor:raylib"
import img "vendor:stb/image"
import "core:math"
import "core:math/rand"
import "core:math/linalg"

// --- Windows High Performance GPU Hint ---
@(export, link_name = "NvOptimusEnablement")
NvOptimusEnablement: c.ulong = 1
@(export, link_name = "AmdPowerXpressRequestingHighPerformance")
AmdPowerXpressRequestingHighPerformance: i32 = 1

W_WIDTH, W_HEIGHT :: 640, 480

Player :: struct {
	pos: [2]f32,
	health: int,
	max_health: int,
	xp: int,
	xp_needed: int,
	level: int,
	weapons: [dynamic]^Weapon,
	whip_flash_timer: f32,
}

Enemy :: struct {
	pos: [2]f32,
	health: int,
	speed: f32,
	is_boss: bool,
}

Weapon :: struct {
	name: string,
	damage: int,
	cooldown: f32,
	behavior: ^Node, // auto-firing loop
}

Projectile :: struct {
	pos: [2]f32,
	dir: [2]f32,
	speed: f32,
}

Game_World :: struct {
	player: Player,
	enemies: [dynamic]Enemy,
	gems: [dynamic][2]f32,
	projectiles: [dynamic]Projectile,
	spawner_coro: ^Node, // spawning loop
	exec: Executor,
	is_paused: bool,
	player_damage_timer: f32,
}

// attacks enemies in area with intervals
whip_behavior :: proc(game: ^Game_World, weapon: ^Weapon) -> ^Node {
	return loop(
		seq(
			// delay between attacks
			wait(weapon.cooldown),

			// animation and damage
			run(proc(data: rawptr) -> bool {
				gw := (^Game_World)(data)

				for &enemy in gw.enemies {
					dist := linalg.distance(enemy.pos, gw.player.pos)
					if dist < 120.0 {
						enemy.health -= 15
					}
				}
				gw.player.whip_flash_timer = 0.15 // flash duration
				return true
			}, game),
	)
)
}

// every few seconds fires firebal to nearest enemy
fireball_behavior :: proc(game: ^Game_World, weapon: ^Weapon) -> ^Node {
	return loop(
		seq(
			// delay between attacks
			wait(weapon.cooldown),

			// animation and damage
			run(proc(data: rawptr) -> bool {
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
					append(&gw.projectiles, Projectile {
						pos = gw.player.pos,
						dir = dir,
						speed = 280.0,
					})
			}
			return true
		}, game),
)
)
}

// progression with intervals spawning
spawner_behavior :: proc(game: ^Game_World) -> ^Node {

	spawn_skeleton_wave :: proc(data: rawptr) -> bool {
		gw := (^Game_World)(data)
		for i in 0..<5 {
			angle := rand.float32_range(0, 2 * math.PI)
			offset := [2]f32{math.cos(angle), math.sin(angle)} * 220.0
			append(&gw.enemies, Enemy {
				pos = gw.player.pos + offset,
				health = 20,
				speed = 70.0,
				is_boss = false,
			})
		}
		return true
	}

	spawn_boss :: proc(data: rawptr) -> bool {
		gw := (^Game_World)(data)
		append(&gw.enemies, Enemy {
			pos = gw.player.pos + {0, -200},
			health = 250,
			speed = 50.0,
			is_boss = true
		})
		return true
	}

	return seq(
		// wave 1
		// basic skeletons every 3 seconds
		race(
			loop(
				seq(
					run(spawn_skeleton_wave, game),
					wait(3.0),
				)
			),
			wait(30.0), // wait 30 seconds to spawn boss
		),

		// boss transition
		run(spawn_boss, game),
		wait(5.0),

		// wave 2
		// double spawn rate for skeletons
		loop(
			seq(
				run(spawn_skeleton_wave, game),
				wait(1.5),
			)
		)
	)
}

level_up_sequence :: proc(game: ^Game_World) -> ^Node {
	return seq(
		// pause gameplay
		run(proc(data: rawptr) -> bool {
			gw := (^Game_World)(data)
			gw.is_paused = true
			return true
		}, game),

	// upgrade ui, wait for input
	wait_until(proc(data: rawptr) -> bool {
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
		return false
	}, game),

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
	defer {
		for w in gw.player.weapons {
			free(w)
		}
		delete(gw.player.weapons)
		delete(gw.enemies)
		delete(gw.gems)
		delete(gw.projectiles)
		executor_destroy(&gw.exec)
	}

	gw.spawner_coro = spawner_behavior(&gw)
	enqueue_node(&gw.exec, gw.spawner_coro)

	// Player weapon
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

				if dist < 15.0 && gw.player_damage_timer <= 0.0 {
					gw.player.health = math.max(0, gw.player.health - 10)
					gw.player_damage_timer = 0.5
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

				offscreen := proj.pos.x < -10 || proj.pos.x > W_WIDTH + 10 || proj.pos.y < -10 || proj.pos.y > W_HEIGHT + 10
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
							enqueue_node(&gw.exec, level_up_sequence(&gw))
						}
					}
				}
			}
		}

		// update coroutines
		current_dt := gw.is_paused ? f32(0.0) : dt
		executor_step(&gw.exec, current_dt)

		// render everything
		rl.BeginDrawing()
		rl.ClearBackground(rl.Color{24, 28, 36, 255})

		for gem in gw.gems {
			rl.DrawRectanglePro(
				rl.Rectangle{x = gem.x, y = gem.y, width = 8, height = 8},
				rl.Vector2{4, 4},
				45.0,
				rl.SKYBLUE
			)
		}

		for enemy in gw.enemies {
			color := enemy.is_boss ? rl.MAROON : rl.RED
			radius := f32(enemy.is_boss ? 18.0 : 10.0)
			rl.DrawCircleV(cast(rl.Vector2)enemy.pos, radius, color)
		}

		for proj in gw.projectiles {
			rl.DrawCircleV(cast(rl.Vector2)proj.pos, 5.0, rl.ORANGE)
		}

		player_color := gw.player_damage_timer > 0.0 ? rl.ORANGE : rl.GREEN
		rl.DrawCircleV(cast(rl.Vector2)gw.player.pos, 12.0, player_color)

		if gw.player.whip_flash_timer > 0.0 {
			rl.DrawCircleLinesV(cast(rl.Vector2)gw.player.pos, 120.0, rl.Fade(rl.LIGHTGRAY, 0.4))
		}

		hud_y := i32(10)
		rl.DrawText(rl.TextFormat("HP: %d/%d", gw.player.health, gw.player.max_health), 10, hud_y, 16, rl.WHITE)
		rl.DrawText(rl.TextFormat("Level: %d", gw.player.level), 160, hud_y, 16, rl.GOLD)
		rl.DrawText(rl.TextFormat("XP: %d/%d", gw.player.xp, gw.player.xp_needed), 280, hud_y, 16, rl.SKYBLUE)
		rl.DrawText(rl.TextFormat("Active Enemies: %d", len(gw.enemies)), 440, hud_y, 16, rl.LIGHTGRAY)

		// Level Up Card Screen
		if gw.is_paused {
			rl.DrawRectangle(0, 0, W_WIDTH, W_HEIGHT, rl.Fade(rl.BLACK, 0.75))
			rl.DrawText("LEVEL UP!", W_WIDTH / 2 - 70, 140, 28, rl.YELLOW)
			rl.DrawText("Choose an upgrade:", W_WIDTH / 2 - 100, 190, 18, rl.LIGHTGRAY)

			rl.DrawRectangle(100, 240, 200, 100, rl.DARKGRAY)
			rl.DrawRectangleLines(100, 240, 200, 100, rl.GOLD)
			rl.DrawText("Press [1]", 120, 255, 14, rl.GOLD)
			rl.DrawText("Whip Swiftness", 120, 280, 16, rl.WHITE)
			rl.DrawText("Cooldown reduction", 120, 305, 12, rl.GRAY)

			rl.DrawRectangle(340, 240, 200, 100, rl.DARKGRAY)
			rl.DrawRectangleLines(340, 240, 200, 100, rl.GOLD)
			rl.DrawText("Press [2]", 360, 255, 14, rl.GOLD)
			rl.DrawText("Vitality", 360, 280, 16, rl.WHITE)
			rl.DrawText("Heal & increase HP", 360, 305, 12, rl.GRAY)
		}

		if gw.player.health <= 0 {
			rl.DrawRectangle(0, 0, W_WIDTH, W_HEIGHT, rl.Fade(rl.MAROON, 0.6))
			rl.DrawText("GAME OVER", W_WIDTH / 2 - 100, W_HEIGHT / 2 - 20, 32, rl.WHITE)
		}

		rl.EndDrawing()
	}
}
