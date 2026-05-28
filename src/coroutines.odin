package main

import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"

Status :: enum {
	None,
	Completed,
	Failed,
	Running,
	Suspended,
	Aborted,
}

Node :: struct {
	using base: ^Node_VTable,
	parent:     ^Node,
	status:     Status,
	name:       string,
	dbg:        ^Node_Debug_Info,
}

Node_VTable :: struct {
	start:            proc(self: ^Node, exec: ^Executor) -> Status,
	update:           proc(self: ^Node, exec: ^Executor, dt: f32) -> Status,
	end:              proc(self: ^Node, exec: ^Executor, status: Status),
	on_child_stopped: proc(self: ^Node, exec: ^Executor, status: Status, child: ^Node) -> Status,
	get_debug_info:   proc(self: ^Node, buf: []byte) -> string,
	destroy:          proc(self: ^Node, exec: ^Executor),
}

Node_Exec_Info :: struct {
	node:   ^Node,
	parent: ^Node,
	status: Status,
}

Node_Debug_Info :: struct {
	user_name:  string,
	info_buf:   [64]byte,
	info_len:   int,
	start_time: f64,
	is_leaf:    bool,
	is_scope:   bool,
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

diagnostics_init_node :: proc(exec: ^Executor, node: ^Node, user_name: string = "", is_leaf := false, is_scope := false) {
	if exec.debugger == nil || !exec.debugger.enabled || node == nil do return

	if node.dbg == nil {
		node.dbg = new(Node_Debug_Info, exec.allocator)
	}

	node.dbg.user_name = user_name
	node.dbg.is_leaf = is_leaf
	node.dbg.is_scope = is_scope
	node.dbg.start_time = exec.total_time
	node.dbg.info_len = 0
}

diagnostics_update_node :: proc(exec: ^Executor, node: ^Node) {
	if exec.debugger == nil || !exec.debugger.enabled || node == nil || node.dbg == nil do return

	if node.get_debug_info != nil {
		info := node.get_debug_info(node, node.dbg.info_buf[:])
		node.dbg.info_len = len(info)
	}
}

diagnostics_notify_destroyed :: proc(exec: ^Executor, node: ^Node, depth: int) {
	if exec.debugger == nil || !exec.debugger.enabled || node == nil || node.dbg == nil {
		if node != nil && node.dbg != nil {
			free(node.dbg, exec.allocator)
			node.dbg = nil
		}
		return
	}

	db := exec.debugger
	f := Fading_Node {
		name      = node.name,
		user_name = node.dbg.user_name,
		status    = node.status,
		end_time  = exec.total_time,
		depth     = depth,
	}

	if node.dbg.info_len > 0 {
		f.info = strings.clone(string(node.dbg.info_buf[:node.dbg.info_len]), db.allocator)
	}

	append(&db.fading_nodes, f)
	free(node.dbg, exec.allocator)
	node.dbg = nil
}

Executor :: struct {
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
	exec.active_nodes = make([dynamic]Node_Exec_Info, allocator)
	exec.next_active_nodes = make([dynamic]Node_Exec_Info, allocator)
	exec.suspended_nodes = make([dynamic]Node_Exec_Info, allocator)
	exec.step_count = 0
	exec.total_time = 0
	exec.debugger = nil
}

executor_destroy :: proc(exec: ^Executor) {
	for info in exec.active_nodes {
		if info.parent == nil && info.node != nil {
			destroy_node(info.node, exec)
		}
	}
	for info in exec.next_active_nodes {
		if info.parent == nil && info.node != nil {
			destroy_node(info.node, exec)
		}
	}
	for info in exec.suspended_nodes {
		if info.parent == nil && info.node != nil {
			destroy_node(info.node, exec)
		}
	}
	delete(exec.active_nodes)
	delete(exec.next_active_nodes)
	delete(exec.suspended_nodes)
}

executor_shrink :: proc(exec: ^Executor) {
	shrink(&exec.active_nodes)
	shrink(&exec.next_active_nodes)
	shrink(&exec.suspended_nodes)
}

destroy_node :: proc(node: ^Node, exec: ^Executor, depth: int = 0) {
	if node != nil {
		diagnostics_notify_destroyed(exec, node, depth)

		for &info in exec.active_nodes {
			if info.node == node do info.node = nil
			if info.parent == node do info.parent = nil
		}
		for &info in exec.next_active_nodes {
			if info.node == node do info.node = nil
			if info.parent == node do info.parent = nil
		}
		for &info in exec.suspended_nodes {
			if info.node == node do info.node = nil
			if info.parent == node do info.parent = nil
		}
		node.destroy(node, exec)
	}
}

enqueue_node :: proc(exec: ^Executor, node: ^Node, parent: ^Node = nil) {
	node.parent = parent
	if exec.debugger != nil && exec.debugger.enabled && node.dbg == nil {
		node.dbg = new(Node_Debug_Info, exec.allocator)
		node.dbg.start_time = exec.total_time
	}
	append(&exec.active_nodes, Node_Exec_Info{node = node, parent = parent, status = .None})
}

executor_step :: proc(exec: ^Executor, dt: f32) {
	exec.total_time += f64(dt)

	for i := len(exec.suspended_nodes) - 1; i >= 0; i -= 1 {
		if exec.suspended_nodes[i].status == .Aborted {
			if exec.suspended_nodes[i].parent == nil {
				destroy_node(exec.suspended_nodes[i].node, exec)
			}
			unordered_remove(&exec.suspended_nodes, i)
		}
	}

	i := 0
	for i < len(exec.active_nodes) {
		info := exec.active_nodes[i]
		i += 1

		if info.node == nil || info.status == .Aborted {
			if info.node != nil && info.parent == nil {
				destroy_node(info.node, exec)
			}
			continue
		}

		if info.status == .None {
			info.status = info.node.start(info.node, exec)
			info.node.status = info.status
			diagnostics_update_node(exec, info.node)

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
			info.status = info.node.update(info.node, exec, dt)
			info.node.status = info.status
			diagnostics_update_node(exec, info.node)

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
	info.node.end(info.node, exec, status)
	info.node.status = status
	diagnostics_update_node(exec, info.node)

	if info.parent != nil {
		parent_status := info.parent.on_child_stopped(info.parent, exec, status, info.node)

		for j := 0; j < len(exec.active_nodes); j += 1 {
			if exec.active_nodes[j].node == info.parent {
				exec.active_nodes[j].status = parent_status
				diagnostics_update_node(exec, info.parent)
			}
		}

		for j := len(exec.next_active_nodes) - 1; j >= 0; j -= 1 {
			if exec.next_active_nodes[j].node == info.parent {
				if parent_status != .Running {
					p := exec.next_active_nodes[j]
					p.status = parent_status
					append(&exec.active_nodes, p)
					unordered_remove(&exec.next_active_nodes, j)
				} else {
					exec.next_active_nodes[j].status = parent_status
				}
				diagnostics_update_node(exec, info.parent)
			}
		}

		for j := len(exec.suspended_nodes) - 1; j >= 0; j -= 1 {
			if exec.suspended_nodes[j].node == info.parent {
				if parent_status != .Suspended {
					p := exec.suspended_nodes[j]
					p.status = parent_status
					append(&exec.active_nodes, p)
					unordered_remove(&exec.suspended_nodes, j)
				} else {
					exec.suspended_nodes[j].status = parent_status
				}
				diagnostics_update_node(exec, info.parent)
			}
		}
	} else {
		destroy_node(info.node, exec)
	}
}

abort_node :: proc(exec: ^Executor, node: ^Node) {
	if node == nil do return
	node.end(node, exec, .Aborted)
	node.status = .Aborted
	diagnostics_update_node(exec, node)

	for &info in exec.active_nodes {
		if info.node == node {
			info.status = .Aborted
		}
	}
	for &info in exec.next_active_nodes {
		if info.node == node {
			info.status = .Aborted
		}
	}
	for &info in exec.suspended_nodes {
		if info.node == node {
			info.status = .Aborted
		}
	}
}

Wait_Node :: struct {
	using node:        Node,
	duration, elapsed: f32,
	duration_ptr:      ^f32,
}

wait_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		w := (^Wait_Node)(self); w.elapsed = 0
		dur := w.duration_ptr != nil ? w.duration_ptr^ : w.duration
		return dur <= 0 ? .Completed : .Running
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {
		w := (^Wait_Node)(self); w.elapsed += dt
		dur := w.duration_ptr != nil ? w.duration_ptr^ : w.duration
		return w.elapsed >= dur ? .Completed : .Running
	},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {},
	on_child_stopped = proc(
		self: ^Node,
		exec: ^Executor,
		status: Status,
		child: ^Node,
	) -> Status {return .Failed},
	get_debug_info = proc(self: ^Node, buf: []byte) -> string {
		w := (^Wait_Node)(self)
		dur := w.duration_ptr != nil ? w.duration_ptr^ : w.duration
		return fmt.bprintf(buf, "%.1fs / %.1fs", w.elapsed, dur)
	},
	destroy = proc(self: ^Node, exec: ^Executor) {free(self, exec.allocator)},
}

Sequence_Node :: struct {
	using node:  Node,
	children:    [dynamic]^Node,
	child_index: int,
}

seq_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		s := (^Sequence_Node)(self); if len(s.children) == 0 do return .Completed
		s.child_index = 0; enqueue_node(exec, s.children[s.child_index], s); return .Suspended
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {return .Suspended},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {
		s := (^Sequence_Node)(self); if status == .Aborted && s.child_index < len(s.children) {
			abort_node(exec, s.children[s.child_index])
		}
	},
	on_child_stopped = proc(self: ^Node, exec: ^Executor, status: Status, child: ^Node) -> Status {
		s := (^Sequence_Node)(self); if status == .Failed do return .Failed
		s.child_index += 1; if s.child_index >= len(s.children) do return .Completed
		enqueue_node(exec, s.children[s.child_index], s); return .Suspended
	},
	get_debug_info = proc(self: ^Node, buf: []byte) -> string {
		s := (^Sequence_Node)(self)
		return fmt.bprintf(buf, "%d / %d", s.child_index + 1, len(s.children))
	},
	destroy = proc(self: ^Node, exec: ^Executor) {
		s := (^Sequence_Node)(self); for c in s.children do destroy_node(c, exec)
		delete(s.children); free(s, exec.allocator)
	},
}

Select_Node :: struct {
	using node:  Node,
	children:    [dynamic]^Node,
	child_index: int,
}

select_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		s := (^Select_Node)(self); if len(s.children) == 0 do return .Completed
		s.child_index = 0; enqueue_node(exec, s.children[s.child_index], s); return .Suspended
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {return .Suspended},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {
		s := (^Select_Node)(self); if status == .Aborted && s.child_index < len(s.children) {
			abort_node(exec, s.children[s.child_index])
		}
	},
	on_child_stopped = proc(self: ^Node, exec: ^Executor, status: Status, child: ^Node) -> Status {
		s := (^Select_Node)(self); if status == .Completed do return .Completed
		s.child_index += 1; if s.child_index >= len(s.children) do return .Failed
		enqueue_node(exec, s.children[s.child_index], s); return .Suspended
	},
	get_debug_info = proc(self: ^Node, buf: []byte) -> string {
		s := (^Select_Node)(self)
		return fmt.bprintf(buf, "%d / %d", s.child_index + 1, len(s.children))
	},
	destroy = proc(self: ^Node, exec: ^Executor) {
		s := (^Select_Node)(self); for c in s.children do destroy_node(c, exec)
		delete(s.children); free(s, exec.allocator)
	},
}

