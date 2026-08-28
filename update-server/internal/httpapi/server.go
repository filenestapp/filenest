package httpapi

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"

	"filenest/update-server/internal/release"
)

const (
	maxRequestBody = 1 << 20
	maxOMPManifest = 64 << 10
	adminPath      = "/v1/admin/releases"
)

var ompSHA256Pattern = regexp.MustCompile(`^[a-fA-F0-9]{64}$`)

type Server struct {
	store           release.Store
	adminToken      string
	ompManifestFile string
	allowedOrigins  map[string]struct{}
	logger          *slog.Logger
	mux             *http.ServeMux
	now             func() time.Time
}

type Option func(*Server)

func WithLogger(logger *slog.Logger) Option {
	return func(server *Server) {
		if logger != nil {
			server.logger = logger
		}
	}
}

func WithClock(now func() time.Time) Option {
	return func(server *Server) {
		if now != nil {
			server.now = now
		}
	}
}

func WithOMPManifestFile(path string) Option {
	return func(server *Server) {
		server.ompManifestFile = strings.TrimSpace(path)
	}
}

func New(
	store release.Store,
	adminToken string,
	allowedOrigins []string,
	options ...Option,
) *Server {
	server := &Server{
		store:          store,
		adminToken:     adminToken,
		allowedOrigins: make(map[string]struct{}, len(allowedOrigins)),
		logger:         slog.Default(),
		mux:            http.NewServeMux(),
		now:            time.Now,
	}
	for _, origin := range allowedOrigins {
		server.allowedOrigins[origin] = struct{}{}
	}
	for _, option := range options {
		option(server)
	}

	server.routes()
	return server
}

func (s *Server) Handler() http.Handler {
	return s.withAccessLog(s.withCORS(s.mux))
}

func (s *Server) routes() {
	s.mux.HandleFunc("/healthz", s.handleHealth)
	s.mux.HandleFunc("/v1/updates/check", s.handleCheck)
	s.mux.HandleFunc("/v1/releases/latest", s.handleLatest)
	s.mux.HandleFunc("/appcast.xml", s.handleAppcast)
	s.mux.HandleFunc("/appcast/", s.handleAppcastAlias)
	s.mux.HandleFunc("/omp-agent/stable.json", s.handleOMPManifest)
	s.mux.HandleFunc(adminPath, s.handleAdminReleases)
	s.mux.HandleFunc(adminPath+"/", s.handleAdminRelease)
}

func (s *Server) handleHealth(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		writeMethodNotAllowed(writer, http.MethodGet)
		return
	}
	writeJSON(writer, http.StatusOK, map[string]any{
		"status": "ok",
		"time":   s.now().UTC(),
	})
}

func (s *Server) handleCheck(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		writeMethodNotAllowed(writer, http.MethodGet)
		return
	}

	filter := filterFromQuery(request.URL.Query())
	currentVersion := strings.TrimSpace(request.URL.Query().Get("version"))
	currentBuild, err := optionalInt64(request.URL.Query().Get("build"))
	if err != nil {
		writeError(writer, http.StatusBadRequest, "invalid_request", "build must be an integer")
		return
	}
	if currentVersion == "" && currentBuild == 0 {
		writeError(
			writer,
			http.StatusBadRequest,
			"invalid_request",
			"version or build is required",
		)
		return
	}

	latest, found := s.store.Latest(filter)
	response := checkResponse{
		UpdateAvailable: false,
		CheckedAt:       s.now().UTC().Truncate(5 * time.Minute),
	}
	if found {
		response.Latest = &latest
		response.UpdateAvailable = release.IsNewer(latest, currentVersion, currentBuild)
	}
	writeCacheableJSON(writer, request, http.StatusOK, response)
}

func (s *Server) handleLatest(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		writeMethodNotAllowed(writer, http.MethodGet)
		return
	}

	item, found := s.store.Latest(filterFromQuery(request.URL.Query()))
	if !found {
		writeError(writer, http.StatusNotFound, "release_not_found", "no matching release was found")
		return
	}
	writeCacheableJSON(writer, request, http.StatusOK, item)
}

