# dmgbuild layout for Throwcast.dmg. Paths come from build-dmg.sh with -D.
import os

app = defines['app']
staging = defines['staging']

files = [app, os.path.join(staging, 'Browser Extension'), os.path.join(staging, 'Read Me First.txt')]
symlinks = {'Applications': '/Applications'}
icon = os.path.join(app, 'Contents/Resources/AppIcon.icns')
badge_icon = None
background = defines['background']

format = 'UDZO'
window_rect = ((200, 120), (640, 520))
default_view = 'icon-view'
show_toolbar = show_tab_view = show_status_bar = show_pathbar = show_sidebar = False
icon_size = 96
# "Throwcast", not "Throwcast.app".
hide_extensions = [os.path.basename(app)]
text_size = 13
icon_locations = {
    os.path.basename(app): (170, 200),
    'Applications': (470, 200),
    'Browser Extension': (250, 352),
    'Read Me First.txt': (390, 352),
}
