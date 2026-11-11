package msgpack

// A small msgpack encoder and decoder, covering what nvim's msgpack-RPC
// uses: nil, bool, ints, floats, strings, binary, arrays, maps and ext
// types. Odin's core library lacks msgpack, so ngam has its own.

import "core:encoding/endian"

Bin :: distinct []byte

Ext :: struct {
	type: i8,
	data: []byte,
}

Map_Entry :: struct {
	key, value: Value,
}

// A decoded msgpack value. The nil union value is msgpack's nil. Strings,
// Bin and Ext data point into the buffer they were decoded from, so a Value
// stays valid only while that buffer lives.
Value :: union {
	bool,
	i64,
	f64,
	string,
	Bin,
	[]Value,
	[]Map_Entry,
	Ext,
}

Decode_Error :: enum {
	None,
	Incomplete, // the buffer ends before the value does: wait for more bytes
	Invalid,    // a byte outside the msgpack format
}

// ---- Encoding ----

enc_nil :: proc(b: ^[dynamic]byte) {
	append(b, 0xc0)
}

enc_bool :: proc(b: ^[dynamic]byte, v: bool) {
	append(b, v ? 0xc3 : 0xc2)
}

enc_int :: proc(b: ^[dynamic]byte, v: i64) {
	switch {
	case v >= 0 && v <= 0x7f:
		append(b, byte(v))
	case v < 0 && v >= -32:
		append(b, byte(i8(v)))
	case v >= 0 && v <= 0xffff:
		append(b, 0xcd, byte(v >> 8), byte(v))
	case v >= 0 && v <= 0xffff_ffff:
		append(b, 0xce)
		enc_be32(b, u32(v))
	case v >= 0:
		append(b, 0xcf)
		enc_be64(b, u64(v))
	case v >= -0x8000_0000:
		append(b, 0xd2)
		enc_be32(b, u32(i32(v)))
	case:
		append(b, 0xd3)
		enc_be64(b, u64(v))
	}
}

@(private)
enc_float :: proc(b: ^[dynamic]byte, v: f64) {
	append(b, 0xcb)
	enc_be64(b, transmute(u64)v)
}

enc_str :: proc(b: ^[dynamic]byte, s: string) {
	n := len(s)
	switch {
	case n < 32:
		append(b, 0xa0 | byte(n))
	case n <= 0xff:
		append(b, 0xd9, byte(n))
	case n <= 0xffff:
		append(b, 0xda, byte(n >> 8), byte(n))
	case:
		append(b, 0xdb)
		enc_be32(b, u32(n))
	}
	append(b, s)
}

enc_array :: proc(b: ^[dynamic]byte, n: int) {
	switch {
	case n < 16:
		append(b, 0x90 | byte(n))
	case n <= 0xffff:
		append(b, 0xdc, byte(n >> 8), byte(n))
	case:
		append(b, 0xdd)
		enc_be32(b, u32(n))
	}
}

enc_map :: proc(b: ^[dynamic]byte, n: int) {
	switch {
	case n < 16:
		append(b, 0x80 | byte(n))
	case n <= 0xffff:
		append(b, 0xde, byte(n >> 8), byte(n))
	case:
		append(b, 0xdf)
		enc_be32(b, u32(n))
	}
}

// enc_value encodes any Value, for arguments built as Values.
enc_value :: proc(b: ^[dynamic]byte, v: Value) {
	switch x in v {
	case nil:
		enc_nil(b)
	case bool:
		enc_bool(b, x)
	case i64:
		enc_int(b, x)
	case f64:
		enc_float(b, x)
	case string:
		enc_str(b, x)
	case Bin:
		n := len(x)
		switch {
		case n <= 0xff:
			append(b, 0xc4, byte(n))
		case n <= 0xffff:
			append(b, 0xc5, byte(n >> 8), byte(n))
		case:
			append(b, 0xc6)
			enc_be32(b, u32(n))
		}
		append(b, ..([]byte)(x))
	case []Value:
		enc_array(b, len(x))
		for e in x {
			enc_value(b, e)
		}
	case []Map_Entry:
		enc_map(b, len(x))
		for e in x {
			enc_value(b, e.key)
			enc_value(b, e.value)
		}
	case Ext:
		// ngam sends nvim only plain values, so an ext becomes nil.
		enc_nil(b)
	}
}

// map_get returns the value for key in a msgpack map, or nil.
map_get :: proc(m: []Map_Entry, key: string) -> Value {
	for e in m {
		if as_str(e.key) == key {
			return e.value
		}
	}
	return nil
}

@(private = "file")
enc_be32 :: proc(b: ^[dynamic]byte, v: u32) {
	append(b, byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v))
}

