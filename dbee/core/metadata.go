package core

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
)

// Metadata is a complete snapshot of the structure and columns of a database.
type Metadata struct {
	Structure []*Structure
	Columns   map[string][]*Column
}

// MetadataDriver can collect schemas more efficiently than individual Columns calls.
type MetadataDriver interface {
	Metadata() (*Metadata, error)
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
	if driver, ok := c.driver.(MetadataDriver); ok {
		return driver.Metadata()
	}
	structure, err := c.GetStructure()
	if err != nil {
		return nil, err
	}
	metadata := &Metadata{Structure: structure, Columns: make(map[string][]*Column)}
	var collect func([]*Structure) error
	collect = func(nodes []*Structure) error {
		for _, node := range nodes {
			if node.Type == StructureTypeTable || node.Type == StructureTypeView {
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
