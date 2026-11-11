package ngam

// Fonts and the glyph atlas. stb_truetype turns each glyph into pixels the
// first time it is drawn, in one big texture. Glyphs are white, with how
// much of each pixel they cover in alpha, so a quad's vertex color tints
// them.

import "core:fmt"
import "core:math"
import "core:strings"
import "core:sys/posix"
import sdl "vendor:sdl3"
import stbtt "vendor:stb/truetype"

DEFAULT_SIZE :: 13 // points
UI_SIZE :: 13 // points, for the panel and the setup screen

// DEFAULT_FONT is the editor font when the settings leave it empty, UI_FONTS the
// proportional fonts tried for the UI, and FALLBACK_FONTS the fonts tried,
// in order, for codepoints a font lacks. Missing files are skipped.
when ODIN_OS == .Darwin {
	DEFAULT_FONT :: "/System/Library/Fonts/Menlo.ttc"
	UI_FONTS :: []string{"/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc"}
	FALLBACK_FONTS :: []string{"/System/Library/Fonts/Apple Symbols.ttf", "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"}
} else {
	DEFAULT_FONT :: "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
	UI_FONTS :: []string{"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"}
	FALLBACK_FONTS :: []string{"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"}
}

ATLAS_SIZE :: 2048 // pixels on a side; a Font's atlas_size can change it

Style :: enum u8 {
	Regular,
	Bold,
	Italic,
	Bold_Italic,
}

Face :: struct {
	info:  stbtt.fontinfo,
	scale: f32,
}

Glyph_Key :: struct {
	r:     rune,
	style: Style,
}

// Where a glyph is in the atlas, and where its bitmap goes relative to
// the top left of its cell. A glyph with w == 0 draws nothing.
Glyph :: struct {
	x, y, w, h: i32,
	dx, dy:     i32,
	adv:        f32, // how far the pen moves after it
}

Font :: struct {
	styles:    [Style]Maybe(Face), // faces of the main font
	fallbacks: [dynamic]Face,

	// Cell metrics in pixels.
	cell_w, cell_h: i32,
	baseline:       i32, // from the cell's top
	underline_y:    i32,
	line_px:        i32, // thickness of underline and strikethrough
	size_px:        f32, // the size it was loaded at

	atlas:          ^sdl.Texture,
	atlas_size:     i32, // 0 means ATLAS_SIZE
	glyphs:         map[Glyph_Key]Glyph,
	pack_x, pack_y: i32, // the next free spot on the current shelf
	shelf_h:        i32,
	full:           bool, // the atlas ran out of room for a glyph and must be reset
}

// Face_Ref names one face of a font file: its path and, in a .ttc, its
// index.
Face_Ref :: struct {
	path:  string,
	index: i32,
}

// Font_Spec says where each style's face is. A style with an empty path
// uses the regular face.
Font_Spec :: struct {
	faces: [Style]Face_Ref,
}

// Font files are mapped into memory, and each file is mapped only once,
// shared by every Font that uses it: the editor, UI and icon fonts share
// the fallbacks (Arial Unicode alone is 23 MB). Mapped pages are clean,
// so macOS counts only the pages stb_truetype touches and can drop them.
// The files stay mapped until ngam exits.
@(private = "file")
font_files: map[string][]byte

// font_file returns path's contents, mapped read-only.
font_file :: proc(path: string) -> (data: []byte, ok: bool) {
	if d, seen := font_files[path]; seen {
		return d, true
	}
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	fd := posix.open(cpath, {})
	if fd < 0 {
		return nil, false
	}
	defer posix.close(fd)
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK || st.st_size < 12 {
		return nil, false
	}
	size := int(st.st_size)
	mem := posix.mmap(nil, uint(size), {.READ}, {.PRIVATE}, fd, 0)
	if mem == posix.MAP_FAILED {
		return nil, false
	}
	data = ([^]u8)(mem)[:size]
	font_files[strings.clone(path)] = data
	return data, true
}

