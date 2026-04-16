package api

import (
	"log"
	"sync"
	"time"

	"github.com/fsnotify/fsnotify"
)

// FileWatcher watches a workspace directory for changes and broadcasts
// events to all connected file-watch clients via FileWatchHub.
type FileWatcher struct {
	hub     *FileWatchHub
	watcher *fsnotify.Watcher
	mu      sync.Mutex
	workDir string
	stopCh  chan struct{}
}

// NewFileWatcher creates a new file watcher attached to the given hub.
func NewFileWatcher(hub *FileWatchHub) (*FileWatcher, error) {
	w, err := fsnotify.NewWatcher()
	if err != nil {
		return nil, err
	}
	fw := &FileWatcher{
		hub:     hub,
		watcher: w,
		stopCh:  make(chan struct{}),
	}
	go fw.loop()
	return fw, nil
}

// SetWorkDir switches the watched directory to [dir].
// The previous directory (if any) is removed from the watcher.
func (fw *FileWatcher) SetWorkDir(dir string) {
	fw.mu.Lock()
	defer fw.mu.Unlock()

	if fw.workDir == dir {
		return
	}

	if fw.workDir != "" {
		_ = fw.watcher.Remove(fw.workDir)
	}

	fw.workDir = dir

	if dir != "" && dir != "/" {
		_ = fw.watcher.Add(dir)
	}
}

func (fw *FileWatcher) loop() {
	var (
		debounceTimer *time.Timer
		pending       bool
		mu            sync.Mutex
	)

	for {
		select {
		case event, ok := <-fw.watcher.Events:
			if !ok {
				return
			}
			if event.Op == fsnotify.Chmod {
				continue
			}

			mu.Lock()
			pending = true
			mu.Unlock()

			if debounceTimer != nil {
				debounceTimer.Stop()
			}
			debounceTimer = time.AfterFunc(1*time.Second, func() {
				mu.Lock()
				hasPending := pending
				pending = false
				mu.Unlock()

				if hasPending {
					fw.hub.Broadcast(map[string]string{"type": "file_changed"})
				}
			})

		case err, ok := <-fw.watcher.Errors:
			if !ok {
				return
			}
			log.Printf("[FileWatcher] error: %v", err)

		case <-fw.stopCh:
			if debounceTimer != nil {
				debounceTimer.Stop()
			}
			return
		}
	}
}

// Close stops the watcher and releases resources.
func (fw *FileWatcher) Close() error {
	close(fw.stopCh)
	return fw.watcher.Close()
}
