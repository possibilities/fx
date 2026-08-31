const std = @import("std");
const io_mod = @import("../shared/io.zig");
const protocol = @import("launch_admission_final.zig");

const Allocator = std.mem.Allocator;

pub const ledger_dir_name = "launch-admission-final";
pub const records_dir_name = "records";
pub const lock_file_name = "ledger.lock";
pub const record_schema_id = "fx.launch-admission-final-ledger";
pub const record_schema_version: u16 = 1;
pub const max_record_bytes: usize = 64 * 1024;
pub const lock_deadline_ms: u64 = 5_000;

pub const Error = error{
    AdmissionConflict,
    AdmissionCancelled,
    AcknowledgementConflict,
    CorrelationMismatch,
    DurableRecordInvalid,
    FinalReceiptConflict,
    FinalReceiptMissing,
    LaunchNotFound,
    LaunchStateUnsafe,
} || protocol.Error || std.Io.Dir.OpenError || std.Io.Dir.MakeError ||
    std.Io.Dir.StatError || std.Io.Dir.OpenFileError || std.Io.File.ReadError ||
    std.Io.File.StatError || std.Io.File.SetPermissionsError ||
    std.Io.File.LockError || std.Io.File.UnlockError || std.Io.File.CloseError ||
    std.Io.File.SyncError || std.Io.Dir.RenameError || std.Io.Dir.DeleteFileError ||
    std.Io.Dir.SetPermissionsError || std.Io.Dir.SyncError || Allocator.Error;

pub const Options = struct {
    durable_ops: io_mod.DurableOps = .{},
    lock_ops: io_mod.LockOps = .{},
    lock_timeout_ms: u64 = lock_deadline_ms,
};

pub const Record = struct {
    active_conversation_id: []const u8,
    admission_key: []const u8,
    conversation_name: []const u8,
    decision: ?protocol.AdmissionDecision = null,
    directory: []const u8,
    effort: ?[]const u8 = null,
    final_acknowledgement_id: ?[]const u8 = null,
    final_receipt: ?protocol.FinalReceipt = null,
    initial_conversation_id: []const u8,
    initial_work_digest: []const u8,
    launch_digest: []const u8,
    launch_id: []const u8,
    launch_receipt_id: []const u8,
    model: ?[]const u8 = null,
    remaining_launch_controls_digest: []const u8,
    request_id: []const u8,
    resume_target: protocol.Resume,
    state_root: []const u8,

    pub fn launchRequest(self: Record) protocol.LaunchRequest {
        return .{
            .admission_key = self.admission_key,
            .conversation_name = self.conversation_name,
            .directory = self.directory,
            .effort = self.effort,
            .initial_work_digest = self.initial_work_digest,
            .launch_digest = self.launch_digest,
            .launch_id = self.launch_id,
            .model = self.model,
            .remaining_launch_controls_digest = self.remaining_launch_controls_digest,
            .request_id = self.request_id,
            .resume_target = self.resume_target,
            .state_root = self.state_root,
        };
    }

    pub fn launchReceipt(self: Record, request_id: []const u8) protocol.LaunchReceipt {
        return .{
            .admission_key = self.admission_key,
            .launch_digest = self.launch_digest,
            .launch_id = self.launch_id,
            .receipt_id = self.launch_receipt_id,
            .request_id = request_id,
        };
    }
};

const ResumeWire = struct {
    conversation_id: ?[]const u8 = null,
    mode: []const u8,
};

const DecisionWire = struct {
    cancellation_request_id: ?[]const u8 = null,
    disposition: ?[]const u8 = null,
    kind: []const u8,
    receipt_digest: []const u8,
    receipt_id: []const u8,
    turn_id: ?[]const u8 = null,
};

const OutcomeWire = struct {
    code: ?u8 = null,
    kind: []const u8,
    message: ?[]const u8 = null,
    signal: ?u8 = null,
};

const FinalWire = struct {
    conversation_id: []const u8,
    observed_at: []const u8,
    outcome: OutcomeWire,
    receipt_digest: []const u8,
    receipt_id: []const u8,
};

const RecordWire = struct {
    active_conversation_id: []const u8,
    admission_key: []const u8,
    conversation_name: []const u8,
    decision: ?DecisionWire = null,
    directory: []const u8,
    effort: ?[]const u8 = null,
    final_acknowledgement_id: ?[]const u8 = null,
    final_receipt: ?FinalWire = null,
    initial_conversation_id: []const u8,
    initial_work_digest: []const u8,
    launch_digest: []const u8,
    launch_id: []const u8,
    launch_receipt_id: []const u8,
    model: ?[]const u8 = null,
    remaining_launch_controls_digest: []const u8,
    request_id: []const u8,
    @"resume": ResumeWire,
    schema_id: []const u8,
    schema_version: u16,
    state_root: []const u8,
};

pub const Loaded = struct {
    parsed: std.json.Parsed(RecordWire),
    record: Record,

    pub fn deinit(self: *Loaded) void {
        self.parsed.deinit();
        self.* = undefined;
    }
};

pub const AdmissionMutation = struct {
    loaded: Loaded,
    newly_decided: bool,

    pub fn deinit(self: *AdmissionMutation) void {
        self.loaded.deinit();
        self.* = undefined;
    }
};

pub const LaunchMutation = struct {
    loaded: Loaded,
    newly_accepted: bool,

    pub fn deinit(self: *LaunchMutation) void {
        self.loaded.deinit();
        self.* = undefined;
    }
};

