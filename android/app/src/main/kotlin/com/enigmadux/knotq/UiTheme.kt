package com.enigmadux.knotq

internal data class UiTheme(
    val isDark: Boolean,
    val bgApp: Int,
    val bgSidebar: Int,
    val bgToolbar: Int,
    val bgModal: Int,
    val rowAlt: Int,
    val rowSelected: Int,
    val buttonBg: Int,
    val divider: Int,
    val dividerSoft: Int,
    val dividerTiny: Int,
    val borderOverlay: Int,
    val textPrimary: Int,
    val textDim: Int,
    val textMuted: Int,
    val textSoft: Int,
    val textToday: Int,
    val accent: Int,
    val danger: Int,
) {
    companion object {
        private fun rgb(hex: Int): Int = rgbColor(hex)
        private fun rgba(hex: Int, alpha: Int): Int = rgbaColor(hex, alpha)

        val dark = UiTheme(
            isDark = true,
            bgApp = rgb(0x000000),
            bgSidebar = rgb(0x000000),
            bgToolbar = rgb(0x151517),
            bgModal = rgb(0x0e0e10),
            rowAlt = rgba(0xffffff, 11),
            rowSelected = rgba(0xffffff, 36),
            buttonBg = rgba(0xffffff, 24),
            divider = rgba(0xffffff, 33),
            dividerSoft = rgba(0xffffff, 20),
            dividerTiny = rgba(0xffffff, 13),
            borderOverlay = rgba(0xffffff, 41),
            textPrimary = rgb(0xf2f2f7),
            textDim = rgba(0xb4bcc4, 189),
            textMuted = rgba(0x98a0aa, 140),
            textSoft = rgba(0xd2dae2, 163),
            textToday = rgb(0xff453a),
            accent = rgb(0x7aa0ff),
            danger = rgb(0xff453a),
        )

        // Clean, near-white light theme matching knotq.com: an off-white canvas,
        // soft gray-green surfaces, near-black ink, and a rose accent. Translucent
        // rows/dividers tint with a slate-green so they read as the site's --line
        // colors over the light canvas.
        val light = UiTheme(
            isDark = false,
            bgApp = rgb(0xfafbf9),
            bgSidebar = rgb(0xf2f5f2),
            bgToolbar = rgb(0xf2f5f2),
            bgModal = rgb(0xffffff),
            rowAlt = rgba(0x3a443d, 10),
            rowSelected = rgba(0xc7375d, 31),
            buttonBg = rgba(0x3a443d, 20),
            divider = rgba(0x3a443d, 41),
            dividerSoft = rgba(0x3a443d, 28),
            dividerTiny = rgba(0x3a443d, 13),
            borderOverlay = rgba(0x3a443d, 51),
            textPrimary = rgb(0x171717),
            textDim = rgba(0x393f39, 230),
            textMuted = rgba(0x6d746d, 204),
            textSoft = rgba(0x393f39, 217),
            textToday = rgb(0xc7375d),
            accent = rgb(0xc7375d),
            danger = rgb(0xb84433),
        )
    }
}
