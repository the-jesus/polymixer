import importlib
import sys
import os
import pathlib
from file_handler import FileHandler
from typing import List
from types import ModuleType

def _get_handler_from_module(module: ModuleType):
    functions = [ getattr(module, name) for name in dir(module) ]
    instances = [ item for item in functions if isinstance(item, type) ]
    subclasses = [ item for item in instances if issubclass(item, FileHandler) ]
    implementations = [ item for item in subclasses if item is not FileHandler ]

    return [ item() for item in implementations ]

def _load_modules(path: str):
    handlers = []
    files = [
        file[:-3]
        for file in os.listdir(path) if file.endswith('.py')
    ]

    modules = [
        importlib.import_module(f'{path}.{module_name}')
        for module_name in files
    ]

    handlers = [
        handler
        for module in modules
        for handler in _get_handler_from_module(module)
    ]

    return handlers

def process_file(file_path: str, handlers: List[FileHandler]):
    for handler in handlers:
        if handler.supports(file_path):
            handler.process(file_path)
            return
    print("Kein Modul unterstützt diese Datei.")

if __name__ == "__main__":
    directory = "modules"  # Verzeichnis, in dem die Module gespeichert sind
    handlers = _load_modules(directory)

    # Beispiel: zwei Dateien
    files = ["example.pdf", "archive.zip"]
    for file in files:
        process_file(file, handlers)
