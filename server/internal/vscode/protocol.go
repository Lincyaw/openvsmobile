package vscode

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
)

// ProtocolMessageType represents the type of a PersistentProtocol message.
// These values match the TypeScript enum in ipc.net.ts.
type ProtocolMessageType uint8

const (
	ProtocolMessageNone       ProtocolMessageType = 0
	ProtocolMessageRegular    ProtocolMessageType = 1
	ProtocolMessageControl    ProtocolMessageType = 2
	ProtocolMessageAck        ProtocolMessageType = 3
	ProtocolMessageDisconnect ProtocolMessageType = 5
	ProtocolMessageReplayReq  ProtocolMessageType = 6
	ProtocolMessagePause      ProtocolMessageType = 7
	ProtocolMessageResume     ProtocolMessageType = 8
	ProtocolMessageKeepAlive  ProtocolMessageType = 9
)

// ProtocolHeaderLength is the fixed header size for PersistentProtocol frames (13 bytes).
//
// Header layout:
//
//	Offset 0: TYPE       (1 byte,  uint8)
//	Offset 1: ID         (4 bytes, uint32 big-endian)
//	Offset 5: ACK        (4 bytes, uint32 big-endian)
//	Offset 9: DATA_LENGTH (4 bytes, uint32 big-endian)
const ProtocolHeaderLength = 13

// ProtocolMessage represents a single frame in the PersistentProtocol.
type ProtocolMessage struct {
	Type ProtocolMessageType
	ID   uint32
	Ack  uint32
	Data []byte
}

// EncodeProtocolMessage serialises a ProtocolMessage into wire format (header + data).
func EncodeProtocolMessage(msg *ProtocolMessage) []byte {
	buf := make([]byte, ProtocolHeaderLength+len(msg.Data))
	buf[0] = byte(msg.Type)
	binary.BigEndian.PutUint32(buf[1:5], msg.ID)
	binary.BigEndian.PutUint32(buf[5:9], msg.Ack)
	binary.BigEndian.PutUint32(buf[9:13], uint32(len(msg.Data)))
	copy(buf[13:], msg.Data)
	return buf
}

// DecodeProtocolMessage reads exactly one frame from the reader.
func DecodeProtocolMessage(r io.Reader) (*ProtocolMessage, error) {
	header := make([]byte, ProtocolHeaderLength)
	if _, err := io.ReadFull(r, header); err != nil {
		return nil, fmt.Errorf("read header: %w", err)
	}

	msgType := ProtocolMessageType(header[0])
	id := binary.BigEndian.Uint32(header[1:5])
	ack := binary.BigEndian.Uint32(header[5:9])
	dataLen := binary.BigEndian.Uint32(header[9:13])

	data := make([]byte, dataLen)
	if dataLen > 0 {
		if _, err := io.ReadFull(r, data); err != nil {
			return nil, fmt.Errorf("read data (%d bytes): %w", dataLen, err)
		}
	}

	return &ProtocolMessage{
		Type: msgType,
		ID:   id,
		Ack:  ack,
		Data: data,
	}, nil
}

// ---------------------------------------------------------------------------
// VS Code IPC serialisation
//
// The IPC layer serialises a header (array) and a body using a custom
// binary format with variable-length quantity (VQL) encoded lengths.
// ---------------------------------------------------------------------------

// DataType mirrors the TypeScript DataType enum in ipc.ts.
type DataType uint8

const (
	DataTypeUndefined DataType = 0
	DataTypeString    DataType = 1
	DataTypeBuffer    DataType = 2
	DataTypeVSBuffer  DataType = 3
	DataTypeArray     DataType = 4
	DataTypeObject    DataType = 5
	DataTypeInt       DataType = 6
)

// RequestType mirrors the TypeScript RequestType enum in ipc.ts.
type RequestType int

const (
	RequestTypePromise       RequestType = 100
	RequestTypePromiseCancel RequestType = 101
	RequestTypeEventListen   RequestType = 102
	RequestTypeEventDispose  RequestType = 103
)

// ResponseType mirrors the TypeScript ResponseType enum in ipc.ts.
type ResponseType int

const (
	ResponseTypeInitialize      ResponseType = 200
	ResponseTypePromiseSuccess  ResponseType = 201
	ResponseTypePromiseError    ResponseType = 202
	ResponseTypePromiseErrorObj ResponseType = 203
	ResponseTypeEventFire       ResponseType = 204
)

// writeVQL writes a variable-length quantity encoded integer.
func writeVQL(w *bufWriter, value int) {
	if value == 0 {
		w.WriteByte(0)
		return
	}
	for value != 0 {
		b := byte(value & 0x7f)
		value >>= 7
		if value > 0 {
			b |= 0x80
		}
		w.WriteByte(b)
	}
}

// readVQL reads a variable-length quantity encoded integer.
func readVQL(r *bufReader) (int, error) {
	value := 0
	for n := 0; ; n += 7 {
		b, err := r.ReadByte()
		if err != nil {
			return 0, err
		}
		value |= int(b&0x7f) << n
		if b&0x80 == 0 {
			return value, nil
		}
		if n > 28 {
			return 0, errors.New("VQL overflow")
		}
	}
}

