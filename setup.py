import sys
from pathlib import Path

from setuptools import setup

# Resolve dylibs relative to the Python that's running this build.
# Works whether miniconda lives in /opt/homebrew/Caskroom/miniconda/base,
# /opt/miniconda3, or anywhere else.
PY_LIB = Path(sys.executable).resolve().parent.parent / "lib"

APP = ["cc_menubar.py"]
DATA_FILES = ["cc-menubar-icon.png", "menubarcc_hook.py"]
OPTIONS = {
    "argv_emulation": False,
    "plist": {
        "CFBundleName": "MenubarCC",
        "CFBundleDisplayName": "MenubarCC",
        "CFBundleIdentifier": "com.ksterx.MenubarCC",
        "CFBundleVersion": "1.6.2",
        "CFBundleShortVersionString": "1.6.2",
        "LSUIElement": True,          # メニューバーのみ（Dockに出ない）
        "NSMicrophoneUsageDescription": "",
    },
    "packages": ["rumps", "PIL", "certifi", "ServiceManagement"],
    "includes": ["AppKit", "Foundation", "ssl"],
    "frameworks": [
        str(PY_LIB / "libffi.8.dylib"),
        str(PY_LIB / "libssl.3.dylib"),
        str(PY_LIB / "libcrypto.3.dylib"),
        # pyexpat.so (used by plistlib at startup) links @rpath/libexpat.1.dylib;
        # py2app doesn't pull it in automatically, so bundle it or the app crashes
        # on launch with "Symbol not found: _XML_SetHashSalt16Bytes".
        str(PY_LIB / "libexpat.1.dylib"),
    ],
    "iconfile": "MenubarCC.icns",
}

setup(
    app=APP,
    data_files=DATA_FILES,
    options={"py2app": OPTIONS},
    setup_requires=["py2app"],
)
