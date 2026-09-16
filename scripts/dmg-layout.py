"""Write Finder disk-image layout; requires ds-store 1.3.3 (build tool only)."""
import sys
from pathlib import Path
from ds_store import DSStore
from mac_alias import Alias

volume = Path(sys.argv[1]).resolve()
background = Alias.for_file(str(volume / '.background' / 'background.png'))
with DSStore.open(str(volume / '.DS_Store'), 'w+') as store:
    store['.']['bwsp'] = {
        'ShowStatusBar': False, 'ShowToolbar': False, 'ShowTabView': False,
        'ShowPathbar': False, 'ShowSidebar': False, 'SidebarWidth': 0,
        'ContainerShowSidebar': False, 'WindowBounds': '{{240, 140}, {720, 460}}',
    }
    store['.']['icvp'] = {
        'viewOptionsVersion': 1, 'backgroundType': 2,
        'backgroundImageAlias': background.to_bytes(),
        'backgroundColorRed': 1.0, 'backgroundColorGreen': 1.0, 'backgroundColorBlue': 1.0,
        'scrollPositionX': 0.0, 'scrollPositionY': 0.0,
        'iconSize': 104.0, 'textSize': 14.0, 'gridSpacing': 100.0,
        'gridOffsetX': 0.0, 'gridOffsetY': 0.0, 'labelOnBottom': True,
        'showItemInfo': False, 'showIconPreview': False, 'arrangeBy': 'none',
    }
    store['.']['vSrn'] = ('long', 1)
    store['.']['icvl'] = ('type', b'icnv')
    store['UTUVO Orbit.app']['Iloc'] = (210, 226)
    store['Applications']['Iloc'] = (510, 226)
