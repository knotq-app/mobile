package com.enigmadux.knotq

import android.widget.EditText

/// The floating inline table-cell editor currently shown, with everything
/// needed to commit its per-line diff back to the core.
internal class ActiveCellEdit(
    val editor: SchemeEditText,
    val field: EditText,
    val schemeId: String,
    val itemId: String,
    val hit: TableCellHit,
    val oldLines: List<String>,
)

internal enum class TableStructureAction {
    INSERT_ROW_ABOVE,
    INSERT_ROW_BELOW,
    DELETE_ROW,
    INSERT_COLUMN_LEFT,
    INSERT_COLUMN_RIGHT,
    DELETE_COLUMN
}
