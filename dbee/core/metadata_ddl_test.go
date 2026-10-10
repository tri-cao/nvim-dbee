package core_test

import (
	"context"
	"errors"
	"testing"

	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/kndndrj/nvim-dbee/dbee/core/mock"
	"github.com/stretchr/testify/require"
)

func TestMetadataCollectsDDLWithoutQueryLimits(t *testing.T) {
	for _, test := range []struct {
		name   string
		header core.Header
		rows   []core.Row
		want   string
	}{
		{"text", core.Header{"ddl"}, []core.Row{{"CREATE TABLE users (id INT)"}}, "CREATE TABLE users (id INT)"},
		{"mysql", core.Header{"Table", "Create Table"}, []core.Row{{"users", "CREATE TABLE users (id INT)"}}, "CREATE TABLE users (id INT)"},
		{"mysql view", core.Header{"View", "Create View", "character_set_client"}, []core.Row{{"users", "CREATE VIEW users AS SELECT 1", "utf8"}}, "CREATE VIEW users AS SELECT 1"},
		{"multiple rows", core.Header{"ddl"}, []core.Row{{[]byte("CREATE TABLE users (")}, {"id INT);"}}, "CREATE TABLE users (\nid INT);"},
	} {
		t.Run(test.name, func(t *testing.T) {
			queries := 0
			adapter := mock.NewAdapter(test.rows,
				mock.AdapterWithTableDefinition("users", []*core.Column{{Name: "id", Type: "INT"}}),
				mock.AdapterWithTableHelper("DDL", "SELECT definition FROM catalog"),
				mock.AdapterWithResultStreamOpts(mock.ResultStreamWithHeader(test.header)),
				mock.AdapterWithQuerySideEffect("SELECT definition FROM catalog", func(context.Context) error {
					queries++
					return nil
				}),
			)
			conn, err := core.NewConnection(&core.ConnectionParams{Type: "mysql"}, adapter)
			require.NoError(t, err)
			defer conn.Close()
			snapshot, err := conn.GetMetadata()
			require.NoError(t, err)
			key := core.ColumnKey(&core.TableOptions{Table: "users", Materialization: core.StructureTypeTable})
			require.Equal(t, test.want, snapshot.DDL[key])
			require.Equal(t, 1, queries, "DDL query must not receive a default LIMIT")
		})
	}
}

func TestMetadataDDLFailureRejectsSnapshot(t *testing.T) {
	adapter := mock.NewAdapter(nil,
		mock.AdapterWithTableDefinition("users", []*core.Column{{Name: "id", Type: "INT"}}),
		mock.AdapterWithTableHelper("DDL", "SHOW CREATE TABLE users"),
		mock.AdapterWithQuerySideEffect("SHOW CREATE TABLE users", func(context.Context) error {
			return errors.New("permission denied")
		}),
	)
	conn, err := core.NewConnection(&core.ConnectionParams{}, adapter)
	require.NoError(t, err)
	defer conn.Close()
	snapshot, err := conn.GetMetadata()
	require.Nil(t, snapshot)
	require.ErrorContains(t, err, "DDL for .users")
	require.ErrorContains(t, err, "permission denied")
}

func TestMetadataWithoutDDLSupportStillCollectsColumns(t *testing.T) {
	adapter := mock.NewAdapter(nil,
		mock.AdapterWithTableDefinition("users", []*core.Column{{Name: "id", Type: "INT"}}),
	)
	conn, err := core.NewConnection(&core.ConnectionParams{}, adapter)
	require.NoError(t, err)
	defer conn.Close()
	snapshot, err := conn.GetMetadata()
	require.NoError(t, err)
	require.NotNil(t, snapshot.DDL)
	require.Empty(t, snapshot.DDL)
	require.Len(t, snapshot.Columns, 1)
}