func (s *Server) handleAppcastAlias(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		writeMethodNotAllowed(writer, http.MethodGet)
		return
	}

	segment := strings.TrimPrefix(request.URL.Path, "/appcast/")
	if !strings.HasSuffix(segment, ".xml") || strings.Contains(strings.TrimSuffix(segment, ".xml"), "/") {
		http.NotFound(writer, request)
		return
	}
	channel := strings.TrimSuffix(segment, ".xml")
	if channel != "" && request.URL.Query().Get("channel") == "" {
		query := request.URL.Query()
		query.Set("channel", channel)
		request.URL.RawQuery = query.Encode()
	}
	s.handleAppcast(writer, request)
}

func (s *Server) handleAppcast(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		writeMethodNotAllowed(writer, http.MethodGet)
		return
	}

	filter := filterFromQuery(request.URL.Query())
	filter.Platform = "macos"
	items := s.store.List(filter)
	if len(items) > 20 {
		items = items[:20]
	}

	payload, err := marshalAppcast(filter.Channel, items)
	if err != nil {
		s.logger.Error("Failed to generate appcast", "error", err)
		writeError(writer, http.StatusInternalServerError, "internal_error", "could not generate appcast")
		return
	}
	writeCacheable(writer, request, http.StatusOK, "application/rss+xml; charset=utf-8", payload)
}

func (s *Server) handleOMPManifest(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		writeMethodNotAllowed(writer, http.MethodGet)
		return
	}
	if s.ompManifestFile == "" {
		http.NotFound(writer, request)
		return
	}
	payload, err := os.ReadFile(s.ompManifestFile)
	if errors.Is(err, os.ErrNotExist) {
		http.NotFound(writer, request)
		return
	}
	if err != nil {
		s.logger.Error("Could not read OMP update manifest", "path", s.ompManifestFile, "error", err)
		writeError(writer, http.StatusInternalServerError, "manifest_read_failed", "could not read the OMP update manifest")
		return
	}
	if len(payload) == 0 || len(payload) > maxOMPManifest || !validOMPManifest(payload) {
		writeError(writer, http.StatusInternalServerError, "invalid_manifest", "the OMP update manifest is invalid")
		return
	}
	writeCacheable(writer, request, http.StatusOK, "application/json; charset=utf-8", payload)
}

func validOMPManifest(payload []byte) bool {
	var manifest struct {
		Version   string `json:"version"`
		Artifacts map[string]struct {
			URL    string `json:"url"`
			SHA256 string `json:"sha256"`
		} `json:"artifacts"`
	}
	if err := json.Unmarshal(payload, &manifest); err != nil ||
		strings.TrimSpace(manifest.Version) == "" || len(manifest.Artifacts) == 0 {
		return false
	}
	for _, artifact := range manifest.Artifacts {
		parsed, err := url.Parse(strings.TrimSpace(artifact.URL))
		if err != nil || parsed.Scheme != "https" || parsed.Host == "" ||
			!ompSHA256Pattern.MatchString(strings.TrimSpace(artifact.SHA256)) {
			return false
		}
	}
	return true
}

func (s *Server) handleAdminReleases(writer http.ResponseWriter, request *http.Request) {
	if !s.authorizeAdmin(writer, request) {
		return
	}
	if request.Method != http.MethodPost {
		writeMethodNotAllowed(writer, http.MethodPost)
		return
	}

	request.Body = http.MaxBytesReader(writer, request.Body, maxRequestBody)
	decoder := json.NewDecoder(request.Body)
	decoder.DisallowUnknownFields()

	var item release.Release
	if err := decoder.Decode(&item); err != nil {
		writeError(writer, http.StatusBadRequest, "invalid_request", "request body must contain one valid release")
		return
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		writeError(writer, http.StatusBadRequest, "invalid_request", "request body must contain exactly one release")
		return
	}
	item.Normalize()
	if err := item.Validate(); err != nil {
		writeError(writer, http.StatusUnprocessableEntity, "invalid_release", err.Error())
		return
	}
	if err := s.store.Upsert(item); err != nil {
		s.logger.Error("Failed to save release", "release_id", item.ID, "error", err)
		writeError(writer, http.StatusInternalServerError, "storage_error", "could not save release")
		return
	}

	writer.Header().Set("Location", adminPath+"/"+url.PathEscape(item.ID))
	writeJSON(writer, http.StatusCreated, item)
}

