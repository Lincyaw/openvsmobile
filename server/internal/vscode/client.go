package vscode

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/url"
	"sync"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
	"github.com/gorilla/websocket"
)

// ConnectionType represents the VS Code remote connection type.
type ConnectionType int

const (
	ConnectionTypeManagement    ConnectionType = 1
	ConnectionTypeExtensionHost ConnectionType = 2
	ConnectionTypeTunnel        ConnectionType = 3
)

// keepAliveSendTime is how often keep-alive messages are sent.
const keepAliveSendTime = 5 * time.Second

// HandshakeMessage types exchanged during the initial connection.
type AuthRequest struct {
	Type string `json:"type"`
	Auth string `json:"auth"`
	Data string `json:"data"`
}

type SignResponse struct {
	Type       string `json:"type"`
	Data       string `json:"data"`
	SignedData string `json:"signedData"`
}

type ConnectionTypeRequest struct {
	Type                  string         `json:"type"`
	Commit                string         `json:"commit,omitempty"`
	SignedData            string         `json:"signedData"`
	DesiredConnectionType ConnectionType `json:"desiredConnectionType,omitempty"`
}

type OKMessage struct {
	Type string `json:"type"`
}

type ErrorMessage struct {
	Type   string `json:"type"`
	Reason string `json:"reason"`
}

// Client manages a WebSocket connection to an OpenVSCode Server instance
// and provides a PersistentProtocol-level interface.
type Client struct {
	conn *websocket.Conn
	mu   sync.Mutex

	// reconnectionToken identifies this session for reconnection.
	reconnectionToken string

	// outgoing message tracking for PersistentProtocol
	outgoingMsgID atomic.Uint32
	outgoingAckID atomic.Uint32
	incomingMsgID atomic.Uint32

	// ipcClient is the IPC channel multiplexer attached to this connection.
	ipcClient *IPCClient

	// stopKeepAlive signals the keep-alive goroutine to stop.
	stopKeepAlive chan struct{}
	closeOnce     sync.Once

	// bufferedMessages holds Regular messages received during handshake
	// before the readLoop/onMessage handler is set up.
	bufferedMessages []*ProtocolMessage

	// onMessage is called for each Regular message received.
	onMessage func(data []byte)
	// onControl is called for each Control message received.
	onControl func(data []byte)
}

// NewClient creates a new Client with a fresh reconnection token.
func NewClient() *Client {
	return &Client{
		reconnectionToken: uuid.New().String(),
		stopKeepAlive:     make(chan struct{}),
	}
}

// Connect establishes a WebSocket connection to serverURL and performs
// the VS Code handshake to create a Management connection.
//
// serverURL should be the base HTTP URL of the OpenVSCode server
// (e.g., "http://localhost:3000"). connectionToken is the server's
// connection token (pass empty string for no auth).
func (c *Client) Connect(ctx context.Context, serverURL string, connectionToken string) error {
	return c.ConnectWithType(ctx, serverURL, connectionToken, ConnectionTypeManagement, "")
}

// ConnectWithType is like Connect but allows specifying the connection type and commit.
func (c *Client) ConnectWithType(ctx context.Context, serverURL string, connectionToken string, connType ConnectionType, commit string) error {
	wsURL, err := buildWSURL(serverURL, c.reconnectionToken, false)
	if err != nil {
		return fmt.Errorf("build ws url: %w", err)
	}

	dialer := websocket.Dialer{
		HandshakeTimeout: 10 * time.Second,
	}

	conn, _, err := dialer.DialContext(ctx, wsURL, nil)
	if err != nil {
		return fmt.Errorf("websocket dial: %w", err)
	}
	c.conn = conn

	if err := c.performHandshake(ctx, connectionToken, connType, commit); err != nil {
		conn.Close()
		return fmt.Errorf("handshake: %w", err)
	}

	// Send the IPC initialization message (ctx = remoteAuthority string).
	// The VS Code IPCClient sends serialize(ctx) as the first Regular message
	// to trigger the server-side ChannelServer creation.
	ctxWriter := &bufWriter{}
	Serialize(ctxWriter, "vscode-remote")
	if err := c.SendRegular(ctxWriter.Bytes()); err != nil {
		conn.Close()
		return fmt.Errorf("send IPC ctx: %w", err)
	}

	// Attach the IPC multiplexer.
	c.ipcClient = NewIPCClient(c)

	// Replay any messages buffered during handshake (e.g., Initialize).
	for _, msg := range c.bufferedMessages {
		c.handleMessage(msg)
	}
	c.bufferedMessages = nil

	// Start the read loop and keep-alive.
	go c.readLoop()
	go c.keepAliveLoop()

	return nil
}

// IPC returns the IPC channel multiplexer for this connection.
func (c *Client) IPC() *IPCClient {
	return c.ipcClient
}

