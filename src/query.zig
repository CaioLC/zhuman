//! `query` — the **one catalog query parser** (KIT-14), shared by every catalog view (ACTIONS,
//! BUILD, and the trade/recipe lists). It parses a search string **once** into a bounded set of
//! terms and then matches each row against them **without allocating per row** — the terms are
//! slices into the original query bytes, and matching is pure `[]const u8` comparison.
//!
//! Grammar (a compact, prototype-faithful search language):
//!   - **whitespace-separated terms**, all of which must match (AND across terms);
//!   - **quoted phrases** — `"root cellar"` is one term whose value contains the space; an
//!     unterminated quote runs to end-of-string (malformed-but-usable, never an error);
//!   - **leading negation** — `-fish` (or `-type:tool`) requires the term to *not* match;
//!   - **wildcard** — a bare `*` matches everything (an empty/space value also matches);
//!   - **`field:value`** — restrict a term to one field; unknown fields fall back to free text;
//!   - **comma-OR values** — `type:tool,food` matches tool OR food;
//!   - **case-insensitive** throughout (ASCII lower-fold on compare, no allocation).
//! A term with no field is **free text**, matched against the row's whole presentation
//! **haystack** (substring, case-insensitive).
//!
//! **Fields are parameterized per catalog.** Actions expose `in`/`out`/`type`/`state`/`is`;
//! recipes add `tech`. Aliases collapse synonyms to one field: `input→in`, `output→out`,
//! `kind→type`, `status→state`, and the value alias `built→owned`. Two cross-field rules the
//! prototype relies on: **`state:in-reach`** means *ready or reach ≥ 0.5*, and **`is:`** matches
//! *either* the state or the type. Those semantics live in the row provider (below), so the
//! parser stays a pure tokenizer and the catalog supplies the field values.

const std = @import("std");

/// The catalog fields a query may target. `.free` is the no-field free-text term (the whole
/// haystack). `tech` is recipe-only; a catalog that does not expose it simply never returns a
/// value for it (an always-miss), so one enum serves both catalogs.
pub const Field = enum { free, in, out, type, state, is, tech };

/// Resolve a `field:` token (already lower-folded) to a `Field`, applying the aliases. Returns
/// `null` for an unknown field so the caller treats `unknown:foo` as free text `unknown:foo`.
pub fn fieldOf(token: []const u8) ?Field {
    const map = .{
        .{ "in", Field.in },       .{ "input", Field.in },
        .{ "out", Field.out },     .{ "output", Field.out },
        .{ "type", Field.type },   .{ "kind", Field.type },
        .{ "state", Field.state }, .{ "status", Field.state },
        .{ "is", Field.is },       .{ "tech", Field.tech },
    };
    inline for (map) |entry| {
        if (eqlFold(token, entry[0])) return entry[1];
    }
    return null;
}

/// One parsed term: a field (or `.free`), whether it is negated, and its value (which may hold
/// comma-OR alternatives and, for a phrase, spaces). The value is a slice into the original
/// query bytes — no copy. A `*` value (or empty) is the match-anything wildcard.
pub const Term = struct {
    field: Field = .free,
    negate: bool = false,
    value: []const u8 = "",

    /// Whether this term is the match-anything wildcard (`*` or empty value).
    pub fn isWildcard(self: Term) bool {
        return self.value.len == 0 or std.mem.eql(u8, self.value, "*");
    }
};

/// The maximum number of terms a query holds. Beyond this, extra terms are dropped (a search
/// with more than 16 terms is pathological, not a real query) — bounded, never allocating.
pub const max_terms = 16;

/// A parsed query: a fixed-capacity term list. Built once by `parse`, then matched against many
/// rows with no further allocation.
pub const Query = struct {
    terms: [max_terms]Term = undefined,
    len: usize = 0,

    pub fn slice(self: *const Query) []const Term {
        return self.terms[0..self.len];
    }
};

/// Parse `text` into a `Query`. Splits on whitespace (honoring `"quotes"`), peels a leading `-`
/// as negation, and splits a leading `field:` prefix. All allocation-free — every term value is
/// a slice of `text`, so `text` must outlive the `Query` (it does: the caller holds the search
/// buffer). Malformed input (an unterminated quote, an empty value, a lone `-`) degrades to a
/// usable term rather than an error.
pub fn parse(text: []const u8) Query {
    var q: Query = .{};
    var i: usize = 0;
    while (i < text.len) {
        // Skip whitespace between terms.
        while (i < text.len and isSpace(text[i])) i += 1;
        if (i >= text.len) break;

        var negate = false;
        if (text[i] == '-') {
            negate = true;
            i += 1;
            if (i >= text.len) break; // a lone '-' is nothing
        }

        // A leading `field:` prefix (letters only, then a colon), before any quote.
        var field: Field = .free;
        if (text[i] != '"') {
            var j = i;
            while (j < text.len and isFieldChar(text[j])) j += 1;
            if (j < text.len and text[j] == ':' and j > i) {
                if (fieldOf(text[i..j])) |f| {
                    field = f;
                    i = j + 1; // consume `field:`
                }
                // Unknown field: leave `field = .free` and do NOT consume — the whole
                // `unknown:foo` becomes a free-text value below.
            }
        }

        // The value: a quoted phrase (to the closing quote or end), else up to whitespace.
        var value: []const u8 = "";
        if (i < text.len and text[i] == '"') {
            i += 1;
            const start = i;
            while (i < text.len and text[i] != '"') i += 1;
            value = text[start..i];
            if (i < text.len) i += 1; // consume the closing quote if present
        } else {
            const start = i;
            while (i < text.len and !isSpace(text[i])) i += 1;
            value = text[start..i];
        }

        if (q.len < max_terms) {
            q.terms[q.len] = .{ .field = field, .negate = negate, .value = value };
            q.len += 1;
        }
    }
    return q;
}

