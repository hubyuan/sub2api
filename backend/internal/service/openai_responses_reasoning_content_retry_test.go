package service

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
	"github.com/tidwall/gjson"
)

func TestClassifyOpenAIReasoningContentArrayError(t *testing.T) {
	tests := []struct {
		name       string
		statusCode int
		body       string
		wantIndex  int
		matched    bool
	}{
		{
			name:       "index zero",
			statusCode: http.StatusBadRequest,
			body:       reasoningContentArrayErrorBody("input[0].content"),
			wantIndex:  0,
			matched:    true,
		},
		{
			name:       "two digit index and trimmed values",
			statusCode: http.StatusBadRequest,
			body:       `{"error":{"type":" invalid_request_error ","code":" array_above_max_length ","param":" input[12].content ","message":"ignored"}}`,
			wantIndex:  12,
			matched:    true,
		},
		{
			name:       "wrong status",
			statusCode: http.StatusUnprocessableEntity,
			body:       reasoningContentArrayErrorBody("input[0].content"),
		},
		{
			name:       "wrong type",
			statusCode: http.StatusBadRequest,
			body:       `{"error":{"type":"server_error","code":"array_above_max_length","param":"input[0].content"}}`,
		},
		{
			name:       "wrong code",
			statusCode: http.StatusBadRequest,
			body:       `{"error":{"type":"invalid_request_error","code":"array_too_long","param":"input[0].content"}}`,
		},
		{
			name:       "type case mismatch",
			statusCode: http.StatusBadRequest,
			body:       `{"error":{"type":"INVALID_REQUEST_ERROR","code":"array_above_max_length","param":"input[0].content"}}`,
		},
		{
			name:       "param suffix",
			statusCode: http.StatusBadRequest,
			body:       reasoningContentArrayErrorBody("input[0].content.extra"),
		},
		{
			name:       "negative index",
			statusCode: http.StatusBadRequest,
			body:       reasoningContentArrayErrorBody("input[-1].content"),
		},
		{
			name:       "non numeric index",
			statusCode: http.StatusBadRequest,
			body:       reasoningContentArrayErrorBody("input[one].content"),
		},
		{
			name:       "message only",
			statusCode: http.StatusBadRequest,
			body:       `{"error":{"type":"invalid_request_error","message":"array_above_max_length at input[0].content"}}`,
		},
		{
			name:       "missing param",
			statusCode: http.StatusBadRequest,
			body:       `{"error":{"type":"invalid_request_error","code":"array_above_max_length"}}`,
		},
		{
			name:       "non string code",
			statusCode: http.StatusBadRequest,
			body:       `{"error":{"type":"invalid_request_error","code":400,"param":"input[0].content"}}`,
		},
		{
			name:       "invalid json",
			statusCode: http.StatusBadRequest,
			body:       `{"error":`,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			signature, matched := classifyOpenAIReasoningContentArrayError(tt.statusCode, []byte(tt.body))
			require.Equal(t, tt.matched, matched)
			if matched {
				require.Equal(t, tt.wantIndex, signature.Index)
				require.Equal(t, strings.TrimSpace(gjson.Get(tt.body, "error.param").String()), signature.Param)
			}
		})
	}
}

func TestNormalizeOpenAIReasoningContentRetryBodyOnlyDeletesTargetContent(t *testing.T) {
	original := []byte(`{"model":"gpt-5.6-sol","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"keep"}]},{"type":"reasoning","content":[{"type":"reasoning_text","text":"raw one"},{"type":"reasoning_text","text":"raw two"}],"summary":[{"type":"summary_text","text":"keep summary"}],"encrypted_content":"keep-encrypted","custom":"keep-custom"},{"type":"reasoning","content":[{"type":"reasoning_text","text":"keep other reasoning"}],"summary":[]}]}`)
	originalCopy := append([]byte(nil), original...)

	retryBody, changed, err := normalizeOpenAIReasoningContentRetryBody(original, openAIReasoningContentArrayError{Index: 1, Param: "input[1].content"})

	require.NoError(t, err)
	require.True(t, changed)
	require.Equal(t, originalCopy, original, "normalization must not mutate the forwarded body")
	require.False(t, gjson.GetBytes(retryBody, "input.1.content").Exists())
	require.Equal(t, "keep summary", gjson.GetBytes(retryBody, "input.1.summary.0.text").String())
	require.Equal(t, "keep-encrypted", gjson.GetBytes(retryBody, "input.1.encrypted_content").String())
	require.Equal(t, "keep-custom", gjson.GetBytes(retryBody, "input.1.custom").String())
	require.Equal(t, "keep", gjson.GetBytes(retryBody, "input.0.content.0.text").String())
	require.Equal(t, "keep other reasoning", gjson.GetBytes(retryBody, "input.2.content.0.text").String())
}

