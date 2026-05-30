package main

import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"
import hm "core:container/handle_map"

Status :: enum {
	None,
	Completed,
	Failed,
	Running,
	Suspended,
	Aborted,
}

Handle :: hm.Handle32

Node :: struct {
	handle:       Handle,
	parent:       Handle,
	first_child:  Handle,
	next_sibling: Handle,
	status:       Status,
	name:         string,
	user_name:    string,
	start_time:   f64,
	show_age:     bool,
	data:         Node_Data,
}

Node_Exec_Info :: struct {
	handle: Handle,
	status: Status,
}

Ease_Proc :: proc(t: f32) -> f32

ease_linear :: proc(t: f32) -> f32 {
	return t
}

ease_in_out_cubic :: proc(t: f32) -> f32 {
	if t < 0.5 {
		return 4.0 * t * t * t
	}
	return 1.0 - math.pow(f32(-2.0 * t + 2.0), 3.0) / 2.0
}

ease_in_out_elastic :: proc(t: f32) -> f32 {
	c5: f32 = (2.0 * math.PI) / 4.5
	if t == 0.0 do return 0.0
	if t == 1.0 do return 1.0

	if t < 0.5 {
		return -(math.pow(f32(2.0), 20.0 * t - 10.0) * math.sin((20.0 * t - 11.125) * c5)) / 2.0
	}
	return (math.pow(f32(2.0), -20.0 * t + 10.0) * math.sin((20.0 * t - 11.125) * c5)) / 2.0 + 1.0
}

Tween_Node :: struct {
	start_val, target_val: f32,
	duration, elapsed: 	   f32,
	output:				   ^f32,
    ease: 				   Ease_Proc,
}

Wait_Node :: struct {
	duration, elapsed: f32,
	duration_ptr:      ^f32,
}

Sequence_Node :: struct {
	current_child: Handle,
}

Select_Node :: struct {
	current_child: Handle,
}

Callback_Node :: struct {
	callback_ptr: rawptr,
	payload:      rawptr,
	thunk:        proc(cb: rawptr, p: rawptr) -> bool,
}

Loop_Node :: struct {
	last_step: int,
}

Race_Node :: struct {}

Sync_Node :: struct {
	closed_count: int,
	end_status:   Status,
}

Condition_Node :: struct {
	condition_ptr: rawptr,
	payload:       rawptr,
	thunk:         proc(cb: rawptr, p: rawptr) -> bool,
}

Scope_Node :: struct {
	on_exit_ptr: rawptr,
	payload:     rawptr,
	thunk:       proc(cb: rawptr, p: rawptr, status: Status),
}

Not_Node :: struct {}

Managed_Node :: struct {
	payload:    rawptr,
	allocator:  mem.Allocator,
}

Catch_Node :: struct {
	output: ^bool,
}

Wait_Frames_Node :: struct {
	target_frames:  int,
	elapsed_frames: int,
}

Capture_Return_Node :: struct {
	output: ^bool,
}

Optional_Sequence_Node :: struct {
	current_child: Handle,
}

Semaphore_Handler_Node :: struct {
	sem:      ^Semaphore,
	acquired: bool,
}

Fork_Node :: struct {}

Wait_Forever_Node :: struct {}

Weak_Node :: struct {
	is_valid_ptr: rawptr,
	payload:      rawptr,
	thunk:        proc(cb: rawptr, p: rawptr) -> bool,
}

Node_Data :: union {
	Wait_Node,
	Sequence_Node,
	Select_Node,
	Callback_Node,
	Loop_Node,
	Race_Node,
	Sync_Node,
	Tween_Node,
	Condition_Node,
	Scope_Node,
	Not_Node,
	Managed_Node,
	Catch_Node,
	Wait_Frames_Node,
	Capture_Return_Node,
	Optional_Sequence_Node,
	Semaphore_Handler_Node,
	Fork_Node,
	Wait_Forever_Node,
	Weak_Node,
}

Fading_Node :: struct {
	name:       string,
	user_name:  string,
	info:       string, // cloned only for fading
	status:     Status,
	end_time:   f64,
	depth:      int,
}

Diagnostics_DB :: struct {
	enabled:      bool,
	fading_nodes: [dynamic]Fading_Node,
	allocator:    mem.Allocator,
}

diagnostics_db_init :: proc(db: ^Diagnostics_DB, allocator := context.allocator) {
	db.allocator = allocator
	db.enabled = true
	db.fading_nodes = make([dynamic]Fading_Node, 0, 128, allocator)
}

