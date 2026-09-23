const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const fontconfig = @import("fontconfig");
const macos = @import("macos");
const opentype = @import("opentype.zig");
const options = @import("main.zig").options;
const Collection = @import("main.zig").Collection;
const DeferredFace = @import("main.zig").DeferredFace;
const Face = @import("main.zig").Face;
const Library = @import("main.zig").Library;
const Presentation = @import("main.zig").Presentation;
const Variation = @import("main.zig").face.Variation;
const global = @import("../global.zig");

const log = std.log.scoped(.discovery);

/// Discover implementation for the compile options.
pub const Discover = switch (options.backend) {
    .freetype => void, // no discovery
    .freetype_windows => Windows,
    .fontconfig_freetype => Fontconfig,
    .web_canvas => void, // no discovery
    .coretext,
    .coretext_freetype,
    .coretext_harfbuzz,
    .coretext_noshape,
    => CoreText,
};

/// Descriptor is used to search for fonts. The only required field
/// is "family". The rest are ignored unless they're set to a non-zero
/// value.
pub const Descriptor = struct {
    /// Font family to search for. This can be a fully qualified font
    /// name such as "Fira Code", "monospace", "serif", etc. Memory is
    /// owned by the caller and should be freed when this descriptor
    /// is no longer in use. The discovery structs will never store the
    /// descriptor.
    ///
    /// On systems that use fontconfig (Linux), this can be a full
    /// fontconfig pattern, such as "Fira Code-14:bold".
    family: ?[:0]const u8 = null,

    /// Specific font style to search for. This will filter the style
    /// string the font advertises. The "bold/italic" booleans later in this
    /// struct filter by the style trait the font has, not the string, so
    /// these can be used in conjunction or not.
    style: ?[:0]const u8 = null,

    /// A codepoint that this font must be able to render.
    codepoint: u32 = 0,

    /// Font size in points that the font should support. For conversion
    /// to pixels, we will use 72 DPI for Mac and 96 DPI for everything else.
    /// (If pixel conversion is necessary, i.e. emoji fonts)
    size: f32 = 0,

    /// True if we want to search specifically for a font that supports
    /// specific styles.
    bold: bool = false,
    italic: bool = false,
    monospace: bool = false,

    /// Variation axes to apply to the font. This also impacts searching
    /// for fonts since fonts with the ability to set these variations
    /// will be preferred, but not guaranteed.
    variations: []const Variation = &.{},

    /// Hash the descriptor with the given hasher.
    pub fn hash(self: Descriptor, hasher: anytype) void {
        const autoHash = std.hash.autoHash;
        const autoHashStrat = std.hash.autoHashStrat;
        autoHashStrat(hasher, self.family, .Deep);
        autoHashStrat(hasher, self.style, .Deep);
        autoHash(hasher, self.codepoint);
        autoHash(hasher, @as(u32, @bitCast(self.size)));
        autoHash(hasher, self.bold);
        autoHash(hasher, self.italic);
        autoHash(hasher, self.monospace);
        autoHash(hasher, self.variations.len);
        for (self.variations) |variation| {
            autoHash(hasher, variation.id);

            // This is not correct, but we don't currently depend on the
            // hash value being different based on decimal values of variations.
            autoHash(hasher, @as(i64, @intFromFloat(variation.value)));
        }
    }

    /// Returns a hash code that can be used to uniquely identify this
    /// action.
    pub fn hashcode(self: Descriptor) u64 {
        var hasher = std.hash.Wyhash.init(0);
        self.hash(&hasher);
        return hasher.final();
    }

    /// Deep copy of the struct. The given allocator is expected to
    /// be an arena allocator of some sort since the descriptor
    /// itself doesn't support fine-grained deallocation of fields.
    pub fn clone(self: *const Descriptor, alloc: Allocator) !Descriptor {
        // We can't do any errdefer cleanup in here. As documented we
        // expect the allocator to be an arena so any errors should be
        // cleaned up somewhere else.

        var copy = self.*;
        copy.family = if (self.family) |src| try alloc.dupeZ(u8, src) else null;
        copy.style = if (self.style) |src| try alloc.dupeZ(u8, src) else null;
        copy.variations = try alloc.dupe(Variation, self.variations);
        return copy;
    }

    /// Convert to Fontconfig pattern to use for lookup. The pattern does
    /// not have defaults filled/substituted (Fontconfig thing) so callers
    /// must still do this.
    pub fn toFcPattern(self: Descriptor) *fontconfig.Pattern {
        const pat = fontconfig.Pattern.create();
        if (self.family) |family| {
            assert(pat.add(.family, .{ .string = family }, false));
        }
        if (self.style) |style| {
            assert(pat.add(.style, .{ .string = style }, false));
        }
        if (self.codepoint > 0) {
            const cs = fontconfig.CharSet.create();
            defer cs.destroy();
            assert(cs.addChar(self.codepoint));
            assert(pat.add(.charset, .{ .char_set = cs }, false));
        }
        if (self.size > 0) assert(pat.add(
            .size,
            .{ .integer = @intFromFloat(@round(self.size)) },
            false,
        ));
        if (self.bold) assert(pat.add(
            .weight,
            .{ .integer = @intFromEnum(fontconfig.Weight.bold) },
            false,
        ));
        if (self.italic) assert(pat.add(
            .slant,
            .{ .integer = @intFromEnum(fontconfig.Slant.italic) },
            false,
        ));

        // For fontconfig, we always add monospace in the pattern. Since
        // fontconfig sorts by closeness to the pattern, this doesn't fully
        // exclude non-monospace but helps prefer it.
        assert(pat.add(
            .spacing,
            .{ .integer = @intFromEnum(fontconfig.Spacing.mono) },
            false,
        ));

        return pat;
    }

    /// Convert to Core Text font descriptor to use for lookup or
    /// conversion to a specific font.
    pub fn toCoreTextDescriptor(self: Descriptor) !*macos.text.FontDescriptor {
        const attrs = try macos.foundation.MutableDictionary.create(0);
        defer attrs.release();

        // Family
        if (self.family) |family_bytes| {
            const family = try macos.foundation.String.createWithBytes(family_bytes, .utf8, false);
            defer family.release();
            attrs.setValue(
                macos.text.FontAttribute.family_name.key(),
                family,
            );
        }

        // Style
        if (self.style) |style_bytes| {
            const style = try macos.foundation.String.createWithBytes(style_bytes, .utf8, false);
            defer style.release();
            attrs.setValue(
                macos.text.FontAttribute.style_name.key(),
                style,
            );
        }

        // Codepoint support
        if (self.codepoint > 0) {
            const cs = try macos.foundation.CharacterSet.createWithCharactersInRange(.{
                .location = self.codepoint,
                .length = 1,
            });
            defer cs.release();
            attrs.setValue(
                macos.text.FontAttribute.character_set.key(),
                cs,
            );
        }

        // Set our size attribute if set
        if (self.size > 0) {
            const size32: i32 = @intFromFloat(@round(self.size));
            const size = try macos.foundation.Number.create(
                .sint32,
                &size32,
            );
            defer size.release();
            attrs.setValue(
                macos.text.FontAttribute.size.key(),
                size,
            );
        }

        // Build our traits. If we set any, then we store it in the attributes
        // otherwise we do nothing. We determine this by setting up the packed
        // struct, converting to an int, and checking if it is non-zero.
        const traits: macos.text.FontSymbolicTraits = .{
            .bold = self.bold,
            .italic = self.italic,
            .monospace = self.monospace,
        };
        const traits_cval: u32 = @bitCast(traits);
        if (traits_cval > 0) {
            // Setting traits is a pain. We have to create a nested dictionary
            // of the symbolic traits value, and set that in our attributes.
            const traits_num = try macos.foundation.Number.create(
                .sint32,
                @as(*const i32, @ptrCast(&traits_cval)),
            );
            defer traits_num.release();

            const traits_dict = try macos.foundation.MutableDictionary.create(0);
            defer traits_dict.release();
            traits_dict.setValue(
                macos.text.FontTraitKey.symbolic.key(),
                traits_num,
            );

            attrs.setValue(
                macos.text.FontAttribute.traits.key(),
                traits_dict,
            );
        }

        return try macos.text.FontDescriptor.createWithAttributes(@ptrCast(attrs));
    }
};

