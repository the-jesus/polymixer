from memory_profiler import profile
from typing import List
from file_handler import FileHandler
from chunk import Chunk, FixedChunk, FlexibleChunk
from argparse import ArgumentParser
from hook_manager import HookManager
import mmap

class TruecryptHandler(FileHandler):
    def setup(self, args, hook_manager: HookManager):
        self.filepath = args.truecrypt_file
        self.reencrypt_key = args.truecrypt_new_salt

        hook_manager.register('place_chunk', self.place_chunk)

    def param(self, parser: ArgumentParser) -> None:
        truecrypt_group = parser.add_argument_group("TrueCrypt Options")
        truecrypt_group.add_argument("--truecrypt-file", nargs=None, help="Specify the source TrueCrypt container.", required=True)
        truecrypt_group.add_argument("--truecrypt-new-salt", action='store_true', help="Enables re-encryption of the key using the specified salt.")

    def place_chunk(self, start: int, end: int, chunk: Chunk) -> None:
        if start < 64:
            # reencrypt the key with the new salt
            pass

    @profile
    def get_chunks(self) -> List[Chunk]:
        with open(self.filepath, 'rb') as f:
            data = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_COPY)
            image_size = f.seek(0, 2)

        header_size = 128 * 1024

        chunks = []

        if self.reencrypt_key:
            chunks.append(FixedChunk(size=448, position=64, offset=0, data=data))
        else:
            chunks.append(FixedChunk(size=512, position=0, offset=0, data=data))

        chunks.append(FixedChunk(size=image_size - header_size, position=header_size, offset=header_size, data=data))

        return chunks
