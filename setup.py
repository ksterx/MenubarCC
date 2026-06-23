from setuptools import setup

APP = ["cc_menubar.py"]
DATA_FILES = ["cc-menubar-icon.png", "menubarcc_hook.py"]
OPTIONS = {
    "argv_emulation": False,
    "plist": {
        "CFBundleName": "MenubarCC",
        "CFBundleDisplayName": "MenubarCC",
        "CFBundleIdentifier": "com.ksterx.MenubarCC",
        "CFBundleVersion": "1.3.1",
        "CFBundleShortVersionString": "1.3.1",
        "LSUIElement": True,          # メニューバーのみ（Dockに出ない）
        "NSMicrophoneUsageDescription": "",
    },
    "packages": ["rumps", "PIL", "certifi"],
    "includes": ["AppKit", "Foundation", "ssl"],
    "frameworks": ["/opt/homebrew/Caskroom/miniconda/base/lib/libffi.8.dylib"],
    "iconfile": "MenubarCC.icns",
}

setup(
    app=APP,
    data_files=DATA_FILES,
    options={"py2app": OPTIONS},
    setup_requires=["py2app"],
)
