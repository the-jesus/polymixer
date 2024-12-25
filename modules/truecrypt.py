from typing import List
from file_handler import FileHandler
from chunk import Chunk, FixedChunk, FlexibleChunk
from argparse import ArgumentParser
from hook_manager import HookManager
from chunk_manager import ChunkManager
import mmap

class TruecryptHandler(FileHandler):
    def setup(self, args, hook_manager: HookManager):
        self.filepath = args.truecrypt_file
        self.reencrypt_key = args.truecrypt_new_salt

        if self.reencrypt_key:
            hook_manager.register('placing:complete', self.chunks_placed)

    def param(self, parser: ArgumentParser) -> None:
        truecrypt_group = parser.add_argument_group("TrueCrypt Options")
        truecrypt_group.add_argument("--truecrypt-file", nargs=None, help="Specify the source TrueCrypt container.", required=True)
        truecrypt_group.add_argument("--truecrypt-new-salt", action='store_true', help="Enables re-encryption of the key using the specified salt.")

    def chunks_placed(self, chunk_manager: ChunkManager) -> None:
        new_salt = chunk_manager[0:64]
        old_salt = self.old_salt

        print('old salt', len(old_salt), old_salt)
        print('new salt', len(new_salt), new_salt)

        # TODO: Reencrypt the key here with the new salt

    def get_chunks(self) -> List[Chunk]:
        with open(self.filepath, 'rb') as f:
            data = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_COPY)
            image_size = f.seek(0, 2)

        header_size = 128 * 1024

        chunks = []

        self.old_salt = data[0:64]

        if self.reencrypt_key:
            chunks.append(FixedChunk(position=64, size=448, offset=0, data=data))
        else:
            chunks.append(FixedChunk(position=0, size=512, offset=0, data=data))

        chunks.append(FixedChunk(position=header_size, size=image_size - header_size, offset=header_size, data=data))

        return chunks