diagnostics_db_destroy :: proc(db: ^Diagnostics_DB) {
	for &f in db.fading_nodes {
		if len(f.info) > 0 do delete(f.info, db.allocator)
	}
	delete(db.fading_nodes)
}

Executor :: struct {
	pool:              hm.Dynamic_Handle_Map(Node, Handle),
	active_nodes:      [dynamic]Node_Exec_Info,
	next_active_nodes: [dynamic]Node_Exec_Info,
	suspended_nodes:   [dynamic]Node_Exec_Info,
	step_count:        int,
	total_time:        f64,
	allocator:         mem.Allocator,
	debugger:          ^Diagnostics_DB,
}

executor_init :: proc(exec: ^Executor, allocator := context.allocator) {
	exec.allocator = allocator
	hm.dynamic_init(&exec.pool, allocator)
	exec.active_nodes = make([dynamic]Node_Exec_Info, allocator)
	exec.next_active_nodes = make([dynamic]Node_Exec_Info, allocator)
	exec.suspended_nodes = make([dynamic]Node_Exec_Info, allocator)
	exec.step_count = 0
	exec.total_time = 0
	exec.debugger = nil
}

executor_destroy :: proc(exec: ^Executor) {
	for info in exec.active_nodes {
		if info.handle.idx != 0 {
			node, ok := hm.get(&exec.pool, info.handle)
			if ok && node.parent.idx == 0 {
				node_free(exec, info.handle)
			}
		}
	}
	for info in exec.next_active_nodes {
		if info.handle.idx != 0 {
			node, ok := hm.get(&exec.pool, info.handle)
			if ok && node.parent.idx == 0 {
				node_free(exec, info.handle)
			}
		}
	}
	for info in exec.suspended_nodes {
		if info.handle.idx != 0 {
			node, ok := hm.get(&exec.pool, info.handle)
			if ok && node.parent.idx == 0 {
				node_free(exec, info.handle)
			}
		}
	}
	delete(exec.active_nodes)
	delete(exec.next_active_nodes)
	delete(exec.suspended_nodes)
	hm.dynamic_destroy(&exec.pool)
}

node_free :: proc(exec: ^Executor, h: Handle, depth: int = 0) {
	node, ok := hm.get(&exec.pool, h)
	if !ok do return

	diagnostics_notify_destroyed(exec, node, depth)

	// Recursively free children
	curr := node.first_child
	for curr.idx != 0 {
		c_node, c_ok := hm.get(&exec.pool, curr)
		if c_ok {
			next := c_node.next_sibling
			node_free(exec, curr, depth + 1)
			curr = next
		} else {
			break
		}
	}

	// Special variant cleanup
	#partial switch &v in node.data {
	case Managed_Node:
		if v.payload != nil {
			free(v.payload, v.allocator)
		}
	case Scope_Node:
		if v.thunk != nil {
			v.thunk(v.on_exit_ptr, v.payload, .Aborted)
		}
	case Semaphore_Handler_Node:
		if v.acquired {
			semaphore_release(exec, v.sem)
			v.acquired = false
		} else {
			for i := 0; i < len(v.sem.queued); i += 1 {
				if v.sem.queued[i] == h {
					unordered_remove(&v.sem.queued, i)
					break
				}
			}
		}
	case:
		// No special cleanup
	}

	// Nullify in execution queues
	for &info in exec.active_nodes {
		if info.handle == h do info.handle = {}
	}
	for &info in exec.next_active_nodes {
		if info.handle == h do info.handle = {}
	}
	for &info in exec.suspended_nodes {
		if info.handle == h do info.handle = {}
	}

	hm.remove(&exec.pool, h)
}

enqueue_node :: proc(exec: ^Executor, h: Handle, parent: Handle = {}) {
	if h.idx == 0 do return
	node, ok := hm.get(&exec.pool, h)
	if !ok do return
	node.parent = parent
	append(&exec.active_nodes, Node_Exec_Info{handle = h, status = .None})
}