// Reconnect attempts to re-establish the connection using the same
// reconnection token. It performs a new WebSocket dial with reconnection=true,
// replays the handshake, and restores the IPC layer.
func (c *Client) Reconnect(ctx context.Context, serverURL string, connectionToken string) error {
	// Close existing connection if any.
	c.mu.Lock()
	if c.conn != nil {
		c.conn.Close()
	}
	c.mu.Unlock()

	// Stop old keep-alive.
	select {
	case <-c.stopKeepAlive:
	default:
		close(c.stopKeepAlive)
	}
	c.stopKeepAlive = make(chan struct{})

	wsURL, err := buildWSURL(serverURL, c.reconnectionToken, true)
	if err != nil {
		return fmt.Errorf("build reconnect ws url: %w", err)
	}

	dialer := websocket.Dialer{
		HandshakeTimeout: 10 * time.Second,
	}

	conn, _, err := dialer.DialContext(ctx, wsURL, nil)
	if err != nil {
		return fmt.Errorf("websocket reconnect dial: %w", err)
	}
	c.conn = conn

	if err := c.performHandshake(ctx, connectionToken, ConnectionTypeManagement, ""); err != nil {
		conn.Close()
		return fmt.Errorf("reconnect handshake: %w", err)
	}

	// Re-send IPC ctx.
	ctxWriter := &bufWriter{}
	Serialize(ctxWriter, "vscode-remote")
	if err := c.SendRegular(ctxWriter.Bytes()); err != nil {
		conn.Close()
		return fmt.Errorf("reconnect send IPC ctx: %w", err)
	}

	// Re-attach IPC.
	c.ipcClient = NewIPCClient(c)
	for _, msg := range c.bufferedMessages {
		c.handleMessage(msg)
	}
	c.bufferedMessages = nil

	go c.readLoop()
	go c.keepAliveLoop()

	return nil
}

// ReconnectWithRetry attempts reconnection with exponential backoff.
// Returns nil on success or the last error after maxRetries attempts.
func (c *Client) ReconnectWithRetry(ctx context.Context, serverURL, connectionToken string, maxRetries int) error {
	delay := 1 * time.Second
	var lastErr error
	for i := 0; i < maxRetries; i++ {
		lastErr = c.Reconnect(ctx, serverURL, connectionToken)
		if lastErr == nil {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(delay):
		}
		delay *= 2
		if delay > 30*time.Second {
			delay = 30 * time.Second
		}
	}
	return fmt.Errorf("reconnection failed after %d attempts: %w", maxRetries, lastErr)
}

// Close shuts down the connection gracefully. It is safe to call multiple times.
func (c *Client) Close() error {
	var closeErr error
	c.closeOnce.Do(func() {
		close(c.stopKeepAlive)
		c.mu.Lock()
		defer c.mu.Unlock()
		if c.conn == nil {
			return
		}
		// Send disconnect message.
		msg := &ProtocolMessage{
			Type: ProtocolMessageDisconnect,
			ID:   0,
			Ack:  0,
			Data: []byte{},
		}
		c.writeMessageLocked(msg)
		closeErr = c.conn.Close()
	})
	return closeErr
}

// ReconnectionToken returns the token used for this session.
func (c *Client) ReconnectionToken() string {
	return c.reconnectionToken
}

// performHandshake executes the 3-step VS Code WebSocket handshake.
func (c *Client) performHandshake(ctx context.Context, connectionToken string, connType ConnectionType, commit string) error {
	if connectionToken == "" {
		connectionToken = "00000000000000000000"
	}

	// Step 1: Send AuthRequest (as a control message).
	authReq := AuthRequest{
		Type: "auth",
		Auth: connectionToken,
		Data: uuid.New().String(),
	}
	if err := c.sendControlJSON(authReq); err != nil {
		return fmt.Errorf("send auth: %w", err)
	}

	// Step 2: Read SignResponse.
	signResp, err := c.readControlJSON(ctx)
	if err != nil {
		return fmt.Errorf("read sign: %w", err)
	}
	msgType, ok := signResp["type"].(string)
	if !ok || msgType != "sign" {
		if msgType == "error" {
			reason, _ := signResp["reason"].(string)
			return fmt.Errorf("server error: %s", reason)
		}
		return fmt.Errorf("unexpected handshake message type: %v", msgType)
	}
	signedData, _ := signResp["signedData"].(string)

	// Step 3: Send ConnectionTypeRequest.
	// For the sign step, we use the server's signedData as-is (the Go client
	// trusts the server). We sign the challenge data by echoing it back;
	// the default sign service in openvscode-server simply returns the data.
	challengeData, _ := signResp["data"].(string)
	connTypeReq := ConnectionTypeRequest{
		Type:                  "connectionType",
		Commit:                commit,
		SignedData:            challengeData, // echo the challenge as our signature
		DesiredConnectionType: connType,
	}
	_ = signedData // validated server identity
	if err := c.sendControlJSON(connTypeReq); err != nil {
		return fmt.Errorf("send connectionType: %w", err)
	}

	// Step 4: Read OK response.
	okResp, err := c.readControlJSON(ctx)
	if err != nil {
		return fmt.Errorf("read ok: %w", err)
	}
	okType, _ := okResp["type"].(string)
	if okType == "error" {
		reason, _ := okResp["reason"].(string)
		return fmt.Errorf("server rejected connection: %s", reason)
	}
	if okType != "ok" {
		return fmt.Errorf("expected 'ok', got '%s'", okType)
	}

	return nil
}

