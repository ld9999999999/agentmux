package markdown

// A small Markdown renderer, so the preview server can show .md files as
// pages. It covers the common parts of CommonMark and GitHub's additions:
// headings, paragraphs, emphasis, code, block quotes, lists and task lists,
// links, images, rules, line breaks and pipe tables. It covers only part
// of CommonMark, so some odd corners come out a little differently.
//
// Raw HTML in the source shows as text, and links with javascript: and
// similar URLs go nowhere. This matters: script in a Markdown file would
// run on the preview server's origin, which can read every file in the
// session.
//
// Blocks are found line by line. A block quote or list item takes its
// lines, drops its own marker and indent from them, and parses what is left
// as blocks again, which is how nesting works. Text inside a block is then
// parsed for inline parts (code, links, emphasis and so on).

import "core:strconv"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

@(private = "file")
Md :: struct {
	b:      strings.Builder, // the HTML
	refs:   map[string]Md_Ref, // link reference definitions, by normalized label
	slugs:  map[string]int, // heading ids used so far, to keep them unique
	prefix: string, // a task list check box, for the start of its item's first paragraph
}

@(private = "file")
Md_Ref :: struct {
	url, title: string,
}

// to_html renders Markdown source as an HTML fragment, the part that goes
// inside <body>. The result is in allocator; everything else it makes is
// in the temp allocator.
to_html :: proc(src: string, allocator := context.temp_allocator) -> string {
	md: Md
	md.b = strings.builder_make(allocator)
	// All the scratch work goes in the temp allocator, so it is all freed
	// at once.
	context.allocator = context.temp_allocator
	md.refs = make(map[string]Md_Ref)
	md.slugs = make(map[string]int)
	lines := md_split(src)
	md_collect_refs(&md, lines)
	md_blocks(&md, lines, false)
	return strings.to_string(md.b)
}

// page returns a whole HTML page for a Markdown file called name: the
// rendered text in a readable column, a style sheet that follows the
// system's light or dark mode, and tail (such as a script tag) at the end
// of the body. It is in the temp allocator.
page :: proc(name, src, tail: string) -> string {
	context.allocator = context.temp_allocator
	return strings.concatenate(
		{
			`<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>`,
			md_esc_str(name),
			"</title>\n<style>\n",
			MD_CSS,
			"</style>\n</head>\n<body><main class=\"markdown-body\">\n",
			to_html(src),
			"</main>\n",
			tail,
			"\n</body></html>\n",
		},
	)
}

// The page style: close to how GitHub shows a README.
@(private = "file")
MD_CSS :: `:root {
  color-scheme: light dark;
  --fg: #1f2328; --bg: #ffffff; --muted: #59636e; --line: #d1d9e0;
  --code-bg: #f6f8fa; --inline-bg: rgba(129, 139, 152, 0.12); --link: #0969da;
}
@media (prefers-color-scheme: dark) {
  :root {
    --fg: #f0f6fc; --bg: #0d1117; --muted: #9198a1; --line: #3d444d;
    --code-bg: #151b23; --inline-bg: rgba(101, 108, 118, 0.2); --link: #4493f8;
  }
}
html { background: var(--bg); }
body {
  margin: 0; color: var(--fg); background: var(--bg);
  font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans", Helvetica, Arial, sans-serif;
}
main { max-width: 860px; margin: 0 auto; padding: 32px 24px 64px; overflow-wrap: break-word; }
main > :first-child { margin-top: 0; }
h1, h2, h3, h4, h5, h6 { margin: 24px 0 16px; font-weight: 600; line-height: 1.25; }
h1 { font-size: 2em; padding-bottom: 0.3em; border-bottom: 1px solid var(--line); }
h2 { font-size: 1.5em; padding-bottom: 0.3em; border-bottom: 1px solid var(--line); }
h3 { font-size: 1.25em; }
h4 { font-size: 1em; }
h5 { font-size: 0.875em; }
h6 { font-size: 0.85em; color: var(--muted); }
p, blockquote, ul, ol, table, pre { margin: 0 0 16px; }
a { color: var(--link); text-decoration: none; }
a:hover { text-decoration: underline; }
code, pre {
  font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace;
  font-size: 85%;
}
code { padding: 0.2em 0.4em; border-radius: 6px; background: var(--inline-bg); }
pre { padding: 16px; overflow: auto; line-height: 1.45; border-radius: 6px; background: var(--code-bg); }
pre code { padding: 0; font-size: 100%; background: none; white-space: pre; tab-size: 4; }
blockquote { margin-left: 0; margin-right: 0; padding: 0 1em; color: var(--muted); border-left: 0.25em solid var(--line); }
blockquote > :last-child { margin-bottom: 0; }
ul, ol { padding-left: 2em; }
ul ul, ul ol, ol ol, ol ul { margin-bottom: 0; }
li + li, li > ul, li > ol { margin-top: 0.25em; }
li > p { margin-top: 16px; }
.task-list-item { list-style-type: none; }
.task-list-item input { margin: 0 0.2em 0.25em -1.4em; vertical-align: middle; }
table { display: block; width: max-content; max-width: 100%; overflow: auto; border-collapse: collapse; border-spacing: 0; }
th, td { padding: 6px 13px; border: 1px solid var(--line); }
th { font-weight: 600; }
tr:nth-child(2n) { background: var(--code-bg); }
hr { height: 0.25em; margin: 24px 0; padding: 0; border: 0; background: var(--line); }
img { max-width: 100%; box-sizing: content-box; }
`

// md_split splits the source into lines. Tabs stay in the lines, so code
// keeps them; indents are measured in columns, with tab stops every 4.
@(private = "file")
md_split :: proc(src: string) -> []string {
	s := strings.trim_prefix(src, "\xef\xbb\xbf") // a byte order mark
	lines := make([dynamic]string)
	for len(s) > 0 {
		end := strings.index_any(s, "\r\n")
		line: string
		if end < 0 {
			line, s = s, ""
		} else {
			line = s[:end]
			if s[end] == '\r' && end + 1 < len(s) && s[end + 1] == '\n' {
				s = s[end + 2:]
			} else {
				s = s[end + 1:]
			}
		}
		append(&lines, line)
	}
	return lines[:]
}

@(private = "file")
md_expand_tabs :: proc(line: string) -> string {
	n := 0
	for n < len(line) && (line[n] == ' ' || line[n] == '\t') {
		n += 1
	}
	if strings.index_byte(line[:n], '\t') < 0 {
		return line
	}
	b := strings.builder_make()
	col := 0
	for c in transmute([]byte)line[:n] {
		strings.write_byte(&b, ' ')
		col += 1
		if c == '\t' {
			for col % 4 != 0 {
				strings.write_byte(&b, ' ')
				col += 1
			}
		}
	}
	strings.write_string(&b, line[n:])
	return strings.to_string(b)
}

