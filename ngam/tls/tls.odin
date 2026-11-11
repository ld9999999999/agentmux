package tls

// HTTPS for the preview server, using OpenSSL 3. On first use ngam makes a
// self-signed certificate for 127.0.0.1 and localhost and keeps it, with
// its key, in the config folder. ngam never trusts the certificate itself:
// the README gives the command to trust it, and the user runs it.

import "core:c"
import "core:crypto"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:net"

// Homebrew's OpenSSL 3. Odin import paths cannot hold the "@", so the
// folder goes to the linker as a flag. The libraries are named libssl.3
// and libcrypto.3 so the linker picks OpenSSL 3 even when a newer OpenSSL
// is in /opt/homebrew/lib.
when ODIN_OS == .Darwin {
	@(extra_linker_flags = "-L/opt/homebrew/opt/openssl@3/lib")
	foreign import libssl "system:ssl.3"
	@(extra_linker_flags = "-L/opt/homebrew/opt/openssl@3/lib")
	foreign import libcrypto "system:crypto.3"
} else {
	foreign import libssl "system:ssl"
	foreign import libcrypto "system:crypto"
}

@(private = "file")
SSL_FILETYPE_PEM :: 1
@(private = "file")
SSL_CTRL_SET_MIN_PROTO_VERSION :: 123
@(private = "file")
TLS1_2_VERSION :: 0x0303
@(private = "file")
MBSTRING_ASC :: 0x1001
@(private = "file")
NID_key_usage :: 83
@(private = "file")
NID_subject_alt_name :: 85
@(private = "file")
NID_basic_constraints :: 87
@(private = "file")
NID_ext_key_usage :: 126

@(default_calling_convention = "c", private = "file")
foreign libssl {
	TLS_server_method :: proc() -> rawptr ---
	SSL_CTX_new :: proc(method: rawptr) -> rawptr ---
	SSL_CTX_ctrl :: proc(ctx: rawptr, cmd: c.int, larg: c.long, parg: rawptr) -> c.long ---
	SSL_CTX_use_certificate_file :: proc(ctx: rawptr, file: cstring, type: c.int) -> c.int ---
	SSL_CTX_use_PrivateKey_file :: proc(ctx: rawptr, file: cstring, type: c.int) -> c.int ---
	SSL_CTX_check_private_key :: proc(ctx: rawptr) -> c.int ---
	SSL_CTX_free :: proc(ctx: rawptr) ---
	SSL_new :: proc(ctx: rawptr) -> rawptr ---
	SSL_set_fd :: proc(ssl: rawptr, fd: c.int) -> c.int ---
	SSL_accept :: proc(ssl: rawptr) -> c.int ---
	SSL_read :: proc(ssl: rawptr, buf: rawptr, num: c.int) -> c.int ---
	SSL_write :: proc(ssl: rawptr, buf: rawptr, num: c.int) -> c.int ---
	SSL_shutdown :: proc(ssl: rawptr) -> c.int ---
	SSL_free :: proc(ssl: rawptr) ---
}