pub const Fontconfig = struct {
    fc_config: *fontconfig.Config,

    pub fn init(lib: Library) Fontconfig {
        _ = lib;
        // safe to call multiple times and concurrently
        _ = fontconfig.init();
        return .{ .fc_config = fontconfig.initLoadConfigAndFonts() };
    }

    pub fn deinit(self: *Fontconfig) void {
        self.fc_config.destroy();
    }

    /// Discover fonts from a descriptor. This returns an iterator that can
    /// be used to build up the deferred fonts.
    pub fn discover(
        self: *const Fontconfig,
        alloc: Allocator,
        desc: Descriptor,
    ) !DiscoverIterator {
        _ = alloc;

        // Build our pattern that we'll search for
        const pat = desc.toFcPattern();
        errdefer pat.destroy();
        assert(self.fc_config.substituteWithPat(pat, .pattern));
        pat.defaultSubstitute();

        // Search
        const res = self.fc_config.fontSort(pat, false, null);
        if (res.result != .match) return error.FontConfigFailed;
        errdefer res.fs.destroy();

        return .{
            .config = self.fc_config,
            .pattern = pat,
            .set = res.fs,
            .fonts = res.fs.fonts(),
            .variations = desc.variations,
            .i = 0,
        };
    }

    pub fn discoverFallback(
        self: *const Fontconfig,
        alloc: Allocator,
        collection: *Collection,
        desc: Descriptor,
    ) !DiscoverIterator {
        _ = collection;
        return try self.discover(alloc, desc);
    }

    pub const DiscoverIterator = struct {
        config: *fontconfig.Config,
        pattern: *fontconfig.Pattern,
        set: *fontconfig.FontSet,
        fonts: []*fontconfig.Pattern,
        variations: []const Variation,
        i: usize,

        pub fn deinit(self: *DiscoverIterator) void {
            self.set.destroy();
            self.pattern.destroy();
            self.* = undefined;
        }

        pub fn next(self: *DiscoverIterator) fontconfig.Error!?DeferredFace {
            if (self.i >= self.fonts.len) return null;

            // Get the copied pattern from our fontset that has the
            // attributes configured for rendering.
            const font_pattern = try self.config.fontRenderPrepare(
                self.pattern,
                self.fonts[self.i],
            );
            errdefer font_pattern.destroy();

            // Increment after we return
            defer self.i += 1;

            return DeferredFace{
                .fc = .{
                    .pattern = font_pattern,
                    .charset = (try font_pattern.get(.charset, 0)).char_set,
                    .langset = (try font_pattern.get(.lang, 0)).lang_set,
                    .variations = self.variations,
                },
            };
        }
    };
};

