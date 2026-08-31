const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Limits = struct {
    max_depth: usize = 32,
    max_properties: usize = 256,
    max_required: usize = 256,
    max_alternatives: usize = 64,
    max_enum_values: usize = 256,
    max_total_nodes: usize = 8192,
    max_evaluations: usize = 32768,
    max_number_bytes: usize = 256,
    max_value_depth: usize = 128,
};

pub const SchemaError = error{
    InvalidSchema,
    SchemaDepthExceeded,
    SchemaLimitExceeded,
    UnsupportedSchemaKeyword,
};

pub const ValidationError = SchemaError || error{ValueDoesNotMatchSchema};

/// Validates the strict, local JSON Schema subset accepted by the structured
/// subscription boundary. The root must be an object schema. Every object
/// closes additional properties and requires each declared property, matching
/// the strict Responses schema contract.
pub fn validateObjectSchema(schema: std.json.Value, limits: Limits) SchemaError!void {
    var budget = StructuralBudget{ .remaining = limits.max_total_nodes };
    try preflightJsonValue(schema, 0, limits, &budget);
    if (schema != .object) return error.InvalidSchema;
    const type_value = schema.object.get("type") orelse return error.InvalidSchema;
    if (type_value != .string or !std.mem.eql(u8, type_value.string, "object")) {
        return error.InvalidSchema;
    }
    try validateSchemaNode(schema, schema, 0, limits);
}

pub fn validateValue(
    schema: std.json.Value,
    value: std.json.Value,
    limits: Limits,
) ValidationError!void {
    try validateObjectSchema(schema, limits);
    var structural_budget = StructuralBudget{ .remaining = limits.max_total_nodes };
    try preflightJsonValue(value, 0, limits, &structural_budget);
    var evaluation_budget = EvaluationBudget{ .remaining = limits.max_evaluations };
    if (!try matchesSchema(schema, schema, value, 0, limits, &evaluation_budget)) {
        return error.ValueDoesNotMatchSchema;
    }
}

/// Returns canonical JSON with lexicographically sorted object keys. The
/// caller owns the returned bytes.
pub fn canonicalStringify(alloc: Allocator, value: std.json.Value) ![]u8 {
    const limits = Limits{};
    var budget = StructuralBudget{ .remaining = limits.max_total_nodes };
    try preflightJsonValue(value, 0, limits, &budget);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try writeCanonical(alloc, &out.writer, value);
    return out.toOwnedSlice();
}

const StructuralBudget = struct {
    remaining: usize,
};

const EvaluationBudget = struct {
    remaining: usize,
};

fn spendStructuralNode(budget: *StructuralBudget) SchemaError!void {
    if (budget.remaining == 0) return error.SchemaLimitExceeded;
    budget.remaining -= 1;
}

fn spendEvaluation(budget: *EvaluationBudget) SchemaError!void {
    if (budget.remaining == 0) return error.SchemaLimitExceeded;
    budget.remaining -= 1;
}

fn preflightJsonValue(
    value: std.json.Value,
    depth: usize,
    limits: Limits,
    budget: *StructuralBudget,
) SchemaError!void {
    if (depth > limits.max_value_depth) return error.SchemaDepthExceeded;
    try spendStructuralNode(budget);
    switch (value) {
        .number_string => |text| {
            if (text.len > limits.max_number_bytes or text.len > number_storage_bytes) {
                return error.SchemaLimitExceeded;
            }
            var storage: [number_storage_bytes]u8 = undefined;
            _ = normalizeDecimal(text, &storage) orelse return error.InvalidSchema;
        },
        // The local protocol parses numbers as lexemes. A floating value has
        // already discarded source precision, so fail closed instead of
        // approximating schema semantics.
        .float => return error.InvalidSchema,
        .array => |array| for (array.items) |item| {
            try preflightJsonValue(item, depth + 1, limits, budget);
        },
        .object => |object| {
            if (object.count() > limits.max_properties) return error.SchemaLimitExceeded;
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                try preflightJsonValue(entry.value_ptr.*, depth + 1, limits, budget);
            }
        },
        else => {},
    }
}

