package core

import "fmt"

// MetadataNode identifies one level of the drawer's database structure.
type MetadataNode struct {
	Name   string `msgpack:"name"`
	Schema string `msgpack:"schema"`
	Type   string `msgpack:"type"`
}

// MetadataScope selects a subtree, from the connection's root to the selected node.
type MetadataScope struct {
	Path   []MetadataNode `msgpack:"path"`
	NodeID string         `msgpack:"node_id"`
}

// ScopedStructureDriver can list just the selected subtree and its ancestors.
type ScopedStructureDriver interface {
	StructureScope(path []MetadataNode) ([]*Structure, error)
}

// StructureMetadataDriver retains optimized column collection for scoped refreshes.
type StructureMetadataDriver interface {
	MetadataForStructure(structure []*Structure) (*Metadata, error)
}

type ScopedDDLMetadataDriver interface {
	MetadataDDLScope(structure []*Structure) (map[string]string, error)
}

func matchesMetadataNode(node *Structure, target MetadataNode) bool {
	return node.Name == target.Name && node.Schema == target.Schema && node.Type.String() == target.Type
}

// metadataSubtree keeps the ancestor chain so batch DDL drivers still see schemas.
func metadataSubtree(nodes []*Structure, path []MetadataNode) []*Structure {
	if len(path) == 0 {
		return nodes
	}
	for _, node := range nodes {
		if matchesMetadataNode(node, path[0]) {
			copy := *node
			copy.Children = metadataSubtree(node.Children, path[1:])
			return []*Structure{&copy}
		}
	}
	return nil
}

// GetMetadataScope fetches columns and DDL only for the selected subtree.
func (c *Connection) GetMetadataScope(scope *MetadataScope) (*Metadata, error) {
	if scope == nil || len(scope.Path) == 0 {
		return c.GetMetadata()
	}
	var structure []*Structure
	var err error
	if driver, ok := c.driver.(ScopedStructureDriver); ok {
		structure, err = driver.StructureScope(scope.Path)
	} else {
		structure, err = c.GetStructure()
	}
	if err != nil {
		return nil, err
	}
	structure = metadataSubtree(structure, scope.Path)
	var snapshot *Metadata
	if driver, ok := c.driver.(StructureMetadataDriver); ok {
		snapshot, err = driver.MetadataForStructure(structure)
	} else {
		snapshot, err = c.columnsForStructure(structure)
	}
	if err != nil {
		return nil, err
	}
	if snapshot == nil || snapshot.Columns == nil {
		return nil, fmt.Errorf("incomplete metadata snapshot")
	}
	if driver, ok := c.driver.(ScopedDDLMetadataDriver); ok && snapshot.DDL == nil {
		snapshot.DDL, err = driver.MetadataDDLScope(snapshot.Structure)
		return snapshot, err
	}
	return c.collectDDL(snapshot)
}

// MergeMetadataScope replaces a subtree without mutating the previous snapshot.
func MergeMetadataScope(previous, fresh *Metadata, path []MetadataNode) *Metadata {
	merged := &Metadata{Columns: make(map[string][]*Column), DDL: make(map[string]string)}
	for key, columns := range previous.Columns {
		merged.Columns[key] = columns
	}
	for key, ddl := range previous.DDL {
		merged.DDL[key] = ddl
	}
	var remove func([]*Structure)
	remove = func(nodes []*Structure) {
		for _, node := range nodes {
			key := ColumnKey(&TableOptions{Schema: node.Schema, Table: node.Name, Materialization: node.Type})
			delete(merged.Columns, key)
			delete(merged.DDL, key)
			remove(node.Children)
		}
	}
	var replace func([]*Structure, []*Structure, []MetadataNode) []*Structure
	replace = func(old, next []*Structure, remaining []MetadataNode) []*Structure {
		if len(remaining) == 0 {
			remove(old)
			return next
		}
		var replacement *Structure
		for _, node := range next {
			if matchesMetadataNode(node, remaining[0]) {
				replacement = node
				break
			}
		}
		nodes := make([]*Structure, 0, len(old))
		found := false
		for _, node := range old {
			if !matchesMetadataNode(node, remaining[0]) {
				nodes = append(nodes, node)
				continue
			}
			found = true
			if len(remaining) == 1 {
				remove([]*Structure{node})
				if replacement != nil {
					nodes = append(nodes, replacement)
				}
			} else {
				copy := *node
				var children []*Structure
				if replacement != nil {
					children = replacement.Children
				}
				copy.Children = replace(node.Children, children, remaining[1:])
				nodes = append(nodes, &copy)
			}
		}
		if !found && replacement != nil {
			nodes = append(nodes, replacement)
		}
		return nodes
	}
	merged.Structure = replace(previous.Structure, fresh.Structure, path)
	for key, columns := range fresh.Columns {
		merged.Columns[key] = columns
	}
	for key, ddl := range fresh.DDL {
		merged.DDL[key] = ddl
	}
	return merged
}
