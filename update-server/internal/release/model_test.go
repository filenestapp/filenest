package release

import (
	"testing"
	"time"
)

func TestIsNewerPrefersBuildNumber(t *testing.T) {
	candidate := Release{Version: "0.2.0", Build: 3}
	if !IsNewer(candidate, "0.3.0", 2) {
		t.Fatal("a greater build number should be considered newer")
	}
	if IsNewer(candidate, "0.1.0", 4) {
		t.Fatal("a lower build number should not be considered newer")
	}
}

func TestCompareVersions(t *testing.T) {
	tests := []struct {
		name string
		a    string
		b    string
		want int
	}{
		{name: "greater patch", a: "1.2.10", b: "1.2.9", want: 1},
		{name: "equal missing component", a: "1.2", b: "1.2.0", want: 0},
		{name: "version prefix", a: "v2.0.0", b: "1.9.9", want: 1},
		{name: "lower prerelease number", a: "2.0-beta.1", b: "2.0-beta.2", want: -1},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := CompareVersions(test.a, test.b); got != test.want {
				t.Fatalf("CompareVersions(%q, %q) = %d, want %d", test.a, test.b, got, test.want)
			}
		})
	}
}

func TestReleaseValidationRequiresSignedMacOSArtifact(t *testing.T) {
	item := validRelease()
	item.SparkleEdSignature = ""

	if err := item.Validate(); err == nil {
		t.Fatal("expected unsigned macOS release to be rejected")
	}
}

func TestFileStorePersistsAndReloads(t *testing.T) {
	path := t.TempDir() + "/releases.json"
	store, err := NewFileStore(path)
	if err != nil {
		t.Fatalf("NewFileStore() error = %v", err)
	}

	item := validRelease()
	if err := store.Upsert(item); err != nil {
		t.Fatalf("Upsert() error = %v", err)
	}

	reloaded, err := NewFileStore(path)
	if err != nil {
		t.Fatalf("reload NewFileStore() error = %v", err)
	}
	got, found := reloaded.Latest(Filter{
		Platform:     "macos",
		Architecture: "arm64",
		Channel:      "stable",
	})
	if !found {
		t.Fatal("expected persisted release")
	}
	if got.ID != item.ID {
		t.Fatalf("latest release ID = %q, want %q", got.ID, item.ID)
	}
}

func TestStoreFiltersChannelsAndArchitectures(t *testing.T) {
	path := t.TempDir() + "/releases.json"
	store, err := NewFileStore(path)
	if err != nil {
		t.Fatalf("NewFileStore() error = %v", err)
	}

	stable := validRelease()
	stable.ID = "stable-arm64"
	stable.Build = 10
	if err := store.Upsert(stable); err != nil {
		t.Fatalf("Upsert(stable) error = %v", err)
	}

	beta := validRelease()
	beta.ID = "beta-arm64"
	beta.Channel = "beta"
	beta.Build = 20
	if err := store.Upsert(beta); err != nil {
		t.Fatalf("Upsert(beta) error = %v", err)
	}

	intel := validRelease()
	intel.ID = "stable-intel"
	intel.Architecture = "x86_64"
	intel.Build = 30
	if err := store.Upsert(intel); err != nil {
		t.Fatalf("Upsert(intel) error = %v", err)
	}

	got, found := store.Latest(Filter{
		Platform:     "macos",
		Architecture: "arm64",
		Channel:      "stable",
	})
	if !found || got.ID != stable.ID {
		t.Fatalf("latest stable arm64 release = %#v, want %q", got, stable.ID)
	}
}

func TestUniversalFilterDoesNotSelectArchitectureSpecificRelease(t *testing.T) {
	universalFilter := Filter{
		Platform:     "macos",
		Architecture: "universal",
		Channel:      "stable",
	}
	universalFilter.Normalize()

	armRelease := validRelease()
	if Matches(armRelease, universalFilter) {
		t.Fatal("a universal request must not select an arm64-only release")
	}

	universalRelease := validRelease()
	universalRelease.Architecture = "universal"
	if !Matches(universalRelease, universalFilter) {
		t.Fatal("a universal request should select a universal release")
	}
}

func validRelease() Release {
	return Release{
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