fn validateSchemaNode(
    root: std.json.Value,
    schema: std.json.Value,
    depth: usize,
    limits: Limits,
) SchemaError!void {
    if (depth > limits.max_depth) return error.SchemaDepthExceeded;
    if (schema != .object) return error.InvalidSchema;

    var iterator = schema.object.iterator();
    while (iterator.next()) |entry| {
        if (!supportedKeyword(entry.key_ptr.*)) return error.UnsupportedSchemaKeyword;
    }

    if (schema.object.get("$defs")) |defs| {
        if (defs != .object or defs.object.count() > limits.max_properties) {
            return error.SchemaLimitExceeded;
        }
        var defs_iterator = defs.object.iterator();
        while (defs_iterator.next()) |entry| {
            if (entry.key_ptr.len == 0) return error.InvalidSchema;
            try validateSchemaNode(root, entry.value_ptr.*, depth + 1, limits);
        }
    }

    if (schema.object.get("$ref")) |ref_value| {
        if (ref_value != .string) return error.InvalidSchema;
        _ = try resolveLocalRef(root, ref_value.string);
    }

    var has_assertion = schema.object.get("$ref") != null or
        schema.object.get("const") != null or schema.object.get("enum") != null;

    if (schema.object.get("enum")) |values| {
        if (values != .array or values.array.items.len == 0 or
            values.array.items.len > limits.max_enum_values)
        {
            return error.SchemaLimitExceeded;
        }
    }

    inline for (.{ "allOf", "anyOf", "oneOf" }) |keyword| {
        if (schema.object.get(keyword)) |alternatives| {
            has_assertion = true;
            if (alternatives != .array or alternatives.array.items.len == 0 or
                alternatives.array.items.len > limits.max_alternatives)
            {
                return error.SchemaLimitExceeded;
            }
            for (alternatives.array.items) |alternative| {
                try validateSchemaNode(root, alternative, depth + 1, limits);
            }
        }
    }

    const type_name = if (schema.object.get("type")) |type_value| type: {
        has_assertion = true;
        if (type_value != .string or !validTypeName(type_value.string)) {
            return error.InvalidSchema;
        }
        break :type type_value.string;
    } else null;

    if (!has_assertion) return error.InvalidSchema;
    try validateTypeKeywordCompatibility(schema.object, type_name);

    if (type_name) |name| {
        if (std.mem.eql(u8, name, "object")) {
            try validateObjectKeywords(root, schema.object, depth, limits);
        } else if (std.mem.eql(u8, name, "array")) {
            try validateArrayKeywords(root, schema.object, depth, limits);
        } else if (std.mem.eql(u8, name, "string")) {
            try validateOrderedNonNegativeBounds(schema.object, "minLength", "maxLength");
        } else if (std.mem.eql(u8, name, "number") or std.mem.eql(u8, name, "integer")) {
            try validateNumberBounds(schema.object);
        }
    }
}

fn validateTypeKeywordCompatibility(
    object: std.json.ObjectMap,
    type_name: ?[]const u8,
) SchemaError!void {
    inline for (.{ "properties", "required", "additionalProperties", "minProperties", "maxProperties" }) |key| {
        if (object.get(key) != null and !optionalTypeIs(type_name, "object")) return error.InvalidSchema;
    }
    inline for (.{ "items", "minItems", "maxItems" }) |key| {
        if (object.get(key) != null and !optionalTypeIs(type_name, "array")) return error.InvalidSchema;
    }
    inline for (.{ "minLength", "maxLength" }) |key| {
        if (object.get(key) != null and !optionalTypeIs(type_name, "string")) return error.InvalidSchema;
    }
    inline for (.{ "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum" }) |key| {
        if (object.get(key) != null and !optionalTypeIsNumeric(type_name)) return error.InvalidSchema;
    }
}

fn optionalTypeIs(type_name: ?[]const u8, expected: []const u8) bool {
    const name = type_name orelse return false;
    return std.mem.eql(u8, name, expected);
}

fn optionalTypeIsNumeric(type_name: ?[]const u8) bool {
    const name = type_name orelse return false;
    return std.mem.eql(u8, name, "number") or std.mem.eql(u8, name, "integer");
}

