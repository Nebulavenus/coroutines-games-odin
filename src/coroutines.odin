package main

import "core:fmt"
import "core:mem"

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
	parent: ^Node,
	status: Status,
	name: string,
}

Node_VTable :: struct {
	start: proc(self: ^Node, exec: ^Executor) -> Status,
	update: proc(self: ^Node, exec: ^Executor, dt: f32) -> Status,
	end: proc(self: ^Node, exec: ^Executor, status: Status),
	on_child_stopped: proc(self: ^Node, exec: ^Executor, status: Status, child: ^Node) -> Status,
	destroy: proc(self: ^Node),
}

Node_Exec_Info :: struct {
	node: ^Node,
	parent: ^Node,
	status: Status,
}

Executor :: struct {
	active_nodes: [dynamic]Node_Exec_Info,
	suspended_nodes: [dynamic]Node_Exec_Info,
	step_count: int,
}

executor_init :: proc(exec: ^Executor) {
	exec.active_nodes = make([dynamic]Node_Exec_Info)
	exec.suspended_nodes = make([dynamic]Node_Exec_Info)
	exec.step_count = 0
}

executor_destroy :: proc(exec: ^Executor) {
	for info in exec.active_nodes {
		if info.parent == nil && info.node != nil {
			destroy_node(info.node)
		}
	}
	for info in exec.suspended_nodes {
		if info.parent == nil && info.node != nil {
			destroy_node(info.node)
		}
	}
	delete(exec.active_nodes)
	delete(exec.suspended_nodes)
}

destroy_node :: proc(node: ^Node) {
	if node != nil {
		node.destroy(node)
	}
}

enqueue_node :: proc(exec: ^Executor, node: ^Node, parent: ^Node = nil) {
	node.parent = parent
	append(&exec.active_nodes, Node_Exec_Info {
		node = node,
		parent = parent,
		status = .None,
	})
}

executor_step :: proc(exec: ^Executor, dt: f32) {
	// filter out completed or aborted suspended nodes
	for i := len(exec.suspended_nodes) - 1; i >= 0; i -= 1 {
		if exec.suspended_nodes[i].status == .Aborted {
			unordered_remove(&exec.suspended_nodes, i)
		}
	}

	// start of the frame active nodes
	initial_active_count := len(exec.active_nodes)
	for i := 0; i < initial_active_count; i += 1 {
		if len(exec.active_nodes) == 0 do break

		info := pop(&exec.active_nodes)

		if info.status == .Aborted {
			continue
		}

		if info.status == .None {
			info.status = info.node.start(info.node, exec)
			info.node.status = info.status

			if info.status == .Suspended {
				append(&exec.suspended_nodes, info)
				continue
			}
			if info.status == .Completed || info.status == .Failed {
				process_node_end(exec, &info, info.status)
				continue
			}
		}

		// update running node
		info.status = info.node.update(info.node, exec, dt)
		info.node.status = info.status

		if info.status == .Suspended {
			append(&exec.suspended_nodes, info)
			continue
		}
		if info.status == .Completed || info.status == .Failed {
			process_node_end(exec, &info, info.status)
			continue
		}

		// requeue running node for next frame
		inject_at(&exec.active_nodes, 0, info)
	}
	exec.step_count += 1
}

process_node_end :: proc(exec: ^Executor, info: ^Node_Exec_Info, status: Status) {
	info.node.end(info.node, exec, status)

	if info.parent != nil {
		parent_status := info.parent.on_child_stopped(info.parent, exec, status, info.node)
		if parent_status != .Suspended {
			// find parent in active or suspended nodes, to propagate status
			for &active_info in exec.active_nodes {
				if active_info.node == info.parent {
					active_info.status = parent_status
				}
			}
			for &suspended_info in exec.suspended_nodes {
				if suspended_info.node == info.parent {
					suspended_info.status = parent_status
					// move parent back to active if it woke up
					if parent_status != .Suspended {
						append(&exec.active_nodes, suspended_info)
						suspended_info.status = .Aborted // lazy deletion
					}
				}
			}
		}
	} else {
		// root node completed, clean it up
		destroy_node(info.node)
	}
}

abort_node :: proc(exec: ^Executor, node: ^Node) {
	if node == nil do return

	node.end(node, exec, .Aborted)
	node.status = .Aborted

	// mark others
	for &info in exec.active_nodes {
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
	using node: Node,
	duration: f32,
	elapsed: f32,
}

wait_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		wait := (^Wait_Node)(self)
		wait.elapsed = 0.0
		return wait.duration <= 0.0 ? .Completed : .Running
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {
		wait := (^Wait_Node)(self)
		wait.elapsed += dt
		return wait.elapsed >= wait.duration ? .Completed : .Running
	},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {},
	on_child_stopped = proc(self: ^Node, exec: ^Executor, status: Status, child: ^Node) -> Status {
		return .Failed
	},
	destroy = proc(self: ^Node) {
		free(self)
	},
}

new_wait_node :: proc(duration: f32) -> ^Node {
	node := new(Wait_Node)
	node.base = &wait_vtable
	node.duration = duration
	node.name = "Wait"
	return node
}

Sequence_Node :: struct {
	using node: Node,
	children: [dynamic]^Node,
	child_index: int,
}

seq_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		seq := (^Sequence_Node)(self)
		if len(seq.children) == 0 do return .Completed
		seq.child_index = 0
		enqueue_node(exec, seq.children[seq.child_index], seq)
		return .Suspended
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {
		return .Suspended
	},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {
		seq := (^Sequence_Node)(self)
		if status == .Aborted {
			// abort current active child branch
			if seq.child_index < len(seq.children) {
				abort_node(exec, seq.children[seq.child_index])
			}
		}
	},
	on_child_stopped = proc(self: ^Node, exec: ^Executor, status: Status, child: ^Node) -> Status {
		seq := (^Sequence_Node)(self)
		if status == .Failed {
			return .Failed
		}
		seq.child_index += 1
		if seq.child_index >= len(seq.children) {
			return .Completed
		}
		enqueue_node(exec, seq.children[seq.child_index], seq)
		return .Suspended
	},
	destroy = proc(self: ^Node) {
		seq := (^Sequence_Node)(self)
		for child in seq.children {
			destroy_node(child)
		}
		delete(seq.children)
		free(seq)
	},
}

new_sequence_node :: proc(children: []^Node) -> ^Node {
	node := new(Sequence_Node)
	node.base = &seq_vtable
	node.children = make([dynamic]^Node)
	for child in children {
		append(&node.children, child)
	}
	node.name = "Sequence"
	return node
}

Callback_Proc :: proc(data: rawptr) -> bool

Callback_Node :: struct {
	using node: Node,
	callback: Callback_Proc,
	payload: rawptr,
}

callback_vtable := Node_VTable {
	start = proc(self: ^Node, exec: ^Executor) -> Status {
		cb := (^Callback_Node)(self)
		ok := cb.callback(cb.payload)
		return ok ? .Completed : .Failed
	},
	update = proc(self: ^Node, exec: ^Executor, dt: f32) -> Status {
		return .Completed
	},
	end = proc(self: ^Node, exec: ^Executor, status: Status) {},
	on_child_stopped = proc(self: ^Node, exec: ^Executor, status: Status, child: ^Node) -> Status {
		return .Failed
	},
	destroy = proc(self: ^Node) {
		free(self)
	},
}

new_callback_node :: proc(callback: Callback_Proc, payload: rawptr = nil) -> ^Node {
	node := new(Callback_Node)
	node.base = &callback_vtable
	node.callback = callback
	node.payload = payload
	node.name = "Callback"
	return node
}
