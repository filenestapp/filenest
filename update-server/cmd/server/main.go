package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"filenest/update-server/internal/config"
	"filenest/update-server/internal/httpapi"
	"filenest/update-server/internal/release"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	cfg, err := config.Load()
	if err != nil {
		logger.Error("Invalid server configuration", "error", err)
		os.Exit(1)
	}

	store, err := release.NewFileStore(cfg.DataFile)
	if err != nil {
		logger.Error("Could not open release store", "error", err)
		os.Exit(1)
	}

	api := httpapi.New(
		store,
		cfg.AdminToken,
		cfg.AllowedOrigins,
		httpapi.WithLogger(logger),
		httpapi.WithOMPManifestFile(cfg.OMPManifestFile),
	)
	server := &http.Server{
		Addr:              cfg.Address,
		Handler:           api.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	shutdownSignals := make(chan os.Signal, 1)
	signal.Notify(shutdownSignals, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		<-shutdownSignals
		logger.Info("Shutting down update API")
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := server.Shutdown(ctx); err != nil {
			logger.Error("Could not shut down update API cleanly", "error", err)
		}
	}()

	logger.Info(
		"Starting FileNest update API",
		"address", cfg.Address,
		"data_file", cfg.DataFile,
		"omp_manifest_file", cfg.OMPManifestFile,
	)
	if cfg.AdminToken == "" {
		logger.Warn("Admin API is disabled because FILENEST_UPDATE_ADMIN_TOKEN is empty")
	}
	if err := server.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
		logger.Error("Update API stopped unexpectedly", "error", err)
		os.Exit(1)
	}
}
