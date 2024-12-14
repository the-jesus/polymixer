from file_handler import FileHandler
from argparse import ArgumentParser
from typing import List
from chunk import FixedChunk, Chunk, FlexibleChunk
from hook_manager import HookManager
import struct
import mmap

class EndOfCentralDirectoryRecord:
    def __init__(self, data: bytes):
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
        # FIXME: This calculation is incorrect because it uses data
        # from the central directory entry, while the local header might
        # contain different values. Notably, the local header entries do
        # not include a comment field, explaining the unexpected four-byte
        # gap. Review and align the calculation method with the local
        # header's structure.
        return 30 \
             + self.filename_length \
             + self.extra_length \
             + self.comment_length + 4 \
             + self.compressed_size

    def __repr__(self) -> str:
        return f"<CDFH({self.signature}, {self.offset})>"

class ZIPHandler(FileHandler):
    def setup(self, args, hook_manager: HookManager) -> None:
        self.filepath = args.zip_file
        self.first_header = args.zip_first_header

        hook_manager.register('place_chunk', self.place_chunk)

    def param(self, parser: ArgumentParser) -> None:
        pdf_group = parser.add_argument_group("ZIP Options")
        pdf_group.add_argument("--zip-file", nargs=None, help="Specify a file and its arguments.", required=True)
        pdf_group.add_argument("--zip-first-header", action='store_true', help="If set the zip content starts at position zero.")

    def place_chunk(self, start: int, end: int, chunk: Chunk) -> None:
        if chunk.extra and isinstance(chunk.extra, CentralDirectoryFileHeader):
            new_block_position = start.to_bytes(4, byteorder='little')
            pos = chunk.extra.pos
            dchunk = self.directory_chunk
            dchunk.data[pos + 42:pos + 46] = new_block_position

        if chunk.extra and isinstance(chunk.extra, EndOfCentralDirectoryRecord):
            new_block_position = start.to_bytes(4, byteorder='little')
            dchunk = self.directory_chunk
            dchunk.data[-6:-2] = new_block_position

    def get_chunks(self) -> List[Chunk]:
        with open(self.filepath, 'rb') as f:
            data = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_COPY)

        filesize = len(data)

        eocd = self._parse_eocd()
        file_list = self._get_files(eocd)

        first=self.first_header

        chunks = [];
        for file in file_list:
            offset = file.offset
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

        footer_size=(filesize - eocd.offset)

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
            f.seek(-22, 2)
            data = f.read(22)

            if not EndOfCentralDirectoryRecord.match(data):
                raise ValueError("EOCD signature not found")

            return EndOfCentralDirectoryRecord(data)

    def _get_files(self, eocd: EndOfCentralDirectoryRecord) -> List[CentralDirectoryFileHeader]:
        with open(self.filepath, 'rb') as f:
            f.seek(eocd.offset)

            files = []
            for _ in range(eocd.total_entries):
                pos = f.seek(0, 1)
                header = f.read(46)

                if not CentralDirectoryFileHeader.match(header):
                    raise ValueError("CDFH signature not found")

                cdfh = CentralDirectoryFileHeader(pos, header)

                filename = f.read(cdfh.filename_length).decode('utf-8')
                f.seek(cdfh.extra_length + cdfh.comment_length, 1)

                files.append(cdfh)

            return files