Callback_Proc :: proc(data: rawptr) -> bool

Callback_Node :: struct {
	using node: Node,
	callback:   Callback_Proc,
	payload:    rawptr,
}

callback_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		c := (^Callback_Node)(self); return c.callback(c.payload) ? .Completed : .Failed
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {return .Completed},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {},
	on_child_stopped = proc(
		self: ^Node,
		exec: ^Executor,
		status: Status,
		child: ^Node,
	) -> Status {return .Failed},
	get_debug_info = proc(self: ^Node, buf: []byte) -> string {return ""},
	destroy = proc(self: ^Node, exec: ^Executor) {free(self, exec.allocator)},
}

Loop_Node :: struct {
	using node: Node,
	child:      ^Node,
	last_step:  int,
}

loop_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		l := (^Loop_Node)(self); l.last_step = -1; return .Running
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {
		l := (^Loop_Node)(self)
		if exec.step_count != l.last_step {
			l.last_step = exec.step_count
			if l.child.status != .Running && l.child.status != .Suspended {
				enqueue_node(exec, l.child, l)
			}
		}
		return .Running
	},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {
		l := (^Loop_Node)(self)
		if status == .Aborted &&
		   (l.child.status == .None ||
				   l.child.status == .Running ||
				   l.child.status == .Suspended) {
			abort_node(exec, l.child)
		}
	},
	on_child_stopped = proc(self: ^Node, exec: ^Executor, status: Status, child: ^Node) -> Status {
		return status == .Failed ? .Completed : .Running
	},
	get_debug_info = proc(self: ^Node, buf: []byte) -> string {return ""},
	destroy = proc(self: ^Node, exec: ^Executor) {
		l := (^Loop_Node)(self); destroy_node(l.child, exec); free(l, exec.allocator)
	},
}

