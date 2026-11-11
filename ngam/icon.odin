package ngam

// ngam's icon, drawn in code: two upright rounded rectangles side by side
// in a square, aqua on the left (the editor) and a lighter blue on the
// right (the agent). On macOS the window icon is also the Dock's.

import "core:math"
import sdl "vendor:sdl3"

@(private = "file")
ICON_SIZE :: 512

@(private = "file")
ICON_LEFT :: [3]u8{0x00, 0xb4, 0xd8} // aqua blue

@(private = "file")
ICON_RIGHT :: [3]u8{0x8e, 0xd3, 0xf5} // a lighter blue

// set_app_icon gives the window (and on macOS the app) ngam's icon.
set_app_icon :: proc(window: ^sdl.Window) {
	s := sdl.CreateSurface(ICON_SIZE, ICON_SIZE, .RGBA32)
	if s == nil {
		return
	}
	defer sdl.DestroySurface(s)
	px := ([^]u8)(s.pixels)
	// As macOS draws app icons: the shape takes about 80% of the square.
	m: f32 = ICON_SIZE * 0.1
	gap: f32 = ICON_SIZE * 0.035
	r: f32 = ICON_SIZE * 0.07
	mid: f32 = ICON_SIZE / 2
	left := [4]f32{m, m, mid - gap / 2, ICON_SIZE - m}
	right := [4]f32{mid + gap / 2, m, ICON_SIZE - m, ICON_SIZE - m}
	for y in 0 ..< ICON_SIZE {
		row := px[int(s.pitch) * y:]
		for x in 0 ..< ICON_SIZE {
			p := [2]f32{f32(x) + 0.5, f32(y) + 0.5}
			color := ICON_LEFT
			a := coverage(p, left, r)
			if b := coverage(p, right, r); b > 0 {
				color, a = ICON_RIGHT, b
			}
			o := row[x * 4:]
			o[0], o[1], o[2], o[3] = color.r, color.g, color.b, u8(a * 255)
		}
	}
	_ = sdl.SetWindowIcon(window, s)
}

// coverage is how much of the pixel at p a rounded rectangle (x0, y0, x1,
// y1, corner radius r) covers, from 0 to 1, for smooth edges.
@(private = "file")
coverage :: proc(p: [2]f32, rect: [4]f32, r: f32) -> f32 {
	c := [2]f32{(rect[0] + rect[2]) / 2, (rect[1] + rect[3]) / 2}
	half := [2]f32{(rect[2] - rect[0]) / 2 - r, (rect[3] - rect[1]) / 2 - r}
	q := [2]f32{abs(p.x - c.x) - half.x, abs(p.y - c.y) - half.y}
	outside := math.sqrt(max(q.x, 0) * max(q.x, 0) + max(q.y, 0) * max(q.y, 0))
	d := outside + min(max(q.x, q.y), 0) - r // signed distance to the edge
	return clamp(0.5 - d, 0, 1)
}