// md_indent returns the number of columns a line's indent takes. An indent
// of 3 or less is all spaces (a tab goes to column 4), so then it is also
// the number of bytes.
@(private = "file")
md_indent :: proc(line: string) -> int {
	col := 0
	for c in transmute([]byte)line {
		switch c {
		case ' ':
			col += 1
		case '\t':
			col += 4 - col % 4
		case:
			return col
		}
	}
	return col
}

// md_strip takes up to cols columns of indent off a line. When that ends
// inside a tab, the rest of the tab's width stays as spaces.
@(private = "file")
md_strip :: proc(line: string, cols: int) -> string {
	col := 0
	for k := 0; k < len(line); k += 1 {
		if col >= cols {
			return line[k:]
		}
		switch line[k] {
		case ' ':
			col += 1
		case '\t':
			next := col + 4 - col % 4
			if next > cols {
				return strings.concatenate({strings.repeat(" ", next - cols), line[k + 1:]})
			}
			col = next
		case:
			return line[k:]
		}
	}
	return ""
}

@(private = "file")
md_blank :: proc(line: string) -> bool {
	return strings.trim_space(line) == ""
}

// md_blocks renders lines as blocks. In a tight list item (tight),
// paragraphs skip the <p> tags.
@(private = "file")
md_blocks :: proc(md: ^Md, lines: []string, tight: bool) {
	i := 0
	for i < len(lines) {
		line := lines[i]
		if md_blank(line) {
			i += 1
			continue
		}
		if md_indent(line) >= 4 {
			i = md_code_block(md, lines, i)
			continue
		}
		if ch, n, indent, info, ok := md_fence(line); ok {
			i = md_fenced(md, lines, i, ch, n, indent, info)
			continue
		}
		if level, text, ok := md_atx(line); ok {
			md_heading(md, level, text)
			i += 1
			continue
		}
		if md_hr(line) {
			strings.write_string(&md.b, "<hr />\n")
			i += 1
			continue
		}
		if _, ok := md_quote_strip(line); ok {
			i = md_quote(md, lines, i)
			continue
		}
		if m, ok := md_marker(line); ok {
			i = md_list(md, lines, i, m)
			continue
		}
		// md_collect_refs already read the definitions, and they produce
		// no output.
		if _, _, ok := md_ref_def(line); ok {
			i += 1
			continue
		}
		if i + 1 < len(lines) && md_table_start(line, lines[i + 1]) {
			i = md_table(md, lines, i)
			continue
		}
		i = md_paragraph(md, lines, i, tight)
	}
}

// md_interrupts reports whether a line starts a block that ends a
// paragraph before it.
@(private = "file")
md_interrupts :: proc(line: string) -> bool {
	if md_indent(line) > 3 {
		return false
	}
	if _, _, _, _, ok := md_fence(line); ok {
		return true
	}
	if _, _, ok := md_atx(line); ok {
		return true
	}
	if md_hr(line) {
		return true
	}
	if _, ok := md_quote_strip(line); ok {
		return true
	}
	// As in CommonMark, only a numbered list that starts at 1 can begin
	// right under a paragraph, so a line like "2019. was a year" stays text.
	if m, ok := md_marker(line); ok && m.rest != "" && (!m.ordered || m.start == 1) {
		return true
	}
	return false
}

// md_paragraph renders the paragraph that starts at lines[start], or a
// heading when it is underlined with === or ---. It returns the next line.
@(private = "file")
md_paragraph :: proc(md: ^Md, lines: []string, start: int, tight: bool) -> int {
	i := start + 1
	for i < len(lines) {
		line := lines[i]
		if md_blank(line) {
			break
		}
		if md_indent(line) < 4 {
			if level := md_setext(line); level > 0 {
				md_heading(md, level, md_join(lines[start:i]))
				return i + 1
			}
			if md_interrupts(line) || (i + 1 < len(lines) && md_table_start(line, lines[i + 1])) {
				break
			}
		}
		i += 1
	}
	if !tight {
		strings.write_string(&md.b, "<p>")
	}
	strings.write_string(&md.b, md.prefix)
	md.prefix = ""
	strings.write_string(&md.b, md_inline(md, md_join(lines[start:i]), false))
	if !tight {
		strings.write_string(&md.b, "</p>")
	}
	strings.write_byte(&md.b, '\n')
	return i
}

// md_join joins a paragraph's lines without their indents.
@(private = "file")
md_join :: proc(lines: []string) -> string {
	parts := make([]string, len(lines))
	for line, k in lines {
		parts[k] = strings.trim_left_space(line)
	}
	return strings.trim_right_space(strings.join(parts, "\n"))
}

// md_setext returns the heading level of a === (1) or --- (2) underline,
// or 0.
@(private = "file")
md_setext :: proc(line: string) -> int {
	if md_indent(line) > 3 {
		return 0
	}
	s := strings.trim_space(line)
	if s == "" || (s[0] != '=' && s[0] != '-') {
		return 0
	}
	for k in 0 ..< len(s) {
		if s[k] != s[0] {
			return 0
		}
	}
	return s[0] == '=' ? 1 : 2
}

// md_atx reads a "# Heading" line.
@(private = "file")
md_atx :: proc(line: string) -> (level: int, text: string, ok: bool) {
	ind := md_indent(line)
	if ind > 3 {
		return
	}
	s := line[ind:]
	n := 0
	for n < len(s) && s[n] == '#' {
		n += 1
	}
	if n == 0 || n > 6 || (n < len(s) && s[n] != ' ' && s[n] != '\t') {
		return
	}
	text = strings.trim_space(s[n:])
	// Drop a closing run of #s when a space comes before it.
	k := len(text)
	for k > 0 && text[k - 1] == '#' {
		k -= 1
	}
	if k == 0 {
		text = ""
	} else if k < len(text) && (text[k - 1] == ' ' || text[k - 1] == '\t') {
		text = strings.trim_right_space(text[:k])
	}
	return n, text, true
}