Race_Node :: struct {
	using node: Node,
	children:   [dynamic]^Node,
}

race_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		r := (^Race_Node)(self); if len(r.children) == 0 do return .Completed
		for c in r.children do enqueue_node(exec, c, r)
		return .Suspended
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {return .Suspended},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {
		r := (^Race_Node)(self)
		if status == .Aborted {
			for c in r.children {
				if c.status == .None || c.status == .Running || c.status == .Suspended do abort_node(exec, c)
			}
		}
	},
	on_child_stopped = proc(self: ^Node, exec: ^Executor, status: Status, child: ^Node) -> Status {
		r := (^Race_Node)(self)
		for other in r.children {
			if other != child &&
			   (other.status == .None || other.status == .Running || other.status == .Suspended) {
				abort_node(exec, other)
			}
		}
		return status
	},
	get_debug_info = proc(self: ^Node, buf: []byte) -> string {
		r := (^Race_Node)(self)
		return fmt.bprintf(buf, "%d children", len(r.children))
	},
	destroy = proc(self: ^Node, exec: ^Executor) {
		r := (^Race_Node)(self); for c in r.children do destroy_node(c, exec)
		delete(r.children); free(r, exec.allocator)
	},
}

Sync_Node :: struct {
	using node:   Node,
	children:     [dynamic]^Node,
	closed_count: int,
	end_status:   Status,
}

