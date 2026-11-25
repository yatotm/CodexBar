#!/usr/bin/env python3
"""CodexBar 远端部署入口, 复用 App 内置的相同中枢实现"""

import pathlib
import runpy
import sys

sys.dont_write_bytecode = True
TARGET = pathlib.Path(__file__).resolve().parents[1] / "CodexBar/Resources/CodexBarHub.py"

if __name__ == "__main__":
    runpy.run_path(str(TARGET), run_name="__main__")