fn validateObjectKeywords(
    root: std.json.Value,
    object: std.json.ObjectMap,
    depth: usize,
    limits: Limits,
) SchemaError!void {
    const properties = object.get("properties") orelse return error.InvalidSchema;
    if (properties != .object or properties.object.count() > limits.max_properties) {
        return error.SchemaLimitExceeded;
    }
    const required = object.get("required") orelse return error.InvalidSchema;
    if (required != .array or required.array.items.len > limits.max_required or
        required.array.items.len != properties.object.count())
    {
        return error.InvalidSchema;
    }
    const additional = object.get("additionalProperties") orelse return error.InvalidSchema;
    if (additional != .bool or additional.bool) return error.InvalidSchema;

    for (required.array.items, 0..) |item, index| {
        if (item != .string or item.string.len == 0) return error.InvalidSchema;
        for (required.array.items[0..index]) |prior| {
            if (std.mem.eql(u8, prior.string, item.string)) return error.InvalidSchema;
        }
    }

    var iterator = properties.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.key_ptr.len == 0 or !containsRequiredName(required.array.items, entry.key_ptr.*))
            return error.InvalidSchema;
        try validateSchemaNode(root, entry.value_ptr.*, depth + 1, limits);
    }
    try validateOrderedNonNegativeBounds(object, "minProperties", "maxProperties");
}

fn containsRequiredName(required: []const std.json.Value, name: []const u8) bool {
    for (required) |item| {
        if (std.mem.eql(u8, item.string, name)) return true;
    }
    return false;
}

fn validateArrayKeywords(
    root: std.json.Value,
    object: std.json.ObjectMap,
    depth: usize,
    limits: Limits,
) SchemaError!void {
    const items = object.get("items") orelse return error.InvalidSchema;
    try validateSchemaNode(root, items, depth + 1, limits);
    try validateOrderedNonNegativeBounds(object, "minItems", "maxItems");
}

fn validateOrderedNonNegativeBounds(
    object: std.json.ObjectMap,
    min_key: []const u8,
    max_key: []const u8,
) SchemaError!void {
    const minimum = try optionalNonNegativeInteger(object, min_key);
    const maximum = try optionalNonNegativeInteger(object, max_key);
    if (minimum != null and maximum != null and minimum.? > maximum.?) {
        return error.InvalidSchema;
    }
}

fn validateNumberBounds(object: std.json.ObjectMap) SchemaError!void {
    const minimum = try optionalNumber(object, "minimum");
    const maximum = try optionalNumber(object, "maximum");
    const exclusive_minimum = try optionalNumber(object, "exclusiveMinimum");
    const exclusive_maximum = try optionalNumber(object, "exclusiveMaximum");
    if (minimum != null and maximum != null and
        (jsonNumberCompare(minimum.?, maximum.?) orelse return error.InvalidSchema) == .gt)
    {
        return error.InvalidSchema;
    }
    if (exclusive_minimum != null and exclusive_maximum != null and
        (jsonNumberCompare(exclusive_minimum.?, exclusive_maximum.?) orelse return error.InvalidSchema) != .lt)
    {
        return error.InvalidSchema;
    }
}

fn supportedKeyword(key: []const u8) bool {
    const supported = [_][]const u8{
        "$defs",    "$id",       "$ref",          "$schema",   "additionalProperties", "allOf",
        "anyOf",    "const",     "description",   "enum",      "exclusiveMaximum",     "exclusiveMinimum",
        "items",    "maximum",   "maxItems",      "maxLength", "maxProperties",        "minimum",
        "minItems", "minLength", "minProperties", "oneOf",     "properties",           "required",
        "title",    "type",
    };
    for (supported) |candidate| if (std.mem.eql(u8, key, candidate)) return true;
    return false;
}

