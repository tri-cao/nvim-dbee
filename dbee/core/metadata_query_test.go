package core

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestQueryMetadataChanges(t *testing.T) {
	for _, test := range []struct {
		query string
		want  []MetadataChange
	}{
		{`SELECT 'CREATE TABLE users; ALTER TABLE users'; -- DROP SCHEMA public`, nil},
		{`INSERT INTO users VALUES ('DROP TABLE users;'); UPDATE users SET name = 'ALTER'; DELETE FROM users`, nil},
		{`/* nested /* ALTER TABLE fake */ comment */ CREATE TABLE IF NOT EXISTS public.users (id int)`, []MetadataChange{{Name: []string{"public", "users"}, Parent: true}}},
		{"CREATE OR REPLACE MATERIALIZED VIEW `project.dataset.view` AS SELECT 1", []MetadataChange{{Name: []string{"project", "dataset", "view"}, Parent: true}}},
		{`ALTER TABLE ONLY "public"."user's (data)" ADD COLUMN email text`, []MetadataChange{{Name: []string{"public", "user's (data)"}}}},
		{`ALTER TABLE [public].[users] RENAME COLUMN name TO full_name`, []MetadataChange{{Name: []string{"public", "users"}}}},
		{`ALTER TABLE users RENAME TO people`, []MetadataChange{{Name: []string{"users"}, Parent: true}}},
		{`ALTER TABLE users SET SCHEMA private`, []MetadataChange{{}}},
		{`CREATE UNIQUE INDEX users_id ON public.users (id)`, []MetadataChange{{Name: []string{"public", "users"}}}},
		{`COMMENT ON COLUMN public.users.name IS 'hi; DROP TABLE users'`, []MetadataChange{{Name: []string{"public", "users"}}}},
		{`DROP TABLE IF EXISTS public.users`, []MetadataChange{{Name: []string{"public", "users"}}}},
		{`DROP TABLE users, events`, []MetadataChange{{}}},
		{`DROP TABLE users CASCADE`, []MetadataChange{{}}},
		{`TRUNCATE TABLE public.users`, []MetadataChange{{Name: []string{"public", "users"}}}},
		{`RENAME TABLE users TO people`, []MetadataChange{{Parent: true}}},
		{`CREATE DATABASE warehouse; CREATE SCHEMA public; CREATE DATASET analytics`, []MetadataChange{{}, {}, {}}},
		{`DROP INDEX users_id; GRANT SELECT ON users TO reader`, []MetadataChange{{}, {}}},
		{`CREATE FUNCTION f() RETURNS void AS $body$ BEGIN ALTER TABLE fake ADD x int; END $body$ LANGUAGE plpgsql; SELECT 1`, []MetadataChange{{}}},
		{`SELECT $$; CREATE TABLE fake$$; ALTER TABLE users ADD email text; CREATE TABLE events (id int)`, []MetadataChange{{Name: []string{"users"}}, {Name: []string{"events"}, Parent: true}}},
	} {
		t.Run(test.query, func(t *testing.T) {
			require.Equal(t, test.want, QueryMetadataChanges(test.query))
		})
	}
}

