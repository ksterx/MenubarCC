from setuptools import setup

APP = ["cc_menubar.py"]
DATA_FILES = []
OPTIONS = {
    "argv_emulation": False,
    "plist": {
        "CFBundleName": "CC Monitor",
        "CFBundleDisplayName": "CC Monitor",
        "CFBundleIdentifier": "com.ksterx.cc-monitor",
        "CFBundleVersion": "1.0.0",
        "CFBundleShortVersionString": "1.0",
        "LSUIElement": True,          # メニューバーのみ（Dockに出ない）
        "NSMicrophoneUsageDescription": "",
    },
    "packages": ["rumps", "PIL"],
    "includes": ["AppKit", "Foundation"],
    "frameworks": ["/opt/homebrew/Caskroom/miniconda/base/lib/libffi.8.dylib"],
    "iconfile": "cc-monitor.icns",
}

setup(
    app=APP,
    data_files=DATA_FILES,
    options={"py2app": OPTIONS},
    setup_requires=["py2app"],
)
