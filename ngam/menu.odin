package ngam

// The right-click menu for a file or folder in the side panel (Explorer
// and Git rows). It is a small window at the mouse; a click outside it or
// Escape closes it.
//
//   Preview in Browser   the file (or the folder's index.html) through the
//                        preview server
//   Download             a remote session's file, copied through nvim
//                        into ~/Downloads
//   Open Folder          a local session's file shown in Finder (or the
//                        folder opened in the file manager)
//   Copy Path            the path on the session's machine
//   Close Buffer         for a row of the Explorer's Buffers area: closes
//                        that buffer in nvim, asking first when it has
//                        unsaved changes; windows showing it stay open

import "core:strings"
import mu "vendor:microui"

Menu :: struct {
	open: bool,
	path: string, // "" for an unnamed buffer
	dir:  bool,
	buf:  int, // the nvim buffer the row stands for, or 0
	at:   [2]i32, // the top left, in window pixels
}

@(private = "file")
Menu_Item :: enum {
	Preview,
	Download,
	Open_Folder,
	Copy_Path,
	Close_Buffer,
}

@(private = "file")
ITEM_LABELS := [Menu_Item]string {
	.Preview     = "Preview in Browser",
	.Download    = "Download",
	.Open_Folder = "Open Folder",
	.Copy_Path   = "Copy Path",
	.Close_Buffer = "Close Buffer",
}

// To test Download on a local session, build with
// -define:NGAM_TEST_REMOTE=true.
@(private = "file")
TEST_REMOTE :: #config(NGAM_TEST_REMOTE, false)

// session_is_remote says whether the session runs on an ssh host.
session_is_remote :: proc(app: ^App) -> bool {
	return TEST_REMOTE || (app.host != "" && app.host != "local")
}

menu_open :: proc(app: ^App, path: string, dir: bool, buf := 0) {
	m := &app.menu
	delete(m.path)
	m.path = strings.clone(path)
	m.dir = dir
	m.buf = buf
	m.at = {app.mouse.x, app.mouse.y}
	m.open = true
	app.need_draw = true
}

menu_close :: proc(app: ^App) {
	app.menu.open = false
	app.need_draw = true
}

// menu_items are the items that apply to the menu's file.
@(private = "file")
menu_items :: proc(app: ^App) -> []Menu_Item {
	m := &app.menu
	items := make([dynamic]Menu_Item, context.temp_allocator)
	if m.path != "" {
		if m.dir || previewable(m.path) {
			append(&items, Menu_Item.Preview)
		}
		if session_is_remote(app) {
			if !m.dir {
				append(&items, Menu_Item.Download)
			}
		} else {
			append(&items, Menu_Item.Open_Folder)
		}
		append(&items, Menu_Item.Copy_Path)
	}
	if m.buf > 0 {
		append(&items, Menu_Item.Close_Buffer)
	}
	return items[:]
}

// menu_frame builds the menu for this frame, when it is open.
menu_frame :: proc(app: ^App) {
	m := &app.menu
	if !m.open {
		return
	}
	ui := &app.ui
	ctx := &ui.ctx
	items := menu_items(app)
	pad := ctx.style.padding
	row_h := ui.font.cell_h + pad
	w: i32 = 0
	for it in items {
		w = max(w, text_width(&ui.font, ITEM_LABELS[it]))
	}
	w += pad * 6
	h := i32(len(items)) * (row_h + ctx.style.spacing) + pad * 2
	ww, wh := window_pixels(app)
	r := mu.Rect{min(m.at.x, ww - w - 1), min(m.at.y, wh - h - 1), w, h}

	// A press outside the menu closes it. microui hears of presses one
	// frame late, so the press that opened the menu counts as a press on
	// the panel row.
	if ctx.mouse_pressed_bits != {} && !point_in(r, ctx.mouse_pos) {
		menu_close(app)
		return
	}
	if fixed_window(ctx, "!menu", r, {.NO_TITLE, .NO_RESIZE, .NO_CLOSE, .NO_SCROLL}, Z_OVERLAY) {
		for it in items {
			if list_row(ui, ITEM_LABELS[it], 0, ITEM_LABELS[it]) && !ui.right_click {
				menu_close(app)
				menu_do(app, it)
			}
			ui.right_click = false
		}
		mu.end_window(ctx)
	}
}

@(private = "file")
point_in :: proc(r: mu.Rect, p: mu.Vec2) -> bool {
	return p.x >= r.x && p.y >= r.y && p.x < r.x + r.w && p.y < r.y + r.h
}

@(private = "file")
menu_do :: proc(app: ^App, it: Menu_Item) {
	m := &app.menu
	switch it {
	case .Preview:
		preview_open(app, m.path, m.dir)
	case .Download:
		download_start(app, m.path)
	case .Open_Folder:
		reveal(m.path, m.dir)
	case .Copy_Path:
		clipboard_set(m.path)
		show_toast(app, "Copied the path.")
	case .Close_Buffer:
		buffer_close(app, m.buf)
	}
}

// reveal shows a local file in the file manager: selected in its folder
// in Finder, or its folder opened elsewhere. A folder opens itself.
@(private = "file")
reveal :: proc(path: string, dir: bool) {
	when ODIN_OS == .Darwin {
		if dir {
			job_start(.Open_Url, {"open", path})
		} else {
			job_start(.Open_Url, {"open", "-R", path})
		}
	} else {
		job_start(.Open_Url, {"xdg-open", dir ? path : path[:max(strings.last_index_byte(path, '/'), 1)]})
	}
}