func TestNormalizeOpenAIReasoningContentRetryBodyRejectsUnsafeShapes(t *testing.T) {
	tests := []struct {
		name  string
		body  string
		index int
	}{
		{name: "ordinary message", body: `{"input":[{"type":"message","content":[{"type":"reasoning_text","text":"do not delete"}]}]}`, index: 0},
		{name: "output text", body: `{"input":[{"type":"reasoning","content":[{"type":"output_text","text":"do not delete"}]}]}`, index: 0},
		{name: "input text", body: `{"input":[{"type":"reasoning","content":[{"type":"input_text","text":"do not delete"}]}]}`, index: 0},
		{name: "unknown content type", body: `{"input":[{"type":"reasoning","content":[{"type":"future_reasoning","text":"do not delete"}]}]}`, index: 0},
		{name: "mixed content types", body: `{"input":[{"type":"reasoning","content":[{"type":"reasoning_text","text":"one"},{"type":"output_text","text":"two"}]}]}`, index: 0},
		{name: "wrong index", body: `{"input":[{"type":"reasoning","content":[{"type":"reasoning_text","text":"do not delete"}]}]}`, index: 1},
		{name: "empty content", body: `{"input":[{"type":"reasoning","content":[]}]}`, index: 0},
		{name: "missing content", body: `{"input":[{"type":"reasoning","summary":[]}]}`, index: 0},
		{name: "non array content", body: `{"input":[{"type":"reasoning","content":{"type":"reasoning_text"}}]}`, index: 0},
		{name: "unknown item type", body: `{"input":[{"type":"future_reasoning","content":[{"type":"reasoning_text","text":"do not delete"}]}]}`, index: 0},
		{name: "content primitive", body: `{"input":[{"type":"reasoning","content":["reasoning_text"]}]}`, index: 0},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			body := []byte(tt.body)
			original := append([]byte(nil), body...)
			retryBody, changed, err := normalizeOpenAIReasoningContentRetryBody(body, openAIReasoningContentArrayError{Index: tt.index})
			require.NoError(t, err)
			require.False(t, changed)
			require.Nil(t, retryBody)
			require.Equal(t, original, body)
		})
	}
}