// md_heading writes a heading, with an id made from its text as GitHub
// does, so links to #some-heading work.
@(private = "file")
md_heading :: proc(md: ^Md, level: int, text: string) {
	inner := md_inline(md, text, false)
	digits := "123456"
	digit := digits[level - 1:level]
	strings.write_string(&md.b, "<h")
	strings.write_string(&md.b, digit)
	if slug := md_slug(md, inner); slug != "" {
		strings.write_string(&md.b, ` id="`)
		strings.write_string(&md.b, slug)
		strings.write_byte(&md.b, '"')
	}
	strings.write_byte(&md.b, '>')
	strings.write_string(&md.b, inner)
	strings.write_string(&md.b, "</h")
	strings.write_string(&md.b, digit)
	strings.write_string(&md.b, ">\n")
}

// md_slug makes a heading's id from its HTML: the text in lower case, with
// spaces as dashes and other punctuation dropped. A repeated id gets -1,
// -2 and so on.
@(private = "file")
md_slug :: proc(md: ^Md, html: string) -> string {
	text := md_strip_tags(html)
	b := strings.builder_make()
	for i := 0; i < len(text); {
		r, size := utf8.decode_rune_in_string(text[i:])
		if r == '&' {
			// Drop an escaped character, such as &amp;.
			if e := strings.index_byte(text[i:], ';'); e >= 0 {
				i += e + 1
				continue
			}
		}
		i += size
		switch {
		case r == ' ':
			strings.write_byte(&b, '-')
		case r == '-' || r == '_' || unicode.is_letter(r) || unicode.is_digit(r):
			strings.write_rune(&b, unicode.to_lower(r))
		}
	}
	base := strings.to_string(b)
	if base == "" {
		return ""
	}
	n := md.slugs[base]
	md.slugs[base] = n + 1
	if n == 0 {
		return base
	}
	buf: [24]byte
	return strings.concatenate({base, "-", strconv.write_int(buf[:], i64(n), 10)})
}

