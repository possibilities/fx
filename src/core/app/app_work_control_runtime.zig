const std = @import("std");
const work_control = @import("../control/work_control.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const input_approval_runtime = @import("input_approval_runtime.zig");
const input_interrupt_runtime = @import("input_interrupt_runtime.zig");
const input_question_runtime = @import("input_question_runtime.zig");

pub fn Runtime(comptime App: type) type {
    return struct {
        const ApprovalRuntime = input_approval_runtime.ApprovalRuntime(App);
        const InterruptRuntime = input_interrupt_runtime.InterruptRuntime(App);
        const QuestionRuntime = input_question_runtime.QuestionRuntime(App);

        pub fn collect(app: *App) !void {
            const pending = app.work_control.takePending() orelse return;
            const response = dispatch(app, &pending.request) catch |err|
                try work_control.encodeError(
                    std.heap.c_allocator,
                    app.work_control.instanceId(),
                    pending.request.request_id,
                    applicationErrorCode(err),
                    applicationErrorMessage(err),
                );
            app.work_control.complete(pending, response);
        }

        fn dispatch(app: *App, request: *const work_control.Request) ![]u8 {
            return switch (request.method) {
                .snapshot => encodeSnapshot(app, request.request_id),
                .queue => admit(app, request, .queue),
                .steer => admit(app, request, .steer),
                .interrupt => interrupt(app, request.request_id),
                .update => update(app, request),
                .delete => delete(app, request),
                .resume_queue => resumeQueue(app, request.request_id),
            };
        }

        fn encodeSnapshot(app: *App, request_id: []const u8) ![]u8 {
            var snapshot = try takeSnapshot(app);
            defer snapshot.deinit(std.heap.c_allocator);
            return work_control.encodeSnapshotResponse(
                std.heap.c_allocator,
                app.work_control.instanceId(),
                request_id,
                snapshot,
            );
        }

        fn admit(
            app: *App,
            request: *const work_control.Request,
            intent: App.PromptSubmitIntent,
        ) ![]u8 {
            const admission = try app.admitWorkControlPrompt(request.text.?, intent);
            _ = app.worker.resumeQueue();
            var snapshot = try takeSnapshot(app);
            defer snapshot.deinit(std.heap.c_allocator);
            return work_control.encodeAdmissionResponse(
                std.heap.c_allocator,
                app.work_control.instanceId(),
                request.request_id,
                admission,
                snapshot,
            );
        }

        fn interrupt(app: *App, request_id: []const u8) ![]u8 {
            if (app.approval_prompt.isActive()) {
                if (approvalTargetsSubagent(app)) return error.SubagentControlUnsupported;
                try ApprovalRuntime.cancelApprovalOperation(app);
            } else if (app.question_prompt.isActive()) {
                try QuestionRuntime.cancelQuestionPrompt(app);
            } else if (app.stream.active) {
                try InterruptRuntime.cancelActiveOperation(app);
            } else {
                return error.NoActiveWork;
            }
            _ = app.worker.pauseQueue();
            var snapshot = try takeSnapshot(app);
            defer snapshot.deinit(std.heap.c_allocator);
            return work_control.encodeMutationResponse(
                std.heap.c_allocator,
                app.work_control.instanceId(),
                request_id,
                snapshot,
            );
        }

        fn update(app: *App, request: *const work_control.Request) ![]u8 {
            switch (try app.worker.updateQueuedPromptText(
                std.heap.c_allocator,
                request.turn_id.?,
                request.text.?,
            )) {
                .updated => {},
                .not_found => return error.QueuedWorkNotFound,
                .carries_non_text_state => return error.QueuedWorkNotTextOnly,
            }
            return encodeSnapshot(app, request.request_id);
        }

        fn delete(app: *App, request: *const work_control.Request) ![]u8 {
            if (!app.worker.removeQueuedPrompt(
                std.heap.c_allocator,
                request.turn_id.?,
                app.input_runtime.kill_ring.images.items,
            )) return error.QueuedWorkNotFound;
            if (app.worker.queuedPromptCount() == 0) _ = app.worker.resumeQueue();
            return encodeSnapshot(app, request.request_id);
        }

        fn resumeQueue(app: *App, request_id: []const u8) ![]u8 {
            if (!app.worker.resumeQueue()) {
                return error.QueueNotPaused;
            }
            return encodeSnapshot(app, request_id);
        }

        fn takeSnapshot(app: *App) !worker_runtime.WorkSnapshot {
            return app.worker.snapshotWork(std.heap.c_allocator, .{
                .max_entries = work_control.max_snapshot_entries,
                .max_text_bytes = work_control.max_snapshot_text_bytes,
            });
        }

        fn approvalTargetsSubagent(app: *App) bool {
            if (comptime !@hasField(App, "subagents")) return false;
            if (comptime !@hasDecl(@TypeOf(app.subagents), "mainApprovalBinding")) return false;
            const request = app.approval_prompt.request orelse return false;
            return app.subagents.mainApprovalBinding(request.id) != null;
        }
    };
}

fn applicationErrorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.NoActiveWork => "no_active_work",
        error.SubagentControlUnsupported => "subagent_control_unsupported",
        error.QueuedWorkNotFound => "queued_work_not_found",
        error.QueuedWorkNotTextOnly => "queued_work_not_text_only",
        error.QueueNotPaused => "queue_not_paused",
        error.WorkSnapshotEntryLimitExceeded,
        error.WorkSnapshotTextLimitExceeded,
        error.WorkControlResponseTooLarge,
        => "snapshot_too_large",
        error.WorkerStopped => "worker_stopped",
        error.TurnFinalizationDeliveryFailed => "turn_finalization_failed",
        else => "work_control_failed",
    };
}

fn applicationErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.NoActiveWork => "the main Agent has no interruptible work",
        error.SubagentControlUnsupported => "work control does not target subagents",
        error.QueuedWorkNotFound => "queued work no longer exists",
        error.QueuedWorkNotTextOnly => "queued work carries images or skills",
        error.QueueNotPaused => "the work queue is not paused",
        error.WorkSnapshotEntryLimitExceeded,
        error.WorkSnapshotTextLimitExceeded,
        error.WorkControlResponseTooLarge,
        => "the authoritative work snapshot exceeds its bound",
        error.WorkerStopped => "the Fx worker has stopped",
        error.TurnFinalizationDeliveryFailed => "the active turn could not be finalized",
        else => "Fx could not apply the work-control request",
    };
}
