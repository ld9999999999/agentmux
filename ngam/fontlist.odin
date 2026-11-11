package ngam

// The monospace fonts installed in the system font folders, for the setup
// screen's font list. Each file is mapped into memory, so stb_truetype
// touches only the tables it needs and a scan of a few hundred fonts stays
// fast.

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:unicode/utf16"
import stbtt "vendor:stb/truetype"

Font_Family :: struct {
	name:  string,
	faces: [Style]Face_Ref,
	score: [Style]int, // how well each face's name matched its style
}

@(private = "file")
font_dirs :: proc(allocator := context.allocator) -> []string {
	home, _ := os.user_home_dir(context.temp_allocator)
	dirs := make([dynamic]string, allocator)
	when ODIN_OS == .Darwin {
		append(&dirs, "/System/Library/Fonts", "/Library/Fonts")
		append(&dirs, filepath.join({home, "Library/Fonts"}, allocator) or_else "")
	} else {
		append(&dirs, "/usr/share/fonts")
		append(&dirs, filepath.join({home, ".local/share/fonts"}, allocator) or_else "")
	}
	return dirs[:]
}

// list_mono_fonts returns the monospace families, sorted by name.
list_mono_fonts :: proc(allocator := context.allocator) -> []Font_Family {
	families := make(map[string]Font_Family, allocator = context.temp_allocator)
	for dir in font_dirs(context.temp_allocator) {
		scan_dir(dir, &families, 0, allocator)
	}
	out := make([dynamic]Font_Family, allocator)
	for _, fam in families {
		if fam.faces[.Regular].path != "" {
			append(&out, fam)
		}
	}
	slice.sort_by(out[:], proc(a, b: Font_Family) -> bool {
		return strings.to_lower(a.name, context.temp_allocator) < strings.to_lower(b.name, context.temp_allocator)
	})
	return out[:]
}

@(private = "file")
scan_dir :: proc(dir: string, families: ^map[string]Font_Family, depth: int, allocator := context.allocator) {
	if depth > 6 {
		return
	}
	entries, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil {
		return
	}
	for e in entries {
		if e.type == .Directory {
			scan_dir(e.fullpath, families, depth + 1, allocator)
			continue
		}
		ext := strings.to_lower(filepath.ext(e.name), context.temp_allocator)
		if ext == ".ttf" || ext == ".ttc" || ext == ".otf" {
			scan_file(e.fullpath, families, allocator)
		}
	}
}

@(private = "file")
scan_file :: proc(path: string, families: ^map[string]Font_Family, allocator := context.allocator) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	fd := posix.open(cpath, {})
	if fd < 0 {
		return
	}
	defer posix.close(fd)
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK || st.st_size < 12 {
		return
	}
	size := uint(st.st_size)
	mem := posix.mmap(nil, size, {.READ}, {.PRIVATE}, fd, 0)
	if mem == posix.MAP_FAILED {
		return
	}
	defer posix.munmap(mem, size)
	data := ([^]u8)(mem)

	n := max(stbtt.GetNumberOfFonts(data), 1)
	for i in 0 ..< n {
		off := stbtt.GetFontOffsetForIndex(data, i)
		info: stbtt.fontinfo
		if off < 0 || !stbtt.InitFont(&info, data, off) {
			continue
		}
		if !is_monospace(&info) {
			continue
		}
		family := font_name(&info, 16)
		if family == "" {
			family = font_name(&info, 1)
		}
		sub := font_name(&info, 17)
		if sub == "" {
			sub = font_name(&info, 2)
		}
		if family == "" || strings.has_prefix(family, ".") {
			continue // hidden system fonts start with a dot
		}
		style, score := style_of(sub)
		fam, seen := families[family]
		if !seen {
			fam.name = strings.clone(family, allocator)
		}
		if fam.faces[style].path == "" || score > fam.score[style] {
			fam.faces[style] = {strings.clone(path, allocator), i}
			fam.score[style] = score
		}
		families[fam.name] = fam
	}
}

// is_monospace: the face has 'i' and 'M', with the same advance.
@(private = "file")
is_monospace :: proc(info: ^stbtt.fontinfo) -> bool {
	if stbtt.FindGlyphIndex(info, 'i') == 0 || stbtt.FindGlyphIndex(info, 'M') == 0 {
		return false
	}
	ai, am, lsb: i32
	stbtt.GetCodepointHMetrics(info, 'i', &ai, &lsb)
	stbtt.GetCodepointHMetrics(info, 'M', &am, &lsb)
	return ai > 0 && ai == am
}

// style_of maps a subfamily name such as "Bold Italic" to a style, with a
// score that prefers plain names ("Regular", "Bold") over weights such as
// "Light" or "SemiBold".
@(private = "file")
style_of :: proc(sub: string) -> (Style, int) {
	s := strings.to_lower(sub, context.temp_allocator)
	style := style_from_name(s)
	score := 1
	switch s {
	case "regular", "book", "roman", "normal", "bold", "italic", "bold italic", "oblique", "bold oblique":
		score = 3
	}
	if strings.contains(s, "semi") || strings.contains(s, "extra") || strings.contains(s, "light") || strings.contains(s, "thin") || strings.contains(s, "medium") || strings.contains(s, "black") || strings.contains(s, "heavy") || strings.contains(s, "condensed") {
		score = 0
	}
	return style, score
}

// font_name reads a name from the name table, trying the Windows
// (UTF-16) entry, which most fonts have, then the Mac one.
@(private = "file")
font_name :: proc(info: ^stbtt.fontinfo, id: i32) -> string {
	length: i32
	if p := stbtt.GetFontNameString(info, &length, .PLATFORM_ID_MICROSOFT, 1, 0x409, id); p != nil && length > 0 {
		raw := ([^]u8)(p)[:length]
		units := make([]u16, length / 2, context.temp_allocator)
		for i in 0 ..< len(units) {
			units[i] = u16(raw[2 * i]) << 8 | u16(raw[2 * i + 1])
		}
		buf := make([]u8, len(units) * 3, context.temp_allocator)
		n := utf16.decode_to_utf8(buf, units)
		return string(buf[:n])
	}
	if p := stbtt.GetFontNameString(info, &length, .PLATFORM_ID_MAC, 0, 0, id); p != nil && length > 0 {
		return strings.clone(string(([^]u8)(p)[:length]), context.temp_allocator)
	}
	return ""
}
