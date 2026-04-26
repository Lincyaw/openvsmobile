package bridge

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Event is a single fan-out event emitted by the bridge extension.
type Event struct {
	Type      string          `json:"type"`
	Data      json.RawMessage `json:"data"`
	Timestamp time.Time       `json:"ts"`
}

// EventStream owns a long-lived goroutine that consumes the extension's
// /events SSE endpoint and fans out parsed events to subscribers.
//
// Reconnect strategy:
//   - On any read error, wait with exponential backoff (1s..30s) and retry.
//   - On runtime-info file mtime change, force-close the in-flight connection
//     so the next iteration picks up the new host:port/token.
//   - When runtime-info is missing, poll its existence every 5s.
type EventStream struct {
	client *Client

	// Subscriber bookkeeping.
	mu      sync.Mutex
	nextID  uint64
	subs    map[uint64]chan Event
	closed  bool

	// Liveness telemetry — atomic so callers can read without locking.
	lastReadyUnixNano   atomic.Int64
	lastEventUnixNano   atomic.Int64
	lastKeepaliveUnixNano atomic.Int64

	// Tunables (overridable for tests).
	initialBackoff   time.Duration
	maxBackoff       time.Duration
	missingPollEvery time.Duration
	mtimePollEvery   time.Duration
	httpClient       *http.Client
}

// NewEventStream builds an EventStream for the given bridge client. Call Start
// to launch the background consumer.
func NewEventStream(client *Client) *EventStream {
	return &EventStream{
		client:           client,
		subs:             make(map[uint64]chan Event),
		initialBackoff:   1 * time.Second,
		maxBackoff:       30 * time.Second,
		missingPollEvery: 5 * time.Second,
		mtimePollEvery:   2 * time.Second,
		httpClient: &http.Client{
			// No overall timeout: SSE is intentionally long-lived. Per-request
			// cancellation is driven by ctx.
			Transport: &http.Transport{
				MaxIdleConns:        2,
				MaxIdleConnsPerHost: 1,
				IdleConnTimeout:     30 * time.Second,
			},
		},
	}
}

// Start launches the consumer goroutine. The stream stops when ctx is done.
// Calling Start more than once is undefined; instantiate a fresh EventStream
// per process.
func (s *EventStream) Start(ctx context.Context) {
	go s.run(ctx)
}

// Subscribe returns a channel that receives events. The caller must invoke
// the returned cancel function to release the slot when done; otherwise the
// stream's broadcaster will block on the channel and back-pressure others.
//
// The returned channel is buffered. If the buffer fills (slow consumer),
// further events are dropped for that subscriber rather than stalling the
// broadcast loop.
func (s *EventStream) Subscribe() (<-chan Event, func()) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.closed {
		ch := make(chan Event)
		close(ch)
		return ch, func() {}
	}

	id := s.nextID
	s.nextID++
	ch := make(chan Event, 64)
	s.subs[id] = ch

	cancel := func() {
		s.mu.Lock()
		if existing, ok := s.subs[id]; ok && existing == ch {
			delete(s.subs, id)
			close(ch)
		}
		s.mu.Unlock()
	}
	return ch, cancel
}

// SubscriberCount is exposed for tests to assert leak-free subscribe/unsubscribe.
func (s *EventStream) SubscriberCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.subs)
}

// LastEventAt reports the time of the most recently fanned-out event (any
// type), or the zero value if none has been received.
func (s *EventStream) LastEventAt() time.Time {
	v := s.lastEventUnixNano.Load()
	if v == 0 {
		return time.Time{}
	}
	return time.Unix(0, v)
}

// LastReadyAt reports the time of the most recent `ready` frame.
func (s *EventStream) LastReadyAt() time.Time {
	v := s.lastReadyUnixNano.Load()
	if v == 0 {
		return time.Time{}
	}
	return time.Unix(0, v)
}

func (s *EventStream) broadcast(ev Event) {
	s.lastEventUnixNano.Store(time.Now().UnixNano())
	s.mu.Lock()
	// Snapshot under the lock to avoid holding it across channel sends.
	targets := make([]chan Event, 0, len(s.subs))
	for _, ch := range s.subs {
		targets = append(targets, ch)
	}
	s.mu.Unlock()

	for _, ch := range targets {
		select {
		case ch <- ev:
		default:
			// Slow subscriber — drop. Better to lose an event for one
			// client than stall every consumer behind a stuck channel.
		}
	}
}

func (s *EventStream) run(ctx context.Context) {
	backoff := s.initialBackoff
	for {
		if ctx.Err() != nil {
			s.shutdown()
			return
		}

		info, err := s.client.RuntimeInfo()
		if err != nil {
			if errors.Is(err, ErrBridgeUnavailable) || isNotExist(err) {
				if !sleepCtx(ctx, s.missingPollEvery) {
					s.shutdown()
					return
				}
				continue
			}
			log.Printf("[bridge/events] runtime info read error: %v", err)
			if !sleepCtx(ctx, backoff) {
				s.shutdown()
				return
			}
			backoff = nextBackoff(backoff, s.maxBackoff)
			continue
		}

		// Runtime info loaded — open the SSE stream and pump until error.
		path := s.client.cache.Path()
		ranOK, err := s.consume(ctx, info, path)
		if ctx.Err() != nil {
			s.shutdown()
			return
		}
		if ranOK {
			// We saw at least one event/ready frame, so reset backoff —
			// transient drops shouldn't pile on extra delay.
			backoff = s.initialBackoff
		}
		if err != nil {
			log.Printf("[bridge/events] stream error: %v", err)
		}
		// Force the client cache to re-read the runtime-info file on the next
		// iteration so that a restarted extension is picked up immediately.
		s.client.cache.Invalidate()
		if !sleepCtx(ctx, backoff) {
			s.shutdown()
			return
		}
		if !ranOK {
			backoff = nextBackoff(backoff, s.maxBackoff)
		}
	}
}