// bufWriter is a simple byte-slice builder.
type bufWriter struct {
	buf []byte
}

func (w *bufWriter) Write(p []byte) {
	w.buf = append(w.buf, p...)
}

func (w *bufWriter) WriteByte(b byte) error {
	w.buf = append(w.buf, b)
	return nil
}

func (w *bufWriter) Bytes() []byte {
	return w.buf
}

// bufReader reads from a byte slice.
type bufReader struct {
	data []byte
	pos  int
}

func newBufReader(data []byte) *bufReader {
	return &bufReader{data: data}
}

func (r *bufReader) ReadByte() (byte, error) {
	if r.pos >= len(r.data) {
		return 0, io.EOF
	}
	b := r.data[r.pos]
	r.pos++
	return b, nil
}

func (r *bufReader) Read(n int) ([]byte, error) {
	if r.pos+n > len(r.data) {
		return nil, io.ErrUnexpectedEOF
	}
	result := r.data[r.pos : r.pos+n]
	r.pos += n
	return result, nil
}

func (r *bufReader) Remaining() int {
	return len(r.data) - r.pos
}

// Serialize encodes a Go value into the VS Code IPC binary format.
func Serialize(w *bufWriter, data interface{}) {
	if data == nil {
		w.WriteByte(byte(DataTypeUndefined))
		return
	}
	switch v := data.(type) {
	case string:
		w.WriteByte(byte(DataTypeString))
		strBytes := []byte(v)
		writeVQL(w, len(strBytes))
		w.Write(strBytes)
	case []byte:
		w.WriteByte(byte(DataTypeVSBuffer))
		writeVQL(w, len(v))
		w.Write(v)
	case []interface{}:
		w.WriteByte(byte(DataTypeArray))
		writeVQL(w, len(v))
		for _, el := range v {
			Serialize(w, el)
		}
	case int:
		if v >= 0 && v <= math.MaxInt32 {
			w.WriteByte(byte(DataTypeInt))
			writeVQL(w, v)
		} else {
			serializeAsJSON(w, v)
		}
	case int64:
		if v >= 0 && v <= math.MaxInt32 {
			w.WriteByte(byte(DataTypeInt))
			writeVQL(w, int(v))
		} else {
			serializeAsJSON(w, v)
		}
	default:
		serializeAsJSON(w, v)
	}
}

func serializeAsJSON(w *bufWriter, v interface{}) {
	jsonBytes, _ := json.Marshal(v)
	w.WriteByte(byte(DataTypeObject))
	writeVQL(w, len(jsonBytes))
	w.Write(jsonBytes)
}

// Deserialize decodes a value from the VS Code IPC binary format.
func Deserialize(r *bufReader) (interface{}, error) {
	typeByte, err := r.ReadByte()
	if err != nil {
		return nil, err
	}
	dt := DataType(typeByte)
	switch dt {
	case DataTypeUndefined:
		return nil, nil
	case DataTypeString:
		length, err := readVQL(r)
		if err != nil {
			return nil, err
		}
		data, err := r.Read(length)
		if err != nil {
			return nil, err
		}
		return string(data), nil
	case DataTypeBuffer, DataTypeVSBuffer:
		length, err := readVQL(r)
		if err != nil {
			return nil, err
		}
		data, err := r.Read(length)
		if err != nil {
			return nil, err
		}
		buf := make([]byte, length)
		copy(buf, data)
		return buf, nil
	case DataTypeArray:
		length, err := readVQL(r)
		if err != nil {
			return nil, err
		}
		arr := make([]interface{}, length)
		for i := 0; i < length; i++ {
			val, err := Deserialize(r)
			if err != nil {
				return nil, err
			}
			arr[i] = val
		}
		return arr, nil
	case DataTypeObject:
		length, err := readVQL(r)
		if err != nil {
			return nil, err
		}
		data, err := r.Read(length)
		if err != nil {
			return nil, err
		}
		var obj interface{}
		if err := json.Unmarshal(data, &obj); err != nil {
			return nil, fmt.Errorf("unmarshal object: %w", err)
		}
		return obj, nil
	case DataTypeInt:
		val, err := readVQL(r)
		if err != nil {
			return nil, err
		}
		return val, nil
	default:
		return nil, fmt.Errorf("unknown data type: %d", dt)
	}
}

// EncodeIPCMessage builds a complete IPC message (header + body) as used
// by the VS Code ChannelClient.sendRequest / ChannelServer.sendResponse.
func EncodeIPCMessage(header interface{}, body interface{}) []byte {
	w := &bufWriter{}
	Serialize(w, header)
	Serialize(w, body)
	return w.Bytes()
}

// DecodeIPCMessage splits a raw IPC payload into header and body parts.
func DecodeIPCMessage(data []byte) (header interface{}, body interface{}, err error) {
	r := newBufReader(data)
	header, err = Deserialize(r)
	if err != nil {
		return nil, nil, fmt.Errorf("decode header: %w", err)
	}
	body, err = Deserialize(r)
	if err != nil {
		return nil, nil, fmt.Errorf("decode body: %w", err)
	}
	return header, body, nil
}