pub const CoreText = struct {
    pub fn init(lib: Library) CoreText {
        _ = lib;
        // Required for the "interface" but does nothing for CoreText.
        return .{};
    }

    pub fn deinit(self: *CoreText) void {
        _ = self;
    }

    /// Warm up the system font registry.
    ///
    /// The first CoreText query in a process initializes the system font
    /// database, which takes multiple milliseconds, while subsequent
    /// queries are microseconds.
    pub fn warmup() void {
        const name = macos.foundation.String.createWithBytes(
            "AppleColorEmoji",
            .utf8,
            false,
        ) catch return;
        defer name.release();
        const ct_font = macos.text.Font.createWithName(name, 12) catch return;
        ct_font.release();
    }

    /// Discover fonts from a descriptor. This returns an iterator that can
    /// be used to build up the deferred fonts.
    pub fn discover(self: *const CoreText, alloc: Allocator, desc: Descriptor) !DiscoverIterator {
        _ = self;

        // Build our pattern that we'll search for
        const ct_desc = try desc.toCoreTextDescriptor();
        defer ct_desc.release();

        // Our descriptors have to be in an array
        var ct_desc_arr = [_]*const macos.text.FontDescriptor{ct_desc};
        const desc_arr = try macos.foundation.Array.create(macos.text.FontDescriptor, &ct_desc_arr);
        defer desc_arr.release();

        // Build our collection
        const set = try macos.text.FontCollection.createWithFontDescriptors(desc_arr);
        defer set.release();
        const list = set.createMatchingFontDescriptors();
        defer list.release();

        // Sort our descriptors
        const zig_list = try copyMatchingDescriptors(alloc, list);
        errdefer alloc.free(zig_list);
        sortMatchingDescriptors(&desc, zig_list);

        return DiscoverIterator{
            .alloc = alloc,
            .list = zig_list,
            .variations = desc.variations,
            .i = 0,
        };
    }

    /// Discover a font by its exact name (family, full, or PostScript
    /// name). This is significantly faster than `discover` because it
    /// avoids the system-wide font matching that CTFontCollection does
    /// (which takes multiple milliseconds). This should be preferred
    /// when the desired font is known exactly, e.g. system fonts such
    /// as Apple Color Emoji.
    ///
    /// Returns null if no font with this exact family name exists;
    /// CoreText fallback fonts are never returned.
    pub fn discoverExactFamily(
        self: *const CoreText,
        family: []const u8,
    ) !?DeferredFace {
        _ = self;

        const family_str = try macos.foundation.String.createWithBytes(
            family,
            .utf8,
            false,
        );
        defer family_str.release();

        // Create our font. We need a size to initialize it so we use size
        // 12 but we will alter the size later (same as DiscoverIterator).
        const ct_font = try macos.text.Font.createWithName(family_str, 12);

        // CTFontCreateWithName never returns null: if the requested font
        // isn't installed it returns a substitute font. Verify we got
        // the family we asked for, otherwise report not found.
        const found: bool = found: {
            const actual = ct_font.copyFamilyName();
            defer actual.release();
            var buf: [256]u8 = undefined;
            const actual_slice = actual.cstring(&buf, .utf8) orelse
                break :found false;
            break :found std.mem.eql(u8, actual_slice, family);
        };
        if (!found) {
            ct_font.release();
            return null;
        }

        return .{ .ct = .{
            .font = ct_font,
            .variations = &.{},
        } };
    }

    pub fn discoverFallback(
        self: *const CoreText,
        alloc: Allocator,
        collection: *Collection,
        desc: Descriptor,
    ) !DiscoverIterator {
        // If we have a codepoint within the CJK unified ideographs block
        // then we fallback to macOS to find a font that supports it because
        // there isn't a better way manually with CoreText that I can find that
        // properly takes into account system locale.
        //
        // References:
        // - http://unicode.org/charts/PDF/U4E00.pdf
        // - https://chromium.googlesource.com/chromium/src/+/main/third_party/blink/renderer/platform/fonts/LocaleInFonts.md#unified-han-ideographs
        if (desc.codepoint >= 0x4E00 and
            desc.codepoint <= 0x9FFF)
        han: {
            const han = try self.discoverCodepoint(
                collection,
                desc,
            ) orelse break :han;

            // This is silly but our discover iterator needs a slice so
            // we allocate here. This isn't a performance bottleneck but
            // this is something we can optimize very easily...
            const list = try alloc.alloc(*macos.text.FontDescriptor, 1);
            errdefer alloc.free(list);
            list[0] = han;

            return DiscoverIterator{
                .alloc = alloc,
                .list = list,
                .variations = desc.variations,
                .i = 0,
            };
        }

        const it = try self.discover(alloc, desc);

        // If our normal discovery doesn't find anything and we have a specific
        // codepoint, then fallback to using CTFontCreateForString to find a
        // matching font CoreText wants to use. See:
        // https://github.com/ghostty-org/ghostty/issues/2499
        if (it.list.len == 0 and desc.codepoint > 0) codepoint: {
            const ct_desc = try self.discoverCodepoint(
                collection,
                desc,
            ) orelse break :codepoint;

            const list = try alloc.alloc(*macos.text.FontDescriptor, 1);
            errdefer alloc.free(list);
            list[0] = ct_desc;

            return DiscoverIterator{
                .alloc = alloc,
                .list = list,
                .variations = desc.variations,
                .i = 0,
            };
        }

        return it;
    }

    /// Discover a font for a specific codepoint using the CoreText
    /// CTFontCreateForString API.
    fn discoverCodepoint(
        self: *const CoreText,
        collection: *Collection,
        desc: Descriptor,
    ) !?*macos.text.FontDescriptor {
        _ = self;

        if (comptime options.backend.hasFreetype()) {
            // If we have freetype, we can't use CoreText to find a font
            // that supports a specific codepoint because we need to
            // have a CoreText font to be able to do so.
            return null;
        }

        assert(desc.codepoint > 0);

        // Get our original font. This is dependent on the requested style
        // from the descriptor.
        const original = original: {
            // In all the styles below, we try to match it but if we don't
            // we always fall back to some other option. The order matters
            // here.

            if (desc.bold and desc.italic) {
                const entries = collection.faces.get(.bold_italic);
                if (entries.count() > 0) {
                    break :original try collection.getFace(.{ .style = .bold_italic });
                }
            }

            if (desc.bold) {
                const entries = collection.faces.get(.bold);
                if (entries.count() > 0) {
                    break :original try collection.getFace(.{ .style = .bold });
                }
            }

            if (desc.italic) {
                const entries = collection.faces.get(.italic);
                if (entries.count() > 0) {
                    break :original try collection.getFace(.{ .style = .italic });
                }
            }

            break :original try collection.getFace(.{ .style = .regular });
        };

        // We need it in utf8 format
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(
            @intCast(desc.codepoint),
            &buf,
        );

        // We need a CFString
        const str = try macos.foundation.String.createWithBytes(
            buf[0..len],
            .utf8,
            false,
        );
        defer str.release();

        // Get our range length for CTFontCreateForString. It looks like
        // the range uses UTF-16 codepoints and not UTF-32 codepoints.
        const range_len: usize = range_len: {
            var unichars: [2]u16 = undefined;
            const pair = macos.foundation.stringGetSurrogatePairForLongCharacter(
                desc.codepoint,
                &unichars,
            );
            break :range_len if (pair) 2 else 1;
        };

        // Get our font
        const font = original.font.createForString(
            str,
            macos.foundation.Range.init(0, range_len),
        ) orelse return null;
        defer font.release();

        // Do not allow the last resort font to go through. This is the
        // last font used by CoreText if it can't find anything else and
        // only contains replacement characters.
        last_resort: {
            const name_str = font.copyPostScriptName();
            defer name_str.release();

            // If the name doesn't fit in our buffer, then it can't
            // be the last resort font so we break out.
            var name_buf: [64]u8 = undefined;
            const name: []const u8 = name_str.cstring(&name_buf, .utf8) orelse
                break :last_resort;

            // If the name is "LastResort" then we don't want to use it.
            if (std.mem.eql(u8, "LastResort", name)) return null;
        }

        // Get the descriptor
        return font.copyDescriptor();
    }

    fn copyMatchingDescriptors(
        alloc: Allocator,
        list: *macos.foundation.Array,
    ) ![]*macos.text.FontDescriptor {
        var result = try alloc.alloc(*macos.text.FontDescriptor, list.getCount());
        errdefer alloc.free(result);
        for (0..result.len) |i| {
            result[i] = list.getValueAtIndex(macos.text.FontDescriptor, i);

            // We need to retain because once the list is freed it will
            // release all its members.
            result[i].retain();
        }
        return result;
    }

    fn sortMatchingDescriptors(
        desc: *const Descriptor,
        list: []*macos.text.FontDescriptor,
    ) void {
        std.mem.sortUnstable(*macos.text.FontDescriptor, list, desc, struct {
            fn lessThan(
                desc_inner: *const Descriptor,
                lhs: *macos.text.FontDescriptor,
                rhs: *macos.text.FontDescriptor,
            ) bool {
                const lhs_score: Score = .score(desc_inner, lhs);
                const rhs_score: Score = .score(desc_inner, rhs);
                // Higher score is "less" (earlier)
                return lhs_score.int() > rhs_score.int();
            }
        }.lessThan);
    }

    /// We represent our sorting score as a packed struct so that we
    /// can compare scores numerically but build scores symbolically.
    ///
    /// Note that packed structs store their fields from least to most
    /// significant, so the fields here are defined in increasing order
    /// of precedence.
    const Score = packed struct {
        const Backing = @typeInfo(@This()).@"struct".backing_integer.?;

        /// Number of glyphs in the font, if two fonts have identical
        /// scores otherwise then we prefer the one with more glyphs.
        ///
        /// (Number of glyphs clamped at u16 intmax)
        glyph_count: u16 = 0,
        /// A fuzzy match on the style string, less important than
        /// an exact match, and less important than trait matches.
        fuzzy_style: u8 = 0,
        /// Whether the bold-ness of the font matches the descriptor.
        /// This is less important than italic because a font that's italic
        /// when it shouldn't be or not italic when it should be is a bigger
        /// problem (subjectively) than being the wrong weight.
        bold: bool = false,
        /// Whether the italic-ness of the font matches the descriptor.
        /// This is less important than an exact match on the style string
        /// because we want users to be allowed to override trait matching
        /// for the bold/italic/bold italic styles if they want.
        italic: bool = false,
        /// An exact (case-insensitive) match on the style string.
        exact_style: bool = false,
        /// Whether the font is monospace, this is more important than any of
        /// the other fields unless we're looking for a specific codepoint,
        /// in which case that is the most important thing.
        monospace: bool = false,
        /// If we're looking for a codepoint, whether this font has it.
        codepoint: bool = false,

        pub fn int(self: Score) Backing {
            return @bitCast(self);
        }

        fn score(desc: *const Descriptor, ct_desc: *const macos.text.FontDescriptor) Score {
            var self: Score = .{};

            // We always load the font if we can since some things can only be
            // inspected on the font itself. Fonts that can't be loaded score
            // 0 automatically because we don't want a font we can't load.
            const font: *macos.text.Font = macos.text.Font.createWithFontDescriptor(
                ct_desc,
                12,
            ) catch return self;
            defer font.release();

            // We prefer fonts with more glyphs, all else being equal.
            {
                const Type = @TypeOf(self.glyph_count);
                self.glyph_count = std.math.cast(
                    Type,
                    font.getGlyphCount(),
                ) orelse std.math.maxInt(Type);
            }

            // If we're searching for a codepoint, then we
            // prioritize fonts that have that codepoint.
            if (desc.codepoint > 0) {
                // Turn UTF-32 into UTF-16 for CT API
                var unichars: [2]u16 = undefined;
                const pair = macos.foundation.stringGetSurrogatePairForLongCharacter(
                    desc.codepoint,
                    &unichars,
                );
                const len: usize = if (pair) 2 else 1;

                // Get our glyphs
                var glyphs = [2]macos.graphics.Glyph{ 0, 0 };
                self.codepoint = font.getGlyphsForCharacters(
                    unichars[0..len],
                    glyphs[0..len],
                );
            }

            // Get our symbolic traits for the descriptor so we can
            // compare boolean attributes like bold, monospace, etc.
            const symbolic_traits: macos.text.FontSymbolicTraits = traits: {
                const traits = ct_desc.copyAttribute(.traits) orelse break :traits .{};
                defer traits.release();

                const key = macos.text.FontTraitKey.symbolic.key();
                const symbolic = traits.getValue(macos.foundation.Number, key) orelse
                    break :traits .{};

                break :traits macos.text.FontSymbolicTraits.init(symbolic);
            };

            self.monospace = symbolic_traits.monospace;

            // We try to derived data from the font itself, which is generally
            // more reliable than only using the symbolic traits for this.
            const is_bold: bool, const is_italic: bool = derived: {
                // We start with initial guesses based on the symbolic traits,
                // but refine these with more information if we can get it.
                var is_italic = symbolic_traits.italic;
                var is_bold = symbolic_traits.bold;

                // Read the 'head' table out of the font data if it's available.
                if (head: {
                    const tag = macos.text.FontTableTag.init("head");
                    const data = font.copyTable(tag) orelse break :head null;
                    defer data.release();
                    const ptr = data.getPointer();
                    const len = data.getLength();
                    break :head opentype.Head.init(ptr[0..len]) catch |err| {
                        log.warn("error parsing head table: {}", .{err});
                        break :head null;
                    };
                }) |head_| {
                    const head: opentype.Head = head_;
                    is_bold = is_bold or (head.macStyle & 1 == 1);
                    is_italic = is_italic or (head.macStyle & 2 == 2);
                }

                // Read the 'OS/2' table out of the font data if it's available.
                if (os2: {
                    const tag = macos.text.FontTableTag.init("OS/2");
                    const data = font.copyTable(tag) orelse break :os2 null;
                    defer data.release();
                    const ptr = data.getPointer();
                    const len = data.getLength();
                    break :os2 opentype.OS2.init(ptr[0..len]) catch |err| {
                        log.warn("error parsing OS/2 table: {}", .{err});
                        break :os2 null;
                    };
                }) |os2| {
                    is_bold = is_bold or os2.fsSelection.bold;
                    is_italic = is_italic or os2.fsSelection.italic;
                }

                // Check if we have variation axes in our descriptor, if we
                // do then we can derive weight italic-ness or both from them.
                if (font.copyAttribute(.variation_axes)) |axes| variations: {
                    defer axes.release();

                    // Copy the variation values for this instance of the font.
                    // if there are none then we just break out immediately.
                    const values: *macos.foundation.Dictionary =
                        font.copyAttribute(.variation) orelse break :variations;
                    defer values.release();

                    var buf: [1024]u8 = undefined;

                    // If we see the 'ital' value then we ignore 'slnt'.
                    var ital_seen = false;

                    const len = axes.getCount();
                    for (0..len) |i| {
                        const dict = axes.getValueAtIndex(macos.foundation.Dictionary, i);
                        const Key = macos.text.FontVariationAxisKey;
                        const cf_id = dict.getValue(Key.identifier.Value(), Key.identifier.key()).?;
                        const cf_name = dict.getValue(Key.name.Value(), Key.name.key()).?;
                        const cf_def = dict.getValue(Key.default_value.Value(), Key.default_value.key()).?;

                        const name_str = cf_name.cstring(&buf, .utf8) orelse "";

                        // Default value
                        var def: f64 = 0;
                        _ = cf_def.getValue(.double, &def);
                        // Value in this font
                        var val: f64 = def;
                        if (values.getValue(
                            macos.foundation.Number,
                            cf_id,
                        )) |cf_val| _ = cf_val.getValue(.double, &val);

                        if (std.mem.eql(u8, "wght", name_str)) {
                            // Somewhat subjective threshold, we consider fonts
                            // bold if they have a 'wght' set greater than 600.
                            is_bold = val > 600;
                            continue;
                        }
                        if (std.mem.eql(u8, "ital", name_str)) {
                            is_italic = val > 0.5;
                            ital_seen = true;
                            continue;
                        }
                        if (!ital_seen and std.mem.eql(u8, "slnt", name_str)) {
                            // Arbitrary threshold of anything more than a 5
                            // degree clockwise slant is considered italic.
                            is_italic = val <= -5.0;
                            continue;
                        }
                    }
                }

                break :derived .{ is_bold, is_italic };
            };

            self.bold = desc.bold == is_bold;
            self.italic = desc.italic == is_italic;

            // Get the style string from the font.
            var style_str_buf: [128]u8 = undefined;
            const style_str: []const u8 = style_str: {
                const style = ct_desc.copyAttribute(.style_name) orelse
                    break :style_str "";
                defer style.release();

                break :style_str style.cstring(&style_str_buf, .utf8) orelse "";
            };

            // The first string in this slice will be used for the exact match,
            // and for the fuzzy match, all matching substrings will increase
            // the rank.
            const desired_styles: []const [:0]const u8 = desired: {
                if (desc.style) |s| break :desired &.{s};

                // If we don't have an explicitly desired style name, we base
                // it on the bold and italic properties, this isn't ideal since
                // fonts may use style names other than these, but it helps in
                // some edge cases.
                if (desc.bold) {
                    if (desc.italic) break :desired &.{ "bold italic", "bold", "italic", "oblique" };
                    break :desired &.{ "bold", "upright" };
                } else if (desc.italic) {
                    break :desired &.{ "italic", "regular", "oblique" };
                }
                break :desired &.{ "regular", "upright" };
            };

            self.exact_style = std.ascii.eqlIgnoreCase(
                style_str,
                desired_styles[0],
            );
            // Our "fuzzy match" score is 0 if the desired style isn't present
            // in the string, otherwise we give higher priority for styles that
            // have fewer characters not in the desired_styles list.
            const fuzzy_type = @TypeOf(self.fuzzy_style);
            self.fuzzy_style = @intCast(style_str.len);
            for (desired_styles) |s| {
                if (std.ascii.indexOfIgnoreCase(style_str, s) != null) {
                    self.fuzzy_style -|= @intCast(s.len);
                }
            }
            self.fuzzy_style = std.math.maxInt(fuzzy_type) -| self.fuzzy_style;

            return self;
        }
    };

    pub const DiscoverIterator = struct {
        alloc: Allocator,
        list: []const *macos.text.FontDescriptor,
        variations: []const Variation,
        i: usize,

        pub fn deinit(self: *DiscoverIterator) void {
            for (self.list) |desc| {
                desc.release();
            }
            self.alloc.free(self.list);
            self.* = undefined;
        }

        pub fn next(self: *DiscoverIterator) !?DeferredFace {
            if (self.i >= self.list.len) return null;

            // Get our descriptor. We need to remove the character set
            // limitation because we may have used that to filter but we
            // don't want it anymore because it'll restrict the characters
            // available.
            const desc = desc: {
                // We create a copy, overwriting the character set attribute.
                const attrs = try macos.foundation.MutableDictionary.create(0);
                defer attrs.release();

                attrs.setValue(
                    macos.text.FontAttribute.character_set.key(),
                    macos.c.kCFNull,
                );

                break :desc try macos.text.FontDescriptor.createCopyWithAttributes(
                    self.list[self.i],
                    @ptrCast(attrs),
                );
            };
            defer desc.release();

            // Create our font. We need a size to initialize it so we use size
            // 12 but we will alter the size later.
            const font = try macos.text.Font.createWithFontDescriptor(desc, 12);
            errdefer font.release();

            // Increment after we return
            defer self.i += 1;

            return DeferredFace{
                .ct = .{
                    .font = font,
                    .variations = self.variations,
                },
            };
        }
    };
};