pub const Ledger = struct {
    alloc: Allocator,
    state_root: []u8,
    control_dir: io_mod.VerifiedDir,
    records_dir: io_mod.VerifiedDir,
    options: Options,

    pub fn open(alloc: Allocator, state_root: []const u8, options: Options) !Ledger {
        if (!std.fs.path.isAbsolute(state_root) or std.mem.eql(u8, state_root, "/")) {
            return error.LaunchStateUnsafe;
        }
        const owned_root = try alloc.dupe(u8, state_root);
        errdefer alloc.free(owned_root);
        var selected = io_mod.VerifiedDir{
            .dir = io_mod.openDirAbsoluteNoFollow(state_root, .{ .iterate = true }) catch
                return error.LaunchStateUnsafe,
        };
        defer selected.close();
        const stat = try selected.dir.stat(io_mod.getIo());
        if (stat.kind != .directory) return error.LaunchStateUnsafe;

        var fx_root = try io_mod.openOrCreateVerifiedPrivateDir(&selected, ".fx");
        defer fx_root.close();
        var control = try io_mod.openOrCreateVerifiedPrivateDir(&fx_root, ledger_dir_name);
        errdefer control.close();
        const records = try io_mod.openOrCreateVerifiedPrivateDir(&control, records_dir_name);
        return .{
            .alloc = alloc,
            .state_root = owned_root,
            .control_dir = control,
            .records_dir = records,
            .options = options,
        };
    }

    pub fn deinit(self: *Ledger) void {
        self.records_dir.close();
        self.control_dir.close();
        self.alloc.free(self.state_root);
        self.* = undefined;
    }

    pub fn acceptLaunch(
        self: *Ledger,
        request: protocol.LaunchRequest,
        initial_conversation_id: []const u8,
    ) !Loaded {
        var mutation = try self.acceptLaunchObserved(request, initial_conversation_id);
        const loaded = mutation.loaded;
        mutation = undefined;
        return loaded;
    }

    pub fn acceptLaunchObserved(
        self: *Ledger,
        request: protocol.LaunchRequest,
        initial_conversation_id: []const u8,
    ) !LaunchMutation {
        try protocol.validateLaunchRequest(self.alloc, request);
        if (!try protocol.launchDigestMatches(self.alloc, request)) {
            return error.InvalidMessage;
        }
        if (!std.mem.eql(u8, request.state_root, self.state_root)) return error.CorrelationMismatch;
        try protocol.validateConversationId(initial_conversation_id);
        switch (request.resume_target) {
            .fresh => {},
            .exact => |requested_id| if (!std.mem.eql(u8, requested_id, initial_conversation_id)) {
                return error.CorrelationMismatch;
            },
        }
        var lock = try self.acquireLock();
        defer lock.release();

        if (try self.loadUnlocked(request.admission_key)) |loaded_value| {
            var loaded = loaded_value;
            errdefer loaded.deinit();
            try requireCorrelation(loaded.record, request.admission_key, request.launch_digest, request.launch_id);
            return .{ .loaded = loaded, .newly_accepted = false };
        }

        var receipt_id_buffer: [48]u8 = undefined;
        const receipt_id = try deterministicReceiptId(&receipt_id_buffer, "launch-receipt", request.launch_digest);
        const record: Record = .{
            .active_conversation_id = initial_conversation_id,
            .admission_key = request.admission_key,
            .conversation_name = request.conversation_name,
            .directory = request.directory,
            .effort = request.effort,
            .initial_conversation_id = initial_conversation_id,
            .initial_work_digest = request.initial_work_digest,
            .launch_digest = request.launch_digest,
            .launch_id = request.launch_id,
            .launch_receipt_id = receipt_id,
            .model = request.model,
            .remaining_launch_controls_digest = request.remaining_launch_controls_digest,
            .request_id = request.request_id,
            .resume_target = request.resume_target,
            .state_root = request.state_root,
        };
        try self.persistUnlocked(record);
        return .{
            .loaded = (try self.loadUnlocked(request.admission_key)) orelse
                return error.DurableRecordInvalid,
            .newly_accepted = true,
        };
    }

    pub fn load(self: *Ledger, admission_key: []const u8) !?Loaded {
        try protocol.validateSafeToken(admission_key);
        var lock = try self.acquireLock();
        defer lock.release();
        return self.loadUnlocked(admission_key);
    }

    pub fn cancel(self: *Ledger, request: protocol.AdmissionCancelRequest) !AdmissionMutation {
        try protocol.validateCorrelation(request.admission_key, request.launch_digest, request.launch_id);
        try protocol.validateSafeToken(request.request_id);
        var lock = try self.acquireLock();
        defer lock.release();
        var loaded = (try self.loadUnlocked(request.admission_key)) orelse return error.LaunchNotFound;
        defer loaded.deinit();
        try requireCorrelation(loaded.record, request.admission_key, request.launch_digest, request.launch_id);
        if (loaded.record.decision != null) {
            return .{ .loaded = (try self.loadUnlocked(request.admission_key)).?, .newly_decided = false };
        }

        var receipt_id_buffer: [48]u8 = undefined;
        const receipt_id = try deterministicReceiptId(&receipt_id_buffer, "admission-receipt", request.launch_digest);
        var digest_storage: [64]u8 = [_]u8{'0'} ** 64;
        loaded.record.decision = .{
            .admission_key = loaded.record.admission_key,
            .decision = .{ .cancelled_before_start = .{ .cancellation_request_id = request.request_id } },
            .launch_digest = loaded.record.launch_digest,
            .launch_id = loaded.record.launch_id,
            .receipt_digest = &digest_storage,
            .receipt_id = receipt_id,
        };
        digest_storage = try protocol.computeReceiptDigest(self.alloc, .{ .admission_decision = loaded.record.decision.? });
        try self.persistUnlocked(loaded.record);
        return .{ .loaded = (try self.loadUnlocked(request.admission_key)).?, .newly_decided = true };
    }

    pub fn admit(
        self: *Ledger,
        admission_key: []const u8,
        launch_digest: []const u8,
        launch_id: []const u8,
        turn_id: u64,
        disposition: protocol.Disposition,
    ) !AdmissionMutation {
        if (turn_id == 0) return error.InvalidMessage;
        try protocol.validateCorrelation(admission_key, launch_digest, launch_id);
        var lock = try self.acquireLock();
        defer lock.release();
        var loaded = (try self.loadUnlocked(admission_key)) orelse return error.LaunchNotFound;
        defer loaded.deinit();
        try requireCorrelation(loaded.record, admission_key, launch_digest, launch_id);
        if (loaded.record.decision) |existing| {
            switch (existing.decision) {
                .cancelled_before_start => return error.AdmissionCancelled,
                .admitted => return .{ .loaded = (try self.loadUnlocked(admission_key)).?, .newly_decided = false },
            }
        }

        var receipt_id_buffer: [48]u8 = undefined;
        const receipt_id = try deterministicReceiptId(&receipt_id_buffer, "admission-receipt", launch_digest);
        var digest_storage: [64]u8 = [_]u8{'0'} ** 64;
        loaded.record.decision = .{
            .admission_key = loaded.record.admission_key,
            .decision = .{ .admitted = .{ .disposition = disposition, .turn_id = turn_id } },
            .launch_digest = loaded.record.launch_digest,
            .launch_id = loaded.record.launch_id,
            .receipt_digest = &digest_storage,
            .receipt_id = receipt_id,
        };
        digest_storage = try protocol.computeReceiptDigest(self.alloc, .{ .admission_decision = loaded.record.decision.? });
        try self.persistUnlocked(loaded.record);
        return .{ .loaded = (try self.loadUnlocked(admission_key)).?, .newly_decided = true };
    }

    pub fn updateActiveConversation(
        self: *Ledger,
        admission_key: []const u8,
        launch_digest: []const u8,
        launch_id: []const u8,
        conversation_id: []const u8,
    ) !Loaded {
        try protocol.validateConversationId(conversation_id);
        var lock = try self.acquireLock();
        defer lock.release();
        var loaded = (try self.loadUnlocked(admission_key)) orelse return error.LaunchNotFound;
        defer loaded.deinit();
        try requireCorrelation(loaded.record, admission_key, launch_digest, launch_id);
        if (loaded.record.final_receipt != null) return error.FinalReceiptConflict;
        if (!std.mem.eql(u8, loaded.record.active_conversation_id, conversation_id)) {
            loaded.record.active_conversation_id = conversation_id;
            try self.persistUnlocked(loaded.record);
        }
        return (try self.loadUnlocked(admission_key)).?;
    }

    pub fn recordFinal(
        self: *Ledger,
        admission_key: []const u8,
        launch_digest: []const u8,
        launch_id: []const u8,
        outcome: protocol.Outcome,
        observed_at: []const u8,
    ) !Loaded {
        try protocol.validateTimestamp(observed_at);
        switch (outcome) {
            .exec_failed => |message| try protocol.validateBoundedText(message, 1024),
            .signalled => |signal| if (signal == 0) return error.InvalidMessage,
            .exited => {},
        }
        var lock = try self.acquireLock();
        defer lock.release();
        var loaded = (try self.loadUnlocked(admission_key)) orelse return error.LaunchNotFound;
        defer loaded.deinit();
        try requireCorrelation(loaded.record, admission_key, launch_digest, launch_id);
        if (loaded.record.final_receipt) |existing| {
            if (!outcomesEqual(existing.outcome, outcome)) return error.FinalReceiptConflict;
            return (try self.loadUnlocked(admission_key)).?;
        }

        var receipt_id_buffer: [48]u8 = undefined;
        const receipt_id = try deterministicReceiptId(&receipt_id_buffer, "final-receipt", launch_digest);
        var digest_storage: [64]u8 = [_]u8{'0'} ** 64;
        loaded.record.final_receipt = .{
            .admission_key = loaded.record.admission_key,
            .conversation_id = loaded.record.active_conversation_id,
            .launch_digest = loaded.record.launch_digest,
            .launch_id = loaded.record.launch_id,
            .observed_at = observed_at,
            .outcome = outcome,
            .receipt_digest = &digest_storage,
            .receipt_id = receipt_id,
        };
        digest_storage = try protocol.computeReceiptDigest(self.alloc, .{ .final_receipt = loaded.record.final_receipt.? });
        try self.persistUnlocked(loaded.record);
        return (try self.loadUnlocked(admission_key)).?;
    }

    pub fn acknowledgeFinal(
        self: *Ledger,
        acknowledgement: protocol.FinalReceiptAcknowledgement,
    ) !Loaded {
        try protocol.validateCorrelation(acknowledgement.admission_key, acknowledgement.launch_digest, acknowledgement.launch_id);
        try protocol.validateSafeToken(acknowledgement.acknowledgement_id);
        try protocol.validateConversationId(acknowledgement.conversation_id);
        try protocol.validateDigest(acknowledgement.receipt_digest);
        try protocol.validateSafeToken(acknowledgement.receipt_id);
        var lock = try self.acquireLock();
        defer lock.release();
        var loaded = (try self.loadUnlocked(acknowledgement.admission_key)) orelse return error.LaunchNotFound;
        defer loaded.deinit();
        try requireCorrelation(loaded.record, acknowledgement.admission_key, acknowledgement.launch_digest, acknowledgement.launch_id);
        const final = loaded.record.final_receipt orelse return error.FinalReceiptMissing;
        if (!std.mem.eql(u8, final.conversation_id, acknowledgement.conversation_id) or
            !std.mem.eql(u8, final.receipt_id, acknowledgement.receipt_id) or
            !std.mem.eql(u8, final.receipt_digest, acknowledgement.receipt_digest))
        {
            return error.AcknowledgementConflict;
        }
        if (loaded.record.final_acknowledgement_id) |existing| {
            if (!std.mem.eql(u8, existing, acknowledgement.acknowledgement_id)) {
                return error.AcknowledgementConflict;
            }
            return (try self.loadUnlocked(acknowledgement.admission_key)).?;
        }
        loaded.record.final_acknowledgement_id = acknowledgement.acknowledgement_id;
        try self.persistUnlocked(loaded.record);
        return (try self.loadUnlocked(acknowledgement.admission_key)).?;
    }

    fn acquireLock(self: *Ledger) !io_mod.TimedAdvisoryLock {
        return io_mod.acquireTimedAdvisoryLockWithOps(
            &self.control_dir,
            lock_file_name,
            self.options.lock_timeout_ms,
            self.options.lock_ops,
        );
    }

    fn loadUnlocked(self: *Ledger, admission_key: []const u8) !?Loaded {
        const name = try recordFileName(self.alloc, admission_key);
        defer self.alloc.free(name);
        var file = self.records_dir.dir.openFile(io_mod.getIo(), name, .{
            .mode = .read_only,
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch |err| switch (err) {
            error.FileNotFound => return null,
            error.SymLinkLoop, error.IsDir, error.NotDir => return error.LaunchStateUnsafe,
            else => return err,
        };
        defer file.close(io_mod.getIo());
        const stat = try file.stat(io_mod.getIo());
        if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o777 != 0o600 or
            stat.size == 0 or stat.size > max_record_bytes)
        {
            return error.DurableRecordInvalid;
        }
        const bytes = io_mod.readFileToEnd(self.alloc, &file, max_record_bytes) catch |err| switch (err) {
            error.StreamTooLong => return error.DurableRecordInvalid,
            else => return err,
        };
        defer self.alloc.free(bytes);
        var parsed = std.json.parseFromSlice(RecordWire, self.alloc, bytes, .{ .allocate = .alloc_always }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.DurableRecordInvalid,
        };
        errdefer parsed.deinit();
        const record = recordFromWire(self.alloc, parsed.value) catch return error.DurableRecordInvalid;
        const canonical = encodeRecord(self.alloc, record) catch return error.DurableRecordInvalid;
        defer self.alloc.free(canonical);
        if (!std.mem.eql(u8, canonical, bytes)) return error.DurableRecordInvalid;
        if (!std.mem.eql(u8, record.admission_key, admission_key)) return error.DurableRecordInvalid;
        return .{ .parsed = parsed, .record = record };
    }

    fn persistUnlocked(self: *Ledger, record: Record) !void {
        const bytes = try encodeRecord(self.alloc, record);
        defer self.alloc.free(bytes);
        if (bytes.len == 0 or bytes.len > max_record_bytes) return error.DurableRecordInvalid;
        const name = try recordFileName(self.alloc, record.admission_key);
        defer self.alloc.free(name);
        try io_mod.durableReplaceVerifiedWithOps(
            self.alloc,
            &self.records_dir,
            name,
            bytes,
            self.options.durable_ops,
        );
    }
};

fn recordFromWire(alloc: Allocator, wire: RecordWire) !Record {
    if (!std.mem.eql(u8, wire.schema_id, record_schema_id) or wire.schema_version != record_schema_version) {
        return error.DurableRecordInvalid;
    }
    const resume_target: protocol.Resume = if (std.mem.eql(u8, wire.@"resume".mode, "fresh")) resume_value: {
        if (wire.@"resume".conversation_id != null) return error.DurableRecordInvalid;
        break :resume_value .fresh;
    } else if (std.mem.eql(u8, wire.@"resume".mode, "exact")) resume_value: {
        const id = wire.@"resume".conversation_id orelse return error.DurableRecordInvalid;
        try protocol.validateConversationId(id);
        break :resume_value .{ .exact = id };
    } else return error.DurableRecordInvalid;
    const decision = if (wire.decision) |value| decision: {
        const decision_value: protocol.AdmissionDecisionValue = if (std.mem.eql(u8, value.kind, "admitted")) admitted: {
            if (value.cancellation_request_id != null) return error.DurableRecordInvalid;
            const text = value.turn_id orelse return error.DurableRecordInvalid;
            if (text.len == 0 or text[0] == '0') return error.DurableRecordInvalid;
            const turn_id = std.fmt.parseInt(u64, text, 10) catch return error.DurableRecordInvalid;
            const disposition_text = value.disposition orelse return error.DurableRecordInvalid;
            const disposition: protocol.Disposition = if (std.mem.eql(u8, disposition_text, "queued"))
                .queued
            else if (std.mem.eql(u8, disposition_text, "steering"))
                .steering
            else
                return error.DurableRecordInvalid;
            break :admitted .{ .admitted = .{ .turn_id = turn_id, .disposition = disposition } };
        } else if (std.mem.eql(u8, value.kind, "cancelled_before_start")) cancelled: {
            if (value.disposition != null or value.turn_id != null) return error.DurableRecordInvalid;
            const request_id = value.cancellation_request_id orelse return error.DurableRecordInvalid;
            try protocol.validateSafeToken(request_id);
            break :cancelled .{ .cancelled_before_start = .{ .cancellation_request_id = request_id } };
        } else return error.DurableRecordInvalid;
        break :decision protocol.AdmissionDecision{
            .admission_key = wire.admission_key,
            .decision = decision_value,
            .launch_digest = wire.launch_digest,
            .launch_id = wire.launch_id,
            .receipt_digest = value.receipt_digest,
            .receipt_id = value.receipt_id,
        };
    } else null;
    const final_receipt = if (wire.final_receipt) |value| final: {
        const outcome: protocol.Outcome = if (std.mem.eql(u8, value.outcome.kind, "exited")) outcome: {
            if (value.outcome.message != null or value.outcome.signal != null) return error.DurableRecordInvalid;
            break :outcome .{ .exited = value.outcome.code orelse return error.DurableRecordInvalid };
        } else if (std.mem.eql(u8, value.outcome.kind, "signalled")) outcome: {
            if (value.outcome.code != null or value.outcome.message != null) return error.DurableRecordInvalid;
            const signal = value.outcome.signal orelse return error.DurableRecordInvalid;
            if (signal == 0) return error.DurableRecordInvalid;
            break :outcome .{ .signalled = signal };
        } else if (std.mem.eql(u8, value.outcome.kind, "exec_failed")) outcome: {
            if (value.outcome.code != null or value.outcome.signal != null) return error.DurableRecordInvalid;
            const message = value.outcome.message orelse return error.DurableRecordInvalid;
            try protocol.validateBoundedText(message, 1024);
            break :outcome .{ .exec_failed = message };
        } else return error.DurableRecordInvalid;
        break :final protocol.FinalReceipt{
            .admission_key = wire.admission_key,
            .conversation_id = value.conversation_id,
            .launch_digest = wire.launch_digest,
            .launch_id = wire.launch_id,
            .observed_at = value.observed_at,
            .outcome = outcome,
            .receipt_digest = value.receipt_digest,
            .receipt_id = value.receipt_id,
        };
    } else null;
    const record: Record = .{
        .active_conversation_id = wire.active_conversation_id,
        .admission_key = wire.admission_key,
        .conversation_name = wire.conversation_name,
        .decision = decision,
        .directory = wire.directory,
        .effort = wire.effort,
        .final_acknowledgement_id = wire.final_acknowledgement_id,
        .final_receipt = final_receipt,
        .initial_conversation_id = wire.initial_conversation_id,
        .initial_work_digest = wire.initial_work_digest,
        .launch_digest = wire.launch_digest,
        .launch_id = wire.launch_id,
        .launch_receipt_id = wire.launch_receipt_id,
        .model = wire.model,
        .remaining_launch_controls_digest = wire.remaining_launch_controls_digest,
        .request_id = wire.request_id,
        .resume_target = resume_target,
        .state_root = wire.state_root,
    };
    try protocol.validateLaunchRequest(alloc, record.launchRequest());
    if (!try protocol.launchDigestMatches(alloc, record.launchRequest())) {
        return error.DurableRecordInvalid;
    }
    try protocol.validateConversationId(record.initial_conversation_id);
    try protocol.validateConversationId(record.active_conversation_id);
    try protocol.validateSafeToken(record.launch_receipt_id);
    if (record.final_acknowledgement_id) |id| try protocol.validateSafeToken(id);
    if (decision) |value| if (!try protocol.receiptDigestMatches(alloc, .{ .admission_decision = value })) return error.DurableRecordInvalid;
    if (final_receipt) |value| {
        try protocol.validateConversationId(value.conversation_id);
        try protocol.validateTimestamp(value.observed_at);
        if (!try protocol.receiptDigestMatches(alloc, .{ .final_receipt = value })) return error.DurableRecordInvalid;
    }
    return record;
}

fn encodeRecord(alloc: Allocator, record: Record) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"active_conversation_id\":");
    try writeString(writer, record.active_conversation_id);
    try writer.writeAll(",\"admission_key\":");
    try writeString(writer, record.admission_key);
    try writer.writeAll(",\"conversation_name\":");
    try writeString(writer, record.conversation_name);
    if (record.decision) |decision| {
        try writer.writeAll(",\"decision\":{");
        switch (decision.decision) {
            .admitted => |value| {
                try writer.writeAll("\"disposition\":");
                try writeString(writer, @tagName(value.disposition));
                try writer.writeAll(",\"kind\":\"admitted\"");
            },
            .cancelled_before_start => |value| {
                try writer.writeAll("\"cancellation_request_id\":");
                try writeString(writer, value.cancellation_request_id);
                try writer.writeAll(",\"kind\":\"cancelled_before_start\"");
            },
        }
        try writer.writeAll(",\"receipt_digest\":");
        try writeString(writer, decision.receipt_digest);
        try writer.writeAll(",\"receipt_id\":");
        try writeString(writer, decision.receipt_id);
        switch (decision.decision) {
            .admitted => |value| try writer.print(",\"turn_id\":\"{d}\"", .{value.turn_id}),
            .cancelled_before_start => {},
        }
        try writer.writeByte('}');
    }
    try writer.writeAll(",\"directory\":");
    try writeString(writer, record.directory);
    if (record.effort) |effort| {
        try writer.writeAll(",\"effort\":");
        try writeString(writer, effort);
    }
    if (record.final_acknowledgement_id) |id| {
        try writer.writeAll(",\"final_acknowledgement_id\":");
        try writeString(writer, id);
    }
    if (record.final_receipt) |final| {
        try writer.writeAll(",\"final_receipt\":{\"conversation_id\":");
        try writeString(writer, final.conversation_id);
        try writer.writeAll(",\"observed_at\":");
        try writeString(writer, final.observed_at);
        try writer.writeAll(",\"outcome\":");
        switch (final.outcome) {
            .exited => |code| try writer.print("{{\"code\":{d},\"kind\":\"exited\"}}", .{code}),
            .signalled => |signal| try writer.print("{{\"kind\":\"signalled\",\"signal\":{d}}}", .{signal}),
            .exec_failed => |message| {
                try writer.writeAll("{\"kind\":\"exec_failed\",\"message\":");
                try writeString(writer, message);
                try writer.writeByte('}');
            },
        }
        try writer.writeAll(",\"receipt_digest\":");
        try writeString(writer, final.receipt_digest);
        try writer.writeAll(",\"receipt_id\":");
        try writeString(writer, final.receipt_id);
        try writer.writeByte('}');
    }
    try writer.writeAll(",\"initial_conversation_id\":");
    try writeString(writer, record.initial_conversation_id);
    try writer.writeAll(",\"initial_work_digest\":");
    try writeString(writer, record.initial_work_digest);
    try writer.writeAll(",\"launch_digest\":");
    try writeString(writer, record.launch_digest);
    try writer.writeAll(",\"launch_id\":");
    try writeString(writer, record.launch_id);
    try writer.writeAll(",\"launch_receipt_id\":");
    try writeString(writer, record.launch_receipt_id);
    if (record.model) |model| {
        try writer.writeAll(",\"model\":");
        try writeString(writer, model);
    }
    try writer.writeAll(",\"remaining_launch_controls_digest\":");
    try writeString(writer, record.remaining_launch_controls_digest);
    try writer.writeAll(",\"request_id\":");
    try writeString(writer, record.request_id);
    try writer.writeAll(",\"resume\":");
    switch (record.resume_target) {
        .fresh => try writer.writeAll("{\"mode\":\"fresh\"}"),
        .exact => |conversation_id| {
            try writer.writeAll("{\"conversation_id\":");
            try writeString(writer, conversation_id);
            try writer.writeAll(",\"mode\":\"exact\"}");
        },
    }
    try writer.writeAll(",\"schema_id\":\"fx.launch-admission-final-ledger\",\"schema_version\":1,\"state_root\":");
    try writeString(writer, record.state_root);
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn recordFileName(alloc: Allocator, admission_key: []const u8) ![]u8 {
    try protocol.validateSafeToken(admission_key);
    const digest = protocol.sha256Hex(admission_key);
    return std.fmt.allocPrint(alloc, "{s}.json", .{digest});
}

