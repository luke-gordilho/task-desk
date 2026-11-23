#!/bin/zsh
cd -- "${0:A:h}"
PYTHON="$(command -v python3)"
if [[ -x /opt/homebrew/bin/python3 ]]; then PYTHON=/opt/homebrew/bin/python3; fi
if curl --silent --fail http://127.0.0.1:8765/api/tasks >/dev/null; then
  open http://127.0.0.1:8765
else
  "$PYTHON" app.py --open
fi