fn validTypeName(name: []const u8) bool {
    inline for (.{ "object", "array", "string", "number", "integer", "boolean", "null" }) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn optionalNonNegativeInteger(object: std.json.ObjectMap, key: []const u8) SchemaError!?usize {
    const value = object.get(key) orelse return null;
    return jsonNonNegativeUsize(value) orelse error.InvalidSchema;
}

fn optionalNumber(object: std.json.ObjectMap, key: []const u8) SchemaError!?std.json.Value {
    const value = object.get(key) orelse return null;
    var storage: [number_storage_bytes]u8 = undefined;
    _ = normalizeJsonNumber(value, &storage) orelse return error.InvalidSchema;
    return value;
}

fn matchesSchema(
    root: std.json.Value,
    schema: std.json.Value,
    value: std.json.Value,
    depth: usize,
    limits: Limits,
    budget: *EvaluationBudget,
) SchemaError!bool {
    if (depth > limits.max_depth) return error.SchemaDepthExceeded;
    try spendEvaluation(budget);
    const object = schema.object;

    if (object.get("$ref")) |ref_value| {
        if (!try matchesSchema(root, try resolveLocalRef(root, ref_value.string), value, depth + 1, limits, budget)) {
            return false;
        }
    }
    if (object.get("const")) |expected| {
        if (!try jsonEqual(expected, value, budget)) return false;
    }
    if (object.get("enum")) |values| {
        var found = false;
        for (values.array.items) |expected| {
            if (try jsonEqual(expected, value, budget)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }

    if (object.get("allOf")) |alternatives| {
        for (alternatives.array.items) |alternative| {
            if (!try matchesSchema(root, alternative, value, depth + 1, limits, budget)) return false;
        }
    }
    if (object.get("anyOf")) |alternatives| {
        var matched = false;
        for (alternatives.array.items) |alternative| {
            if (try matchesSchema(root, alternative, value, depth + 1, limits, budget)) {
                matched = true;
                break;
            }
        }
        if (!matched) return false;
    }
    if (object.get("oneOf")) |alternatives| {
        var matches: usize = 0;
        for (alternatives.array.items) |alternative| {
            if (try matchesSchema(root, alternative, value, depth + 1, limits, budget)) matches += 1;
        }
        if (matches != 1) return false;
    }

    const type_value = object.get("type") orelse return true;
    const type_name = type_value.string;
    if (!valueMatchesType(value, type_name)) return false;

    if (std.mem.eql(u8, type_name, "object")) {
        const properties = object.get("properties").?.object;
        const required = object.get("required").?.array;
        for (required.items) |required_name| {
            if (value.object.get(required_name.string) == null) return false;
        }
        var value_iterator = value.object.iterator();
        while (value_iterator.next()) |entry| {
            const property_schema = properties.get(entry.key_ptr.*) orelse return false;
            if (!try matchesSchema(root, property_schema, entry.value_ptr.*, depth + 1, limits, budget)) {
                return false;
            }
        }
        if (!withinOptionalCount(value.object.count(), object, "minProperties", "maxProperties")) return false;
    } else if (std.mem.eql(u8, type_name, "array")) {
        if (!withinOptionalCount(value.array.items.len, object, "minItems", "maxItems")) return false;
        const item_schema = object.get("items").?;
        for (value.array.items) |item| {
            if (!try matchesSchema(root, item_schema, item, depth + 1, limits, budget)) return false;
        }
    } else if (std.mem.eql(u8, type_name, "string")) {
        const length = std.unicode.utf8CountCodepoints(value.string) catch return false;
        if (!withinOptionalCount(length, object, "minLength", "maxLength")) return false;
    } else if (std.mem.eql(u8, type_name, "number") or std.mem.eql(u8, type_name, "integer")) {
        if (object.get("minimum")) |bound| {
            if ((jsonNumberCompare(value, bound) orelse return false) == .lt) return false;
        }
        if (object.get("maximum")) |bound| {
            if ((jsonNumberCompare(value, bound) orelse return false) == .gt) return false;
        }
        if (object.get("exclusiveMinimum")) |bound| {
            if ((jsonNumberCompare(value, bound) orelse return false) != .gt) return false;
        }
        if (object.get("exclusiveMaximum")) |bound| {
            if ((jsonNumberCompare(value, bound) orelse return false) != .lt) return false;
        }
    }
    return true;
}

fn withinOptionalCount(
    count: usize,
    object: std.json.ObjectMap,
    min_key: []const u8,
    max_key: []const u8,
) bool {
    if (object.get(min_key)) |minimum| {
        const minimum_count = jsonNonNegativeUsize(minimum) orelse return false;
        if (count < minimum_count) return false;
    }
    if (object.get(max_key)) |maximum| {
        const maximum_count = jsonNonNegativeUsize(maximum) orelse return false;
        if (count > maximum_count) return false;
    }
    return true;
}

fn valueMatchesType(value: std.json.Value, type_name: []const u8) bool {
    if (std.mem.eql(u8, type_name, "object")) return value == .object;
    if (std.mem.eql(u8, type_name, "array")) return value == .array;
    if (std.mem.eql(u8, type_name, "string")) return value == .string;
    if (std.mem.eql(u8, type_name, "boolean")) return value == .bool;
    if (std.mem.eql(u8, type_name, "null")) return value == .null;
    if (std.mem.eql(u8, type_name, "number")) {
        var storage: [number_storage_bytes]u8 = undefined;
        return normalizeJsonNumber(value, &storage) != null;
    }
    if (std.mem.eql(u8, type_name, "integer")) return jsonInteger(value);
    return false;
}

const number_storage_bytes: usize = 256;
const max_decimal_exponent: i64 = 1_000_000;

const NormalizedNumber = struct {
    negative: bool,
    digits: []const u8,
    exponent: i64,

    fn isZero(self: NormalizedNumber) bool {
        return self.digits.len == 0;
    }

    fn isInteger(self: NormalizedNumber) bool {
        return self.isZero() or self.exponent >= 0;
    }
};

fn normalizeJsonNumber(value: std.json.Value, storage: *[number_storage_bytes]u8) ?NormalizedNumber {
    return switch (value) {
        .integer => |number| blk: {
            var text: [32]u8 = undefined;
            const rendered = std.fmt.bufPrint(&text, "{d}", .{number}) catch break :blk null;
            break :blk normalizeDecimal(rendered, storage);
        },
        .float => null,
        .number_string => |text| normalizeDecimal(text, storage),
        else => null,
    };
}

fn normalizeDecimal(text: []const u8, storage: *[number_storage_bytes]u8) ?NormalizedNumber {
    if (text.len == 0 or text.len > number_storage_bytes) return null;
    var index: usize = 0;
    const negative = if (text[index] == '-') negative: {
        index += 1;
        if (index == text.len) return null;
        break :negative true;
    } else false;

    var digits_len: usize = 0;
    if (text[index] == '0') {
        storage[digits_len] = '0';
        digits_len += 1;
        index += 1;
        if (index < text.len and std.ascii.isDigit(text[index])) return null;
    } else {
        if (text[index] < '1' or text[index] > '9') return null;
        while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {
            storage[digits_len] = text[index];
            digits_len += 1;
        }
    }

    var fractional_digits: usize = 0;
    if (index < text.len and text[index] == '.') {
        index += 1;
        const fraction_start = index;
        while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {
            storage[digits_len] = text[index];
            digits_len += 1;
            fractional_digits += 1;
        }
        if (index == fraction_start) return null;
    }

    var explicit_exponent: i64 = 0;
    if (index < text.len and (text[index] == 'e' or text[index] == 'E')) {
        index += 1;
        if (index == text.len) return null;
        const exponent_negative = if (text[index] == '+' or text[index] == '-') sign: {
            const result = text[index] == '-';
            index += 1;
            if (index == text.len) return null;
            break :sign result;
        } else false;
        const exponent_start = index;
        var magnitude: i64 = 0;
        while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {
            const digit: i64 = text[index] - '0';
            if (magnitude > @divFloor(max_decimal_exponent - digit, 10)) return null;
            magnitude = magnitude * 10 + digit;
        }
        if (index == exponent_start) return null;
        explicit_exponent = if (exponent_negative) -magnitude else magnitude;
    }
    if (index != text.len) return null;

    var first: usize = 0;
    while (first < digits_len and storage[first] == '0') : (first += 1) {}
    if (first == digits_len) {
        return .{ .negative = false, .digits = storage[0..0], .exponent = 0 };
    }

    var exponent = explicit_exponent - @as(i64, @intCast(fractional_digits));
    var last = digits_len;
    while (last > first and storage[last - 1] == '0') : (last -= 1) {
        exponent += 1;
    }
    if (exponent < -max_decimal_exponent or exponent > max_decimal_exponent) return null;
    return .{ .negative = negative, .digits = storage[first..last], .exponent = exponent };
}

fn jsonNumberCompare(a: std.json.Value, b: std.json.Value) ?std.math.Order {
    var a_storage: [number_storage_bytes]u8 = undefined;
    var b_storage: [number_storage_bytes]u8 = undefined;
    const left = normalizeJsonNumber(a, &a_storage) orelse return null;
    const right = normalizeJsonNumber(b, &b_storage) orelse return null;
    if (left.isZero() and right.isZero()) return .eq;
    if (left.isZero()) return if (right.negative) .gt else .lt;
    if (right.isZero()) return if (left.negative) .lt else .gt;
    if (left.negative != right.negative) return if (left.negative) .lt else .gt;
    const magnitude_order = compareMagnitude(left, right);
    return if (left.negative) reverseOrder(magnitude_order) else magnitude_order;
}

fn compareMagnitude(a: NormalizedNumber, b: NormalizedNumber) std.math.Order {
    const a_scale = a.exponent + @as(i64, @intCast(a.digits.len));
    const b_scale = b.exponent + @as(i64, @intCast(b.digits.len));
    if (a_scale < b_scale) return .lt;
    if (a_scale > b_scale) return .gt;
    const width = @max(a.digits.len, b.digits.len);
    for (0..width) |index| {
        const a_digit: u8 = if (index < a.digits.len) a.digits[index] else '0';
        const b_digit: u8 = if (index < b.digits.len) b.digits[index] else '0';
        if (a_digit < b_digit) return .lt;
        if (a_digit > b_digit) return .gt;
    }
    return .eq;
}

fn reverseOrder(order: std.math.Order) std.math.Order {
    return switch (order) {
        .lt => .gt,
        .eq => .eq,
        .gt => .lt,
    };
}

fn jsonNonNegativeUsize(value: std.json.Value) ?usize {
    var storage: [number_storage_bytes]u8 = undefined;
    const number = normalizeJsonNumber(value, &storage) orelse return null;
    if (number.negative or !number.isInteger()) return null;
    if (number.isZero()) return 0;
    const exponent: usize = @intCast(number.exponent);
    if (number.digits.len + exponent > 32) return null;
    var result: usize = 0;
    for (number.digits) |digit| {
        result = std.math.mul(usize, result, 10) catch return null;
        result = std.math.add(usize, result, digit - '0') catch return null;
    }
    for (0..exponent) |_| result = std.math.mul(usize, result, 10) catch return null;
    return result;
}

fn jsonInteger(value: std.json.Value) bool {
    var storage: [number_storage_bytes]u8 = undefined;
    const number = normalizeJsonNumber(value, &storage) orelse return false;
    return number.isInteger();
}

fn resolveLocalRef(root: std.json.Value, reference: []const u8) SchemaError!std.json.Value {
    const prefix = "#/$defs/";
    if (!std.mem.startsWith(u8, reference, prefix) or reference.len == prefix.len) {
        return error.InvalidSchema;
    }
    const name = reference[prefix.len..];
    if (std.mem.findScalar(u8, name, '/') != null or std.mem.findScalar(u8, name, '~') != null) {
        return error.InvalidSchema;
    }
    const defs = root.object.get("$defs") orelse return error.InvalidSchema;
    if (defs != .object) return error.InvalidSchema;
    return defs.object.get(name) orelse error.InvalidSchema;
}

fn jsonEqual(a: std.json.Value, b: std.json.Value, budget: *EvaluationBudget) SchemaError!bool {
    try spendEvaluation(budget);
    if (a == .integer or a == .float or a == .number_string) {
        if (b != .integer and b != .float and b != .number_string) return false;
        return (jsonNumberCompare(a, b) orelse return false) == .eq;
    }
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |value| value == b.bool,
        .string => |value| std.mem.eql(u8, value, b.string),
        .array => |array| blk: {
            if (array.items.len != b.array.items.len) break :blk false;
            for (array.items, b.array.items) |left, right| {
                if (!try jsonEqual(left, right, budget)) break :blk false;
            }
            break :blk true;
        },
        .object => |object| blk: {
            if (object.count() != b.object.count()) break :blk false;
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const other = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!try jsonEqual(entry.value_ptr.*, other, budget)) break :blk false;
            }
            break :blk true;
        },
        .integer, .float, .number_string => unreachable,
    };
}