func TestOpenAIGatewayServiceReasoningContentRetrySucceedsForStreamingAndNonStreaming(t *testing.T) {
	tests := []struct {
		name        string
		stream      bool
		contentType string
		successBody string
	}{
		{
			name:        "non streaming",
			contentType: "application/json",
			successBody: `{"id":"resp_nonstream","output":[],"usage":{"input_tokens":11,"output_tokens":7,"total_tokens":18}}`,
		},
		{
			name:        "streaming",
			stream:      true,
			contentType: "text/event-stream",
			successBody: "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_stream\",\"output\":[],\"usage\":{\"input_tokens\":11,\"output_tokens\":7,\"total_tokens\":18}}}\n\ndata: [DONE]\n\n",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			body := []byte(fmt.Sprintf(`{"model":"gpt-5.6-sol","stream":%t,"input":[{"type":"message","content":[{"type":"input_text","text":"keep"}]},{"type":"reasoning","content":[{"type":"reasoning_text","text":"remove"}],"summary":[{"type":"summary_text","text":"keep summary"}],"encrypted_content":"keep encrypted"}]}`, tt.stream))
			upstream := &httpUpstreamRecorder{responses: []*http.Response{
				reasoningContentTestResponse(http.StatusBadRequest, "application/json", `{"error":{"type":"invalid_request_error","code":"array_above_max_length","param":"input[1].content","message":"synthetic validation error"},"usage":{"input_tokens":999,"output_tokens":999}}`),
				reasoningContentTestResponse(http.StatusOK, tt.contentType, tt.successBody),
			}}
			recorder, c := newReasoningContentTestContext(body)

			result, err := newOpenAIRejectedFieldTestService(upstream).Forward(
				context.Background(), c, newOpenAIRejectedFieldTestAccount(), body,
			)

			require.NoError(t, err)
			require.NotNil(t, result)
			require.Equal(t, OpenAIUsage{InputTokens: 11, OutputTokens: 7}, result.Usage)
			require.Len(t, upstream.bodies, 2)
			require.Equal(t, []int64{5107, 5107}, upstream.accountIDs)
			require.Equal(t, upstream.requests[0].URL.String(), upstream.requests[1].URL.String())
			require.True(t, gjson.GetBytes(upstream.bodies[0], "input.1.content").Exists())
			require.False(t, gjson.GetBytes(upstream.bodies[1], "input.1.content").Exists())
			require.Equal(t, "keep summary", gjson.GetBytes(upstream.bodies[1], "input.1.summary.0.text").String())
			require.Equal(t, "keep encrypted", gjson.GetBytes(upstream.bodies[1], "input.1.encrypted_content").String())
			require.Equal(t, http.StatusOK, recorder.Code)
			require.False(t, IsResponseCommitted(c))
			_, hasUpstreamErrors := c.Get(OpsUpstreamErrorsKey)
			require.False(t, hasUpstreamErrors)

			cachedBody, readErr := io.ReadAll(c.Request.Body)
			require.NoError(t, readErr)
			require.Equal(t, body, cachedBody, "Gin request body must remain unchanged")
		})
	}
}

func TestOpenAIGatewayServiceReasoningContentRetryFailureReturnsStructured400Once(t *testing.T) {
	body := []byte(`{"model":"gpt-5.6-sol","stream":false,"input":[{"type":"reasoning","content":[{"type":"reasoning_text","text":"remove first"}],"summary":[],"encrypted_content":"keep first"},{"type":"reasoning","content":[{"type":"reasoning_text","text":"do not retry second"}],"summary":[],"encrypted_content":"keep second"}]}`)
	upstream := &httpUpstreamRecorder{responses: []*http.Response{
		reasoningContentTestResponse(http.StatusBadRequest, "application/json", reasoningContentArrayErrorBody("input[0].content")),
		reasoningContentTestResponse(http.StatusBadRequest, "application/json", `{"error":{"type":"invalid_request_error","code":"array_above_max_length","param":"input[1].content","message":"Selected model is at capacity; retry your request"}}`),
		reasoningContentTestResponse(http.StatusOK, "application/json", `{"usage":{"input_tokens":99,"output_tokens":99}}`),
	}}
	recorder, c := newReasoningContentTestContext(body)
	account := newOpenAIRejectedFieldTestAccount()
	initialStatus, initialSchedulable := account.Status, account.Schedulable

	result, err := newOpenAIRejectedFieldTestService(upstream).Forward(context.Background(), c, account, body)

	require.Error(t, err)
	require.Nil(t, result)
	var failoverErr *UpstreamFailoverError
	require.False(t, errors.As(err, &failoverErr))
	var clientValidationErr *OpenAIReasoningContentArrayClientError
	require.True(t, errors.As(err, &clientValidationErr))
	require.Len(t, upstream.bodies, 2, "compatibility retry must be attempted at most once")
	require.Equal(t, []int64{account.ID, account.ID}, upstream.accountIDs)
	require.Equal(t, upstream.requests[0].URL.String(), upstream.requests[1].URL.String())
	require.False(t, gjson.GetBytes(upstream.bodies[1], "input.0.content").Exists())
	require.True(t, gjson.GetBytes(upstream.bodies[1], "input.1.content").Exists())
	require.Equal(t, initialStatus, account.Status)
	require.Equal(t, initialSchedulable, account.Schedulable)
	require.Equal(t, http.StatusBadRequest, recorder.Code)
	require.True(t, IsResponseCommitted(c))
	require.False(t, strings.Contains(recorder.Body.String(), "Upstream request failed"))
	require.Equal(t, "invalid_request_error", gjson.GetBytes(recorder.Body.Bytes(), "error.type").String())
	require.Equal(t, "array_above_max_length", gjson.GetBytes(recorder.Body.Bytes(), "error.code").String())
	require.Equal(t, "input[1].content", gjson.GetBytes(recorder.Body.Bytes(), "error.param").String())
	require.Equal(t, openAIReasoningContentArrayClientMessage, gjson.GetBytes(recorder.Body.Bytes(), "error.message").String())
	_, hasUpstreamErrors := c.Get(OpsUpstreamErrorsKey)
	require.False(t, hasUpstreamErrors, "client validation failures must not be recorded as channel failures")
	_, hasUpstreamStatus := c.Get(OpsUpstreamStatusCodeKey)
	require.False(t, hasUpstreamStatus)
}

