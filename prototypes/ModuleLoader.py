import importlib
import os
from pathlib import Path
from typing import List, Optional, Type
from types import ModuleType
from file_handler import FileHandler

class ModuleLoader:
    def __init__(self, directory: str):
        """
        Initializes the ModuleLoader and loads all handlers from the specified directory.

        :param directory: Path to the directory containing the modules.
        """
        self.directory = directory
        self._handlers: List[FileHandler] = []
        self._load_modules()

    def _get_handler_from_module(self, module: ModuleType) -> List[FileHandler]:
        """
        Extracts all FileHandler implementations from a module.

        :param module: The Python module to analyze.
        :return: List of instances of FileHandler subclasses.
        """
        functions = [getattr(module, name) for name in dir(module)]
        instances = [item for item in functions if isinstance(item, type)]
        subclasses = [item for item in instances if issubclass(item, FileHandler)]
        implementations = [item for item in subclasses if item is not FileHandler]
        return [item() for item in implementations]

    def _get_module_files(self, directory: str) -> List[str]:
        return [
            file.stem
            for file in Path(directory).glob("*.py")
        ]


    def _load_modules(self) -> None:
        """
        Loads all modules from the specified directory and extracts their handlers.
        """
        if not os.path.isdir(self.directory):
            raise ValueError(f"{self.directory} is not a valid directory.")

        files = self._get_module_files(self.directory)

        # Import modules and extract handlers
        for module_name in files:
            module_path = f'{self.directory}.{module_name}'
            module = importlib.import_module(module_path)
            self._handlers.extend(self._get_handler_from_module(module))

    @property
    def handlers(self) -> List[FileHandler]:
        """
        Returns all loaded FileHandler instances.

        :return: List of FileHandler instances.
        """
        return self._handlers

    def get_handlers(self, file_path: Optional[str] = None) -> List[FileHandler]:
        """
        Returns all handlers or only those that support a specific file, if provided.

        :param file_path: (Optional) Path to a file to filter supported handlers.
        :return: List of FileHandler instances that support the file.
        """
        if file_path is None:
            return self._handlers
        return [handler for handler in self._handlers if handler.supports(file_path)]


# Example: Main program
if __name__ == "__main__":
    directory = "modules"  # Directory containing the modules
    loader = ModuleLoader(directory)

    # Display all loaded handlers
    print("Loaded handlers:", loader.handlers)

    # Example: Process files
    files = ["example.pdf", "archive.zip"]
    for file in files:
        handlers = loader.get_handlers(file)
        if handlers:
            for handler in handlers:
                handler.process(file)
        else:
            print(f"No module supports this file: {file}")