/// The value alias fold applied at match time (currently just `built → owned`), so a query
/// value is compared in canonical form. Kept here (not in the parser) because it is a *match*
/// rule, not a tokenization rule.
fn canonicalValue(v: []const u8) []const u8 {
    if (eqlFold(v, "built")) return "owned";
    return v;
}

/// Does `haystack` contain `needle` (case-insensitive), or is `needle` empty/`*` (wildcard)?
/// Substring, allocation-free.
pub fn matchValue(haystack: []const u8, needle: []const u8) bool {
    const n = canonicalValue(needle);
    if (n.len == 0 or std.mem.eql(u8, n, "*")) return true;
    if (n.len > haystack.len) return false;
    var i: usize = 0;
    while (i + n.len <= haystack.len) : (i += 1) {
        if (eqlFold(haystack[i .. i + n.len], n)) return true;
    }
    return false;
}

/// Match one term's value against a field's value, honoring **comma-OR**: the term matches if
/// *any* comma-separated alternative matches `field_value`. A wildcard alternative matches all.
pub fn matchFieldValue(field_value: []const u8, term_value: []const u8) bool {
    var it = std.mem.splitScalar(u8, term_value, ',');
    while (it.next()) |alt| {
        if (matchValue(field_value, alt)) return true;
    }
    return false;
}

/// The row-facing contract (KIT-14). A catalog wraps its row in something that answers a
/// `Field` with the row's text for that field, plus a `haystack` for free text, and the two
/// cross-field facts: `ready`/`reach` (for `state:in-reach`) and the `is:` union of state+type.
/// This is where the catalog-specific semantics live, keeping the parser pure. Duck-typed
/// (`anytype`) so a catalog passes a lightweight struct with these methods; `matches` calls:
///   - `row.text(field) []const u8` — the row's value for a field (empty ⇒ never matches);
///   - `row.haystack() []const u8`  — the whole presentation string for free text;
///   - `row.inReach() bool`         — ready OR reach ≥ 0.5 (the `state:in-reach` rule).
/// `is:` is handled here by matching against *both* the `state` and `type` field texts.
/// Whether `row` matches every term of `q` (AND across terms; comma-OR within a term; negation
/// inverts a term). Allocation-free — the hot path a catalog runs per row.
pub fn matches(q: *const Query, row: anytype) bool {
    for (q.slice()) |term| {
        const hit = termHit(term, row);
        if (hit == term.negate) return false; // negated term that matched, or plain term that missed
    }
    return true;
}

fn termHit(term: Term, row: anytype) bool {
    if (term.isWildcard()) return true;
    return switch (term.field) {
        .free => matchFieldValue(row.haystack(), term.value),
        .is => matchFieldValue(row.text(.state), term.value) or matchFieldValue(row.text(.type), term.value),
        .state => blk: {
            // `state:in-reach` is the cross-field rule (ready or reach ≥ 0.5); any other
            // state value is an ordinary field match.
            var it = std.mem.splitScalar(u8, term.value, ',');
            while (it.next()) |alt| {
                if (eqlFold(alt, "in-reach")) {
                    if (row.inReach()) break :blk true;
                } else if (matchValue(row.text(.state), alt)) {
                    break :blk true;
                }
            }
            break :blk false;
        },
        else => matchFieldValue(row.text(term.field), term.value),
    };
}

// —— small ASCII helpers (allocation-free) ————————————————————————————————————————————————

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}
fn isFieldChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}
fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}
/// Case-insensitive ASCII equality, allocation-free.
pub fn eqlFold(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| if (lower(ca) != lower(cb)) return false;
    return true;
}

// ============================ Tests =====================================================

/// A minimal test row: fixed field texts + an inReach fact + a haystack.
const TestRow = struct {
    name: []const u8 = "",
    in_v: []const u8 = "",
    out_v: []const u8 = "",
    type_v: []const u8 = "",
    state_v: []const u8 = "",
    tech_v: []const u8 = "",
    reachable: bool = false,

    fn text(self: TestRow, f: Field) []const u8 {
        return switch (f) {
            .in => self.in_v,
            .out => self.out_v,
            .type => self.type_v,
            .state => self.state_v,
            .tech => self.tech_v,
            else => "",
        };
    }
    fn haystack(self: TestRow) []const u8 {
        return self.name;
    }
    fn inReach(self: TestRow) bool {
        return self.reachable;
    }
};

