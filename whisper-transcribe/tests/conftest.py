"""Make `import whisper_runner` work regardless of where pytest was started.

`whisper-transcribe` is a plain directory of scripts, not an installed package,
so the tests could only ever import the runner because `python -m pytest` happens
to put the working directory on `sys.path`. That made the suite depend on being
invoked from exactly one place — and it broke the moment it wasn't.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