executor_step :: proc(exec: ^Executor, dt: f32) {
	exec.total_time += f64(dt)

	for i := len(exec.suspended_nodes) - 1; i >= 0; i -= 1 {
		if exec.suspended_nodes[i].status == .Aborted {
			node, ok := hm.get(&exec.pool, exec.suspended_nodes[i].handle)
			if ok && node.parent.idx == 0 {
				node_free(exec, exec.suspended_nodes[i].handle)
			}
			unordered_remove(&exec.suspended_nodes, i)
		}
	}

	i := 0
	for i < len(exec.active_nodes) {
		info := exec.active_nodes[i]
		i += 1

		if info.handle.idx == 0 || info.status == .Aborted {
			if info.handle.idx != 0 {
				node, ok := hm.get(&exec.pool, info.handle)
				if ok && node.parent.idx == 0 {
					node_free(exec, info.handle)
				}
			}
			continue
		}

		node, ok := hm.get(&exec.pool, info.handle)
		if !ok do continue

		if info.status == .None {
			info.status = node_start(exec, info.handle)
			node.status = info.status

			if info.status == .Suspended {
				append(&exec.suspended_nodes, info)
				continue
			}
			if info.status == .Completed || info.status == .Failed {
				process_node_end(exec, &info, info.status)
				continue
			}
		}

		if info.status == .Running {
			info.status = node_update(exec, info.handle, dt)
			node.status = info.status

			if info.status == .Suspended {
				append(&exec.suspended_nodes, info)
				continue
			}
			if info.status == .Completed || info.status == .Failed {
				process_node_end(exec, &info, info.status)
				continue
			}

			append(&exec.next_active_nodes, info)
		}

		if info.status == .Completed || info.status == .Failed {
			process_node_end(exec, &info, info.status)
			continue
		}
	}

	clear(&exec.active_nodes)
	for info in exec.next_active_nodes {
		append(&exec.active_nodes, info)
	}
	clear(&exec.next_active_nodes)
	exec.step_count += 1
}

process_node_end :: proc(exec: ^Executor, info: ^Node_Exec_Info, status: Status) {
	node, ok := hm.get(&exec.pool, info.handle)
	if !ok do return

	node_end(exec, info.handle, status)
	node.status = status

	if node.parent.idx != 0 {
		parent_status := node_on_child_stopped(exec, node.parent, info.handle, status)

		for j := 0; j < len(exec.active_nodes); j += 1 {
			if exec.active_nodes[j].handle == node.parent {
				exec.active_nodes[j].status = parent_status
			}
		}

		for j := len(exec.next_active_nodes) - 1; j >= 0; j -= 1 {
			if exec.next_active_nodes[j].handle == node.parent {
				if parent_status != .Running {
					p := exec.next_active_nodes[j]
					p.status = parent_status
					append(&exec.active_nodes, p)
					unordered_remove(&exec.next_active_nodes, j)
				} else {
					exec.next_active_nodes[j].status = parent_status
				}
			}
		}

		for j := len(exec.suspended_nodes) - 1; j >= 0; j -= 1 {
			if exec.suspended_nodes[j].handle == node.parent {
				if parent_status != .Suspended {
					p := exec.suspended_nodes[j]
					p.status = parent_status
					append(&exec.active_nodes, p)
					unordered_remove(&exec.suspended_nodes, j)
				} else {
					exec.suspended_nodes[j].status = parent_status
				}
			}
		}
	} else {
		node_free(exec, info.handle)
	}
}

abort_node :: proc(exec: ^Executor, h: Handle) {
	if h.idx == 0 do return
	node, ok := hm.get(&exec.pool, h)
	if !ok do return

	node_end(exec, h, .Aborted)
	node.status = .Aborted

	for &info in exec.active_nodes {
		if info.handle == h do info.status = .Aborted
	}
	for &info in exec.next_active_nodes {
		if info.handle == h do info.status = .Aborted
	}
	for &info in exec.suspended_nodes {
		if info.handle == h do info.status = .Aborted
	}
}

