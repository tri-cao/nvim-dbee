package handler

import (
	"errors"
	"fmt"

	"github.com/kndndrj/nvim-dbee/dbee/core"
)

// refreshQueryMetadata runs on the call's event goroutine, after successful
// execution and result retrieval. Each query keeps its own refresh: coalescing
// it with an older in-flight job could miss a change committed by this query.
func (h *Handler) refreshQueryMetadata(c *core.Connection, changes []core.MetadataChange) {
	id := c.GetID()
	snapshot, err := h.connectionMetadata(c, false)
	if err != nil {
		h.events.MetadataRefreshStateChanged(id, nil, false, fmt.Errorf("load metadata after query: %w", err))
		return
	}
	for _, scope := range c.MetadataChangesScopes(changes, snapshot.Structure) {
		h.events.MetadataRefreshStateChanged(id, scope, true, nil)
		_, err := h.connectionMetadata(c, true, scope)
		if err == nil && len(scope.Path) == 0 {
			// New/dropped databases also invalidate the database selector.
			h.metadataDatabases.Delete(c.MetadataCacheKey())
			var current string
			var available []string
			current, available, err = c.ListDatabases()
			if errors.Is(err, core.ErrDatabaseSwitchingNotSupported) {
				err = nil
			}
			if err == nil {
				h.metadataDatabases.Store(c.MetadataCacheKey(), metadataDatabases{current, available})
			}
		}
		if err != nil {
			err = fmt.Errorf("refresh metadata after query: %w", err)
		}
		h.events.MetadataRefreshStateChanged(id, scope, false, err)
	}
}
