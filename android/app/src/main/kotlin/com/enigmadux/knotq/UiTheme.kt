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

        val moonlit = dark.copy(bgApp = rgb(0x191724), bgSidebar = rgb(0x1f1d2e), bgToolbar = rgb(0x26233a), bgModal = rgb(0x26233a), accent = rgb(0xc4a7e7), textPrimary = rgb(0xe0def4), textSoft = rgb(0x908caa), textDim = rgb(0x9893a5), textMuted = rgb(0x6e6a86), textToday = rgb(0xc4a7e7))
        val espresso = dark.copy(bgApp = rgb(0x1e1e2e), bgSidebar = rgb(0x181825), bgToolbar = rgb(0x313244), bgModal = rgb(0x313244), accent = rgb(0xf5c2e7), textPrimary = rgb(0xcdd6f4), textSoft = rgb(0xa6adc8), textDim = rgb(0xbac2de), textMuted = rgb(0x7f849c), textToday = rgb(0xf5c2e7))
        val blueHour = dark.copy(bgApp = rgb(0x1a1b26), bgSidebar = rgb(0x16161e), bgToolbar = rgb(0x24283b), bgModal = rgb(0x24283b), accent = rgb(0x7aa2f7), textPrimary = rgb(0xc0caf5), textSoft = rgb(0xa9b1d6), textDim = rgb(0x9aa5ce), textMuted = rgb(0x565f89), textToday = rgb(0x7aa2f7))
        val parchment = light.copy(bgApp = rgb(0xf4eddf), bgSidebar = rgb(0xebe1cf), bgToolbar = rgb(0xe4d6bf), bgModal = rgb(0xfff9ed), accent = rgb(0xa66a00), textPrimary = rgb(0x3c3024), textSoft = rgb(0x6b5b48), textDim = rgb(0x665542), textMuted = rgb(0x887763), textToday = rgb(0xa66a00))
        val dawn = light.copy(bgApp = rgb(0xfaf4ed), bgSidebar = rgb(0xf2e9df), bgToolbar = rgb(0xece0d3), bgModal = rgb(0xfffaf3), accent = rgb(0x907aa9), textPrimary = rgb(0x575279), textSoft = rgb(0x797593), textDim = rgb(0x6e6a86), textMuted = rgb(0x9893a5), textToday = rgb(0x907aa9))
        val cream = light.copy(bgApp = rgb(0xeff1f5), bgSidebar = rgb(0xe6e9ef), bgToolbar = rgb(0xdce0e8), bgModal = rgb(0xffffff), accent = rgb(0x1e66f5), textPrimary = rgb(0x4c4f69), textSoft = rgb(0x6c6f85), textDim = rgb(0x5c5f77), textMuted = rgb(0x8c8fa1), textToday = rgb(0x1e66f5))
    }
}