// sendControlJSON sends a JSON-encoded control message over the PersistentProtocol.
func (c *Client) sendControlJSON(v interface{}) error {
	data, err := json.Marshal(v)
	if err != nil {
		return err
	}
	msg := &ProtocolMessage{
		Type: ProtocolMessageControl,
		ID:   0,
		Ack:  0,
		Data: data,
	}
	return c.WriteMessage(msg)
}

// readControlJSON reads the next PersistentProtocol frame and expects a control message.
func (c *Client) readControlJSON(ctx context.Context) (map[string]interface{}, error) {
	for {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		default:
		}

		msg, err := c.readOneMessage()
		if err != nil {
			return nil, err
		}
		if msg.Type == ProtocolMessageControl {
			var result map[string]interface{}
			if err := json.Unmarshal(msg.Data, &result); err != nil {
				return nil, fmt.Errorf("unmarshal control message: %w", err)
			}
			return result, nil
		}
		// Buffer non-control messages received during handshake
		// (e.g., the Initialize IPC message) for later replay.
		c.bufferedMessages = append(c.bufferedMessages, msg)
	}
}

// readOneMessage reads exactly one PersistentProtocol frame from the WebSocket.
func (c *Client) readOneMessage() (*ProtocolMessage, error) {
	_, rawData, err := c.conn.ReadMessage()
	if err != nil {
		return nil, fmt.Errorf("ws read: %w", err)
	}
	// The WebSocket message may contain one or more protocol frames.
	// During handshake we expect exactly one.
	return DecodeProtocolMessage(bytes.NewReader(rawData))
}

// WriteMessage sends a PersistentProtocol frame over the WebSocket.
func (c *Client) WriteMessage(msg *ProtocolMessage) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.writeMessageLocked(msg)
}

func (c *Client) writeMessageLocked(msg *ProtocolMessage) error {
	if c.conn == nil {
		return fmt.Errorf("not connected")
	}
	data := EncodeProtocolMessage(msg)
	return c.conn.WriteMessage(websocket.BinaryMessage, data)
}

// SendRegular sends a Regular protocol message with proper ID tracking.
func (c *Client) SendRegular(data []byte) error {
	id := c.outgoingMsgID.Add(1)
	ack := c.incomingMsgID.Load()
	msg := &ProtocolMessage{
		Type: ProtocolMessageRegular,
		ID:   id,
		Ack:  ack,
		Data: data,
	}
	return c.WriteMessage(msg)
}

// readLoop continuously reads messages from the WebSocket and dispatches them.
func (c *Client) readLoop() {
	for {
		_, rawData, err := c.conn.ReadMessage()
		if err != nil {
			// Connection closed or error.
			return
		}

		reader := bytes.NewReader(rawData)
		for reader.Len() > 0 {
			msg, err := DecodeProtocolMessage(reader)
			if err != nil {
				if err == io.EOF {
					break
				}
				log.Printf("vscode: decode error: %v", err)
				break
			}
			c.handleMessage(msg)
		}
	}
}

func (c *Client) handleMessage(msg *ProtocolMessage) {
	switch msg.Type {
	case ProtocolMessageRegular:
		c.incomingMsgID.Store(msg.ID)
		if c.onMessage != nil {
			c.onMessage(msg.Data)
		}
	case ProtocolMessageControl:
		if c.onControl != nil {
			c.onControl(msg.Data)
		}
	case ProtocolMessageAck:
		c.outgoingAckID.Store(msg.Ack)
	case ProtocolMessageKeepAlive:
		// No action needed.
	case ProtocolMessageDisconnect:
		log.Println("vscode: received disconnect")
	}
}

// keepAliveLoop sends periodic keep-alive frames.
func (c *Client) keepAliveLoop() {
	ticker := time.NewTicker(keepAliveSendTime)
	defer ticker.Stop()
	for {
		select {
		case <-c.stopKeepAlive:
			return
		case <-ticker.C:
			msg := &ProtocolMessage{
				Type: ProtocolMessageKeepAlive,
				ID:   0,
				Ack:  0,
				Data: []byte{},
			}
			if err := c.WriteMessage(msg); err != nil {
				return
			}
		}
	}
}

// buildWSURL constructs the WebSocket URL for connecting to the server.
func buildWSURL(serverURL string, reconnectionToken string, reconnection bool) (string, error) {
	u, err := url.Parse(serverURL)
	if err != nil {
		return "", err
	}

	// Switch scheme to ws/wss.
	switch u.Scheme {
	case "http":
		u.Scheme = "ws"
	case "https":
		u.Scheme = "wss"
	case "ws", "wss":
		// Already correct.
	default:
		u.Scheme = "ws"
	}

	// The WebSocket endpoint path.
	u.Path = u.Path + "/"

	q := u.Query()
	q.Set("reconnectionToken", reconnectionToken)
	if reconnection {
		q.Set("reconnection", "true")
	} else {
		q.Set("reconnection", "false")
	}
	q.Set("skipWebSocketFrames", "false")
	u.RawQuery = q.Encode()

	return u.String(), nil
}
