from abc import ABC, abstractmethod
from argparse import ArgumentParser
from chunk import Chunk
from typing import List
from hook_manager import HookManager

class FileHandler(ABC):
    def __init__(self, hook_manager: HookManager = None):
        if hook_manager:
            self.hook_manager = hook_manager
        pass

    @abstractmethod
    def param(self, parser: ArgumentParser) -> None:
        pass

    @abstractmethod
    def get_chunks(self) -> List[Chunk]:
        pass
