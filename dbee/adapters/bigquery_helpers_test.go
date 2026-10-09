package adapters

import (
	"context"
	"testing"

	"cloud.google.com/go/bigquery"
	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/stretchr/testify/require"
	"google.golang.org/api/option"
)

type bigQueryHelperAdapter struct {
	core.Adapter
	driver core.Driver
}

func (a *bigQueryHelperAdapter) Connect(string) (core.Driver, error) { return a.driver, nil }

func TestBigQueryHelpersUseConnectionProject(t *testing.T) {
	opts := &core.TableOptions{Schema: "analytics", Table: "events", Materialization: core.StructureTypeTable}
	for _, project := range []string{"first-project", "second-project"} {
		client, err := bigquery.NewClient(context.Background(), project, option.WithoutAuthentication())
		require.NoError(t, err)
		defer client.Close()
		conn, err := core.NewConnection(&core.ConnectionParams{Type: "bigquery", URL: "bigquery://" + project},
			&bigQueryHelperAdapter{Adapter: &BigQuery{}, driver: &bigQueryDriver{c: client}})
		require.NoError(t, err)
		helpers := conn.GetHelpers(opts)
		require.Equal(t, "SELECT * FROM `"+project+".analytics.events` TABLESAMPLE SYSTEM (5 PERCENT)", helpers["List"])
		require.Equal(t, "SELECT * FROM `"+project+".analytics.INFORMATION_SCHEMA.COLUMNS` WHERE TABLE_SCHEMA = 'analytics' AND TABLE_NAME = 'events'", helpers["Columns"])
		explicit := *opts
		explicit.Project = "source-project"
		require.Equal(t, "SELECT * FROM `source-project.analytics.events` TABLESAMPLE SYSTEM (5 PERCENT)", conn.GetHelpers(&explicit)["List"])
	}
	require.Empty(t, opts.Project, "helper resolution must not change the caller's options")
	require.Equal(t, "analytics", opts.Schema)
	require.Equal(t, "events", opts.Table)
}

func TestBigQueryHelpersKeepExplicitProject(t *testing.T) {
	helpers := (&BigQuery{}).GetHelpers(&core.TableOptions{Project: "source-project", Schema: "dataset", Table: "events"})
	require.Equal(t, "SELECT * FROM `source-project.dataset.events` TABLESAMPLE SYSTEM (5 PERCENT)", helpers["List"])
}
