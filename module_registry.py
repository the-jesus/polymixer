from typing import Dict, List, Type
from file_handler import FileHandler

class ModuleRegistry(object):
    def __init__(self):
        self._modules: Dict[str, Type[FileHandler]] = {}

    def register(self, name: str, module: Type[FileHandler]):
        #if not issubclass(module, FileHandler):
        #    raise ValueError(f"Module {module} is not a subclass of FileHandler.")

        self._modules[name] = module

    def get_modules(self) -> List[str]:
        return list(self._modules.keys())

    def get(self, module_name: str) -> FileHandler:
        if module_name not in self._modules:
            raise ValueError(f"Module {module} is not available")

        return self._modules[module_name]