/// Windows font discovery. A process-global index of every face in the
/// system and per-user font directories (plus the fonts registered in
/// the registry) is built on first use and then scored per request.
pub const Windows = struct {
    const freetype = @import("freetype");

    lib: Library,

    pub fn init(lib: Library) Windows {
        return .{ .lib = lib };
    }

    pub fn deinit(self: *Windows) void {
        _ = self;
    }

    pub fn discover(
        self: *const Windows,
        alloc: Allocator,
        desc: Descriptor,
    ) !DiscoverIterator {
        return try self.search(alloc, desc, false);
    }

    pub fn discoverFallback(
        self: *const Windows,
        alloc: Allocator,
        collection: *Collection,
        desc: Descriptor,
    ) !DiscoverIterator {
        _ = collection;
        return try self.search(alloc, desc, true);
    }

    fn search(
        self: *const Windows,
        alloc: Allocator,
        desc: Descriptor,
        fallback: bool,
    ) !DiscoverIterator {
        const index = try Index.get();
        const curated: []const []const u8 = if (fallback and desc.codepoint != 0)
            curatedFallback(desc.codepoint, index.locale)
        else
            &.{};

        var candidates: std.ArrayList(Candidate) = .empty;
        errdefer candidates.deinit(alloc);
        for (index.entries, 0..) |*entry, i| {
            if (desc.codepoint != 0 and !entry.coverage.mayHave(desc.codepoint)) continue;
            const s = Score.score(&desc, entry, curated) orelse continue;
            try candidates.append(alloc, .{ .entry = @intCast(i), .score = s });
        }
        std.mem.sort(Candidate, candidates.items, {}, Candidate.greaterThan);

        return .{
            .alloc = alloc,
            .lib = self.lib,
            .entries = index.entries,
            .candidates = try candidates.toOwnedSlice(alloc),
            .codepoint = desc.codepoint,
            .variations = desc.variations,
        };
    }

    const Candidate = struct {
        entry: u32,
        score: Score,

        fn greaterThan(_: void, a: Candidate, b: Candidate) bool {
            return a.score.int() > b.score.int();
        }
    };

    const Score = packed struct {
        const Backing = @typeInfo(@This()).@"struct".backing_integer.?;

        weight: u10 = 0,
        fuzzy_style: u8 = 0,
        bold: bool = false,
        italic: bool = false,
        exact_style: bool = false,
        variable: bool = false,
        monospace: bool = false,
        family: u2 = 0,
        curated: u5 = 0,

        fn int(self: Score) Backing {
            return @bitCast(self);
        }

        fn score(
            desc: *const Descriptor,
            entry: *const Entry,
            curated: []const []const u8,
        ) ?Score {
            var self: Score = .{};

            if (desc.family) |family| {
                if (std.ascii.eqlIgnoreCase(entry.family, family)) {
                    self.family = 2;
                } else if (entry.hasAltName(family)) {
                    self.family = 1;
                } else return null;
            }

            if (desc.style == null) {
                if (desc.bold and !entry.bold) return null;
                if (desc.italic and !entry.italic) return null;
            }

            for (curated, 0..) |name, i| {
                if (std.ascii.eqlIgnoreCase(entry.family, name) or
                    entry.hasAltName(name))
                {
                    self.curated = @intCast(curated.len - i);
                    break;
                }
            }

            self.monospace = desc.monospace and entry.monospace;
            self.variable = desc.variations.len > 0 and entry.variable;
            self.bold = desc.bold == entry.bold;
            self.italic = desc.italic == entry.italic;

            const desired_styles: []const [:0]const u8 = desired: {
                if (desc.style) |s| break :desired &.{s};
                if (desc.bold) {
                    if (desc.italic) break :desired &.{ "bold italic", "bold", "italic", "oblique" };
                    break :desired &.{ "bold", "upright" };
                } else if (desc.italic) {
                    break :desired &.{ "italic", "regular", "oblique" };
                }
                break :desired &.{ "regular", "upright" };
            };

            self.exact_style = std.ascii.eqlIgnoreCase(entry.style, desired_styles[0]);
            const fuzzy_type = @TypeOf(self.fuzzy_style);
            var fuzzy: fuzzy_type = std.math.cast(fuzzy_type, entry.style.len) orelse
                std.math.maxInt(fuzzy_type);
            for (desired_styles) |s| {
                if (std.ascii.indexOfIgnoreCase(entry.style, s) != null) {
                    fuzzy -|= std.math.cast(fuzzy_type, s.len) orelse
                        std.math.maxInt(fuzzy_type);
                }
            }
            self.fuzzy_style = std.math.maxInt(fuzzy_type) -| fuzzy;

            const target: i32 = if (desc.bold) 700 else 400;
            const diff: u32 = @abs(@as(i32, entry.weight) - target);
            self.weight = @intCast(std.math.maxInt(u10) - @min(diff, std.math.maxInt(u10)));

            return self;
        }
    };

    pub const DiscoverIterator = struct {
        alloc: Allocator,
        lib: Library,
        entries: []const Entry,
        candidates: []const Candidate,
        codepoint: u32,
        variations: []const Variation,
        i: usize = 0,

        pub fn deinit(self: *DiscoverIterator) void {
            self.alloc.free(self.candidates);
            self.* = undefined;
        }

        pub fn next(self: *DiscoverIterator) !?DeferredFace {
            while (self.i < self.candidates.len) {
                const entry = &self.entries[self.candidates[self.i].entry];
                self.i += 1;

                const peek = self.openPeek(entry) orelse continue;
                if (self.codepoint != 0 and peek.getCharIndex(self.codepoint) == null) {
                    self.closePeek(peek);
                    continue;
                }

                return DeferredFace{
                    .win = .{
                        .lib = self.lib,
                        .path = entry.path,
                        .face_index = entry.face_index,
                        .family = entry.family,
                        .name = entry.full_name,
                        .variations = self.variations,
                        .peek = peek,
                        .presentation = if (entry.color) .emoji else .text,
                    },
                };
            }

            return null;
        }

        fn openPeek(self: *DiscoverIterator, entry: *const Entry) ?freetype.Face {
            self.lib.mutex.lockUncancelable(global.io());
            defer self.lib.mutex.unlock(global.io());
            const face = self.lib.lib.initFace(entry.path, entry.face_index) catch
                return null;
            face.selectCharmap(.unicode) catch {
                face.deinit();
                return null;
            };
            return face;
        }

        fn closePeek(self: *DiscoverIterator, face: freetype.Face) void {
            self.lib.mutex.lockUncancelable(global.io());
            defer self.lib.mutex.unlock(global.io());
            face.deinit();
        }
    };

    const Coverage = struct {
        const pages = 0x40000 >> 8;

        set: std.StaticBitSet(pages) = .initEmpty(),
        high: bool = false,

        fn mayHave(self: *const Coverage, cp: u32) bool {
            if (cp >= 0x40000) return self.high;
            return self.set.isSet(cp >> 8);
        }
    };

    const Entry = struct {
        path: [:0]const u8,
        face_index: i32,
        family: []const u8,
        alt_names: []const []const u8,
        style: []const u8,
        full_name: []const u8,
        weight: u16,
        bold: bool,
        italic: bool,
        monospace: bool,
        variable: bool,
        color: bool,
        coverage: *const Coverage,

        fn hasAltName(self: *const Entry, name: []const u8) bool {
            for (self.alt_names) |n| {
                if (std.ascii.eqlIgnoreCase(n, name)) return true;
            }
            return false;
        }
    };

    const Locale = enum { other, ja, zh_hans, zh_hant, ko };

    const Index = struct {
        entries: []const Entry,
        locale: Locale,

        var mutex: std.Io.Mutex = .init;
        var instance: ?Index = null;
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

        fn get() !*const Index {
            mutex.lockUncancelable(global.io());
            defer mutex.unlock(global.io());
            if (instance) |*v| return v;
            instance = try build(arena.allocator());
            return &instance.?;
        }

        fn build(alloc: Allocator) !Index {
            const io = global.io();
            const start = std.Io.Timestamp.now(io, .awake);

            const ft = try freetype.Library.init();
            defer ft.deinit();

            var paths: PathSet = .{};
            const system_dir = fontsDir(alloc, "SYSTEMROOT", "\\Fonts");
            const user_dir = fontsDir(alloc, "LOCALAPPDATA", "\\Microsoft\\Windows\\Fonts");
            if (system_dir) |dir| try paths.addDir(alloc, dir);
            if (user_dir) |dir| try paths.addDir(alloc, dir);
            try paths.addRegistry(alloc, hkey_local_machine, system_dir);
            try paths.addRegistry(alloc, hkey_current_user, system_dir);

            std.mem.sort([:0]const u8, paths.list.items, {}, struct {
                fn lessThan(_: void, a: [:0]const u8, b: [:0]const u8) bool {
                    return std.ascii.lessThanIgnoreCase(a, b);
                }
            }.lessThan);

            var entries: std.ArrayList(Entry) = .empty;
            for (paths.list.items) |path| try indexFile(alloc, ft, path, &entries);

            const elapsed = start.durationTo(std.Io.Timestamp.now(io, .awake));
            log.info("indexed {d} font faces from {d} files in {d}ms", .{
                entries.items.len,
                paths.list.items.len,
                @divTrunc(elapsed.toNanoseconds(), std.time.ns_per_ms),
            });

            return .{
                .entries = try entries.toOwnedSlice(alloc),
                .locale = userLocale(),
            };
        }

        fn fontsDir(alloc: Allocator, env: []const u8, suffix: []const u8) ?[]const u8 {
            const base = global.environ().getAlloc(alloc, env) catch return null;
            return std.mem.concat(alloc, u8, &.{ base, suffix }) catch null;
        }

        fn indexFile(
            alloc: Allocator,
            ft: freetype.Library,
            path: [:0]const u8,
            entries: *std.ArrayList(Entry),
        ) Allocator.Error!void {
            var num_faces: i32 = 1;
            var i: i32 = 0;
            while (i < num_faces) : (i += 1) {
                const face = ft.initFace(path, i) catch continue;
                defer face.deinit();
                if (i == 0) num_faces = std.math.cast(i32, face.handle.*.num_faces) orelse 1;
                face.selectCharmap(.unicode) catch continue;

                const coverage = try buildCoverage(alloc, face);
                const instances: i32 = @intCast((face.handle.*.style_flags >> 16) & 0x7FFF);
                if (instances == 0) {
                    try addEntry(alloc, ft, face, path, i, false, coverage, entries);
                    continue;
                }

                var n: i32 = 1;
                while (n <= instances) : (n += 1) {
                    const inst_index = (n << 16) | i;
                    const inst = ft.initFace(path, inst_index) catch continue;
                    defer inst.deinit();
                    try addEntry(alloc, ft, inst, path, inst_index, true, coverage, entries);
                }
            }
        }

        fn buildCoverage(alloc: Allocator, face: freetype.Face) Allocator.Error!*const Coverage {
            const cov = try alloc.create(Coverage);
            cov.* = .{};
            var gindex: freetype.c.FT_UInt = 0;
            var cp = freetype.c.FT_Get_First_Char(face.handle, &gindex);
            while (gindex != 0) {
                if (cp >= 0x40000) {
                    cov.high = true;
                    break;
                }
                const page: usize = @intCast(cp >> 8);
                cov.set.set(page);
                cp = freetype.c.FT_Get_Next_Char(face.handle, cp | 0xFF, &gindex);
            }
            return cov;
        }

        fn addEntry(
            alloc: Allocator,
            ft: freetype.Library,
            face: freetype.Face,
            path: [:0]const u8,
            face_index: i32,
            named_instance: bool,
            coverage: *const Coverage,
            entries: *std.ArrayList(Entry),
        ) Allocator.Error!void {
            const rec = face.handle.*;
            const family_c = rec.family_name orelse return;
            const family = try alloc.dupe(u8, std.mem.span(family_c));
            const style = if (rec.style_name) |s|
                try alloc.dupe(u8, std.mem.span(s))
            else
                "Regular";

            var weight: u16 = 400;
            var bold = rec.style_flags & freetype.c.FT_STYLE_FLAG_BOLD != 0;
            var italic = rec.style_flags & freetype.c.FT_STYLE_FLAG_ITALIC != 0;
            var monospace = rec.face_flags & freetype.c.FT_FACE_FLAG_FIXED_WIDTH != 0;

            if (face.getSfntTable(.os2)) |os2| {
                if (os2.version != 0xFFFF) {
                    weight = os2.usWeightClass;
                    if (weight > 0 and weight < 10) weight *= 100;
                    bold = bold or os2.fsSelection & 0x20 != 0;
                    italic = italic or os2.fsSelection & 0x201 != 0;
                    monospace = monospace or (os2.panose[0] == 2 and os2.panose[3] == 9);
                }
            }
            if (face.getSfntTable(.head)) |head| {
                bold = bold or head.Mac_Style & 1 != 0;
                italic = italic or head.Mac_Style & 2 != 0;
            }
            if (weight == 0) weight = if (bold) 700 else 400;

            if (named_instance) instance: {
                const mm = face.getMMVar() catch break :instance;
                defer ft.doneMMVar(mm);
                var coords_buf: [32]freetype.c.FT_Fixed = undefined;
                const coords = coords_buf[0..@min(coords_buf.len, mm.*.num_axis)];
                face.getVarDesignCoordinates(coords) catch break :instance;

                var ital_seen = false;
                for (coords, 0..) |coord, j| {
                    const value: f64 = @as(f64, @floatFromInt(coord)) / 65536.0;
                    const tag = mm.*.axis[j].tag;
                    if (tag == axisTag("wght")) {
                        weight = std.math.lossyCast(u16, value);
                        bold = value > 600;
                    } else if (tag == axisTag("ital")) {
                        italic = value > 0.5;
                        ital_seen = true;
                    } else if (!ital_seen and tag == axisTag("slnt")) {
                        italic = value <= -5.0;
                    }
                }
            }

            var alt_names: std.ArrayList([]const u8) = .empty;
            var full_name: ?[]const u8 = null;
            const count = face.getSfntNameCount();
            for (0..count) |j| {
                const entry = face.getSfntName(j) catch continue;
                if (entry.platform_id != freetype.c.TT_PLATFORM_MICROSOFT) continue;
                if (entry.encoding_id != freetype.c.TT_MS_ID_UNICODE_CS and
                    entry.encoding_id != freetype.c.TT_MS_ID_UCS_4) continue;
                const is_family = entry.name_id == freetype.c.TT_NAME_ID_FONT_FAMILY or
                    entry.name_id == freetype.c.TT_NAME_ID_TYPOGRAPHIC_FAMILY;
                const is_full = entry.name_id == freetype.c.TT_NAME_ID_FULL_NAME and
                    entry.language_id == 0x409;
                if (!is_family and !is_full) continue;

                const value = decodeUtf16Be(alloc, entry.string[0..entry.string_len]) orelse
                    continue;
                if (is_full) {
                    if (full_name == null) full_name = value;
                    continue;
                }
                if (std.ascii.eqlIgnoreCase(value, family)) continue;
                for (alt_names.items) |existing| {
                    if (std.ascii.eqlIgnoreCase(existing, value)) break;
                } else try alt_names.append(alloc, value);
            }

            const name = if (named_instance or full_name == null)
                try std.fmt.allocPrint(alloc, "{s} {s}", .{ family, style })
            else
                full_name.?;

            try entries.append(alloc, .{
                .path = path,
                .face_index = face_index,
                .family = family,
                .alt_names = try alt_names.toOwnedSlice(alloc),
                .style = style,
                .full_name = name,
                .weight = weight,
                .bold = bold,
                .italic = italic,
                .monospace = monospace,
                .variable = face.hasMultipleMasters(),
                .color = face.hasColor(),
                .coverage = coverage,
            });
        }

        fn axisTag(comptime s: *const [4]u8) freetype.c.FT_ULong {
            return std.mem.readInt(u32, s, .big);
        }

        fn decodeUtf16Be(alloc: Allocator, bytes: []const u8) ?[]const u8 {
            if (bytes.len == 0 or bytes.len % 2 != 0) return null;
            var buf: [512]u16 = undefined;
            const len = @min(buf.len, bytes.len / 2);
            for (0..len) |k| buf[k] = std.mem.readInt(u16, bytes[k * 2 ..][0..2], .big);
            return std.unicode.utf16LeToUtf8Alloc(alloc, buf[0..len]) catch null;
        }
    };

    const PathSet = struct {
        list: std.ArrayList([:0]const u8) = .empty,
        seen: std.StringHashMapUnmanaged(void) = .empty,

        fn add(self: *PathSet, alloc: Allocator, path: [:0]const u8) Allocator.Error!void {
            if (!isFontFile(path)) return;
            const key = try std.ascii.allocLowerString(alloc, path);
            const gop = try self.seen.getOrPut(alloc, key);
            if (gop.found_existing) return;
            try self.list.append(alloc, path);
        }

        fn addDir(self: *PathSet, alloc: Allocator, dir_path: []const u8) Allocator.Error!void {
            const io = global.io();
            var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch
                return;
            defer dir.close(io);
            var it = dir.iterate();
            while (it.next(io) catch null) |entry| {
                if (entry.kind != .file) continue;
                const path = try std.fmt.allocPrintSentinel(
                    alloc,
                    "{s}\\{s}",
                    .{ dir_path, entry.name },
                    0,
                );
                try self.add(alloc, path);
            }
        }

        fn addRegistry(
            self: *PathSet,
            alloc: Allocator,
            root: HKEY,
            system_dir: ?[]const u8,
        ) Allocator.Error!void {
            var key: HKEY = undefined;
            if (RegOpenKeyExW(
                root,
                std.unicode.utf8ToUtf16LeStringLiteral("SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts"),
                0,
                key_read,
                &key,
            ) != 0) return;
            defer _ = RegCloseKey(key);

            var name_buf: [1024]u16 = undefined;
            var data_buf: [1024]u16 = undefined;
            var i: u32 = 0;
            while (true) : (i += 1) {
                var name_len: u32 = name_buf.len;
                var data_len: u32 = @sizeOf(@TypeOf(data_buf));
                var value_type: u32 = 0;
                const rc = RegEnumValueW(
                    key,
                    i,
                    &name_buf,
                    &name_len,
                    null,
                    &value_type,
                    @ptrCast(&data_buf),
                    &data_len,
                );
                if (rc == error_no_more_items) break;
                if (rc != 0) continue;
                if (value_type != reg_sz) continue;

                var chars: []const u16 = data_buf[0 .. data_len / 2];
                while (chars.len > 0 and chars[chars.len - 1] == 0) chars = chars[0 .. chars.len - 1];
                if (chars.len == 0) continue;

                const file = std.unicode.utf16LeToUtf8Alloc(alloc, chars) catch continue;
                const absolute = (file.len >= 2 and file[1] == ':') or
                    std.mem.startsWith(u8, file, "\\\\");
                const path = if (absolute)
                    try alloc.dupeZ(u8, file)
                else if (system_dir) |dir|
                    try std.fmt.allocPrintSentinel(alloc, "{s}\\{s}", .{ dir, file }, 0)
                else
                    continue;
                try self.add(alloc, path);
            }
        }
    };

    fn isFontFile(name: []const u8) bool {
        return std.ascii.endsWithIgnoreCase(name, ".ttf") or
            std.ascii.endsWithIgnoreCase(name, ".ttc") or
            std.ascii.endsWithIgnoreCase(name, ".otf") or
            std.ascii.endsWithIgnoreCase(name, ".otc");
    }

    fn userLocale() Locale {
        var buf: [85]u16 = undefined;
        const n = GetUserDefaultLocaleName(&buf, buf.len);
        if (n <= 1) return .other;
        var ascii: [85]u8 = undefined;
        const len: usize = @intCast(n - 1);
        for (buf[0..len], 0..) |c, i| ascii[i] = if (c < 0x80) @intCast(c) else '?';
        const name = ascii[0..len];

        if (std.ascii.startsWithIgnoreCase(name, "ja")) return .ja;
        if (std.ascii.startsWithIgnoreCase(name, "ko")) return .ko;
        if (std.ascii.startsWithIgnoreCase(name, "zh")) {
            for ([_][]const u8{ "-TW", "-HK", "-MO", "-Hant" }) |suffix| {
                if (std.ascii.indexOfIgnoreCase(name, suffix) != null) return .zh_hant;
            }
            return .zh_hans;
        }
        return .other;
    }

    fn curatedFallback(cp: u32, locale: Locale) []const []const u8 {
        if (cp >= 0x1F000 and cp <= 0x1FAFF)
            return &.{ "Segoe UI Emoji", "Segoe UI Symbol" };
        if ((cp >= 0x2000 and cp <= 0x2BFF) or (cp >= 0x1D400 and cp <= 0x1D7FF))
            return &.{ "Segoe UI Symbol", "Segoe UI Emoji", "Cambria Math" };
        if ((cp >= 0x1100 and cp <= 0x11FF) or
            (cp >= 0x3130 and cp <= 0x318F) or
            (cp >= 0xAC00 and cp <= 0xD7FF))
            return &.{ "Malgun Gothic", "Gulim" };
        if ((cp >= 0x2E80 and cp <= 0x9FFF) or
            (cp >= 0xF900 and cp <= 0xFAFF) or
            (cp >= 0xFE30 and cp <= 0xFE4F) or
            (cp >= 0xFF00 and cp <= 0xFFEF) or
            (cp >= 0x20000 and cp <= 0x3FFFF))
        {
            return switch (locale) {
                .ja => &.{ "Yu Gothic UI", "Meiryo UI", "MS Gothic", "Microsoft YaHei UI", "Microsoft JhengHei UI", "Malgun Gothic", "SimSun", "SimSun-ExtB", "SimSun-ExtG" },
                .zh_hans => &.{ "Microsoft YaHei UI", "SimSun", "Yu Gothic UI", "Microsoft JhengHei UI", "Malgun Gothic", "SimSun-ExtB", "SimSun-ExtG" },
                .zh_hant => &.{ "Microsoft JhengHei UI", "MingLiU", "Microsoft YaHei UI", "Yu Gothic UI", "Malgun Gothic", "MingLiU-ExtB", "SimSun-ExtG" },
                .ko => &.{ "Malgun Gothic", "Yu Gothic UI", "Microsoft YaHei UI", "Microsoft JhengHei UI", "SimSun-ExtB", "SimSun-ExtG" },
                .other => &.{ "Yu Gothic UI", "Microsoft YaHei UI", "Microsoft JhengHei UI", "Malgun Gothic", "SimSun", "MS Gothic", "SimSun-ExtB", "SimSun-ExtG" },
            };
        }
        if ((cp >= 0x0900 and cp <= 0x0DFF) or (cp >= 0x1CD0 and cp <= 0x1CFF) or (cp >= 0xA8E0 and cp <= 0xA8FF))
            return &.{ "Nirmala UI", "Nirmala Text" };
        if (cp >= 0x0E00 and cp <= 0x0EFF)
            return &.{ "Leelawadee UI", "Leelawadee" };
        if ((cp >= 0x1200 and cp <= 0x139F) or (cp >= 0x2D80 and cp <= 0x2DDF))
            return &.{ "Ebrima", "Nyala" };
        if ((cp >= 0x0590 and cp <= 0x08FF) or
            (cp >= 0xFB1D and cp <= 0xFDFF) or
            (cp >= 0xFE70 and cp <= 0xFEFF))
            return &.{ "Segoe UI", "Tahoma" };
        return &.{};
    }

    const HKEY = *opaque {};
    // Predefined HKEYs are sign-extended 32-bit values on 64-bit Windows.
    const hkey_current_user: HKEY = @ptrFromInt(@as(usize, @bitCast(@as(isize, @as(i32, @bitCast(@as(u32, 0x80000001)))))));
    const hkey_local_machine: HKEY = @ptrFromInt(@as(usize, @bitCast(@as(isize, @as(i32, @bitCast(@as(u32, 0x80000002)))))));
    const key_read: u32 = 0x20019;
    const reg_sz: u32 = 1;
    const error_no_more_items: i32 = 259;

    extern "advapi32" fn RegOpenKeyExW(
        hKey: HKEY,
        lpSubKey: [*:0]const u16,
        ulOptions: u32,
        samDesired: u32,
        phkResult: *HKEY,
    ) callconv(.winapi) i32;
    extern "advapi32" fn RegEnumValueW(
        hKey: HKEY,
        dwIndex: u32,
        lpValueName: [*]u16,
        lpcchValueName: *u32,
        lpReserved: ?*u32,
        lpType: ?*u32,
        lpData: ?[*]u8,
        lpcbData: ?*u32,
    ) callconv(.winapi) i32;
    extern "advapi32" fn RegCloseKey(hKey: HKEY) callconv(.winapi) i32;
    extern "kernel32" fn GetUserDefaultLocaleName(
        lpLocaleName: [*]u16,
        cchLocaleName: i32,
    ) callconv(.winapi) i32;
};

