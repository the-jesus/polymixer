from typing import Generator, Tuple, List
from intervaltree import IntervalTree
from chunk import Chunk, FixedChunk, FlexibleChunk
from collections.abc import Sequence

class ChunkManager(Sequence):
    def __init__(self):
        self.tree = IntervalTree()

    def place(self, start: int, chunk: Chunk) -> None:
        end = start + chunk.size

        if self.tree.overlaps(start, end):
            placed_chunk = self.tree.overlap(start, end)
            raise Exception(f"Found overlapping chunk at position {(start, end)} {placed_chunk} vs {chunk}")

        self.tree.addi(start, end, chunk)

    def find_position(self, chunk: FlexibleChunk) -> int:
        size = chunk.size
        first_position = chunk.position[0] if chunk.position[0] != None else self.tree.begin()
        last_position = chunk.position[1] if chunk.position[1] != None else self.tree.end()

        intervals = self.tree.overlap(first_position, last_position)
        positions = set([ first_position ])
        positions.update([ i.end for i in intervals if i.end <= last_position ])

        for position in sorted(positions):
            start = position
            end = position + size

            if not self.tree.overlaps(start, end):
                return position
        else:
            raise Exception("No free space for chunk")

    def get_end_chunks(self) -> Generator[Tuple[int, Chunk], None, None]:
        new_file_size = self.tree.end() - min(0, self.tree.begin())
        self.tree.slice(0)
        end_interval = self.tree.overlap(self.tree.begin(), 0)
        self.tree.remove_overlap(self.tree.begin(), 0)

        for interval in end_interval:
            start = interval.begin + new_file_size
            chunk = interval.data

            yield (start, chunk)

    def get_fixed_chunks(cls, chunks: Chunk) -> List[FixedChunk]:
        return [ c for c in chunks if isinstance(c, FixedChunk) ]

    def get_flexible_chunks(cls, chunks: Chunk) -> List[FlexibleChunk]:
        return [ c for c in chunks if isinstance(c, FlexibleChunk) ]

    def get_data_blocks(self) -> Generator[Tuple[int, bytes], None, None]:
        for interval in self.tree:
            chunk = interval.data
            offset = chunk.offset
            size = chunk.size
            yield (interval.begin, memoryview(chunk.data[offset:offset + size]))

    def __getitem__(self, key: slice) -> bytes:
        if isinstance(key, int):
            start = key
            end = key + 1
        elif isinstance(key, slice):
            start = key.start if key.start != None else self.tree.begin()
            end = key.stop if key.stop != None else self.tree.end()
        else:
            raise Exception(f'Unsupported index: {key}')

        blocks = []

        for interval in sorted(self.tree.overlap(start, end)):
            chunk = interval.data

            if interval.begin > start:
                # Add padding in front of the interval
                blocks.append(b'\x00' * (interval.begin - start))
                start = interval.begin

            o = chunk.offset - interval.begin
            s = start
            e = min(end, interval.end)
            blocks.append(chunk.data[s + o:e + o])

            start = e

        if start < end:
            # If necessary, fill up the end
            blocks.append(b'\x00' * (end - start))

        return b''.join(blocks)

    def __len__(self) -> int:
        return self.tree.span()