node_start :: proc(exec: ^Executor, h: Handle) -> Status {
	node, ok := hm.get(&exec.pool, h)
	if !ok do return .Failed

	switch &v in node.data {
	case Wait_Node:
		v.elapsed = 0
		dur := v.duration_ptr != nil ? v.duration_ptr^ : v.duration
		return dur <= 0 ? .Completed : .Running
	case Sequence_Node:
		if node.first_child.idx == 0 do return .Completed
		v.current_child = node.first_child
		enqueue_node(exec, v.current_child, h)
		return .Suspended
	case Select_Node:
		if node.first_child.idx == 0 do return .Completed
		v.current_child = node.first_child
		enqueue_node(exec, v.current_child, h)
		return .Suspended
	case Callback_Node:
		if v.thunk != nil {
			return v.thunk(v.callback_ptr, v.payload) ? .Completed : .Failed
		}
		return .Failed
	case Loop_Node:
		v.last_step = -1
		return .Running
	case Race_Node:
		if node.first_child.idx == 0 do return .Completed
		curr := node.first_child
		for curr.idx != 0 {
			enqueue_node(exec, curr, h)
			c_node, c_ok := hm.get(&exec.pool, curr)
			if !c_ok do break
			curr = c_node.next_sibling
		}
		return .Suspended
	case Sync_Node:
		if node.first_child.idx == 0 do return .Completed
		v.closed_count = 0
		v.end_status = .Completed
		curr := node.first_child
		for curr.idx != 0 {
			enqueue_node(exec, curr, h)
			c_node, c_ok := hm.get(&exec.pool, curr)
			if !c_ok do break
			curr = c_node.next_sibling
		}
		return .Suspended
	case Tween_Node:
		v.elapsed = 0
		v.output^ = v.start_val
		return v.duration <= 0 ? .Completed : .Running
	case Condition_Node:
		return .Running
	case Scope_Node:
		enqueue_node(exec, node.first_child, h)
		return .Suspended
	case Not_Node:
		enqueue_node(exec, node.first_child, h)
		return .Suspended
	case Managed_Node:
		enqueue_node(exec, node.first_child, h)
		return .Suspended
	case Catch_Node:
		enqueue_node(exec, node.first_child, h)
		return .Suspended
	case Wait_Frames_Node:
		v.elapsed_frames = 0
		return v.target_frames <= 0 ? .Completed : .Running
	case Capture_Return_Node:
		enqueue_node(exec, node.first_child, h)
		return .Suspended
	case Optional_Sequence_Node:
		if node.first_child.idx == 0 do return .Completed
		v.current_child = node.first_child
		enqueue_node(exec, v.current_child, h)
		return .Suspended
	case Semaphore_Handler_Node:
		if v.sem.current_active < v.sem.max_active {
			v.sem.current_active += 1
			v.acquired = true
			enqueue_node(exec, node.first_child, h)
			return .Suspended
		}
		append(&v.sem.queued, h)
		return .Suspended
	case Fork_Node:
		enqueue_node(exec, node.first_child, {})
		node.first_child = {}
		return .Completed
	case Wait_Forever_Node:
		return .Suspended
	case Weak_Node:
		if v.thunk != nil && !v.thunk(v.is_valid_ptr, v.payload) do return .Failed
		enqueue_node(exec, node.first_child, h)
		return .Running
	}
	return .Completed
}

node_update :: proc(exec: ^Executor, h: Handle, dt: f32) -> Status {
	node, ok := hm.get(&exec.pool, h)
	if !ok do return .Failed

	#partial switch &v in node.data {
	case Wait_Node:
		v.elapsed += dt
		dur := v.duration_ptr != nil ? v.duration_ptr^ : v.duration
		return v.elapsed >= dur ? .Completed : .Running
	case Tween_Node:
		v.elapsed += dt
		alpha := clamp(v.elapsed / v.duration, 0.0, 1.0)
		e_alpha := v.ease != nil ? v.ease(alpha) : alpha
		v.output^ = v.start_val + (v.target_val - v.start_val) * e_alpha
		return v.elapsed >= v.duration ? .Completed : .Running
	case Condition_Node:
		if v.thunk != nil {
			return v.thunk(v.condition_ptr, v.payload) ? .Completed : .Running
		}
		return .Failed
	case Loop_Node:
		if exec.step_count != v.last_step {
			v.last_step = exec.step_count
			c_node, c_ok := hm.get(&exec.pool, node.first_child)
			if c_ok && c_node.status != .Running && c_node.status != .Suspended {
				enqueue_node(exec, node.first_child, h)
			}
		}
		return .Running
	case Wait_Frames_Node:
		v.elapsed_frames += 1
		return v.elapsed_frames >= v.target_frames ? .Completed : .Running
	case Weak_Node:
		if v.thunk != nil && !v.thunk(v.is_valid_ptr, v.payload) {
			abort_node(exec, node.first_child)
			return .Failed
		}
		c_node, c_ok := hm.get(&exec.pool, node.first_child)
		if !c_ok do return .Failed
		if c_node.status == .Completed do return .Completed
		if c_node.status == .Failed do return .Failed
		return .Running
	case:
		return node.status
	}
	return node.status
}

