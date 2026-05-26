package main

import "core:fmt"
import "core:testing"

Test_Context :: struct {
	action_count:  int,
	was_completed: bool,
	was_failed:    bool,
	cleanup_val:   Status,
}

reset_context :: proc(ctx: ^Test_Context) {
	ctx.action_count = 0
	ctx.was_completed = false
	ctx.was_failed = false
	ctx.cleanup_val = .None
}

increment_action :: proc(data: rawptr) -> bool {
	ctx := (^Test_Context)(data)
	ctx.action_count += 1
	return true
}

fail_action :: proc(data: rawptr) -> bool {
	ctx := (^Test_Context)(data)
	ctx.was_failed = true
	return false
}

complete_action :: proc(data: rawptr) -> bool {
	ctx := (^Test_Context)(data)
	ctx.was_completed = true
	return true
}

@(test)
test_wait_and_callback_sequence :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	defer executor_destroy(&exec)

	ctx: Test_Context
	reset_context(&ctx)

	// Seq: incr -> wait 0.1s -> completed
	node := seq(run(increment_action, &ctx), wait(0.10), run(complete_action, &ctx))
	enqueue_node(&exec, node)

	executor_step(&exec, 0.0)
	testing.expect_value(t, ctx.action_count, 1)
	testing.expect_value(t, ctx.was_completed, false)

	executor_step(&exec, 0.05)
	testing.expect_value(t, ctx.was_completed, false)

	executor_step(&exec, 0.06)
	testing.expect_value(t, ctx.was_completed, true)
}

@(test)
test_selector_fallback :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	defer executor_destroy(&exec)

	ctx: Test_Context
	reset_context(&ctx)

	// Select: Try to Fail -> Then Fallback to Complete
	node := select(run(fail_action, &ctx), run(complete_action, &ctx))
	enqueue_node(&exec, node)

	executor_step(&exec, 0.0)

	testing.expect_value(t, ctx.was_failed, true) // First branch ran and failed
	testing.expect_value(t, ctx.was_completed, true) // Second branch successfully executed
}

@(test)
test_parallel_race :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	defer executor_destroy(&exec)

	ctx: Test_Context
	reset_context(&ctx)

	// Race: Fast wait vs Slow wait
	// If fast wait wins, slow wait is aborted and the complete action triggers
	node := seq(race(wait(0.05), wait(1.00)), run(complete_action, &ctx))
	enqueue_node(&exec, node)

	// 0.02s elapsed. No winner yet.
	executor_step(&exec, 0.02)
	testing.expect_value(t, ctx.was_completed, false)

	// Total 0.06s elapsed. 0.05s timer completed, winning the race.
	executor_step(&exec, 0.04)
	testing.expect_value(t, ctx.was_completed, true)
}

@(test)
test_parallel_sync :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	defer executor_destroy(&exec)

	ctx: Test_Context
	reset_context(&ctx)

	// Sync: Wait 0.05s AND Wait 0.20s
	node := seq(sync(wait(0.05), wait(0.20)), run(complete_action, &ctx))
	enqueue_node(&exec, node)

	// Step past the first timer limit (0.05s)
	executor_step(&exec, 0.10)
	testing.expect_value(t, ctx.was_completed, false) // Still waiting for the second timer (0.20s)

	// Step past the second timer limit
	executor_step(&exec, 0.15)
	testing.expect_value(t, ctx.was_completed, true) // Both are done, sync finishes
}

@(test)
test_loop_termination_on_failure :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	defer executor_destroy(&exec)

	ctx: Test_Context
	reset_context(&ctx)

	// Loop that increments action count, then fails on the third iteration
	looping_counter_action :: proc(data: rawptr) -> bool {
		c := (^Test_Context)(data)
		c.action_count += 1
		return c.action_count < 3 // Return false (fail) on the 3rd step to terminate loop
	}

	node := loop(run(looping_counter_action, &ctx))
	enqueue_node(&exec, node)

	executor_step(&exec, 0.0) // Frame 1: count = 1, returns true (running)
	testing.expect_value(t, ctx.action_count, 1)

	executor_step(&exec, 0.0) // Frame 2: count = 2, returns true (running)
	testing.expect_value(t, ctx.action_count, 2)

	executor_step(&exec, 0.0) // Frame 3: count = 3, returns false (fails, breaking loop)
	testing.expect_value(t, ctx.action_count, 3)

	// Step once more to verify execution has stopped
	executor_step(&exec, 0.0)
	testing.expect_value(t, ctx.action_count, 3) // Count should remain 3
}

@(test)
test_scope_cleanup :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	defer executor_destroy(&exec)

	ctx: Test_Context
	reset_context(&ctx)

	cleanup_callback :: proc(data: rawptr, status: Status) {
		c := (^Test_Context)(data)
		c.cleanup_val = status
	}

	// Scope wraps a wait node. When wait completes, cleanup runs with .Completed
	node := scope(wait(0.10), cleanup_callback, &ctx)
	enqueue_node(&exec, node)

	executor_step(&exec, 0.05)
	testing.expect_value(t, ctx.cleanup_val, Status.None) // Not finished yet

	executor_step(&exec, 0.06)
	testing.expect_value(t, ctx.cleanup_val, Status.Completed) // Cleanup executed successfully
}

