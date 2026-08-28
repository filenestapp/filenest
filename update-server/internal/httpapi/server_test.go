package httpapi

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"filenest/update-server/internal/release"
)

func TestCheckReturnsAvailableUpdate(t *testing.T) {
	api, _ := newTestServer(t)
	request := httptest.NewRequest(
		http.MethodGet,
		"/v1/updates/check?platform=macos&arch=arm64&channel=stable&version=0.2.0&build=2",
		nil,
	)
	response := httptest.NewRecorder()

	api.Handler().ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d; body = %s", response.Code, http.StatusOK, response.Body.String())
	}
	var body checkResponse
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if !body.UpdateAvailable {
		t.Fatal("expected update_available to be true")
	}
	if body.Latest == nil || body.Latest.Version != "0.3.0" {
		t.Fatalf("latest = %#v, want version 0.3.0", body.Latest)
	}
}

func TestCheckRejectsMissingCurrentVersion(t *testing.T) {
	api, _ := newTestServer(t)
	request := httptest.NewRequest(http.MethodGet, "/v1/updates/check", nil)
	response := httptest.NewRecorder()

	api.Handler().ServeHTTP(response, request)

	if response.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusBadRequest)
	}
}

func TestAppcastContainsSparkleMetadata(t *testing.T) {
	api, _ := newTestServer(t)
	request := httptest.NewRequest(http.MethodGet, "/appcast/stable.xml?arch=arm64", nil)
	response := httptest.NewRecorder()

	api.Handler().ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d; body = %s", response.Code, http.StatusOK, response.Body.String())
	}
	body := response.Body.String()
	expectedFragments := []string{
		`xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"`,
		`sparkle:version="3"`,
		`sparkle:shortVersionString="0.3.0"`,
		`sparkle:edSignature="example-signature"`,
		`<sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>`,
	}
	for _, fragment := range expectedFragments {
		if !strings.Contains(body, fragment) {
			t.Fatalf("appcast does not contain %q:\n%s", fragment, body)
		}
	}
}

func TestAppcastSupportsConditionalRequest(t *testing.T) {
	api, _ := newTestServer(t)
	firstRequest := httptest.NewRequest(http.MethodGet, "/appcast.xml", nil)
	firstResponse := httptest.NewRecorder()
	api.Handler().ServeHTTP(firstResponse, firstRequest)

	etag := firstResponse.Header().Get("ETag")
	if etag == "" {
		t.Fatal("expected ETag header")
	}

	secondRequest := httptest.NewRequest(http.MethodGet, "/appcast.xml", nil)
	secondRequest.Header.Set("If-None-Match", etag)
	secondResponse := httptest.NewRecorder()
	api.Handler().ServeHTTP(secondResponse, secondRequest)

	if secondResponse.Code != http.StatusNotModified {
		t.Fatalf("status = %d, want %d", secondResponse.Code, http.StatusNotModified)
	}
}

func TestOMPManifestServesConfiguredManifest(t *testing.T) {
	api, _ := newTestServer(t)
	manifestPath := filepath.Join(t.TempDir(), "omp-agent-manifest.json")
	payload := `{"version":"17.3.0","artifacts":{"arm64":{"url":"https://downloads.example.com/omp-arm64","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}`
	if err := os.WriteFile(manifestPath, []byte(payload), 0o600); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	api.ompManifestFile = manifestPath

	request := httptest.NewRequest(http.MethodGet, "/omp-agent/stable.json", nil)
	response := httptest.NewRecorder()
	api.Handler().ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d; body = %s", response.Code, http.StatusOK, response.Body.String())
	}
	if response.Header().Get("Content-Type") != "application/json; charset=utf-8" {
		t.Fatalf("content type = %q", response.Header().Get("Content-Type"))
	}
	if response.Body.String() != payload {
		t.Fatalf("body = %s, want %s", response.Body.String(), payload)
	}
}

func TestOMPManifestRejectsInvalidConfiguredManifest(t *testing.T) {
	api, _ := newTestServer(t)
	manifestPath := filepath.Join(t.TempDir(), "omp-agent-manifest.json")
	if err := os.WriteFile(manifestPath, []byte(`{"version":"17.3.0","artifacts":{}}`), 0o600); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	api.ompManifestFile = manifestPath

	request := httptest.NewRequest(http.MethodGet, "/omp-agent/stable.json", nil)
	response := httptest.NewRecorder()
	api.Handler().ServeHTTP(response, request)

	if response.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusInternalServerError)
	}
}