node_end :: proc(exec: ^Executor, h: Handle, status: Status) {
	node, ok := hm.get(&exec.pool, h)
	if !ok do return

	#partial switch &v in node.data {
	case Sequence_Node:
		if status == .Aborted && v.current_child.idx != 0 {
			abort_node(exec, v.current_child)
		}
	case Select_Node:
		if status == .Aborted && v.current_child.idx != 0 {
			abort_node(exec, v.current_child)
		}
	case Optional_Sequence_Node:
		if status == .Aborted && v.current_child.idx != 0 {
			abort_node(exec, v.current_child)
		}
	case Loop_Node:
		if status == .Aborted {
			c_node, c_ok := hm.get(&exec.pool, node.first_child)
			if c_ok && (c_node.status == .None || c_node.status == .Running || c_node.status == .Suspended) {
				abort_node(exec, node.first_child)
			}
		}
	case Race_Node:
		if status == .Aborted {
			curr := node.first_child
			for curr.idx != 0 {
				child, c_ok := hm.get(&exec.pool, curr)
				if !c_ok do break
				if child.status == .None || child.status == .Running || child.status == .Suspended {
					abort_node(exec, curr)
				}
				curr = child.next_sibling
			}
		}
	case Sync_Node:
		if status == .Aborted {
			curr := node.first_child
			for curr.idx != 0 {
				child, c_ok := hm.get(&exec.pool, curr)
				if !c_ok do break
				if child.status == .None || child.status == .Running || child.status == .Suspended {
					abort_node(exec, curr)
				}
				curr = child.next_sibling
			}
		}
	case Scope_Node:
		if v.thunk != nil {
			v.thunk(v.on_exit_ptr, v.payload, status)
			v.thunk = nil
		}
		c_node, c_ok := hm.get(&exec.pool, node.first_child)
		if c_ok && status == .Aborted && (c_node.status == .Running || c_node.status == .Suspended) {
			abort_node(exec, node.first_child)
		}
	case Not_Node:
		c_node, c_ok := hm.get(&exec.pool, node.first_child)
		if c_ok && status == .Aborted && (c_node.status == .Running || c_node.status == .Suspended) {
			abort_node(exec, node.first_child)
		}
	case Managed_Node:
		c_node, c_ok := hm.get(&exec.pool, node.first_child)
		if c_ok && status == .Aborted && (c_node.status == .Running || c_node.status == .Suspended) {
			abort_node(exec, node.first_child)
		}
	case Catch_Node:
		c_node, c_ok := hm.get(&exec.pool, node.first_child)
		if c_ok && status == .Aborted && (c_node.status == .Running || c_node.status == .Suspended) {
			abort_node(exec, node.first_child)
		}
	case Capture_Return_Node:
		c_node, c_ok := hm.get(&exec.pool, node.first_child)
		if c_ok && status == .Aborted && (c_node.status == .Running || c_node.status == .Suspended) {
			abort_node(exec, node.first_child)
		}
	case Weak_Node:
		c_node, c_ok := hm.get(&exec.pool, node.first_child)
		if c_ok && status == .Aborted && (c_node.status == .Running || c_node.status == .Suspended) {
			abort_node(exec, node.first_child)
		}
	case:
		// No special handling
	}
}

node_on_child_stopped :: proc(exec: ^Executor, parent: Handle, child: Handle, status: Status) -> Status {
	p, ok := hm.get(&exec.pool, parent)
	if !ok do return .Failed

	#partial switch &v in p.data {
	case Sequence_Node:
		if status == .Failed do return .Failed
		c_node, c_ok := hm.get(&exec.pool, child)
		if !c_ok do return .Failed
		v.current_child = c_node.next_sibling
		if v.current_child.idx == 0 do return .Completed
		enqueue_node(exec, v.current_child, parent)
		return .Suspended
	case Select_Node:
		if status == .Completed do return .Completed
		c_node, c_ok := hm.get(&exec.pool, child)
		if !c_ok do return .Failed
		v.current_child = c_node.next_sibling
		if v.current_child.idx == 0 do return .Failed
		enqueue_node(exec, v.current_child, parent)
		return .Suspended
	case Optional_Sequence_Node:
		c_node, c_ok := hm.get(&exec.pool, child)
		if !c_ok do return .Failed
		v.current_child = c_node.next_sibling
		if v.current_child.idx == 0 do return .Completed
		enqueue_node(exec, v.current_child, parent)
		return .Suspended
	case Loop_Node:
		return status == .Failed ? .Completed : .Running
	case Race_Node:
		curr := p.first_child
		for curr.idx != 0 {
			if curr != child {
				other, o_ok := hm.get(&exec.pool, curr)
				if o_ok && (other.status == .None || other.status == .Running || other.status == .Suspended) {
					abort_node(exec, curr)
				}
			}
			c_node, c_ok := hm.get(&exec.pool, curr)
			if !c_ok do break
			curr = c_node.next_sibling
		}
		return status
	case Sync_Node:
		if status == .Failed do v.end_status = .Failed
		v.closed_count += 1

		total_children := 0
		curr := p.first_child
		for curr.idx != 0 {
			total_children += 1
			c_node, c_ok := hm.get(&exec.pool, curr)
			if !c_ok do break
			curr = c_node.next_sibling
		}

		if v.closed_count == total_children do return v.end_status
		return .Suspended
	case Scope_Node:
		return status
	case Not_Node:
		if status == .Completed do return .Failed
		if status == .Failed do return .Completed
		return status
	case Managed_Node:
		return status
	case Catch_Node:
		if v.output != nil do v.output^ = (status == .Completed)
		return .Completed
	case Capture_Return_Node:
		v.output^ = (status == .Completed)
		return .Completed
	case Semaphore_Handler_Node:
		if v.acquired {
			semaphore_release(exec, v.sem)
			v.acquired = false
		}
		return status
	case Weak_Node:
		return status
	case:
		return .Failed
	}
	return .Failed
}

