from abc import ABC, abstractmethod
from typing import Union, List

class Chunk(ABC):
    def __init__(self, name: str = None, size: int = 0, offset: int = 0, data: bytes = None, extra = None):
        self.name = name
        self.size = size
        self.offset = offset
        self.data = data
        self.extra = extra

    def __repr__(self) -> str:
        name_str = f"name={self.name}" if self.name else "no name"
        size_str = f"size={self.size}" if self.size else "no size"
        offset_str = f"offset={self.offset}" if self.offset else "no offset"
        data_str = f"data={self.data[0:9]!r}" if self.data else "no data"
        return f"<Chunk({name_str}, {size_str}, {offset_str}, {data_str})>"

class FixedChunk(Chunk):
    def __init__(self, name: str = None, size: int = 0, offset: int = 0, data: bytes = None, position: Union[int, range, List[int]] = None, extra = None):
        super().__init__(name, size, offset, data, extra)

        self.position = position

    def __repr__(self) -> str:
        name_str = f"name={self.name}" if self.name else "no name"
        position_str = f"position=({self.position!r})"
        size_str = f"size={self.size}" if self.size else "no size"
        offset_str = f"offset={self.offset!r}" if self.offset else "no offset"
        data_str = f"data={self.data[0:9]!r}" if self.data else "no data"
        return f"<FixedChunk({name_str}, {size_str}, {offset_str}, {data_str}, {position_str})>"

class FlexibleChunk(Chunk):
    def __init__(self, name: str = None, size: int = 0, offset: int = 0, data: bytes = None, position: Union[int, range, List[int]] = None, extra = None):
        super().__init__(name, size, offset, data, extra)

        self.position = position

    def __repr__(self) -> str:
        name_str = f"name={self.name}" if self.name else "no name"
        position_str = f"position=({self.position!r})"
        size_str = f"size={self.size}" if self.size else "no size"
        offset_str = f"offset={self.offset!r}" if self.offset else "no offset"
        data_str = f"data={self.data[0:9]!r}" if self.data else "no data"
        return f"<FlexibleChunk({name_str}, {size_str}, {offset_str}, {data_str}, {position_str})>"
