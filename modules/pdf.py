from file_handler import FileHandler
from argparse import ArgumentParser
from typing import List
from chunk import Chunk, FixedChunk, FlexibleChunk
from hook_manager import HookManager

class PDFHandler(FileHandler):
    def setup(self, args, hook_manager: HookManager) -> None:
        raise Exception("Not implemented yet")

    def param(self, parser: ArgumentParser) -> None:
        pdf_group = parser.add_argument_group("PDF Options")
        pdf_group.add_argument("--pdf-file", nargs=None, help="Specify a file and its arguments.", required=True)

    def get_chunks(self) -> List[Chunk]:
        data = b'P' * 3000
        return [
            FixedChunk(position=100, size=100, offset=10, data=data),
            FixedChunk(position=1000, size=100, offset=100, data=data),
            FlexibleChunk(position=(1000, 1900), size=100, offset=120, data=data),
            FlexibleChunk(position=(1000, 1900), size=300, offset=120, data=data),
            FlexibleChunk(position=(1800, 2200), size=200, offset=120, data=data),
            FixedChunk(position=2300, size=100, offset=200, data=data),
        ]
