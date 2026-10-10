package core

import "strings"

// MetadataChange describes the smallest subtree a SQL statement can change.
// An empty name means the statement needs a complete connection refresh.
type MetadataChange struct {
	Name   []string
	Parent bool
}

type metadataToken struct {
	text   string
	quoted bool
}

func (t metadataToken) is(word string) bool {
	return !t.quoted && strings.EqualFold(t.text, word)
}

// metadataStatements tokenizes just enough SQL to locate DDL targets. Literals,
// comments and routine bodies cannot introduce statements or DDL keywords.
func metadataStatements(sql string) [][]metadataToken {
	var statements [][]metadataToken
	var tokens []metadataToken
	for i := 0; i < len(sql); {
		ch := sql[i]
		switch {
		case ch <= ' ':
			i++
		case strings.HasPrefix(sql[i:], "--") || ch == '#':
			for i < len(sql) && sql[i] != '\n' {
				i++
			}
		case strings.HasPrefix(sql[i:], "/*"):
			i += 2
			depth := 1
			for i < len(sql) && depth > 0 {
				if strings.HasPrefix(sql[i:], "/*") {
					depth++
					i += 2
				} else if strings.HasPrefix(sql[i:], "*/") {
					depth--
					i += 2
				} else {
					i++
				}
			}
		case ch == '\'' || ch == '"' || ch == '`' || ch == '[':
			end := ch
			if ch == '[' {
				end = ']'
			}
			i++
			var value strings.Builder
			for i < len(sql) {
				if sql[i] == end {
					i++
					if i < len(sql) && sql[i] == end {
						value.WriteByte(end)
						i++
						continue
					}
					break
				}
				if sql[i] == '\\' && ch == '\'' && i+1 < len(sql) {
					i++
				}
				value.WriteByte(sql[i])
				i++
			}
			if ch == '\'' {
				tokens = append(tokens, metadataToken{quoted: true})
			} else if ch == '`' {
				// BigQuery quotes the entire project.dataset.table path.
				for n, part := range strings.Split(value.String(), ".") {
					if n > 0 {
						tokens = append(tokens, metadataToken{text: "."})
					}
					tokens = append(tokens, metadataToken{text: part, quoted: true})
				}
			} else {
				tokens = append(tokens, metadataToken{text: value.String(), quoted: true})
			}
		case ch == '$':
			j := i + 1
			for j < len(sql) && (sql[j] == '_' || sql[j] >= 'a' && sql[j] <= 'z' || sql[j] >= 'A' && sql[j] <= 'Z' || sql[j] >= '0' && sql[j] <= '9') {
				j++
			}
			if j < len(sql) && sql[j] == '$' {
				tag := sql[i : j+1]
				if end := strings.Index(sql[j+1:], tag); end >= 0 {
					i = j + 1 + end + len(tag)
					tokens = append(tokens, metadataToken{quoted: true})
					continue
				}
			}
			tokens = append(tokens, metadataToken{text: "$"})
			i++
		case ch == ';':
			if len(tokens) > 0 {
				statements = append(statements, tokens)
			}
			tokens = nil
			i++
		case strings.ContainsRune(".,()=", rune(ch)):
			tokens = append(tokens, metadataToken{text: string(ch)})
			i++
		default:
			start := i
			for i < len(sql) && sql[i] > ' ' && !strings.ContainsRune(";.,()='\"`[$#", rune(sql[i])) && !strings.HasPrefix(sql[i:], "--") && !strings.HasPrefix(sql[i:], "/*") {
				i++
			}
			tokens = append(tokens, metadataToken{text: sql[start:i]})
		}
	}
	if len(tokens) > 0 {
		statements = append(statements, tokens)
	}
	return statements
}

// QueryMetadataChanges ignores data-only statements and returns conservative
// connection refreshes for DDL whose target cannot be resolved safely.
func QueryMetadataChanges(query string) []MetadataChange {
	var changes []MetadataChange
	for _, tokens := range metadataStatements(query) {
		verb := strings.ToUpper(tokens[0].text)
		if tokens[0].quoted {
			continue
		}
		switch verb {
		case "CREATE", "ALTER", "DROP", "RENAME", "TRUNCATE", "COMMENT", "GRANT", "REVOKE", "ATTACH", "DETACH":
		default:
			continue
		}
		change := MetadataChange{}
		i := 1
		for i < len(tokens) && (tokens[i].is("OR") || tokens[i].is("REPLACE") || tokens[i].is("TEMP") || tokens[i].is("TEMPORARY") || tokens[i].is("EXTERNAL") || tokens[i].is("MATERIALIZED") || tokens[i].is("STREAMING") || tokens[i].is("UNIQUE") || tokens[i].is("LIVE")) {
			i++
		}
		if verb == "COMMENT" && i < len(tokens) && tokens[i].is("ON") {
			i++
		}
		if i < len(tokens) && (tokens[i].is("TABLE") || tokens[i].is("VIEW") || tokens[i].is("COLUMN") || tokens[i].is("INDEX")) {
			kind := tokens[i]
			i++
			change.Parent = verb == "CREATE" || verb == "RENAME"
			if kind.is("INDEX") {
				// Indexes are stored with their owning table, not as tree nodes.
				for i < len(tokens) && !tokens[i].is("ON") {
					i++
				}
				i++
				change.Parent = false
			}
			for i < len(tokens) && (tokens[i].is("IF") || tokens[i].is("NOT") || tokens[i].is("EXISTS") || tokens[i].is("ONLY")) {
				i++
			}
			for i < len(tokens) && tokens[i].text != "" && (tokens[i].quoted || !strings.ContainsAny(tokens[i].text, "(),=;")) {
				change.Name = append(change.Name, tokens[i].text)
				i++
				if i >= len(tokens) || !tokens[i].is(".") {
					break
				}
				i++
			}
			if kind.is("COLUMN") && len(change.Name) > 0 {
				change.Name = change.Name[:len(change.Name)-1]
			}
			// Multiple targets, cascades and moves can affect other subtrees.
			for j := i; j < len(tokens); j++ {
				if tokens[j].is("TO") && j > i && tokens[j-1].is("RENAME") {
					change.Parent = true
				}
				if tokens[j].is("CASCADE") || tokens[j].is("SCHEMA") || j == i && tokens[j].is(",") {
					change.Name = nil
					break
				}
			}
			if verb == "RENAME" {
				change.Name = nil
			}
		}
		changes = append(changes, change)
	}
	return changes
}