test "descriptor hash" {
    const testing = std.testing;

    var d: Descriptor = .{};
    try testing.expect(d.hashcode() != 0);
}

test "descriptor hash family names" {
    const testing = std.testing;

    var d1: Descriptor = .{ .family = "A" };
    var d2: Descriptor = .{ .family = "B" };
    try testing.expect(d1.hashcode() != d2.hashcode());
}

test "fontconfig" {
    if (options.backend != .fontconfig_freetype) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var fc = Fontconfig.init(lib);
    defer fc.deinit();
    var it = try fc.discover(alloc, .{ .family = "monospace", .size = 12 });
    defer it.deinit();
}

test "fontconfig codepoint" {
    if (options.backend != .fontconfig_freetype) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var fc = Fontconfig.init(lib);
    defer fc.deinit();
    var it = try fc.discover(alloc, .{ .codepoint = 'A', .size = 12 });
    defer it.deinit();

    // The first result should have the codepoint. Later ones may not
    // because fontconfig returns all fonts sorted.
    var face = (try it.next()).?;
    defer face.deinit();
    try testing.expect(face.hasCodepoint('A', null));

    // Should have other codepoints too
    try testing.expect(face.hasCodepoint('B', null));
}

test "coretext" {
    if (options.backend != .coretext and options.backend != .coretext_freetype)
        return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var ct = CoreText.init(lib);
    defer ct.deinit();
    var it = try ct.discover(alloc, .{ .family = "Monaco", .size = 12 });
    defer it.deinit();
    var count: usize = 0;
    while (try it.next()) |_| {
        count += 1;
    }
    try testing.expect(count > 0);
}