sync_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		s := (^Sync_Node)(self); if len(s.children) == 0 do return .Completed
		s.closed_count = 0; s.end_status = .Completed
		for c in s.children do enqueue_node(exec, c, s)
		return .Suspended
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {return .Suspended},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {
		s := (^Sync_Node)(self)
		if status == .Aborted {
			for c in s.children {
				if c.status == .None || c.status == .Running || c.status == .Suspended do abort_node(exec, c)
			}
		}
	},
	on_child_stopped = proc(self: ^Node, exec: ^Executor, status: Status, child: ^Node) -> Status {
		s := (^Sync_Node)(self)
		if status == .Failed do s.end_status = .Failed
		s.closed_count += 1
		if s.closed_count == len(s.children) {
			return s.end_status
		}
		return .Suspended
	},
	get_debug_info = proc(self: ^Node, buf: []byte) -> string {
		s := (^Sync_Node)(self)
		return fmt.bprintf(buf, "%d / %d closed", s.closed_count, len(s.children))
	},
	destroy = proc(self: ^Node, exec: ^Executor) {
		s := (^Sync_Node)(self); for c in s.children do destroy_node(c, exec)
		delete(s.children); free(s, exec.allocator)
	},
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
	using node:                               Node,
	start_val, target_val, duration, elapsed: f32,
	output:                                   ^f32,
	ease:                                     Ease_Proc,
}

tween_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		t := (^Tween_Node)(self); t.elapsed = 0; t.output^ = t.start_val
		return t.duration <= 0 ? .Completed : .Running
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {
		t := (^Tween_Node)(self); t.elapsed += dt
		alpha := clamp(t.elapsed / t.duration, 0.0, 1.0)
		e_alpha := t.ease != nil ? t.ease(alpha) : alpha
		t.output^ = t.start_val + (t.target_val - t.start_val) * e_alpha
		return t.elapsed >= t.duration ? .Completed : .Running
	},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {},
	on_child_stopped = proc(
		self: ^Node,
		exec: ^Executor,
		status: Status,
		child: ^Node,
	) -> Status {return .Failed},
	get_debug_info = proc(self: ^Node, buf: []byte) -> string {
		t := (^Tween_Node)(self)
		return fmt.bprintf(buf, "%.2f (%.1fs / %.1fs)", t.output^, t.elapsed, t.duration)
	},
	destroy = proc(self: ^Node, exec: ^Executor) {free(self, exec.allocator)},
}

Condition_Node :: struct {
	using node: Node,
	condition:  proc(_: rawptr) -> bool,
	payload:    rawptr,
}

condition_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {return .Running},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {
		c := (^Condition_Node)(self); return c.condition(c.payload) ? .Completed : .Running
	},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {},
	on_child_stopped = proc(
		self: ^Node,
		exec: ^Executor,
		status: Status,
		child: ^Node,
	) -> Status {return .Failed},
	get_debug_info = proc(self: ^Node, buf: []byte) -> string {return "Waiting..."},
	destroy = proc(self: ^Node, exec: ^Executor) {free(self, exec.allocator)},
}

Scope_Node :: struct {
	using node: Node,
	child:      ^Node,
	on_exit:    proc(data: rawptr, status: Status),
	payload:    rawptr,
}

scope_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		s := (^Scope_Node)(self); enqueue_node(exec, s.child, s); return .Suspended
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {return .Suspended},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {
		s := (^Scope_Node)(self)
		// run once
		if s.on_exit != nil {
			s.on_exit(s.payload, status)
			s.on_exit = nil
		}
		if status == .Aborted && (s.child.status == .Running || s.child.status == .Suspended) {
			abort_node(exec, s.child)
		}
	},
	on_child_stopped = proc(
		self: ^Node,
		exec: ^Executor,
		status: Status,
		child: ^Node,
	) -> Status {return status},
	get_debug_info = proc(self: ^Node, buf: []byte) -> string {return ""},
	destroy = proc(self: ^Node, exec: ^Executor) {
		s := (^Scope_Node)(self)
		if s.on_exit != nil {
			s.on_exit(s.payload, .Aborted)
			s.on_exit = nil
		}
		destroy_node(s.child, exec)
		free(s, exec.allocator)
	},
}

