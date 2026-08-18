package service

import (
	"encoding/json"
	"fmt"
	"net/http"
	"regexp"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/tidwall/sjson"
)

const openAIReasoningContentArrayClientMessage = "The referenced reasoning item contains unsupported content. Remove its content field and retry the request."

var openAIReasoningContentArrayParamPattern = regexp.MustCompile(`^input\[([0-9]+)\]\.content$`)

type openAIReasoningContentArrayError struct {
	Index int
	Param string
}

// OpenAIReasoningContentArrayClientError marks a validation response that was
// already returned to the client and must not count as an account scheduling failure.
type OpenAIReasoningContentArrayClientError struct {
	param string
}

func (e *OpenAIReasoningContentArrayClientError) Error() string {
	if e == nil || e.param == "" {
		return "openai invalid reasoning content"
	}
	return fmt.Sprintf("openai invalid reasoning content at %s", e.param)
}

func classifyOpenAIReasoningContentArrayError(statusCode int, responseBody []byte) (openAIReasoningContentArrayError, bool) {
	if statusCode != http.StatusBadRequest || len(responseBody) == 0 {
		return openAIReasoningContentArrayError{}, false
	}

	var payload struct {
		Error struct {
			Type  string `json:"type"`
			Code  string `json:"code"`
			Param string `json:"param"`
		} `json:"error"`
	}
	if err := json.Unmarshal(responseBody, &payload); err != nil {
		return openAIReasoningContentArrayError{}, false
	}
	if strings.TrimSpace(payload.Error.Type) != "invalid_request_error" ||
		strings.TrimSpace(payload.Error.Code) != "array_above_max_length" {
		return openAIReasoningContentArrayError{}, false
	}

	param := strings.TrimSpace(payload.Error.Param)
	match := openAIReasoningContentArrayParamPattern.FindStringSubmatch(param)
	if len(match) != 2 {
		return openAIReasoningContentArrayError{}, false
	}
	index, err := strconv.Atoi(match[1])
	if err != nil || index < 0 {
		return openAIReasoningContentArrayError{}, false
	}
	return openAIReasoningContentArrayError{Index: index, Param: param}, true
}

func normalizeOpenAIReasoningContentRetryBody(body []byte, signature openAIReasoningContentArrayError) ([]byte, bool, error) {
	if len(body) == 0 || signature.Index < 0 {
		return nil, false, nil
	}

	var request struct {
		Input []json.RawMessage `json:"input"`
	}
	if err := json.Unmarshal(body, &request); err != nil || signature.Index >= len(request.Input) {
		return nil, false, nil
	}

	var item map[string]json.RawMessage
	if err := json.Unmarshal(request.Input[signature.Index], &item); err != nil || item == nil {
		return nil, false, nil
	}
	if !rawJSONStringEquals(item["type"], "reasoning") {
		return nil, false, nil
	}

	var content []json.RawMessage
	contentJSON, exists := item["content"]
	if !exists || json.Unmarshal(contentJSON, &content) != nil || len(content) == 0 {
		return nil, false, nil
	}
	for _, rawPart := range content {
		var part map[string]json.RawMessage
		if err := json.Unmarshal(rawPart, &part); err != nil || part == nil || !rawJSONStringEquals(part["type"], "reasoning_text") {
			return nil, false, nil
		}
	}

	retryBody, err := sjson.DeleteBytes(
		append([]byte(nil), body...),
		fmt.Sprintf("input.%d.content", signature.Index),
	)
	if err != nil {
		return nil, false, fmt.Errorf("delete reasoning content at input[%d]: %w", signature.Index, err)
	}
	return retryBody, true, nil
}

func rawJSONStringEquals(raw json.RawMessage, expected string) bool {
	if len(raw) == 0 {
		return false
	}
	var value string
	return json.Unmarshal(raw, &value) == nil && value == expected
}

func writeOpenAIReasoningContentArrayError(c *gin.Context, signature openAIReasoningContentArrayError) {
	MarkResponseCommitted(c)
	c.JSON(http.StatusBadRequest, gin.H{
		"error": gin.H{
			"type":    "invalid_request_error",
			"code":    "array_above_max_length",
			"param":   signature.Param,
			"message": openAIReasoningContentArrayClientMessage,
		},
	})
}

func newOpenAIReasoningContentArrayClientError(signature openAIReasoningContentArrayError) error {
	return &OpenAIReasoningContentArrayClientError{param: signature.Param}
}
