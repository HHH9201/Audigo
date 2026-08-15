package main

import (
	"fmt"
	"os"
	"path/filepath"
)

// writeJSONAtomic writes a complete JSON document without exposing a partial file.
func writeJSONAtomic(filePath string, data []byte, perm os.FileMode) error {
	tempFile, err := os.CreateTemp(filepath.Dir(filePath), ".tmp-*")
	if err != nil {
		return err
	}
	tempPath := tempFile.Name()
	defer os.Remove(tempPath)

	if err := tempFile.Chmod(perm); err != nil {
		tempFile.Close()
		return err
	}
	if _, err := tempFile.Write(data); err != nil {
		tempFile.Close()
		return err
	}
	if err := tempFile.Sync(); err != nil {
		tempFile.Close()
		return err
	}
	if err := tempFile.Close(); err != nil {
		return err
	}
	if err := os.Rename(tempPath, filePath); err != nil {
		return fmt.Errorf("replace %s: %w", filePath, err)
	}
	return nil
}
