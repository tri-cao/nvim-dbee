package adapters

import "strings"

func ddlLiteral(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "''") + "'"
}

func ddlIdentifier(value, quote string) string {
	return quote + strings.ReplaceAll(value, quote, quote+quote) + quote
}

func ddlQualified(schema, table, quote string) string {
	if schema == "" {
		return ddlIdentifier(table, quote)
	}
	return ddlIdentifier(schema, quote) + "." + ddlIdentifier(table, quote)
}
