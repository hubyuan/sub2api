//go:build unit

package repository

import (
	"database/sql"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/stretchr/testify/require"
)

func TestPrepareUsageLogInsertFirstSSEEventWiring(t *testing.T) {
	firstSSEEventMs := 17
	prepared := prepareUsageLogInsert(&service.UsageLog{
		UserID:          1,
		APIKeyID:        2,
		AccountID:       3,
		RequestID:       "req-first-sse",
		Model:           "gpt-5.4",
		FirstSSEEventMs: &firstSSEEventMs,
	})

	require.Len(t, prepared.args, len(usageLogInsertArgTypes))
	require.Equal(t, "integer", usageLogInsertArgTypes[35])
	require.Equal(t, sql.NullInt64{Int64: 17, Valid: true}, prepared.args[35])
	require.Contains(t, usageLogSelectColumns, "first_token_ms, first_sse_event_ms, user_agent")
}
