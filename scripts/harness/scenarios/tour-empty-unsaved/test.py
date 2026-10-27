"""Every protocol operation against REAPER's startup state: an empty project
that was never saved (see corpus/empty-unsaved.lua)."""
import os

from tour import main

main(None, "empty-unsaved", only=os.environ.get("TOUR_ONLY", "").split() or None)