@(default_calling_convention = "c", private = "file")
foreign libcrypto {
	EVP_PKEY_CTX_new_from_name :: proc(libctx: rawptr, name: cstring, propq: cstring) -> rawptr ---
	EVP_PKEY_keygen_init :: proc(ctx: rawptr) -> c.int ---
	EVP_PKEY_CTX_set_group_name :: proc(ctx: rawptr, name: cstring) -> c.int ---
	EVP_PKEY_generate :: proc(ctx: rawptr, pkey: ^rawptr) -> c.int ---
	EVP_PKEY_CTX_free :: proc(ctx: rawptr) ---
	EVP_PKEY_free :: proc(pkey: rawptr) ---
	EVP_sha256 :: proc() -> rawptr ---
	X509_new :: proc() -> rawptr ---
	X509_free :: proc(x: rawptr) ---
	X509_set_version :: proc(x: rawptr, version: c.long) -> c.int ---
	X509_get_serialNumber :: proc(x: rawptr) -> rawptr ---
	ASN1_INTEGER_set :: proc(a: rawptr, v: c.long) -> c.int ---
	X509_getm_notBefore :: proc(x: rawptr) -> rawptr ---
	X509_getm_notAfter :: proc(x: rawptr) -> rawptr ---
	X509_gmtime_adj :: proc(s: rawptr, adj: c.long) -> rawptr ---
	X509_set_pubkey :: proc(x: rawptr, pkey: rawptr) -> c.int ---
	X509_get_subject_name :: proc(x: rawptr) -> rawptr ---
	X509_set_issuer_name :: proc(x: rawptr, name: rawptr) -> c.int ---
	X509_NAME_add_entry_by_txt :: proc(name: rawptr, field: cstring, type: c.int, bytes: cstring, len: c.int, loc: c.int, set: c.int) -> c.int ---
	X509V3_EXT_conf_nid :: proc(conf: rawptr, ctx: rawptr, nid: c.int, value: cstring) -> rawptr ---
	X509_add_ext :: proc(x: rawptr, ex: rawptr, loc: c.int) -> c.int ---
	X509_EXTENSION_free :: proc(ex: rawptr) ---
	X509_sign :: proc(x: rawptr, pkey: rawptr, md: rawptr) -> c.int ---
	BIO_new_file :: proc(filename: cstring, mode: cstring) -> rawptr ---
	BIO_free :: proc(bio: rawptr) -> c.int ---
	PEM_write_bio_X509 :: proc(bio: rawptr, x: rawptr) -> c.int ---
	PEM_write_bio_PrivateKey :: proc(bio: rawptr, pkey: rawptr, enc: rawptr, kstr: rawptr, klen: c.int, cb: rawptr, u: rawptr) -> c.int ---
	ERR_get_error :: proc() -> c.ulong ---
	ERR_error_string_n :: proc(e: c.ulong, buf: [^]u8, len: c.size_t) ---
}

@(private = "file")
ssl_error :: proc(what: string) -> string {
	buf: [256]u8
	ERR_error_string_n(ERR_get_error(), &buf[0], len(buf))
	return fmt.tprintf("%s: %s", what, cstring(&buf[0]))
}

// paths returns where the certificate and its key live in dir.
@(private = "file")
paths :: proc(dir: string) -> (cert, key: string) {
	cert, _ = filepath.join({dir, "preview-cert.pem"}, context.allocator)
	key, _ = filepath.join({dir, "preview-key.pem"}, context.temp_allocator)
	return
}

// server_ctx makes the server's SSL_CTX. It first makes the certificate
// when dir lacks one.
server_ctx :: proc(dir: string) -> (ctx: rawptr, cert_path: string, err: string) {
	cert, key := paths(dir)
	if !os.exists(cert) || !os.exists(key) {
		if msg := make_certificate(cert, key); msg != "" {
			return nil, cert, msg
		}
	}
	ccert := strings.clone_to_cstring(cert, context.temp_allocator)
	ckey := strings.clone_to_cstring(key, context.temp_allocator)
	ctx = SSL_CTX_new(TLS_server_method())
	if ctx == nil {
		return nil, cert, ssl_error("SSL_CTX_new")
	}
	_ = SSL_CTX_ctrl(ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_2_VERSION, nil)
	if SSL_CTX_use_certificate_file(ctx, ccert, SSL_FILETYPE_PEM) != 1 || SSL_CTX_use_PrivateKey_file(ctx, ckey, SSL_FILETYPE_PEM) != 1 || SSL_CTX_check_private_key(ctx) != 1 {
		msg := ssl_error(fmt.tprintf("Cannot load %s", cert))
		SSL_CTX_free(ctx)
		return nil, cert, msg
	}
	return ctx, cert, ""
}

