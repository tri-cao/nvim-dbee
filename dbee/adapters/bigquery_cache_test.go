package adapters

import (
	"math/big"
	"testing"
	"time"

	"cloud.google.com/go/bigquery"
	"cloud.google.com/go/civil"
	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/kndndrj/nvim-dbee/dbee/core/mock"
	"github.com/stretchr/testify/require"
)

func TestBigQueryValuesDiskCache(t *testing.T) {
	date := civil.Date{Year: 2026, Month: time.October, Day: 9}
	clock := civil.Time{Hour: 12, Minute: 34, Second: 56}
	row := core.Row{
		[]bigquery.Value{"array value", int64(42), nil, []bigquery.Value{true}},
		big.NewRat(12345, 100),
		date,
		clock,
		civil.DateTime{Date: date, Time: clock},
		&bigquery.IntervalValue{Years: 1, Days: 2, Hours: 3},
		&bigquery.RangeValue{Start: date, End: civil.Date{Year: 2027, Month: time.January, Day: 1}},
	}
	result := new(core.Result)
	t.Cleanup(result.Wipe)
	require.NoError(t, result.SetIter(mock.NewResultStream([]core.Row{row}), nil))
	got, err := result.Rows(0, -1)
	require.NoError(t, err)
	require.Equal(t, []core.Row{row}, got)
}
