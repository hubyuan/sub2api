package migrations

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestMigration220PreservesRecoverableVideoPricingContract(t *testing.T) {
	sqlBytes, err := FS.ReadFile("220_clear_non_grok_video_generation_config.sql")
	require.NoError(t, err)
	rawChecksum := sha256.Sum256(sqlBytes)
	runnerChecksum := sha256.Sum256([]byte(strings.TrimSpace(string(sqlBytes))))
	require.Equal(t, "9335aa80e464e774bbde71ce0ca847186a3555dae5bd6c9201d01bd0fd8791f9", hex.EncodeToString(rawChecksum[:]))
	require.Equal(t, "4595baeb0dab0fd05be15da4e8f0dcf9f8e7d0ca36d60d00d223fca9bef03625", hex.EncodeToString(runnerChecksum[:]))
	sql := strings.ToLower(string(sqlBytes))

	require.Contains(t, sql, "create table if not exists groups_video_price_backup_220 as")
	require.Contains(t, sql, "platform is distinct from 'grok'")
	require.Contains(t, sql, "platform is distinct from 'composite'")
	for _, column := range []string{
		"video_price_480p",
		"video_price_720p",
		"video_price_1080p",
		"video_model_prices",
	} {
		require.Contains(t, sql, column)
	}
	require.Contains(t, sql, "update groups")
	require.Contains(t, sql, "set video_price_480p = null")
	require.Contains(t, sql, "update groups g set video_price_480p = b.video_price_480p")
	require.Contains(t, sql, "video_price_720p = b.video_price_720p")
	require.Contains(t, sql, "video_price_1080p = b.video_price_1080p")
	require.Contains(t, sql, "video_model_prices = b.video_model_prices")
}
