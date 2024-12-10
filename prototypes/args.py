from typing import Callable, Dict, List, Type
from file_handler import FileHandler
import argparse

from modules.pdf import PDFHandler
from modules.zip import ZIPHandler
from modules.random import RandomHandler

class ModuleRegistry:
    def __init__(self):
        self._modules: Dict[str, Type[FileHandler]] = {}

    def register(self, name: str, module: Type[FileHandler]):
        if not issubclass(module, FileHandler):
            raise ValueError(f"Module {module} is not a subclass of FileHandler.")

        self._modules[name] = module

    def get_modules(self) -> List[str]:
        """
        Returns a list of all registered module names.
        """
        return list(self._modules.keys())

    def get(self, module_name: str) -> FileHandler:
        if module_name not in self._modules:
            raise ValueError(f"Module {module} is not available")

        return self._modules[name]


modules = [
    PDFHandler(),
    ZIPHandler(),
    RandomHandler(),
]

parser = argparse.ArgumentParser(
    description="A modular program with module-specific help."
)

global_group = parser.add_argument_group("Global Options")
global_group.add_argument("-m", "--module", nargs="+", help="Specify a module and its arguments.")

for module in modules:
    module.param(parser)

args, unknown_args = parser.parse_known_args()

#print(modules)
#print(args, unknown_args)

modules[1].chunk(args)
