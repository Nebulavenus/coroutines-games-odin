# Coroutines for Games in Odin

A lightweight, hierarchical, stackless, cooperative task scheduler and coroutine library for the Odin programming language.

Inspired by the structured concurrency paradigm of *SkookumScript*. It allows you to write asynchronous code in a linear way to manage time-dependent gameplay logic, scripted sequences, AI behavior, and animations. It is highly portable and ticks entirely on the main game thread, without any OS context switching.

This is an idiomatic Odin port of [ACE Team Coroutines for UE](https://github.com/aceteam/Coroutines)

**WIP**, but its already usable.

## Basic Usage

To run a coroutine, initialize an `Executor` and enqueue a composed task node. Here is a simple sequence that waits, executes a callback, and then interpolates a value:

```odin
package main

import "core:fmt"
import k2 "shared:karl2d"

Game_State :: struct {
    exec:         Executor,
    player_y:     f32,
    player_score: int,
}

main :: proc() {
    state: Game_State
    executor_init(&state.exec)
    defer executor_destroy(&state.exec)

    // Construct a coroutine which executes tasks sequentially
    // wait 1.5s -> increase score -> apply tween 2s, to move player up
    my_task := seq(
        wait(1.5),
        run(proc(s: ^Game_State) -> bool {
            s.player_score += 100
            fmt.println("Score increased!")
            return true
        }, &state),
        tween(0.0, 400.0, 2.0, &state.player_y, ease_in_out_cubic),
    )

    // Add coroutine to the scheduler
    enqueue_node(&state.exec, my_task)
  
    // Step the executor in your main loop
    dt: f32 = 1.0 / 60.0 // or k2.get_frame_time()
    for step in 0..120 {
      executor_step(&state.exec, dt)
    }
}
```

## Complex example

Playable version on itch.io: 

Check `main.odin` to check how it looks.

## Installation

Copy `coroutines.odin` file into your project.

## Node Catalog

The library provides three core types of execution nodes: **Composites** (control flow), **Decorators** (behavior wrappers), and **Leaves** (actions & timers).

### 1. Composites (Execution Flow)
*   **`seq(nodes...)`**: Runs children sequentially. Aborts and propagates failure immediately if any child fails.
*   **`optional_seq(nodes...)`**: Runs children sequentially but ignores child failures, continuing until all children have run.
*   **`select(nodes...)`**: Runs children sequentially until one *succeeds* (Selector/Fallback). Only fails if all children fail.
*   **`race(nodes...)`**: Runs children concurrently in parallel. The *first* child to complete or fail immediately aborts all other running branches.
*   **`sync(nodes...)`**: Runs children concurrently in parallel. Waits for *all* children to complete. Fails if any child fails.

### 2. Decorators (Wrappers)
*   **`loop(child)`**: Ticks its child indefinitely. If the child fails, the loop terminates successfully.
*   **`loop_seq(nodes...)`**: Shorthand wrapper combining `loop` and `seq`.
*   **`scope(child, on_exit, payload)`**: Executes a guaranteed cleanup callback when the scope is terminated (via completion, failure, or abortion).
*   **`weak(child, is_valid, payload)`**: Monitors target validity every frame. Instantly aborts the child and fails if the target is invalidated.
*   **`managed(child, payload)`**: Pairs a node with its dynamic payload allocation, automatically freeing the payload memory when the node is destroyed.
*   **`managed_run(callback, payload)`**: Shorthand wrapper combining `managed` and `run`.
*   **`capture_return(child, bool_ptr)`**: Captures the success outcome of its child and writes it to a boolean pointer.
*   **`semaphore_scope(semaphore, child)`**: Limits concurrent access to the child node based on available semaphore locks.
*   **`not(child)`**: Negates success/failure states of the child.
*   **`catch(child, bool_ptr = nil)`**: Converts any child failure into a success state, optionally writing the result to a boolean pointer.
*   **`named(child, name)`**: Assigns a user-friendly debug name to the node for visual diagnostics.

### 3. Leaf Nodes (Action & Timers)
*   **`wait(duration)`**: Pauses execution for a float duration in seconds.
*   **`wait_ptr(^duration)`**: Pauses execution, pulling its duration dynamically from a float pointer.
*   **`wait_frames(frame_count)`**: Pauses execution for a fixed number of engine ticks.
*   **`wait_until(condition, payload)`**: Suspends the coroutine, polling the condition procedure every frame until it returns `true`.
*   **`check(condition, payload)`**: Performs an instant, non-blocking evaluation, returning success or failure.
*   **`run(callback, payload)`**: Runs a standard, non-capturing procedure instantly.
*   **`tween(start, target, duration, output_ptr, ease_func)`**: Smoothly interpolates an output float using linear or customizable easing equations.
*   **`nop()`**: Completes instantly with success.
*   **`fail()`**: Completes instantly with failure.
*   **`fork(child)`**: Spawns its child as an independent root-level node, isolating it from parent aborts.
*   **`wait_forever()`**: Suspends the coroutine indefinitely.

---

## Memory Management

Because Odin is a manually managed systems language, the library provides some QoL utilities for memory management in coroutines, but it's still a WIP.

When a root node (no parents) completes or is aborted, the `Executor` calls `destroy_node()` recursively, freeing the entire subtree.

Payloads used in callbacks can lead to dangling pointers or leaks, so special wrapper `managed` exists.

---

## Visual Debugging

WIP

Exists, check itch.io to see it.

* F1 - toggle debugger
* F2 - full/compact view
* F3 - pause debugger/game
* F4 - clear filters
* Mouse Wheel - to scroll