@(private = "file")
enc_be64 :: proc(b: ^[dynamic]byte, v: u64) {
	enc_be32(b, u32(v >> 32))
	enc_be32(b, u32(v))
}

// ---- Decoding ----

// decode reads one value from buf starting at pos^ and moves pos^ past it.
// Arrays and maps are allocated with context.allocator.
decode :: proc(buf: []byte, pos: ^int) -> (v: Value, err: Decode_Error) {
	if pos^ >= len(buf) {
		return nil, .Incomplete
	}
	t := buf[pos^]
	pos^ += 1
	switch {
	case t <= 0x7f:
		return i64(t), .None
	case t >= 0xe0:
		return i64(i8(t)), .None
	case t >= 0xa0 && t <= 0xbf:
		return dec_str(buf, pos, int(t & 0x1f))
	case t >= 0x90 && t <= 0x9f:
		return dec_array(buf, pos, int(t & 0x0f))
	case t >= 0x80 && t <= 0x8f:
		return dec_map(buf, pos, int(t & 0x0f))
	}
	switch t {
	case 0xc0:
		return nil, .None
	case 0xc2:
		return false, .None
	case 0xc3:
		return true, .None
	case 0xc4, 0xc5, 0xc6: // bin 8, 16, 32
		n := dec_len(buf, pos, t - 0xc4) or_return
		data := take(buf, pos, n) or_return
		return Bin(data), .None
	case 0xc7, 0xc8, 0xc9: // ext 8, 16, 32
		n := dec_len(buf, pos, t - 0xc7) or_return
		return dec_ext(buf, pos, n)
	case 0xca:
		b := take(buf, pos, 4) or_return
		u, _ := endian.get_u32(b, .Big)
		return f64(transmute(f32)u), .None
	case 0xcb:
		b := take(buf, pos, 8) or_return
		u, _ := endian.get_u64(b, .Big)
		return transmute(f64)u, .None
	case 0xcc:
		b := take(buf, pos, 1) or_return
		return i64(b[0]), .None
	case 0xcd:
		b := take(buf, pos, 2) or_return
		u, _ := endian.get_u16(b, .Big)
		return i64(u), .None
	case 0xce:
		b := take(buf, pos, 4) or_return
		u, _ := endian.get_u32(b, .Big)
		return i64(u), .None
	case 0xcf:
		// Values above the i64 range wrap; nvim keeps to the i64 range.
		b := take(buf, pos, 8) or_return
		u, _ := endian.get_u64(b, .Big)
		return i64(u), .None
	case 0xd0:
		b := take(buf, pos, 1) or_return
		return i64(i8(b[0])), .None
	case 0xd1:
		b := take(buf, pos, 2) or_return
		u, _ := endian.get_u16(b, .Big)
		return i64(i16(u)), .None
	case 0xd2:
		b := take(buf, pos, 4) or_return
		u, _ := endian.get_u32(b, .Big)
		return i64(i32(u)), .None
	case 0xd3:
		b := take(buf, pos, 8) or_return
		u, _ := endian.get_u64(b, .Big)
		return i64(u), .None
	case 0xd4, 0xd5, 0xd6, 0xd7, 0xd8: // fixext 1, 2, 4, 8, 16
		return dec_ext(buf, pos, 1 << (t - 0xd4))
	case 0xd9, 0xda, 0xdb: // str 8, 16, 32
		n := dec_len(buf, pos, t - 0xd9) or_return
		return dec_str(buf, pos, n)
	case 0xdc, 0xdd: // array 16, 32
		n := dec_len(buf, pos, t - 0xdc + 1) or_return
		return dec_array(buf, pos, n)
	case 0xde, 0xdf: // map 16, 32
		n := dec_len(buf, pos, t - 0xde + 1) or_return
		return dec_map(buf, pos, n)
	}
	return nil, .Invalid
}

