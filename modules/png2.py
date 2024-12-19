from typing import List
from file_handler import FileHandler
from chunk import Chunk, FixedChunk, FlexibleChunk
from argparse import ArgumentParser
from hook_manager import HookManager
import mmap
import struct

class PNGHandler(FileHandler):
    def __init__(self):
        pass

    def setup(self, args, hook_manager: HookManager):
        self.filepath = args.png_file

        hook_manager.register('place_chunk', self.place_chunk)

    def param(self, parser: ArgumentParser) -> None:
        png_group = parser.add_argument_group("PNG Options")
        png_group.add_argument("--png-file", nargs=None, help="Specify the source PNG file.", required=True)

    def place_chunk(self, start: int, end: int, chunk: Chunk) -> None:
        if chunk.extra != 'png':
            print(start, end, chunk)
            new_size = end - self.fake_pos
            new_size_bytes = new_size.to_bytes(4, byteorder='big')
            self.fake[0:4] = new_size_bytes
            # crc ändern

    def get_chunks(self) -> List[Chunk]:

        with open(self.filepath, 'rb') as f:
            data = f.read()

        self.data = bytearray(data)

        chunks = []

        size, header = struct.unpack('>I4s', data[8:16])

        chunks.append(FixedChunk(position=0, size=8, offset=0, data=data, extra='png'))
        chunks.append(FixedChunk(position=8, size=4 + 4 + size + 4, offset=8, data=data, extra='png'))

        self.fake_pos = 8 + 4 + 4 + size + 4
        self.fake = bytearray(b'\x00\x00\x00\x00fRAc')
        chunks.append(FixedChunk(position=8 + 4 + 4 + size + 4, size=8, offset=0, data=self.fake, extra='png'))

        pos = 8 + 4 + 4 + size + 4

        crc = b'\x00\x00\x00\x00'
        chunks.append(FlexibleChunk(position=(8 + 4 + 4 + size + 4, None), size=4, offset=0, data=crc, extra='png'))

        while pos < len(data):
            size, header = struct.unpack('>I4s', data[pos:pos + 8])
            if header == b'IEND':
                chunks.append(FixedChunk(position=-8, size=size + 8, offset=pos, data=data))
            else:
                chunks.append(FlexibleChunk(position=(pos, None), size=size + 8, offset=pos, data=data))
            pos += 8 + size + 4

        return chunks
