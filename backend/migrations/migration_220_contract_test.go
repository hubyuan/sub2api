package migrations

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

const (
	migration220RawSHA256    = "9335aa80e464e774bbde71ce0ca847186a3555dae5bd6c9201d01bd0fd8791f9"
	migration220RunnerSHA256 = "4595baeb0dab0fd05be15da4e8f0dcf9f8e7d0ca36d60d00d223fca9bef03625"
	migration220Upstream     = "2ac784c51a5d0925b324efef2ba6b3446c364781"
)

func sha256Hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func executableSQL(data []byte) string {
	lineComment := regexp.MustCompile(`(?m)--.*$`)
	withoutComments := lineComment.ReplaceAllString(string(data), "")
	metadataComment := regexp.MustCompile(`(?is)COMMENT\s+ON\s+TABLE\s+groups_video_price_backup_220\s+IS\s+'[^']*';`)
	withoutMetadataComment := metadataComment.ReplaceAllString(withoutComments, "")
	return strings.Join(strings.Fields(withoutMetadataComment), " ")
}

func TestMigration220ProductionCompatibility(t *testing.T) {
	path := filepath.Join("220_clear_non_grok_video_generation_config.sql")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := sha256Hex(data); got != migration220RawSHA256 {
		t.Fatalf("raw checksum = %s, want %s", got, migration220RawSHA256)
	}
	if got := sha256Hex([]byte(strings.TrimSpace(string(data)))); got != migration220RunnerSHA256 {
		t.Fatalf("runner checksum = %s, want %s", got, migration220RunnerSHA256)
	}

	repoRoot := filepath.Join("..", "..")
	cmd := exec.Command("git", "show", migration220Upstream+":"+filepath.ToSlash(filepath.Join("backend", "migrations", path)))
	cmd.Dir = repoRoot
	upstream, err := cmd.Output()
	if err != nil {
		t.Fatalf("read exact upstream migration: %v", err)
	}
	if got, want := executableSQL(data), executableSQL(upstream); got != want {
		t.Fatal("migration 220 executable SQL differs from exact upstream v0.1.185")
	}
}
