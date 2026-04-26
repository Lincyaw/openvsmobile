package api

import (
	"encoding/json"
	"log"
	"net/http"
	"time"
)

// handleWSBridgeEvents fans out the bridge SSE feed to a connected mobile
// client. Each connection subscribes to the EventStream and forwards events
// as JSON envelopes of the form `{"type":"<name>","payload":<data>,"ts":...}`.
//
// The shape mirrors what the existing GitProvider already parses (see
// app/lib/providers/git_provider.dart -> _onEvent) so that adding new event
// types on the server doesn't require a Flutter-side schema change.
func (s *Server) handleWSBridgeEvents(w http.ResponseWriter, r *http.Request) {
	if s.bridgeEvents == nil {
		http.Error(w, "bridge events stream not configured", http.StatusServiceUnavailable)
		return
	}

	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("[WS/BridgeEvents] upgrade error: %v", err)
		return
	}
	defer conn.Close()

	events, cancel := s.bridgeEvents.Subscribe()
	defer cancel()

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
		case ev, ok := <-events:
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
		case <-readErrCh:
			return
		}
	}
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
