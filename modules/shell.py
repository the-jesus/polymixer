from file_handler import FileHandler
from argparse import ArgumentParser
from typing import List
from chunk import Chunk, FixedChunk, FlexibleChunk
from chunk_manager import ChunkManager
from hook_manager import HookManager

class ShellHandler(FileHandler):
    def setup(self, args, hook_manager: HookManager) -> None:
        self.pos = 0
        self.file = args.shell_file
        self.header = bytearray(b'\x00' * 64)

        hook_manager.register('placing:complete', self.chunks_placed)
        hook_manager.register('placing:chunk', self.place_chunk)

    def chunks_placed(self, chunk_manager: ChunkManager) -> None:
        pos = str(self.pos + 1).encode()
        new_header = b'#!/bin/bash\ntail -c+' + pos + b' $0|bash\nexit\n'
        self.header[0:len(new_header)] = new_header

    def place_chunk(self, start: int, end: int, chunk: Chunk) -> None:
        if chunk.extra == 'shell':
            self.pos = start

    def param(self, parser: ArgumentParser) -> None:
        shell_group = parser.add_argument_group("Shell Options")
        shell_group.add_argument("--shell-file", nargs=None, help="Specify a file and its arguments.", required=True)

    def get_chunks(self) -> List[Chunk]:
        with open(self.file, 'rb') as f:
            data = f.read()

        data += b'\nexit\n'

        size = len(data)
        return [
            FixedChunk(position=0, size=64, offset=0, data=self.header),
            FlexibleChunk(position=(0, None), size=size, offset=0, data=data, extra='shell'),
        ]