fn deterministicReceiptId(buffer: *[48]u8, prefix: []const u8, launch_digest: []const u8) ![]const u8 {
    try protocol.validateDigest(launch_digest);
    return std.fmt.bufPrint(buffer, "{s}-{s}", .{ prefix, launch_digest[0..24] });
}

fn requireCorrelation(record: Record, admission_key: []const u8, launch_digest: []const u8, launch_id: []const u8) !void {
    if (!std.mem.eql(u8, record.admission_key, admission_key)) return error.CorrelationMismatch;
    if (!std.mem.eql(u8, record.launch_digest, launch_digest)) return error.AdmissionConflict;
    if (!std.mem.eql(u8, record.launch_id, launch_id)) return error.CorrelationMismatch;
}

fn outcomesEqual(left: protocol.Outcome, right: protocol.Outcome) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .exited => |code| code == right.exited,
        .signalled => |signal| signal == right.signalled,
        .exec_failed => |message| std.mem.eql(u8, message, right.exec_failed),
    };
}

fn sampleLaunchRequest(state_root: []const u8, digest: *[64]u8) !protocol.LaunchRequest {
    var request: protocol.LaunchRequest = .{
        .admission_key = "attempt-a",
        .conversation_name = "Durable fixture",
        .directory = "/var/tmp/fx-ledger-worktree",
        .effort = "medium",
        .initial_work_digest = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        .launch_digest = digest,
        .launch_id = "launch-a",
        .model = "fixture/model",
        .remaining_launch_controls_digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .request_id = "launch-request-a",
        .resume_target = .fresh,
        .state_root = state_root,
    };
    digest.* = try protocol.computeLaunchDigest(std.testing.allocator, request);
    request.launch_digest = digest;
    return request;
}