Semaphore :: struct {
	max_active:     int,
	current_active: int,
	queued:         [dynamic]Handle,
}

semaphore_init :: proc(sem: ^Semaphore, max_active: int, allocator := context.allocator) {
	sem.max_active = max_active
	sem.current_active = 0
	sem.queued = make([dynamic]Handle, allocator)
}

semaphore_destroy :: proc(sem: ^Semaphore) {
	delete(sem.queued)
}

semaphore_release :: proc(exec: ^Executor, sem: ^Semaphore) {
	if len(sem.queued) > 0 {
		h := sem.queued[0]
		ordered_remove(&sem.queued, 0)

		node, ok := hm.get(&exec.pool, h)
		if ok {
			if v, vok := &node.data.(Semaphore_Handler_Node); vok {
				v.acquired = true
				enqueue_node(exec, node.first_child, h)
			}
		}
	} else {
		sem.current_active = max(0, sem.current_active - 1)
	}
}

node_get_debug_info :: proc(exec: ^Executor, h: Handle, buf: []byte) -> string {
	node, ok := hm.get(&exec.pool, h)
	if !ok do return ""

	#partial switch &v in node.data {
	case Wait_Node:
		dur := v.duration_ptr != nil ? v.duration_ptr^ : v.duration
		return fmt.bprintf(buf, "%.2f/%.2f s", v.elapsed, dur)
	case Sequence_Node:
		total := 0
		curr_idx := 0
		curr := node.first_child
		for curr.idx != 0 {
			total += 1
			if curr == v.current_child do curr_idx = total
			c_node, c_ok := hm.get(&exec.pool, curr)
			if !c_ok do break
			curr = c_node.next_sibling
		}
		return fmt.bprintf(buf, "%d/%d", curr_idx, total)
	case Select_Node:
		total := 0
		curr_idx := 0
		curr := node.first_child
		for curr.idx != 0 {
			total += 1
			if curr == v.current_child do curr_idx = total
			c_node, c_ok := hm.get(&exec.pool, curr)
			if !c_ok do break
			curr = c_node.next_sibling
		}
		return fmt.bprintf(buf, "%d/%d", curr_idx, total)
	case Tween_Node:
		return fmt.bprintf(buf, "%.0f%%", (v.elapsed / v.duration) * 100.0)
	case Wait_Frames_Node:
		return fmt.bprintf(buf, "%d/%d frames", v.elapsed_frames, v.target_frames)
	case Optional_Sequence_Node:
		total := 0
		curr_idx := 0
		curr := node.first_child
		for curr.idx != 0 {
			total += 1
			if curr == v.current_child do curr_idx = total
			c_node, c_ok := hm.get(&exec.pool, curr)
			if !c_ok do break
			curr = c_node.next_sibling
		}
		return fmt.bprintf(buf, "%d/%d", curr_idx, total)
	case Sync_Node:
		total := 0
		curr := node.first_child
		for curr.idx != 0 {
			total += 1
			c_node, c_ok := hm.get(&exec.pool, curr)
			if !c_ok do break
			curr = c_node.next_sibling
		}
		return fmt.bprintf(buf, "%d/%d", v.closed_count, total)
	case Wait_Forever_Node:
		return "Forever"
	case:
		// No special debug info
	}
	return ""
}

diagnostics_notify_destroyed :: proc(exec: ^Executor, node: ^Node, depth: int) {
	if exec.debugger == nil || !exec.debugger.enabled || node == nil do return

	db := exec.debugger

	info_buf: [128]byte
	info_str := node_get_debug_info(exec, node.handle, info_buf[:])

	f := Fading_Node {
		name      = node.name,
		user_name = node.user_name,
		status    = node.status,
		end_time  = exec.total_time,
		depth     = depth,
		info      = strings.clone(info_str, db.allocator),
	}

	append(&db.fading_nodes, f)
}