fn writeCanonical(alloc: Allocator, writer: *std.Io.Writer, value: std.json.Value) !void {
    switch (value) {
        .array => |array| {
            try writer.writeByte('[');
            for (array.items, 0..) |item, index| {
                if (index > 0) try writer.writeByte(',');
                try writeCanonical(alloc, writer, item);
            }
            try writer.writeByte(']');
        },
        .object => |object| {
            const keys = try alloc.alloc([]const u8, object.count());
            defer alloc.free(keys);
            var iterator = object.iterator();
            var index: usize = 0;
            while (iterator.next()) |entry| : (index += 1) keys[index] = entry.key_ptr.*;
            std.sort.pdq([]const u8, keys, {}, lessThanStrings);

            try writer.writeByte('{');
            for (keys, 0..) |key, key_index| {
                if (key_index > 0) try writer.writeByte(',');
                try std.json.Stringify.value(key, .{}, writer);
                try writer.writeByte(':');
                try writeCanonical(alloc, writer, object.get(key).?);
            }
            try writer.writeByte('}');
        },
        else => try std.json.Stringify.value(value, .{}, writer),
    }
}

fn lessThanStrings(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

test "structured subscription object schema validator enforces the local strict subset" {
    const alloc = std.testing.allocator;
    const schema_text =
        \\{"type":"object","properties":{"choice":{"type":"string","enum":["low","high"]},"score":{"type":"integer","minimum":0,"maximum":10}},"required":["choice","score"],"additionalProperties":false}
    ;
    var schema = try std.json.parseFromSlice(std.json.Value, alloc, schema_text, .{});
    defer schema.deinit();
    try validateObjectSchema(schema.value, .{});

    var valid = try std.json.parseFromSlice(std.json.Value, alloc, "{\"score\":7,\"choice\":\"low\"}", .{});
    defer valid.deinit();
    try validateValue(schema.value, valid.value, .{});

    var wrong_enum = try std.json.parseFromSlice(std.json.Value, alloc, "{\"choice\":\"medium\",\"score\":7}", .{});
    defer wrong_enum.deinit();
    try std.testing.expectError(error.ValueDoesNotMatchSchema, validateValue(schema.value, wrong_enum.value, .{}));

    var extra = try std.json.parseFromSlice(std.json.Value, alloc, "{\"choice\":\"low\",\"score\":7,\"extra\":true}", .{});
    defer extra.deinit();
    try std.testing.expectError(error.ValueDoesNotMatchSchema, validateValue(schema.value, extra.value, .{}));

    var unsupported = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"type\":\"object\",\"properties\":{},\"required\":[],\"additionalProperties\":false,\"patternProperties\":{}}",
        .{},
    );
    defer unsupported.deinit();
    try std.testing.expectError(error.UnsupportedSchemaKeyword, validateObjectSchema(unsupported.value, .{}));

    const canonical = try canonicalStringify(alloc, schema.value);
    defer alloc.free(canonical);
    try std.testing.expect(std.mem.startsWith(u8, canonical, "{\"additionalProperties\":false,"));
}

