-- switcharoo-bindings.lua — bindings to inject into the Hyprland Lua config
-- (~/.config/hypr/customisation.lua or bindings.lua), Hyprland ≥ 0.56.

-- The "Switcharoo switcher" description acts as a sentinel: the plugin checks
-- for it in `hyprctl binds` to detect that the binding is installed.
hl.unbind("ALT + TAB")
o.bind("ALT + TAB", "Switcharoo switcher", hl.dsp.global("omarchy-switcharoo:next"), { repeating = true })

hl.unbind("ALT + SHIFT + TAB")
o.bind("ALT + SHIFT + TAB", "Switcharoo switcher", hl.dsp.global("omarchy-switcharoo:previous"), { repeating = true })

hl.unbind("ALT + GRAVE")
o.bind("ALT + GRAVE", "Switcharoo switcher", hl.dsp.global("omarchy-switcharoo:previous"), { repeating = true })

hl.layer_rule({ match = { namespace = "omarchy-switcharoo" }, no_anim = true })
