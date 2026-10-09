package adapters

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"cloud.google.com/go/bigquery"
	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/stretchr/testify/assert"
	"google.golang.org/api/googleapi"
	"google.golang.org/api/option"
)

func Test_bigQueryDriver_Structure(t *testing.T) {
	for _, test := range []struct {
		name          string
		tableStatus   int
		partialTables bool
		listStatus    int
		wantError     int
	}{
		{name: "skip missing dataset", tableStatus: http.StatusNotFound},
		{name: "discard partial missing dataset", tableStatus: http.StatusNotFound, partialTables: true},
		{name: "preserve permission errors", tableStatus: http.StatusForbidden, wantError: http.StatusForbidden},
		{name: "preserve dataset listing errors", listStatus: http.StatusNotFound, wantError: http.StatusNotFound},
	} {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				writeError := func(status int) {
					w.WriteHeader(status)
					_ = json.NewEncoder(w).Encode(map[string]any{
						"error": map[string]any{"code": status, "message": http.StatusText(status)},
					})
				}
				if r.URL.Path == "/projects/test-project/datasets" {
					if test.listStatus != 0 {
						writeError(test.listStatus)
						return
					}
					var datasets []any
					for _, name := range []string{"before", "missing", "after"} {
						datasets = append(datasets, map[string]any{
							"datasetReference": map[string]string{"projectId": "test-project", "datasetId": name},
						})
					}
					_ = json.NewEncoder(w).Encode(map[string]any{"datasets": datasets})
					return
				}
				var dataset string
				switch r.URL.Path {
				case "/projects/test-project/datasets/before/tables":
					dataset = "before"
				case "/projects/test-project/datasets/after/tables":
					dataset = "after"
				case "/projects/test-project/datasets/missing/tables":
					if !test.partialTables || r.URL.Query().Get("pageToken") != "" {
						writeError(test.tableStatus)
						return
					}
					dataset = "missing"
				default:
					t.Errorf("unexpected request: %s", r.URL)
					http.NotFound(w, r)
					return
				}
				response := map[string]any{
					"tables": []any{map[string]any{
						"tableReference": map[string]string{
							"projectId": "test-project", "datasetId": dataset, "tableId": "events",
						},
					}},
				}
				if dataset == "missing" {
					response["nextPageToken"] = "next"
				}
				_ = json.NewEncoder(w).Encode(response)
			}))
			defer server.Close()

			client, err := bigquery.NewClient(context.Background(), "test-project",
				option.WithEndpoint(server.URL+"/"), option.WithoutAuthentication())
			if err != nil {
				t.Fatal(err)
			}
			defer client.Close()

			layouts, err := (&bigQueryDriver{c: client}).Structure()
			if test.wantError != 0 {
				var apiErr *googleapi.Error
				if !errors.As(err, &apiErr) {
					t.Fatalf("expected API error %d, got %v", test.wantError, err)
				}
				assert.Equal(t, test.wantError, apiErr.Code)
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			var want []*core.Structure
			for _, name := range []string{"before", "after"} {
				want = append(want, &core.Structure{
					Name: name, Schema: name, Type: core.StructureTypeNone,
					Children: []*core.Structure{{Name: "events", Schema: name, Type: core.StructureTypeTable}},
				})
			}
			assert.Equal(t, want, layouts)
		})
	}
}
