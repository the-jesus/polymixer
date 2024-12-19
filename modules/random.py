from typing import List
from file_handler import FileHandler
from chunk import Chunk, FixedChunk, FlexibleChunk
from argparse import ArgumentParser
from hook_manager import HookManager
import random

class RandomHandler(FileHandler):
    def setup(self, args, hook_manager: HookManager):
        hook_manager.register('placing:chunk', self.place)
        pass

    def place(self, start, end, chunk) -> None:
        print('hook', start, end, chunk)

    def param(self, parser: ArgumentParser) -> None:
        pass

    def get_chunks(self) -> List[Chunk]:
        data = b'R' * 1024 * 1024
        count = random.randint(16, 64)
        chunks = []
        last_pos = 0

        for _ in range(count):
            type = random.randint(0, 1)
            pos = last_pos + random.randint(1, 512)
            size = random.randint(1, 512)

            if type == 0:
                chunk = FixedChunk(size=size, position=pos, offset=0, data=data)
            else:
                pos2 = pos + random.randint(1, 512)
                chunk = FlexibleChunk(size=size, position=(pos, pos2), offset=0, data=data)

            last_pos = pos + size
            chunks.append(chunk)

        random.shuffle(chunks)

        return chunks
