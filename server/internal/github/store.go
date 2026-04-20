package github

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
)

type Store struct {
	path string
	mu   sync.Mutex
}

type storeFile struct {
	Records map[string]AuthRecord `json:"records"`
}

func NewStore(path string) *Store {
	return &Store{path: path}
}

func (s *Store) Load(host string) (*AuthRecord, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	data, err := s.readAll()
	if err != nil {
		return nil, err
	}
	record, ok := data.Records[NormalizeHost(host)]
	if !ok {
		return nil, nil
	}
	record.GitHubHost = NormalizeHost(record.GitHubHost)
	return &record, nil
}

func (s *Store) Save(record AuthRecord) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	data, err := s.readAllRecovering()
	if err != nil {
		return err
	}
	if data.Records == nil {
		data.Records = map[string]AuthRecord{}
	}
	record.GitHubHost = NormalizeHost(record.GitHubHost)
	data.Records[record.GitHubHost] = record
	return s.writeAll(data)
}

func (s *Store) Delete(host string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	data, err := s.readAllRecovering()
	if err != nil {
		return err
	}
	delete(data.Records, NormalizeHost(host))
	if len(data.Records) == 0 {
		if err := os.Remove(s.path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("remove github auth store: %w", err)
		}
		return nil
	}
	return s.writeAll(data)
}

func (s *Store) readAll() (storeFile, error) {
	var data storeFile
	body, err := os.ReadFile(s.path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return storeFile{Records: map[string]AuthRecord{}}, nil
		}
		return data, fmt.Errorf("read github auth store: %w", err)
	}
	if err := json.Unmarshal(body, &data); err != nil {
		return storeFile{}, fmt.Errorf("decode github auth store: %w", err)
	}
	if data.Records == nil {
		data.Records = map[string]AuthRecord{}
	}
	return data, nil
}

func (s *Store) readAllRecovering() (storeFile, error) {
	data, err := s.readAll()
	if err == nil {
		return data, nil
	}
	var syntaxErr *json.SyntaxError
	var typeErr *json.UnmarshalTypeError
	if errors.As(err, &syntaxErr) || errors.As(err, &typeErr) {
		return storeFile{Records: map[string]AuthRecord{}}, nil
	}
	return storeFile{}, err
}

func (s *Store) writeAll(data storeFile) error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0755); err != nil {
		return fmt.Errorf("create github auth store dir: %w", err)
	}
	payload, err := json.MarshalIndent(data, "", "  ")
	if err != nil {
		return fmt.Errorf("encode github auth store: %w", err)
	}
	tmp, err := os.CreateTemp(filepath.Dir(s.path), "github-auth-*.tmp")
	if err != nil {
		return fmt.Errorf("create github auth temp file: %w", err)
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err := tmp.Write(payload); err != nil {
		tmp.Close()
		return fmt.Errorf("write github auth temp file: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close github auth temp file: %w", err)
	}
	if err := os.Rename(tmpName, s.path); err != nil {
		return fmt.Errorf("replace github auth store: %w", err)
	}
	return nil
}
