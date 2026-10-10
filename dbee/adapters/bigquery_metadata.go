package adapters

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync"

	"cloud.google.com/go/bigquery"
	"github.com/kndndrj/nvim-dbee/dbee/core"
	"golang.org/x/sync/errgroup"
	"google.golang.org/api/googleapi"
	"google.golang.org/api/iterator"
)

var _ core.MetadataDriver = (*bigQueryDriver)(nil)
var _ core.DDLMetadataDriver = (*bigQueryDriver)(nil)

// MetadataDDL reads the server's complete DDL in one query per dataset. The
// schema API does not expose DDL (partitioning, clustering, options, and views).
func (d *bigQueryDriver) MetadataDDL(structure []*core.Structure) (map[string]string, error) {
	return d.metadataDDL(structure, false)
}

func (d *bigQueryDriver) MetadataDDLScope(structure []*core.Structure) (map[string]string, error) {
	return d.metadataDDL(structure, true)
}

func (d *bigQueryDriver) metadataDDL(structure []*core.Structure, scoped bool) (map[string]string, error) {
	ddls := make(map[string]string)
	for _, dataset := range structure {
		if len(dataset.Children) == 0 {
			continue
		}
		keys := make(map[string]string)
		for _, table := range dataset.Children {
			keys[table.Name] = core.ColumnKey(&core.TableOptions{Schema: table.Schema, Table: table.Name, Materialization: table.Type})
		}
		name := strings.ReplaceAll(d.c.Project()+"."+dataset.Name, "`", "\\`")
		sql := "SELECT table_name, ddl FROM `" + name + ".INFORMATION_SCHEMA.TABLES`"
		if scoped {
			sql += " WHERE table_name IN UNNEST(@table_names)"
		}
		query := d.c.Query(sql)
		if scoped {
			names := make([]string, 0, len(dataset.Children))
			for _, table := range dataset.Children {
				names = append(names, table.Name)
			}
			query.Parameters = []bigquery.QueryParameter{{Name: "table_names", Value: names}}
		}
		query.MaxBytesBilled = d.MaxBytesBilled
		query.DisableQueryCache = d.DisableQueryCache
		iter, err := query.Read(context.Background())
		if err != nil {
			return nil, fmt.Errorf("DDL for dataset %s: %w", dataset.Name, err)
		}
		for {
			var row []bigquery.Value
			if err := iter.Next(&row); err != nil {
				if errors.Is(err, iterator.Done) {
					break
				}
				return nil, fmt.Errorf("DDL for dataset %s: %w", dataset.Name, err)
			}
			if len(row) != 2 {
				return nil, fmt.Errorf("invalid DDL row for dataset %s", dataset.Name)
			}
			table, ok := row[0].(string)
			if !ok {
				return nil, fmt.Errorf("invalid table name in DDL for dataset %s", dataset.Name)
			}
			key, exists := keys[table]
			if !exists || row[1] == nil {
				continue
			}
			ddl, ok := row[1].(string)
			if !ok {
				return nil, fmt.Errorf("invalid DDL text for %s.%s", dataset.Name, table)
			}
			if strings.TrimSpace(ddl) != "" {
				ddls[key] = ddl
			}
		}
	}
	return ddls, nil
}

// Metadata reads table schemas through the metadata API instead of running a
// separate INFORMATION_SCHEMA query for every table.
func (d *bigQueryDriver) Metadata() (*core.Metadata, error) {
	structure, err := d.Structure()
	if err != nil {
		return nil, err
	}
	return d.MetadataForStructure(structure)
}

func (d *bigQueryDriver) MetadataForStructure(structure []*core.Structure) (*core.Metadata, error) {
	snapshot := &core.Metadata{Structure: structure, Columns: make(map[string][]*core.Column)}
	group, ctx := errgroup.WithContext(context.Background())
	group.SetLimit(8)
	var mu sync.Mutex
	missing := make(map[*core.Structure]bool)
	for _, dataset := range structure {
		for _, table := range dataset.Children {
			group.Go(func() error {
				metadata, err := d.c.Dataset(table.Schema).Table(table.Name).Metadata(ctx)
				if err != nil {
					var apiErr *googleapi.Error
					if errors.As(err, &apiErr) && apiErr.Code == http.StatusNotFound {
						mu.Lock()
						missing[table] = true
						mu.Unlock()
						return nil
					}
					return fmt.Errorf("metadata for %s.%s: %w", table.Schema, table.Name, err)
				}
				columns := make([]*core.Column, 0, len(metadata.Schema))
				for _, field := range metadata.Schema {
					columns = append(columns, &core.Column{Name: field.Name, Type: bigQueryColumnType(field)})
				}
				key := core.ColumnKey(&core.TableOptions{
					Schema: table.Schema, Table: table.Name, Materialization: table.Type,
				})
				mu.Lock()
				snapshot.Columns[key] = columns
				mu.Unlock()
				return nil
			})
		}
	}
	if err := group.Wait(); err != nil {
		return nil, err
	}
	for _, dataset := range structure {
		tables := dataset.Children[:0]
		for _, table := range dataset.Children {
			if !missing[table] {
				tables = append(tables, table)
			}
		}
		dataset.Children = tables
	}
	return snapshot, nil
}

// StructureScope bypasses project-wide dataset/table listing for a drawer refresh.
func (d *bigQueryDriver) StructureScope(path []core.MetadataNode) ([]*core.Structure, error) {
	if len(path) == 0 {
		return d.Structure()
	}
	if len(path) > 2 {
		return nil, fmt.Errorf("invalid BigQuery metadata path")
	}
	dataset := &core.Structure{Name: path[0].Name, Schema: path[0].Schema, Type: core.StructureTypeFromString(path[0].Type)}
	if len(path) == 2 {
		// MetadataForStructure reads this table directly and removes it on 404.
		table := path[1]
		dataset.Children = []*core.Structure{{Name: table.Name, Schema: table.Schema, Type: core.StructureTypeFromString(table.Type)}}
		return []*core.Structure{dataset}, nil
	}
	iter := d.c.Dataset(dataset.Name).Tables(context.Background())
	for {
		table, err := iter.Next()
		if errors.Is(err, iterator.Done) {
			break
		}
		if err != nil {
			var apiErr *googleapi.Error
			if errors.As(err, &apiErr) && apiErr.Code == http.StatusNotFound {
				return nil, nil
			}
			return nil, err
		}
		dataset.Children = append(dataset.Children, &core.Structure{
			Name: table.TableID, Schema: table.DatasetID, Type: core.StructureTypeTable,
		})
	}
	return []*core.Structure{dataset}, nil
}

func bigQueryColumnType(field *bigquery.FieldSchema) string {
	typ := string(field.Type)
	switch field.Type {
	case bigquery.IntegerFieldType:
		typ = "INT64"
	case bigquery.FloatFieldType:
		typ = "FLOAT64"
	case bigquery.BooleanFieldType:
		typ = "BOOL"
	case bigquery.RecordFieldType:
		fields := make([]string, 0, len(field.Schema))
		for _, nested := range field.Schema {
			fields = append(fields, "`"+strings.ReplaceAll(nested.Name, "`", "\\`")+"` "+bigQueryColumnType(nested))
		}
		typ = "STRUCT<" + strings.Join(fields, ", ") + ">"
	case bigquery.RangeFieldType:
		if field.RangeElementType != nil {
			typ = "RANGE<" + string(field.RangeElementType.Type) + ">"
		}
	}
	if field.Repeated {
		typ = "ARRAY<" + typ + ">"
	}
	return typ
}