fn tempRoot(alloc: Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
}

const DurableBoundary = enum {
    launch,
    admission,
    cancellation,
    active_conversation,
    final_receipt,
    final_acknowledgement,
};

const InjectedDurabilityFailure = enum {
    before_rename,
    after_rename,
};

const DurabilityFailureProbe = struct {
    failure: InjectedDurabilityFailure,
    fired: bool = false,

    fn syncFile(raw: ?*anyopaque, file: std.Io.File) anyerror!void {
        const self: *DurabilityFailureProbe = @ptrCast(@alignCast(raw.?));
        if (self.failure == .before_rename and !self.fired) {
            self.fired = true;
            return error.InjectedDurabilityFailure;
        }
        try file.sync(io_mod.getIo());
    }

    fn syncDir(raw: ?*anyopaque, dir: std.Io.Dir) anyerror!void {
        const self: *DurabilityFailureProbe = @ptrCast(@alignCast(raw.?));
        if (self.failure == .after_rename and !self.fired) {
            self.fired = true;
            return error.InjectedDurabilityFailure;
        }
        try io_mod.syncVerifiedDir(dir);
    }

    fn options(self: *DurabilityFailureProbe) Options {
        return .{ .durable_ops = .{
            .ctx = self,
            .sync_file = syncFile,
            .sync_dir = syncDir,
        } };
    }
};

