package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/Lincyaw/vscode-mobile/server/internal/api"
	"github.com/Lincyaw/vscode-mobile/server/internal/claude"
	"github.com/Lincyaw/vscode-mobile/server/internal/diagnostics"
	"github.com/Lincyaw/vscode-mobile/server/internal/git"
	"github.com/Lincyaw/vscode-mobile/server/internal/terminal"
	"github.com/Lincyaw/vscode-mobile/server/internal/vscode"
)

func main() {
	var (
		port       int
		vsCodeURL  string
		vsCodeTok  string
		claudeHome string
		claudeBin  string
		token      string
		workDir    string
	)

	flag.IntVar(&port, "port", 8080, "HTTP server port")
	flag.StringVar(&vsCodeURL, "vscode-url", "http://localhost:3000", "OpenVSCode Server URL")
	flag.StringVar(&vsCodeTok, "vscode-token", "", "OpenVSCode Server connection token")
	flag.StringVar(&claudeHome, "claude-home", "", "Claude home directory (default: ~/.claude)")
	flag.StringVar(&claudeBin, "claude-bin", "claude", "Claude CLI binary path")
	flag.StringVar(&token, "token", "", "Connection token for API authentication")
	flag.StringVar(&workDir, "work-dir", ".", "Working directory for Claude processes")
	flag.Parse()

	if claudeHome == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			log.Fatalf("failed to get home directory: %v", err)
		}
		claudeHome = home + "/.claude"
	}

	// Initialize session index.
	sessionIndex := claude.NewSessionIndex(claudeHome)
	if err := sessionIndex.ScanSessions(); err != nil {
		log.Printf("warning: failed to scan sessions: %v", err)
	}

	// Initialize process manager.
	pm := claude.NewProcessManager(claudeBin, workDir)

	// Initialize filesystem via VS Code remote proxy.
	var fs api.FileSystem
	var vsClient *vscode.Client
	var bridgeManager *vscode.BridgeManager
	bridgeCtx, cancelBridge := context.WithCancel(context.Background())
	defer cancelBridge()
	if vsCodeURL != "" {
		vsClient = vscode.NewClient()
		if err := vsClient.Connect(context.Background(), vsCodeURL, vsCodeTok); err != nil {
			log.Fatalf("failed to connect to vscode server: %v", err)
		}
		fsp := vscode.NewFileSystemProxy(vsClient.IPC(), "vscode-remote")
		fs = api.NewVSCodeFSAdapter(fsp)
		bridgeManager = vscode.NewBridgeManager(vscode.BridgeManagerOptions{
			Client:          vsClient,
			ServerURL:       vsCodeURL,
			ConnectionToken: vsCodeTok,
		})
		bridgeManager.Start(bridgeCtx)
		log.Printf("mobile runtime bridge discovery watching %s", bridgeManager.MetadataPath())
	}

	// Initialize git client.
	gitClient := git.NewGit(workDir)

	// Initialize terminal manager.
	termMgr := terminal.NewManager()

	// Initialize diagnostics runner.
	diagRunner := diagnostics.NewRunner(30 * time.Second)

	// Start periodic session index refresh.
	stopRefresh := make(chan struct{})
	go func() {
		ticker := time.NewTicker(30 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				if err := sessionIndex.ScanSessions(); err != nil {
					log.Printf("warning: session refresh failed: %v", err)
				}
			case <-stopRefresh:
				return
			}
		}
	}()

	// Initialize API server.
	srv := api.NewServer(fs, sessionIndex, pm, token, gitClient, termMgr, diagRunner)
	srv.SetBridgeManager(bridgeManager)

	httpServer := &http.Server{
		Addr:    fmt.Sprintf(":%d", port),
		Handler: srv.Handler(),
	}

	// Graceful shutdown.
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)

	go func() {
		log.Printf("server starting on :%d", port)
		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("server error: %v", err)
		}
	}()

	<-sigCh
	log.Println("shutting down...")

	// Stop session refresh goroutine.
	close(stopRefresh)

	// Shutdown HTTP server.
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := httpServer.Shutdown(ctx); err != nil {
		log.Printf("http shutdown error: %v", err)
	}

	// Shutdown terminals.
	termMgr.CloseAll()

	// Shutdown Claude processes.
	pm.Shutdown()

	// Close VS Code connection.
	cancelBridge()
	if bridgeManager != nil {
		bridgeManager.Close()
	}
	if vsClient != nil {
		if err := vsClient.Close(); err != nil {
			log.Printf("vscode client close error: %v", err)
		}
	}

	log.Println("shutdown complete")
}