test "coretext codepoint" {
    if (options.backend != .coretext and options.backend != .coretext_freetype)
        return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var ct = CoreText.init(lib);
    defer ct.deinit();
    var it = try ct.discover(alloc, .{ .codepoint = 'A', .size = 12 });
    defer it.deinit();

    // The first result should have the codepoint. Later ones may not
    // because fontconfig returns all fonts sorted.
    const face = (try it.next()).?;
    try testing.expect(face.hasCodepoint('A', null));

    // Should have other codepoints too
    try testing.expect(face.hasCodepoint('B', null));
}

test "coretext sorting" {
    if (options.backend != .coretext and options.backend != .coretext_freetype)
        return error.SkipZigTest;

    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!//
    // FIXME: Disabled for now because SF Pro is not available in CI
    //        The solution likely involves directly testing that the
    //        `sortMatchingDescriptors` function sorts a bundled test
    //        font correctly, instead of relying on the system fonts.
    if (true) return error.SkipZigTest;
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!//

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var ct = CoreText.init(lib);
    defer ct.deinit();

    // We try to get a Regular, Italic, Bold, & Bold Italic version of SF Pro,
    // which should be installed on all Macs, and has many styles which makes
    // it a good test, since there will be many results for each discovery.

    // Regular
    {
        var it = try ct.discover(alloc, .{
            .family = "SF Pro",
            .size = 12,
        });
        defer it.deinit();
        const res = (try it.next()).?;
        var buf: [1024]u8 = undefined;
        const name = try res.name(&buf);
        try testing.expectEqualStrings("SF Pro Regular", name);
    }

    // Regular Italic
    //
    // NOTE: This makes sure that we don't accidentally prefer "Thin Italic",
    //       which we previously did, because it has a shorter name.
    {
        var it = try ct.discover(alloc, .{
            .family = "SF Pro",
            .size = 12,
            .italic = true,
        });
        defer it.deinit();
        const res = (try it.next()).?;
        var buf: [1024]u8 = undefined;
        const name = try res.name(&buf);
        try testing.expectEqualStrings("SF Pro Regular Italic", name);
    }

    // Bold
    {
        var it = try ct.discover(alloc, .{
            .family = "SF Pro",
            .size = 12,
            .bold = true,
        });
        defer it.deinit();
        const res = (try it.next()).?;
        var buf: [1024]u8 = undefined;
        const name = try res.name(&buf);
        try testing.expectEqualStrings("SF Pro Bold", name);
    }

    // Bold Italic
    {
        var it = try ct.discover(alloc, .{
            .family = "SF Pro",
            .size = 12,
            .bold = true,
            .italic = true,
        });
        defer it.deinit();
        const res = (try it.next()).?;
        var buf: [1024]u8 = undefined;
        const name = try res.name(&buf);
        try testing.expectEqualStrings("SF Pro Bold Italic", name);
    }
}

