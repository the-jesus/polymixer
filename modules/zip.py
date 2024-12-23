from file_handler import FileHandler
from argparse import ArgumentParser
from typing import List
from chunk import FixedChunk, Chunk, FlexibleChunk
from hook_manager import HookManager
import struct
import mmap

class LocalFileHeader:
    def __init__(self, cdfh_pos: int, pos: int, data: bytes):
        self.pos = pos
        self.cdfh_pos = cdfh_pos
        (
            self.signature,
            self.version,
            self.flags,
            self.compression_method,
            self.time,
            self.date,
            self.crc,
            self.compressed_size,
            self.uncompressed_size,
            self.filename_length,
            self.extra_length,
        ) = struct.unpack('<IHHHHHIIIHH', data)

    @classmethod
    def match(cls, data: bytes):
        return data[:4] == b'\x50\x4b\x03\x04'

    def size(self) -> int:
        return 30 \
             + self.filename_length \
             + self.extra_length \
             + self.compressed_size

    def __repr__(self) -> str:
        return f"<LFH({self.signature}, {self.uncompressed_size})>"

class EndOfCentralDirectoryRecord:
    def __init__(self, pos: int, data: bytes):
        self.pos = pos
        (
            self.signature,
            self.disk_number,
            self.disk_with_cd,
            self.total_entries_disk,
            self.total_entries,
            self.size,
            self.offset,
            self.comment_length,
        ) = struct.unpack('<IHHHHIIH', data)

    @classmethod
    def match(cls, data: bytes):
        return data[:4] == b'\x50\x4b\x05\x06'

    def __repr__(self) -> str:
        return f"<EOCD({self.signature}, {self.offset})>"

class CentralDirectoryFileHeader:
    def __init__(self, pos: int, data: bytes):
        self.pos = pos
        (
            self.signature,
            self.version_made,
            self.version_needed,
            self.flags,
            self.compression,
            self.mod_time,
            self.mod_date,
            self.crc32,
            self.compressed_size,
            self.uncompressed_size,
            self.filename_length,
            self.extra_length,
            self.comment_length,
            self.disk_number_start,
            self.internal_attrs,
            self.external_attrs,
            self.offset,
        ) = struct.unpack('<IHHHHHHIIIHHHHHII', data)

    @classmethod
    def match(cls, data: bytes):
        return data[:4] == b'\x50\x4b\x01\x02'

    def size(self) -> int:
        return 46 \
             + self.filename_length \
             + self.extra_length \
             + self.comment_length

    def __repr__(self) -> str:
        return f"<CDFH({self.signature}, {self.offset})>"

class ZIPHandler(FileHandler):
    def setup(self, args, hook_manager: HookManager) -> None:
        self.filepath = args.zip_file
        self.first_header = args.zip_first_header

        hook_manager.register('placing:chunk', self.place_chunk)

    def param(self, parser: ArgumentParser) -> None:
        pdf_group = parser.add_argument_group("ZIP Options")
        pdf_group.add_argument("--zip-file", nargs=None, help="Specify a file and its arguments.", required=True)
        pdf_group.add_argument("--zip-first-header", action='store_true', help="If set the zip content starts at position zero.")

    def place_chunk(self, start: int, end: int, chunk: Chunk) -> None:
        if chunk.extra and isinstance(chunk.extra, LocalFileHeader):
            new_block_position = start.to_bytes(4, byteorder='little')
            pos = chunk.extra.cdfh_pos
            dchunk = self.directory_chunk
            dchunk.data[pos + 42:pos + 46] = new_block_position

        if chunk.extra and isinstance(chunk.extra, EndOfCentralDirectoryRecord):
            new_block_position = start.to_bytes(4, byteorder='little')
            pos = chunk.extra.pos
            dchunk = self.directory_chunk
            dchunk.data[pos + 16:pos + 20] = new_block_position

    def get_chunks(self) -> List[Chunk]:
        with open(self.filepath, 'rb') as f:
            data = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_COPY)

        filesize = len(data)

        eocd = self._parse_eocd()
        file_list = self._get_files(eocd)

        first = self.first_header

        chunks = [];
        for file in file_list:
            offset = file.pos
            size = file.size()

            if first:
                chunks.append(FixedChunk(
                    position=offset,
                    size=size,
                    offset=offset,
                    data=data,
                    extra=file,
                ))
                first=False
            else:
                chunks.append(FlexibleChunk(
                    position=(offset, None),
                    size=size,
                    offset=offset,
                    data=data,
                    extra=file,
                ))

        footer_size = (filesize - eocd.offset)

        self.directory_chunk = FixedChunk(
                position=-footer_size,
                size=footer_size,
                offset=eocd.offset,
                data=data,
                extra=eocd,
        )
        chunks.append(self.directory_chunk)

        return chunks

    def _parse_eocd(self) -> EndOfCentralDirectoryRecord:
        with open(self.filepath, 'rb') as f:
            filesize = f.seek(0, 2)

            footer_size = min(65536 + 22, filesize)
            f.seek(-footer_size, 2)
            data = f.read(footer_size)

            for pos in range(0, footer_size):
                if EndOfCentralDirectoryRecord.match(data[pos:pos + 22]):
                    footer_pos = pos
                    break
            else:
                raise ValueError("EOCD signature not found")

            return EndOfCentralDirectoryRecord(footer_pos, data[footer_pos:footer_pos + 22])

    def _get_files(self, eocd: EndOfCentralDirectoryRecord) -> List[LocalFileHeader]:
        with open(self.filepath, 'rb') as f:
            offset = eocd.offset

            files = []
            for _ in range(eocd.total_entries):
                f.seek(offset, 0)
                cdfh_data = f.read(46)

                if not CentralDirectoryFileHeader.match(cdfh_data):
                    raise ValueError("CDFH signature not found")

                cdfh = CentralDirectoryFileHeader(offset, cdfh_data)

                f.seek(cdfh.offset, 0)
                lfh_data = f.read(30)

                lfh = LocalFileHeader(offset, cdfh.offset, lfh_data)

                files.append(lfh)

                offset += cdfh.size()

            return files