// md_strip_tags returns the text of some HTML with its tags removed,
// still escaped.
@(private = "file")
md_strip_tags :: proc(html: string) -> string {
	b := strings.builder_make()
	in_tag := false
	for c in transmute([]byte)html {
		switch {
		case c == '<':
			in_tag = true
		case c == '>' && in_tag:
			in_tag = false
		case !in_tag:
			strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b)
}

@(private = "file")
md_hr :: proc(line: string) -> bool {
	if md_indent(line) > 3 {
		return false
	}
	ch: u8 = 0
	n := 0
	for c in transmute([]byte)line {
		switch c {
		case ' ', '\t':
		case '-', '*', '_':
			if ch != 0 && c != ch {
				return false
			}
			ch = c
			n += 1
		case:
			return false
		}
	}
	return n >= 3
}

// md_code_block renders an indented code block.
@(private = "file")
md_code_block :: proc(md: ^Md, lines: []string, start: int) -> int {
	end := start
	for i := start; i < len(lines) && (md_blank(lines[i]) || md_indent(lines[i]) >= 4); i += 1 {
		if !md_blank(lines[i]) {
			end = i + 1 // the block ends at its last nonblank line
		}
	}
	strings.write_string(&md.b, "<pre><code>")
	for line in lines[start:end] {
		md_esc(&md.b, md_strip(line, 4))
		strings.write_byte(&md.b, '\n')
	}
	strings.write_string(&md.b, "</code></pre>\n")
	return end
}

// md_fence reads the line that opens a fenced code block: ``` or ~~~ (or
// more), then an info string whose first word is the language.
@(private = "file")
md_fence :: proc(line: string) -> (ch: u8, n: int, indent: int, info: string, ok: bool) {
	indent = md_indent(line)
	if indent > 3 || indent >= len(line) {
		return
	}
	ch = line[indent]
	if ch != '`' && ch != '~' {
		return
	}
	for indent + n < len(line) && line[indent + n] == ch {
		n += 1
	}
	info = strings.trim_space(line[indent + n:])
	if n < 3 || (ch == '`' && strings.index_byte(info, '`') >= 0) {
		return
	}
	ok = true
	return
}

@(private = "file")
md_fence_close :: proc(line: string, ch: u8, n: int) -> bool {
	ind := md_indent(line)
	if ind > 3 {
		return false
	}
	k := ind
	for k < len(line) && line[k] == ch {
		k += 1
	}
	return k - ind >= n && md_blank(line[k:])
}

// md_fenced renders a fenced code block. A block that lacks a closing
// fence runs to the end of its container.
@(private = "file")
md_fenced :: proc(md: ^Md, lines: []string, start: int, ch: u8, n, indent: int, info: string) -> int {
	strings.write_string(&md.b, "<pre><code")
	lang := info
	if sp := strings.index_any(lang, " \t"); sp >= 0 {
		lang = lang[:sp]
	}
	if lang != "" {
		strings.write_string(&md.b, ` class="language-`)
		md_esc(&md.b, md_unescape(lang))
		strings.write_byte(&md.b, '"')
	}
	strings.write_byte(&md.b, '>')
	i := start + 1
	for i < len(lines) {
		line := lines[i]
		i += 1
		if md_fence_close(line, ch, n) {
			break
		}
		// Take the fence's own indent off each line.
		md_esc(&md.b, md_strip(line, indent))
		strings.write_byte(&md.b, '\n')
	}
	strings.write_string(&md.b, "</code></pre>\n")
	return i
}

// md_quote_strip takes the > (and one space) off a block quote line.
@(private = "file")
md_quote_strip :: proc(line: string) -> (rest: string, ok: bool) {
	ind := md_indent(line)
	if ind > 3 || ind >= len(line) || line[ind] != '>' {
		return
	}
	rest = line[ind + 1:]
	if len(rest) > 0 && rest[0] == ' ' {
		rest = rest[1:]
	}
	return rest, true
}

// md_quote renders a block quote. A plain line right after quoted text
// belongs to the quote's paragraph, even without its own > ("lazy"
// continuation).
@(private = "file")
md_quote :: proc(md: ^Md, lines: []string, start: int) -> int {
	inner := make([dynamic]string)
	i := start
	for i < len(lines) {
		line := lines[i]
		if rest, ok := md_quote_strip(line); ok {
			append(&inner, rest)
		} else if !md_blank(line) && len(inner) > 0 && !md_blank(inner[len(inner) - 1]) && !md_interrupts(line) {
			append(&inner, strings.trim_left_space(line))
		} else {
			break
		}
		i += 1
	}
	strings.write_string(&md.b, "<blockquote>\n")
	md_blocks(md, inner[:], false)
	strings.write_string(&md.b, "</blockquote>\n")
	return i
}

// Md_Marker is a list item's marker: "-", "+", "*", "1." or "1)".
@(private = "file")
Md_Marker :: struct {
	ordered: bool,
	ch:      u8, // the bullet, or the . or ) after the number
	start:   int, // the number
	width:   int, // the column the item's text starts at; later lines indented this far belong to the item
	rest:    string, // the text on the marker's line
}

@(private = "file")
md_marker :: proc(line: string) -> (m: Md_Marker, ok: bool) {
	ind := md_indent(line)
	if ind > 3 || ind >= len(line) {
		return
	}
	s := line[ind:]
	p := 0
	switch s[0] {
	case '-', '+', '*':
		m.ch = s[0]
		p = 1
	case '0' ..= '9':
		for p < len(s) && p < 9 && s[p] >= '0' && s[p] <= '9' {
			p += 1
		}
		if p >= len(s) || (s[p] != '.' && s[p] != ')') {
			return
		}
		m.ordered = true
		m.start, _ = strconv.parse_int(s[:p], 10)
		m.ch = s[p]
		p += 1
	case:
		return
	}
	if p < len(s) && s[p] != ' ' && s[p] != '\t' {
		return
	}
	rest := md_expand_tabs(s[p:])
	sp := md_indent(rest)
	switch {
	case md_blank(rest):
		m.width = ind + p + 1
		m.rest = ""
	case sp > 4:
		// The text is indented code: only one space belongs to the marker.
		m.width = ind + p + 1
		m.rest = rest[1:]
	case:
		m.width = ind + p + sp
		m.rest = rest[sp:]
	}
	ok = true
	return
}

// md_list renders a list and its items, and returns the line after it.
// A list is loose (its paragraphs get <p>, and so space between them) when
// a blank line separates its items or the blocks in one.
@(private = "file")
md_list :: proc(md: ^Md, lines: []string, start: int, first: Md_Marker) -> int {
	items := make([dynamic][]string)
	loose := false
	m := first
	i := start
	for {
		item := make([dynamic]string)
		append(&item, m.rest)
		i += 1
		item_lines: for i < len(lines) {
			line := lines[i]
			switch {
			case md_blank(line):
				append(&item, "")
			case md_indent(line) >= m.width:
				append(&item, md_strip(line, m.width))
			case !md_blank(item[len(item) - 1]) && !md_interrupts(line) && !md_is_marker(line):
				append(&item, strings.trim_left_space(line)) // lazy continuation
			case:
				break item_lines
			}
			i += 1
		}
		trailing := 0
		for len(item) > 1 && md_blank(item[len(item) - 1]) {
			pop(&item)
			trailing += 1
		}
		if md_inner_gap(item[:]) {
			loose = true
		}
		append(&items, item[:])
		if i < len(lines) && !md_hr(lines[i]) {
			if next, ok := md_marker(lines[i]); ok && next.ordered == first.ordered && next.ch == first.ch {
				if trailing > 0 {
					loose = true
				}
				m = next
				continue
			}
		}
		break
	}

	tag := first.ordered ? "ol" : "ul"
	strings.write_byte(&md.b, '<')
	strings.write_string(&md.b, tag)
	if first.ordered && first.start != 1 {
		buf: [24]byte
		strings.write_string(&md.b, ` start="`)
		strings.write_string(&md.b, strconv.write_int(buf[:], i64(first.start), 10))
		strings.write_byte(&md.b, '"')
	}
	strings.write_string(&md.b, ">\n")
	for body in items {
		if box, rest, ok := md_task(body[0]); ok {
			strings.write_string(&md.b, `<li class="task-list-item">`)
			body[0] = rest
			md.prefix = box
		} else {
			strings.write_string(&md.b, "<li>")
		}
		md_blocks(md, body, !loose)
		strings.write_string(&md.b, md.prefix) // the check box of an item without a paragraph
		md.prefix = ""
		strings.write_string(&md.b, "</li>\n")
	}
	strings.write_string(&md.b, "</")
	strings.write_string(&md.b, tag)
	strings.write_string(&md.b, ">\n")
	return i
}

@(private = "file")
md_is_marker :: proc(line: string) -> bool {
	_, ok := md_marker(line)
	return ok
}

// md_inner_gap reports whether an item's own blocks have a blank line
// between them. It skips blank lines inside a code block or a nested
// list.
@(private = "file")
md_inner_gap :: proc(item: []string) -> bool {
	for k := 0; k < len(item); k += 1 {
		if ch, n, _, _, ok := md_fence(item[k]); ok {
			for k + 1 < len(item) && !md_fence_close(item[k + 1], ch, n) {
				k += 1
			}
			k += 1
			continue
		}
		if k > 0 && k + 1 < len(item) && md_blank(item[k]) && !md_blank(item[k + 1]) && md_indent(item[k + 1]) == 0 && !md_is_marker(item[k + 1]) {
			return true
		}
	}
	return false
}

// md_task reads a task list item's "[ ] " or "[x] ", and returns its check
// box and the text after it.
@(private = "file")
md_task :: proc(text: string) -> (box: string, rest: string, ok: bool) {
	if len(text) < 3 || text[0] != '[' || text[2] != ']' || (len(text) > 3 && text[3] != ' ') {
		return
	}
	switch text[1] {
	case ' ':
		box = `<input type="checkbox" disabled /> `
	case 'x', 'X':
		box = `<input type="checkbox" checked disabled /> `
	case:
		return
	}
	return box, strings.trim_left_space(text[3:]), true
}

// md_ref_def reads a link reference definition on one line:
// [label]: url "title".
@(private = "file")
md_ref_def :: proc(line: string) -> (label: string, ref: Md_Ref, ok: bool) {
	if md_indent(line) > 3 {
		return
	}
	s := strings.trim_space(line)
	if !strings.has_prefix(s, "[") {
		return
	}
	close := -1
	for k := 1; k < len(s); k += 1 {
		if s[k] == '\\' {
			k += 1
			continue
		}
		if s[k] == '[' {
			return
		}
		if s[k] == ']' {
			close = k
			break
		}
	}
	if close < 2 || close + 1 >= len(s) || s[close + 1] != ':' {
		return
	}
	rest := strings.trim_space(s[close + 2:])
	if rest == "" {
		return
	}
	url: string
	if rest[0] == '<' {
		e := strings.index_byte(rest, '>')
		if e < 0 {
			return
		}
		url, rest = rest[1:e], rest[e + 1:]
	} else {
		e := strings.index_any(rest, " \t")
		if e < 0 {
			e = len(rest)
		}
		url, rest = rest[:e], rest[e:]
	}
	rest = strings.trim_space(rest)
	title := ""
	if rest != "" {
		first, last := rest[0], rest[len(rest) - 1]
		if len(rest) < 2 || !((first == '"' && last == '"') || (first == '\'' && last == '\'') || (first == '(' && last == ')')) {
			return
		}
		title = rest[1:len(rest) - 1]
	}
	return md_label(s[1:close]), {md_unescape(url), md_unescape(title)}, true
}

// md_collect_refs finds the link reference definitions before rendering,
// since a link may come before its definition. It looks inside block quotes
// and list items too, and skips fenced code.
@(private = "file")
md_collect_refs :: proc(md: ^Md, lines: []string) {
	fence: u8 = 0
	fence_n := 0
	after_text := false // the line before was paragraph text, which a definition cannot follow
	for line in lines {
		s := line
		for {
			t := strings.trim_left_space(s)
			if strings.has_prefix(t, ">") {
				s = t[1:]
				continue
			}
			if m, ok := md_marker(t); ok && m.rest != "" {
				s = m.rest
				continue
			}
			s = t
			break
		}
		if fence != 0 {
			if md_fence_close(s, fence, fence_n) {
				fence = 0
			}
			continue
		}
		if ch, n, _, _, ok := md_fence(s); ok {
			fence, fence_n = ch, n
			after_text = false
			continue
		}
		if !after_text {
			if label, ref, ok := md_ref_def(s); ok {
				if label not_in md.refs {
					md.refs[label] = ref
				}
				continue
			}
		}
		_, _, heading := md_atx(s)
		after_text = !md_blank(s) && !heading && !md_hr(s)
	}
}

// md_label normalizes a link label: it folds case and collapses runs of
// spaces.
@(private = "file")
md_label :: proc(s: string) -> string {
	return strings.to_lower(strings.join(strings.fields(s), " "))
}

// Md_Align is a table column's alignment.
@(private = "file")
Md_Align :: enum u8 {
	None,
	Left,
	Center,
	Right,
}

// md_cells splits a table row at its | characters, skipping \|.
@(private = "file")
md_cells :: proc(line: string) -> []string {
	s := strings.trim_space(line)
	s = strings.trim_prefix(s, "|")
	if strings.has_suffix(s, "|") && !strings.has_suffix(s, "\\|") {
		s = s[:len(s) - 1]
	}
	cells := make([dynamic]string)
	from := 0
	for k := 0; k < len(s); k += 1 {
		if s[k] == '\\' {
			k += 1
		} else if s[k] == '|' {
			append(&cells, strings.trim_space(s[from:k]))
			from = k + 1
		}
	}
	append(&cells, strings.trim_space(s[from:]))
	return cells[:]
}

// md_aligns reads a table's delimiter row, such as | :--- | :---: | ---: |.
@(private = "file")
md_aligns :: proc(line: string) -> (aligns: []Md_Align, ok: bool) {
	if md_indent(line) > 3 || strings.index_byte(line, '|') < 0 {
		return
	}
	cells := md_cells(line)
	aligns = make([]Md_Align, len(cells))
	for c, k in cells {
		left := strings.has_prefix(c, ":")
		right := strings.has_suffix(c, ":")
		dashes := strings.trim_suffix(strings.trim_prefix(c, ":"), ":")
		if dashes == "" || strings.trim_left(dashes, "-") != "" {
			return nil, false
		}
		switch {
		case left && right:
			aligns[k] = .Center
		case left:
			aligns[k] = .Left
		case right:
			aligns[k] = .Right
		}
	}
	return aligns, true
}

// md_table_start reports whether head and the line under it begin a table:
// a header row with pipes, then a delimiter row with as many cells.
@(private = "file")
md_table_start :: proc(head, delim: string) -> bool {
	if md_indent(head) > 3 || strings.index_byte(head, '|') < 0 {
		return false
	}
	aligns, ok := md_aligns(delim)
	return ok && len(aligns) == len(md_cells(head))
}

// md_table renders a table. Its rows go on to a blank line or the start of
// another block. A row with too few cells gets empty ones; extra cells are
// dropped.
@(private = "file")
md_table :: proc(md: ^Md, lines: []string, start: int) -> int {
	aligns, _ := md_aligns(lines[start + 1])
	strings.write_string(&md.b, "<table>\n<thead>\n")
	md_row(md, md_cells(lines[start]), aligns, "th")
	strings.write_string(&md.b, "</thead>\n")
	i := start + 2
	if i < len(lines) && !md_blank(lines[i]) && !md_interrupts(lines[i]) {
		strings.write_string(&md.b, "<tbody>\n")
		for i < len(lines) && !md_blank(lines[i]) && !md_interrupts(lines[i]) {
			md_row(md, md_cells(lines[i]), aligns, "td")
			i += 1
		}
		strings.write_string(&md.b, "</tbody>\n")
	}
	strings.write_string(&md.b, "</table>\n")
	return i
}

@(private = "file")
md_row :: proc(md: ^Md, cells: []string, aligns: []Md_Align, tag: string) {
	strings.write_string(&md.b, "<tr>\n")
	for a, k in aligns {
		strings.write_byte(&md.b, '<')
		strings.write_string(&md.b, tag)
		switch a {
		case .None:
		case .Left:
			strings.write_string(&md.b, ` style="text-align: left"`)
		case .Center:
			strings.write_string(&md.b, ` style="text-align: center"`)
		case .Right:
			strings.write_string(&md.b, ` style="text-align: right"`)
		}
		strings.write_byte(&md.b, '>')
		if k < len(cells) {
			// \| is a | in the cell, even in code.
			cell, _ := strings.replace_all(cells[k], "\\|", "|")
			strings.write_string(&md.b, md_inline(md, cell, false))
		}
		strings.write_string(&md.b, "</")
		strings.write_string(&md.b, tag)
		strings.write_string(&md.b, ">\n")
	}
	strings.write_string(&md.b, "</tr>\n")
}

// Md_Piece is a piece of a line of inline text: HTML ready to write, or a
// run of *, _ or ~ that may turn into emphasis once the whole text is read.
@(private = "file")
Md_Piece :: struct {
	html:   string, // when delim is 0
	delim:  u8, // '*', '_' or '~', or 0
	count:  int, // the run's characters not used for emphasis yet
	orig:   int, // the run's length
	open:   bool, // the run can open emphasis
	close:  bool, // the run can close emphasis
	before: string, // closing tags, before what is left of the run
	after:  string, // opening tags, after what is left of the run
}

// md_inline renders inline text as HTML. in_link turns off links inside a
// link's text, since a link cannot hold another link.
@(private = "file")
md_inline :: proc(md: ^Md, s: string, in_link: bool) -> string {
	pieces := make([dynamic]Md_Piece)
	brackets := md_brackets(s)
	b := strings.builder_make()
	p := 0
	for p < len(s) {
		c := s[p]
		switch c {
		case '\\':
			if p + 1 < len(s) && s[p + 1] == '\n' {
				strings.write_string(&b, "<br />\n") // a hard line break
				p += 2
				continue
			}
			if p + 1 < len(s) && md_punct_byte(s[p + 1]) {
				md_esc(&b, s[p + 1:p + 2])
				p += 2
				continue
			}
			strings.write_byte(&b, '\\')
			p += 1
		case ' ':
			n := md_run(s, p, ' ')
			if p + n < len(s) && s[p + n] == '\n' {
				// Two spaces at the end of a line are a hard line break.
				strings.write_string(&b, n >= 2 ? "<br />\n" : "\n")
				p += n + 1
				continue
			}
			strings.write_string(&b, s[p:p + n])
			p += n
		case '`':
			n := md_run(s, p, '`')
			end := md_code_end(s, p + n, n)
			if end < 0 {
				strings.write_string(&b, s[p:p + n])
				p += n
				continue
			}
			code, _ := strings.replace_all(s[p + n:end], "\n", " ")
			if len(code) >= 2 && code[0] == ' ' && code[len(code) - 1] == ' ' && !md_blank(code) {
				code = code[1:len(code) - 1]
			}
			strings.write_string(&b, "<code>")
			md_esc(&b, code)
			strings.write_string(&b, "</code>")
			p = end + n
		case '*', '_', '~':
			n := md_run(s, p, c)
			if c == '~' && n != 2 {
				strings.write_string(&b, s[p:p + n]) // only ~~ is strikethrough
				p += n
				continue
			}
			// CommonMark's flanking rules: a run can open emphasis when text
			// follows it, and close it when text comes before it. An _ inside
			// a word does neither, so snake_case stays as it is.
			before, after := md_rune_before(s, p), md_rune_after(s, p + n)
			left := !md_space(after) && (!md_punct(after) || md_space(before) || md_punct(before))
			right := !md_space(before) && (!md_punct(before) || md_space(after) || md_punct(after))
			open, close := left, right
			if c == '_' {
				open = left && (!right || md_punct(before))
				close = right && (!left || md_punct(after))
			}
			md_flush(&pieces, &b)
			append(&pieces, Md_Piece{delim = c, count = n, orig = n, open = open, close = close})
			p += n
		case '!':
			if p + 1 < len(s) && s[p + 1] == '[' {
				if text, url, title, end, ok := md_link(md, s, p + 1, brackets); ok {
					strings.write_string(&b, `<img src="`)
					md_esc(&b, md_safe_url(url, true))
					strings.write_string(&b, `" alt="`)
					strings.write_string(&b, md_strip_tags(md_inline(md, text, true)))
					strings.write_byte(&b, '"')
					md_title(&b, title)
					strings.write_string(&b, " />")
					p = end
					continue
				}
			}
			strings.write_byte(&b, '!')
			p += 1
		case '[':
			if !in_link {
				if text, url, title, end, ok := md_link(md, s, p, brackets); ok {
					strings.write_string(&b, `<a href="`)
					md_esc(&b, md_safe_url(url, false))
					strings.write_byte(&b, '"')
					md_title(&b, title)
					strings.write_byte(&b, '>')
					strings.write_string(&b, md_inline(md, text, true))
					strings.write_string(&b, "</a>")
					p = end
					continue
				}
			}
			strings.write_byte(&b, '[')
			p += 1
		case '<':
			if !in_link {
				if href, label, end, ok := md_autolink(s, p); ok {
					md_link_html(&b, href, label)
					p = end
					continue
				}
			}
			// Raw HTML is shown as text.
			strings.write_string(&b, "&lt;")
			p += 1
		case '&':
			// Character references such as &copy; are kept, since they are
			// safe; any other & is escaped.
			if n := md_entity(s, p); n > 0 {
				strings.write_string(&b, s[p:p + n])
				p += n
				continue
			}
			strings.write_string(&b, "&amp;")
			p += 1
		case '>':
			strings.write_string(&b, "&gt;")
			p += 1
		case '"':
			strings.write_string(&b, "&quot;")
			p += 1
		case 'h':
			// A bare http(s):// URL becomes a link, as on GitHub.
			if !in_link && (p == 0 || strings.index_byte(" \t\n*_~(", s[p - 1]) >= 0) {
				if n := md_bare_url(s, p); n > 0 {
					md_link_html(&b, s[p:p + n], s[p:p + n])
					p += n
					continue
				}
			}
			strings.write_byte(&b, c)
			p += 1
		case:
			strings.write_byte(&b, c)
			p += 1
		}
	}
	md_flush(&pieces, &b)
	md_emphasis(pieces[:])
	out := strings.builder_make()
	for piece in pieces {
		if piece.delim == 0 {
			strings.write_string(&out, piece.html)
			continue
		}
		strings.write_string(&out, piece.before)
		for _ in 0 ..< piece.count {
			strings.write_byte(&out, piece.delim)
		}
		strings.write_string(&out, piece.after)
	}
	return strings.to_string(out)
}

// md_flush ends the HTML piece being built, if it has anything.
@(private = "file")
md_flush :: proc(pieces: ^[dynamic]Md_Piece, b: ^strings.Builder) {
	if strings.builder_len(b^) == 0 {
		return
	}
	append(pieces, Md_Piece{html = strings.clone(strings.to_string(b^))})
	strings.builder_reset(b)
}

// md_emphasis pairs runs of *, _ and ~ into <em>, <strong> and <del>, by
// CommonMark's rules: each closing run, left to right, takes the nearest
// opening run of the same character before it.
@(private = "file")
md_emphasis :: proc(pieces: []Md_Piece) {
	// For each kind of closer, where the last search for an opener failed.
	// The next such search stops there, which keeps long texts fast.
	bottom: [3][3][2]int
	for ci in 0 ..< len(pieces) {
		c := &pieces[ci]
		if c.delim == 0 || !c.close {
			continue
		}
		kind := c.delim == '*' ? 0 : (c.delim == '_' ? 1 : 2)
		for c.count > 0 {
			lo := &bottom[kind][c.orig % 3][int(c.open)]
			found := -1
			for oi := ci - 1; oi >= lo^; oi -= 1 {
				o := &pieces[oi]
				if o.delim != c.delim || !o.open || o.count == 0 {
					continue
				}
				// The "rule of 3", which keeps *a**b* and the like sensible.
				if (o.close || c.open) && (o.orig + c.orig) % 3 == 0 && (o.orig % 3 != 0 || c.orig % 3 != 0) {
					continue
				}
				found = oi
				break
			}
			if found < 0 {
				lo^ = ci
				break
			}
			o := &pieces[found]
			use := (o.count >= 2 && c.count >= 2) ? 2 : 1
			tag := use == 2 ? "strong" : "em"
			if c.delim == '~' {
				use, tag = 2, "del"
			}
			// Later pairs with the same opener are outside the earlier ones.
			o.after = strings.concatenate({"<", tag, ">", o.after})
			c.before = strings.concatenate({c.before, "</", tag, ">"})
			o.count -= use
			c.count -= use
			// Runs between the two stay unpaired from here on.
			for k in found + 1 ..< ci {
				pieces[k].open = false
				pieces[k].close = false
			}
		}
	}
}

// md_link reads a link that starts with the [ at s[p]: [text](url "title"),
// or a reference link, [text][label], [text][] or [text]. end is just past it.
// brackets is from md_brackets.
@(private = "file")
md_link :: proc(md: ^Md, s: string, p: int, brackets: map[int]int) -> (text, url, title: string, end: int, ok: bool) {
	close, matched := brackets[p]
	if !matched {
		return
	}
	text = s[p + 1:close]
	q := close + 1
	if q < len(s) && s[q] == '(' {
		if u, t, e, good := md_link_dest(s, q + 1); good {
			return text, u, t, e, true
		}
	}
	label := text
	if q < len(s) && s[q] == '[' {
		if e := strings.index_byte(s[q + 1:], ']'); e >= 0 {
			if e > 0 {
				label = s[q + 1:q + 1 + e]
			}
			q += e + 2
		}
	}
	if ref, found := md.refs[md_label(label)]; found {
		return text, ref.url, ref.title, q, true
	}
	if label != text {
		if ref, found := md.refs[md_label(text)]; found {
			return text, ref.url, ref.title, close + 1, true
		}
	}
	return
}

// md_brackets pairs each [ in s with the ] that closes it, skipping
// escapes and code. It works in one pass, because a search for each [ 's ]
// in turn is slow on text full of [ that lack a ]. It maps the [ to the ].
@(private = "file")
md_brackets :: proc(s: string) -> map[int]int {
	pairs := make(map[int]int)
	if strings.index_byte(s, '[') < 0 {
		return pairs
	}
	open := make([dynamic]int)
	for k := 0; k < len(s); k += 1 {
		switch s[k] {
		case '\\':
			k += 1
		case '`':
			n := md_run(s, k, '`')
			if e := md_code_end(s, k + n, n); e >= 0 {
				k = e + n - 1
			} else {
				k += n - 1
			}
		case '[':
			append(&open, k)
		case ']':
			if len(open) > 0 {
				pairs[pop(&open)] = k
			}
		}
	}
	return pairs
}

// md_link_dest reads what follows a link's "](": the URL, an optional
// title, and the ")".
@(private = "file")
md_link_dest :: proc(s: string, start: int) -> (url, title: string, end: int, ok: bool) {
	k := md_skip_space(s, start)
	if k < len(s) && s[k] == '<' {
		e := k + 1
		for e < len(s) && s[e] != '>' && s[e] != '\n' && s[e] != '<' {
			e += s[e] == '\\' ? 2 : 1
		}
		if e >= len(s) || s[e] != '>' {
			return
		}
		url, _ = strings.replace_all(s[k + 1:e], " ", "%20")
		k = e + 1
	} else {
		depth := 0
		e := k
		dest: for e < len(s) {
			switch s[e] {
			case '\\':
				e += 1
			case ' ', '\t', '\n':
				break dest
			case '(':
				depth += 1
			case ')':
				if depth == 0 {
					break dest
				}
				depth -= 1
			}
			e += 1
		}
		e = min(e, len(s))
		url = s[k:e]
		k = e
	}
	k = md_skip_space(s, k)
	if k < len(s) && (s[k] == '"' || s[k] == '\'' || s[k] == '(') {
		closer := s[k] == '(' ? ')' : s[k]
		e := k + 1
		for e < len(s) && s[e] != closer {
			e += s[e] == '\\' ? 2 : 1
		}
		if e >= len(s) {
			return
		}
		title = s[k + 1:e]
		k = md_skip_space(s, e + 1)
	}
	if k >= len(s) || s[k] != ')' {
		return
	}
	return md_unescape(url), md_unescape(title), k + 1, true
}

@(private = "file")
md_skip_space :: proc(s: string, k: int) -> int {
	k := k
	for k < len(s) && (s[k] == ' ' || s[k] == '\t' || s[k] == '\n') {
		k += 1
	}
	return k
}

// md_autolink reads <https://example.com> or <someone@example.com>.
@(private = "file")
md_autolink :: proc(s: string, p: int) -> (href, label: string, end: int, ok: bool) {
	// It ends at the first >. A space or < before that makes it invalid.
	e := 0
	for p + 1 + e < len(s) && strings.index_byte(" \t\n<>", s[p + 1 + e]) < 0 {
		e += 1
	}
	if e == 0 || p + 1 + e >= len(s) || s[p + 1 + e] != '>' {
		return
	}
	inner := s[p + 1:p + 1 + e]
	end = p + 2 + e
	if colon := strings.index_byte(inner, ':'); colon >= 2 && colon <= 32 && md_scheme(inner[:colon]) {
		return inner, inner, end, true
	}
	if md_email(inner) {
		return strings.concatenate({"mailto:", inner}), inner, end, true
	}
	return "", "", 0, false
}

@(private = "file")
md_scheme :: proc(s: string) -> bool {
	for k in 0 ..< len(s) {
		c := s[k]
		if !(md_alpha(c) || (k > 0 && ((c >= '0' && c <= '9') || c == '+' || c == '.' || c == '-'))) {
			return false
		}
	}
	return true
}

@(private = "file")
md_email :: proc(s: string) -> bool {
	at := strings.index_byte(s, '@')
	if at <= 0 || at == len(s) - 1 {
		return false
	}
	for k in 0 ..< len(s) {
		c := s[k]
		switch {
		case md_alnum(c), c == '.', c == '-':
		case k < at && strings.index_byte("!#$%&'*+/=?^_`{|}~", c) >= 0:
		case k == at:
		case:
			return false
		}
	}
	return true
}

// md_bare_url returns the length of an http:// or https:// URL at s[p], or
// 0. Punctuation at its end belongs to the sentence, and so does a ) that
// lacks a matching (.
@(private = "file")
md_bare_url :: proc(s: string, p: int) -> int {
	rest := s[p:]
	scheme := 0
	switch {
	case strings.has_prefix(rest, "https://"):
		scheme = 8
	case strings.has_prefix(rest, "http://"):
		scheme = 7
	case:
		return 0
	}
	e := scheme
	for e < len(rest) && strings.index_byte(" \t\n<", rest[e]) < 0 {
		e += 1
	}
	for e > scheme {
		ch := rest[e - 1]
		if strings.index_byte("?!.,:*_~'\";", ch) >= 0 {
			e -= 1
		} else if ch == ')' && strings.count(rest[:e], "(") < strings.count(rest[:e], ")") {
			e -= 1
		} else {
			break
		}
	}
	return e > scheme ? e : 0
}

@(private = "file")
md_link_html :: proc(b: ^strings.Builder, href, label: string) {
	strings.write_string(b, `<a href="`)
	md_esc(b, md_safe_url(href, false))
	strings.write_string(b, `">`)
	md_esc(b, label)
	strings.write_string(b, "</a>")
}

@(private = "file")
md_title :: proc(b: ^strings.Builder, title: string) {
	if title != "" {
		strings.write_string(b, ` title="`)
		md_esc(b, title)
		strings.write_byte(b, '"')
	}
}

// md_safe_url keeps a URL as written (so a relative one resolves against
// the page's own URL), except one that would run script: javascript: and
// vbscript:, and data: other than an image in <img>. Those become "#".
@(private = "file")
md_safe_url :: proc(url: string, image: bool) -> string {
	colon := strings.index_byte(url, ':')
	if colon < 0 || strings.index_any(url[:colon], "/?#") >= 0 {
		return url
	}
	// Browsers ignore spaces and control characters in a scheme.
	b := strings.builder_make()
	for c in transmute([]byte)url[:colon] {
		if c > ' ' {
			strings.write_byte(&b, (c >= 'A' && c <= 'Z') ? c + 32 : c)
		}
	}
	switch strings.to_string(b) {
	case "javascript", "vbscript":
		return "#"
	case "data":
		if image && strings.has_prefix(strings.to_lower(strings.trim_left_space(url[colon + 1:])), "image/") {
			return url
		}
		return "#"
	}
	return url
}

// md_entity returns the length of a character reference (&name;, &#123; or
// &#x1F;) at s[p], or 0.
@(private = "file")
md_entity :: proc(s: string, p: int) -> int {
	k := p + 1
	if k < len(s) && s[k] == '#' {
		k += 1
		hex := k < len(s) && (s[k] == 'x' || s[k] == 'X')
		if hex {
			k += 1
		}
		d := k
		for k < len(s) && k - d < 7 && (hex ? md_hex(s[k]) : (s[k] >= '0' && s[k] <= '9')) {
			k += 1
		}
		if k == d {
			return 0
		}
	} else {
		d := k
		for k < len(s) && k - d < 32 && md_alnum(s[k]) {
			k += 1
		}
		if k - d < 2 || !md_alpha(s[d]) {
			return 0
		}
	}
	if k < len(s) && s[k] == ';' {
		return k + 1 - p
	}
	return 0
}

// md_code_end finds the closing run of exactly n backticks from s[from], or
// returns -1.
@(private = "file")
md_code_end :: proc(s: string, from, n: int) -> int {
	k := from
	for k < len(s) {
		if s[k] != '`' {
			k += 1
			continue
		}
		r := md_run(s, k, '`')
		if r == n {
			return k
		}
		k += r
	}
	return -1
}

// md_run returns the number of c characters in a row from s[p].
@(private = "file")
md_run :: proc(s: string, p: int, c: u8) -> int {
	n := 0
	for p + n < len(s) && s[p + n] == c {
		n += 1
	}
	return n
}

// md_rune_before and md_rune_after return the character before s[p] and
// the one at s[p]; the start and end of the text count as spaces.
@(private = "file")
md_rune_before :: proc(s: string, p: int) -> rune {
	if p <= 0 {
		return ' '
	}
	r, _ := utf8.decode_last_rune_in_string(s[:p])
	return r
}

@(private = "file")
md_rune_after :: proc(s: string, p: int) -> rune {
	if p >= len(s) {
		return ' '
	}
	r, _ := utf8.decode_rune_in_string(s[p:])
	return r
}

@(private = "file")
md_space :: proc(r: rune) -> bool {
	return r == ' ' || r == '\t' || r == '\n' || unicode.is_space(r)
}

@(private = "file")
md_punct :: proc(r: rune) -> bool {
	if r < 128 {
		return md_punct_byte(u8(r))
	}
	return unicode.is_punct(r) || unicode.is_symbol(r)
}

@(private = "file")
md_punct_byte :: proc(c: u8) -> bool {
	return (c >= '!' && c <= '/') || (c >= ':' && c <= '@') || (c >= '[' && c <= '`') || (c >= '{' && c <= '~')
}

@(private = "file")
md_alpha :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

@(private = "file")
md_alnum :: proc(c: u8) -> bool {
	return md_alpha(c) || (c >= '0' && c <= '9')
}

@(private = "file")
md_hex :: proc(c: u8) -> bool {
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

// md_unescape drops the backslash from backslash escapes, as in URLs.
@(private = "file")
md_unescape :: proc(s: string) -> string {
	if strings.index_byte(s, '\\') < 0 {
		return s
	}
	b := strings.builder_make()
	for k := 0; k < len(s); k += 1 {
		if s[k] == '\\' && k + 1 < len(s) && md_punct_byte(s[k + 1]) {
			k += 1
		}
		strings.write_byte(&b, s[k])
	}
	return strings.to_string(b)
}

// md_esc writes s with the characters that mean something in HTML escaped.
@(private = "file")
md_esc :: proc(b: ^strings.Builder, s: string) {
	for k in 0 ..< len(s) {
		switch s[k] {
		case '&':
			strings.write_string(b, "&amp;")
		case '<':
			strings.write_string(b, "&lt;")
		case '>':
			strings.write_string(b, "&gt;")
		case '"':
			strings.write_string(b, "&quot;")
		case:
			strings.write_byte(b, s[k])
		}
	}
}

@(private = "file")
md_esc_str :: proc(s: string) -> string {
	b := strings.builder_make()
	md_esc(&b, s)
	return strings.to_string(b)
}