fn expectInjectedDurabilityFailure(
    failure: InjectedDurabilityFailure,
    result: anytype,
) !void {
    const expected = switch (failure) {
        .before_rename => error.DurableReplacePreRenameFailed,
        .after_rename => error.DurableReplacePostRenameFailed,
    };
    try std.testing.expectError(expected, result);
}

fn exerciseDurableBoundaryRecovery(
    boundary: DurableBoundary,
    failure: InjectedDurabilityFailure,
) !void {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempRoot(alloc, &tmp);
    defer alloc.free(root);
    var digest: [64]u8 = undefined;
    const request = try sampleLaunchRequest(root, &digest);

    if (boundary != .launch) {
        var setup = try Ledger.open(alloc, root, .{});
        defer setup.deinit();
        var accepted = try setup.acceptLaunch(request, "fresh-conversation-a");
        accepted.deinit();
        if (boundary == .final_acknowledgement) {
            var final = try setup.recordFinal(
                request.admission_key,
                request.launch_digest,
                request.launch_id,
                .{ .exited = 0 },
                "2026-08-31T12:00:00.000Z",
            );
            final.deinit();
        }
    }

    var probe = DurabilityFailureProbe{ .failure = failure };
    var faulting = try Ledger.open(alloc, root, probe.options());
    defer faulting.deinit();
    switch (boundary) {
        .launch => try expectInjectedDurabilityFailure(
            failure,
            faulting.acceptLaunchObserved(request, "fresh-conversation-a"),
        ),
        .admission => try expectInjectedDurabilityFailure(
            failure,
            faulting.admit(
                request.admission_key,
                request.launch_digest,
                request.launch_id,
                41,
                .queued,
            ),
        ),
        .cancellation => try expectInjectedDurabilityFailure(
            failure,
            faulting.cancel(.{
                .admission_key = request.admission_key,
                .launch_digest = request.launch_digest,
                .launch_id = request.launch_id,
                .request_id = "cancel-a",
            }),
        ),
        .active_conversation => try expectInjectedDurabilityFailure(
            failure,
            faulting.updateActiveConversation(
                request.admission_key,
                request.launch_digest,
                request.launch_id,
                "conversation-after-new",
            ),
        ),
        .final_receipt => try expectInjectedDurabilityFailure(
            failure,
            faulting.recordFinal(
                request.admission_key,
                request.launch_digest,
                request.launch_id,
                .{ .exited = 0 },
                "2026-08-31T12:00:00.000Z",
            ),
        ),
        .final_acknowledgement => {
            var current = (try faulting.load(request.admission_key)).?;
            defer current.deinit();
            const final = current.record.final_receipt.?;
            try expectInjectedDurabilityFailure(
                failure,
                faulting.acknowledgeFinal(.{
                    .acknowledgement_id = "final-ack-a",
                    .admission_key = request.admission_key,
                    .conversation_id = final.conversation_id,
                    .launch_digest = request.launch_digest,
                    .launch_id = request.launch_id,
                    .receipt_digest = final.receipt_digest,
                    .receipt_id = final.receipt_id,
                }),
            );
        },
    }
    try std.testing.expect(probe.fired);

    var recovered = try Ledger.open(alloc, root, .{});
    defer recovered.deinit();
    switch (boundary) {
        .launch => {
            var mutation = try recovered.acceptLaunchObserved(
                request,
                "fresh-conversation-a",
            );
            defer mutation.deinit();
            try std.testing.expectEqual(
                failure == .before_rename,
                mutation.newly_accepted,
            );
        },
        .admission => {
            var mutation = try recovered.admit(
                request.admission_key,
                request.launch_digest,
                request.launch_id,
                41,
                .queued,
            );
            defer mutation.deinit();
            try std.testing.expectEqual(
                failure == .before_rename,
                mutation.newly_decided,
            );
            try std.testing.expectEqual(
                @as(u64, 41),
                mutation.loaded.record.decision.?.decision.admitted.turn_id,
            );
        },
        .cancellation => {
            var mutation = try recovered.cancel(.{
                .admission_key = request.admission_key,
                .launch_digest = request.launch_digest,
                .launch_id = request.launch_id,
                .request_id = "cancel-retry",
            });
            defer mutation.deinit();
            try std.testing.expectEqual(
                failure == .before_rename,
                mutation.newly_decided,
            );
            const cancellation = mutation.loaded.record.decision.?.decision.cancelled_before_start;
            try std.testing.expectEqualStrings(
                if (failure == .before_rename) "cancel-retry" else "cancel-a",
                cancellation.cancellation_request_id,
            );
        },
        .active_conversation => {
            var loaded = try recovered.updateActiveConversation(
                request.admission_key,
                request.launch_digest,
                request.launch_id,
                "conversation-after-new",
            );
            defer loaded.deinit();
            try std.testing.expectEqualStrings(
                "conversation-after-new",
                loaded.record.active_conversation_id,
            );
        },
        .final_receipt => {
            var loaded = try recovered.recordFinal(
                request.admission_key,
                request.launch_digest,
                request.launch_id,
                .{ .exited = 0 },
                "2026-08-31T12:00:00.000Z",
            );
            defer loaded.deinit();
            try std.testing.expect(loaded.record.final_receipt != null);
        },
        .final_acknowledgement => {
            var current = (try recovered.load(request.admission_key)).?;
            defer current.deinit();
            const final = current.record.final_receipt.?;
            var acknowledged = try recovered.acknowledgeFinal(.{
                .acknowledgement_id = "final-ack-a",
                .admission_key = request.admission_key,
                .conversation_id = final.conversation_id,
                .launch_digest = request.launch_digest,
                .launch_id = request.launch_id,
                .receipt_digest = final.receipt_digest,
                .receipt_id = final.receipt_id,
            });
            defer acknowledged.deinit();
            try std.testing.expectEqualStrings(
                "final-ack-a",
                acknowledged.record.final_acknowledgement_id.?,
            );
        },
    }
}