Not_Node :: struct {
	using node: Node,
	child:      ^Node,
}

not_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		n := (^Not_Node)(self); enqueue_node(exec, n.child, n); return .Suspended
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {return .Suspended},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {
		n := (^Not_Node)(
			self,
		); if status == .Aborted && (n.child.status == .Running || n.child.status == .Suspended) {
			abort_node(exec, n.child)
		}
	},
	on_child_stopped = proc(self: ^Node, exec: ^Executor, status: Status, child: ^Node) -> Status {
		if status == .Completed do return .Failed
		if status == .Failed do return .Completed
		return status
	},
	get_debug_info = proc(self: ^Node, buf: []byte) -> string {return ""},
	destroy = proc(self: ^Node, exec: ^Executor) {
		n := (^Not_Node)(self); destroy_node(n.child, exec); free(n, exec.allocator)
	},
}

Managed_Node :: struct {
	using node: Node,
	child:      ^Node,
	payload:    rawptr,
	allocator:  mem.Allocator,
}

managed_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		m := (^Managed_Node)(self); enqueue_node(exec, m.child, m); return .Suspended
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {return .Suspended},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {
		m := (^Managed_Node)(self)
		if status == .Aborted && (m.child.status == .Running || m.child.status == .Suspended) {
			abort_node(exec, m.child)
		}
	},
	on_child_stopped = proc(
		self: ^Node,
		exec: ^Executor,
		status: Status,
		child: ^Node,
	) -> Status {return status},
	get_debug_info = proc(self: ^Node, buf: []byte) -> string {return ""},
	destroy = proc(self: ^Node, exec: ^Executor) {
		m := (^Managed_Node)(self)
		if m.payload != nil {
			free(m.payload, m.allocator)
			m.payload = nil // double free in complex abort cycles?
		}
		destroy_node(m.child, exec)
		free(m, exec.allocator)
	},
}

Catch_Node :: struct {
	using node: Node,
	child:      ^Node,
}

catch_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		c := (^Catch_Node)(self); enqueue_node(exec, c.child, c); return .Suspended
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {return .Suspended},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {
		c := (^Catch_Node)(
			self,
		); if status == .Aborted && (c.child.status == .Running || c.child.status == .Suspended) {
			abort_node(exec, c.child)
		}
	},
	on_child_stopped = proc(
		self: ^Node,
		exec: ^Executor,
		status: Status,
		child: ^Node,
	) -> Status {return .Completed},
	get_debug_info = proc(self: ^Node, buf: []byte) -> string {return ""},
	destroy = proc(self: ^Node, exec: ^Executor) {
		c := (^Catch_Node)(self); destroy_node(c.child, exec); free(c, exec.allocator)
	},
}

Wait_Frames_Node :: struct {
	using node:     Node,
	target_frames:  int,
	elapsed_frames: int,
}

wait_frames_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		w := (^Wait_Frames_Node)(self)
		w.elapsed_frames = 0
		return w.target_frames <= 0 ? .Completed : .Running
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {
		w := (^Wait_Frames_Node)(self)
		w.elapsed_frames += 1
		return w.elapsed_frames >= w.target_frames ? .Completed : .Running
	},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {},
	on_child_stopped = proc(
		self: ^Node,
		exec: ^Executor,
		status: Status,
		child: ^Node,
	) -> Status {return .Failed},
	get_debug_info = proc(self: ^Node, buf: []byte) -> string {
		w := (^Wait_Frames_Node)(self)
		return fmt.bprintf(buf, "%d / %d frames", w.elapsed_frames, w.target_frames)
	},
	destroy = proc(self: ^Node, exec: ^Executor) {free(self, exec.allocator)},
}

Capture_Return_Node :: struct {
	using node: Node,
	child:      ^Node,
	output:     ^bool,
}

capture_return_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		c := (^Capture_Return_Node)(self)
		enqueue_node(exec, c.child, c)
		return .Suspended
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {return .Suspended},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {
		c := (^Capture_Return_Node)(self)
		if status == .Aborted && (c.child.status == .Running || c.child.status == .Suspended) {
			abort_node(exec, c.child)
		}
	},
	on_child_stopped = proc(self: ^Node, exec: ^Executor, status: Status, child: ^Node) -> Status {
		c := (^Capture_Return_Node)(self)
		c.output^ = (status == .Completed)
		return .Completed
	},
	get_debug_info = proc(self: ^Node, buf: []byte) -> string {return ""},
	destroy = proc(self: ^Node, exec: ^Executor) {
		c := (^Capture_Return_Node)(self)
		destroy_node(c.child, exec)
		free(c, exec.allocator)
	},
}

