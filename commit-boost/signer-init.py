import os
import logging
import sys
import tomlkit
from pathlib import Path
from collections.abc import Mapping
from typing import Any
from tomlkit.toml_document import TOMLDocument

logger = logging.getLogger("signer-init")
if not logger.handlers:
    _handler = logging.StreamHandler(sys.stdout)
    _handler.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s"))
    logger.addHandler(_handler)
    _level = os.getenv("LOG_LEVEL", "INFO").upper()
    logger.setLevel(getattr(logging, _level, logging.INFO))
    logger.propagate = False  # Prevent propagation to root logger

def getenv_bool(name: str, default: bool = False) -> bool:
    val = os.getenv(name)
    if val is None:
        return default
    return val.strip().lower() in {"true"}

# Load environment variables
COMPOSE_FILE = os.environ["COMPOSE_FILE"]
WEB3SIGNER = getenv_bool("WEB3SIGNER", default=False)
W3S_NODE = os.getenv("W3S_NODE", "")
LOG_LEVEL = os.getenv("LOG_LEVEL", "info").lower()

def get_in(mapping: Mapping[str, Any] ,path: str, default: Any=None) -> Any:
    """Safe lookup like 'signer.remote.url'."""
    cur = mapping
    for key in path.split("."):
        if isinstance(cur, Mapping) and key in cur:
            cur = cur[key]
        else:
            return default
    return cur

def update_signer(doc: TOMLDocument) -> None:

def main():
    path = Path("/cb-config.toml")
    doc = tomlkit.parse(path.read_text(encoding="utf-8"))

    doc["logs"]["stdout"]["level"] = LOG_LEVEL

    update_signer(doc)

    path.write_text(tomlkit.dumps(doc), encoding="utf-8")

    sys.exit(0)

if __name__ == "__main__":
    main()