// font_spec_from_file makes a spec from one file: a .ttf, or a .ttc whose
// faces are matched to styles by name.
font_spec_from_file :: proc(path: string, allocator := context.allocator) -> (spec: Font_Spec, ok: bool) {
	data, data_ok := font_file(path)
	if !data_ok {
		fmt.eprintfln("ngam: cannot read font %s", path)
		return {}, false
	}
	n := max(stbtt.GetNumberOfFonts(raw_data(data)), 1)
	for i in 0 ..< n {
		face, face_ok := face_open(data, i, 10)
		if !face_ok {
			continue
		}
		style := face_style(&face.info)
		if i == 0 || spec.faces[style].path == "" {
			spec.faces[style] = {strings.clone(path, allocator), i}
		}
	}
	return spec, spec.faces[.Regular].path != ""
}

// font_load opens the faces in spec and the fallback fonts at size points
// times density. Cells are sized from the regular face.
font_load :: proc(f: ^Font, spec: Font_Spec, size_pt: f32, density: f32) -> bool {
	px := size_pt * density
	f.size_px = px
	for ref, style in spec.faces {
		if ref.path == "" {
			continue
		}
		data, data_ok := font_file(ref.path)
		if !data_ok {
			fmt.eprintfln("ngam: cannot read font %s", ref.path)
			continue
		}
		if face, ok := face_open(data, ref.index, px); ok {
			f.styles[style] = face
		}
	}
	if f.styles[.Regular] == nil {
		fmt.eprintln("ngam: no usable regular face in", spec.faces[.Regular].path)
		return false
	}
	for fb in FALLBACK_FONTS {
		fb_data, fb_ok := font_file(fb)
		if !fb_ok {
			continue
		}
		if face, ok := face_open(fb_data, 0, px); ok {
			append(&f.fallbacks, face)
		}
	}

	// Cell size from the regular face. Monospace fonts give every
	// glyph the same advance; use 'M' to be safe.
	reg := &f.styles[.Regular].?
	ascent, descent, gap: i32
	stbtt.GetFontVMetrics(&reg.info, &ascent, &descent, &gap)
	adv, lsb: i32
	stbtt.GetCodepointHMetrics(&reg.info, 'M', &adv, &lsb)
	f.cell_w = i32(math.round(f32(adv) * reg.scale))
	f.cell_h = i32(math.ceil(f32(ascent - descent + gap) * reg.scale))
	f.baseline = i32(math.round(f32(ascent) * reg.scale + f32(gap) * reg.scale / 2))
	f.line_px = max(1, i32(math.round(density)))
	f.underline_y = min(f.baseline + f.line_px, f.cell_h - f.line_px)
	return true
}

@(private = "file")
face_open :: proc(data: []byte, index: i32, px: f32) -> (face: Face, ok: bool) {
	off := stbtt.GetFontOffsetForIndex(raw_data(data), index)
	if off < 0 || !stbtt.InitFont(&face.info, raw_data(data), off) {
		return {}, false
	}
	face.scale = stbtt.ScaleForMappingEmToPixels(&face.info, px)
	return face, true
}

// face_style guesses a face's style from its subfamily name, such as
// "Bold Italic".
@(private = "file")
face_style :: proc(info: ^stbtt.fontinfo) -> Style {
	length: i32
	p := stbtt.GetFontNameString(info, &length, .PLATFORM_ID_MAC, 0, 0, 2)
	if p == nil {
		return .Regular
	}
	return style_from_name(string(([^]u8)(p)[:length]))
}

// style_from_name is the style a subfamily name such as "Bold Italic"
// names, in any case.
style_from_name :: proc(name: string) -> Style {
	s := strings.to_lower(name, context.temp_allocator)
	bold := strings.contains(s, "bold")
	italic := strings.contains(s, "italic") || strings.contains(s, "oblique")
	switch {
	case bold && italic:
		return .Bold_Italic
	case bold:
		return .Bold
	case italic:
		return .Italic
	}
	return .Regular
}

font_destroy :: proc(f: ^Font) {
	if f.atlas != nil {
		sdl.DestroyTexture(f.atlas)
	}
	delete(f.glyphs)
	delete(f.fallbacks)
	f^ = {} // the files stay mapped, for the next load
}