Optional_Sequence_Node :: struct {
	using node:  Node,
	children:    [dynamic]^Node,
	child_index: int,
}

optional_seq_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		s := (^Optional_Sequence_Node)(self)
		if len(s.children) == 0 do return .Completed
		s.child_index = 0
		enqueue_node(exec, s.children[s.child_index], s)
		return .Suspended
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {return .Suspended},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {
		s := (^Optional_Sequence_Node)(self)
		if status == .Aborted && s.child_index < len(s.children) {
			abort_node(exec, s.children[s.child_index])
		}
	},
	on_child_stopped = proc(self: ^Node, exec: ^Executor, status: Status, child: ^Node) -> Status {
		s := (^Optional_Sequence_Node)(self)
		s.child_index += 1
		if s.child_index >= len(s.children) do return .Completed
		enqueue_node(exec, s.children[s.child_index], s)
		return .Suspended
	},
	get_debug_info = proc(self: ^Node, buf: []byte) -> string {
		s := (^Optional_Sequence_Node)(self)
		return fmt.bprintf(buf, "%d / %d", s.child_index + 1, len(s.children))
	},
	destroy = proc(self: ^Node, exec: ^Executor) {
		s := (^Optional_Sequence_Node)(self)
		for c in s.children do destroy_node(c, exec)
		delete(s.children); free(s, exec.allocator)
	},
}

Semaphore :: struct {
	max_active:     int,
	current_active: int,
	queued:         [dynamic]^Semaphore_Handler_Node,
}

Semaphore_Handler_Node :: struct {
	using node: Node,
	child:      ^Node,
	sem:        ^Semaphore,
	acquired:   bool,
	exec:       ^Executor,
}

semaphore_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		s := (^Semaphore_Handler_Node)(self)
		s.exec = exec

		if s.sem.current_active < s.sem.max_active {
			s.sem.current_active += 1
			s.acquired = true
			enqueue_node(exec, s.child, s)
			return .Suspended
		}

		append(&s.sem.queued, s)
		return .Suspended
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {return .Suspended},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {
		s := (^Semaphore_Handler_Node)(self)
		if status == .Aborted {
			if s.acquired {
				semaphore_release(s.sem)
				s.acquired = false
			} else {
				for i := 0; i < len(s.sem.queued); i += 1 {
					if s.sem.queued[i] == s {
						unordered_remove(&s.sem.queued, i)
						break
					}
				}
			}
			if s.child.status == .None ||
			   s.child.status == .Running ||
			   s.child.status == .Suspended {
				abort_node(exec, s.child)
			}
		}
	},
	on_child_stopped = proc(self: ^Node, exec: ^Executor, status: Status, child: ^Node) -> Status {
		s := (^Semaphore_Handler_Node)(self)
		if s.acquired {
			semaphore_release(s.sem)
			s.acquired = false
		}
		return status
	},
	get_debug_info = proc(self: ^Node, buf: []byte) -> string {
		s := (^Semaphore_Handler_Node)(self)
		return s.acquired ? "Acquired" : "Waiting for Slot"
	},
	destroy = proc(self: ^Node, exec: ^Executor) {
		s := (^Semaphore_Handler_Node)(self)

		if s.acquired {
			semaphore_release(s.sem)
			s.acquired = false
		} else {
			for i := 0; i < len(s.sem.queued); i += 1 {
				if s.sem.queued[i] == s {
					unordered_remove(&s.sem.queued, i)
					break
				}
			}
		}

		destroy_node(s.child, exec)
		free(s, exec.allocator)
	},
}

semaphore_init :: proc(sem: ^Semaphore, max_active: int, allocator := context.allocator) {
	sem.max_active = max_active
	sem.current_active = 0
	sem.queued = make([dynamic]^Semaphore_Handler_Node, allocator)
}

semaphore_destroy :: proc(sem: ^Semaphore) {
	delete(sem.queued)
}

semaphore_release :: proc(sem: ^Semaphore) {
	if len(sem.queued) > 0 {
		next := sem.queued[0]
		ordered_remove(&sem.queued, 0)
		next.acquired = true
		enqueue_node(next.exec, next.child, next)
	} else {
		sem.current_active = max(0, sem.current_active - 1)
	}
}

Fork_Node :: struct {
	using node: Node,
	child:      ^Node,
}

fork_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		f := (^Fork_Node)(self)
		enqueue_node(exec, f.child, nil)
		return .Completed
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {return .Completed},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {},
	on_child_stopped = proc(
		self: ^Node,
		exec: ^Executor,
		status: Status,
		child: ^Node,
	) -> Status {return .Failed},
	get_debug_info = proc(self: ^Node, buf: []byte) -> string {return "Forking..."},
	destroy = proc(self: ^Node, exec: ^Executor) {free(self, exec.allocator)},
}