test "windows" {
    if (options.backend != .freetype_windows) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var win = Windows.init(lib);
    defer win.deinit();

    // Arial ships on every stock Windows install.
    var it = try win.discover(alloc, .{ .family = "Arial", .size = 12 });
    defer it.deinit();

    var face = (try it.next()) orelse return error.TestFontNotFound;
    defer face.deinit();
    try testing.expect(face.hasCodepoint('A', null));
}

test "windows bold style" {
    if (options.backend != .freetype_windows) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var win = Windows.init(lib);
    defer win.deinit();

    var it = try win.discover(alloc, .{ .family = "Arial", .size = 12, .bold = true });
    defer it.deinit();

    var face = (try it.next()) orelse return error.TestFontNotFound;
    defer face.deinit();
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("Arial", try face.familyName(&buf));
    try testing.expectEqualStrings("Arial Bold", try face.name(&buf));
}

test "windows emoji fallback" {
    if (options.backend != .freetype_windows) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var win = Windows.init(lib);
    defer win.deinit();

    var it = try win.search(alloc, .{ .codepoint = 0x1F600, .size = 12 }, true);
    defer it.deinit();

    var face = (try it.next()) orelse return error.TestFontNotFound;
    defer face.deinit();
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("Segoe UI Emoji", try face.familyName(&buf));
    try testing.expect(face.hasCodepoint(0x1F600, .emoji));
}

