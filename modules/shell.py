from file_handler import FileHandler
from argparse import ArgumentParser
from typing import List
from chunk import Chunk, FixedChunk, FlexibleChunk

class ShellHandler(FileHandler):
    def setup(self, args, foo) -> None:
        self.file = args.shell_file

    def param(self, parser: ArgumentParser) -> None:
        shell_group = parser.add_argument_group("Shell Options")
        shell_group.add_argument("--shell-file", nargs=None, help="Specify a file and its arguments.")

    def get_chunks(self) -> List[Chunk]:
        with open(self.file, 'rb') as f:
            data = f.read()

        data += b'\nexit\n'

        size = len(data)
        return (
            FixedChunk(position=0, size=size, offset=0, data=data),
        )
