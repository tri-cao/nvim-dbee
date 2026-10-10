package core

import (
	"errors"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestMetadataRefreshScopeCollectsOnlySelectedColumns(t *testing.T) {
	driver := &metadataTestDriver{columns: make(map[string][]*Column)}
	for _, schema := range []string{"public", "private"} {
		node := &Structure{Name: schema, Schema: schema, Type: StructureTypeSchema}
		for _, name := range []string{"users", "events"} {
			node.Children = append(node.Children, &Structure{Name: name, Schema: schema, Type: StructureTypeTable})
			key := ColumnKey(&TableOptions{Schema: schema, Table: name, Materialization: StructureTypeTable})
			driver.columns[key] = []*Column{{Name: "id", Type: "integer"}}
		}
		driver.structure = append(driver.structure, node)
	}
	conn := &Connection{driver: driver}
	path := []MetadataNode{{Name: "public", Schema: "public", Type: "schema"}, {Name: "users", Schema: "public", Type: "table"}}
	for _, test := range []struct {
		name string
		path []MetadataNode
		want int
	}{
		{"connection", nil, 4}, {"schema", path[:1], 2}, {"table", path, 1},
	} {
		t.Run(test.name, func(t *testing.T) {
			driver.requests = 0
			snapshot, err := conn.GetMetadataScope(&MetadataScope{Path: test.path})
			require.NoError(t, err)
			require.Equal(t, test.want, driver.requests)
			require.Len(t, snapshot.Columns, test.want)
		})
	}
	driver.err = errors.New("permission denied")
	_, err := conn.GetMetadataScope(&MetadataScope{Path: path})
	require.ErrorContains(t, err, "permission denied")
}

func TestMergeMetadataScopePreservesSiblingsAndPreviousSnapshot(t *testing.T) {
	key := func(schema, table string) string {
		return ColumnKey(&TableOptions{Schema: schema, Table: table, Materialization: StructureTypeTable})
	}
	previous := &Metadata{Columns: make(map[string][]*Column), DDL: make(map[string]string)}
	for _, schema := range []string{"public", "private"} {
		node := &Structure{Name: schema, Schema: schema, Type: StructureTypeSchema}
		for _, table := range []string{"users", "events"} {
			node.Children = append(node.Children, &Structure{Name: table, Schema: schema, Type: StructureTypeTable})
			previous.Columns[key(schema, table)] = []*Column{{Name: "old"}}
			previous.DDL[key(schema, table)] = "old DDL"
		}
		previous.Structure = append(previous.Structure, node)
	}
	path := []MetadataNode{{Name: "public", Schema: "public", Type: "schema"}, {Name: "users", Schema: "public", Type: "table"}}
	fresh := &Metadata{
		Structure: []*Structure{{Name: "public", Schema: "public", Type: StructureTypeSchema, Children: []*Structure{
			{Name: "users", Schema: "public", Type: StructureTypeTable},
		}}},
		Columns: map[string][]*Column{key("public", "users"): {{Name: "new"}}},
		DDL:     map[string]string{key("public", "users"): "new DDL"},
	}
	merged := MergeMetadataScope(previous, fresh, path)
	require.Len(t, merged.Columns, 4)
	require.Len(t, merged.Structure[0].Children, 2)
	require.Equal(t, "new", merged.Columns[key("public", "users")][0].Name)
	require.Equal(t, "old DDL", merged.DDL[key("public", "events")])
	require.Same(t, previous.Structure[1], merged.Structure[1])
	require.Equal(t, "old", previous.Columns[key("public", "users")][0].Name)
	require.Equal(t, "old DDL", previous.DDL[key("public", "users")])

	// Refreshing a schema removes dropped tables and stale columns/DDL in that schema only.
	merged = MergeMetadataScope(previous, fresh, path[:1])
	require.Len(t, merged.Columns, 3)
	require.NotContains(t, merged.DDL, key("public", "events"))
	require.Len(t, merged.Structure[0].Children, 1)
	require.Len(t, previous.Structure[0].Children, 2)

	// If the table or even its schema disappeared, a table refresh leaves siblings alone.
	for _, structure := range [][]*Structure{nil, {{Name: "public", Schema: "public", Type: StructureTypeSchema}}} {
		fresh.Structure = structure
		fresh.Columns = map[string][]*Column{}
		fresh.DDL = map[string]string{}
		merged = MergeMetadataScope(previous, fresh, path)
		require.Len(t, merged.Columns, 3)
		require.NotContains(t, merged.DDL, key("public", "users"))
		require.Contains(t, merged.DDL, key("public", "events"))
		require.Len(t, merged.Structure[0].Children, 1)
	}
}