// consume opens an SSE connection and pumps events until either the connection
// errors out or the runtime-info file's mtime changes (signal that the
// extension restarted). Returns true if at least one frame was processed.
func (s *EventStream) consume(ctx context.Context, info RuntimeInfo, infoPath string) (bool, error) {
	// Establish the request with a per-attempt cancellable context so we can
	// abort the read when the runtime-info mtime watcher sees a restart.
	attemptCtx, cancel := context.WithCancel(ctx)
	defer cancel()

	req, err := http.NewRequestWithContext(attemptCtx, http.MethodGet, info.BaseURL()+"/events", nil)
	if err != nil {
		return false, fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("Accept", "text/event-stream")
	req.Header.Set("Cache-Control", "no-cache")
	req.Header.Set("Authorization", "Bearer "+info.Token)

	resp, err := s.httpClient.Do(req)
	if err != nil {
		return false, fmt.Errorf("dial /events: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return false, fmt.Errorf("/events status %d", resp.StatusCode)
	}

	// Watcher: if the runtime-info file's mtime changes, abort the request.
	// This catches extension restarts where the listener moved port/token but
	// the previous TCP connection is still half-open.
	watcherDone := make(chan struct{})
	go s.watchRuntimeInfoMtime(attemptCtx, infoPath, cancel, watcherDone)
	defer func() {
		cancel()
		<-watcherDone
	}()

	reader := bufio.NewReader(resp.Body)
	processed := false

	var (
		evType string
		data   strings.Builder
	)
	flush := func() {
		if evType == "" && data.Len() == 0 {
			return
		}
		s.handleFrame(evType, data.String())
		processed = true
		evType = ""
		data.Reset()
	}

	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			if errors.Is(err, io.EOF) {
				return processed, nil
			}
			return processed, err
		}
		// Strip the trailing newline (and CR if present).
		line = strings.TrimRight(line, "\n")
		line = strings.TrimRight(line, "\r")

		// Blank line marks end-of-frame per the SSE spec.
		if line == "" {
			flush()
			continue
		}
		// Comments (": ...") are used by the extension as keepalives.
		if strings.HasPrefix(line, ":") {
			s.lastKeepaliveUnixNano.Store(time.Now().UnixNano())
			continue
		}
		if strings.HasPrefix(line, "event:") {
			evType = strings.TrimSpace(line[len("event:"):])
			continue
		}
		if strings.HasPrefix(line, "data:") {
			if data.Len() > 0 {
				data.WriteByte('\n')
			}
			data.WriteString(strings.TrimPrefix(strings.TrimSpace(line[len("data:"):]), ""))
			continue
		}
		// Ignore unknown SSE fields (id:, retry:) — we don't use them.
	}
}

// handleFrame dispatches a parsed SSE frame to subscribers. Liveness frames
// (`ready`, `keepalive`) are recorded for telemetry but not fanned out.
func (s *EventStream) handleFrame(evType, payload string) {
	switch evType {
	case "":
		// Frames without an event: type are valid SSE but we have no
		// schema for them today; drop quietly.
		return
	case "ready":
		s.lastReadyUnixNano.Store(time.Now().UnixNano())
		return
	case "keepalive":
		s.lastKeepaliveUnixNano.Store(time.Now().UnixNano())
		return
	}

	raw := json.RawMessage(payload)
	if payload == "" {
		raw = json.RawMessage("null")
	}
	s.broadcast(Event{
		Type:      evType,
		Data:      raw,
		Timestamp: time.Now(),
	})
}

func (s *EventStream) watchRuntimeInfoMtime(ctx context.Context, infoPath string, cancel context.CancelFunc, done chan<- struct{}) {
	defer close(done)
	if infoPath == "" {
		return
	}
	stat, err := os.Stat(infoPath)
	if err != nil {
		// If the file disappears, treat that as a restart trigger so we
		// re-enter the main loop and start polling for it.
		cancel()
		return
	}
	original := stat.ModTime()
	period := s.mtimePollEvery
	if period <= 0 {
		period = 2 * time.Second
	}
	ticker := time.NewTicker(period)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			stat, err := os.Stat(infoPath)
			if err != nil {
				cancel()
				return
			}
			if !stat.ModTime().Equal(original) {
				cancel()
				return
			}
		}
	}
}

func (s *EventStream) shutdown() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	for id, ch := range s.subs {
		close(ch)
		delete(s.subs, id)
	}
	s.mu.Unlock()
}

func sleepCtx(ctx context.Context, d time.Duration) bool {
	if d <= 0 {
		return ctx.Err() == nil
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-t.C:
		return true
	}
}

func nextBackoff(current, max time.Duration) time.Duration {
	doubled := current * 2
	if doubled > max {
		return max
	}
	return doubled
}

func isNotExist(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, os.ErrNotExist) {
		return true
	}
	msg := err.Error()
	return strings.Contains(msg, "no such file") || strings.Contains(msg, "missing")
}
