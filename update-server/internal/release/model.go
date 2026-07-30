package release

import (
	"fmt"
	"net"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var (
	channelPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]*$`)
	sha256Pattern  = regexp.MustCompile(`^[a-fA-F0-9]{64}$`)
)

type Release struct {
	ID                 string    `json:"id"`
	Version            string    `json:"version"`
	Build              int64     `json:"build"`
	Platform           string    `json:"platform"`
	Architecture       string    `json:"architecture"`
	Channel            string    `json:"channel"`
	PublishedAt        time.Time `json:"published_at"`
	DownloadURL        string    `json:"download_url"`
	FileSize           int64     `json:"file_size"`
	SHA256             string    `json:"sha256"`
	SparkleEdSignature string    `json:"sparkle_ed_signature,omitempty"`
	MinimumOSVersion   string    `json:"minimum_os_version,omitempty"`
	ReleaseNotesURL    string    `json:"release_notes_url,omitempty"`
	ReleaseNotes       string    `json:"release_notes,omitempty"`
	Critical           bool      `json:"critical"`
}

type Filter struct {
	Platform     string
	Architecture string
	Channel      string
}

func (r *Release) Normalize() {
	r.ID = strings.TrimSpace(r.ID)
	r.Version = strings.TrimPrefix(strings.TrimSpace(r.Version), "v")
	r.Platform = strings.ToLower(strings.TrimSpace(r.Platform))
	r.Architecture = normalizeArchitecture(r.Architecture)
	r.Channel = strings.ToLower(strings.TrimSpace(r.Channel))
	r.DownloadURL = strings.TrimSpace(r.DownloadURL)
	r.SHA256 = strings.ToLower(strings.TrimSpace(r.SHA256))
	r.SparkleEdSignature = strings.TrimSpace(r.SparkleEdSignature)
	r.MinimumOSVersion = strings.TrimSpace(r.MinimumOSVersion)
	r.ReleaseNotesURL = strings.TrimSpace(r.ReleaseNotesURL)
	r.ReleaseNotes = strings.TrimSpace(r.ReleaseNotes)

	if r.Channel == "" {
		r.Channel = "stable"
	}
	if r.Architecture == "" {
		r.Architecture = "universal"
	}
	if r.PublishedAt.IsZero() {
		r.PublishedAt = time.Now().UTC()
	} else {
		r.PublishedAt = r.PublishedAt.UTC()
	}
	if r.ID == "" && r.Platform != "" && r.Version != "" && r.Build > 0 {
		r.ID = fmt.Sprintf(
			"%s-%s-%s-%s-%d",
			r.Platform,
			r.Architecture,
			r.Channel,
			r.Version,
			r.Build,
		)
	}
}

func (r Release) Validate() error {
	if r.ID == "" {
		return fmt.Errorf("id is required")
	}
	if r.Version == "" {
		return fmt.Errorf("version is required")
	}
	if r.Build <= 0 {
		return fmt.Errorf("build must be greater than zero")
	}
	if r.Platform == "" {
		return fmt.Errorf("platform is required")
	}
	if !channelPattern.MatchString(r.Channel) {
		return fmt.Errorf("channel must contain only lowercase letters, numbers, dots, underscores, or hyphens")
	}
	switch r.Architecture {
	case "arm64", "x86_64", "universal", "any":
	default:
		return fmt.Errorf("architecture must be arm64, x86_64, universal, or any")
	}
	if err := validateHTTPSURL(r.DownloadURL, "download_url"); err != nil {
		return err
	}
	if r.FileSize <= 0 {
		return fmt.Errorf("file_size must be greater than zero")
	}
	if !sha256Pattern.MatchString(r.SHA256) {
		return fmt.Errorf("sha256 must be a 64-character hexadecimal digest")
	}
	if r.Platform == "macos" && r.SparkleEdSignature == "" {
		return fmt.Errorf("sparkle_ed_signature is required for macOS releases")
	}
	if r.ReleaseNotesURL != "" {
		if err := validateHTTPSURL(r.ReleaseNotesURL, "release_notes_url"); err != nil {
			return err
		}
	}
	return nil
}

func (f *Filter) Normalize() {
	f.Platform = strings.ToLower(strings.TrimSpace(f.Platform))
	f.Architecture = normalizeArchitecture(f.Architecture)
	f.Channel = strings.ToLower(strings.TrimSpace(f.Channel))
	if f.Platform == "" {
		f.Platform = "macos"
	}
	if f.Architecture == "" {
		f.Architecture = "universal"
	}
	if f.Channel == "" {
		f.Channel = "stable"
	}
}

func Matches(r Release, filter Filter) bool {
	if r.Platform != filter.Platform || r.Channel != filter.Channel {
		return false
	}
	if filter.Architecture == "any" {
		return true
	}
	if filter.Architecture == "universal" {
		return r.Architecture == "universal" || r.Architecture == "any"
	}
	return r.Architecture == filter.Architecture ||
		r.Architecture == "universal" ||
		r.Architecture == "any"
}

func IsNewer(candidate Release, currentVersion string, currentBuild int64) bool {
	if currentBuild > 0 && candidate.Build != currentBuild {
		return candidate.Build > currentBuild
	}
	return CompareVersions(candidate.Version, currentVersion) > 0
}

func Compare(a, b Release) int {
	if a.Build != b.Build {
		if a.Build > b.Build {
			return 1
		}
		return -1
	}
	if result := CompareVersions(a.Version, b.Version); result != 0 {
		return result
	}
	if a.PublishedAt.After(b.PublishedAt) {
		return 1
	}
	if a.PublishedAt.Before(b.PublishedAt) {
		return -1
	}
	return 0
}

func CompareVersions(a, b string) int {
	aParts := versionParts(a)
	bParts := versionParts(b)
	count := max(len(aParts), len(bParts))
	for index := 0; index < count; index++ {
		var aPart, bPart int64
		if index < len(aParts) {
			aPart = aParts[index]
		}
		if index < len(bParts) {
			bPart = bParts[index]
		}
		if aPart > bPart {
			return 1
		}
		if aPart < bPart {
			return -1
		}
	}
	return 0
}

func versionParts(version string) []int64 {
	version = strings.TrimPrefix(strings.TrimSpace(version), "v")
	fields := strings.FieldsFunc(version, func(r rune) bool {
		return r < '0' || r > '9'
	})
	parts := make([]int64, 0, len(fields))
	for _, field := range fields {
		value, err := strconv.ParseInt(field, 10, 64)
		if err != nil {
			value = 0
		}
		parts = append(parts, value)
	}
	return parts
}

func normalizeArchitecture(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "amd64", "x64":
		return "x86_64"
	case "aarch64":
		return "arm64"
	default:
		return strings.ToLower(strings.TrimSpace(value))
	}
}

func validateHTTPSURL(rawValue, fieldName string) error {
	parsed, err := url.Parse(rawValue)
	if err != nil || parsed.Host == "" {
		return fmt.Errorf("%s must be a valid absolute URL", fieldName)
	}
	if parsed.Scheme == "https" {
		return nil
	}
	host := parsed.Hostname()
	if parsed.Scheme == "http" && (host == "localhost" || net.ParseIP(host).IsLoopback()) {
		return nil
	}
	return fmt.Errorf("%s must use HTTPS", fieldName)
}