// atlas_reset empties the atlas, creating it the first time. The top left
// 4x4 pixels stay solid white for drawing plain rectangles.
atlas_reset :: proc(f: ^Font, r: ^sdl.Renderer) {
	if f.atlas_size == 0 {
		f.atlas_size = ATLAS_SIZE
	}
	if f.atlas == nil {
		f.atlas = sdl.CreateTexture(r, .RGBA32, .STATIC, f.atlas_size, f.atlas_size)
		_ = sdl.SetTextureBlendMode(f.atlas, sdl.BLENDMODE_BLEND)
		_ = sdl.SetTextureScaleMode(f.atlas, .NEAREST)
	}
	clear(&f.glyphs)
	white: [4 * 4 * 4]byte = 255
	rect := sdl.Rect{0, 0, 4, 4}
	_ = sdl.UpdateTexture(f.atlas, &rect, &white, 4 * 4)
	f.pack_x, f.pack_y, f.shelf_h = 4, 0, 4
	f.full = false
}

// glyph_get returns r's glyph in style, adding it to the atlas on first use.
glyph_get :: proc(f: ^Font, r: rune, style: Style) -> Glyph {
	key := Glyph_Key{r, style}
	if g, ok := f.glyphs[key]; ok {
		return g
	}
	g := glyph_render(f, r, style)
	f.glyphs[key] = g
	return g
}

@(private = "file")
glyph_render :: proc(f: ^Font, r: rune, style: Style) -> Glyph {
	// Find a face with the glyph: the style's own face, then the regular
	// face, then the fallbacks.
	face: ^Face
	index: i32
	if s, ok := &f.styles[style].?; ok {
		if i := stbtt.FindGlyphIndex(&s.info, r); i != 0 {
			face, index = s, i
		}
	}
	if face == nil {
		reg := &f.styles[.Regular].?
		if i := stbtt.FindGlyphIndex(&reg.info, r); i != 0 {
			face, index = reg, i
		}
	}
	for &fb in f.fallbacks {
		if face != nil {
			break
		}
		if i := stbtt.FindGlyphIndex(&fb.info, r); i != 0 {
			face, index = &fb, i
		}
	}
	if face == nil {
		// Every face lacks it: draw the regular face's missing-glyph box.
		face, index = &f.styles[.Regular].?, 0
	}

	adv_units, lsb: i32
	stbtt.GetGlyphHMetrics(&face.info, index, &adv_units, &lsb)
	adv := f32(adv_units) * face.scale
	x0, y0, x1, y1: i32
	stbtt.GetGlyphBitmapBox(&face.info, index, face.scale, face.scale, &x0, &y0, &x1, &y1)
	w, h := x1 - x0, y1 - y0
	size := f.atlas_size
	if w <= 0 || h <= 0 || w + 1 > size || h + 1 > size {
		return {adv = adv}
	}
	// Shelf packing: fill rows left to right, starting a new row when
	// one is full. 1 pixel of padding keeps neighbouring glyphs from
	// bleeding into each other.
	if f.pack_x + w + 1 > size {
		f.pack_x, f.pack_y, f.shelf_h = 0, f.pack_y + f.shelf_h, 0
	}
	if f.pack_y + h + 1 > size {
		f.full = true
		return {adv = adv}
	}
	gx, gy := f.pack_x, f.pack_y
	f.pack_x += w + 1
	f.shelf_h = max(f.shelf_h, h + 1)

	alpha := make([]byte, int(w * h), context.temp_allocator)
	stbtt.MakeGlyphBitmap(&face.info, raw_data(alpha), w, h, w, face.scale, face.scale, index)
	rgba := make([]byte, int(w * h * 4), context.temp_allocator)
	for a, i in alpha {
		rgba[i * 4 + 0] = 255
		rgba[i * 4 + 1] = 255
		rgba[i * 4 + 2] = 255
		rgba[i * 4 + 3] = a
	}
	rect := sdl.Rect{gx, gy, w, h}
	_ = sdl.UpdateTexture(f.atlas, &rect, raw_data(rgba), w * 4)
	return {x = gx, y = gy, w = w, h = h, dx = x0, dy = f.baseline + y0, adv = adv}
}