// MetadataChangesScopes accounts for project-qualified BigQuery identifiers.
// References to a different project cannot be matched to this connection's tree.
func (c *Connection) MetadataChangesScopes(changes []MetadataChange, structure []*Structure) []*MetadataScope {
	if c.GetType() == "bigquery" {
		resolved := append([]MetadataChange(nil), changes...)
		for i, change := range resolved {
			if len(change.Name) == 3 {
				project, ok := c.driver.(ProjectIDProvider)
				if !ok || project.ProjectID() != change.Name[0] {
					resolved[i].Name = nil
				} else {
					resolved[i].Name = change.Name[1:]
				}
			}
		}
		changes = resolved
	}
	return MetadataChangeScopes(changes, structure, c.GetID())
}

// MetadataChangeScopes resolves SQL names against the cached tree. Ambiguous
// names refresh the connection, since the session's search path may differ.
func MetadataChangeScopes(changes []MetadataChange, structure []*Structure, connID ConnectionID) []*MetadataScope {
	var scopes []*MetadataScope
	for _, change := range changes {
		if len(change.Name) == 0 {
			return []*MetadataScope{{}}
		}
		name := change.Name[len(change.Name)-1]
		qualifier := strings.Join(change.Name[:len(change.Name)-1], ".")
		var matches [][]MetadataNode
		var walk func([]*Structure, []MetadataNode)
		walk = func(nodes []*Structure, path []MetadataNode) {
			for _, node := range nodes {
				next := append(append([]MetadataNode(nil), path...), MetadataNode{Name: node.Name, Schema: node.Schema, Type: node.Type.String()})
				qualified := qualifier == "" || strings.EqualFold(node.Schema, qualifier) || len(path) > 0 && strings.EqualFold(path[len(path)-1].Name, qualifier)
				if node.Type != StructureTypeSchema && node.Type != StructureTypeNone && strings.EqualFold(node.Name, name) && qualified {
					if change.Parent {
						matches = append(matches, path)
					} else {
						matches = append(matches, next)
					}
				}
				walk(node.Children, next)
			}
		}
		walk(structure, nil)
		if len(matches) == 0 && change.Parent {
			var containers func([]*Structure, []MetadataNode)
			containers = func(nodes []*Structure, path []MetadataNode) {
				for _, node := range nodes {
					next := append(append([]MetadataNode(nil), path...), MetadataNode{Name: node.Name, Schema: node.Schema, Type: node.Type.String()})
					container := node.Type == StructureTypeSchema || node.Type == StructureTypeNone && (node.Schema != "" || len(node.Children) > 0)
					if container && (qualifier == "" || strings.EqualFold(node.Name, qualifier) || strings.EqualFold(node.Schema, qualifier)) {
						matches = append(matches, next)
					}
					containers(node.Children, next)
				}
			}
			containers(structure, nil)
		}
		if len(matches) != 1 || len(matches[0]) == 0 {
			return []*MetadataScope{{}}
		}
		scope := &MetadataScope{Path: matches[0], NodeID: string(connID)}
		for _, node := range scope.Path {
			scope.NodeID += "__connection_" + node.Name + node.Schema + node.Type + "__"
		}
		// A parent refresh already covers all changes below it.
		covered := false
		for i := 0; i < len(scopes); {
			if metadataPathContains(scopes[i].Path, scope.Path) {
				covered = true
				break
			}
			if metadataPathContains(scope.Path, scopes[i].Path) {
				scopes = append(scopes[:i], scopes[i+1:]...)
			} else {
				i++
			}
		}
		if !covered {
			scopes = append(scopes, scope)
		}
	}
	return scopes
}

func metadataPathContains(parent, child []MetadataNode) bool {
	if len(parent) > len(child) {
		return false
	}
	for i := range parent {
		if parent[i] != child[i] {
			return false
		}
	}
	return true
}