test "structured subscription schema compares JSON numbers without integer precision loss" {
    const alloc = std.testing.allocator;
    var schema = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"integer\",\"const\":9007199254740992},\"large\":{\"type\":\"integer\",\"const\":9223372036854775808}},\"required\":[\"id\",\"large\"],\"additionalProperties\":false}",
        .{ .parse_numbers = false },
    );
    defer schema.deinit();
    var valid = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"id\":9007199254740992,\"large\":9223372036854775808}",
        .{ .parse_numbers = false },
    );
    defer valid.deinit();
    try validateValue(schema.value, valid.value, .{});

    var adjacent = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"id\":9007199254740993,\"large\":9223372036854775809}",
        .{ .parse_numbers = false },
    );
    defer adjacent.deinit();
    try std.testing.expectError(
        error.ValueDoesNotMatchSchema,
        validateValue(schema.value, adjacent.value, .{}),
    );
}

test "structured subscription schema rejects untyped keywords and bounds evaluation" {
    const alloc = std.testing.allocator;
    var untyped = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"type\":\"object\",\"properties\":{\"choice\":{\"enum\":[\"a\"],\"minLength\":2}},\"required\":[\"choice\"],\"additionalProperties\":false}",
        .{},
    );
    defer untyped.deinit();
    try std.testing.expectError(error.InvalidSchema, validateObjectSchema(untyped.value, .{}));

    const fanout_schema_text =
        \\{"$defs":{"d0":{"const":1},"d1":{"allOf":[{"$ref":"#/$defs/d0"},{"$ref":"#/$defs/d0"}]},"d2":{"allOf":[{"$ref":"#/$defs/d1"},{"$ref":"#/$defs/d1"}]},"d3":{"allOf":[{"$ref":"#/$defs/d2"},{"$ref":"#/$defs/d2"}]},"d4":{"allOf":[{"$ref":"#/$defs/d3"},{"$ref":"#/$defs/d3"}]}},"type":"object","properties":{"value":{"$ref":"#/$defs/d4"}},"required":["value"],"additionalProperties":false}
    ;
    var fanout_schema = try std.json.parseFromSlice(std.json.Value, alloc, fanout_schema_text, .{});
    defer fanout_schema.deinit();
    var fanout_value = try std.json.parseFromSlice(std.json.Value, alloc, "{\"value\":1}", .{});
    defer fanout_value.deinit();
    try std.testing.expectError(
        error.SchemaLimitExceeded,
        validateValue(fanout_schema.value, fanout_value.value, .{ .max_evaluations = 8 }),
    );
}
