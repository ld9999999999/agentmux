package main

import (
	"encoding/binary"
	"errors"
	"io"
	"net"
	"time"
)

// Frames on the holder socket: 1 type byte, 4 byte big-endian length, payload.
const (
	frameHello  = 'H' // client -> holder, first frame: "attach", "send" or "editor"
	frameData   = 'D' // both ways: terminal bytes
	frameResize = 'R' // client -> holder: rows u16, cols u16
	frameKill   = 'K' // client -> holder: stop the agent and exit
	frameExit   = 'X' // holder -> client: agent exited, payload is the status
	frameEditor = 'E' // both ways on an "editor" link: one JSON editorMsg
)

const maxFrame = 4 << 20

// framed returns one whole frame, header and payload, so one Write sends
// it.
func framed(typ byte, payload []byte) []byte {
	b := make([]byte, 5+len(payload))
	b[0] = typ
	binary.BigEndian.PutUint32(b[1:], uint32(len(payload)))
	copy(b[5:], payload)
	return b
}

func writeFrame(w io.Writer, typ byte, payload []byte) error {
	_, err := w.Write(framed(typ, payload))
	return err
}

func readFrame(r io.Reader) (byte, []byte, error) {
	var hdr [5]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return 0, nil, err
	}
	n := binary.BigEndian.Uint32(hdr[1:])
	if n > maxFrame {
		return 0, nil, errors.New("frame too large")
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		return 0, nil, err
	}
	return hdr[0], buf, nil
}

func resizePayload(rows, cols uint16) []byte {
	b := make([]byte, 4)
	binary.BigEndian.PutUint16(b[0:], rows)
	binary.BigEndian.PutUint16(b[2:], cols)
	return b
}

// parseResize reads a resize payload: rows u16, cols u16.
func parseResize(b []byte) (rows, cols uint16, ok bool) {
	if len(b) != 4 {
		return 0, 0, false
	}
	return binary.BigEndian.Uint16(b[0:]), binary.BigEndian.Uint16(b[2:]), true
}

func dialHolder(s *Session) (net.Conn, error) {
	return net.DialTimeout("unix", s.Sock("holder"), time.Second)
}

// holderLink connects to the session's running holder as hello ("attach",
// "send" or "editor").
func holderLink(s *Session, hello string) (net.Conn, error) {
	conn, err := dialHolder(s)
	if err != nil {
		return nil, err
	}
	if err := writeFrame(conn, frameHello, []byte(hello)); err != nil {
		conn.Close()
		return nil, err
	}
	return conn, nil
}
