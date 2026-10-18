#!/usr/bin/env python3
"""author the installer layout without driving finder or changing user preferences"""

import argparse
from pathlib import Path

from ds_store import DSStore
from mac_alias import Alias


def layout(volume):
    background = volume / ".background/background.tiff"
    if not background.is_file() or not (volume / "Fileel.app").is_dir():
        raise ValueError("the mounted installer is missing its app or artwork")
    with DSStore.open(str(volume / ".DS_Store"), "w+") as store:
        store["."]["bwsp"] = {
            "ShowStatusBar": False, "ShowTabView": False, "ShowToolbar": False,
            "ShowPathbar": False, "ShowSidebar": False, "SidebarWidth": 0,
            "ContainerShowSidebar": False, "WindowBounds": "{{160, 120}, {720, 480}}",
            "PreviewPaneVisibility": False,
        }
        store["."]["icvp"] = {
            "viewOptionsVersion": 1, "backgroundType": 2,
            "backgroundImageAlias": Alias.for_file(str(background)).to_bytes(),
            "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0,
            "iconSize": 112.0, "gridSpacing": 100.0, "gridOffsetX": 0.0, "gridOffsetY": 0.0,
            "scrollPositionX": 0.0, "scrollPositionY": 0.0,
            "textSize": 12.0, "labelOnBottom": True, "showIconPreview": True,
            "showItemInfo": False, "arrangeBy": "none",
        }
        store["."]["vSrn"] = ("long", 1)
        store["."]["vstl"] = ("type", b"icnv")
        store["Fileel.app"]["Iloc"] = (208, 247)
        store["Applications"]["Iloc"] = (512, 247)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("volume", type=Path)
    layout(parser.parse_args().volume.resolve())
