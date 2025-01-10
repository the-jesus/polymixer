from typing import Dict, List, Type
from file_handler import FileHandler

class ModuleRegistry(object):
    __slots__ = '_modules'
    def __init__(self):
        self._modules: Dict[str, Type[FileHandler]] = {}

    def register(self, name: str, module: Type[FileHandler]):
        if not isinstance(module, FileHandler):
            raise ValueError(f"Module {name} is not a subclass of FileHandler.")

        if name in self._modules:
            raise ValueError(f"Module {name} is already registered.")

        self._modules[name] = module

    def get_modules(self) -> List[str]:
        return list(self._modules.keys())

    def get(self, module_name: str) -> FileHandler:
        if module_name not in self._modules:
            raise ValueError(f"Module {module_name} is not available.")

        return self._modules[module_name]

