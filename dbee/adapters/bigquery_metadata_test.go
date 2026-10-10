package adapters

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"cloud.google.com/go/bigquery"
	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/stretchr/testify/require"
	"google.golang.org/api/option"
)

func TestBigQueryMetadataUsesSchemaAPI(t *testing.T) {
	for _, status := range []int{http.StatusNotFound, http.StatusForbidden} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				if r.Method != http.MethodGet {
					t.Errorf("metadata must not execute query jobs: %s %s", r.Method, r.URL)
				}
				ref := func(table string) map[string]string {
					return map[string]string{"projectId": "test-project", "datasetId": "analytics", "tableId": table}
				}
				switch r.URL.Path {
				case "/projects/test-project/datasets":
					_ = json.NewEncoder(w).Encode(map[string]any{"datasets": []any{map[string]any{
						"datasetReference": map[string]string{"projectId": "test-project", "datasetId": "analytics"},
					}}})
				case "/projects/test-project/datasets/analytics/tables":
					var tables []any
					for _, name := range []string{"events", "missing"} {
						tables = append(tables, map[string]any{"tableReference": ref(name)})
					}
					_ = json.NewEncoder(w).Encode(map[string]any{"tables": tables})
				case "/projects/test-project/datasets/analytics/tables/missing":
					w.WriteHeader(status)
					_ = json.NewEncoder(w).Encode(map[string]any{"error": map[string]any{
						"code": status, "message": http.StatusText(status),
					}})
				case "/projects/test-project/datasets/analytics/tables/events":
					_ = json.NewEncoder(w).Encode(map[string]any{
						"tableReference": ref("events"),
						"schema": map[string]any{"fields": []any{
							map[string]string{"name": "id", "type": "INTEGER"},
							map[string]string{"name": "tags", "type": "STRING", "mode": "REPEATED"},
						}},
					})
				default:
					t.Errorf("unexpected request: %s", r.URL)
					http.NotFound(w, r)
				}
			}))
			defer server.Close()
			client, err := bigquery.NewClient(context.Background(), "test-project",
				option.WithEndpoint(server.URL+"/"), option.WithoutAuthentication())
			require.NoError(t, err)
			defer client.Close()
			snapshot, err := (&bigQueryDriver{c: client}).Metadata()
			if status == http.StatusForbidden {
				require.ErrorContains(t, err, "Forbidden")
				return
			}
			require.NoError(t, err)
			require.Len(t, snapshot.Structure, 1)
			require.Len(t, snapshot.Structure[0].Children, 1)
			require.Equal(t, "events", snapshot.Structure[0].Children[0].Name)
			key := core.ColumnKey(&core.TableOptions{Schema: "analytics", Table: "events", Materialization: core.StructureTypeTable})
			require.Equal(t, []*core.Column{{Name: "id", Type: "INT64"}, {Name: "tags", Type: "ARRAY<STRING>"}}, snapshot.Columns[key])
			require.Len(t, snapshot.Columns, 1)
		})
	}
}

func TestBigQueryColumnTypePreservesNestedAndRepeatedFields(t *testing.T) {
	field := &bigquery.FieldSchema{
		Type: bigquery.RecordFieldType, Repeated: true,
		Schema: bigquery.Schema{
			{Name: "active", Type: bigquery.BooleanFieldType},
			{Name: "values", Type: bigquery.FloatFieldType, Repeated: true},
			{Name: "period", Type: bigquery.RangeFieldType, RangeElementType: &bigquery.RangeElementType{Type: bigquery.DateFieldType}},
		},
	}
	require.Equal(t, "ARRAY<STRUCT<`active` BOOL, `values` ARRAY<FLOAT64>, `period` RANGE<DATE>>>", bigQueryColumnType(field))
	require.False(t, strings.Contains(bigQueryColumnType(field), "BOOLEAN"))
}

func TestBigQueryDDLBatchesByDataset(t *testing.T) {
	for _, status := range []int{http.StatusOK, http.StatusForbidden} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			requests := 0
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				if r.Method != http.MethodPost || r.URL.Path != "/projects/test-project/queries" {
					t.Errorf("unexpected DDL request: %s %s", r.Method, r.URL)
					w.WriteHeader(http.StatusBadRequest)
					return
				}
				requests++
				var request struct {
					Query          string `json:"query"`
					UseLegacySQL   bool   `json:"useLegacySql"`
					MaxBytesBilled string `json:"maximumBytesBilled"`
				}
				if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
					t.Error(err)
					return
				}
				if request.Query != "SELECT table_name, ddl FROM `test-project.analytics.INFORMATION_SCHEMA.TABLES`" || request.UseLegacySQL || request.MaxBytesBilled != "12345" {
					t.Errorf("unexpected DDL configuration: %+v", request)
				}
				if status != http.StatusOK {
					w.WriteHeader(status)
					_ = json.NewEncoder(w).Encode(map[string]any{"error": map[string]any{"code": status, "message": "Forbidden"}})
					return
				}
				var rows []any
				for _, name := range []string{"events", "view", "new_table"} {
					rows = append(rows, map[string]any{"f": []any{
						map[string]any{"v": name}, map[string]any{"v": "CREATE " + name},
					}})
				}
				rows = append(rows, map[string]any{"f": []any{map[string]any{"v": "external"}, map[string]any{"v": nil}}})
				_ = json.NewEncoder(w).Encode(map[string]any{
					"jobComplete": true, "totalRows": "4", "rows": rows,
					"jobReference": map[string]string{"projectId": "test-project", "jobId": "ddl"},
					"schema": map[string]any{"fields": []any{
						map[string]string{"name": "table_name", "type": "STRING"},
						map[string]string{"name": "ddl", "type": "STRING"},
					}},
				})
			}))
			defer server.Close()
			client, err := bigquery.NewClient(context.Background(), "test-project",
				option.WithEndpoint(server.URL+"/"), option.WithoutAuthentication())
			require.NoError(t, err)
			defer client.Close()
			driver := &bigQueryDriver{c: client, QueryConfig: bigquery.QueryConfig{
				Q: "original user query", UseLegacySQL: true, MaxBytesBilled: 12345,
				Dst: client.Dataset("output").Table("user_result"), WriteDisposition: bigquery.WriteTruncate,
			}}
			structure := []*core.Structure{
				{Name: "analytics", Children: []*core.Structure{
					{Name: "events", Schema: "analytics", Type: core.StructureTypeTable},
					{Name: "view", Schema: "analytics", Type: core.StructureTypeView},
					{Name: "external", Schema: "analytics", Type: core.StructureTypeTable},
				}},
				{Name: "empty"},
			}
			ddls, err := driver.MetadataDDL(structure)
			if status != http.StatusOK {
				require.ErrorContains(t, err, "DDL for dataset analytics")
				require.ErrorContains(t, err, "Forbidden")
				return
			}
			require.NoError(t, err)
			require.Equal(t, 1, requests, "one DDL query per nonempty dataset")
			require.Len(t, ddls, 2, "unlisted tables and null DDL must be excluded")
			for _, typ := range []core.StructureType{core.StructureTypeTable, core.StructureTypeView} {
				name := "events"
				if typ == core.StructureTypeView {
					name = "view"
				}
				key := core.ColumnKey(&core.TableOptions{Schema: "analytics", Table: name, Materialization: typ})
				require.Equal(t, "CREATE "+name, ddls[key])
			}
			require.Equal(t, "original user query", driver.Q)
			require.True(t, driver.UseLegacySQL, "DDL collection must not alter user query settings")
		})
	}
}