func (s *Server) handleAdminRelease(writer http.ResponseWriter, request *http.Request) {
	if !s.authorizeAdmin(writer, request) {
		return
	}
	if request.Method != http.MethodDelete {
		writeMethodNotAllowed(writer, http.MethodDelete)
		return
	}

	rawID := strings.TrimPrefix(request.URL.Path, adminPath+"/")
	id, err := url.PathUnescape(rawID)
	if err != nil || id == "" || strings.Contains(id, "/") {
		writeError(writer, http.StatusBadRequest, "invalid_request", "release id is invalid")
		return
	}
	if err := s.store.Delete(id); err != nil {
		if errors.Is(err, release.ErrNotFound) {
			writeError(writer, http.StatusNotFound, "release_not_found", "release was not found")
			return
		}
		s.logger.Error("Failed to delete release", "release_id", id, "error", err)
		writeError(writer, http.StatusInternalServerError, "storage_error", "could not delete release")
		return
	}
	writer.WriteHeader(http.StatusNoContent)
}

func (s *Server) authorizeAdmin(writer http.ResponseWriter, request *http.Request) bool {
	writer.Header().Set("Cache-Control", "no-store")
	if s.adminToken == "" {
		writeError(writer, http.StatusServiceUnavailable, "admin_disabled", "admin API is disabled")
		return false
	}
	const prefix = "Bearer "
	authorization := request.Header.Get("Authorization")
	if !strings.HasPrefix(authorization, prefix) {
		writer.Header().Set("WWW-Authenticate", "Bearer")
		writeError(writer, http.StatusUnauthorized, "unauthorized", "a valid bearer token is required")
		return false
	}
	provided := strings.TrimPrefix(authorization, prefix)
	if len(provided) != len(s.adminToken) ||
		subtle.ConstantTimeCompare([]byte(provided), []byte(s.adminToken)) != 1 {
		writer.Header().Set("WWW-Authenticate", "Bearer")
		writeError(writer, http.StatusUnauthorized, "unauthorized", "a valid bearer token is required")
		return false
	}
	return true
}

func (s *Server) withCORS(next http.Handler) http.Handler {
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		origin := request.Header.Get("Origin")
		if origin != "" {
			if _, allowed := s.allowedOrigins[origin]; allowed {
				writer.Header().Set("Access-Control-Allow-Origin", origin)
				writer.Header().Set("Vary", "Origin")
				writer.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
				writer.Header().Set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
			}
		}
		if request.Method == http.MethodOptions {
			writer.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(writer, request)
	})
}

func (s *Server) withAccessLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		startedAt := time.Now()
		recorder := &statusRecorder{ResponseWriter: writer, status: http.StatusOK}
		next.ServeHTTP(recorder, request)
		s.logger.Info(
			"HTTP request completed",
			"method", request.Method,
			"path", request.URL.Path,
			"status", recorder.status,
			"duration_ms", time.Since(startedAt).Milliseconds(),
		)
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(status int) {
	r.status = status
	r.ResponseWriter.WriteHeader(status)
}

type checkResponse struct {
	UpdateAvailable bool             `json:"update_available"`
	Latest          *release.Release `json:"latest,omitempty"`
	CheckedAt       time.Time        `json:"checked_at"`
}

