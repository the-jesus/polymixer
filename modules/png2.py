from typing import List
from file_handler import FileHandler
from chunk import Chunk, FixedChunk, FlexibleChunk
from argparse import ArgumentParser
from hook_manager import HookManager
from chunk_manager import ChunkManager
import mmap
import struct
import zlib

class PNGHandler(FileHandler):
    def __init__(self):
        pass

    def setup(self, args, hook_manager: HookManager):
        self.filepath = args.png_file
        self.end_of_truecrypt = 0

        hook_manager.register('placing:chunk', self.place_chunk)
        hook_manager.register('placing:complete', self.place_complete)

    def param(self, parser: ArgumentParser) -> None:
        png_group = parser.add_argument_group("PNG Options")
        png_group.add_argument("--png-file", nargs=None, help="Specify the source PNG file.", required=True)

    def place_chunk(self, start: int, end: int, chunk: Chunk) -> None:

        if chunk.extra != 'png':
            self.end_of_truecrypt = end

        print(start, end, chunk, self.end_of_truecrypt)

        #if chunk.extra != 'png':
        #    print(start, end, chunk)
        #    new_size = end - self.fake_pos
        #    new_size_bytes = new_size.to_bytes(4, byteorder='big')
        #    self.fake[0:4] = new_size_bytes
        #    # crc ändern

    def place_complete(self, chunk_manager: ChunkManager) -> None:
        #print(chunk_manager[0:64])
        size = self.end_of_truecrypt - 41
        self.fake[0:4] = size.to_bytes(4, byteorder='big')
        self.crc[0:4] = zlib.crc32(chunk_manager[41:self.end_of_truecrypt]).to_bytes(4, byteorder='big')
        print(hex(zlib.crc32(chunk_manager[41:self.end_of_truecrypt])))

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

        #pos = 8 + 4 + 4 + size + 4
        pos = 64

        self.crc = bytearray(b'\x00\x00\x00\x00')
        chunks.append(FlexibleChunk(position=(64, None), size=4, offset=0, data=self.crc, extra='png'))

        while pos < len(data):
            size, header = struct.unpack('>I4s', data[pos:pos + 8])
            if header == b'IEND':
                chunks.append(FixedChunk(position=-8, size=size + 8, offset=pos, data=data, extra='png'))
            else:
                chunks.append(FlexibleChunk(position=(pos, None), size=size + 8, offset=pos, data=data, extra='png'))
            pos += 8 + size + 4

        return chunks
