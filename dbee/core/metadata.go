package core

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"strings"
)

// Metadata is a snapshot of database structure, columns, and available DDL.
type Metadata struct {
	Structure []*Structure
	Columns   map[string][]*Column
	DDL       map[string]string
}

// MetadataDriver can collect schemas more efficiently than individual Columns calls.
type MetadataDriver interface {
	Metadata() (*Metadata, error)
}

// DDLMetadataDriver can fetch DDL in batches rather than querying each table.
type DDLMetadataDriver interface {
	MetadataDDL(structure []*Structure) (map[string]string, error)
}

// ColumnKey keeps tables with the same name in different schemas distinct.
func ColumnKey(opts *TableOptions) string {
	key, _ := json.Marshal([3]string{opts.Schema, opts.Table, opts.Materialization.String()})
	return string(key)
}

// MetadataCacheKey identifies the actual connection without storing its credentials.
func (c *Connection) MetadataCacheKey() string {
	key, _ := json.Marshal([3]string{c.params.Type, c.params.URL, c.metadataDatabase})
	return fmt.Sprintf("%x", sha256.Sum256(key))
}

func (c *Connection) GetMetadata() (*Metadata, error) {
	var metadata *Metadata
	var err error
	if driver, ok := c.driver.(MetadataDriver); ok {
		metadata, err = driver.Metadata()
	} else {
		metadata, err = c.collectColumns()
	}
	if err != nil {
		return nil, err
	}
	if metadata == nil || metadata.Columns == nil {
		return nil, fmt.Errorf("incomplete metadata snapshot")
	}
	if metadata.DDL != nil {
		return metadata, nil
	}
	if driver, ok := c.driver.(DDLMetadataDriver); ok {
		metadata.DDL, err = driver.MetadataDDL(metadata.Structure)
		if err != nil {
			return nil, err
		}
		return metadata, nil
	}
	ddls := make(map[string]string)
	var collect func([]*Structure) error
	collect = func(nodes []*Structure) error {
		for _, node := range nodes {
			if node.Type != StructureTypeNone && node.Type != StructureTypeSchema && c.adapter != nil {
				opts := &TableOptions{Schema: node.Schema, Table: node.Name, Materialization: node.Type}
				if query := c.GetHelpers(opts)["DDL"]; strings.TrimSpace(query) != "" {
					ddl, err := c.queryDDL(query)
					if err != nil {
						return fmt.Errorf("DDL for %s.%s: %w", node.Schema, node.Name, err)
					}
					ddls[ColumnKey(opts)] = ddl
				}
			}
			if err := collect(node.Children); err != nil {
				return err
			}
		}
		return nil
	}
	if err := collect(metadata.Structure); err != nil {
		return nil, err
	}
	metadata.DDL = ddls
	return metadata, nil
}

func (c *Connection) collectColumns() (*Metadata, error) {
	structure, err := c.GetStructure()
	if err != nil {
		return nil, err
	}
	metadata := &Metadata{Structure: structure, Columns: make(map[string][]*Column)}
	var collect func([]*Structure) error
	collect = func(nodes []*Structure) error {
		for _, node := range nodes {
			if node.Type != StructureTypeNone && node.Type != StructureTypeSchema && len(node.Children) == 0 {
				opts := &TableOptions{Schema: node.Schema, Table: node.Name, Materialization: node.Type}
				columns, err := c.GetColumns(opts)
				if err != nil {
					return fmt.Errorf("columns for %s.%s: %w", node.Schema, node.Name, err)
				}
				metadata.Columns[ColumnKey(opts)] = columns
			}
			if err := collect(node.Children); err != nil {
				return err
			}
		}
		return nil
	}
	if err := collect(structure); err != nil {
		return nil, err
	}
	return metadata, nil
}

// queryDDL bypasses user query limits and result history. SHOW CREATE in MySQL
// returns the object name first, so select its named definition column.
func (c *Connection) queryDDL(query string) (string, error) {
	rows, err := c.driver.Query(context.Background(), query)
	if err != nil {
		return "", err
	}
	defer rows.Close()
	column := 0
	for i, name := range rows.Header() {
		switch strings.ToLower(name) {
		case "ddl", "create table", "create view":
			column = i
		}
	}
	var parts []string
	for rows.HasNext() {
		row, err := rows.Next()
		if err != nil {
			return "", err
		}
		if column >= len(row) {
			return "", fmt.Errorf("DDL column is absent from query result")
		}
		var ddl string
		switch value := row[column].(type) {
		case string:
			ddl = value
		case []byte:
			ddl = string(value)
		case nil:
			continue
		default:
			return "", fmt.Errorf("expected DDL text, got %T", value)
		}
		if strings.TrimSpace(ddl) != "" {
			parts = append(parts, ddl)
		}
	}
	if len(parts) == 0 {
		return "", fmt.Errorf("no DDL returned")
	}
	return strings.Join(parts, "\n"), nil
}
