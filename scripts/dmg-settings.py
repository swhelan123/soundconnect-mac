# dmgbuild settings for the SoundConnect installer DMG (see scripts/release.sh).
#   dmgbuild -s scripts/dmg-settings.py -D app=dist/SoundConnect.app "SoundConnect" out.dmg
import os.path

app = defines["app"]  # noqa: F821  (injected by dmgbuild)
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__))) if "__file__" in globals() else "."

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join("Resources", "AppIcon.icns")  # volume icon

# 660x400 window; icon centres must match the arrow drawn by `SoundConnect --render-dmg-background`.
background = os.path.join("Resources", "dmg", "background.png")  # background@2x.png picked up for Retina
window_rect = ((200, 140), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
icon_locations = {
    os.path.basename(app): (165, 190),
    "Applications": (495, 190),
}