test "parse: whitespace terms, negation, field prefix, quotes" {
    const q = parse("  -fish  type:tool  \"root cellar\" ");
    try std.testing.expectEqual(@as(usize, 3), q.len);
    try std.testing.expect(q.terms[0].negate);
    try std.testing.expectEqualStrings("fish", q.terms[0].value);
    try std.testing.expectEqual(Field.type, q.terms[1].field);
    try std.testing.expectEqualStrings("tool", q.terms[1].value);
    try std.testing.expectEqual(Field.free, q.terms[2].field);
    try std.testing.expectEqualStrings("root cellar", q.terms[2].value); // phrase keeps its space
}

test "parse: malformed — unterminated quote runs to end; lone dash and empty are safe" {
    const q = parse("\"unterminated");
    try std.testing.expectEqual(@as(usize, 1), q.len);
    try std.testing.expectEqualStrings("unterminated", q.terms[0].value);

    try std.testing.expectEqual(@as(usize, 0), parse("").len);
    try std.testing.expectEqual(@as(usize, 0), parse("   ").len);
    try std.testing.expectEqual(@as(usize, 0), parse("-").len); // a lone dash is nothing
}

test "fieldOf aliases: input/output/kind/status collapse; unknown is null" {
    try std.testing.expectEqual(Field.in, fieldOf("input").?);
    try std.testing.expectEqual(Field.out, fieldOf("output").?);
    try std.testing.expectEqual(Field.type, fieldOf("kind").?);
    try std.testing.expectEqual(Field.state, fieldOf("status").?);
    try std.testing.expectEqual(Field.tech, fieldOf("tech").?);
    try std.testing.expect(fieldOf("bogus") == null);
}

test "match: free text searches the haystack, case-insensitive" {
    const row = TestRow{ .name = "Split Wood" };
    try std.testing.expect(matches(&parse("wood"), row));
    try std.testing.expect(matches(&parse("SPLIT"), row));
    try std.testing.expect(!matches(&parse("fish"), row));
}

test "match: negation inverts a term" {
    const row = TestRow{ .name = "Forage", .type_v = "labor" };
    try std.testing.expect(matches(&parse("-fish"), row)); // does not contain fish ⇒ matches
    try std.testing.expect(!matches(&parse("-forage"), row)); // contains forage ⇒ negated miss
    try std.testing.expect(!matches(&parse("-type:labor"), row)); // is labor ⇒ negated miss
}

test "match: wildcard matches everything" {
    const row = TestRow{ .name = "anything" };
    try std.testing.expect(matches(&parse("*"), row));
    try std.testing.expect(matches(&parse("type:*"), row));
}

test "match: field:value with comma-OR" {
    const tool = TestRow{ .type_v = "tool" };
    const food = TestRow{ .type_v = "food" };
    const other = TestRow{ .type_v = "structure" };
    const q = parse("type:tool,food");
    try std.testing.expect(matches(&q, tool));
    try std.testing.expect(matches(&q, food));
    try std.testing.expect(!matches(&q, other));
}

test "match: phrase term matches a multi-word field/haystack" {
    const row = TestRow{ .name = "You dig a root cellar" };
    try std.testing.expect(matches(&parse("\"root cellar\""), row));
    try std.testing.expect(!matches(&parse("\"root shed\""), row));
}

test "match: state:in-reach means ready or reach>=0.5; built aliases owned" {
    const reachable = TestRow{ .state_v = "locked", .reachable = true };
    const stuck = TestRow{ .state_v = "locked", .reachable = false };
    try std.testing.expect(matches(&parse("state:in-reach"), reachable));
    try std.testing.expect(!matches(&parse("state:in-reach"), stuck));
    // `built` folds to `owned` before comparison.
    const owned = TestRow{ .state_v = "owned" };
    try std.testing.expect(matches(&parse("state:built"), owned));
}

test "match: is: matches either state or type" {
    const by_state = TestRow{ .state_v = "ready", .type_v = "tool" };
    try std.testing.expect(matches(&parse("is:ready"), by_state)); // via state
    try std.testing.expect(matches(&parse("is:tool"), by_state)); // via type
    try std.testing.expect(!matches(&parse("is:food"), by_state));
}

test "match: combined fields AND together" {
    const row = TestRow{ .name = "Fish", .type_v = "labor", .out_v = "food", .reachable = true };
    try std.testing.expect(matches(&parse("type:labor out:food state:in-reach"), row));
    try std.testing.expect(!matches(&parse("type:labor out:materials"), row)); // out mismatch
    try std.testing.expect(matches(&parse("fish -type:tool"), row)); // free hit + negated miss
}