test "launch ledger pre-rename failures leave every durable boundary retryable" {
    inline for (std.meta.tags(DurableBoundary)) |boundary| {
        try exerciseDurableBoundaryRecovery(boundary, .before_rename);
    }
}

test "launch ledger post-rename indeterminate failures recover every durable boundary" {
    inline for (std.meta.tags(DurableBoundary)) |boundary| {
        try exerciseDurableBoundaryRecovery(boundary, .after_rename);
    }
}

test "launch ledger retries a matching digest with the current request identity" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempRoot(alloc, &tmp);
    defer alloc.free(root);
    var ledger = try Ledger.open(alloc, root, .{});
    defer ledger.deinit();
    var digest: [64]u8 = undefined;
    const request = try sampleLaunchRequest(root, &digest);
    var accepted = try ledger.acceptLaunchObserved(request, "fresh-conversation-a");
    accepted.deinit();

    var retry = request;
    retry.request_id = "launch-request-retry";
    var replay = try ledger.acceptLaunchObserved(retry, "unused-fresh-candidate");
    defer replay.deinit();
    try std.testing.expect(!replay.newly_accepted);
    const receipt = replay.loaded.record.launchReceipt(retry.request_id);
    try std.testing.expectEqualStrings("launch-request-retry", receipt.request_id);
    try std.testing.expectEqualStrings(
        "fresh-conversation-a",
        replay.loaded.record.initial_conversation_id,
    );

    var altered = retry;
    altered.conversation_name = "Conflicting launch";
    var altered_digest = try protocol.computeLaunchDigest(alloc, altered);
    altered.launch_digest = &altered_digest;
    try std.testing.expectError(
        error.AdmissionConflict,
        ledger.acceptLaunchObserved(altered, "unused-fresh-candidate"),
    );
}