// API Helpers

_add_node :: proc(exec: ^Executor, name: string, data: Node_Data) -> Handle {
	h, _ := hm.add(&exec.pool, Node{ name = name, data = data, handle = {} })
	node, _ := hm.get(&exec.pool, h)
	node.handle = h
	node.start_time = exec.total_time
	return h
}

_link_children :: proc(exec: ^Executor, parent: Handle, children: []Handle) {
	if len(children) == 0 do return
	p_node, p_ok := hm.get(&exec.pool, parent)
	if !p_ok do return

	last_valid: ^Node = nil

	for h in children {
		c_node, c_ok := hm.get(&exec.pool, h)
		if !c_ok do continue

		c_node.parent = parent
		if last_valid == nil {
			p_node.first_child = h
		} else {
			last_valid.next_sibling = h
		}
		last_valid = c_node
	}
}

// API

seq :: proc(exec: ^Executor, nodes: ..Handle) -> Handle {
	h := _add_node(exec, "Sequence", Sequence_Node{})
	_link_children(exec, h, nodes)
	return h
}

select :: proc(exec: ^Executor, nodes: ..Handle) -> Handle {
	h := _add_node(exec, "Select", Select_Node{})
	_link_children(exec, h, nodes)
	return h
}

sync :: proc(exec: ^Executor, nodes: ..Handle) -> Handle {
	h := _add_node(exec, "Sync", Sync_Node{})
	_link_children(exec, h, nodes)
	return h
}

race :: proc(exec: ^Executor, nodes: ..Handle) -> Handle {
	h := _add_node(exec, "Race", Race_Node{})
	_link_children(exec, h, nodes)
	return h
}

wait :: proc(exec: ^Executor, duration: f32) -> Handle {
	h := _add_node(exec, "Wait", Wait_Node{duration = duration})
	if node, ok := hm.get(&exec.pool, h); ok do node.show_age = true
	return h
}

wait_ptr :: proc(exec: ^Executor, duration: ^f32) -> Handle {
	h := _add_node(exec, "WaitPtr", Wait_Node{duration_ptr = duration})
	if node, ok := hm.get(&exec.pool, h); ok do node.show_age = true
	return h
}


run_typed :: proc(exec: ^Executor, callback: proc(payload: ^$T) -> bool, payload: ^T = nil) -> Handle {
	thunk :: proc(cb: rawptr, p: rawptr) -> bool {
		return (proc(payload: ^T) -> bool)(cb)((^T)(p))
	}
	return _add_node(exec, "Callback", Callback_Node{callback_ptr = rawptr(callback), payload = rawptr(payload), thunk = thunk})
}

run_nil :: proc(exec: ^Executor, callback: proc() -> bool) -> Handle {
	thunk :: proc(cb: rawptr, p: rawptr) -> bool {
		return (proc() -> bool)(cb)()
	}
	return _add_node(exec, "Callback", Callback_Node{callback_ptr = rawptr(callback), thunk = thunk})
}

run :: proc {run_nil, run_typed}
check :: run

loop :: proc(exec: ^Executor, child: Handle) -> Handle {
	h := _add_node(exec, "Loop", Loop_Node{})
	if node, ok := hm.get(&exec.pool, h); ok do node.show_age = true
	_link_children(exec, h, {child})
	return h
}

tween :: proc(exec: ^Executor, start, target, duration: f32, output: ^f32, ease: Ease_Proc = nil) -> Handle {
	h := _add_node(exec, "Tween", Tween_Node{start_val = start, target_val = target, duration = duration, output = output, ease = ease})
	if node, ok := hm.get(&exec.pool, h); ok do node.show_age = true
	return h
}

wait_until_typed :: proc(exec: ^Executor, condition: proc(payload: ^$T) -> bool, payload: ^T = nil) -> Handle {
	thunk :: proc(cb: rawptr, p: rawptr) -> bool {
		return (proc(payload: ^T) -> bool)(cb)((^T)(p))
	}
	h := _add_node(exec, "WaitUntil", Condition_Node{condition_ptr = rawptr(condition), payload = rawptr(payload), thunk = thunk})
	if node, ok := hm.get(&exec.pool, h); ok do node.show_age = true
	return h
}