test "windows monospace and collections" {
    if (options.backend != .freetype_windows) return error.SkipZigTest;

    const testing = std.testing;
    const index = try Windows.Index.get();

    var consolas = false;
    var gothic_faces: usize = 0;
    for (index.entries) |entry| {
        if (std.mem.eql(u8, entry.family, "Consolas")) {
            try testing.expect(entry.monospace);
            consolas = true;
        }
        if (std.ascii.endsWithIgnoreCase(entry.path, "\\msgothic.ttc")) gothic_faces += 1;
    }
    try testing.expect(consolas);
    if (gothic_faces > 0) try testing.expect(gothic_faces > 1);
}

test "windows cjk and symbol fallback" {
    if (options.backend != .freetype_windows) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var win = Windows.init(lib);
    defer win.deinit();

    const index = try Windows.Index.get();
    const cjk: ?[]const u8 = switch (index.locale) {
        .other, .ja => "Yu Gothic UI",
        else => null,
    };
    const cases = [_]struct { u32, ?[]const u8 }{
        .{ 0x65E5, cjk },
        .{ 0x2211, "Segoe UI Symbol" },
        .{ 0x279C, "Segoe UI Symbol" },
    };
    for (cases) |case| {
        const cp, const expected = case;
        var it = try win.search(alloc, .{ .codepoint = cp, .size = 12 }, true);
        defer it.deinit();
        var face = (try it.next()) orelse return error.TestFontNotFound;
        defer face.deinit();
        try testing.expect(face.hasCodepoint(cp, null));
        var buf: [256]u8 = undefined;
        if (expected) |family| try testing.expectEqualStrings(family, try face.familyName(&buf));
    }
}

test "windows variable named instance" {
    if (options.backend != .freetype_windows) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var win = Windows.init(lib);
    defer win.deinit();

    {
        var it = try win.discover(alloc, .{ .family = "Cascadia Mono", .size = 12, .bold = true });
        defer it.deinit();
        var face = (try it.next()) orelse return error.SkipZigTest;
        defer face.deinit();
        var buf: [256]u8 = undefined;
        try testing.expectEqualStrings("Cascadia Mono Bold", try face.name(&buf));

        var regular_it = try win.discover(alloc, .{ .family = "Cascadia Mono", .size = 12 });
        defer regular_it.deinit();
        var regular = (try regular_it.next()) orelse return error.TestFontNotFound;
        defer regular.deinit();
        try testing.expectEqualStrings("Cascadia Mono Regular", try regular.name(&buf));

        const bold_ink = try testInk(alloc, lib, &face, 'l');
        const regular_ink = try testInk(alloc, lib, &regular, 'l');
        try testing.expect(bold_ink > regular_ink + regular_ink / 4);
    }

    {
        const variations: []const Variation = &.{.{ .id = .init("wght"), .value = 600 }};
        var it = try win.discover(alloc, .{
            .family = "Cascadia Mono",
            .size = 12,
            .variations = variations,
        });
        defer it.deinit();
        var deferred = (try it.next()) orelse return error.SkipZigTest;
        defer deferred.deinit();
        var face = try deferred.load(lib, .{ .size = .{ .points = 12 } });
        defer face.deinit();

        const mm = try face.face.getMMVar();
        defer lib.lib.doneMMVar(mm);
        var coords: [32]Windows.freetype.c.FT_Fixed = undefined;
        const n = @min(coords.len, mm.*.num_axis);
        try face.face.getVarDesignCoordinates(coords[0..n]);
        for (0..n) |i| {
            if (mm.*.axis[i].tag == std.mem.readInt(u32, "wght", .big)) {
                try testing.expectEqual(@as(i64, 600), @divTrunc(coords[i], 65536));
            }
        }
    }
}

fn testInk(alloc: Allocator, lib: Library, deferred: *DeferredFace, cp: u32) !u64 {
    const font = @import("main.zig");
    var face = try deferred.load(lib, .{ .size = .{ .points = 24, .xdpi = 96, .ydpi = 96 } });
    defer face.deinit();
    var atlas = try font.Atlas.init(alloc, 128, .grayscale);
    defer atlas.deinit(alloc);
    _ = try face.renderGlyph(
        alloc,
        &atlas,
        face.glyphIndex(cp).?,
        .{ .grid_metrics = font.Metrics.calc(face.getMetrics()) },
    );
    var sum: u64 = 0;
    for (atlas.data) |v| sum += v;
    return sum;
}