test "launch ledger cancellation wins before admission and remains permanent" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempRoot(alloc, &tmp);
    defer alloc.free(root);
    var ledger = try Ledger.open(alloc, root, .{});
    defer ledger.deinit();
    var digest: [64]u8 = undefined;
    const request = try sampleLaunchRequest(root, &digest);
    var accepted = try ledger.acceptLaunch(request, "fresh-conversation-a");
    accepted.deinit();
    var cancelled = try ledger.cancel(.{
        .admission_key = request.admission_key,
        .launch_digest = request.launch_digest,
        .launch_id = request.launch_id,
        .request_id = "cancel-a",
    });
    defer cancelled.deinit();
    try std.testing.expect(cancelled.newly_decided);
    try std.testing.expect(cancelled.loaded.record.decision.?.decision == .cancelled_before_start);
    try std.testing.expectError(
        error.AdmissionCancelled,
        ledger.admit(request.admission_key, request.launch_digest, request.launch_id, 41, .queued),
    );

    var reopened = try Ledger.open(alloc, root, .{});
    defer reopened.deinit();
    var replay = try reopened.cancel(.{
        .admission_key = request.admission_key,
        .launch_digest = request.launch_digest,
        .launch_id = request.launch_id,
        .request_id = "cancel-retry",
    });
    defer replay.deinit();
    try std.testing.expect(!replay.newly_decided);
    try std.testing.expectEqualStrings("cancel-a", replay.loaded.record.decision.?.decision.cancelled_before_start.cancellation_request_id);
}