func TestOpenAIGatewayServiceExactErrorWithUnsafeRequestDoesNotRetry(t *testing.T) {
	body := []byte(`{"model":"gpt-5.6-sol","stream":false,"input":[{"type":"message","content":[{"type":"input_text","text":"keep"}]}]}`)
	upstream := &httpUpstreamRecorder{responses: []*http.Response{
		reasoningContentTestResponse(http.StatusBadRequest, "application/json", reasoningContentArrayErrorBody("input[0].content")),
		reasoningContentTestResponse(http.StatusOK, "application/json", `{"usage":{"input_tokens":99,"output_tokens":99}}`),
	}}
	recorder, c := newReasoningContentTestContext(body)

	result, err := newOpenAIRejectedFieldTestService(upstream).Forward(
		context.Background(), c, newOpenAIRejectedFieldTestAccount(), body,
	)

	require.Error(t, err)
	require.Nil(t, result)
	require.Len(t, upstream.bodies, 1)
	require.Equal(t, http.StatusBadRequest, recorder.Code)
	require.Equal(t, "array_above_max_length", gjson.GetBytes(recorder.Body.Bytes(), "error.code").String())
}

func TestOpenAIGatewayServiceOrdinary400KeepsExistingBehavior(t *testing.T) {
	body := []byte(`{"model":"gpt-5.6-sol","stream":false,"input":"hello"}`)
	upstream := &httpUpstreamRecorder{responses: []*http.Response{
		reasoningContentTestResponse(http.StatusBadRequest, "application/json", `{"error":{"type":"invalid_request_error","code":"invalid_value","param":"input","message":"ordinary bad request"}}`),
	}}
	recorder, c := newReasoningContentTestContext(body)

	result, err := newOpenAIRejectedFieldTestService(upstream).Forward(
		context.Background(), c, newOpenAIRejectedFieldTestAccount(), body,
	)

	require.Error(t, err)
	require.Nil(t, result)
	require.Len(t, upstream.bodies, 1)
	require.Equal(t, http.StatusBadRequest, recorder.Code)
	require.Equal(t, "invalid_request_error", gjson.GetBytes(recorder.Body.Bytes(), "error.type").String())
	require.Equal(t, "ordinary bad request", gjson.GetBytes(recorder.Body.Bytes(), "error.message").String())
}

func reasoningContentArrayErrorBody(param string) string {
	payload := map[string]any{
		"error": map[string]any{
			"type":    "invalid_request_error",
			"code":    "array_above_max_length",
			"param":   param,
			"message": "synthetic validation error",
		},
	}
	body, _ := json.Marshal(payload)
	return string(body)
}

func reasoningContentTestResponse(status int, contentType, body string) *http.Response {
	return &http.Response{
		StatusCode: status,
		Header:     http.Header{"Content-Type": []string{contentType}},
		Body:       io.NopCloser(strings.NewReader(body)),
	}
}

func newReasoningContentTestContext(body []byte) (*httptest.ResponseRecorder, *gin.Context) {
	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(recorder)
	c.Request = httptest.NewRequest(http.MethodPost, "/v1/responses", bytes.NewReader(body))
	c.Request.Header.Set("Content-Type", "application/json")
	c.Request.Header.Set("User-Agent", "synthetic-test-client")
	SetOpenAIClientTransport(c, OpenAIClientTransportHTTP)
	return recorder, c
}
