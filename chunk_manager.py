from typing import Generator, Tuple
from intervaltree import IntervalTree
from chunk import Chunk, FixedChunk, FlexibleChunk

class ChunkManager(object):
    def __init__(self):
        self.tree = IntervalTree()

    def place(self, start: int, chunk: Chunk) -> None:
        end = start + chunk.size

        if self.tree.overlaps(start, end):
            raise Exception(f"Found overlapping chunk at position {(start, end)}")

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

    def get_tail(self) -> Generator[Tuple[int, Chunk], None, None]:
        new_file_size = self.tree.end() - min(0, self.tree.begin())
        self.tree.slice(0)
        end_interval = self.tree.overlap(self.tree.begin(), 0)
        self.tree.remove_overlap(self.tree.begin(), 0)

        for interval in end_interval:
            start = interval.begin + new_file_size
            chunk = interval.data

            yield (start, chunk)

    def get_data_blocks(self) -> Generator[Tuple[int, bytes], None, None]:
        for interval in self.tree:
            chunk = interval.data
            offset = chunk.offset
            size = chunk.size
            yield (interval.begin, memoryview(chunk.data[offset:offset + size]))

    def get_data(self, start: int, end: int) -> bytes:
        blocks = []

        for interval in sorted(self.tree.overlap(start, end)):
            chunk = interval.data

            if interval.begin <= start:
                s = start - interval.begin + chunk.offset
                e = min(end, interval.end) + chunk.offset
                blocks.append(chunk.data[s:e])
            elif interval.begin > start:
                blocks.append(b'\x00' * (interval.begin - start))
                start = interval.begin
                s = start + chunk.offset
                e = min(end, interval.end) + chunk.offset
                blocks.append(chunk.data[s:e])

            start = interval.end

        if start < end:
            blocks.append(b'\x00' * (end - start))

        return b''.join(blocks)