test "launch ledger admission wins before cancellation and replays the original Turn" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempRoot(alloc, &tmp);
    defer alloc.free(root);
    var ledger = try Ledger.open(alloc, root, .{});
    defer ledger.deinit();
    var digest: [64]u8 = undefined;
    const request = try sampleLaunchRequest(root, &digest);
    var accepted = try ledger.acceptLaunch(request, "fresh-conversation-a");
    accepted.deinit();
    var admitted = try ledger.admit(request.admission_key, request.launch_digest, request.launch_id, 41, .steering);
    defer admitted.deinit();
    try std.testing.expect(admitted.newly_decided);
    try std.testing.expectEqual(@as(u64, 41), admitted.loaded.record.decision.?.decision.admitted.turn_id);

    var cancelled = try ledger.cancel(.{
        .admission_key = request.admission_key,
        .launch_digest = request.launch_digest,
        .launch_id = request.launch_id,
        .request_id = "cancel-too-late",
    });
    defer cancelled.deinit();
    try std.testing.expect(!cancelled.newly_decided);
    try std.testing.expectEqual(@as(u64, 41), cancelled.loaded.record.decision.?.decision.admitted.turn_id);
    try std.testing.expectEqual(protocol.Disposition.steering, cancelled.loaded.record.decision.?.decision.admitted.disposition);
}

test "launch ledger rejects conflicting digest and recovers a lost response" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempRoot(alloc, &tmp);
    defer alloc.free(root);
    var digest: [64]u8 = undefined;
    const request = try sampleLaunchRequest(root, &digest);
    {
        var ledger = try Ledger.open(alloc, root, .{});
        defer ledger.deinit();
        var accepted = try ledger.acceptLaunch(request, "fresh-conversation-a");
        accepted.deinit();
        var admitted = try ledger.admit(request.admission_key, request.launch_digest, request.launch_id, 77, .queued);
        admitted.deinit();
    }
    var recovered = try Ledger.open(alloc, root, .{});
    defer recovered.deinit();
    var replay = try recovered.admit(request.admission_key, request.launch_digest, request.launch_id, 999, .steering);
    defer replay.deinit();
    try std.testing.expect(!replay.newly_decided);
    try std.testing.expectEqual(@as(u64, 77), replay.loaded.record.decision.?.decision.admitted.turn_id);
    var conflict = [_]u8{'f'} ** 64;
    try std.testing.expectError(
        error.AdmissionConflict,
        recovered.admit(request.admission_key, &conflict, request.launch_id, 88, .queued),
    );
}

test "launch ledger preserves active Conversation and every terminal outcome until exact ack" {
    const alloc = std.testing.allocator;
    inline for (.{
        protocol.Outcome{ .exited = 0 },
        protocol.Outcome{ .signalled = 15 },
        protocol.Outcome{ .exec_failed = "child executable was unavailable" },
    }) |outcome| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tempRoot(alloc, &tmp);
        defer alloc.free(root);
        var ledger = try Ledger.open(alloc, root, .{});
        defer ledger.deinit();
        var digest: [64]u8 = undefined;
        const request = try sampleLaunchRequest(root, &digest);
        var accepted = try ledger.acceptLaunch(request, "fresh-conversation-a");
        accepted.deinit();
        var active = try ledger.updateActiveConversation(request.admission_key, request.launch_digest, request.launch_id, "conversation-after-new");
        active.deinit();
        var final = try ledger.recordFinal(request.admission_key, request.launch_digest, request.launch_id, outcome, "2026-08-31T12:00:00.000Z");
        defer final.deinit();
        try std.testing.expectEqualStrings("conversation-after-new", final.record.final_receipt.?.conversation_id);

        var wrong = protocol.FinalReceiptAcknowledgement{
            .acknowledgement_id = "final-ack-a",
            .admission_key = request.admission_key,
            .conversation_id = final.record.final_receipt.?.conversation_id,
            .launch_digest = request.launch_digest,
            .launch_id = request.launch_id,
            .receipt_digest = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
            .receipt_id = final.record.final_receipt.?.receipt_id,
        };
        try std.testing.expectError(error.AcknowledgementConflict, ledger.acknowledgeFinal(wrong));
        wrong.receipt_digest = final.record.final_receipt.?.receipt_digest;
        var acknowledged = try ledger.acknowledgeFinal(wrong);
        acknowledged.deinit();
        var replay = try ledger.acknowledgeFinal(wrong);
        defer replay.deinit();
        try std.testing.expectEqualStrings("final-ack-a", replay.record.final_acknowledgement_id.?);

        var reopened = try Ledger.open(alloc, root, .{});
        defer reopened.deinit();
        var restarted_ack = try reopened.acknowledgeFinal(wrong);
        restarted_ack.deinit();
        var retained = (try reopened.load(request.admission_key)).?;
        defer retained.deinit();
        try std.testing.expectEqualStrings("final-ack-a", retained.record.final_acknowledgement_id.?);
    }
}

test "launch ledger exact resume requires and retains the requested Conversation identity" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempRoot(alloc, &tmp);
    defer alloc.free(root);
    var ledger = try Ledger.open(alloc, root, .{});
    defer ledger.deinit();
    var digest: [64]u8 = undefined;
    var request = try sampleLaunchRequest(root, &digest);
    request.resume_target = .{ .exact = "requested-exact-conversation" };
    digest = try protocol.computeLaunchDigest(alloc, request);
    request.launch_digest = &digest;
    var accepted = try ledger.acceptLaunch(request, "requested-exact-conversation");
    defer accepted.deinit();
    try std.testing.expectEqualStrings("requested-exact-conversation", accepted.record.initial_conversation_id);
    try std.testing.expectError(
        error.CorrelationMismatch,
        ledger.acceptLaunch(request, "different-fresh-candidate"),
    );
    var replay = try ledger.acceptLaunch(request, "requested-exact-conversation");
    defer replay.deinit();
    try std.testing.expectEqualStrings("requested-exact-conversation", replay.record.initial_conversation_id);
}