// make_certificate writes a new P-256 key and a self-signed certificate
// for 127.0.0.1 and localhost, valid for 800 days (Apple accepts at most
// 825). Only the owner can read the key file.
@(private = "file")
make_certificate :: proc(cert_path, key_path: string) -> string {
	kctx := EVP_PKEY_CTX_new_from_name(nil, "EC", nil)
	if kctx == nil {
		return ssl_error("EVP_PKEY_CTX_new_from_name")
	}
	defer EVP_PKEY_CTX_free(kctx)
	pkey: rawptr
	if EVP_PKEY_keygen_init(kctx) != 1 || EVP_PKEY_CTX_set_group_name(kctx, "P-256") != 1 || EVP_PKEY_generate(kctx, &pkey) != 1 {
		return ssl_error("Cannot make a key")
	}
	defer EVP_PKEY_free(pkey)

	x := X509_new()
	defer X509_free(x)
	serial: [4]u8
	crypto.rand_bytes(serial[:])
	_ = X509_set_version(x, 2) // version 3
	_ = ASN1_INTEGER_set(X509_get_serialNumber(x), c.long(transmute(u32)serial & 0x7fffffff) + 1)
	_ = X509_gmtime_adj(X509_getm_notBefore(x), -3600)
	_ = X509_gmtime_adj(X509_getm_notAfter(x), 800 * 24 * 3600)
	_ = X509_set_pubkey(x, pkey)
	name := X509_get_subject_name(x)
	_ = X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, "ngam preview (127.0.0.1)", -1, -1, 0)
	_ = X509_NAME_add_entry_by_txt(name, "O", MBSTRING_ASC, "ngam", -1, -1, 0)
	_ = X509_set_issuer_name(x, name)
	exts := [?]struct {
		nid:   c.int,
		value: cstring,
	} {
		{NID_basic_constraints, "critical,CA:FALSE"},
		{NID_key_usage, "critical,digitalSignature"},
		{NID_ext_key_usage, "serverAuth"},
		{NID_subject_alt_name, "IP:127.0.0.1,DNS:localhost"},
	}
	for e in exts {
		ext := X509V3_EXT_conf_nid(nil, nil, e.nid, e.value)
		if ext == nil {
			return ssl_error("Cannot add a certificate extension")
		}
		_ = X509_add_ext(x, ext, -1)
		X509_EXTENSION_free(ext)
	}
	if X509_sign(x, pkey, EVP_sha256()) == 0 {
		return ssl_error("Cannot sign the certificate")
	}

	// Set the key file to 0600 before writing to it, so the key is private
	// from the start.
	ckey := strings.clone_to_cstring(key_path, context.temp_allocator)
	fd := posix.open(ckey, {.CREAT, .WRONLY, .TRUNC}, {.IRUSR, .IWUSR})
	if fd < 0 {
		return fmt.tprintf("Cannot create %s", key_path)
	}
	_ = posix.fchmod(fd, {.IRUSR, .IWUSR})
	posix.close(fd)
	kb := BIO_new_file(ckey, "w")
	if kb == nil || PEM_write_bio_PrivateKey(kb, pkey, nil, nil, 0, nil, nil) != 1 {
		if kb != nil {
			BIO_free(kb)
		}
		return ssl_error(fmt.tprintf("Cannot write %s", key_path))
	}
	BIO_free(kb)
	cb := BIO_new_file(strings.clone_to_cstring(cert_path, context.temp_allocator), "w")
	if cb == nil || PEM_write_bio_X509(cb, x) != 1 {
		if cb != nil {
			BIO_free(cb)
		}
		return ssl_error(fmt.tprintf("Cannot write %s", cert_path))
	}
	BIO_free(cb)
	fmt.eprintln("ngam: made a certificate for the HTTPS preview:", cert_path)
	return ""
}

// accept runs the TLS handshake on a new connection. It returns the
// connection's SSL, or nil when the handshake fails.
accept :: proc(ctx: rawptr, sock: net.TCP_Socket) -> rawptr {
	ssl := SSL_new(ctx)
	if ssl == nil {
		return nil
	}
	if SSL_set_fd(ssl, c.int(sock)) != 1 || SSL_accept(ssl) != 1 {
		SSL_free(ssl)
		return nil
	}
	return ssl
}

read :: proc(ssl: rawptr, buf: []byte) -> int {
	return int(SSL_read(ssl, raw_data(buf), c.int(min(len(buf), 1 << 30))))
}

write :: proc(ssl: rawptr, data: []byte) -> int {
	return int(SSL_write(ssl, raw_data(data), c.int(min(len(data), 1 << 30))))
}

close :: proc(ssl: rawptr) {
	_ = SSL_shutdown(ssl)
	SSL_free(ssl)
}