func TestAdminReleaseRequiresBearerToken(t *testing.T) {
	api, _ := newTestServer(t)
	request := httptest.NewRequest(http.MethodPost, adminPath, strings.NewReader(`{}`))
	response := httptest.NewRecorder()

	api.Handler().ServeHTTP(response, request)

	if response.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusUnauthorized)
	}
}

func TestAdminReleaseCreatesAndDeletesRelease(t *testing.T) {
	api, store := newTestServer(t)
	item := testRelease()
	item.ID = "macos-arm64-stable-0.4.0-4"
	item.Version = "0.4.0"
	item.Build = 4
	payload, err := json.Marshal(item)
	if err != nil {
		t.Fatalf("marshal release: %v", err)
	}

	createRequest := httptest.NewRequest(http.MethodPost, adminPath, strings.NewReader(string(payload)))
	createRequest.Header.Set("Authorization", "Bearer test-admin-token")
	createRequest.Header.Set("Content-Type", "application/json")
	createResponse := httptest.NewRecorder()
	api.Handler().ServeHTTP(createResponse, createRequest)

	if createResponse.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want %d; body = %s", createResponse.Code, http.StatusCreated, createResponse.Body.String())
	}
	if _, found := store.Latest(release.Filter{
		Platform:     "macos",
		Architecture: "arm64",
		Channel:      "stable",
	}); !found {
		t.Fatal("expected created release")
	}

	deleteRequest := httptest.NewRequest(http.MethodDelete, adminPath+"/"+item.ID, nil)
	deleteRequest.Header.Set("Authorization", "Bearer test-admin-token")
	deleteResponse := httptest.NewRecorder()
	api.Handler().ServeHTTP(deleteResponse, deleteRequest)

	if deleteResponse.Code != http.StatusNoContent {
		t.Fatalf("delete status = %d, want %d; body = %s", deleteResponse.Code, http.StatusNoContent, deleteResponse.Body.String())
	}
}

func TestAdminRejectsUnsignedMacOSRelease(t *testing.T) {
	api, _ := newTestServer(t)
	item := testRelease()
	item.SparkleEdSignature = ""
	payload, err := json.Marshal(item)
	if err != nil {
		t.Fatalf("marshal release: %v", err)
	}

	request := httptest.NewRequest(http.MethodPost, adminPath, strings.NewReader(string(payload)))
	request.Header.Set("Authorization", "Bearer test-admin-token")
	response := httptest.NewRecorder()
	api.Handler().ServeHTTP(response, request)

	if response.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want %d; body = %s", response.Code, http.StatusUnprocessableEntity, response.Body.String())
	}
}

func newTestServer(t *testing.T) (*Server, *release.FileStore) {
	t.Helper()
	store, err := release.NewFileStore(t.TempDir() + "/releases.json")
	if err != nil {
		t.Fatalf("NewFileStore() error = %v", err)
	}
	item := testRelease()
	if err := store.Upsert(item); err != nil {
		t.Fatalf("Upsert() error = %v", err)
	}

	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	api := New(
		store,
		"test-admin-token",
		nil,
		WithLogger(logger),
		WithClock(func() time.Time {
			return time.Date(2026, 7, 29, 12, 0, 0, 0, time.UTC)
		}),
	)
	return api, store
}

func testRelease() release.Release {
	return release.Release{
		ID:                 "macos-arm64-stable-0.3.0-3",
		Version:            "0.3.0",
		Build:              3,
		Platform:           "macos",
		Architecture:       "arm64",
		Channel:            "stable",
		PublishedAt:        time.Date(2026, 7, 29, 10, 0, 0, 0, time.UTC),
		DownloadURL:        "https://updates.example.com/FileNest-0.3.0.zip",
		FileSize:           123456,
		SHA256:             "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		SparkleEdSignature: "example-signature",
		MinimumOSVersion:   "13.0",
		ReleaseNotesURL:    "https://updates.example.com/releases/0.3.0",
		ReleaseNotes:       "Performance and reliability improvements.",
	}
}
