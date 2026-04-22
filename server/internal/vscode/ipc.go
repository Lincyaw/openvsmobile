package vscode

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"time"
)

// defaultCallTimeout is the maximum time to wait for an IPC response.
const defaultCallTimeout = 30 * time.Second

// IPCClient multiplexes IPC channels over a single VS Code PersistentProtocol
// connection. It mirrors the ChannelClient from ipc.ts.
type IPCClient struct {
	client      *Client
	lastReqID   atomic.Int64
	handlers    sync.Map // map[int]responseHandler
	initialized chan struct{}
}

// responseHandler processes incoming IPC responses.
type responseHandler func(respType ResponseType, data interface{})

// NewIPCClient creates an IPC multiplexer on top of the given Client.
// It hooks into the Client's message stream to receive Regular messages.
func NewIPCClient(c *Client) *IPCClient {
	ipc := &IPCClient{
		client:      c,
		initialized: make(chan struct{}),
	}
	ipc.attachClient(c)
	return ipc
}

func (ipc *IPCClient) attachClient(c *Client) {
	ipc.client = c
	c.onMessage = ipc.onRawMessage
}

func (ipc *IPCClient) reset(c *Client) {
	ipc.handlers = sync.Map{}
	ipc.initialized = make(chan struct{})
	ipc.attachClient(c)
}

// GetChannel returns a handle to the named IPC channel.
func (ipc *IPCClient) GetChannel(name string) *IPCChannel {
	return &IPCChannel{
		ipc:  ipc,
		name: name,
	}
}

// nextID returns the next request ID.
func (ipc *IPCClient) nextID() int {
	return int(ipc.lastReqID.Add(1))
}

// onRawMessage is called by the Client for each Regular message received.
func (ipc *IPCClient) onRawMessage(data []byte) {
	header, body, err := DecodeIPCMessage(data)
	if err != nil {
		return
	}

	hdr, ok := header.([]interface{})
	if !ok || len(hdr) == 0 {
		return
	}

	respType, err := toInt(hdr[0])
	if err != nil {
		return
	}

	switch ResponseType(respType) {
	case ResponseTypeInitialize:
		select {
		case <-ipc.initialized:
		default:
			close(ipc.initialized)
		}
	case ResponseTypePromiseSuccess, ResponseTypePromiseError, ResponseTypePromiseErrorObj, ResponseTypeEventFire:
		if len(hdr) < 2 {
			return
		}
		id, err := toInt(hdr[1])
		if err != nil {
			return
		}
		if h, ok := ipc.handlers.Load(id); ok {
			h.(responseHandler)(ResponseType(respType), body)
		}
	}
}

// sendRequest sends an IPC request and returns a channel that will receive the response.
func (ipc *IPCClient) sendRequest(reqType RequestType, id int, channelName string, command string, arg interface{}) error {
	var header []interface{}
	switch reqType {
	case RequestTypePromise, RequestTypeEventListen:
		header = []interface{}{int(reqType), id, channelName, command}
	case RequestTypePromiseCancel, RequestTypeEventDispose:
		header = []interface{}{int(reqType), id}
	default:
		return fmt.Errorf("unsupported request type: %d", reqType)
	}

	data := EncodeIPCMessage(header, arg)
	return ipc.client.SendRegular(data)
}

// IPCChannel represents a named channel in the VS Code IPC system.
type IPCChannel struct {
	ipc  *IPCClient
	name string
}

// Call makes a request to this channel's command and waits for the response.
func (ch *IPCChannel) Call(command string, arg interface{}) (interface{}, error) {
	return ch.CallContext(context.Background(), command, arg)
}

// CallContext is like Call but honors cancellation.
func (ch *IPCChannel) CallContext(ctx context.Context, command string, arg interface{}) (interface{}, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	select {
	case <-ch.ipc.initialized:
	case <-ctx.Done():
		return nil, ctx.Err()
	}

	id := ch.ipc.nextID()
	resultCh := make(chan ipcResult, 1)

	ch.ipc.handlers.Store(id, responseHandler(func(respType ResponseType, data interface{}) {
		switch respType {
		case ResponseTypePromiseSuccess:
			resultCh <- ipcResult{data: data}
		case ResponseTypePromiseError:
			errMap, ok := data.(map[string]interface{})
			if ok {
				msg, _ := errMap["message"].(string)
				resultCh <- ipcResult{err: fmt.Errorf("remote error: %s", msg)}
			} else {
				resultCh <- ipcResult{err: fmt.Errorf("remote error (unknown)")}
			}
		case ResponseTypePromiseErrorObj:
			resultCh <- ipcResult{err: fmt.Errorf("remote error object: %v", data)}
		default:
			resultCh <- ipcResult{err: fmt.Errorf("unexpected response type: %d", respType)}
		}
	}))
	defer ch.ipc.handlers.Delete(id)

	if err := ch.ipc.sendRequest(RequestTypePromise, id, ch.name, command, arg); err != nil {
		return nil, fmt.Errorf("send request: %w", err)
	}

	select {
	case result := <-resultCh:
		return result.data, result.err
	case <-time.After(defaultCallTimeout):
		return nil, fmt.Errorf("IPC call %q timed out after %v", command, defaultCallTimeout)
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

// Listen subscribes to an event on this channel. It returns a channel that
// receives event data and a function to stop listening.
func (ch *IPCChannel) Listen(event string, arg interface{}) (<-chan interface{}, func(), error) {
	return ch.ListenContext(context.Background(), event, arg)
}

// ListenContext is like Listen but waits for channel initialization and honors cancellation.
func (ch *IPCChannel) ListenContext(ctx context.Context, event string, arg interface{}) (<-chan interface{}, func(), error) {
	if ctx == nil {
		ctx = context.Background()
	}
	select {
	case <-ch.ipc.initialized:
	case <-ctx.Done():
		return nil, nil, ctx.Err()
	}

	id := ch.ipc.nextID()
	eventCh := make(chan interface{}, 64)
	var once sync.Once

	ch.ipc.handlers.Store(id, responseHandler(func(respType ResponseType, data interface{}) {
		if respType == ResponseTypeEventFire {
			select {
			case eventCh <- data:
			default:
				// Drop if buffer is full.
			}
		}
	}))

	if err := ch.ipc.sendRequest(RequestTypeEventListen, id, ch.name, event, arg); err != nil {
		ch.ipc.handlers.Delete(id)
		close(eventCh)
		return nil, nil, err
	}

	dispose := func() {
		once.Do(func() {
			ch.ipc.handlers.Delete(id)
			close(eventCh)
			// Best effort: send dispose notification.
			_ = ch.ipc.sendRequest(RequestTypeEventDispose, id, "", "", nil)
		})
	}

	return eventCh, dispose, nil
}

type ipcResult struct {
	data interface{}
	err  error
}

// toInt converts a deserialized value to int (handles both int and float64 from JSON).
func toInt(v interface{}) (int, error) {
	switch n := v.(type) {
	case int:
		return n, nil
	case float64:
		return int(n), nil
	case int64:
		return int(n), nil
	default:
		return 0, fmt.Errorf("cannot convert %T to int", v)
	}
}