// skip moves pos^ past one value without allocating. It checks that a
// whole message has arrived before ngam decodes it.
skip :: proc(buf: []byte, pos: ^int) -> Decode_Error {
	// count is how many values are still to be skipped; arrays and maps
	// add their elements to it.
	count := 1
	for count > 0 {
		count -= 1
		if pos^ >= len(buf) {
			return .Incomplete
		}
		t := buf[pos^]
		pos^ += 1
		n := 0
		switch {
		case t <= 0x7f || t >= 0xe0 || t == 0xc0 || t == 0xc2 || t == 0xc3:
			continue
		case t >= 0xa0 && t <= 0xbf:
			n = int(t & 0x1f)
		case t >= 0x90 && t <= 0x9f:
			count += int(t & 0x0f)
			continue
		case t >= 0x80 && t <= 0x8f:
			count += 2 * int(t & 0x0f)
			continue
		case t == 0xc4 || t == 0xc5 || t == 0xc6:
			n = dec_len(buf, pos, t - 0xc4) or_return
		case t == 0xc7 || t == 0xc8 || t == 0xc9:
			n = dec_len(buf, pos, t - 0xc7) or_return
			n += 1 // the ext type byte
		case t == 0xca:
			n = 4
		case t == 0xcb:
			n = 8
		case t >= 0xcc && t <= 0xcf:
			n = 1 << (t - 0xcc)
		case t >= 0xd0 && t <= 0xd3:
			n = 1 << (t - 0xd0)
		case t >= 0xd4 && t <= 0xd8:
			n = 1 + (1 << (t - 0xd4))
		case t == 0xd9 || t == 0xda || t == 0xdb:
			n = dec_len(buf, pos, t - 0xd9) or_return
		case t == 0xdc || t == 0xdd:
			c := dec_len(buf, pos, t - 0xdc + 1) or_return
			count += c
			continue
		case t == 0xde || t == 0xdf:
			c := dec_len(buf, pos, t - 0xde + 1) or_return
			count += 2 * c
			continue
		case:
			return .Invalid
		}
		_ = take(buf, pos, n) or_return
	}
	return .None
}

// dec_len reads a big-endian length of 1, 2 or 4 bytes (size 0, 1 or 2).
@(private = "file")
dec_len :: proc(buf: []byte, pos: ^int, size: byte) -> (n: int, err: Decode_Error) {
	b := take(buf, pos, 1 << size) or_return
	switch size {
	case 0:
		return int(b[0]), .None
	case 1:
		u, _ := endian.get_u16(b, .Big)
		return int(u), .None
	case:
		u, _ := endian.get_u32(b, .Big)
		return int(u), .None
	}
}

@(private = "file")
take :: proc(buf: []byte, pos: ^int, n: int) -> (b: []byte, err: Decode_Error) {
	if pos^ + n > len(buf) {
		return nil, .Incomplete
	}
	b = buf[pos^:pos^ + n]
	pos^ += n
	return b, .None
}

@(private = "file")
dec_str :: proc(buf: []byte, pos: ^int, n: int) -> (v: Value, err: Decode_Error) {
	b := take(buf, pos, n) or_return
	return string(b), .None
}

@(private = "file")
dec_ext :: proc(buf: []byte, pos: ^int, n: int) -> (v: Value, err: Decode_Error) {
	t := take(buf, pos, 1) or_return
	data := take(buf, pos, n) or_return
	return Ext{type = i8(t[0]), data = data}, .None
}

@(private = "file")
dec_array :: proc(buf: []byte, pos: ^int, n: int) -> (v: Value, err: Decode_Error) {
	// Each element takes at least one byte, so the length must fit in the
	// bytes left. Checking this first keeps a corrupt length from
	// allocating a huge slice.
	if n > len(buf) - pos^ {
		return nil, .Incomplete
	}
	items := make([]Value, n)
	for i in 0 ..< n {
		items[i] = decode(buf, pos) or_return
	}
	return items, .None
}

@(private = "file")
dec_map :: proc(buf: []byte, pos: ^int, n: int) -> (v: Value, err: Decode_Error) {
	if 2 * n > len(buf) - pos^ {
		return nil, .Incomplete
	}
	entries := make([]Map_Entry, n)
	for i in 0 ..< n {
		entries[i].key = decode(buf, pos) or_return
		entries[i].value = decode(buf, pos) or_return
	}
	return entries, .None
}

// ---- Reading values ----

// These helpers read a Value as one type and return a zero value for any
// other type. This keeps the redraw handlers short.

as_int :: proc(v: Value) -> i64 {
	#partial switch x in v {
	case i64:
		return x
	case f64:
		return i64(x)
	case bool:
		return x ? 1 : 0
	}
	return 0
}

as_str :: proc(v: Value) -> string {
	#partial switch x in v {
	case string:
		return x
	case Bin:
		return string(x)
	}
	return ""
}

as_bool :: proc(v: Value) -> bool {
	#partial switch x in v {
	case bool:
		return x
	case i64:
		return x != 0
	}
	return false
}

as_array :: proc(v: Value) -> []Value {
	if a, ok := v.([]Value); ok {
		return a
	}
	return nil
}

as_map :: proc(v: Value) -> []Map_Entry {
	if m, ok := v.([]Map_Entry); ok {
		return m
	}
	return nil
}

// at returns a[i], or nil when a is too short.
at :: proc(a: []Value, i: int) -> Value {
	if i < len(a) {
		return a[i]
	}
	return nil
}
