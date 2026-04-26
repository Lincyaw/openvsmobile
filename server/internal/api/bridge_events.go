package api

import (
	"encoding/json"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/Lincyaw/vscode-mobile/server/internal/bridge"
	"github.com/Lincyaw/vscode-mobile/server/internal/terminal"
)

// handleWSBridgeEvents fans out the bridge SSE feed to a connected mobile
// client. Each connection subscribes to the EventStream and forwards events
// as JSON envelopes of the form `{"type":"<name>","payload":<data>,"ts":...}`.
//
// In addition to the bridge SSE feed, this WebSocket multiplexes local
// terminal lifecycle events (`terminal.session.created` / `.updated` /
// `.closed`) so that the Flutter side can consume a single event stream.
//
// The shape mirrors what the existing GitProvider already parses (see
// app/lib/providers/git_provider.dart -> _onEvent) so that adding new event
// types on the server doesn't require a Flutter-side schema change.
func (s *Server) handleWSBridgeEvents(w http.ResponseWriter, r *http.Request) {
	if s.bridgeEvents == nil && s.termManager == nil {
		http.Error(w, "bridge events stream not configured", http.StatusServiceUnavailable)
		return
	}

	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("[WS/BridgeEvents] upgrade error: %v", err)
		return
	}
	defer conn.Close()

	// Subscribe to the bridge SSE stream (if configured) and the local
	// terminal manager (if configured). Each subscription owns its own
	// cancel func that we invoke on disconnect to avoid goroutine /
	// channel leaks.
	var (
		bridgeEvents <-chan bridge.Event
		bridgeCancel func()
	)
	if s.bridgeEvents != nil {
		bridgeEvents, bridgeCancel = s.bridgeEvents.Subscribe()
		defer bridgeCancel()
	}

	var (
		termEvents <-chan terminal.Event
		termCancel func()
	)
	if s.termManager != nil {
		termEvents, termCancel = s.termManager.SubscribeEvents()
		defer termCancel()
	}

	// Send a hello frame so the client knows the channel is wired up.
	_ = conn.WriteJSON(map[string]any{
		"type": "ready",
		"ts":   time.Now().UTC().Format(time.RFC3339Nano),
	})

	// Reader goroutine: detect client disconnect / pings.
	readErrCh := make(chan struct{})
	go func() {
		defer close(readErrCh)
		for {
			if _, _, err := conn.ReadMessage(); err != nil {
				return
			}
		}
	}()

	for {
		select {
		case ev, ok := <-bridgeEvents:
			if !ok {
				// Stream shut down (server stopping). Tell the client.
				_ = conn.WriteJSON(map[string]any{"type": "closed"})
				return
			}
			// Decode the inner data so the JSON we emit on the wire is
			// `payload: <object>` instead of `payload: "<json string>"`.
			payload := decodeBridgeEventPayload(ev.Data)
			if err := conn.WriteJSON(map[string]any{
				"type":    ev.Type,
				"payload": payload,
				"ts":      ev.Timestamp.UTC().Format(time.RFC3339Nano),
			}); err != nil {
				log.Printf("[WS/BridgeEvents] write error: %v", err)
				return
			}
		case ev, ok := <-termEvents:
			if !ok {
				// Terminal manager went away — clear the channel so the
				// select stops firing on it. The bridge subscription (if
				// any) keeps running.
				termEvents = nil
				continue
			}
			if err := conn.WriteJSON(map[string]any{
				"type":    normalizeTerminalEventType(ev.Type),
				"payload": ev.Session,
				"ts":      time.Now().UTC().Format(time.RFC3339Nano),
			}); err != nil {
				log.Printf("[WS/BridgeEvents] write error: %v", err)
				return
			}
		case <-readErrCh:
			return
		}
	}
}

// normalizeTerminalEventType converts the in-process slash-style event name
// (e.g. `terminal/session.created`) to the dotted naming used by the bridge
// SSE feed (`terminal.session.created`) so consumers see one convention.
func normalizeTerminalEventType(t string) string {
	return strings.Replace(t, "/", ".", 1)
}

func decodeBridgeEventPayload(raw json.RawMessage) any {
	if len(raw) == 0 {
		return nil
	}
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		return string(raw)
	}
	return v
}
