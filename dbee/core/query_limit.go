package core

import "strings"

// withDefaultQueryLimit limits SELECT statements on databases supporting LIMIT.
// Explicit limits, write statements and non-SQL commands are left unchanged.
func withDefaultQueryLimit(query, databaseType string) string {
	switch databaseType {
	case "postgres", "postgresql", "pg", "mysql", "sqlite", "sqlite3",
		"duck", "duckdb", "clickhouse", "bigquery", "redshift", "databricks":
	default:
		return query
	}

	tokens, ok := queryLimitTokens(query)
	if !ok {
		return query // Let the database report malformed SQL without rewriting it.
	}

	var out strings.Builder
	previous, start := 0, 0
	for i := 0; i <= len(tokens); i++ {
		if i < len(tokens) && tokens[i].word != ";" {
			continue
		}
		statement := tokens[start:i]
		start = i + 1
		position, beforeClause := queryLimitPosition(statement)
		if position < 0 {
			continue
		}
		out.WriteString(query[previous:position])
		if beforeClause {
			out.WriteString("LIMIT 100 ")
		} else {
			out.WriteString(" LIMIT 100")
		}
		previous = position
	}
	if previous == 0 {
		return query
	}
	out.WriteString(query[previous:])
	return out.String()
}

type queryLimitToken struct {
	word       string
	start, end int
}

func queryLimitPosition(tokens []queryLimitToken) (int, bool) {
	if len(tokens) == 0 {
		return -1, false
	}
	command := tokens[0].word
	if command == "WITH" {
		for _, token := range tokens[1:] {
			switch token.word {
			case "SELECT", "INSERT", "UPDATE", "DELETE", "MERGE":
				command = token.word
			}
			if command != "WITH" {
				break
			}
		}
	}
	if command != "SELECT" {
		return -1, false
	}
	position, beforeClause := tokens[len(tokens)-1].end, false
	for _, token := range tokens {
		switch token.word {
		case "LIMIT", "FETCH", "TOP", "INTO":
			return -1, false
		case "OFFSET", "FOR", "FORMAT", "SETTINGS":
			if !beforeClause {
				position, beforeClause = token.start, true
			}
		}
	}
	return position, beforeClause
}

// queryLimitTokens collects only outer SQL tokens. Quoted values, identifiers,
// comments and nested queries cannot masquerade as an outer LIMIT clause.
func queryLimitTokens(query string) ([]queryLimitToken, bool) {
	var tokens []queryLimitToken
	depth := 0
	for i := 0; i < len(query); {
		start, word := i, ""
		switch {
		case strings.ContainsRune(" \t\r\n\f", rune(query[i])):
			i++
			continue
		case strings.HasPrefix(query[i:], "--"):
			for i < len(query) && query[i] != '\n' {
				i++
			}
			continue
		case strings.HasPrefix(query[i:], "/*"):
			i += 2
			comments := 1
			for i < len(query) && comments > 0 {
				switch {
				case strings.HasPrefix(query[i:], "/*"):
					comments++
					i += 2
				case strings.HasPrefix(query[i:], "*/"):
					comments--
					i += 2
				default:
					i++
				}
			}
			if comments != 0 {
				return nil, false
			}
			continue
		case query[i] == '\'' || query[i] == '"' || query[i] == '`':
			quote := query[i]
			i++
			closed := false
			for i < len(query) {
				if query[i] == '\\' {
					i += 2
				} else if query[i] == quote {
					i++
					if i < len(query) && query[i] == quote {
						i++
						continue
					}
					closed = true
					break
				} else {
					i++
				}
			}
			if !closed {
				return nil, false
			}
		case query[i] == '$':
			end := i + 1
			for end < len(query) && queryLimitWordByte(query[end]) && query[end] != '$' {
				end++
			}
			if end < len(query) && query[end] == '$' {
				delimiter := query[i : end+1]
				close := strings.Index(query[end+1:], delimiter)
				if close < 0 {
					return nil, false
				}
				i = end + 1 + close + len(delimiter)
			} else {
				i++
			}
		case query[i] == '(':
			depth++
			i++
			continue
		case query[i] == ')':
			depth--
			if depth < 0 {
				return nil, false
			}
			i++
		case queryLimitWordByte(query[i]):
			for i < len(query) && queryLimitWordByte(query[i]) {
				i++
			}
			word = strings.ToUpper(query[start:i])
		default:
			if query[i] == ';' {
				word = ";"
			}
			i++
		}
		if depth == 0 {
			tokens = append(tokens, queryLimitToken{word: word, start: start, end: i})
		}
	}
	return tokens, depth == 0
}

func queryLimitWordByte(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' ||
		c >= '0' && c <= '9' || c == '_' || c == '$' || c >= 128
}
