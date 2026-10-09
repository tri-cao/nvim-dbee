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
)

var _ core.MetadataDriver = (*bigQueryDriver)(nil)

// Metadata reads table schemas through the metadata API instead of running a
// separate INFORMATION_SCHEMA query for every table.
func (d *bigQueryDriver) Metadata() (*core.Metadata, error) {
	structure, err := d.Structure()
	if err != nil {
		return nil, err
	}
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
