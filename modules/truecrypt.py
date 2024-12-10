from typing import List
from file_handler import FileHandler
from chunk import Chunk, FixedChunk, FlexibleChunk
from argparse import ArgumentParser
from hook_manager import HookManager

class TruecryptHandler(FileHandler):
    def setup(self, args, hook_manager: HookManager):
        self.filepath = args.truecrypt_file

    def param(self, parser: ArgumentParser) -> None:
        truecrypt_group = parser.add_argument_group("Truecrypt Options")
        truecrypt_group.add_argument("--truecrypt-file", nargs=None, help="Specify a file and its arguments.")

    def get_chunks(self) -> List[Chunk]:
        with open(self.filepath, 'rb') as f:
            data = f.read()
            image_size = f.seek(0, 2)

        header_size = 128 * 1024
        return [
            FixedChunk(size=512, position=0, offset=0, data=data),
            FixedChunk(size=image_size - header_size, position=header_size, offset=header_size, data=data),
        ]
