package release

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
)

var ErrNotFound = errors.New("release not found")

type Store interface {
	List(Filter) []Release
	Latest(Filter) (Release, bool)
	Upsert(Release) error
	Delete(string) error
}

type FileStore struct {
	mu       sync.RWMutex
	path     string
	releases []Release
}

type fileDocument struct {
	Releases []Release `json:"releases"`
}

func NewFileStore(path string) (*FileStore, error) {
	store := &FileStore{path: path}
	if err := store.load(); err != nil {
		return nil, err
	}
	return store, nil
}

func (s *FileStore) List(filter Filter) []Release {
	filter.Normalize()

	s.mu.RLock()
	defer s.mu.RUnlock()

	result := make([]Release, 0, len(s.releases))
	for _, item := range s.releases {
		if Matches(item, filter) {
			result = append(result, item)
		}
	}
	sort.SliceStable(result, func(i, j int) bool {
		comparison := Compare(result[i], result[j])
		if comparison != 0 {
			return comparison > 0
		}
		return architecturePriority(result[i].Architecture, filter.Architecture) >
			architecturePriority(result[j].Architecture, filter.Architecture)
	})
	return result
}

func (s *FileStore) Latest(filter Filter) (Release, bool) {
	items := s.List(filter)
	if len(items) == 0 {
		return Release{}, false
	}
	return items[0], true
}

func (s *FileStore) Upsert(item Release) error {
	item.Normalize()
	if err := item.Validate(); err != nil {
		return err
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	next := append([]Release(nil), s.releases...)
	replaced := false
	for index := range next {
		if next[index].ID == item.ID {
			next[index] = item
			replaced = true
			break
		}
	}
	if !replaced {
		next = append(next, item)
	}
	if err := s.persistLocked(next); err != nil {
		return err
	}
	s.releases = next
	return nil
}

func (s *FileStore) Delete(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	next := make([]Release, 0, len(s.releases))
	found := false
	for _, item := range s.releases {
		if item.ID == id {
			found = true
			continue
		}
		next = append(next, item)
	}
	if !found {
		return ErrNotFound
	}
	if err := s.persistLocked(next); err != nil {
		return err
	}
	s.releases = next
	return nil
}

func (s *FileStore) load() error {
	data, err := os.ReadFile(s.path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("read release data: %w", err)
	}

	var document fileDocument
	if err := json.Unmarshal(data, &document); err != nil {
		return fmt.Errorf("decode release data: %w", err)
	}
	for index := range document.Releases {
		document.Releases[index].Normalize()
		if err := document.Releases[index].Validate(); err != nil {
			return fmt.Errorf("validate release %q: %w", document.Releases[index].ID, err)
		}
	}
	s.releases = document.Releases
	return nil
}

func (s *FileStore) persistLocked(releases []Release) error {
	directory := filepath.Dir(s.path)
	if err := os.MkdirAll(directory, 0o750); err != nil {
		return fmt.Errorf("create release data directory: %w", err)
	}

	data, err := json.MarshalIndent(fileDocument{Releases: releases}, "", "  ")
	if err != nil {
		return fmt.Errorf("encode release data: %w", err)
	}
	data = append(data, '\n')

	file, err := os.CreateTemp(directory, ".releases-*.tmp")
	if err != nil {
		return fmt.Errorf("create temporary release data: %w", err)
	}
	tempPath := file.Name()
	defer os.Remove(tempPath)

	if err := file.Chmod(0o640); err != nil {
		file.Close()
		return fmt.Errorf("set release data permissions: %w", err)
	}
	if _, err := file.Write(data); err != nil {
		file.Close()
		return fmt.Errorf("write release data: %w", err)
	}
	if err := file.Sync(); err != nil {
		file.Close()
		return fmt.Errorf("sync release data: %w", err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("close release data: %w", err)
	}
	if err := os.Rename(tempPath, s.path); err != nil {
		return fmt.Errorf("replace release data: %w", err)
	}
	return nil
}

func architecturePriority(candidate, requested string) int {
	if candidate == requested {
		return 3
	}
	if candidate == "universal" {
		return 2
	}
	if candidate == "any" {
		return 1
	}
	return 0
}
