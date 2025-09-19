// Copyright (c) Tailscale Inc & AUTHORS
// SPDX-License-Identifier: BSD-3-Clause

package server

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestUIDenyOnMissingApplicationGrant(t *testing.T) {

	tests := []struct {
		name              string
		bypassAppCapCheck bool
		expectedStatus    int
	}{
		{name: "No UI Application Capability", bypassAppCapCheck: false, expectedStatus: http.StatusForbidden},
		{name: "Has UI application Capability", bypassAppCapCheck: true, expectedStatus: http.StatusOK},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := &IDPServer{
				bypassAppCapCheck: tt.bypassAppCapCheck,
			}
			req := httptest.NewRequest("GET", "/", nil)
			rr := httptest.NewRecorder()
			s.ServeHTTP(rr, req)

			if rr.Code != tt.expectedStatus {
				t.Errorf("expected status %d, got %d", tt.expectedStatus, rr.Code)
			}
		})
	}
}
