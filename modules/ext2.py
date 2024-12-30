from typing import List
from file_handler import FileHandler
from chunk import Chunk, FixedChunk
from argparse import ArgumentParser
from hook_manager import HookManager
import mmap

class Ext2Handler(FileHandler):
    def setup(self, args, hook_manager: HookManager):
        self.file = args.ext2_file
        self.badblocks_file = args.ext2_badblocks_file
        self.blocksize = int(args.ext2_blocksize)

    def param(self, parser: ArgumentParser) -> None:
        ext2_group = parser.add_argument_group("Ext2 Options")
        ext2_group.add_argument("--ext2-file", nargs=None, help="Specify a file and its arguments.", required=True)
        ext2_group.add_argument("--ext2-badblocks-file", nargs=None, help="Specify a file and its arguments.", required=True)
        ext2_group.add_argument("--ext2-blocksize", nargs=None, help="Specify a block size.", required=True)

    def _get_used_space(self, data, start, end):
        for line in data:
            block = int(line.strip())
            size = (block * self.blocksize) - start
            if size > 0:
                yield start, size + 2 * self.blocksize

            start = (block + 1) * self.blocksize

        size = end - start
        if size > 0:
            yield start, size

    def get_chunks(self) -> List[Chunk]:
        chunks = []

        with open(self.file, 'rb') as f:
            data = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_COPY)
            filesize = f.seek(0, 2)

        with open(self.badblocks_file, "r") as badblocks:
            used_space = self._get_used_space(badblocks, 1024, filesize)
            for start, size in used_space:
                chunks.append(FixedChunk(
                    module=self,
                    position=start,
                    offset=start,
                    size=size,
                    data=data,
                ))

        return chunks
