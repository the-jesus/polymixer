from abc import ABC, abstractmethod
from typing import List

class Chunk(ABC):
    def __init__(self, module = None, size: int = 0, offset: int = 0, data: bytes = None, extra = None):
        self.module = module
        self.size = size
        self.offset = offset
        self.data = data
        self.extra = extra

    def __repr__(self) -> str:
        module_str = f"module={self.module}" if self.module else "no module"
        size_str = f"size={self.size}" if self.size else "no size"
        offset_str = f"offset={self.offset}" if self.offset else "no offset"
        data_str = f"data={self.data[0:9]!r}" if self.data else "no data"
        return f"<Chunk({module_str}, {size_str}, {offset_str}, {data_str})>"

class FixedChunk(Chunk):
    def __init__(self, module = None, size: int = 0, offset: int = 0, data: bytes = None, position: int = None, extra = None):
        super().__init__(module, size, offset, data, extra)

        self.position = position

    def __repr__(self) -> str:
        module_str = f"module={self.module}" if self.module else "no module"
        position_str = f"position=({self.position!r})"
        size_str = f"size={self.size}" if self.size else "no size"
        offset_str = f"offset={self.offset!r}" if self.offset else "no offset"
        data_str = f"data={self.data[0:9]!r}" if self.data else "no data"
        return f"<FixedChunk({module_str}, {size_str}, {offset_str}, {data_str}, {position_str})>"

class FlexibleChunk(Chunk):
    def __init__(self, module = None, size: int = 0, offset: int = 0, data: bytes = None, position: List[int] = None, extra = None):
        super().__init__(module, size, offset, data, extra)

        self.position = position

    def __repr__(self) -> str:
        module_str = f"module={self.module}" if self.module else "no module"
        position_str = f"position=({self.position!r})"
        size_str = f"size={self.size}" if self.size else "no size"
        offset_str = f"offset={self.offset!r}" if self.offset else "no offset"
        data_str = f"data={self.data[0:9]!r}" if self.data else "no data"
        return f"<FlexibleChunk({module_str}, {size_str}, {offset_str}, {data_str}, {position_str})>"