Wait_Forever_Node :: struct {
	using node: Node,
}

wait_forever_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {return .Suspended},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {return .Suspended},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {},
	on_child_stopped = proc(
		self: ^Node,
		exec: ^Executor,
		status: Status,
		child: ^Node,
	) -> Status {return .Failed},
	get_debug_info = proc(self: ^Node, buf: []byte) -> string {return "Forever"},
	destroy = proc(self: ^Node, exec: ^Executor) {free(self, exec.allocator)},
}

Weak_Node :: struct {
	using node: Node,
	child:      ^Node,
	is_valid:   proc(_: rawptr) -> bool,
	payload:    rawptr,
}

weak_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		w := (^Weak_Node)(self)
		if !w.is_valid(w.payload) do return .Failed
		enqueue_node(exec, w.child, w)
		return .Running
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {
		w := (^Weak_Node)(self)
		if !w.is_valid(w.payload) {
			abort_node(exec, w.child)
			return .Failed
		}
		if w.child.status == .Completed do return .Completed
		if w.child.status == .Failed do return .Failed
		return .Running
	},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {
		w := (^Weak_Node)(self)
		if status == .Aborted && (w.child.status == .Running || w.child.status == .Suspended) {
			abort_node(exec, w.child)
		}
	},
	on_child_stopped = proc(
		self: ^Node,
		exec: ^Executor,
		status: Status,
		child: ^Node,
	) -> Status {
		return status
	},
	get_debug_info = proc(self: ^Node, buf: []byte) -> string {return "Guarding..."},
	destroy = proc(self: ^Node, exec: ^Executor) {
		w := (^Weak_Node)(self); destroy_node(w.child, exec); free(self, exec.allocator)
	},
}


// api

seq :: proc(nodes: ..^Node, allocator := context.allocator) -> ^Node {
	node := new(Sequence_Node, allocator); node.base = &seq_vtable
	node.children = make([dynamic]^Node, allocator)
	for n in nodes do append(&node.children, n)
	node.name = "Sequence"; return node
}

select :: proc(nodes: ..^Node, allocator := context.allocator) -> ^Node {
	node := new(Select_Node, allocator); node.base = &select_vtable
	node.children = make([dynamic]^Node, allocator)
	for n in nodes do append(&node.children, n)
	node.name = "Select"; return node
}

sync :: proc(nodes: ..^Node, allocator := context.allocator) -> ^Node {
	node := new(Sync_Node, allocator); node.base = &sync_vtable
	node.children = make([dynamic]^Node, allocator)
	for n in nodes do append(&node.children, n)
	node.name = "Sync"; return node
}

race :: proc(nodes: ..^Node, allocator := context.allocator) -> ^Node {
	node := new(Race_Node, allocator); node.base = &race_vtable
	node.children = make([dynamic]^Node, allocator)
	for n in nodes do append(&node.children, n)
	node.name = "Race"; return node
}

wait :: proc(duration: f32, allocator := context.allocator) -> ^Node {
	node := new(Wait_Node, allocator); node.base = &wait_vtable; node.duration = duration
	node.name = "Wait"
	return node
}

wait_ptr :: proc(duration: ^f32, allocator := context.allocator) -> ^Node {
	node := new(Wait_Node, allocator); node.base = &wait_vtable; node.duration_ptr = duration
	node.name = "WaitPtr"
	return node
}

run :: proc(
	callback: Callback_Proc,
	payload: rawptr = nil,
	allocator := context.allocator,
) -> ^Node {
	node := new(Callback_Node, allocator); node.base = &callback_vtable
	node.callback = callback; node.payload = payload; node.name = "Callback"
	return node
}

loop :: proc(child: ^Node, allocator := context.allocator) -> ^Node {
	node := new(Loop_Node, allocator); node.base = &loop_vtable; node.child = child
	node.name = "Loop"; return node
}

tween :: proc(
	start, target, duration: f32,
	output: ^f32,
	ease: Ease_Proc = nil,
	allocator := context.allocator,
) -> ^Node {
	node := new(Tween_Node, allocator); node.base = &tween_vtable
	node.start_val =
		start; node.target_val = target; node.duration = duration; node.output = output; node.ease = ease
	node.name = "Tween"
	return node
}

wait_until :: proc(
	condition: proc(_: rawptr) -> bool,
	payload: rawptr = nil,
	allocator := context.allocator,
) -> ^Node {
	node := new(Condition_Node, allocator); node.base = &condition_vtable
	node.condition = condition; node.payload = payload; node.name = "WaitUntil"
	return node
}