wait_until_nil :: proc(exec: ^Executor, condition: proc() -> bool) -> Handle {
	thunk :: proc(cb: rawptr, p: rawptr) -> bool {
		return (proc() -> bool)(cb)()
	}
	h := _add_node(exec, "WaitUntil", Condition_Node{condition_ptr = rawptr(condition), thunk = thunk})
	if node, ok := hm.get(&exec.pool, h); ok do node.show_age = true
	return h
}

wait_until :: proc {wait_until_typed, wait_until_nil}

scope_typed :: proc(exec: ^Executor, child: Handle, on_exit: proc(payload: ^$T, status: Status), payload: ^T = nil) -> Handle {
	thunk :: proc(cb: rawptr, p: rawptr, status: Status) {
		(proc(payload: ^T, status: Status))(cb)((^T)(p), status)
	}
	h := _add_node(exec, "Scope", Scope_Node{on_exit_ptr = rawptr(on_exit), payload = rawptr(payload), thunk = thunk})
	_link_children(exec, h, {child})
	return h
}

scope_nil :: proc(exec: ^Executor, child: Handle, on_exit: proc(status: Status)) -> Handle {
	thunk :: proc(cb: rawptr, p: rawptr, status: Status) {
		(proc(status: Status))(cb)(status)
	}
	h := _add_node(exec, "Scope", Scope_Node{on_exit_ptr = rawptr(on_exit), thunk = thunk})
	_link_children(exec, h, {child})
	return h
}

scope :: proc {scope_typed, scope_nil}

not :: proc(exec: ^Executor, child: Handle) -> Handle {
	h := _add_node(exec, "Not", Not_Node{})
	_link_children(exec, h, {child})
	return h
}

catch :: proc(exec: ^Executor, child: Handle) -> Handle {
	h := _add_node(exec, "Catch", Catch_Node{})
	_link_children(exec, h, {child})
	return h
}

managed :: proc(exec: ^Executor, child: Handle, payload: rawptr, allocator := context.allocator) -> Handle {
	h := _add_node(exec, "Managed", Managed_Node{payload = payload, allocator = allocator})
	_link_children(exec, h, {child})
	return h
}

wait_frames :: proc(exec: ^Executor, frames: int) -> Handle {
	h := _add_node(exec, "WaitFrames", Wait_Frames_Node{target_frames = frames})
	if node, ok := hm.get(&exec.pool, h); ok do node.show_age = true
	return h
}

capture_return :: proc(exec: ^Executor, child: Handle, output_ptr: ^bool) -> Handle {
	h := _add_node(exec, "CaptureReturn", Capture_Return_Node{output = output_ptr})
	_link_children(exec, h, {child})
	return h
}

optional_seq :: proc(exec: ^Executor, nodes: ..Handle) -> Handle {
	h := _add_node(exec, "OptionalSequence", Optional_Sequence_Node{})
	_link_children(exec, h, nodes)
	return h
}

semaphore_scope :: proc(exec: ^Executor, sem: ^Semaphore, child: Handle) -> Handle {
	h := _add_node(exec, "Semaphore", Semaphore_Handler_Node{sem = sem})
	_link_children(exec, h, {child})
	return h
}

fork :: proc(exec: ^Executor, child: Handle) -> Handle {
	h := _add_node(exec, "Fork", Fork_Node{})
	_link_children(exec, h, {child})
	return h
}

wait_forever :: proc(exec: ^Executor) -> Handle {
	return _add_node(exec, "WaitForever", Wait_Forever_Node{})
}

weak_typed :: proc(exec: ^Executor, child: Handle, is_valid: proc(payload: ^$T) -> bool, payload: ^T = nil) -> Handle {
	thunk :: proc(cb: rawptr, p: rawptr) -> bool {
		return (proc(payload: ^T) -> bool)(cb)((^T)(p))
	}
	h := _add_node(exec, "Weak", Weak_Node{is_valid_ptr = rawptr(is_valid), payload = rawptr(payload), thunk = thunk})
	_link_children(exec, h, {child})
	return h
}

weak_nil :: proc(exec: ^Executor, child: Handle, is_valid: proc() -> bool) -> Handle {
	thunk :: proc(cb: rawptr, p: rawptr) -> bool {
		return (proc() -> bool)(cb)()
	}
	h := _add_node(exec, "Weak", Weak_Node{is_valid_ptr = rawptr(is_valid), thunk = thunk})
	_link_children(exec, h, {child})
	return h
}

weak :: proc {weak_typed, weak_nil}

named :: proc(exec: ^Executor, h: Handle, name: string) -> Handle {
	if h.idx != 0 {
		node, ok := hm.get(&exec.pool, h)
		if ok do node.user_name = name
	}
	return h
}
