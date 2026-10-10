package core

import (
	"context"
	"errors"
	"testing"

	"github.com/stretchr/testify/require"
)

type metadataTestDriver struct {
	structure []*Structure
	columns   map[string][]*Column
	requests  int
	err       error
}

func (d *metadataTestDriver) Query(context.Context, string) (ResultStream, error) {
	return nil, errors.New("unused")
}
func (d *metadataTestDriver) Structure() ([]*Structure, error) { return d.structure, nil }
func (d *metadataTestDriver) Close()                           {}
func (d *metadataTestDriver) Columns(opts *TableOptions) ([]*Column, error) {
	d.requests++
	return d.columns[ColumnKey(opts)], d.err
}
func (d *metadataTestDriver) SelectDatabase(string) error { return nil }
func (d *metadataTestDriver) ListDatabases() (string, []string, error) {
	return "default", []string{"default", "other"}, nil
}

func TestConnectionMetadataCollectsTablesAndViews(t *testing.T) {
	driver := &metadataTestDriver{
		structure: []*Structure{{Name: "public", Children: []*Structure{
			{Name: "users", Schema: "public", Type: StructureTypeTable},
			{Name: "users", Schema: "public", Type: StructureTypeView},
		}}},
		columns: make(map[string][]*Column),
	}
	for _, typ := range []StructureType{StructureTypeTable, StructureTypeView} {
		opts := &TableOptions{Schema: "public", Table: "users", Materialization: typ}
		driver.columns[ColumnKey(opts)] = []*Column{{Name: "id", Type: typ.String()}}
	}
	conn := &Connection{driver: driver}
	snapshot, err := conn.GetMetadata()
	require.NoError(t, err)
	require.Equal(t, driver.structure, snapshot.Structure)
	require.Equal(t, driver.columns, snapshot.Columns)
	require.Equal(t, 2, driver.requests)
	driver.err = errors.New("permission denied")
	_, err = conn.GetMetadata()
	require.ErrorContains(t, err, "permission denied")
}

func TestMetadataCacheKeyPartitionsConnectionAndDatabase(t *testing.T) {
	conn := &Connection{params: &ConnectionParams{Type: "test", URL: "test://one"}, driver: &metadataTestDriver{}}
	original := conn.MetadataCacheKey()
	require.NotContains(t, original, "test://one")
	conn.params.Name = "Renamed"
	require.Equal(t, original, conn.MetadataCacheKey())
	conn.params.URL = "test://two"
	require.NotEqual(t, original, conn.MetadataCacheKey())
	conn.params.URL = "test://one"
	require.NoError(t, conn.SelectDatabase("other"))
	require.NotEqual(t, original, conn.MetadataCacheKey())
}

func TestColumnKeyDoesNotCollideAcrossSchemas(t *testing.T) {
	one := &TableOptions{Schema: "a.b", Table: "c", Materialization: StructureTypeTable}
	two := &TableOptions{Schema: "a", Table: "b.c", Materialization: StructureTypeTable}
	require.NotEqual(t, ColumnKey(one), ColumnKey(two))
}

type batchMetadataTestDriver struct {
	metadataTestDriver
	snapshot *Metadata
	ddl      map[string]string
	ddlErr   error
	ddlCalls int
}

func (d *batchMetadataTestDriver) Metadata() (*Metadata, error) { return d.snapshot, nil }
func (d *batchMetadataTestDriver) MetadataDDL(structure []*Structure) (map[string]string, error) {
	d.ddlCalls++
	return d.ddl, d.ddlErr
}

func TestOptimizedMetadataAlsoCollectsDDL(t *testing.T) {
	driver := &batchMetadataTestDriver{
		snapshot: &Metadata{Columns: make(map[string][]*Column)},
		ddl:      map[string]string{"table": "CREATE TABLE table (id INT)"},
	}
	conn := &Connection{driver: driver}
	snapshot, err := conn.GetMetadata()
	require.NoError(t, err)
	require.Equal(t, driver.ddl, snapshot.DDL)
	require.Equal(t, 1, driver.ddlCalls)
	require.Zero(t, driver.requests, "optimized column collection must be retained")
	driver.snapshot = &Metadata{Columns: make(map[string][]*Column)}
	driver.ddlErr = errors.New("DDL query failed")
	_, err = conn.GetMetadata()
	require.ErrorContains(t, err, "DDL query failed")
}