@(test)
test_scope_cleanup_on_abort :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	defer executor_destroy(&exec)

	ctx: Test_Context
	reset_context(&ctx)

	cleanup_callback :: proc(data: rawptr, status: Status) {
		c := (^Test_Context)(data)
		c.cleanup_val = status
	}

	node := scope(wait(1.00), cleanup_callback, &ctx)
	enqueue_node(&exec, node)

	executor_step(&exec, 0.05)

	// Force abort the active node tree midway
	abort_node(&exec, node)
	testing.expect_value(t, ctx.cleanup_val, Status.Aborted) // Cleanup should run with Aborted state
}

@(test)
test_tween_interpolation :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	defer executor_destroy(&exec)

	val: f32 = 0.0
	node := tween(0.0, 10.0, 1.0, &val)
	enqueue_node(&exec, node)

	executor_step(&exec, 0.0)
	testing.expect(t, val == 0.0, "Expected initial value to be 0.0")

	executor_step(&exec, 0.5)
	testing.expect(t, val == 5.0, "Expected value to interpolate to 5.0")

	executor_step(&exec, 0.5)
	testing.expect(t, val == 10.0, "Expected final value to interpolate to 10.0")
}

@(test)
test_wait_until :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	defer executor_destroy(&exec)

	ctx: Test_Context
	reset_context(&ctx)

	condition_met := false
	check_condition :: proc(data: rawptr) -> bool {
		return (^bool)(data)^
	}

	node := seq(wait_until(check_condition, &condition_met), run(complete_action, &ctx))
	enqueue_node(&exec, node)

	executor_step(&exec, 0.0)
	testing.expect_value(t, ctx.was_completed, false)

	condition_met = true
	executor_step(&exec, 0.0)
	testing.expect_value(t, ctx.was_completed, true)
}

@(test)
test_catch_node :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	defer executor_destroy(&exec)

	ctx: Test_Context
	reset_context(&ctx)

	// Catch a failure, turning it into a success for the sequence
	node := seq(catch(run(fail_action, &ctx)), run(complete_action, &ctx))
	enqueue_node(&exec, node)

	executor_step(&exec, 0.0)
	testing.expect_value(t, ctx.was_failed, true)
	testing.expect_value(t, ctx.was_completed, true)
}

@(test)
test_logical_decorators :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	defer executor_destroy(&exec)

	ctx: Test_Context
	reset_context(&ctx)

	// Decorate a failure action with NOT, converting it to Success
	node := seq(not(run(fail_action, &ctx)), run(complete_action, &ctx))
	enqueue_node(&exec, node)

	executor_step(&exec, 0.0)
	testing.expect_value(t, ctx.was_failed, true) // Failure action was executed
	testing.expect_value(t, ctx.was_completed, true) // NOT intercepted failure, allowing sequence to complete
}

@(test)
test_nested_aborts :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	defer executor_destroy(&exec)

	ctx: Test_Context
	reset_context(&ctx)

	cleanup_callback :: proc(data: rawptr, status: Status) {
		c := (^Test_Context)(data)
		c.cleanup_val = status
	}

	// Seq [ Scope [ Wait ] ]
	// Aborting Seq should abort Scope, which should abort Wait and run cleanup.
	inner_wait := wait(10.0)
	scoped := scope(inner_wait, cleanup_callback, &ctx)
	root_seq := seq(scoped)

	enqueue_node(&exec, root_seq)
	executor_step(&exec, 0.1)

	testing.expect_value(t, ctx.cleanup_val, Status.None)

	abort_node(&exec, root_seq)
	testing.expect_value(t, ctx.cleanup_val, Status.Aborted)
}

@(test)
test_deep_nesting :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	defer executor_destroy(&exec)

	ctx: Test_Context
	reset_context(&ctx)

	// Deeply nested sequence
	node := seq(seq(seq(seq(run(complete_action, &ctx)))))
	enqueue_node(&exec, node)

	executor_step(&exec, 0.0)
	testing.expect_value(t, ctx.was_completed, true)
}

@(test)
test_manual_enqueue_during_step :: proc(t: ^testing.T) {
	exec: Executor
	executor_init(&exec)
	defer executor_destroy(&exec)

	ctx: Test_Context
	reset_context(&ctx)

	// Action that enqueues another action when run
	enqueue_action :: proc(data: rawptr) -> bool {
		payload := (^struct {
				exec: ^Executor,
				ctx:  ^Test_Context,
			})(data)
		enqueue_node(payload.exec, run(complete_action, payload.ctx))
		return true
	}

	payload := struct {
		exec: ^Executor,
		ctx:  ^Test_Context,
	}{&exec, &ctx}

	enqueue_node(&exec, run(enqueue_action, &payload))

	executor_step(&exec, 0.0)
	// The enqueued action should have run in the same frame
	testing.expect_value(t, ctx.was_completed, true)
}

