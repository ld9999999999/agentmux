package ngam

// Downloads copy a file from a remote session into ~/Downloads on this
// machine. nvim reads the file one chunk at a time (vim.uv.fs_read) and
// sends it over the session's own connection, as the preview server does.
// ngam writes each chunk to disk and then asks for the next one. When a
// name is already taken in Downloads, ngam adds " (1)", " (2)" and so on
// before the extension, as browsers do.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import mp "msgpack"

@(private = "file")
Download :: struct {
	path:   string, // on nvim's machine
	dest:   string, // in ~/Downloads
	file:   ^os.File,
	offset: i64,
}

// Lua run in nvim. It returns {'file', size, data} with up to len bytes
// from offset off, or {'error', message}.
@(private = "file")
READ_LUA :: `
local path, off, len = ...
local st = vim.uv.fs_stat(path)
if not st or st.type ~= 'file' then return {'error', 'cannot read ' .. path} end
local fd = vim.uv.fs_open(path, 'r', 0)
if not fd then return {'error', 'cannot open ' .. path} end
local data = ''
if off < st.size then data = vim.uv.fs_read(fd, len, off) or '' end
vim.uv.fs_close(fd)
return {'file', st.size, data}
`

download_start :: proc(app: ^App, path: string) {
	home, err := os.user_home_dir(context.temp_allocator)
	if err != nil {
		show_toast(app, "Cannot find the home folder.")
		return
	}
	dir, _ := filepath.join({home, "Downloads"}, context.temp_allocator)
	_ = os.make_directory_all(dir)
	dest := free_name(dir, filepath.base(path))
	f, ferr := os.open(dest, {.Write, .Create, .Excl}, os.Permissions_Default_File)
	if ferr != nil {
		show_toast(app, fmt.tprintf("Cannot write %s.", dest))
		return
	}
	d := new(Download)
	d.path = strings.clone(path)
	d.dest = strings.clone(dest)
	d.file = f
	show_toast(app, fmt.tprintf("Downloading %s…", filepath.base(path)))
	next_chunk(app, d)
}

// free_name returns dir/name, or dir/"stem (n).ext" for the first free n.
@(private = "file")
free_name :: proc(dir, name: string) -> string {
	p, _ := filepath.join({dir, name}, context.temp_allocator)
	if !os.exists(p) {
		return p
	}
	ext := filepath.ext(name)
	stem := name[:len(name) - len(ext)]
	for n := 1; ; n += 1 {
		p, _ = filepath.join({dir, fmt.tprintf("%s (%d)%s", stem, n, ext)}, context.temp_allocator)
		if !os.exists(p) {
			return p
		}
	}
}

@(private = "file")
next_chunk :: proc(app: ^App, d: ^Download) {
	if !exec_lua(app, READ_LUA, {d.path, d.offset, i64(CHUNK)}, chunk_done, d) {
		finish(app, d, "The session closed before the download finished.")
	}
}

@(private = "file")
chunk_done :: proc(app: ^App, result: mp.Value, failed: bool, user: rawptr) {
	d := (^Download)(user)
	r := mp.as_array(result)
	switch {
	case failed:
		finish(app, d, "The download failed; see nvim's messages (:messages).")
		return
	case mp.as_str(mp.at(r, 0)) != "file":
		finish(app, d, fmt.tprintf("Download failed: %s.", mp.as_str(mp.at(r, 1))))
		return
	}
	size := mp.as_int(mp.at(r, 1))
	data := transmute([]byte)mp.as_str(mp.at(r, 2))
	if len(data) > 0 {
		if _, err := os.write(d.file, data); err != nil {
			finish(app, d, fmt.tprintf("Cannot write %s.", d.dest))
			return
		}
		d.offset += i64(len(data))
	}
	if d.offset < size && len(data) > 0 {
		next_chunk(app, d)
		return
	}
	finish(app, d, "")
}

// finish closes the download. A failure message means the download
// failed, so finish removes the partial file and shows the message.
@(private = "file")
finish :: proc(app: ^App, d: ^Download, failure: string) {
	os.close(d.file)
	if failure != "" {
		_ = os.remove(d.dest)
		show_toast(app, failure)
	} else {
		home, _ := os.user_home_dir(context.temp_allocator)
		shown := d.dest
		if strings.has_prefix(shown, home) {
			shown = strings.concatenate({"~", shown[len(home):]}, context.temp_allocator)
		}
		show_toast(app, fmt.tprintf("Downloaded to %s", shown))
	}
	delete(d.path)
	delete(d.dest)
	free(d)
}