type errorResponse struct {
	Error struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

type appcastRSS struct {
	XMLName xml.Name       `xml:"rss"`
	Version string         `xml:"version,attr"`
	Sparkle string         `xml:"xmlns:sparkle,attr"`
	Channel appcastChannel `xml:"channel"`
}

type appcastChannel struct {
	Title       string        `xml:"title"`
	Link        string        `xml:"link"`
	Description string        `xml:"description"`
	Language    string        `xml:"language"`
	Items       []appcastItem `xml:"item"`
}

type appcastItem struct {
	Title                  string           `xml:"title"`
	PubDate                string           `xml:"pubDate"`
	Description            string           `xml:"description,omitempty"`
	ReleaseNotesLink       string           `xml:"sparkle:releaseNotesLink,omitempty"`
	MinimumSystemVersion   string           `xml:"sparkle:minimumSystemVersion,omitempty"`
	CriticalUpdate         *struct{}        `xml:"sparkle:criticalUpdate,omitempty"`
	FullReleaseDescription string           `xml:"sparkle:fullReleaseNotesLink,omitempty"`
	Enclosure              appcastEnclosure `xml:"enclosure"`
}

type appcastEnclosure struct {
	URL                string `xml:"url,attr"`
	Length             int64  `xml:"length,attr"`
	Type               string `xml:"type,attr"`
	Version            int64  `xml:"sparkle:version,attr"`
	ShortVersionString string `xml:"sparkle:shortVersionString,attr"`
	EdSignature        string `xml:"sparkle:edSignature,attr"`
}

func marshalAppcast(channel string, releases []release.Release) ([]byte, error) {
	items := make([]appcastItem, 0, len(releases))
	for _, item := range releases {
		appcast := appcastItem{
			Title:                "FileNest " + item.Version,
			PubDate:              item.PublishedAt.Format(time.RFC1123Z),
			Description:          item.ReleaseNotes,
			ReleaseNotesLink:     item.ReleaseNotesURL,
			MinimumSystemVersion: item.MinimumOSVersion,
			Enclosure: appcastEnclosure{
				URL:                item.DownloadURL,
				Length:             item.FileSize,
				Type:               "application/octet-stream",
				Version:            item.Build,
				ShortVersionString: item.Version,
				EdSignature:        item.SparkleEdSignature,
			},
		}
		if item.Critical {
			appcast.CriticalUpdate = &struct{}{}
		}
		items = append(items, appcast)
	}

	document := appcastRSS{
		Version: "2.0",
		Sparkle: "http://www.andymatuschak.org/xml-namespaces/sparkle",
		Channel: appcastChannel{
			Title:       fmt.Sprintf("FileNest %s Updates", channel),
			Link:        "https://filenestapp.com",
			Description: fmt.Sprintf("Signed FileNest %s update feed", channel),
			Language:    "en",
			Items:       items,
		},
	}

	payload, err := xml.MarshalIndent(document, "", "  ")
	if err != nil {
		return nil, err
	}
	return append([]byte(xml.Header), payload...), nil
}

func filterFromQuery(query url.Values) release.Filter {
	filter := release.Filter{
		Platform:     query.Get("platform"),
		Architecture: query.Get("arch"),
		Channel:      query.Get("channel"),
	}
	filter.Normalize()
	return filter
}

func optionalInt64(value string) (int64, error) {
	if strings.TrimSpace(value) == "" {
		return 0, nil
	}
	return strconv.ParseInt(value, 10, 64)
}

func writeCacheableJSON(writer http.ResponseWriter, request *http.Request, status int, value any) {
	payload, err := json.Marshal(value)
	if err != nil {
		writeError(writer, http.StatusInternalServerError, "internal_error", "could not encode response")
		return
	}
	writeCacheable(writer, request, status, "application/json; charset=utf-8", payload)
}

func writeCacheable(
	writer http.ResponseWriter,
	request *http.Request,
	status int,
	contentType string,
	payload []byte,
) {
	digest := sha256.Sum256(payload)
	etag := `"` + hex.EncodeToString(digest[:]) + `"`
	writer.Header().Set("Cache-Control", "public, max-age=300")
	writer.Header().Set("Content-Type", contentType)
	writer.Header().Set("ETag", etag)
	if request.Header.Get("If-None-Match") == etag {
		writer.WriteHeader(http.StatusNotModified)
		return
	}
	writer.WriteHeader(status)
	_, _ = writer.Write(payload)
}

func writeJSON(writer http.ResponseWriter, status int, value any) {
	writer.Header().Set("Content-Type", "application/json; charset=utf-8")
	writer.WriteHeader(status)
	_ = json.NewEncoder(writer).Encode(value)
}

func writeError(writer http.ResponseWriter, status int, code, message string) {
	var response errorResponse
	response.Error.Code = code
	response.Error.Message = message
	writeJSON(writer, status, response)
}

func writeMethodNotAllowed(writer http.ResponseWriter, allowedMethods ...string) {
	writer.Header().Set("Allow", strings.Join(allowedMethods, ", "))
	writeError(writer, http.StatusMethodNotAllowed, "method_not_allowed", "HTTP method is not allowed")
}