func TestMetadataChangeScopes(t *testing.T) {
	structure := []*Structure{
		{Name: "public", Schema: "public", Type: StructureTypeSchema, Children: []*Structure{
			{Name: "users", Schema: "public", Type: StructureTypeTable},
			{Name: "events", Schema: "public", Type: StructureTypeTable},
		}},
		{Name: "private", Schema: "private", Type: StructureTypeSchema, Children: []*Structure{
			{Name: "users", Schema: "private", Type: StructureTypeTable},
		}},
	}
	for _, test := range []struct {
		query string
		paths [][]string
	}{
		{`SELECT 1`, nil},
		{`CREATE TABLE public.new_table (id int)`, [][]string{{"public"}}},
		{`ALTER TABLE public.users ADD email text`, [][]string{{"public", "users"}}},
		{`DROP TABLE public.users`, [][]string{{"public", "users"}}},
		{`ALTER TABLE public.users RENAME TO people`, [][]string{{"public"}}},
		{`CREATE SCHEMA analytics`, [][]string{{}}},
		{`ALTER TABLE users ADD email text`, [][]string{{}}},
		{`ALTER TABLE missing ADD email text`, [][]string{{}}},
		{`CREATE TABLE new_table (id int)`, [][]string{{}}},
		{`ALTER TABLE public.users ADD email text; ALTER TABLE public.events ADD name text`, [][]string{{"public", "users"}, {"public", "events"}}},
		{`ALTER TABLE public.users ADD email text; CREATE TABLE public.new_table (id int)`, [][]string{{"public"}}},
		{`CREATE TABLE public.new_table (id int); ALTER TABLE public.users ADD email text`, [][]string{{"public"}}},
		{`ALTER TABLE public.users ADD email text; ALTER TABLE public.users ADD name text`, [][]string{{"public", "users"}}},
	} {
		t.Run(test.query, func(t *testing.T) {
			scopes := MetadataChangeScopes(QueryMetadataChanges(test.query), structure, "conn")
			var paths [][]string
			for _, scope := range scopes {
				path := []string{}
				wantID := "conn"
				for _, node := range scope.Path {
					path = append(path, node.Name)
					wantID += "__connection_" + node.Name + node.Schema + node.Type + "__"
				}
				paths = append(paths, path)
				if len(scope.Path) > 0 {
					require.Equal(t, wantID, scope.NodeID, "progress must target the drawer node")
				}
			}
			require.Equal(t, test.paths, paths)
		})
	}
	// Untyped BigQuery dataset nodes, including an empty dataset, are containers.
	dataset := []*Structure{{Name: "analytics", Schema: "analytics", Children: []*Structure{{Name: "users", Schema: "analytics", Type: StructureTypeTable}}}}
	scopes := MetadataChangeScopes(QueryMetadataChanges("CREATE TABLE analytics.events (id int)"), dataset, "conn")
	require.Len(t, scopes, 1)
	require.Equal(t, []MetadataNode{{Name: "analytics", Schema: "analytics"}}, scopes[0].Path)
	dataset[0].Children = nil
	scopes = MetadataChangeScopes(QueryMetadataChanges("CREATE TABLE analytics.events (id int)"), dataset, "conn")
	require.Equal(t, []MetadataNode{{Name: "analytics", Schema: "analytics"}}, scopes[0].Path)
	// An empty connection's UI placeholder is not a real schema to refresh.
	scopes = MetadataChangeScopes(QueryMetadataChanges("CREATE TABLE first_table (id int)"), []*Structure{{Name: "no schema to show"}}, "conn")
	require.Len(t, scopes, 1)
	require.Empty(t, scopes[0].Path)
}

type queryMetadataProjectDriver struct {
	metadataTestDriver
}

func (*queryMetadataProjectDriver) ProjectID() string { return "my-project" }

func TestProjectQualifiedQueryMetadataScopes(t *testing.T) {
	c := &Connection{params: &ConnectionParams{ID: "conn", Type: "bigquery"}, driver: &queryMetadataProjectDriver{}}
	structure := []*Structure{{Name: "analytics", Schema: "analytics", Children: []*Structure{{Name: "users", Schema: "analytics", Type: StructureTypeTable}}}}
	for _, test := range []struct {
		query string
		depth int
	}{
		{"CREATE TABLE `my-project.analytics.new_table` (id INT64)", 1},
		{"ALTER TABLE `my-project.analytics.users` ADD COLUMN name STRING", 2},
		{"CREATE SCHEMA `my-project.new_dataset`", 0},
		{"ALTER TABLE `other-project.analytics.users` ADD COLUMN name STRING", 0},
	} {
		t.Run(test.query, func(t *testing.T) {
			scopes := c.MetadataChangesScopes(QueryMetadataChanges(test.query), structure)
			require.Len(t, scopes, 1)
			require.Len(t, scopes[0].Path, test.depth)
		})
	}
}