check :: proc(
	condition: proc(_: rawptr) -> bool,
	payload: rawptr = nil,
	allocator := context.allocator,
) -> ^Node {
	node := new(Callback_Node, allocator); node.base = &callback_vtable
	node.callback = condition; node.payload = payload; node.name = "Check"
	return node
}

scope :: proc(
	child: ^Node,
	on_exit: proc(_: rawptr, _: Status),
	payload: rawptr = nil,
	allocator := context.allocator,
) -> ^Node {
	node := new(Scope_Node, allocator); node.base = &scope_vtable
	node.child = child; node.on_exit = on_exit; node.payload = payload
	node.name = "Scope"
	diagnostics_init_node_auto(node, is_scope = true)
	return node
}

not :: proc(child: ^Node, allocator := context.allocator) -> ^Node {
	node := new(Not_Node, allocator); node.base = &not_vtable; node.child = child
	node.name = "Not"; return node
}

catch :: proc(child: ^Node, allocator := context.allocator) -> ^Node {
	node := new(Catch_Node, allocator); node.base = &catch_vtable; node.child = child
	node.name = "Catch"; return node
}

managed :: proc(child: ^Node, payload: rawptr, allocator := context.allocator) -> ^Node {
	node := new(Managed_Node, allocator); node.base = &managed_vtable
	node.child = child; node.payload = payload; node.allocator = allocator
	node.name = "Managed"
	diagnostics_init_node_auto(node, is_scope = true)
	return node
}

managed_run :: proc(
	callback: Callback_Proc,
	payload: rawptr,
	allocator := context.allocator,
) -> ^Node {
	child := run(callback, payload, allocator)
	return managed(child, payload, allocator)
}

wait_frames :: proc(frames: int, allocator := context.allocator) -> ^Node {
	node := new(Wait_Frames_Node, allocator)
	node.base = &wait_frames_vtable
	node.target_frames = frames
	node.name = "WaitFrames"
	return node
}

capture_return :: proc(child: ^Node, output_ptr: ^bool, allocator := context.allocator) -> ^Node {
	node := new(Capture_Return_Node, allocator)
	node.base = &capture_return_vtable
	node.child = child
	node.output = output_ptr
	node.name = "CaptureReturn"
	return node
}

optional_seq :: proc(nodes: ..^Node, allocator := context.allocator) -> ^Node {
	node := new(Optional_Sequence_Node, allocator)
	node.base = &optional_seq_vtable
	node.children = make([dynamic]^Node, allocator)
	for n in nodes do append(&node.children, n)
	node.name = "OptionalSequence"
	return node
}

loop_seq :: proc(nodes: ..^Node, allocator := context.allocator) -> ^Node {
	return loop(seq(..nodes, allocator = allocator), allocator = allocator)
}

semaphore_scope :: proc(sem: ^Semaphore, child: ^Node, allocator := context.allocator) -> ^Node {
	node := new(Semaphore_Handler_Node, allocator)
	node.base = &semaphore_vtable
	node.child = child
	node.sem = sem
	node.acquired = false
	node.name = "Semaphore"
	diagnostics_init_node_auto(node, is_scope = true)
	return node
}

nop :: proc(allocator := context.allocator) -> ^Node {
	return run(proc(_: rawptr) -> bool {return true}, nil, allocator)
}

error_node :: proc(allocator := context.allocator) -> ^Node {
	return run(proc(_: rawptr) -> bool {return false}, nil, allocator)
}

fork :: proc(child: ^Node, allocator := context.allocator) -> ^Node {
	node := new(Fork_Node, allocator); node.base = &fork_vtable; node.child = child
	node.name = "Fork"; return node
}

wait_forever :: proc(allocator := context.allocator) -> ^Node {
	node := new(Wait_Forever_Node, allocator); node.base = &wait_forever_vtable
	node.name = "WaitForever"
	return node
}

weak :: proc(
	child: ^Node,
	is_valid: proc(_: rawptr) -> bool,
	payload: rawptr,
	allocator := context.allocator,
) -> ^Node {
	node := new(Weak_Node, allocator); node.base = &weak_vtable
	node.child = child; node.is_valid = is_valid; node.payload = payload
	node.name = "Weak"; return node
}

named :: proc(node: ^Node, name: string) -> ^Node {
	if node != nil {
		if node.dbg != nil {
			node.dbg.user_name = name
		} else {
			node.dbg = new(Node_Debug_Info, context.allocator)
			node.dbg.user_name = name
		}
	}
	return node
}

// Internal helper for scopes
diagnostics_init_node_auto :: proc(node: ^Node, is_scope: bool) {
	if node.dbg == nil {
		node.dbg = new(Node_Debug_Info, context.allocator)
	}
	node.dbg.is_scope = is_scope
}
